// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./DatasetToken.sol";
import "./RentalPool.sol";
import "./libraries/VirtualAMM.sol";
import "./interfaces/IUniswap.sol";

/**
 * @title IDO
 * @notice Initial Dataset Offering with Virtual AMM pricing
 * @dev Implements:
 *      - Dynamic pricing based on Virtual AMM (Uniswap V2-style constant product)
 *      - Initial price fixed at 0.01 USDC per token
 *      - Buy/sell tokens with USDC using virtual reserves
 *      - Automatic launch when funding goal (rTarget) is reached
 *      - Refund mechanism if minimum raise ratio not met
 *      - 14-day fundraising period
 *
 * IMPORTANT - DECIMAL PRECISION:
 * The contract uses different decimal precision for different tokens:
 *
 * Key points:
 * - USDC: 6 decimals (e.g., 50_000e6 = 50,000 USDC)
 * - Dataset Token: 18 decimals (e.g., 312_500e18 = 312,500 tokens)
 * - Prices: 6 decimals USDC per token (e.g., 0.01e6 = 0.01 USDC)
 * - calculateCost(): Returns 6 decimals (USDC amount including fees)
 * - calculateRefund(): Returns 6 decimals (USDC amount after fees)
 * - buyTokens() maxCost parameter: Expects 6 decimals
 * - sellTokens() minRefund parameter: Expects 6 decimals
 *
 * When interacting with this contract from frontend:
 * - Use parseUnits(amount, 6) for USDC amounts
 * - Use parseUnits(amount, 18) for token amounts
 * - Use formatUnits(amount, 6) to display USDC amounts from calculateCost/calculateRefund
 * - Use parseUnits(userInput, 6) for maxCost/minRefund parameters
 */
contract IDO is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ========== Constants ==========

    /// @notice Fundraising duration (100 days)
    uint256 public constant SALE_DURATION = 100 days;

    /// @notice Buy fee rate (0.3% = 30 / 10000)
    uint256 public constant BUY_FEE_RATE = 30;

    /// @notice Sell fee rate (0.5% = 50 / 10000)
    uint256 public constant SELL_FEE_RATE = 50;

    /// @notice Fee denominator (100% = 10000)
    uint256 public constant FEE_DENOMINATOR = 10000;

    /// @notice Alpha denominator for basis points (100% = 10000)
    uint256 public constant ALPHA_DENOMINATOR = 10000;

    // ========== Initialization Guard ==========

    /// @notice Prevents reinitialization
    bool private _initialized;

    // ========== Configuration Parameters ==========

    /// @notice Funding goal in USDC (6 decimals, e.g., 50_000e6 = 50,000 USDC)
    uint256 public rTarget;

    /// @notice Project ownership ratio in basis points (e.g., 2000 = 20%)
    /// @dev Valid range: 1-5000 (0.01%-50%)
    uint256 public alpha;

    /// @notice Project owner address (multisig wallet)
    address public projectAddress;

    /// @notice Dataset token contract
    address public tokenAddress;

    /// @notice Protocol fee recipient (NOT the Treasury contract)
    /// @dev Receives protocol fees from trading (buy/sell), typically 0.3%-0.5%
    address public feeTo;

    /// @notice USDC token contract
    address public usdcToken;

    /// @notice Governance contract address (merges treasury + voting, handles funds & LP tokens)
    address public governance;

    /// @notice Uniswap V2 Router address
    address public uniswapV2Router;

    /// @notice Uniswap V2 Factory address
    address public uniswapV2Factory;

    /// @notice Created liquidity pair address
    address public liquidityPair;

    // ========== VirtualAMM State ==========

    /// @notice Virtual AMM reserves
    VirtualAMM.Reserves public reserves;

    /// @notice Decimal configuration for USDC and tokens
    VirtualAMM.DecimalConfig public decimalConfig;

    // ========== Derived Values ==========

    /// @notice Total token supply (calculated dynamically)
    uint256 public totalSupply;

    /// @notice Salable tokens (1 - alpha) * totalSupply
    uint256 public salableTokens;

    /// @notice Project reserved tokens (alpha * totalSupply)
    uint256 public projectTokens;

    /// @notice IDO start timestamp
    uint256 public startTime;

    /// @notice IDO end timestamp (startTime + 100 days)
    uint256 public endTime;

    // ========== Dynamic State ==========

    /// @notice Currently sold tokens
    uint256 public soldTokens;

    /// @notice Contract USDC balance (excluding fees)
    /// @dev This represents the actual raised amount. When all salable tokens are sold,
    ///      this is used for liquidity and treasury distribution instead of rTarget.
    ///      May differ slightly from rTarget due to rounding in multiple transactions.
    uint256 public usdcBalance;

    /// @notice IDO status
    enum Status {
        Active,
        Launched,
        Failed
    }
    Status public status;

    /// @notice Launch timestamp (0 if not launched)
    uint256 public launchTime;

    /// @notice Refund rate (USDC per token) when IDO fails
    uint256 public refundRate;

    /// @notice Mapping of users who claimed refund
    mapping(address => bool) public hasClaimedRefund;

    // ========== Dataset Metadata ==========

    /// @notice Metadata version history
    /// @dev Each version contains IPFS CID pointing to complete metadata JSON
    struct MetadataVersion {
        string metadataURI; // IPFS CID
        uint256 timestamp; // Update timestamp
    }

    /// @notice Complete metadata version history
    MetadataVersion[] public metadataHistory;

    // ========== Rental Management ==========

    /// @notice Rental pool (dividend distributor) for this dataset
    address public rentalPool;

    /// @notice Hourly rental rate in USDC (6 decimals)
    uint256 public hourlyRate;

    /// @notice User access expiration timestamp
    mapping(address => uint256) public accessExpiresAt;

    /// @notice Total rental revenue collected
    uint256 public totalRentalCollected;

    /// @notice Protocol fee rate (5% = 500 basis points for rental)
    uint256 public constant PROTOCOL_FEE_RATE = 500;

    // ========== Events ==========

    /**
     * @notice Emitted when tokens are purchased
     */
    event TokensPurchased(
        address indexed buyer,
        uint256 tokenAmount,
        uint256 usdcCost,
        uint256 fee,
        uint256 virtualUsdc,
        uint256 virtualTokens,
        uint256 timestamp
    );

    /**
     * @notice Emitted when tokens are sold back
     */
    event TokensSold(
        address indexed seller,
        uint256 tokenAmount,
        uint256 usdcRefund,
        uint256 fee,
        uint256 virtualUsdc,
        uint256 virtualTokens,
        uint256 timestamp
    );

    /**
     * @notice Emitted when IDO is successfully launched
     */
    event IDOLaunched(
        uint256 finalPrice,
        uint256 totalRaised,
        uint256 lpUSDC,
        uint256 projectFunding,
        uint256 lpTokensLocked,
        uint256 timestamp
    );

    /**
     * @notice Emitted when liquidity is added to Uniswap
     */
    event LiquidityAdded(
        address indexed pair,
        uint256 usdcAmount,
        uint256 tokenAmount,
        uint256 lpTokens
    );

    /**
     * @notice Emitted when IDO fails
     */
    event IDOFailed(
        uint256 soldTokens,
        uint256 usdcBalance,
        uint256 refundRate,
        uint256 timestamp
    );

    /**
     * @notice Emitted when user claims refund
     */
    event RefundClaimed(
        address indexed user,
        uint256 tokenAmount,
        uint256 usdcAmount,
        uint256 timestamp
    );

    /**
     * @notice Emitted when dataset metadata is updated
     */
    event MetadataUpdated(
        string metadataURI,
        uint256 version,
        uint256 timestamp
    );

    /**
     * @notice Emitted when user purchases access
     */
    event AccessPurchased(
        address indexed user,
        uint256 hoursCount,
        uint256 cost,
        uint256 expiresAt
    );

    /**
     * @notice Emitted when rental revenue is distributed
     */
    event RentalDistributed(
        uint256 totalAmount,
        uint256 protocolFee,
        uint256 dividend
    );

    /**
     * @notice Emitted when accumulated revenue increases
     */
    event RevenueAccumulated(uint256 additionalRevenue, uint256 totalRevenue);

    /**
     * @notice Emitted when hourly rate is updated
     */
    event HourlyRateUpdated(uint256 newRate);

    // ========== Errors ==========

    error ZeroAddress(); // Address parameter cannot be zero
    error InvalidParameters(); // Invalid function parameters
    error NotActive(); // IDO is not in active state
    error Expired(); // IDO has expired
    error NotExpired(); // IDO has not expired yet
    error InsufficientAmount(); // Token amount too small
    error SlippageExceeded(); // Price slippage exceeds max tolerance
    error InsufficientBalance(); // User balance insufficient
    error InsufficientUSDC(); // USDC balance insufficient
    error NotFailed(); // IDO has not failed
    error AlreadyClaimed(); // Refund already claimed
    error CannotReachTarget(); // Cannot reach funding target
    error AlreadyInitialized(); // Contract already initialized
    error TransactionExpired(); // Transaction deadline passed
    error OnlyProjectAddress(); // Only project owner can call
    error EmptyMetadataURI(); // Metadata URI cannot be empty
    error InvalidPrice(); // Rental price invalid
    error NoUnlockableLP(); // No LP tokens to unlock
    error Unauthorized(); // Caller not authorized
    error InsufficientUSDCForLP(); // Not enough USDC for liquidity pool
    error DepositFundsFailed(); // Failed to deposit funds to governance
    error LockLPFailed(); // Failed to lock LP tokens

    // ========== Constructor (for implementation contract) ==========

    constructor() {}

    // ========== Modifiers ==========

    /// @notice Ensures transaction deadline has not passed
    /// @param deadline Unix timestamp for transaction expiration
    modifier ensure(uint256 deadline) {
        if (deadline < block.timestamp) revert TransactionExpired();
        _;
    }

    // ========== Initializer ==========

    /**
     * @notice Initializes the cloned IDO contract
     * @param rTarget_ Funding goal in USDC (6 decimals, e.g., 50_000e6 = 50,000 USDC)
     * @param alpha_ Project ownership ratio (basis points, e.g., 2000 = 20%)
     * @param projectAddress_ Project owner address
     * @param tokenAddress_ Dataset token address
     * @param usdcToken_ USDC token address
     * @param feeTo_ Protocol fee recipient address (receives trading and rental fees)
     * @param governance_ Governance contract address (merges treasury + voting, handles funds & LP tokens)
     * @param rentalPool_ Rental pool address (dividend distributor)
     * @param uniswapV2Router_ Uniswap V2 Router address
     * @param uniswapV2Factory_ Uniswap V2 Factory address
     * @param metadataURI_ Initial metadata IPFS CID
     * @param hourlyRate_ Hourly rental rate in USDC
     */
    function initialize(
        uint256 rTarget_,
        uint256 alpha_,
        address projectAddress_,
        address tokenAddress_,
        address usdcToken_,
        address feeTo_,
        address governance_,
        address rentalPool_,
        address uniswapV2Router_,
        address uniswapV2Factory_,
        string memory metadataURI_,
        uint256 hourlyRate_
    ) external {
        if (_initialized) revert AlreadyInitialized();
        _initialized = true;

        // Validate addresses
        if (
            projectAddress_ == address(0) ||
            tokenAddress_ == address(0) ||
            usdcToken_ == address(0) ||
            feeTo_ == address(0) ||
            governance_ == address(0) ||
            rentalPool_ == address(0) ||
            uniswapV2Router_ == address(0) ||
            uniswapV2Factory_ == address(0)
        ) {
            revert ZeroAddress();
        }

        // Validate parameters
        if (rTarget_ == 0) revert InvalidParameters();
        if (alpha_ == 0 || alpha_ > 5000) revert InvalidParameters(); // 0.01%-50%

        // Set parameters
        rTarget = rTarget_;
        alpha = alpha_;
        projectAddress = projectAddress_;
        tokenAddress = tokenAddress_;
        usdcToken = usdcToken_;
        feeTo = feeTo_;
        governance = governance_;
        rentalPool = rentalPool_;
        hourlyRate = hourlyRate_;
        uniswapV2Router = uniswapV2Router_;
        uniswapV2Factory = uniswapV2Factory_;

        // Initialize decimal configuration
        decimalConfig = VirtualAMM.DecimalConfig({
            usdcDecimals: 6,
            tokenDecimals: 18,
            usdcUnit: 1e6,
            tokenUnit: 1e18
        });

        // Calculate total token supply using VirtualAMM
        uint256 sSale;
        uint256 sLP;
        (totalSupply, sSale, sLP) = VirtualAMM.calculateTotalSupply(
            rTarget_,
            alpha_,
            ALPHA_DENOMINATOR,
            decimalConfig
        );

        salableTokens = sSale;
        projectTokens = sLP;

        // Initialize Virtual AMM reserves
        reserves = VirtualAMM.initialize(salableTokens, decimalConfig);

        // Set timestamps
        startTime = block.timestamp;
        endTime = startTime + SALE_DURATION;

        // Set initial status
        status = Status.Active;

        // Validate and store initial metadata
        if (bytes(metadataURI_).length == 0) revert EmptyMetadataURI();
        metadataHistory.push(
            MetadataVersion({
                metadataURI: metadataURI_,
                timestamp: block.timestamp
            })
        );
    }

    // ========== External Functions ==========

    /**
     * @notice Swap USDC for exact amount of tokens
     * @param tokenAmountOut Exact amount of tokens to receive (18 decimals)
     * @param maxUSDCIn Maximum USDC willing to spend (6 decimals, including fees)
     * @param deadline Transaction deadline timestamp
     * @return usdcIn Actual USDC spent (6 decimals, including fees)
     */
    function swapUSDCForExactTokens(
        uint256 tokenAmountOut,
        uint256 maxUSDCIn,
        uint256 deadline
    ) external nonReentrant ensure(deadline) returns (uint256 usdcIn) {
        if (status != Status.Active) revert NotActive();
        if (block.timestamp > endTime) revert Expired();
        if (tokenAmountOut == 0) revert InsufficientAmount();

        // Cap to available salable tokens (prevent overselling)
        uint256 availableTokens = salableTokens - soldTokens;
        uint256 actualTokensOut = tokenAmountOut > availableTokens
            ? availableTokens
            : tokenAmountOut;

        // Also check virtual AMM reserves
        if (actualTokensOut > reserves.y) revert InsufficientBalance();

        // Calculate cost using VirtualAMM (for actual tokens)
        uint256 costWithoutFee = VirtualAMM.getUSDCIn(
            reserves,
            actualTokensOut
        );

        // Calculate fee
        uint256 fee = (costWithoutFee * BUY_FEE_RATE) / FEE_DENOMINATOR;

        // Total cost including fee
        usdcIn = costWithoutFee + fee;

        // Check slippage
        if (usdcIn > maxUSDCIn) revert SlippageExceeded();

        // Transfer USDC from user
        IERC20(usdcToken).safeTransferFrom(msg.sender, address(this), usdcIn);

        // Transfer fee to protocol treasury
        IERC20(usdcToken).safeTransfer(feeTo, fee);

        // Update state
        usdcBalance += costWithoutFee;
        soldTokens += actualTokensOut;

        // Update Virtual AMM reserves
        VirtualAMM.updateReserves(
            reserves,
            int256(costWithoutFee),
            -int256(actualTokensOut)
        );

        // Mint tokens to user (frozen)
        DatasetToken(tokenAddress).transfer(msg.sender, actualTokensOut);

        emit TokensPurchased(
            msg.sender,
            actualTokensOut,
            costWithoutFee,
            fee,
            reserves.x,
            reserves.y,
            block.timestamp
        );

        // Check if all salable tokens are sold and auto-launch
        if (soldTokens == salableTokens) {
            _launch();
        }
    }

    /**
     * @notice Swap exact amount of tokens for USDC
     * @param tokenAmountIn Exact amount of tokens to sell (18 decimals)
     * @param minUSDCOut Minimum USDC expected (6 decimals, after fees)
     * @param deadline Transaction deadline timestamp
     * @return usdcOut Actual USDC received (6 decimals, after fees)
     */
    function swapExactTokensForUSDC(
        uint256 tokenAmountIn,
        uint256 minUSDCOut,
        uint256 deadline
    ) external nonReentrant ensure(deadline) returns (uint256 usdcOut) {
        if (status != Status.Active) revert NotActive();
        if (block.timestamp > endTime) revert Expired();
        if (tokenAmountIn == 0) revert InsufficientAmount();
        if (tokenAmountIn > soldTokens) revert InsufficientBalance();

        // Calculate refund using VirtualAMM
        uint256 refundBeforeFee = VirtualAMM.getUSDCOut(
            reserves,
            tokenAmountIn
        );

        // Calculate fee
        uint256 fee = (refundBeforeFee * SELL_FEE_RATE) / FEE_DENOMINATOR;

        // Net refund after fee
        usdcOut = refundBeforeFee - fee;

        // Check slippage
        if (usdcOut < minUSDCOut) revert SlippageExceeded();

        // Check contract has enough USDC
        if (usdcBalance < refundBeforeFee) revert InsufficientUSDC();

        // Transfer tokens from user back to contract (not burn)
        IERC20(tokenAddress).safeTransferFrom(
            msg.sender,
            address(this),
            tokenAmountIn
        );

        // Update state
        usdcBalance -= refundBeforeFee;
        soldTokens -= tokenAmountIn;

        // Update Virtual AMM reserves
        VirtualAMM.updateReserves(
            reserves,
            -int256(refundBeforeFee),
            int256(tokenAmountIn)
        );

        // Transfer fee to protocol treasury
        IERC20(usdcToken).safeTransfer(feeTo, fee);

        // Transfer refund to user
        IERC20(usdcToken).safeTransfer(msg.sender, usdcOut);

        emit TokensSold(
            msg.sender,
            tokenAmountIn,
            refundBeforeFee,
            fee,
            reserves.x,
            reserves.y,
            block.timestamp
        );
    }

    /**
     * @notice Swap exact amount of USDC for tokens
     * @param usdcAmountIn Exact amount of USDC to spend (6 decimals)
     * @param minTokensOut Minimum tokens expected (18 decimals)
     * @param deadline Transaction deadline timestamp
     * @return tokensOut Actual tokens received (18 decimals)
     */
    function swapExactUSDCForTokens(
        uint256 usdcAmountIn,
        uint256 minTokensOut,
        uint256 deadline
    ) external nonReentrant ensure(deadline) returns (uint256 tokensOut) {
        if (status != Status.Active) revert NotActive();
        if (block.timestamp > endTime) revert Expired();
        if (usdcAmountIn == 0) revert InsufficientAmount();

        // Calculate fee
        uint256 fee = (usdcAmountIn * BUY_FEE_RATE) / FEE_DENOMINATOR;
        uint256 usdcAmountAfterFee = usdcAmountIn - fee;

        // Calculate tokens out using VirtualAMM
        tokensOut = VirtualAMM.getTokensOut(reserves, usdcAmountAfterFee);

        // Cap to available salable tokens and adjust USDC if needed
        uint256 availableTokens = salableTokens - soldTokens;
        uint256 actualUSDCIn = usdcAmountIn;
        uint256 actualFee = fee;
        uint256 actualUSDCAfterFee = usdcAmountAfterFee;
        uint256 refund = 0;

        if (tokensOut > availableTokens) {
            // Cap tokens to available
            tokensOut = availableTokens;

            // Recalculate actual USDC needed for capped tokens
            uint256 actualCostWithoutFee = VirtualAMM.getUSDCIn(
                reserves,
                tokensOut
            );
            actualFee = (actualCostWithoutFee * BUY_FEE_RATE) / FEE_DENOMINATOR;
            actualUSDCIn = actualCostWithoutFee + actualFee;
            actualUSDCAfterFee = actualCostWithoutFee;

            // Calculate refund
            refund = usdcAmountIn - actualUSDCIn;
        }

        // Check slippage (using capped tokensOut)
        if (tokensOut < minTokensOut) revert SlippageExceeded();

        // Also check virtual AMM reserves
        if (tokensOut > reserves.y) revert InsufficientBalance();

        // Transfer USDC from user
        IERC20(usdcToken).safeTransferFrom(
            msg.sender,
            address(this),
            actualUSDCIn
        );

        // Transfer fee to protocol treasury
        IERC20(usdcToken).safeTransfer(feeTo, actualFee);

        // Update state
        usdcBalance += actualUSDCAfterFee;
        soldTokens += tokensOut;

        // Update Virtual AMM reserves
        VirtualAMM.updateReserves(
            reserves,
            int256(actualUSDCAfterFee),
            -int256(tokensOut)
        );

        // Mint tokens to user (frozen)
        DatasetToken(tokenAddress).transfer(msg.sender, tokensOut);

        // Refund excess USDC if capped
        if (refund > 0) {
            IERC20(usdcToken).safeTransfer(msg.sender, refund);
        }

        emit TokensPurchased(
            msg.sender,
            tokensOut,
            actualUSDCAfterFee,
            actualFee,
            reserves.x,
            reserves.y,
            block.timestamp
        );

        // Check if all salable tokens are sold and auto-launch
        if (soldTokens == salableTokens) {
            _launch();
        }
    }

    /**
     * @notice Swap tokens for exact amount of USDC
     * @param usdcAmountOut Exact amount of USDC to receive (6 decimals)
     * @param maxTokensIn Maximum tokens willing to sell (18 decimals)
     * @param deadline Transaction deadline timestamp
     * @return tokensIn Actual tokens sold (18 decimals)
     */
    function swapTokensForExactUSDC(
        uint256 usdcAmountOut,
        uint256 maxTokensIn,
        uint256 deadline
    ) external nonReentrant ensure(deadline) returns (uint256 tokensIn) {
        if (status != Status.Active) revert NotActive();
        if (block.timestamp > endTime) revert Expired();
        if (usdcAmountOut == 0) revert InsufficientAmount();

        // Calculate USDC before fee from desired output after fee
        // usdcOut = usdcBeforeFee - fee
        // usdcOut = usdcBeforeFee * (1 - SELL_FEE_RATE/FEE_DENOMINATOR)
        // usdcBeforeFee = usdcOut / (1 - SELL_FEE_RATE/FEE_DENOMINATOR)
        // usdcBeforeFee = usdcOut * FEE_DENOMINATOR / (FEE_DENOMINATOR - SELL_FEE_RATE)
        uint256 usdcBeforeFee = (usdcAmountOut * FEE_DENOMINATOR) /
            (FEE_DENOMINATOR - SELL_FEE_RATE);

        // Calculate tokens in using VirtualAMM
        tokensIn = VirtualAMM.getTokensIn(reserves, usdcBeforeFee);

        // Check slippage
        if (tokensIn > maxTokensIn) revert SlippageExceeded();

        // Check if user has enough tokens sold
        if (tokensIn > soldTokens) revert InsufficientBalance();

        // Check contract has enough USDC
        if (usdcBalance < usdcBeforeFee) revert InsufficientUSDC();

        // Calculate fee
        uint256 fee = usdcBeforeFee - usdcAmountOut;

        // Transfer tokens from user back to contract
        IERC20(tokenAddress).safeTransferFrom(
            msg.sender,
            address(this),
            tokensIn
        );

        // Update state
        usdcBalance -= usdcBeforeFee;
        soldTokens -= tokensIn;

        // Update Virtual AMM reserves
        VirtualAMM.updateReserves(
            reserves,
            -int256(usdcBeforeFee),
            int256(tokensIn)
        );

        // Transfer fee to protocol treasury
        IERC20(usdcToken).safeTransfer(feeTo, fee);

        // Transfer USDC to user
        IERC20(usdcToken).safeTransfer(msg.sender, usdcAmountOut);

        emit TokensSold(
            msg.sender,
            tokensIn,
            usdcBeforeFee,
            fee,
            reserves.x,
            reserves.y,
            block.timestamp
        );
    }

    /**
     * @notice Trigger refund process if IDO failed
     * @dev Can be called by anyone after expiry if not all tokens were sold
     */
    function triggerRefund() external {
        if (status != Status.Active) revert NotActive();
        if (block.timestamp <= endTime) revert NotExpired();

        // Check if all salable tokens were sold (success case)
        if (soldTokens == salableTokens) revert CannotReachTarget();

        // Update status
        status = Status.Failed;

        // Calculate refund rate (USDC per token in 6 decimals)
        if (soldTokens > 0) {
            // refundRate has 6 decimals: (usdcBalance * 1e18) / soldTokens / 1e18 = usdcBalance / soldTokens
            // But we need to scale properly: usdcBalance (6 decimals) / soldTokens (18 decimals)
            // Result: refundRate in format where (tokenAmount * refundRate) / 1e18 gives USDC (6 decimals)
            refundRate = (usdcBalance * 1e18) / soldTokens;
        }

        emit IDOFailed(soldTokens, usdcBalance, refundRate, block.timestamp);
    }

    /**
     * @notice Claim refund after IDO fails
     * @return refundAmount Amount of USDC refunded
     */
    function claimRefund()
        external
        nonReentrant
        returns (uint256 refundAmount)
    {
        if (status != Status.Failed) revert NotFailed();
        if (hasClaimedRefund[msg.sender]) revert AlreadyClaimed();

        uint256 tokenBalance = IERC20(tokenAddress).balanceOf(msg.sender);
        if (tokenBalance == 0) revert InsufficientBalance();

        // Calculate refund
        refundAmount = (tokenBalance * refundRate) / 1e18;

        // Mark as claimed
        hasClaimedRefund[msg.sender] = true;

        // Burn tokens (transfer back to this contract)
        IERC20(tokenAddress).safeTransferFrom(
            msg.sender,
            address(this),
            tokenBalance
        );

        // Transfer USDC refund
        IERC20(usdcToken).safeTransfer(msg.sender, refundAmount);

        emit RefundClaimed(
            msg.sender,
            tokenBalance,
            refundAmount,
            block.timestamp
        );
    }

    // ========== View Functions ==========

    /**
     * @notice Get current token price
     * @return price Current price in USDC (6 decimals)
     */
    function getCurrentPrice() public view returns (uint256 price) {
        return VirtualAMM.getCurrentPrice(reserves, decimalConfig);
    }

    /**
     * @notice Predict USDC cost for exact token output
     * @param tokenAmountOut Amount of tokens to buy (18 decimals)
     * @return usdcIn USDC cost (6 decimals, including 0.3% fee)
     */
    function predictUSDCIn(
        uint256 tokenAmountOut
    ) external view returns (uint256 usdcIn) {
        // Check if purchase would exceed available tokens
        if (tokenAmountOut > reserves.y) return 0;

        uint256 costWithoutFee = VirtualAMM.getUSDCIn(reserves, tokenAmountOut);
        uint256 fee = (costWithoutFee * BUY_FEE_RATE) / FEE_DENOMINATOR;
        usdcIn = costWithoutFee + fee;
    }

    /**
     * @notice Predict USDC output for exact token input
     * @param tokenAmountIn Amount of tokens to sell (18 decimals)
     * @return usdcOut USDC output (6 decimals, after 0.5% fee)
     */
    function predictUSDCOut(
        uint256 tokenAmountIn
    ) external view returns (uint256 usdcOut) {
        if (tokenAmountIn > soldTokens) return 0;

        uint256 refundBeforeFee = VirtualAMM.getUSDCOut(
            reserves,
            tokenAmountIn
        );
        uint256 fee = (refundBeforeFee * SELL_FEE_RATE) / FEE_DENOMINATOR;
        usdcOut = refundBeforeFee - fee;
    }

    /**
     * @notice Predict token output for exact USDC input
     * @param usdcAmountIn Amount of USDC to spend (6 decimals)
     * @return tokensOut Token output (18 decimals, after 0.3% fee)
     */
    function predictTokensOut(
        uint256 usdcAmountIn
    ) external view returns (uint256 tokensOut) {
        if (usdcAmountIn == 0) return 0;

        // Calculate fee
        uint256 fee = (usdcAmountIn * BUY_FEE_RATE) / FEE_DENOMINATOR;
        uint256 usdcAmountAfterFee = usdcAmountIn - fee;

        // Calculate tokens out using VirtualAMM
        tokensOut = VirtualAMM.getTokensOut(reserves, usdcAmountAfterFee);

        // Check if purchase would exceed available tokens
        if (tokensOut > reserves.y) return 0;
    }

    /**
     * @notice Predict token input for exact USDC output
     * @param usdcAmountOut Amount of USDC to receive (6 decimals)
     * @return tokensIn Token input (18 decimals, with 0.5% fee included)
     */
    function predictTokensIn(
        uint256 usdcAmountOut
    ) external view returns (uint256 tokensIn) {
        if (usdcAmountOut == 0) return 0;

        // Calculate USDC before fee from desired output after fee
        uint256 usdcBeforeFee = (usdcAmountOut * FEE_DENOMINATOR) /
            (FEE_DENOMINATOR - SELL_FEE_RATE);

        // Check if contract has enough USDC
        if (usdcBeforeFee > usdcBalance) return 0;

        // Calculate tokens in using VirtualAMM
        tokensIn = VirtualAMM.getTokensIn(reserves, usdcBeforeFee);

        // Check if it exceeds sold tokens
        if (tokensIn > soldTokens) return 0;
    }

    /**
     * @notice Get IDO progress information
     * @return sold Tokens sold
     * @return target Target tokens (salableTokens)
     * @return percentage Progress percentage (basis points)
     * @return timeLeft Time left in seconds (0 if expired)
     */
    function getProgress()
        external
        view
        returns (
            uint256 sold,
            uint256 target,
            uint256 percentage,
            uint256 timeLeft
        )
    {
        sold = soldTokens;
        target = salableTokens;
        percentage = salableTokens > 0
            ? (soldTokens * FEE_DENOMINATOR) / salableTokens
            : 0;
        timeLeft = block.timestamp >= endTime ? 0 : endTime - block.timestamp;
    }

    /**
     * @notice Get user information
     * @param user User address
     * @return tokenBalance User's token balance
     * @return potentialRefund Potential refund if selling all tokens now
     * @return hasClaimed Whether user claimed refund (if failed)
     */
    function getUserInfo(
        address user
    )
        external
        view
        returns (uint256 tokenBalance, uint256 potentialRefund, bool hasClaimed)
    {
        tokenBalance = IERC20(tokenAddress).balanceOf(user);

        if (
            status == Status.Active &&
            tokenBalance > 0 &&
            tokenBalance <= soldTokens
        ) {
            uint256 refundBeforeFee = VirtualAMM.getUSDCOut(
                reserves,
                tokenBalance
            );
            uint256 fee = (refundBeforeFee * SELL_FEE_RATE) / FEE_DENOMINATOR;
            potentialRefund = refundBeforeFee - fee;
        } else if (status == Status.Failed && tokenBalance > 0) {
            potentialRefund = (tokenBalance * refundRate) / 1e18;
        }

        hasClaimed = hasClaimedRefund[user];
    }

    // ========== Internal Functions ==========

    /**
     * @notice Execute IDO launch process
     * @dev Called automatically when all salable tokens are sold
     *
     * Fund Allocation Strategy (per design document section 2.3):
     * 1. Get final price from actual AMM reserves (not formula, to avoid rounding errors)
     * 2. Calculate LP pairing: USDC_LP = S_LP × P_final
     * 3. Allocate funds:
     *    - LP: USDC_LP (for Uniswap liquidity)
     *    - Treasury: usdcBalance - USDC_LP (project funding)
     * 4. LP ownership: Governance contract (for DAO control)
     */
    function _launch() internal {
        // Update status
        status = Status.Launched;
        launchTime = block.timestamp;

        // Get final price from actual AMM reserves
        // Use getCurrentPrice() instead of calculateFinalPrice formula
        // because actual swaps have rounding errors that cause reserves to differ from theory
        uint256 finalPrice = getCurrentPrice();

        // LP token amount is all project reserved tokens (S_LP = alpha * S_total)
        uint256 lpTokenAmount = projectTokens;

        // Calculate USDC needed for LP pairing at final price
        // finalPrice: 6 decimals (USDC), lpTokenAmount: 18 decimals (token)
        // Result: lpFunds in 6 decimals (USDC)
        uint256 lpFunds = (lpTokenAmount * finalPrice) / 1e18;

        // Ensure we have enough USDC for LP (should always be true if math is correct)
        if (lpFunds > usdcBalance) revert InsufficientUSDCForLP();

        // Treasury gets remaining USDC: actualRaised - USDC_LP
        uint256 projectFunds = usdcBalance - lpFunds;

        // Deposit project funds to Governance (which includes treasury functionality)
        if (projectFunds > 0) {
            IERC20(usdcToken).forceApprove(governance, projectFunds);
            (bool success, ) = governance.call(
                abi.encodeWithSignature("depositFunds(uint256)", projectFunds)
            );
            if (!success) revert DepositFundsFailed();
        }

        // Create Uniswap V2 liquidity pool
        // Note: LP tokens are sent to Governance contract for permanent locking
        uint256 lpTokensReceived = _createLiquidity(lpFunds, lpTokenAmount);

        // Transfer LP tokens to Governance and lock them
        IERC20(liquidityPair).forceApprove(governance, lpTokensReceived);
        (bool lockSuccess, ) = governance.call(
            abi.encodeWithSignature(
                "lockLP(address,uint256)",
                liquidityPair,
                lpTokensReceived
            )
        );
        if (!lockSuccess) revert LockLPFailed();

        // Unfreeze tokens (now all holders can transfer)
        DatasetToken(tokenAddress).unfreeze();

        emit IDOLaunched(
            finalPrice,
            usdcBalance,
            lpFunds,
            projectFunds,
            lpTokensReceived,
            block.timestamp
        );
    }

    /**
     * @notice Creates Uniswap V2 liquidity pool and receives LP tokens to this contract
     * @param usdcAmount Amount of USDC for liquidity
     * @param tokenAmount Amount of dataset tokens for liquidity
     * @return liquidity Amount of LP tokens received
     */
    function _createLiquidity(
        uint256 usdcAmount,
        uint256 tokenAmount
    ) internal returns (uint256 liquidity) {
        // Get or create pair
        address pair = IUniswapV2Factory(uniswapV2Factory).getPair(
            usdcToken,
            tokenAddress
        );

        if (pair == address(0)) {
            pair = IUniswapV2Factory(uniswapV2Factory).createPair(
                usdcToken,
                tokenAddress
            );
        }

        liquidityPair = pair;

        // Approve router to spend tokens
        IERC20(usdcToken).forceApprove(uniswapV2Router, usdcAmount);
        IERC20(tokenAddress).forceApprove(uniswapV2Router, tokenAmount);

        // Add liquidity with 1% slippage tolerance
        uint256 minUSDC = (usdcAmount * 99) / 100;
        uint256 minToken = (tokenAmount * 99) / 100;

        (uint256 amountUSDC, uint256 amountToken, uint256 lpTokens) = IUniswapV2Router02(
            uniswapV2Router
        ).addLiquidity(
                usdcToken,
                tokenAddress,
                usdcAmount,
                tokenAmount,
                minUSDC,
                minToken,
                address(this), // LP tokens sent to this IDO contract for locking
                block.timestamp + 300 // 5 minute deadline
            );

        emit LiquidityAdded(pair, amountUSDC, amountToken, lpTokens);

        return lpTokens;
    }

    // ========== Metadata Management ==========

    /**
     * @notice Update dataset metadata
     * @dev Only project owner can update metadata
     * @param newMetadataURI New IPFS CID pointing to updated metadata JSON
     */
    function updateMetadata(string calldata newMetadataURI) external {
        if (msg.sender != projectAddress) revert OnlyProjectAddress();
        if (bytes(newMetadataURI).length == 0) revert EmptyMetadataURI();

        metadataHistory.push(
            MetadataVersion({
                metadataURI: newMetadataURI,
                timestamp: block.timestamp
            })
        );

        emit MetadataUpdated(
            newMetadataURI,
            metadataHistory.length - 1,
            block.timestamp
        );
    }

    /**
     * @notice Get complete metadata history
     * @dev Frontend can derive:
     *      - Current metadata: history[history.length - 1]
     *      - Version count: history.length
     *      - Specific version: history[version]
     * @return history Array of all metadata versions
     */
    function getMetadataHistory()
        external
        view
        returns (MetadataVersion[] memory history)
    {
        return metadataHistory;
    }

    // ========== Rental Management ==========

    /**
     * @notice Purchase data access for specified hours
     * @dev Automatically distributes rental: 5% protocol fee + 95% dividends
     *      Updates LP unlock progress based on 100% rental amount
     *      Access rights are time-based and can be extended by purchasing again
     * @param hoursCount Number of hours to purchase
     */
    function purchaseAccess(uint256 hoursCount) external nonReentrant {
        if (hoursCount == 0) revert InsufficientAmount();
        if (hourlyRate == 0) revert InvalidPrice();

        uint256 cost = hourlyRate * hoursCount;

        // Transfer USDC from user
        IERC20(usdcToken).safeTransferFrom(msg.sender, address(this), cost);

        // Calculate fees and dividends
        uint256 protocolFee = (cost * PROTOCOL_FEE_RATE) / FEE_DENOMINATOR;
        uint256 dividend = cost - protocolFee;

        // Transfer protocol fee
        if (feeTo != address(0)) {
            IERC20(usdcToken).safeTransfer(feeTo, protocolFee);
        }

        // Approve and add dividends to rental pool
        if (rentalPool != address(0)) {
            IERC20(usdcToken).forceApprove(rentalPool, dividend);
            RentalPool(rentalPool).addRevenue(dividend);
        }

        // Update access rights
        uint256 currentExpiry = accessExpiresAt[msg.sender];
        uint256 newExpiry = (currentExpiry > block.timestamp)
            ? currentExpiry + hoursCount * 1 hours
            : block.timestamp + hoursCount * 1 hours;

        accessExpiresAt[msg.sender] = newExpiry;

        // Update statistics
        totalRentalCollected += cost;

        emit AccessPurchased(msg.sender, hoursCount, cost, newExpiry);
        emit RentalDistributed(cost, protocolFee, dividend);
    }

    /**
     * @notice Update hourly rental price
     * @dev Can only be called by project owner or governance
     * @param newRate New hourly rate (USDC with 6 decimals)
     */
    function updateHourlyRate(uint256 newRate) external {
        if (msg.sender != projectAddress && msg.sender != governance)
            revert Unauthorized();
        if (newRate == 0) revert InvalidPrice();

        hourlyRate = newRate;

        emit HourlyRateUpdated(newRate);
    }

    /**
     * @notice Check if user has valid access
     * @param user User address
     * @return hasAccess True if user has valid access
     */
    function hasValidAccess(address user) external view returns (bool) {
        return accessExpiresAt[user] > block.timestamp;
    }

    /**
     * @notice Get remaining access time for user
     * @param user User address
     * @return remainingTime Remaining seconds of access (0 if expired)
     */
    function getRemainingAccessTime(
        address user
    ) external view returns (uint256 remainingTime) {
        uint256 expiry = accessExpiresAt[user];
        if (expiry <= block.timestamp) return 0;
        return expiry - block.timestamp;
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./DatasetToken.sol";

/**
 * @title IDO
 * @notice Initial Dataset Offering with Bonding Curve pricing
 * @dev Implements:
 *      - Dynamic pricing based on square-root bonding curve
 *      - Buy/sell tokens with USDC
 *      - Automatic launch when target is reached
 *      - Refund mechanism if target not met
 *      - 14-day fundraising period
 *
 * IMPORTANT - DECIMAL PRECISION:
 * The contract's return value precision depends on the 'k' parameter:
 *
 * Key points:
 * - initialPrice: Stored as 6 decimals (e.g., 1000000 = 1 USDC)
 * - k: MUST be a unitless number (e.g., 1000 or 3000), NOT scaled by 1e18!
 * - calculateCost(): Returns 6 decimals when k is unitless (e.g., 1003000000 = 1003 USDC)
 * - calculateRefund(): Returns 6 decimals
 * - buyTokens() maxCost parameter: Expects 6 decimals
 * - sellTokens() minRefund parameter: Expects 6 decimals
 *
 * When interacting with this contract from frontend:
 * - Pass k as a raw number (e.g., BigInt(1000)), NOT parseUnits(k, 18)
 * - Use formatUnits(amount, 6) to display USDC amounts from calculateCost/calculateRefund
 * - Use parseUnits(userInput, 6) for maxCost/minRefund parameters
 */
contract IDO is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ========== Constants ==========

    /// @notice Total token supply (1 million tokens)
    uint256 public constant TOTAL_SUPPLY = 1_000_000 * 10 ** 18;

    /// @notice Fundraising duration (14 days)
    uint256 public constant SALE_DURATION = 14 days;

    /// @notice Buy fee rate (0.3% = 30 / 10000)
    uint256 public constant BUY_FEE_RATE = 30;

    /// @notice Sell fee rate (0.5% = 50 / 10000)
    uint256 public constant SELL_FEE_RATE = 50;

    /// @notice Fee denominator (100% = 10000)
    uint256 public constant FEE_DENOMINATOR = 10000;

    // ========== Initialization Guard ==========

    /// @notice Prevents reinitialization
    bool private _initialized;

    // ========== Configuration Parameters ==========

    /// @notice Project reserved token ratio (e.g., 2000 = 20%)
    uint256 public alphaProject;

    /// @notice Price growth coefficient in USD (scaled by 1e6, e.g., 9e6 = 9 USD)
    /// @dev Represents the USD value added to final price when all tokens are sold
    ///      Recommended range: 6e6 to 12e6 (6-12 USD)
    ///      Example: k=9e6 means final price = initial price + 9 USD
    uint256 public k;

    /// @notice LP lock ratio (e.g., 7000 = 70% of raised funds for LP)
    uint256 public betaLP;

    /// @notice Minimum raise ratio (e.g., 7500 = 75%, must sell at least 75% to succeed)
    uint256 public minRaiseRatio;

    /// @notice Initial price in USDC (6 decimals)
    uint256 public initialPrice;

    /// @notice Project owner address (multisig wallet)
    address public projectAddress;

    /// @notice Dataset token contract
    address public tokenAddress;

    /// @notice Protocol treasury address (receives fees)
    address public protocolTreasury;

    /// @notice USDC token contract
    address public usdcToken;

    /// @notice DAO Treasury address (receives project funding)
    address public daoTreasury;

    /// @notice Rental Manager address (receives LP tokens)
    address public rentalManager;

    // ========== Derived Values ==========

    /// @notice Salable tokens (1 - alpha) * TOTAL_SUPPLY
    uint256 public salableTokens;

    /// @notice Project reserved tokens (alpha * TOTAL_SUPPLY)
    uint256 public projectTokens;

    /// @notice Target tokens to sell (100% of salable tokens)
    uint256 public targetTokens;

    /// @notice IDO start timestamp
    uint256 public startTime;

    /// @notice IDO end timestamp (startTime + 14 days)
    uint256 public endTime;

    // ========== Dynamic State ==========

    /// @notice Currently sold tokens
    uint256 public soldTokens;

    /// @notice Contract USDC balance (excluding fees)
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

    // ========== Events ==========

    /**
     * @notice Emitted when tokens are purchased
     */
    event TokensPurchased(
        address indexed buyer,
        uint256 tokenAmount,
        uint256 usdcCost,
        uint256 fee,
        uint256 newPrice,
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
        uint256 newPrice,
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

    // ========== Errors ==========

    error ZeroAddress();
    error InvalidParameters();
    error NotActive();
    error Expired();
    error NotExpired();
    error InsufficientAmount();
    error SlippageExceeded();
    error InsufficientBalance();
    error InsufficientUSDC();
    error NotFailed();
    error AlreadyClaimed();
    error CannotReachTarget();
    error AlreadyInitialized();

    // ========== Constructor (for implementation contract) ==========

    constructor() {}

    // ========== Initializer ==========

    /**
     * @notice Initializes the cloned IDO contract
     * @param alphaProject_ Project reserved ratio (basis points, e.g., 2000 = 20%)
     * @param k_ Price growth coefficient (unitless, e.g., 1000 or 3000, NOT 1000e18)
     * @param betaLP_ LP lock ratio (basis points, e.g., 7000 = 70%)
     * @param minRaiseRatio_ Minimum raise ratio (basis points, e.g., 7500 = 75%)
     * @param initialPrice_ Initial token price in USDC (6 decimals)
     * @param projectAddress_ Project owner address
     * @param tokenAddress_ Dataset token address
     * @param usdcToken_ USDC token address
     * @param protocolTreasury_ Protocol treasury address
     * @param daoTreasury_ DAO treasury address
     * @param rentalManager_ Rental manager address
     */
    function initialize(
        uint256 alphaProject_,
        uint256 k_,
        uint256 betaLP_,
        uint256 minRaiseRatio_,
        uint256 initialPrice_,
        address projectAddress_,
        address tokenAddress_,
        address usdcToken_,
        address protocolTreasury_,
        address daoTreasury_,
        address rentalManager_
    ) external {
        if (_initialized) revert AlreadyInitialized();
        _initialized = true;

        // Validate addresses
        if (
            projectAddress_ == address(0) ||
            tokenAddress_ == address(0) ||
            usdcToken_ == address(0) ||
            protocolTreasury_ == address(0) ||
            daoTreasury_ == address(0) ||
            rentalManager_ == address(0)
        ) {
            revert ZeroAddress();
        }

        // Validate parameters
        if (alphaProject_ >= FEE_DENOMINATOR || betaLP_ >= FEE_DENOMINATOR) {
            revert InvalidParameters();
        }
        if (minRaiseRatio_ < 5000 || minRaiseRatio_ > FEE_DENOMINATOR) {
            revert InvalidParameters();
        }
        if (k_ == 0 || initialPrice_ == 0) {
            revert InvalidParameters();
        }

        // Set parameters
        alphaProject = alphaProject_;
        k = k_;
        betaLP = betaLP_;
        minRaiseRatio = minRaiseRatio_;
        initialPrice = initialPrice_;
        projectAddress = projectAddress_;
        tokenAddress = tokenAddress_;
        usdcToken = usdcToken_;
        protocolTreasury = protocolTreasury_;
        daoTreasury = daoTreasury_;
        rentalManager = rentalManager_;

        // Calculate derived values
        projectTokens = (TOTAL_SUPPLY * alphaProject_) / FEE_DENOMINATOR;
        salableTokens = TOTAL_SUPPLY - projectTokens;
        targetTokens = salableTokens;

        // Set timestamps
        startTime = block.timestamp;
        endTime = startTime + SALE_DURATION;

        // Set initial status
        status = Status.Active;
    }

    // ========== External Functions ==========

    /**
     * @notice Buy tokens with USDC
     * @param tokenAmount Amount of tokens to buy (18 decimals)
     * @param maxCost Maximum USDC willing to pay (18 decimals, including fees) for slippage protection
     * @return cost Actual USDC cost (18 decimals, including fees)
     */
    function buyTokens(
        uint256 tokenAmount,
        uint256 maxCost
    ) external nonReentrant returns (uint256 cost) {
        if (status != Status.Active) revert NotActive();
        if (block.timestamp > endTime) revert Expired();
        if (tokenAmount == 0) revert InsufficientAmount();

        // Check if purchase would exceed available tokens
        if (soldTokens + tokenAmount > salableTokens) {
            revert InsufficientBalance();
        }

        // Calculate cost using bonding curve
        uint256 costWithoutFee = _calculateCost(
            soldTokens,
            soldTokens + tokenAmount
        );

        // Calculate fee
        uint256 fee = (costWithoutFee * BUY_FEE_RATE) / FEE_DENOMINATOR;

        // Total cost including fee
        cost = costWithoutFee + fee;

        // Check slippage
        if (cost > maxCost) revert SlippageExceeded();

        // Transfer USDC from user
        IERC20(usdcToken).safeTransferFrom(msg.sender, address(this), cost);

        // Transfer fee to protocol treasury
        IERC20(usdcToken).safeTransfer(protocolTreasury, fee);

        // Update state
        usdcBalance += costWithoutFee;
        soldTokens += tokenAmount;

        // Mint tokens to user (frozen)
        DatasetToken(tokenAddress).transfer(msg.sender, tokenAmount);

        // Get new price
        uint256 newPrice = getCurrentPrice();

        emit TokensPurchased(
            msg.sender,
            tokenAmount,
            costWithoutFee,
            fee,
            newPrice,
            block.timestamp
        );

        // Check if target reached and auto-launch
        if (soldTokens >= targetTokens) {
            _launch();
        }
    }

    /**
     * @notice Sell tokens back to contract for USDC
     * @param tokenAmount Amount of tokens to sell (18 decimals)
     * @param minRefund Minimum USDC expected (18 decimals, after fees) for slippage protection
     * @return refund Actual USDC refund (18 decimals, after fees)
     */
    function sellTokens(
        uint256 tokenAmount,
        uint256 minRefund
    ) external nonReentrant returns (uint256 refund) {
        if (status != Status.Active) revert NotActive();
        if (block.timestamp > endTime) revert Expired();
        if (tokenAmount == 0) revert InsufficientAmount();
        if (tokenAmount > soldTokens) revert InsufficientBalance();

        // Calculate refund using bonding curve
        uint256 refundBeforeFee = _calculateCost(
            soldTokens - tokenAmount,
            soldTokens
        );

        // Calculate fee
        uint256 fee = (refundBeforeFee * SELL_FEE_RATE) / FEE_DENOMINATOR;

        // Net refund after fee
        refund = refundBeforeFee - fee;

        // Check slippage
        if (refund < minRefund) revert SlippageExceeded();

        // Check contract has enough USDC
        if (usdcBalance < refundBeforeFee) revert InsufficientUSDC();

        // Transfer tokens from user back to contract (not burn)
        IERC20(tokenAddress).safeTransferFrom(
            msg.sender,
            address(this),
            tokenAmount
        );

        // Update state
        usdcBalance -= refundBeforeFee;
        soldTokens -= tokenAmount;

        // Transfer fee to protocol treasury
        IERC20(usdcToken).safeTransfer(protocolTreasury, fee);

        // Transfer refund to user
        IERC20(usdcToken).safeTransfer(msg.sender, refund);

        // Get new price
        uint256 newPrice = getCurrentPrice();

        emit TokensSold(
            msg.sender,
            tokenAmount,
            refundBeforeFee,
            fee,
            newPrice,
            block.timestamp
        );
    }

    /**
     * @notice Trigger refund process if IDO failed
     * @dev Can be called by anyone after expiry if target not met
     */
    function triggerRefund() external {
        if (status != Status.Active) revert NotActive();
        if (block.timestamp <= endTime) revert NotExpired();

        // Check if minimum raise ratio was not met
        uint256 minTokensRequired = (targetTokens * minRaiseRatio) /
            FEE_DENOMINATOR;
        if (soldTokens >= minTokensRequired) revert CannotReachTarget();

        // Update status
        status = Status.Failed;

        // Calculate refund rate
        if (soldTokens > 0) {
            refundRate = usdcBalance / soldTokens;
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
        return _calculatePrice(soldTokens);
    }

    /**
     * @notice Calculate cost to buy tokens
     * @param tokenAmount Amount of tokens to buy (18 decimals)
     * @return cost USDC cost in 18 decimals (including 0.3% fee)
     * @dev Returns 18 decimal precision for accurate frontend display
     */
    function calculateCost(
        uint256 tokenAmount
    ) external view returns (uint256 cost) {
        uint256 costWithoutFee = _calculateCost(
            soldTokens,
            soldTokens + tokenAmount
        );
        uint256 fee = (costWithoutFee * BUY_FEE_RATE) / FEE_DENOMINATOR;
        cost = costWithoutFee + fee;
    }

    /**
     * @notice Calculate refund for selling tokens
     * @param tokenAmount Amount of tokens to sell (18 decimals)
     * @return refund USDC refund in 18 decimals (after 0.5% fee)
     * @dev Returns 18 decimal precision for accurate frontend display
     */
    function calculateRefund(
        uint256 tokenAmount
    ) external view returns (uint256 refund) {
        if (tokenAmount > soldTokens) return 0;
        uint256 refundBeforeFee = _calculateCost(
            soldTokens - tokenAmount,
            soldTokens
        );
        uint256 fee = (refundBeforeFee * SELL_FEE_RATE) / FEE_DENOMINATOR;
        refund = refundBeforeFee - fee;
    }

    /**
     * @notice Get IDO progress information
     * @return sold Tokens sold
     * @return target Target tokens
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
        target = targetTokens;
        percentage = targetTokens > 0
            ? (soldTokens * FEE_DENOMINATOR) / targetTokens
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
            uint256 refundBeforeFee = _calculateCost(
                soldTokens - tokenBalance,
                soldTokens
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
     * @notice Calculate price at a given sold amount using square-root bonding curve
     * @dev P(s) = P0 + k * sqrt(s / S_sale)
     *      where k is scaled by 1e6 (represents USD value with 6 decimals)
     *      Example: k=9e6 means price growth coefficient of 9 USD
     * @param s Sold tokens amount
     * @return price Price in USDC (6 decimals)
     */
    function _calculatePrice(uint256 s) internal view returns (uint256 price) {
        if (salableTokens == 0) return initialPrice;

        // Calculate sqrt(s / S_sale) with scaling
        // We use 1e18 scaling for precision
        uint256 ratio = (s * 1e18) / salableTokens;
        uint256 sqrtRatio = _sqrt(ratio);

        // P(s) = P0 + k * sqrt(s / S_sale)
        // k is scaled by 1e6 (USD with 6 decimals)
        // sqrtRatio max value is 1e9 (when s = salableTokens, ratio = 1e18, sqrt = 1e9)
        // Result: (1e6 * 1e9) / 1e9 = 1e6 (6 decimals)
        price = initialPrice + (k * sqrtRatio) / 1e9;
    }

    /**
     * @notice Calculate cost between two points on bonding curve (integral)
     * @dev Simplified integral calculation for square-root curve
     * @param s1 Start sold amount (18 decimals)
     * @param s2 End sold amount (18 decimals)
     * @return cost Cost in 18 decimals (NOT 6 decimals!)
     *
     * CRITICAL: This function returns 18 decimals for precision, not USDC's 6 decimals.
     * The return value must be converted when actually transferring USDC.
     *
     * Decimal precision breakdown:
     * - initialPrice: 6 decimals stored, treated as 18 decimals in calculations
     * - linearCost: (6 + 18) / 1e18 = 6 decimals, then scaled to 18 decimals
     * - sqrtCost: (18 + 9 + 18) / (1e18 * 1e9) = 18 decimals
     * - Final result: 18 decimals
     */
    function _calculateCost(
        uint256 s1,
        uint256 s2
    ) internal view returns (uint256 cost) {
        if (s2 <= s1) return 0;

        // Linear term: P0 * (s2 - s1) / 1e18
        // Result: 6 decimals (initialPrice) + 18 decimals (s2-s1) - 18 = 6 decimals
        uint256 linearCost = (initialPrice * (s2 - s1)) / 1e18;

        // Square-root integral term (bonding curve growth)
        // Formula: k * sqrt(avgSold / S_sale) * (s2 - s1)
        // We need to scale this to match USDC's 6 decimals
        uint256 avgSold = (s1 + s2) / 2;
        uint256 sqrtAvg = _sqrt((avgSold * 1e18) / salableTokens); // Result: 9 decimals

        // sqrtCost calculation:
        // - k: 6 decimals (USD with 6 decimals, e.g., 9e6 = 9 USD)
        // - sqrtAvg: varies based on ratio (sqrt output)
        // - (s2 - s1): 18 decimals (tokens)
        // Total: 6 + 9 + 18 = 33 decimals
        // We want 6 decimals output, so divide by 1e27 (33 - 6 = 27)
        uint256 sqrtCost = (k * sqrtAvg * (s2 - s1)) / (1e18 * 1e9);

        // Now both linearCost and sqrtCost are in 6 decimals (USDC units)
        cost = linearCost + sqrtCost;
    }

    /**
     * @notice Execute IDO launch process
     * @dev Called automatically when target is reached
     */
    function _launch() internal {
        // Update status
        status = Status.Launched;
        launchTime = block.timestamp;

        // Calculate fund allocation
        uint256 lpFunds = (usdcBalance * betaLP) / FEE_DENOMINATOR;
        uint256 projectFunds = usdcBalance - lpFunds;

        // Transfer project funds to DAO Treasury
        if (projectFunds > 0) {
            IERC20(usdcToken).safeTransfer(daoTreasury, projectFunds);
        }

        // TODO: MVP - Uniswap LP creation and locking
        // For MVP, we'll skip actual Uniswap integration
        // In production:
        // 1. Create Uniswap V3 pool
        // 2. Add liquidity with lpFunds USDC and project tokens
        // 3. Transfer LP tokens to RentalManager for locking

        // Unfreeze tokens
        DatasetToken(tokenAddress).unfreeze();

        uint256 finalPrice = getCurrentPrice();

        emit IDOLaunched(
            finalPrice,
            usdcBalance,
            lpFunds,
            projectFunds,
            0,
            block.timestamp
        );
    }

    /**
     * @notice Calculate square root using Babylonian method
     * @param x Value to calculate square root of (scaled by 1e18)
     * @return y Square root (scaled by 1e9)
     */
    function _sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;

        uint256 z = (x + 1) / 2;
        y = x;

        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }
}

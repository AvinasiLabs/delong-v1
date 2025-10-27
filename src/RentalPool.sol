// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title RentalPool
 * @notice Manages dividend distribution for dataset token holders using Accumulated Rewards algorithm
 * @dev Implements the standard DeFi dividend distribution pattern (used by Uniswap, Compound, SushiSwap)
 *      Key features:
 *      - O(1) time complexity for adding revenue
 *      - Users claim dividends themselves (gas paid by beneficiary)
 *      - beforeBalanceChange/afterBalanceChange hooks prevent dividend loss during transfers
 *      - RewardDebt mechanism prevents double-claiming
 */
contract RentalPool is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ========== Initialization Guard ==========

    /// @notice Prevents reinitialization
    bool private _initialized;

    // ========== State Variables ==========

    /// @notice USDC token contract
    IERC20 public usdc;

    /// @notice Associated dataset token contract
    address public datasetToken;

    /// @notice Precision multiplier for calculations (1e18)
    uint256 public constant PRECISION = 1e18;

    /// @notice Accumulated revenue per token (scaled by PRECISION)
    uint256 public accRevenuePerToken;

    /// @notice User's reward debt (prevents double-claiming)
    mapping(address => uint256) public rewardDebt;

    /// @notice User's pending claim (accumulated during transfers)
    mapping(address => uint256) public pendingClaim;

    /// @notice Total revenue added to the pool
    uint256 public totalRevenue;

    /// @notice Total dividends claimed by all users
    uint256 public totalClaimed;

    /// @notice Mapping of total claimed per user
    mapping(address => uint256) public userTotalClaimed;

    /// @notice Authorized rental managers that can add revenue
    mapping(address => bool) public authorizedManagers;

    // ========== Events ==========

    /**
     * @notice Emitted when revenue is added to the pool
     * @param amount Revenue amount added (USDC)
     * @param accRevenuePerToken New accumulated revenue per token
     */
    event RevenueAdded(uint256 amount, uint256 accRevenuePerToken);

    /**
     * @notice Emitted when user claims dividends
     * @param user User address
     * @param amount Dividend amount claimed (USDC)
     */
    event DividendsClaimed(address indexed user, uint256 amount);

    /**
     * @notice Emitted when manager authorization changes
     * @param manager Manager address
     * @param authorized Authorization status
     */
    event ManagerAuthorizationChanged(address indexed manager, bool authorized);

    // ========== Errors ==========

    error ZeroAddress();
    error ZeroAmount();
    error Unauthorized();
    error NoSupply();
    error NoPendingDividends();
    error InsufficientBalance();
    error AlreadyInitialized();

    // ========== Constructor (for implementation contract) ==========

    constructor() Ownable(msg.sender) {}

    // ========== Initializer ==========

    /**
     * @notice Initializes the cloned RentalPool
     * @param usdc_ USDC token address
     * @param datasetToken_ Dataset token address
     * @param initialOwner_ Initial owner address (usually Factory)
     */
    function initialize(
        address usdc_,
        address datasetToken_,
        address initialOwner_
    ) external {
        if (_initialized) revert AlreadyInitialized();
        _initialized = true;

        if (usdc_ == address(0) || datasetToken_ == address(0))
            revert ZeroAddress();

        _transferOwnership(initialOwner_);
        usdc = IERC20(usdc_);
        datasetToken = datasetToken_;
    }

    // ========== External Functions ==========

    /**
     * @notice Adds revenue to the pool and updates accumulated rewards
     * @dev Can only be called by authorized rental managers
     *      Uses Accumulated Rewards algorithm: accRevenuePerToken += (amount * PRECISION) / totalSupply
     * @param amount Revenue amount to add (USDC, 95% of rental payment after protocol fee)
     */
    function addRevenue(uint256 amount) external {
        if (!authorizedManagers[msg.sender]) revert Unauthorized();
        if (amount == 0) revert ZeroAmount();

        // Get total supply of dataset tokens
        uint256 totalSupply = IERC20(datasetToken).totalSupply();
        if (totalSupply == 0) revert NoSupply();

        // Calculate revenue per token
        uint256 revenuePerToken = (amount * PRECISION) / totalSupply;

        // Update accumulated revenue per token
        accRevenuePerToken += revenuePerToken;

        // Update total revenue
        totalRevenue += amount;

        // Transfer USDC from caller (RentalManager) to this contract
        usdc.safeTransferFrom(msg.sender, address(this), amount);

        emit RevenueAdded(amount, accRevenuePerToken);
    }

    /**
     * @notice Claims all pending dividends for the caller
     * @dev User pays gas for claiming. Combines pendingClaim with newly accumulated rewards.
     * @return amount Amount of USDC claimed
     */
    function claimDividends() external nonReentrant returns (uint256 amount) {
        address user = msg.sender;

        // Get user's token balance
        uint256 balance = IERC20(datasetToken).balanceOf(user);

        // Calculate pending dividends
        uint256 accumulated = (balance * accRevenuePerToken) / PRECISION;
        uint256 pending = accumulated - rewardDebt[user] + pendingClaim[user];

        if (pending == 0) revert NoPendingDividends();

        // Clear pending claim
        pendingClaim[user] = 0;

        // Update reward debt
        rewardDebt[user] = accumulated;

        // Update statistics
        totalClaimed += pending;
        userTotalClaimed[user] += pending;

        // Transfer USDC to user
        usdc.safeTransfer(user, pending);

        emit DividendsClaimed(user, pending);

        amount = pending;
    }

    /**
     * @notice Hook called before token balance changes
     * @dev Called by DatasetToken's _update function to save pending dividends
     *      Prevents dividend loss during transfers
     * @param user User whose balance is changing
     * @param oldBalance User's balance before the change
     */
    function beforeBalanceChange(address user, uint256 oldBalance) external {
        if (msg.sender != datasetToken) revert Unauthorized();

        // Calculate accumulated rewards based on old balance
        uint256 accumulated = (oldBalance * accRevenuePerToken) / PRECISION;

        // Calculate pending rewards
        uint256 pending = accumulated - rewardDebt[user];

        // Add to pending claim if there are pending rewards
        if (pending > 0) {
            pendingClaim[user] += pending;
        }
    }

    /**
     * @notice Hook called after token balance changes
     * @dev Called by DatasetToken's _update function to update reward debt
     *      Ensures user can only claim future rewards based on new balance
     * @param user User whose balance changed
     * @param newBalance User's new balance after the change
     */
    function afterBalanceChange(address user, uint256 newBalance) external {
        if (msg.sender != datasetToken) revert Unauthorized();

        // Update reward debt based on new balance
        rewardDebt[user] = (newBalance * accRevenuePerToken) / PRECISION;
    }

    // ========== View Functions ==========

    /**
     * @notice Gets user's pending dividends (ready to claim)
     * @param user User address
     * @return pending Pending dividend amount in USDC
     */
    function getPendingDividends(
        address user
    ) external view returns (uint256 pending) {
        uint256 balance = IERC20(datasetToken).balanceOf(user);
        uint256 accumulated = (balance * accRevenuePerToken) / PRECISION;
        pending = accumulated - rewardDebt[user] + pendingClaim[user];
    }

    /**
     * @notice Gets total revenue in the pool
     * @return Total revenue amount
     */
    function getTotalRevenue() external view returns (uint256) {
        return totalRevenue;
    }

    /**
     * @notice Gets total amount claimed by a user
     * @param user User address
     * @return Total claimed amount
     */
    function getUserTotalClaimed(address user) external view returns (uint256) {
        return userTotalClaimed[user];
    }

    /**
     * @notice Gets contract's USDC balance
     * @return USDC balance of this contract
     */
    function getContractBalance() external view returns (uint256) {
        return usdc.balanceOf(address(this));
    }

    // ========== Admin Functions ==========

    /**
     * @notice Authorizes or deauthorizes a rental manager
     * @dev Only owner can call this
     * @param manager Manager address
     * @param authorized Authorization status
     */
    function setAuthorizedManager(
        address manager,
        bool authorized
    ) external onlyOwner {
        if (manager == address(0)) revert ZeroAddress();

        authorizedManagers[manager] = authorized;

        emit ManagerAuthorizationChanged(manager, authorized);
    }
}

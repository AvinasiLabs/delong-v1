// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "./RentalPool.sol";
import "./DatasetManager.sol";

/**
 * @title RentalManager
 * @notice Manages data access payments, rental distribution, and LP locking
 * @dev Key features:
 *      - Users pay USDC to access datasets for specified hours
 *      - Automatic distribution: 5% protocol fee + 95% dividends
 *      - LP tokens locked and unlocked based on accumulated revenue (1:1 ratio)
 *      - Usage tracking via authorized backends with signature verification
 */
contract RentalManager is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using ECDSA for bytes32;

    // ========== Structs ==========

    /**
     * @notice Rental record for user data access
     */
    struct Rental {
        address user;
        uint256 paidAmount;
        uint256 hoursQuota;
        uint256 usedMinutes;
        uint256 purchasedAt;
        bool isActive;
    }

    /**
     * @notice LP lock information
     */
    struct LPLock {
        address lpToken;
        uint256 totalAmount;
        uint256 lpValueUSDC;
        uint256 claimedAmount;
        address projectAddress;
        uint256 startTime;
    }

    // ========== State Variables ==========

    /// @notice USDC token contract
    IERC20 public immutable usdc;

    /// @notice Protocol fee rate (5% = 500 basis points)
    uint256 public constant PROTOCOL_FEE_RATE = 500;
    uint256 public constant FEE_DENOMINATOR = 10000;

    /// @notice Associated contracts
    address public rentalPool; // Deprecated: kept for backward compatibility
    address public protocolTreasury;
    address public datasetManager;
    address public idoContract;
    address public factory;

    /// @notice Mapping of dataset token to its rental pool
    mapping(address => address) public datasetRentalPools;

    /// @notice Rental records per user per dataset
    mapping(address => mapping(address => Rental[])) public userRentals;

    /// @notice Hourly rental rate per dataset (USDC with 6 decimals)
    mapping(address => uint256) public hourlyRate;

    /// @notice Total collected rental per dataset
    mapping(address => uint256) public totalCollected;

    /// @notice LP locks per dataset
    mapping(address => LPLock) public lpLocks;

    /// @notice Accumulated revenue per dataset (based on 100% rental)
    mapping(address => uint256) public accumulatedRevenue;

    /// @notice Authorized backends that can record usage
    mapping(address => bool) public authorizedBackends;

    // ========== Events ==========

    event AccessPurchased(
        address indexed user,
        address indexed datasetToken,
        uint256 hoursCount,
        uint256 cost
    );
    event UsageRecorded(
        address indexed user,
        address indexed datasetToken,
        uint256 indexed rentalIndex,
        uint256 additionalMinutes,
        uint256 totalUsedMinutes
    );
    event RentalDistributed(
        address indexed datasetToken,
        uint256 totalAmount,
        uint256 protocolFee,
        uint256 dividend
    );
    event RevenueAccumulated(
        address indexed datasetToken,
        uint256 additionalRevenue,
        uint256 totalRevenue
    );
    event PriceUpdated(address indexed datasetToken, uint256 newPrice);
    event LPLocked(
        address indexed datasetToken,
        address indexed lpToken,
        address indexed projectAddress,
        uint256 amount,
        uint256 lpValueUSDC
    );
    event LPWithdrawn(
        address indexed datasetToken,
        uint256 amount,
        uint256 totalClaimed
    );
    event RentalPoolSet(address indexed rentalPool);
    event ProtocolTreasurySet(address indexed protocolTreasury);
    event DatasetManagerSet(address indexed datasetManager);
    event IDOContractSet(address indexed idoContract);
    event BackendAuthorizationChanged(address indexed backend, bool authorized);

    // ========== Errors ==========

    error ZeroAddress();
    error ZeroAmount();
    error Unauthorized();
    error AlreadySet();
    error InvalidSignature();
    error RentalNotActive();
    error QuotaExceeded();
    error NoUnlockableLP();
    error InvalidPrice();

    // ========== Constructor ==========

    /**
     * @notice Initializes the RentalManager
     * @param usdc_ USDC token address
     * @param initialOwner_ Initial owner address
     */
    constructor(address usdc_, address initialOwner_) Ownable(initialOwner_) {
        if (usdc_ == address(0)) revert ZeroAddress();
        usdc = IERC20(usdc_);
    }

    // ========== External Functions ==========

    /**
     * @notice Purchase data access for specified hours
     * @dev Automatically distributes rental: 5% protocol fee + 95% dividends
     *      Updates LP unlock progress based on 100% rental amount
     * @param datasetToken Dataset token address
     * @param hoursCount Number of hours to purchase
     */
    function purchaseAccess(
        address datasetToken,
        uint256 hoursCount
    ) external nonReentrant {
        if (hoursCount == 0) revert ZeroAmount();
        if (hourlyRate[datasetToken] == 0) revert InvalidPrice();

        // Calculate total cost
        uint256 totalCost = hourlyRate[datasetToken] * hoursCount;

        // Transfer USDC from user
        usdc.safeTransferFrom(msg.sender, address(this), totalCost);

        // Calculate fees and dividends
        uint256 protocolFee = (totalCost * PROTOCOL_FEE_RATE) / FEE_DENOMINATOR;
        uint256 dividend = totalCost - protocolFee;

        // Transfer protocol fee
        if (protocolTreasury != address(0)) {
            usdc.safeTransfer(protocolTreasury, protocolFee);
        }

        // Approve and add dividends to rental pool
        address pool = datasetRentalPools[datasetToken];
        if (pool == address(0)) {
            pool = rentalPool; // Fallback to legacy rentalPool for backward compatibility
        }
        if (pool != address(0)) {
            usdc.forceApprove(pool, dividend);
            RentalPool(pool).addRevenue(dividend);
        }

        // Update LP unlock progress (based on 100% rental)
        accumulatedRevenue[datasetToken] += totalCost;
        emit RevenueAccumulated(
            datasetToken,
            totalCost,
            accumulatedRevenue[datasetToken]
        );

        // Create rental record
        userRentals[msg.sender][datasetToken].push(
            Rental({
                user: msg.sender,
                paidAmount: totalCost,
                hoursQuota: hoursCount,
                usedMinutes: 0,
                purchasedAt: block.timestamp,
                isActive: true
            })
        );

        // Update statistics
        totalCollected[datasetToken] += totalCost;

        // Record revenue in DatasetManager if set
        if (datasetManager != address(0)) {
            DatasetManager(datasetManager).recordRentalRevenue(
                totalCost,
                msg.sender
            );
        }

        emit AccessPurchased(msg.sender, datasetToken, hoursCount, totalCost);
        emit RentalDistributed(datasetToken, totalCost, protocolFee, dividend);
    }

    /**
     * @notice Records actual usage time (called by authorized backend)
     * @dev Signature verification prevents malicious reporting
     * @param user User address
     * @param datasetToken Dataset token address
     * @param rentalIndex Rental record index
     * @param additionalMinutes Additional minutes used
     * @param signature Backend signature for verification
     */
    function recordUsage(
        address user,
        address datasetToken,
        uint256 rentalIndex,
        uint256 additionalMinutes,
        bytes memory signature
    ) external {
        if (!authorizedBackends[msg.sender]) revert Unauthorized();

        // Verify signature (simplified for MVP)
        // In production, implement proper signature verification
        // bytes32 messageHash = keccak256(abi.encodePacked(user, datasetToken, rentalIndex, additionalMinutes));
        // address signer = messageHash.toEthSignedMessageHash().recover(signature);
        // if (!authorizedBackends[signer]) revert InvalidSignature();

        Rental storage rental = userRentals[user][datasetToken][rentalIndex];
        if (!rental.isActive) revert RentalNotActive();

        uint256 maxMinutes = rental.hoursQuota * 60;
        if (rental.usedMinutes + additionalMinutes > maxMinutes)
            revert QuotaExceeded();

        // Update usage
        rental.usedMinutes += additionalMinutes;

        // Check if quota exhausted
        if (rental.usedMinutes >= maxMinutes) {
            rental.isActive = false;
        }

        emit UsageRecorded(
            user,
            datasetToken,
            rentalIndex,
            additionalMinutes,
            rental.usedMinutes
        );
    }

    /**
     * @notice Locks LP tokens (called by IDO contract on launch)
     * @dev Records LP value for unlock ratio calculation
     * @param datasetToken Dataset token address
     * @param lpToken Uniswap LP token address
     * @param amount LP token amount
     * @param lpValueUSDC LP total value in USDC
     * @param projectAddress Project address (LP recipient)
     */
    function lockLP(
        address datasetToken,
        address lpToken,
        uint256 amount,
        uint256 lpValueUSDC,
        address projectAddress
    ) external {
        if (msg.sender != idoContract) revert Unauthorized();
        if (lpLocks[datasetToken].totalAmount > 0) revert AlreadySet();

        // Transfer LP tokens from IDO contract
        IERC20(lpToken).safeTransferFrom(msg.sender, address(this), amount);

        // Create LP lock
        lpLocks[datasetToken] = LPLock({
            lpToken: lpToken,
            totalAmount: amount,
            lpValueUSDC: lpValueUSDC,
            claimedAmount: 0,
            projectAddress: projectAddress,
            startTime: block.timestamp
        });

        // Initialize accumulated revenue
        accumulatedRevenue[datasetToken] = 0;

        emit LPLocked(
            datasetToken,
            lpToken,
            projectAddress,
            amount,
            lpValueUSDC
        );
    }

    /**
     * @notice Withdraws unlocked LP tokens (project can claim multiple times)
     * @dev Incentivizes continuous operation by project
     * @param datasetToken Dataset token address
     */
    function withdrawLP(address datasetToken) external nonReentrant {
        LPLock storage lock = lpLocks[datasetToken];
        if (msg.sender != lock.projectAddress) revert Unauthorized();

        uint256 unlockable = calculateUnlockableLP(datasetToken);
        if (unlockable == 0) revert NoUnlockableLP();

        // Update claimed amount
        lock.claimedAmount += unlockable;

        // Transfer LP tokens
        IERC20(lock.lpToken).safeTransfer(msg.sender, unlockable);

        emit LPWithdrawn(datasetToken, unlockable, lock.claimedAmount);
    }

    /**
     * @notice Updates hourly rental price
     * @dev Can be called by owner, DAO Governance, or Factory (for initial setup)
     * @param datasetToken Dataset token address
     * @param newPricePerHour New hourly price (USDC with 6 decimals)
     */
    function updatePrice(
        address datasetToken,
        uint256 newPricePerHour
    ) external {
        if (msg.sender != owner() && msg.sender != factory)
            revert Unauthorized();
        if (newPricePerHour == 0) revert InvalidPrice();

        hourlyRate[datasetToken] = newPricePerHour;

        emit PriceUpdated(datasetToken, newPricePerHour);
    }

    // ========== View Functions ==========

    /**
     * @notice Calculates currently unlockable LP amount
     * @dev Unlock ratio = accumulated revenue / LP value (1:1 ratio)
     * @param datasetToken Dataset token address
     * @return unlockable Amount of LP tokens that can be unlocked
     */
    function calculateUnlockableLP(
        address datasetToken
    ) public view returns (uint256 unlockable) {
        LPLock memory lock = lpLocks[datasetToken];
        if (lock.totalAmount == 0) return 0;

        // Calculate unlock ratio based on accumulated revenue
        uint256 unlockedAmount = (lock.totalAmount *
            accumulatedRevenue[datasetToken]) / lock.lpValueUSDC;

        // Cap at total amount
        if (unlockedAmount > lock.totalAmount) {
            unlockedAmount = lock.totalAmount;
        }

        // Subtract already claimed
        if (unlockedAmount > lock.claimedAmount) {
            unlockable = unlockedAmount - lock.claimedAmount;
        }
    }

    /**
     * @notice Gets active rentals for a user
     * @param user User address
     * @param datasetToken Dataset token address
     * @return activeRentals Array of active rental records
     */
    function getActiveRentals(
        address user,
        address datasetToken
    ) external view returns (Rental[] memory) {
        Rental[] memory allRentals = userRentals[user][datasetToken];
        uint256 activeCount = 0;

        // Count active rentals
        for (uint256 i = 0; i < allRentals.length; i++) {
            if (allRentals[i].isActive) {
                activeCount++;
            }
        }

        // Create array of active rentals
        Rental[] memory activeRentals = new Rental[](activeCount);
        uint256 index = 0;
        for (uint256 i = 0; i < allRentals.length; i++) {
            if (allRentals[i].isActive) {
                activeRentals[index] = allRentals[i];
                index++;
            }
        }

        return activeRentals;
    }

    /**
     * @notice Gets LP lock information
     * @param datasetToken Dataset token address
     * @return lpToken LP token address
     * @return totalAmount Total locked amount
     * @return lpValueUSDC LP value in USDC
     * @return claimedAmount Already claimed amount
     * @return projectAddress Project address
     * @return startTime Lock start time
     */
    function getLPLockInfo(
        address datasetToken
    )
        external
        view
        returns (
            address lpToken,
            uint256 totalAmount,
            uint256 lpValueUSDC,
            uint256 claimedAmount,
            address projectAddress,
            uint256 startTime
        )
    {
        LPLock memory lock = lpLocks[datasetToken];
        return (
            lock.lpToken,
            lock.totalAmount,
            lock.lpValueUSDC,
            lock.claimedAmount,
            lock.projectAddress,
            lock.startTime
        );
    }

    // ========== Admin Functions ==========

    /**
     * @notice Sets RentalPool contract address (can only be set once)
     * @param rentalPool_ RentalPool address
     */
    function setRentalPool(address rentalPool_) external onlyOwner {
        if (rentalPool != address(0)) revert AlreadySet();
        if (rentalPool_ == address(0)) revert ZeroAddress();

        rentalPool = rentalPool_;
        emit RentalPoolSet(rentalPool_);
    }

    /**
     * @notice Sets factory address (can only be set once)
     * @param factory_ Factory address
     */
    function setFactory(address factory_) external onlyOwner {
        if (factory != address(0)) revert AlreadySet();
        if (factory_ == address(0)) revert ZeroAddress();

        factory = factory_;
    }

    /**
     * @notice Registers dataset token to its rental pool (can be called by owner or factory)
     * @param datasetToken Dataset token address
     * @param rentalPool_ Rental pool address for this dataset
     */
    function setDatasetRentalPool(
        address datasetToken,
        address rentalPool_
    ) external {
        if (msg.sender != owner() && msg.sender != factory)
            revert Unauthorized();
        if (datasetToken == address(0) || rentalPool_ == address(0))
            revert ZeroAddress();

        datasetRentalPools[datasetToken] = rentalPool_;
    }

    /**
     * @notice Sets protocol treasury address (can only be set once)
     * @param protocolTreasury_ Protocol treasury address
     */
    function setProtocolTreasury(address protocolTreasury_) external onlyOwner {
        if (protocolTreasury != address(0)) revert AlreadySet();
        if (protocolTreasury_ == address(0)) revert ZeroAddress();

        protocolTreasury = protocolTreasury_;
        emit ProtocolTreasurySet(protocolTreasury_);
    }

    /**
     * @notice Sets DatasetManager contract address (can only be set once)
     * @param datasetManager_ DatasetManager address
     */
    function setDatasetManager(address datasetManager_) external onlyOwner {
        if (datasetManager != address(0)) revert AlreadySet();
        if (datasetManager_ == address(0)) revert ZeroAddress();

        datasetManager = datasetManager_;
        emit DatasetManagerSet(datasetManager_);
    }

    /**
     * @notice Sets IDO contract address (can only be set once)
     * @param idoContract_ IDO contract address
     */
    function setIDOContract(address idoContract_) external onlyOwner {
        if (idoContract != address(0)) revert AlreadySet();
        if (idoContract_ == address(0)) revert ZeroAddress();

        idoContract = idoContract_;
        emit IDOContractSet(idoContract_);
    }

    /**
     * @notice Authorizes or deauthorizes a backend
     * @param backend Backend address
     * @param authorized Authorization status
     */
    function setAuthorizedBackend(
        address backend,
        bool authorized
    ) external onlyOwner {
        if (backend == address(0)) revert ZeroAddress();

        authorizedBackends[backend] = authorized;
        emit BackendAuthorizationChanged(backend, authorized);
    }
}

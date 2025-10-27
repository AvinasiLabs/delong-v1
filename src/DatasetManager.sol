// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title DatasetManager
 * @notice Manages dataset metadata, trial credentials, access rights, and statistics
 * @dev Decouples business logic from DatasetToken, enabling upgradability without token migration
 *      Works with TEE Backend for trial access control and usage tracking
 */
contract DatasetManager is Ownable {
    // ========== Initialization Guard ==========

    /// @notice Prevents reinitialization
    bool private _initialized;

    // ========== Associated Contracts ==========

    /// @notice Address of the associated DatasetToken contract
    address public datasetToken;

    /// @notice Address of the project owner (multisig wallet)
    address public projectAddress;

    /// @notice Address of the RentalManager contract
    address public rentalManager;

    /// @notice Address of the authorized TEE Backend for recording trial usage
    address public teeBackend;

    /// @notice Address of the DAO Governance contract
    address public daoGovernance;

    // ========== Metadata Management ==========

    /// @notice Current version of dataset metadata IPFS URI
    string public datasetMetadataURI;

    /// @notice Historical versions of metadata URIs
    string[] public metadataVersionHistory;

    // ========== Dataset Status ==========

    /// @notice Lifecycle status of the dataset
    enum DatasetStatus {
        Active,
        Deprecated,
        Delisted
    }

    /// @notice Current status of the dataset
    DatasetStatus public status;

    /// @notice Timestamp of last status update
    uint256 public statusUpdatedAt;

    // ========== Trial Credential System ==========

    /// @notice Fixed trial quota for token holders (2 hours in seconds)
    uint256 public constant TRIAL_QUOTA = 2 hours;

    /// @notice Mapping of user address to trial time used (in seconds)
    mapping(address => uint256) public trialUsed;

    /// @notice Mapping of user address to first trial start time
    mapping(address => uint256) public trialStartedAt;

    // ========== Statistics ==========

    /// @notice Cumulative rental revenue in USDC
    uint256 public totalRentalRevenue;

    /// @notice Total number of unique users who used the dataset
    uint256 public totalUniqueUsers;

    /// @notice Mapping of whether a user has used the dataset
    mapping(address => bool) public hasUsedDataset;

    /// @notice Total number of users who have started trial
    uint256 public totalTrialUsers;

    /// @notice Timestamp when this contract was created
    uint256 public createdAt;

    // ========== Events ==========

    /**
     * @notice Emitted when metadata is updated
     * @param oldURI Previous metadata URI
     * @param newURI New metadata URI
     * @param version Version number (array index)
     * @param timestamp Update timestamp
     */
    event MetadataUpdated(
        string oldURI,
        string newURI,
        uint256 version,
        uint256 timestamp
    );

    /**
     * @notice Emitted when trial usage is recorded
     * @param user User address
     * @param usedSeconds Seconds used in this session
     * @param totalUsed Total seconds used by user
     */
    event TrialUsageRecorded(
        address indexed user,
        uint256 usedSeconds,
        uint256 totalUsed
    );

    /**
     * @notice Emitted when user's trial quota is exhausted
     * @param user User address
     * @param timestamp Exhaustion timestamp
     */
    event TrialQuotaExhausted(address indexed user, uint256 timestamp);

    /**
     * @notice Emitted when dataset status is updated
     * @param oldStatus Previous status
     * @param newStatus New status
     * @param timestamp Update timestamp
     */
    event StatusUpdated(
        DatasetStatus oldStatus,
        DatasetStatus newStatus,
        uint256 timestamp
    );

    /**
     * @notice Emitted when rental revenue is recorded
     * @param user User who paid rental
     * @param amount Rental amount in USDC
     * @param totalRevenue Cumulative total revenue
     */
    event RentalRevenueRecorded(
        address indexed user,
        uint256 amount,
        uint256 totalRevenue
    );

    /**
     * @notice Emitted when RentalManager address is set
     * @param rentalManager Address of RentalManager contract
     */
    event RentalManagerSet(address indexed rentalManager);

    /**
     * @notice Emitted when TEE Backend address is set
     * @param teeBackend Address of TEE Backend
     */
    event TeeBackendSet(address indexed teeBackend);

    /**
     * @notice Emitted when DAO Governance address is set
     * @param daoGovernance Address of DAO Governance contract
     */
    event DaoGovernanceSet(address indexed daoGovernance);

    // ========== Errors ==========

    error ZeroAddress();
    error OnlyProjectAddress();
    error OnlyRentalManager();
    error OnlyTeeBackend();
    error OnlyDaoGovernance();
    error EmptyString();
    error AlreadySet();
    error InvalidAmount();
    error TrialQuotaExceeded();
    error AlreadyInitialized();

    // ========== Constructor (for implementation contract) ==========

    constructor() Ownable(msg.sender) {}

    // ========== Initializer ==========

    /**
     * @notice Initializes the cloned DatasetManager
     * @param datasetToken_ Address of the associated DatasetToken
     * @param projectAddress_ Address of the project owner
     * @param initialOwner_ Initial owner of this contract (usually Factory)
     * @param metadataURI_ Initial IPFS URI of dataset metadata
     */
    function initialize(
        address datasetToken_,
        address projectAddress_,
        address initialOwner_,
        string memory metadataURI_
    ) external {
        if (_initialized) revert AlreadyInitialized();
        _initialized = true;

        if (datasetToken_ == address(0) || projectAddress_ == address(0))
            revert ZeroAddress();
        if (bytes(metadataURI_).length == 0) revert EmptyString();

        _transferOwnership(initialOwner_);
        datasetToken = datasetToken_;
        projectAddress = projectAddress_;
        datasetMetadataURI = metadataURI_;
        status = DatasetStatus.Active;
        statusUpdatedAt = block.timestamp;
        createdAt = block.timestamp;

        // Store initial version
        metadataVersionHistory.push(metadataURI_);
    }

    // ========== Configuration Functions ==========

    /**
     * @notice Sets the RentalManager contract address (can only be set once)
     * @param rentalManager_ Address of RentalManager contract
     */
    function setRentalManager(address rentalManager_) external onlyOwner {
        if (rentalManager != address(0)) revert AlreadySet();
        if (rentalManager_ == address(0)) revert ZeroAddress();

        rentalManager = rentalManager_;
        emit RentalManagerSet(rentalManager_);
    }

    /**
     * @notice Sets the TEE Backend address (can only be set once)
     * @param teeBackend_ Address of TEE Backend
     */
    function setTeeBackend(address teeBackend_) external onlyOwner {
        if (teeBackend != address(0)) revert AlreadySet();
        if (teeBackend_ == address(0)) revert ZeroAddress();

        teeBackend = teeBackend_;
        emit TeeBackendSet(teeBackend_);
    }

    /**
     * @notice Sets the DAO Governance contract address (can only be set once)
     * @param daoGovernance_ Address of DAO Governance contract
     */
    function setDaoGovernance(address daoGovernance_) external onlyOwner {
        if (daoGovernance != address(0)) revert AlreadySet();
        if (daoGovernance_ == address(0)) revert ZeroAddress();

        daoGovernance = daoGovernance_;
        emit DaoGovernanceSet(daoGovernance_);
    }

    // ========== Metadata Management ==========

    /**
     * @notice Updates dataset metadata URI
     * @dev Only project address can update metadata. Old version is stored in history.
     * @param newURI New IPFS hash for metadata
     */
    function updateMetadata(string calldata newURI) external {
        if (msg.sender != projectAddress) revert OnlyProjectAddress();
        if (bytes(newURI).length == 0) revert EmptyString();

        string memory oldURI = datasetMetadataURI;
        datasetMetadataURI = newURI;
        metadataVersionHistory.push(newURI);

        emit MetadataUpdated(
            oldURI,
            newURI,
            metadataVersionHistory.length - 1,
            block.timestamp
        );
    }

    /**
     * @notice Returns all metadata version history
     * @return Array of all metadata URIs
     */
    function getMetadataVersionHistory()
        external
        view
        returns (string[] memory)
    {
        return metadataVersionHistory;
    }

    // ========== Trial Credential System ==========

    /**
     * @notice Records trial usage for a user
     * @dev Called by authorized TEE Backend to track usage time
     * @param user User address
     * @param usedSeconds Number of seconds used in this session
     */
    function recordTrialUsage(address user, uint256 usedSeconds) external {
        if (msg.sender != teeBackend) revert OnlyTeeBackend();
        if (usedSeconds == 0) revert InvalidAmount();

        // Record first trial time if this is the first usage
        if (trialStartedAt[user] == 0) {
            trialStartedAt[user] = block.timestamp;
            totalTrialUsers++;
        }

        // Update used time
        uint256 newUsed = trialUsed[user] + usedSeconds;
        if (newUsed > TRIAL_QUOTA) revert TrialQuotaExceeded();

        trialUsed[user] = newUsed;

        emit TrialUsageRecorded(user, usedSeconds, newUsed);

        // Check if quota is exhausted
        if (newUsed >= TRIAL_QUOTA) {
            emit TrialQuotaExhausted(user, block.timestamp);
        }
    }

    /**
     * @notice Checks if user has trial eligibility
     * @dev User must hold tokens to be eligible for trial
     * @param user User address
     * @return bool True if user holds tokens
     */
    function hasTrialEligibility(address user) public view returns (bool) {
        return IERC20(datasetToken).balanceOf(user) > 0;
    }

    /**
     * @notice Gets comprehensive trial information for a user
     * @param user User address
     * @return quota Total trial quota (2 hours)
     * @return used Seconds already used
     * @return remaining Seconds remaining
     * @return eligible Whether user is eligible (holds tokens)
     */
    function getTrialInfo(
        address user
    )
        external
        view
        returns (uint256 quota, uint256 used, uint256 remaining, bool eligible)
    {
        quota = TRIAL_QUOTA;
        used = trialUsed[user];
        remaining = used >= quota ? 0 : quota - used;
        eligible = hasTrialEligibility(user);
    }

    // ========== Access Rights ==========

    /**
     * @notice Checks if user can access dataset
     * @dev User can access if they hold tokens OR have active rental
     *      Note: Rental check requires RentalManager to be set and implement hasActiveRental()
     * @param user User address
     * @return bool True if user has access rights
     */
    function canAccessDataset(address user) external view returns (bool) {
        // Check if user holds tokens
        if (IERC20(datasetToken).balanceOf(user) > 0) {
            return true;
        }

        // TODO: Check if user has active rental (requires RentalManager integration)
        // if (rentalManager != address(0)) {
        //     return IRentalManager(rentalManager).hasActiveRental(datasetToken, user);
        // }

        return false;
    }

    // ========== Status Management ==========

    /**
     * @notice Updates dataset status
     * @dev Project can mark as Deprecated, DAO Governance can mark as Delisted
     * @param newStatus New status for the dataset
     */
    function updateStatus(DatasetStatus newStatus) external {
        DatasetStatus oldStatus = status;

        // Only project address can mark as Deprecated
        if (newStatus == DatasetStatus.Deprecated) {
            if (msg.sender != projectAddress) revert OnlyProjectAddress();
        }

        // Only DAO Governance can mark as Delisted
        if (newStatus == DatasetStatus.Delisted) {
            if (msg.sender != daoGovernance) revert OnlyDaoGovernance();
        }

        status = newStatus;
        statusUpdatedAt = block.timestamp;

        emit StatusUpdated(oldStatus, newStatus, block.timestamp);
    }

    /**
     * @notice Gets current dataset status
     * @return DatasetStatus Current status
     */
    function getStatus() external view returns (DatasetStatus) {
        return status;
    }

    // ========== Revenue and Statistics ==========

    /**
     * @notice Records rental revenue and updates user statistics
     * @dev Called by RentalManager when user pays for rental
     * @param amount Revenue amount in USDC
     * @param user User who paid rental
     */
    function recordRentalRevenue(uint256 amount, address user) external {
        if (msg.sender != rentalManager) revert OnlyRentalManager();
        if (amount == 0) revert InvalidAmount();

        // Track unique users
        if (!hasUsedDataset[user]) {
            hasUsedDataset[user] = true;
            totalUniqueUsers++;
        }

        // Update revenue
        totalRentalRevenue += amount;

        emit RentalRevenueRecorded(user, amount, totalRentalRevenue);
    }

    /**
     * @notice Gets comprehensive statistics for the dataset
     * @return totalRevenue Cumulative rental revenue
     * @return uniqueUsers Number of unique users
     * @return trialUsers Number of users who started trial
     * @return creationTime Contract creation timestamp
     * @return currentStatus Current dataset status
     */
    function getStatistics()
        external
        view
        returns (
            uint256 totalRevenue,
            uint256 uniqueUsers,
            uint256 trialUsers,
            uint256 creationTime,
            DatasetStatus currentStatus
        )
    {
        totalRevenue = totalRentalRevenue;
        uniqueUsers = totalUniqueUsers;
        trialUsers = totalTrialUsers;
        creationTime = createdAt;
        currentStatus = status;
    }
}

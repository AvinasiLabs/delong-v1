// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/proxy/Clones.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./IDO.sol";
import "./DatasetToken.sol";
import "./DatasetManager.sol";
import "./RentalPool.sol";
import "./RentalManager.sol";

/**
 * @title Factory
 * @notice Factory contract for deploying dataset contract suites using EIP-1167
 * @dev Key features:
 *      - Deploys complete contract suite for each dataset
 *      - Uses Minimal Proxy Pattern (EIP-1167) for gas efficiency
 *      - Manages registry of all deployed datasets
 *      - Handles initialization and contract linking
 *      - Collects platform deployment fees
 */
contract Factory is Ownable {
    using Clones for address;

    // ========== Structs ==========

    /**
     * @notice Dataset contract suite
     */
    struct DatasetSuite {
        address ido;
        address datasetToken;
        address datasetManager;
        address rentalPool;
        address projectAddress;
        uint256 createdAt;
        bool exists;
    }

    /**
     * @notice IDO configuration parameters
     */
    struct IDOConfig {
        uint256 alphaProject; // Project reserved ratio (basis points)
        uint256 k; // Price growth coefficient
        uint256 betaLP; // LP lock ratio (basis points)
        uint256 minRaiseRatio; // Minimum raise ratio (basis points)
        uint256 initialPrice; // Initial token price (USDC 6 decimals)
    }

    // ========== State Variables ==========

    /// @notice USDC token address
    address public immutable usdc;

    /// @notice RentalManager contract (shared across all datasets)
    address public rentalManager;

    /// @notice DAOTreasury contract (shared across all datasets)
    address public daoTreasury;

    /// @notice Protocol Treasury address
    address public protocolTreasury;

    /// @notice Platform deployment fee (in USDC)
    uint256 public deploymentFee;

    // ========== Implementation Contracts (for cloning) ==========

    /// @notice IDO implementation contract
    address public idoImplementation;

    /// @notice DatasetToken implementation contract
    address public datasetTokenImplementation;

    /// @notice DatasetManager implementation contract
    address public datasetManagerImplementation;

    /// @notice RentalPool implementation contract
    address public rentalPoolImplementation;

    // ========== Registry ==========

    /// @notice Total datasets deployed
    uint256 public datasetCount;

    /// @notice Mapping of dataset ID to contract suite
    mapping(uint256 => DatasetSuite) public datasets;

    /// @notice Mapping of IDO address to dataset ID
    mapping(address => uint256) public idoToDatasetId;

    /// @notice Mapping of DatasetToken address to dataset ID
    mapping(address => uint256) public tokenToDatasetId;

    /// @notice Array of all dataset IDs
    uint256[] public allDatasetIds;

    // ========== Events ==========

    event DatasetDeployed(
        uint256 indexed datasetId,
        address indexed projectAddress,
        address ido,
        address datasetToken,
        address datasetManager,
        address rentalPool
    );
    event DeploymentFeeUpdated(uint256 oldFee, uint256 newFee);
    event ImplementationUpdated(string contractType, address implementation);
    event RentalManagerSet(address indexed rentalManager);
    event DAOTreasurySet(address indexed daoTreasury);
    event ProtocolTreasurySet(address indexed protocolTreasury);

    // ========== Errors ==========

    error ZeroAddress();
    error AlreadySet();
    error InvalidFee();
    error InsufficientFee();
    error DeploymentFailed();
    error EmptyString();

    // ========== Constructor ==========

    /**
     * @notice Initializes the Factory
     * @param usdc_ USDC token address
     * @param initialOwner_ Initial owner address
     */
    constructor(address usdc_, address initialOwner_) Ownable(initialOwner_) {
        if (usdc_ == address(0)) revert ZeroAddress();
        usdc = usdc_;
        deploymentFee = 100 * 1e6; // Default: 100 USDC
    }

    // ========== External Functions ==========

    /**
     * @notice Deploys a complete contract suite for a new dataset
     * @dev Uses EIP-1167 Minimal Proxy Pattern for gas efficiency
     * @param projectAddress Project owner address (multisig)
     * @param tokenName Dataset token name
     * @param tokenSymbol Dataset token symbol
     * @param metadataURI IPFS URI of dataset metadata
     * @param hourlyRate Hourly rental rate (USDC)
     * @param idoConfig IDO configuration parameters
     * @return datasetId ID of the deployed dataset
     */
    function deployDataset(
        address projectAddress,
        string calldata tokenName,
        string calldata tokenSymbol,
        string calldata metadataURI,
        uint256 hourlyRate,
        IDOConfig calldata idoConfig
    ) external returns (uint256 datasetId) {
        // Validate inputs
        if (projectAddress == address(0)) revert ZeroAddress();
        if (bytes(tokenName).length == 0 || bytes(tokenSymbol).length == 0)
            revert EmptyString();
        if (bytes(metadataURI).length == 0) revert EmptyString();

        // Collect deployment fee
        if (deploymentFee > 0 && protocolTreasury != address(0)) {
            IERC20(usdc).transferFrom(
                msg.sender,
                protocolTreasury,
                deploymentFee
            );
        }

        // Get dataset ID
        datasetId = datasetCount++;

        // Deploy contracts using minimal proxy pattern
        address datasetToken = _deployDatasetToken(tokenName, tokenSymbol);
        address datasetManager = _deployDatasetManager(
            datasetToken,
            projectAddress,
            metadataURI
        );
        address rentalPool = _deployRentalPool(datasetToken);
        address ido = _deployIDO(idoConfig, projectAddress, datasetToken);

        // Initialize contracts and set up relationships
        _initializeContracts(
            datasetId,
            ido,
            datasetToken,
            datasetManager,
            rentalPool,
            projectAddress,
            hourlyRate
        );

        // Store in registry
        datasets[datasetId] = DatasetSuite({
            ido: ido,
            datasetToken: datasetToken,
            datasetManager: datasetManager,
            rentalPool: rentalPool,
            projectAddress: projectAddress,
            createdAt: block.timestamp,
            exists: true
        });

        idoToDatasetId[ido] = datasetId;
        tokenToDatasetId[datasetToken] = datasetId;
        allDatasetIds.push(datasetId);

        emit DatasetDeployed(
            datasetId,
            projectAddress,
            ido,
            datasetToken,
            datasetManager,
            rentalPool
        );
    }

    // ========== Internal Functions ==========

    /**
     * @notice Deploys DatasetToken using minimal proxy
     */
    function _deployDatasetToken(
        string calldata tokenName,
        string calldata tokenSymbol
    ) internal returns (address) {
        if (datasetTokenImplementation == address(0)) {
            // Deploy new DatasetToken directly if no implementation set
            // Mint total supply (10 million tokens) to Factory
            uint256 totalSupply = 10_000_000 * 10 ** 18;
            DatasetToken token = new DatasetToken(
                tokenName,
                tokenSymbol,
                address(this),
                address(0), // Will set IDO later
                totalSupply // Mint to Factory, will transfer to IDO
            );
            return address(token);
        } else {
            // Clone implementation
            return datasetTokenImplementation.clone();
        }
    }

    /**
     * @notice Deploys DatasetManager using minimal proxy
     */
    function _deployDatasetManager(
        address datasetToken,
        address projectAddress,
        string calldata metadataURI
    ) internal returns (address) {
        if (datasetManagerImplementation == address(0)) {
            // Deploy new DatasetManager directly
            DatasetManager manager = new DatasetManager(
                datasetToken,
                projectAddress,
                address(this),
                metadataURI
            );
            return address(manager);
        } else {
            // Clone implementation
            return datasetManagerImplementation.clone();
        }
    }

    /**
     * @notice Deploys RentalPool using minimal proxy
     */
    function _deployRentalPool(
        address datasetToken
    ) internal returns (address) {
        if (rentalPoolImplementation == address(0)) {
            // Deploy new RentalPool directly
            RentalPool pool = new RentalPool(usdc, datasetToken, address(this));
            return address(pool);
        } else {
            // Clone implementation
            return rentalPoolImplementation.clone();
        }
    }

    /**
     * @notice Deploys IDO using minimal proxy
     */
    function _deployIDO(
        IDOConfig calldata config,
        address projectAddress,
        address datasetToken
    ) internal returns (address) {
        if (idoImplementation == address(0)) {
            // Deploy new IDO directly
            IDO ido = new IDO(
                config.alphaProject,
                config.k,
                config.betaLP,
                config.minRaiseRatio,
                config.initialPrice,
                projectAddress,
                datasetToken,
                usdc,
                protocolTreasury,
                daoTreasury,
                rentalManager
            );
            return address(ido);
        } else {
            // Clone implementation
            return idoImplementation.clone();
        }
    }

    /**
     * @notice Initializes contracts and sets up relationships
     */
    function _initializeContracts(
        uint256 datasetId,
        address ido,
        address datasetToken,
        address datasetManager,
        address rentalPool,
        address projectAddress,
        uint256 hourlyRate
    ) internal {
        // Set IDO contract in DatasetToken
        DatasetToken(datasetToken).setDLEContract(ido);

        // Transfer all tokens from Factory to IDO
        uint256 totalSupply = DatasetToken(datasetToken).balanceOf(
            address(this)
        );
        if (totalSupply > 0) {
            DatasetToken(datasetToken).transfer(ido, totalSupply);
        }

        // Set RentalPool in DatasetToken
        DatasetToken(datasetToken).setRentalPool(rentalPool);

        // Set DatasetManager in DatasetToken
        DatasetToken(datasetToken).setDatasetManager(datasetManager);

        // Set RentalManager in DatasetManager
        if (rentalManager != address(0)) {
            DatasetManager(datasetManager).setRentalManager(rentalManager);
        }

        // Set TEE Backend (using factory owner as default)
        // In production, this should be set to actual TEE backend
        DatasetManager(datasetManager).setTeeBackend(owner());

        // Authorize RentalManager in RentalPool
        if (rentalManager != address(0)) {
            RentalPool(rentalPool).setAuthorizedManager(rentalManager, true);
        }

        // Set hourly rental rate in RentalManager
        if (rentalManager != address(0)) {
            RentalManager(rentalManager).updatePrice(datasetToken, hourlyRate);
            // Register dataset rental pool mapping
            RentalManager(rentalManager).setDatasetRentalPool(
                datasetToken,
                rentalPool
            );
        }

        // Transfer DatasetToken ownership to IDO
        DatasetToken(datasetToken).transferOwnership(ido);

        // Transfer DatasetManager ownership to project
        DatasetManager(datasetManager).transferOwnership(projectAddress);

        // Transfer RentalPool ownership to project
        RentalPool(rentalPool).transferOwnership(projectAddress);
    }

    // ========== View Functions ==========

    /**
     * @notice Gets dataset contract suite
     * @param datasetId Dataset ID
     * @return suite Dataset contract suite
     */
    function getDataset(
        uint256 datasetId
    ) external view returns (DatasetSuite memory suite) {
        suite = datasets[datasetId];
    }

    /**
     * @notice Gets dataset ID from IDO address
     * @param ido IDO contract address
     * @return datasetId Dataset ID
     */
    function getDatasetIdFromIDO(
        address ido
    ) external view returns (uint256 datasetId) {
        datasetId = idoToDatasetId[ido];
    }

    /**
     * @notice Gets dataset ID from token address
     * @param token DatasetToken address
     * @return datasetId Dataset ID
     */
    function getDatasetIdFromToken(
        address token
    ) external view returns (uint256 datasetId) {
        datasetId = tokenToDatasetId[token];
    }

    /**
     * @notice Gets all dataset IDs
     * @return ids Array of all dataset IDs
     */
    function getAllDatasetIds() external view returns (uint256[] memory ids) {
        ids = allDatasetIds;
    }

    /**
     * @notice Gets total number of datasets
     * @return count Total datasets
     */
    function getTotalDatasets() external view returns (uint256 count) {
        count = datasetCount;
    }

    // ========== Admin Functions ==========

    /**
     * @notice Sets RentalManager contract address (can only be set once)
     * @param rentalManager_ RentalManager address
     */
    function setRentalManager(address rentalManager_) external onlyOwner {
        if (rentalManager != address(0)) revert AlreadySet();
        if (rentalManager_ == address(0)) revert ZeroAddress();

        rentalManager = rentalManager_;
        emit RentalManagerSet(rentalManager_);
    }

    /**
     * @notice Sets DAOTreasury contract address (can only be set once)
     * @param daoTreasury_ DAOTreasury address
     */
    function setDAOTreasury(address daoTreasury_) external onlyOwner {
        if (daoTreasury != address(0)) revert AlreadySet();
        if (daoTreasury_ == address(0)) revert ZeroAddress();

        daoTreasury = daoTreasury_;
        emit DAOTreasurySet(daoTreasury_);
    }

    /**
     * @notice Sets protocol treasury address
     * @param protocolTreasury_ Protocol treasury address
     */
    function setProtocolTreasury(address protocolTreasury_) external onlyOwner {
        if (protocolTreasury_ == address(0)) revert ZeroAddress();

        protocolTreasury = protocolTreasury_;
        emit ProtocolTreasurySet(protocolTreasury_);
    }

    /**
     * @notice Updates deployment fee
     * @param newFee New deployment fee (USDC)
     */
    function setDeploymentFee(uint256 newFee) external onlyOwner {
        uint256 oldFee = deploymentFee;
        deploymentFee = newFee;

        emit DeploymentFeeUpdated(oldFee, newFee);
    }

    /**
     * @notice Sets implementation contract for IDO
     * @param implementation IDO implementation address
     */
    function setIDOImplementation(address implementation) external onlyOwner {
        if (implementation == address(0)) revert ZeroAddress();
        idoImplementation = implementation;
        emit ImplementationUpdated("IDO", implementation);
    }

    /**
     * @notice Sets implementation contract for DatasetToken
     * @param implementation DatasetToken implementation address
     */
    function setDatasetTokenImplementation(
        address implementation
    ) external onlyOwner {
        if (implementation == address(0)) revert ZeroAddress();
        datasetTokenImplementation = implementation;
        emit ImplementationUpdated("DatasetToken", implementation);
    }

    /**
     * @notice Sets implementation contract for DatasetManager
     * @param implementation DatasetManager implementation address
     */
    function setDatasetManagerImplementation(
        address implementation
    ) external onlyOwner {
        if (implementation == address(0)) revert ZeroAddress();
        datasetManagerImplementation = implementation;
        emit ImplementationUpdated("DatasetManager", implementation);
    }

    /**
     * @notice Sets implementation contract for RentalPool
     * @param implementation RentalPool implementation address
     */
    function setRentalPoolImplementation(
        address implementation
    ) external onlyOwner {
        if (implementation == address(0)) revert ZeroAddress();
        rentalPoolImplementation = implementation;
        emit ImplementationUpdated("RentalPool", implementation);
    }
}

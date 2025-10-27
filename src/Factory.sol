// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/proxy/Clones.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./IDO.sol";
import "./DatasetToken.sol";
import "./DatasetManager.sol";
import "./RentalPool.sol";

/**
 * @title IRentalManager
 * @notice Interface for RentalManager contract
 */
interface IRentalManager {
    function updatePrice(address datasetToken, uint256 newPricePerHour) external;
    function setDatasetRentalPool(address datasetToken, address rentalPool) external;
}

/**
 * @title Factory
 * @notice Factory for deploying dataset contract suites using EIP-1167 minimal proxy pattern
 * @dev Size optimized (<24KB). Backend indexes via events. No on-chain registry.
 *      Uses Clones.clone() to deploy minimal proxies (~200 bytes) instead of full contracts.
 *      Gas savings: ~90% (from ~$300 to ~$30 per deployment)
 */
contract Factory is Ownable {
    using Clones for address;

    // ========== Structs ==========

    struct IDOConfig {
        uint256 alphaProject;
        uint256 k;
        uint256 betaLP;
        uint256 minRaiseRatio;
        uint256 initialPrice;
    }

    // ========== Immutable State ==========

    address public immutable usdc;

    // ========== Implementation Contracts ==========

    address public tokenImplementation;
    address public managerImplementation;
    address public poolImplementation;
    address public idoImplementation;

    // ========== Mutable State ==========

    address public rentalManager;
    address public daoTreasury;
    address public protocolTreasury;
    uint256 public datasetCount;

    // ========== Events ==========

    event DatasetDeployed(
        uint256 indexed datasetId,
        address indexed projectAddress,
        address ido,
        address token,
        address manager,
        address pool
    );

    event ImplementationsSet(
        address token,
        address manager,
        address pool,
        address ido
    );

    // ========== Errors ==========

    error ZeroAddress();
    error EmptyString();
    error InvalidConfig();

    // ========== Constructor ==========

    constructor(address usdc_, address initialOwner) Ownable(initialOwner) {
        require(usdc_ != address(0), "0addr");
        usdc = usdc_;

        // Deploy implementation contracts (only once)
        tokenImplementation = address(new DatasetToken());
        managerImplementation = address(new DatasetManager());
        poolImplementation = address(new RentalPool());
        idoImplementation = address(new IDO());

        emit ImplementationsSet(
            tokenImplementation,
            managerImplementation,
            poolImplementation,
            idoImplementation
        );
    }

    // ========== Core Function ==========

    function deployDataset(
        address projectAddress,
        string memory name,
        string memory symbol,
        string memory metadataURI,
        uint256 rentalPricePerHour,
        IDOConfig memory config
    ) external returns (uint256 datasetId) {
        require(projectAddress != address(0), "0addr");
        require(bytes(name).length > 0 && bytes(symbol).length > 0, "empty");
        require(bytes(metadataURI).length > 0, "empty");
        require(
            config.alphaProject > 0 &&
            config.alphaProject < 10000 &&
            config.betaLP > 0 &&
            config.betaLP < 10000 &&
            config.k > 0 &&
            config.minRaiseRatio > 0 &&
            config.minRaiseRatio <= 10000 &&
            config.initialPrice > 0,
            "config"
        );

        datasetId = ++datasetCount;
        uint256 supply = 10_000_000 * 10 ** 18; // 10 million tokens as per spec

        // Clone implementation contracts
        address token = Clones.clone(tokenImplementation);
        address manager = Clones.clone(managerImplementation);
        address pool = Clones.clone(poolImplementation);
        address ido = Clones.clone(idoImplementation);

        // Initialize Token (needs ido address but will transfer tokens to it)
        DatasetToken(token).initialize(
            name,
            symbol,
            address(this), // Factory is initial owner
            ido,           // IDO contract
            supply         // Minted to Token contract itself
        );

        // Initialize Manager
        DatasetManager(manager).initialize(
            token,
            projectAddress,
            address(this), // Factory is initial owner
            metadataURI
        );

        // Initialize Pool
        RentalPool(pool).initialize(
            usdc,
            token,
            address(this) // Factory is initial owner
        );

        // Initialize IDO
        IDO(ido).initialize(
            config.alphaProject,
            config.k,
            config.betaLP,
            config.minRaiseRatio,
            config.initialPrice,
            projectAddress,
            token,
            usdc,
            protocolTreasury,
            daoTreasury,
            rentalManager
        );

        // Tokens are already minted to IDO in initialize()
        // Set rental price in RentalManager
        if (rentalManager != address(0)) {
            IRentalManager(rentalManager).updatePrice(token, rentalPricePerHour);
            IRentalManager(rentalManager).setDatasetRentalPool(token, pool);
        }

        // Transfer ownership
        DatasetToken(token).transferOwnership(projectAddress);
        DatasetManager(manager).transferOwnership(projectAddress);
        RentalPool(pool).transferOwnership(projectAddress);

        emit DatasetDeployed(
            datasetId,
            projectAddress,
            ido,
            token,
            manager,
            pool
        );
    }

    // ========== Admin Functions ==========

    function configure(
        address rentalManager_,
        address daoTreasury_,
        address protocolTreasury_
    ) external onlyOwner {
        if (rentalManager_ != address(0)) rentalManager = rentalManager_;
        if (daoTreasury_ != address(0)) daoTreasury = daoTreasury_;
        if (protocolTreasury_ != address(0)) protocolTreasury = protocolTreasury_;
    }

    function setImplementations(
        address token_,
        address manager_,
        address pool_,
        address ido_
    ) external onlyOwner {
        if (token_ != address(0)) tokenImplementation = token_;
        if (manager_ != address(0)) managerImplementation = manager_;
        if (pool_ != address(0)) poolImplementation = pool_;
        if (ido_ != address(0)) idoImplementation = ido_;

        emit ImplementationsSet(
            tokenImplementation,
            managerImplementation,
            poolImplementation,
            idoImplementation
        );
    }
}

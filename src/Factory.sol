// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/proxy/Clones.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./IDO.sol";
import "./DatasetToken.sol";
import "./RentalPool.sol";
import "./Governance.sol";
import "./libraries/VirtualAMM.sol";

/**
 * @title Factory
 * @notice Factory for launching IDOs by deploying dataset contract suites using EIP-1167 minimal proxy pattern
 * @dev Size optimized (<24KB). Metadata stored in each IDO contract.
 *      Uses Clones.clone() to deploy minimal proxies (~200 bytes) instead of full contracts.
 *      Gas savings: ~90% (from ~$300 to ~$30 per deployment)
 */
contract Factory is Ownable {
    using Clones for address;

    // ========== Structs ==========

    struct IDOConfig {
        uint256 rTarget; // Funding goal in USDC (6 decimals)
        uint256 alpha; // Project ownership ratio (basis points, 1-5000 = 0.01%-50%)
    }

    // ========== Immutable State ==========

    address public immutable usdc;

    // ========== Implementation Contracts ==========

    address public tokenImplementation;
    address public poolImplementation;
    address public idoImplementation;

    // ========== Mutable State ==========

    /// @notice Protocol fee recipient address (NOT the Treasury contract)
    /// @dev Receives protocol fees from IDO trading and dataset rentals
    address public feeTo;
    address public uniswapV2Router;
    address public uniswapV2Factory;
    uint256 public datasetCount;

    // ========== Events ==========

    event IDOCreated(
        uint256 indexed datasetId,
        address indexed projectAddress,
        address indexed ido,
        address token,
        address pool,
        address governance
    );

    event ImplementationsSet(address token, address pool, address ido, address governance);

    event Configured(
        address indexed feeTo,
        address uniswapV2Router,
        address uniswapV2Factory
    );

    // ========== Errors ==========

    error ZeroAddress();
    error EmptyString();
    error InvalidConfig();
    error AlreadySet();

    // ========== Constructor ==========

    /**
     * @notice Initializes the Factory with USDC address and implementation addresses
     * @dev Implements EIP-1167 minimal proxy pattern for Token, Pool, and IDO
     *      Governance is deployed as full instance per IDO (not cloned)
     *      Implementation contracts must be deployed separately to avoid initcode size limit
     *
     * @param usdc_ USDC token address (typically 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48 on mainnet)
     * @param initialOwner Factory owner address (typically multisig)
     * @param tokenImpl_ Pre-deployed DatasetToken implementation address
     * @param poolImpl_ Pre-deployed RentalPool implementation address
     * @param idoImpl_ Pre-deployed IDO implementation address
     *
     * @dev Gas cost breakdown:
     *      - Implementation deployments: ~$150 (3 contracts, done once per network)
     *      - Factory deployment: ~$50 (references implementations)
     *      - Each IDO deployment: ~$40 (clones Token/Pool/IDO + new Governance)
     */
    constructor(
        address usdc_,
        address initialOwner,
        address tokenImpl_,
        address poolImpl_,
        address idoImpl_
    ) Ownable(initialOwner) {
        require(usdc_ != address(0), "0addr");
        require(tokenImpl_ != address(0), "0addr");
        require(poolImpl_ != address(0), "0addr");
        require(idoImpl_ != address(0), "0addr");

        usdc = usdc_;
        tokenImplementation = tokenImpl_;
        poolImplementation = poolImpl_;
        idoImplementation = idoImpl_;

        emit ImplementationsSet(
            tokenImplementation,
            poolImplementation,
            idoImplementation,
            address(0) // No governance implementation (deployed per-IDO)
        );
    }

    // ========== Core Function ==========

    /**
     * @notice Launches an IDO by deploying its complete contract suite
     * @dev Creates Token/Pool/IDO via cloning + full Governance instance
     *      Token/Pool/IDO are cloned (~200 bytes each)
     *      Governance is deployed as full instance per IDO
     *
     * @param projectAddress Project owner address (receives ownership of all contracts)
     * @param name Token name (e.g., "Longevity Data Token")
     * @param symbol Token symbol (e.g., "LDT")
     * @param metadataURI IPFS CID pointing to dataset metadata JSON
     * @param rentalPricePerHour Rental price in USDC (6 decimals, e.g., 10e6 = 10 USDC/hour)
     * @param config IDO configuration:
     *               - rTarget: Funding goal in USDC (6 decimals)
     *               - alpha: Project ownership ratio (basis points, 1-5000 = 0.01%-50%)
     *
     * @return datasetId Unique identifier for this IDO/dataset (sequential counter)
     *
     * @dev Deployment flow:
     *      1. Validate inputs
     *      2. Calculate total token supply using Virtual AMM formula
     *      3. Clone Token/Pool/IDO + deploy Governance instance
     *      4. Initialize all contracts with proper parameters
     *      5. Configure cross-contract permissions
     *      6. Transfer ownership to project address
     *      7. Emit IDOCreated event for backend indexing
     */
    function deployIDO(
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
            config.rTarget > 0 && config.alpha > 0 && config.alpha <= 5000,
            "config"
        );

        datasetId = ++datasetCount;

        // Calculate total supply using VirtualAMM
        VirtualAMM.DecimalConfig memory decimalConfig = VirtualAMM
            .DecimalConfig({
                usdcDecimals: 6,
                tokenDecimals: 18,
                usdcUnit: 1e6,
                tokenUnit: 1e18
            });

        (uint256 totalSupply, , ) = VirtualAMM.calculateTotalSupply(
            config.rTarget,
            config.alpha,
            10000, // ALPHA_DENOMINATOR
            decimalConfig
        );

        // Clone Token/Pool/IDO implementations
        address token = Clones.clone(tokenImplementation);
        address pool = Clones.clone(poolImplementation);
        address ido = Clones.clone(idoImplementation);

        // Deploy full Governance instance (binds to IDO address)
        address governance = address(new Governance(
            ido,
            usdc,
            uniswapV2Router,
            uniswapV2Factory
        ));

        // Initialize Token
        DatasetToken(token).initialize(
            name,
            symbol,
            address(this), // Factory is initial owner
            ido,
            totalSupply
        );

        // Initialize Pool
        RentalPool(pool).initialize(
            usdc,
            token,
            address(this) // Factory is initial owner
        );

        // Initialize IDO with governance and rental pool
        IDO(ido).initialize(
            config.rTarget,
            config.alpha,
            projectAddress,
            token,
            usdc,
            feeTo,
            governance, // Per-IDO governance instance
            pool,
            uniswapV2Router,
            uniswapV2Factory,
            metadataURI,
            rentalPricePerHour
        );

        // Authorize IDO contract to call RentalPool.addRevenue
        RentalPool(pool).setAuthorizedManager(ido, true);

        // Transfer ownership
        DatasetToken(token).transferOwnership(projectAddress);
        RentalPool(pool).transferOwnership(projectAddress);

        emit IDOCreated(datasetId, projectAddress, ido, token, pool, governance);
    }

    // ========== Admin Functions ==========

    /**
     * @notice Configures protocol-wide addresses (can only be called once)
     * @dev Must be called before deploying any IDO. All addresses are required.
     *
     * @param feeTo_ Protocol fee recipient address (receives trading fees)
     * @param uniswapV2Router_ Uniswap V2 Router address (for creating liquidity pools)
     * @param uniswapV2Factory_ Uniswap V2 Factory address (for pair creation)
     *
     * @dev Example usage:
     *      factory.configure(
     *          protocolFeeAddr,
     *          0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D,  // Uniswap Router
     *          0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f   // Uniswap Factory
     *      );
     */
    function configure(
        address feeTo_,
        address uniswapV2Router_,
        address uniswapV2Factory_
    ) external onlyOwner {
        // Can only be configured once
        if (
            feeTo != address(0) ||
            uniswapV2Router != address(0) ||
            uniswapV2Factory != address(0)
        ) {
            revert AlreadySet();
        }

        // All addresses are required
        if (
            feeTo_ == address(0) ||
            uniswapV2Router_ == address(0) ||
            uniswapV2Factory_ == address(0)
        ) {
            revert ZeroAddress();
        }

        feeTo = feeTo_;
        uniswapV2Router = uniswapV2Router_;
        uniswapV2Factory = uniswapV2Factory_;

        emit Configured(feeTo_, uniswapV2Router_, uniswapV2Factory_);
    }
}

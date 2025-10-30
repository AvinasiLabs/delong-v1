// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/mocks/MockUSDC.sol";
import "../src/DatasetToken.sol";
import "../src/DatasetManager.sol";
import "../src/RentalPool.sol";
import "../src/RentalManager.sol";
import "../src/IDO.sol";
import "../src/DAOTreasury.sol";
import "../src/DAOGovernance.sol";
import "../src/Factory.sol";

/**
 * @title Deploy
 * @notice Deployment script for DeLong Protocol v1
 * @dev Usage:
 *      1. Start Anvil: anvil
 *      2. Deploy: forge script script/Deploy.s.sol:Deploy --rpc-url http://localhost:8545 --broadcast -vvvv
 *      3. Or use helper: ./script/deploy-local.sh
 */
contract Deploy is Script {
    // Deployment addresses
    MockUSDC public usdc;
    RentalManager public rentalManager;
    DAOTreasury public daoTreasury;
    DAOGovernance public daoGovernance;
    Factory public factory;

    // Configuration
    uint256 public deployerPrivateKey;
    address public deployer;
    address public protocolTreasury;
    address public projectAddress;

    function setUp() public {
        // Read private key from .env file
        deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        deployer = vm.addr(deployerPrivateKey);

        // Get other addresses from environment or use defaults
        protocolTreasury = vm.envOr(
            "PROTOCOL_TREASURY",
            address(0x7C04CeE8A78e736e1A4f2Bc43E7CCbCB8E3a9114)
        ); // delong-admin
        projectAddress = vm.envOr(
            "PROJECT_ADDRESS",
            address(0x555361045799feD9C50C669a6d7f41374c85c83C)
        ); // original committee
    }

    function run() external {
        console.log("=== DeLong Protocol v1 Deployment ===");
        console.log("Deployer:", deployer);
        console.log("Protocol Treasury:", protocolTreasury);
        console.log("Project Address:", projectAddress);
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        // Step 1: Deploy MockUSDC for local testing
        console.log("Step 1: Deploying MockUSDC...");
        usdc = new MockUSDC();
        console.log("MockUSDC deployed at:", address(usdc));
        console.log("");

        // Step 2: Deploy shared infrastructure contracts
        console.log("Step 2: Deploying shared infrastructure...");

        rentalManager = new RentalManager(address(usdc), deployer);
        console.log("RentalManager deployed at:", address(rentalManager));

        daoTreasury = new DAOTreasury(address(usdc), deployer);
        console.log("DAOTreasury deployed at:", address(daoTreasury));

        daoGovernance = new DAOGovernance(address(usdc), deployer);
        console.log("DAOGovernance deployed at:", address(daoGovernance));
        console.log("");

        // Step 3: Deploy Factory
        console.log("Step 3: Deploying Factory...");
        factory = new Factory(address(usdc), deployer);
        console.log("Factory deployed at:", address(factory));
        console.log("");

        // Step 4: Configure contracts
        console.log("Step 4: Configuring contracts...");

        // Configure Factory
        factory.configure(
            address(rentalManager),
            address(daoTreasury),
            protocolTreasury,
            address(0x1111111111111111111111111111111111111111),
            address(0x2222222222222222222222222222222222222222)
        );
        console.log("Factory configured");

        // Configure RentalManager
        rentalManager.setFactory(address(factory));
        rentalManager.setProtocolTreasury(protocolTreasury);
        rentalManager.setAuthorizedBackend(deployer, true); // Deployer as authorized backend for testing
        console.log("RentalManager configured");

        // Configure DAOTreasury
        daoTreasury.setIDOContract(address(factory)); // Factory can deposit on behalf of IDOs
        daoTreasury.setDAOGovernance(address(daoGovernance));
        console.log("DAOTreasury configured");

        // Configure DAOGovernance
        daoGovernance.setDAOTreasury(address(daoTreasury));
        console.log("DAOGovernance configured");
        console.log("");

        // Step 5: Mint test USDC
        console.log("Step 5: Minting test USDC...");
        usdc.mint(deployer, 10_000_000 * 10 ** 6); // 10M USDC to deployer
        usdc.mint(protocolTreasury, 1_000_000 * 10 ** 6); // 1M USDC to protocol treasury
        console.log("Minted 10M USDC to deployer");
        console.log("Minted 1M USDC to protocol treasury");
        console.log("");

        vm.stopBroadcast();

        // Step 6: Print deployment summary
        printDeploymentSummary();
    }

    function printDeploymentSummary() internal view {
        console.log("=== Deployment Summary ===");
        console.log("");
        console.log("Core Contracts:");
        console.log("  MockUSDC:        ", address(usdc));
        console.log("  Factory:         ", address(factory));
        console.log("  RentalManager:   ", address(rentalManager));
        console.log("  DAOTreasury:     ", address(daoTreasury));
        console.log("  DAOGovernance:   ", address(daoGovernance));
        console.log("");
        console.log("Configuration:");
        console.log("  Deployer:        ", deployer);
        console.log("  Protocol Treasury:", protocolTreasury);
        console.log("  Project Address: ", projectAddress);
        console.log("");
        console.log("Next Steps:");
        console.log("1. Deploy a dataset:");
        console.log(
            "   forge script script/DeployDataset.s.sol:DeployDataset --rpc-url http://localhost:8545 --broadcast"
        );
        console.log("");
        console.log("2. Interact with contracts:");
        console.log(
            "   cast call <address> 'function(params)' --rpc-url http://localhost:8545"
        );
        console.log("");
        console.log("=== Deployment Complete ===");
    }
}

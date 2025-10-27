// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/RentalManager.sol";
import "../src/DAOTreasury.sol";
import "../src/DAOGovernance.sol";
import "../src/Factory.sol";

/**
 * @title DeploySepolia
 * @notice Deployment script for DeLong Protocol v1 on Sepolia testnet
 * @dev Usage: ./script/deploy-sepolia.sh
 */
contract DeploySepolia is Script {
    // MockUSDC deployed on Sepolia (10M initial supply to deployer for testing)
    address public constant SEPOLIA_USDC = 0x854f718774e06879d085ef4f693bb0F2edEa0f24; // MockUSDC (6 decimals)
    
    // Deployment addresses
    RentalManager public rentalManager;
    DAOTreasury public daoTreasury;
    DAOGovernance public daoGovernance;
    Factory public factory;

    // Configuration
    uint256 public deployerPrivateKey;
    address public deployer;
    address public protocolTreasury;

    function setUp() public {
        // Read private key from .env file
        deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        deployer = vm.addr(deployerPrivateKey);

        // Protocol treasury defaults to deployer if not set
        protocolTreasury = vm.envOr("PROTOCOL_TREASURY", deployer);
    }

    function run() external {
        console.log("=== DeLong Protocol v1 Sepolia Deployment ===");
        console.log("Network: Sepolia Testnet");
        console.log("Deployer:", deployer);
        console.log("Protocol Treasury:", protocolTreasury);
        console.log("USDC Address:", SEPOLIA_USDC);
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        // Step 1: Deploy shared infrastructure contracts
        console.log("Step 1: Deploying shared infrastructure...");

        rentalManager = new RentalManager(SEPOLIA_USDC, deployer);
        console.log("RentalManager deployed at:", address(rentalManager));

        daoTreasury = new DAOTreasury(SEPOLIA_USDC, deployer);
        console.log("DAOTreasury deployed at:", address(daoTreasury));

        daoGovernance = new DAOGovernance(SEPOLIA_USDC, deployer);
        console.log("DAOGovernance deployed at:", address(daoGovernance));
        console.log("");

        // Step 2: Deploy Factory
        console.log("Step 2: Deploying Factory...");
        factory = new Factory(SEPOLIA_USDC, deployer);
        console.log("Factory deployed at:", address(factory));
        console.log("");

        // Step 3: Configure contracts
        console.log("Step 3: Configuring contracts...");

        // Configure Factory
        factory.configure(
            address(rentalManager),
            address(daoTreasury),
            protocolTreasury
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

        vm.stopBroadcast();

        // Step 4: Print deployment summary
        printDeploymentSummary();
        
        // Step 5: Save deployment addresses to file
        saveDeploymentAddresses();
    }

    function printDeploymentSummary() internal view {
        console.log("=== Deployment Summary ===");
        console.log("");
        console.log("Network: Sepolia Testnet");
        console.log("");
        console.log("Core Contracts:");
        console.log("  USDC:            ", SEPOLIA_USDC);
        console.log("  Factory:         ", address(factory));
        console.log("  RentalManager:   ", address(rentalManager));
        console.log("  DAOTreasury:     ", address(daoTreasury));
        console.log("  DAOGovernance:   ", address(daoGovernance));
        console.log("");
        console.log("Configuration:");
        console.log("  Deployer:        ", deployer);
        console.log("  Protocol Treasury:", protocolTreasury);
        console.log("");
        console.log("Next Steps:");
        console.log("1. Verify contracts on Etherscan:");
        console.log("   forge verify-contract <address> <contract> --chain sepolia");
        console.log("");
        console.log("2. Update frontend .env.local with these addresses");
        console.log("");
        console.log("3. Update subgraph config with these addresses");
        console.log("");
        console.log("=== Deployment Complete ===");
    }
    
    function saveDeploymentAddresses() internal {
        string memory deploymentInfo = string(abi.encodePacked(
            "# DeLong Protocol v1 - Sepolia Deployment\n",
            "# Deployed at: ", vm.toString(block.timestamp), "\n\n",
            "NETWORK=sepolia\n",
            "USDC_ADDRESS=", vm.toString(SEPOLIA_USDC), "\n",
            "FACTORY_ADDRESS=", vm.toString(address(factory)), "\n",
            "RENTAL_MANAGER_ADDRESS=", vm.toString(address(rentalManager)), "\n",
            "DAO_TREASURY_ADDRESS=", vm.toString(address(daoTreasury)), "\n",
            "DAO_GOVERNANCE_ADDRESS=", vm.toString(address(daoGovernance)), "\n",
            "DEPLOYER_ADDRESS=", vm.toString(deployer), "\n",
            "PROTOCOL_TREASURY_ADDRESS=", vm.toString(protocolTreasury), "\n"
        ));
        
        vm.writeFile("./deployments/sepolia.env", deploymentInfo);
        console.log("");
        console.log("Deployment addresses saved to: ./deployments/sepolia.env");
    }
}

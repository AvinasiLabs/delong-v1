// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/Factory.sol";
import "../src/DatasetToken.sol";
import "../src/RentalPool.sol";
import "../src/IDO.sol";

/**
 * @title DeploySepolia
 * @notice Deployment script for DeLong Protocol v1 on Sepolia testnet
 * @dev Usage: ./script/deploy-sepolia.sh
 *      Note: Treasury and Governance are now per-IDO instances, not global singletons
 */
contract DeploySepolia is Script {
    // MockUSDC deployed on Sepolia (100B pre-minted supply, 50k claimable per address)
    address public constant SEPOLIA_USDC = 0x2bfD56D08d549544AA492Ca021fc3Eb959386Fc0; // MockUSDC (6 decimals)

    // Deployment addresses
    DatasetToken public tokenImplementation;
    RentalPool public poolImplementation;
    IDO public idoImplementation;
    Factory public factory;

    // Configuration
    uint256 public deployerPrivateKey;
    address public deployer;
    address public feeTo;

    function setUp() public {
        // Read private key from .env file
        deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        deployer = vm.addr(deployerPrivateKey);

        // Protocol treasury defaults to deployer if not set
        feeTo = vm.envOr("PROTOCOL_TREASURY", deployer);
    }

    function run() external {
        console.log("=== DeLong Protocol v1 Sepolia Deployment ===");
        console.log("Network: Sepolia Testnet");
        console.log("Deployer:", deployer);
        console.log("Protocol Treasury:", feeTo);
        console.log("USDC Address:", SEPOLIA_USDC);
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        // Step 1: Deploy implementation contracts
        console.log("Step 1: Deploying implementation contracts...");
        tokenImplementation = new DatasetToken();
        console.log("  DatasetToken implementation:", address(tokenImplementation));

        poolImplementation = new RentalPool();
        console.log("  RentalPool implementation:", address(poolImplementation));

        idoImplementation = new IDO();
        console.log("  IDO implementation:", address(idoImplementation));
        console.log("");

        // Step 2: Deploy Factory with implementation addresses
        console.log("Step 2: Deploying Factory...");
        factory = new Factory(
            SEPOLIA_USDC,
            deployer,
            address(tokenImplementation),
            address(poolImplementation),
            address(idoImplementation)
        );
        console.log("Factory deployed at:", address(factory));
        console.log("");

        // Step 3: Configure Factory
        console.log("Step 3: Configuring Factory...");
        factory.configure(
            feeTo,
            0xC532a74256D3Db42D0Bf7a0400fEFDbad7694008, // Sepolia Uniswap V2 Router
            0x7E0987E5b3a30e3f2828572Bb659A548460a3003  // Sepolia Uniswap V2 Factory
        );
        console.log("Factory configured");
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
        console.log("Implementation Contracts:");
        console.log("  DatasetToken:    ", address(tokenImplementation));
        console.log("  RentalPool:      ", address(poolImplementation));
        console.log("  IDO:             ", address(idoImplementation));
        console.log("");
        console.log("Core Contracts:");
        console.log("  USDC:            ", SEPOLIA_USDC);
        console.log("  Factory:         ", address(factory));
        console.log("");
        console.log("Configuration:");
        console.log("  Deployer:        ", deployer);
        console.log("  Protocol Treasury:", feeTo);
        console.log("");
        console.log("Note: Treasury and Governance are deployed per-IDO");
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
            "# Deployed at: ", vm.toString(block.timestamp), "\n",
            "# Virtual AMM pricing (constant product formula)\n",
            "# Per-IDO governance with pluggable strategy pattern\n\n",
            "NETWORK=sepolia\n",
            "USDC_ADDRESS=", vm.toString(SEPOLIA_USDC), "\n",
            "DATASET_TOKEN_IMPL=", vm.toString(address(tokenImplementation)), "\n",
            "RENTAL_POOL_IMPL=", vm.toString(address(poolImplementation)), "\n",
            "IDO_IMPL=", vm.toString(address(idoImplementation)), "\n",
            "FACTORY_ADDRESS=", vm.toString(address(factory)), "\n",
            "DEPLOYER_ADDRESS=", vm.toString(deployer), "\n",
            "FEETO_ADDRESS=", vm.toString(feeTo), "\n"
        ));

        vm.writeFile("./deployments/sepolia.env", deploymentInfo);
        console.log("");
        console.log("Deployment addresses saved to: ./deployments/sepolia.env");
    }
}

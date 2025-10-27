// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/mocks/MockUSDC.sol";
import "../src/Factory.sol";
import "../src/DatasetToken.sol";
import "../src/IDO.sol";

/**
 * @title DeployDataset
 * @notice Script to deploy a dataset using the Factory
 * @dev Usage:
 *      forge script script/DeployDataset.s.sol:DeployDataset --rpc-url http://localhost:8545 --broadcast -vvvv
 */
contract DeployDataset is Script {
    // These should match the addresses from Deploy.s.sol
    // In production, read from environment variables or config file
    address public constant USDC_ADDRESS =
        0x5FbDB2315678afecb367f032d93F642f64180aa3; // First deployment
    address public constant FACTORY_ADDRESS =
        0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512; // Adjust after running Deploy.s.sol

    function run() external {
        // Get deployer (should have USDC from previous deployment)
        address deployer = vm.envOr(
            "DEPLOYER",
            address(0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266)
        );
        address projectAddress = vm.envOr(
            "PROJECT_ADDRESS",
            address(0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC)
        );

        console.log("=== Deploying Dataset via Factory ===");
        console.log("Deployer:", deployer);
        console.log("Project:", projectAddress);
        console.log("");

        MockUSDC usdc = MockUSDC(USDC_ADDRESS);
        Factory factory = Factory(FACTORY_ADDRESS);

        vm.startBroadcast(deployer);

        // Step 1: Configure IDO parameters (no deployment fee required)
        console.log("Step 1: Configuring IDO parameters...");
        Factory.IDOConfig memory config = Factory.IDOConfig({
            alphaProject: 2000, // 20% reserved for project
            k: 1000, // Price growth coefficient
            betaLP: 7000, // 70% for LP
            minRaiseRatio: 7500, // 75% minimum raise
            initialPrice: 1 * 10 ** 6 // 1 USDC initial price
        });
        console.log("  Alpha Project: 20%");
        console.log("  Beta LP: 70%");
        console.log("  Min Raise Ratio: 75%");
        console.log("  Initial Price: 1 USDC");
        console.log("");

        // Step 2: Deploy dataset (no deployment fee)
        console.log("Step 2: Deploying dataset...");

        // Record logs to capture event
        vm.recordLogs();

        uint256 datasetId = factory.deployDataset(
            projectAddress,
            "AI Training Dataset",
            "AITD",
            "ipfs://QmExampleMetadataHash",
            10 * 10 ** 6, // 10 USDC per hour
            config
        );
        console.log("Dataset deployed with ID:", datasetId);
        console.log("");

        // Step 3: Get deployed contract addresses from logs
        // Note: In simplified Factory, addresses are emitted in DatasetDeployed event
        // For now, use placeholder addresses - in real deployment, parse event logs
        address idoAddress = address(0); // TODO: Parse from event logs
        address tokenAddress = address(0);
        address managerAddress = address(0);
        address poolAddress = address(0);

        console.log("WARNING: Contract addresses not retrieved. Event parsing not implemented in this script.");

        console.log("=== Dataset Contract Suite ===");
        console.log("Dataset ID:      ", datasetId);
        console.log("IDO:             ", idoAddress);
        console.log("DatasetToken:    ", tokenAddress);
        console.log("DatasetManager:  ", managerAddress);
        console.log("RentalPool:      ", poolAddress);
        console.log("Project:         ", projectAddress);
        console.log("");

        // Step 4: Verify token supply in IDO
        DatasetToken token = DatasetToken(tokenAddress);
        IDO ido = IDO(idoAddress);
        console.log("=== Token Information ===");
        console.log("Token Name:      ", token.name());
        console.log("Token Symbol:    ", token.symbol());
        console.log(
            "Total Supply:    ",
            token.totalSupply() / 10 ** 18,
            "tokens"
        );
        console.log(
            "IDO Balance:     ",
            token.balanceOf(idoAddress) / 10 ** 18,
            "tokens"
        );
        console.log("Token Frozen:    ", token.isFrozen() ? "Yes" : "No");
        console.log("");

        console.log("=== IDO Information ===");
        console.log(
            "Status:          ",
            uint256(ido.status()) == 0 ? "Active" : "Other"
        );
        console.log("Initial Price:   ", ido.initialPrice() / 10 ** 6, "USDC");
        console.log(
            "Salable Tokens:  ",
            ido.salableTokens() / 10 ** 18,
            "tokens"
        );
        console.log(
            "Target Tokens:   ",
            ido.targetTokens() / 10 ** 18,
            "tokens"
        );
        console.log("Sale Duration:   ", ido.SALE_DURATION() / 1 days, "days");
        console.log("");

        vm.stopBroadcast();

        console.log("=== Next Steps ===");
        console.log("1. Buy tokens during IDO:");
        console.log(
            "   forge script script/BuyTokens.s.sol:BuyTokens --rpc-url http://localhost:8545 --broadcast"
        );
        console.log("");
        console.log("2. Check current price:");
        console.log(
            "   cast call",
            idoAddress,
            '"getCurrentPrice()"',
            "--rpc-url http://localhost:8545"
        );
        console.log("");
        console.log("3. Buy tokens manually:");
        console.log("   cast send", idoAddress);
        console.log(
            "   ",
            '"buyTokens(uint256,uint256)"',
            "1000000000000000000000",
            "10000000000"
        );
        console.log(
            "   ",
            "--rpc-url http://localhost:8545 --private-key <key>"
        );
        console.log("");
    }
}

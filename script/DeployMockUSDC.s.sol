// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/mocks/MockUSDC.sol";

/**
 * @title DeployMockUSDC
 * @notice Script to deploy MockUSDC to Sepolia testnet
 */
contract DeployMockUSDC is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Deploying MockUSDC to Sepolia...");
        console.log("Deployer:", deployer);

        vm.startBroadcast(deployerPrivateKey);

        // Deploy MockUSDC
        MockUSDC usdc = new MockUSDC();
        console.log("MockUSDC deployed at:", address(usdc));

        // Mint 10 million USDC to deployer (6 decimals)
        uint256 amount = 10_000_000 * 1e6; // 10M USDC
        usdc.mint(deployer, amount);
        console.log("Minted 10,000,000 USDC to deployer");

        vm.stopBroadcast();

        // Save deployment info
        console.log("\n=== Deployment Summary ===");
        console.log("MockUSDC Address:", address(usdc));
        console.log("Deployer Balance:", usdc.balanceOf(deployer) / 1e6, "USDC");
    }
}

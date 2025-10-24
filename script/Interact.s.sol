// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/mocks/MockUSDC.sol";
import "../src/IDO.sol";
import "../src/DatasetToken.sol";
import "../src/RentalManager.sol";
import "../src/RentalPool.sol";

/**
 * @title Interact
 * @notice Interactive script for DeLong Protocol operations
 * @dev Choose operation by setting OPERATION environment variable:
 *      - BUY_TOKENS: Buy tokens from IDO
 *      - SELL_TOKENS: Sell tokens back to IDO
 *      - RENT_DATASET: Purchase dataset access
 *      - CLAIM_DIVIDENDS: Claim rental dividends
 */
contract Interact is Script {
    function run() external {
        string memory operation = vm.envOr("OPERATION", string("BUY_TOKENS"));

        if (keccak256(bytes(operation)) == keccak256(bytes("BUY_TOKENS"))) {
            buyTokens();
        } else if (
            keccak256(bytes(operation)) == keccak256(bytes("SELL_TOKENS"))
        ) {
            sellTokens();
        } else if (
            keccak256(bytes(operation)) == keccak256(bytes("RENT_DATASET"))
        ) {
            rentDataset();
        } else if (
            keccak256(bytes(operation)) == keccak256(bytes("CLAIM_DIVIDENDS"))
        ) {
            claimDividends();
        } else {
            console.log("Unknown operation:", operation);
            console.log(
                "Available operations: BUY_TOKENS, SELL_TOKENS, RENT_DATASET, CLAIM_DIVIDENDS"
            );
        }
    }

    function buyTokens() internal {
        address user = vm.envOr(
            "USER",
            address(0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266)
        );
        address idoAddress = vm.envAddress("IDO_ADDRESS");
        address usdcAddress = vm.envAddress("USDC_ADDRESS");
        uint256 tokenAmount = vm.envUint("TOKEN_AMOUNT"); // In wei (18 decimals)
        uint256 maxCost = vm.envUint("MAX_COST"); // In USDC (6 decimals)

        console.log("=== Buying Tokens ===");
        console.log("User:", user);
        console.log("IDO:", idoAddress);
        console.log("Token Amount:", tokenAmount / 10 ** 18, "tokens");
        console.log("Max Cost:", maxCost / 10 ** 6, "USDC");
        console.log("");

        MockUSDC usdc = MockUSDC(usdcAddress);
        IDO ido = IDO(idoAddress);

        vm.startBroadcast(user);

        // Check current price
        uint256 currentPrice = ido.getCurrentPrice();
        console.log("Current Price:", currentPrice / 10 ** 6, "USDC per token");

        // Approve USDC
        usdc.approve(idoAddress, maxCost);
        console.log("Approved", maxCost / 10 ** 6, "USDC");

        // Buy tokens
        uint256 actualCost = ido.buyTokens(tokenAmount, maxCost);
        console.log("Bought", tokenAmount / 10 ** 18);
        console.log("tokens for", actualCost / 10 ** 6, "USDC");

        // Check new balance
        DatasetToken token = DatasetToken(ido.tokenAddress());
        console.log(
            "New token balance:",
            token.balanceOf(user) / 10 ** 18,
            "tokens"
        );
        console.log(
            "New USDC balance:",
            usdc.balanceOf(user) / 10 ** 6,
            "USDC"
        );

        vm.stopBroadcast();
        console.log("=== Purchase Complete ===");
    }

    function sellTokens() internal {
        address user = vm.envOr(
            "USER",
            address(0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266)
        );
        address idoAddress = vm.envAddress("IDO_ADDRESS");
        uint256 tokenAmount = vm.envUint("TOKEN_AMOUNT");
        uint256 minRefund = vm.envUint("MIN_REFUND");

        console.log("=== Selling Tokens ===");
        console.log("User:", user);
        console.log("Token Amount:", tokenAmount / 10 ** 18, "tokens");
        console.log("Min Refund:", minRefund / 10 ** 6, "USDC");
        console.log("");

        IDO ido = IDO(idoAddress);
        DatasetToken token = DatasetToken(ido.tokenAddress());
        MockUSDC usdc = MockUSDC(ido.usdcToken());

        vm.startBroadcast(user);

        // Approve tokens
        token.approve(idoAddress, tokenAmount);
        console.log("Approved", tokenAmount / 10 ** 18, "tokens");

        // Sell tokens
        uint256 actualRefund = ido.sellTokens(tokenAmount, minRefund);
        console.log("Sold", tokenAmount / 10 ** 18);
        console.log("tokens for", actualRefund / 10 ** 6, "USDC");

        // Check new balance
        console.log(
            "New token balance:",
            token.balanceOf(user) / 10 ** 18,
            "tokens"
        );
        console.log(
            "New USDC balance:",
            usdc.balanceOf(user) / 10 ** 6,
            "USDC"
        );

        vm.stopBroadcast();
        console.log("=== Sale Complete ===");
    }

    function rentDataset() internal {
        address user = vm.envOr(
            "USER",
            address(0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266)
        );
        address rentalManagerAddress = vm.envAddress("RENTAL_MANAGER");
        address datasetTokenAddress = vm.envAddress("DATASET_TOKEN");
        address usdcAddress = vm.envAddress("USDC_ADDRESS");
        uint256 numHours = vm.envUint("HOURS");

        console.log("=== Renting Dataset ===");
        console.log("User:", user);
        console.log("Dataset Token:", datasetTokenAddress);
        console.log("Hours:", numHours);
        console.log("");

        RentalManager rentalManager = RentalManager(rentalManagerAddress);
        MockUSDC usdc = MockUSDC(usdcAddress);

        vm.startBroadcast(user);

        // Check rental price
        uint256 hourlyRate = rentalManager.hourlyRate(datasetTokenAddress);
        uint256 totalCost = hourlyRate * numHours;
        console.log("Hourly Rate:", hourlyRate / 10 ** 6, "USDC");
        console.log("Total Cost:", totalCost / 10 ** 6, "USDC");

        // Approve USDC
        usdc.approve(rentalManagerAddress, totalCost);

        // Purchase access
        rentalManager.purchaseAccess(datasetTokenAddress, numHours);
        console.log("Access purchased for", numHours, "hours");

        // Check active rentals
        RentalManager.Rental[] memory rentals = rentalManager.getActiveRentals(
            user,
            datasetTokenAddress
        );
        console.log("Active rentals:", rentals.length);

        vm.stopBroadcast();
        console.log("=== Rental Complete ===");
    }

    function claimDividends() internal {
        address user = vm.envOr(
            "USER",
            address(0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266)
        );
        address rentalPoolAddress = vm.envAddress("RENTAL_POOL");
        address usdcAddress = vm.envAddress("USDC_ADDRESS");

        console.log("=== Claiming Dividends ===");
        console.log("User:", user);
        console.log("Rental Pool:", rentalPoolAddress);
        console.log("");

        RentalPool pool = RentalPool(rentalPoolAddress);
        MockUSDC usdc = MockUSDC(usdcAddress);

        vm.startBroadcast(user);

        // Check pending dividends
        uint256 pending = pool.getPendingDividends(user);
        console.log("Pending dividends:", pending / 10 ** 6, "USDC");

        if (pending > 0) {
            // Claim dividends
            uint256 claimed = pool.claimDividends();
            console.log("Claimed:", claimed / 10 ** 6, "USDC");
            console.log(
                "New USDC balance:",
                usdc.balanceOf(user) / 10 ** 6,
                "USDC"
            );
        } else {
            console.log("No dividends to claim");
        }

        vm.stopBroadcast();
        console.log("=== Claim Complete ===");
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./TestBase.sol";

contract MockUSDCTest is DeLongTestBase {
    function test_Decimals() public view {
        assertEq(usdc.decimals(), 6, "USDC should have 6 decimals");
    }

    function test_InitialSupply() public view {
        uint256 user1Balance = usdc.balanceOf(user1);
        assertEq(
            user1Balance,
            INITIAL_USDC_BALANCE,
            "User1 should have initial balance"
        );
    }

    function test_Mint() public {
        uint256 mintAmount = 1000 * 10 ** 6;
        usdc.mint(user1, mintAmount);

        assertEq(
            usdc.balanceOf(user1),
            INITIAL_USDC_BALANCE + mintAmount,
            "User1 balance should increase after mint"
        );
    }

    function test_Transfer() public {
        uint256 transferAmount = 100 * 10 ** 6;

        vm.prank(user1);
        usdc.transfer(user2, transferAmount);

        assertEq(
            usdc.balanceOf(user1),
            INITIAL_USDC_BALANCE - transferAmount,
            "User1 balance should decrease"
        );
        assertEq(
            usdc.balanceOf(user2),
            INITIAL_USDC_BALANCE + transferAmount,
            "User2 balance should increase"
        );
    }

    function test_Approve() public {
        uint256 approveAmount = 1000 * 10 ** 6;

        vm.prank(user1);
        usdc.approve(user2, approveAmount);

        assertEq(
            usdc.allowance(user1, user2),
            approveAmount,
            "Allowance should be set"
        );
    }

    function test_TransferFrom() public {
        uint256 amount = 100 * 10 ** 6;

        // User1 approves User2
        vm.prank(user1);
        usdc.approve(user2, amount);

        // User2 transfers from User1 to User3
        vm.prank(user2);
        usdc.transferFrom(user1, user3, amount);

        assertEq(
            usdc.balanceOf(user1),
            INITIAL_USDC_BALANCE - amount,
            "User1 balance should decrease"
        );
        assertEq(
            usdc.balanceOf(user3),
            INITIAL_USDC_BALANCE + amount,
            "User3 balance should increase"
        );
    }
}

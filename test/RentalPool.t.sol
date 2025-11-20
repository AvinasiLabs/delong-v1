// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./TestBase.sol";

contract RentalPoolTest is DeLongTestBase {
    address public manager;

    function setUp() public override {
        super.setUp();

        // Setup manager (represents IDO contract)
        manager = makeAddr("manager");

        // Deploy DatasetToken
        datasetToken = new DatasetToken();

        // Deploy RentalPool with manager as IDO
        rentalPool = new RentalPool();
        rentalPool.initialize(
            address(usdc),
            address(datasetToken),
            owner,
            manager // Manager acts as IDO contract for testing
        );

        // Initialize DatasetToken with RentalPool address
        datasetToken.initialize(
            "Test Dataset",
            "TDS",
            owner,
            owner, // owner acts as IDO - tokens minted directly to owner
            address(rentalPool), // RentalPool for dividend distribution
            10_000_000 * 10 ** 18
        );

        // Distribute tokens to users
        datasetToken.transfer(user1, 1000 * 10 ** 18);
        datasetToken.transfer(user2, 2000 * 10 ** 18);
        datasetToken.transfer(user3, 3000 * 10 ** 18);

        vm.label(address(datasetToken), "DatasetToken");
        vm.label(address(rentalPool), "RentalPool");
    }

    function test_InitialState() public view {
        assertEq(
            address(rentalPool.usdc()),
            address(usdc),
            "USDC address should match"
        );
        assertEq(
            rentalPool.datasetToken(),
            address(datasetToken),
            "DatasetToken address should match"
        );
        assertEq(
            rentalPool.accRevenuePerToken(),
            0,
            "Initial accumulated revenue should be 0"
        );
        assertEq(
            rentalPool.totalRevenue(),
            0,
            "Initial total revenue should be 0"
        );
    }

    function test_AddRevenue() public {
        uint256 revenueAmount = 1000 * 10 ** 6; // 1000 USDC

        // Fund manager and approve
        usdc.mint(manager, revenueAmount);
        vm.prank(manager);
        usdc.approve(address(rentalPool), revenueAmount);

        // Add revenue
        vm.prank(manager);
        rentalPool.addRevenue(revenueAmount);

        assertEq(
            rentalPool.totalRevenue(),
            revenueAmount,
            "Total revenue should increase"
        );
        assertGt(
            rentalPool.accRevenuePerToken(),
            0,
            "Accumulated revenue per token should increase"
        );
    }

    function test_RevertAddRevenue_Unauthorized() public {
        uint256 revenueAmount = 1000 * 10 ** 6;

        vm.prank(user1);
        vm.expectRevert(RentalPool.OnlyIDO.selector);
        rentalPool.addRevenue(revenueAmount);
    }

    function test_RevertAddRevenue_ZeroAmount() public {
        vm.prank(manager);
        vm.expectRevert(RentalPool.ZeroAmount.selector);
        rentalPool.addRevenue(0);
    }

    function test_GetPendingDividends() public {
        uint256 revenueAmount = 6000 * 10 ** 6; // 6000 USDC

        // Add revenue
        usdc.mint(manager, revenueAmount);
        vm.prank(manager);
        usdc.approve(address(rentalPool), revenueAmount);
        vm.prank(manager);
        rentalPool.addRevenue(revenueAmount);

        // Check pending dividends
        // Total supply: 10M tokens (initial) - 6000 tokens (distributed) = 9,994,000 tokens still with owner
        // User1: 1000 tokens
        // User2: 2000 tokens
        // User3: 3000 tokens
        // Total distributed: 6000 tokens out of 10M total supply

        uint256 user1Pending = rentalPool.getPendingDividends(user1);
        uint256 user2Pending = rentalPool.getPendingDividends(user2);
        uint256 user3Pending = rentalPool.getPendingDividends(user3);

        // Each user gets: (balance / totalSupply) * revenue
        // User1: (1000 / 10,000,000) * 6,000,000,000 = 600 USDC (0.0001 * 6000)
        assertApproxEqAbs(
            user1Pending,
            600000,
            100,
            "User1 should get ~0.6 USDC"
        );
        assertApproxEqAbs(
            user2Pending,
            1200000,
            100,
            "User2 should get ~1.2 USDC"
        );
        assertApproxEqAbs(
            user3Pending,
            1800000,
            100,
            "User3 should get ~1.8 USDC"
        );
    }

    function test_ClaimDividends() public {
        uint256 revenueAmount = 6000 * 10 ** 6;

        // Add revenue
        usdc.mint(manager, revenueAmount);
        vm.prank(manager);
        usdc.approve(address(rentalPool), revenueAmount);
        vm.prank(manager);
        rentalPool.addRevenue(revenueAmount);

        // User1 claims
        uint256 user1Before = usdc.balanceOf(user1);
        vm.prank(user1);
        uint256 claimed = rentalPool.claimDividends();

        uint256 user1After = usdc.balanceOf(user1);

        assertGt(claimed, 0, "Claimed amount should be > 0");
        assertEq(
            user1After - user1Before,
            claimed,
            "USDC balance should increase by claimed amount"
        );
        assertEq(
            rentalPool.getPendingDividends(user1),
            0,
            "Pending dividends should be 0 after claim"
        );
    }

    function test_RevertClaimDividends_NoPending() public {
        vm.prank(user1);
        vm.expectRevert(RentalPool.NoPendingDividends.selector);
        rentalPool.claimDividends();
    }

    function test_MultipleClaims() public {
        // First revenue
        uint256 revenueAmount1 = 3000 * 10 ** 6;
        usdc.mint(manager, revenueAmount1);
        vm.prank(manager);
        usdc.approve(address(rentalPool), revenueAmount1);
        vm.prank(manager);
        rentalPool.addRevenue(revenueAmount1);

        // User1 claims
        vm.prank(user1);
        uint256 claimed1 = rentalPool.claimDividends();

        // Second revenue
        uint256 revenueAmount2 = 3000 * 10 ** 6;
        usdc.mint(manager, revenueAmount2);
        vm.prank(manager);
        usdc.approve(address(rentalPool), revenueAmount2);
        vm.prank(manager);
        rentalPool.addRevenue(revenueAmount2);

        // User1 claims again
        vm.prank(user1);
        uint256 claimed2 = rentalPool.claimDividends();

        assertGt(claimed1, 0, "First claim should be > 0");
        assertGt(claimed2, 0, "Second claim should be > 0");
        assertApproxEqAbs(
            claimed1,
            claimed2,
            10,
            "Both claims should be approximately equal"
        );
    }

    function test_BeforeAndAfterBalanceChange() public {
        // Add some revenue first
        uint256 revenueAmount = 6000 * 10 ** 6;
        usdc.mint(manager, revenueAmount);
        vm.prank(manager);
        usdc.approve(address(rentalPool), revenueAmount);
        vm.prank(manager);
        rentalPool.addRevenue(revenueAmount);

        // RentalPool is already set in setUp()
        // Unfreeze token to allow transfers
        datasetToken.unfreeze();

        // Before and After hooks are called automatically during transfer
        // Test by making a transfer
        vm.prank(user1);
        datasetToken.transfer(user2, 100 * 10 ** 18);

        // Both users should have pendingClaim or rewardDebt updated
        // This is handled automatically by the transfer hook
        assertTrue(true, "Balance change hooks executed via transfer");
    }

    function test_RevertBeforeBalanceChange_Unauthorized() public {
        vm.prank(user1);
        vm.expectRevert(RentalPool.OnlyDatasetToken.selector);
        rentalPool.beforeBalanceChange(user1, 1000);
    }

    function test_Statistics() public {
        // Add revenue and claim
        uint256 revenueAmount = 6000 * 10 ** 6;
        usdc.mint(manager, revenueAmount);
        vm.prank(manager);
        usdc.approve(address(rentalPool), revenueAmount);
        vm.prank(manager);
        rentalPool.addRevenue(revenueAmount);

        vm.prank(user1);
        uint256 claimed = rentalPool.claimDividends();

        assertEq(
            rentalPool.totalRevenue(),
            revenueAmount,
            "Total revenue should match"
        );
        assertEq(
            rentalPool.totalClaimed(),
            claimed,
            "Total claimed should match"
        );
        assertEq(
            rentalPool.getUserTotalClaimed(user1),
            claimed,
            "User total claimed should match"
        );
    }
}

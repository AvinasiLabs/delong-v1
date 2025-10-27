// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./TestBase.sol";

contract RentalManagerTest is DeLongTestBase {
    address public lpToken;
    uint256 constant HOURLY_RATE = 10 * 10 ** 6; // 10 USDC per hour

    function setUp() public override {
        super.setUp();

        // Deploy core contracts
        datasetToken = new DatasetToken();
        datasetToken.initialize(
            "Test Dataset",
            "TDS",
            owner,
            owner, // owner acts as IDO - tokens minted directly to owner
            10_000_000 * 10 ** 18
        );

        datasetManager = new DatasetManager();
        datasetManager.initialize(
            address(datasetToken),
            projectAddress,
            owner,
            "ipfs://test"
        );
        rentalPool = new RentalPool();
        rentalPool.initialize(
            address(usdc),
            address(datasetToken),
            owner
        );
        rentalManager = new RentalManager(address(usdc), owner);

        // Setup relationships
        datasetToken.setRentalPool(address(rentalPool));
        datasetToken.setDatasetManager(address(datasetManager));
        datasetManager.setRentalManager(address(rentalManager));
        rentalPool.setAuthorizedManager(address(rentalManager), true);

        // Configure RentalManager
        rentalManager.setRentalPool(address(rentalPool));
        rentalManager.setProtocolTreasury(protocolTreasury);
        rentalManager.setDatasetManager(address(datasetManager));
        rentalManager.updatePrice(address(datasetToken), HOURLY_RATE);
        rentalManager.setAuthorizedBackend(backend, true);

        // Fund users
        usdc.mint(user1, 10000 * 10 ** 6);
        usdc.mint(user2, 10000 * 10 ** 6);

        // Create mock LP token
        lpToken = makeAddr("lpToken");

        vm.label(address(rentalManager), "RentalManager");
    }

    function test_InitialState() public view {
        assertEq(
            address(rentalManager.usdc()),
            address(usdc),
            "USDC should match"
        );
        assertEq(
            rentalManager.rentalPool(),
            address(rentalPool),
            "RentalPool should match"
        );
        assertEq(
            rentalManager.protocolTreasury(),
            protocolTreasury,
            "ProtocolTreasury should match"
        );
        assertEq(
            rentalManager.hourlyRate(address(datasetToken)),
            HOURLY_RATE,
            "Hourly rate should match"
        );
    }

    function test_PurchaseAccess() public {
        uint256 hoursCount = 5;
        uint256 totalCost = HOURLY_RATE * hoursCount;

        // Approve USDC
        vm.prank(user1);
        usdc.approve(address(rentalManager), totalCost);

        // Purchase access
        vm.prank(user1);
        rentalManager.purchaseAccess(address(datasetToken), hoursCount);

        // Verify rental record
        (
            address user,
            uint256 paidAmount,
            uint256 hoursQuota,
            uint256 usedMinutes,
            uint256 purchasedAt,
            bool isActive
        ) = rentalManager.userRentals(user1, address(datasetToken), 0);

        assertEq(user, user1, "User should match");
        assertEq(paidAmount, totalCost, "Paid amount should match");
        assertEq(hoursQuota, hoursCount, "Hours quota should match");
        assertEq(usedMinutes, 0, "Used minutes should be 0");
        assertTrue(isActive, "Rental should be active");
    }

    function test_PurchaseAccessDistribution() public {
        uint256 hoursCount = 10;
        uint256 totalCost = HOURLY_RATE * hoursCount; // 100 USDC

        uint256 protocolBefore = usdc.balanceOf(protocolTreasury);

        // Approve and purchase
        vm.prank(user1);
        usdc.approve(address(rentalManager), totalCost);
        vm.prank(user1);
        rentalManager.purchaseAccess(address(datasetToken), hoursCount);

        // Check distributions
        uint256 protocolFee = (totalCost * 500) / 10000; // 5%
        uint256 dividend = totalCost - protocolFee; // 95%

        uint256 protocolAfter = usdc.balanceOf(protocolTreasury);
        assertEq(
            protocolAfter - protocolBefore,
            protocolFee,
            "Protocol should receive 5%"
        );

        // Check rental pool received dividends
        assertEq(
            rentalPool.totalRevenue(),
            dividend,
            "RentalPool should receive 95%"
        );
    }

    function test_RevertPurchaseAccess_ZeroHours() public {
        vm.prank(user1);
        vm.expectRevert(RentalManager.ZeroAmount.selector);
        rentalManager.purchaseAccess(address(datasetToken), 0);
    }

    function test_RevertPurchaseAccess_InvalidPrice() public {
        address unknownDataset = makeAddr("unknownDataset");

        vm.prank(user1);
        vm.expectRevert(RentalManager.InvalidPrice.selector);
        rentalManager.purchaseAccess(unknownDataset, 5);
    }

    function test_RecordUsage() public {
        // Purchase access first
        uint256 hoursCount = 5;
        uint256 totalCost = HOURLY_RATE * hoursCount;

        vm.prank(user1);
        usdc.approve(address(rentalManager), totalCost);
        vm.prank(user1);
        rentalManager.purchaseAccess(address(datasetToken), hoursCount);

        // Record usage
        uint256 usedMinutes = 60; // 1 hour
        vm.prank(backend);
        rentalManager.recordUsage(
            user1,
            address(datasetToken),
            0,
            usedMinutes,
            ""
        );

        // Check updated usage
        (, , , uint256 recordedMinutes, , bool isActive) = rentalManager
            .userRentals(user1, address(datasetToken), 0);

        assertEq(
            recordedMinutes,
            usedMinutes,
            "Used minutes should be recorded"
        );
        assertTrue(isActive, "Should still be active");
    }

    function test_RecordUsageExhaustsQuota() public {
        // Purchase 2 hours
        uint256 hoursCount = 2;
        uint256 totalCost = HOURLY_RATE * hoursCount;

        vm.prank(user1);
        usdc.approve(address(rentalManager), totalCost);
        vm.prank(user1);
        rentalManager.purchaseAccess(address(datasetToken), hoursCount);

        // Use exactly 2 hours (120 minutes)
        vm.prank(backend);
        rentalManager.recordUsage(user1, address(datasetToken), 0, 120, "");

        // Check rental is inactive
        (, , , uint256 recordedMinutes, , bool isActive) = rentalManager
            .userRentals(user1, address(datasetToken), 0);

        assertEq(recordedMinutes, 120, "Should have used 120 minutes");
        assertFalse(isActive, "Should be inactive after quota exhausted");
    }

    function test_RevertRecordUsage_Unauthorized() public {
        vm.prank(user1);
        vm.expectRevert(RentalManager.Unauthorized.selector);
        rentalManager.recordUsage(user1, address(datasetToken), 0, 60, "");
    }

    function test_RevertRecordUsage_QuotaExceeded() public {
        // Purchase 1 hour
        uint256 totalCost = HOURLY_RATE;
        vm.prank(user1);
        usdc.approve(address(rentalManager), totalCost);
        vm.prank(user1);
        rentalManager.purchaseAccess(address(datasetToken), 1);

        // Try to use more than 60 minutes
        vm.prank(backend);
        vm.expectRevert(RentalManager.QuotaExceeded.selector);
        rentalManager.recordUsage(user1, address(datasetToken), 0, 61, "");
    }

    function test_GetActiveRentals() public {
        // Purchase multiple times
        vm.startPrank(user1);
        usdc.approve(address(rentalManager), 1000 * 10 ** 6);

        rentalManager.purchaseAccess(address(datasetToken), 1);
        rentalManager.purchaseAccess(address(datasetToken), 2);
        vm.stopPrank();

        // Exhaust first rental
        vm.prank(backend);
        rentalManager.recordUsage(user1, address(datasetToken), 0, 60, "");

        // Get active rentals
        RentalManager.Rental[] memory activeRentals = rentalManager
            .getActiveRentals(user1, address(datasetToken));

        assertEq(activeRentals.length, 1, "Should have 1 active rental");
        assertEq(
            activeRentals[0].hoursQuota,
            2,
            "Active rental should be the 2-hour one"
        );
    }

    function test_UpdatePrice() public {
        uint256 newPrice = 20 * 10 ** 6; // 20 USDC

        rentalManager.updatePrice(address(datasetToken), newPrice);

        assertEq(
            rentalManager.hourlyRate(address(datasetToken)),
            newPrice,
            "Price should be updated"
        );
    }

    function test_RevertUpdatePrice_ZeroPrice() public {
        vm.expectRevert(RentalManager.InvalidPrice.selector);
        rentalManager.updatePrice(address(datasetToken), 0);
    }

    function test_AccumulatedRevenue() public {
        // Purchase access to accumulate revenue
        uint256 totalCost = HOURLY_RATE * 10; // 100 USDC

        vm.prank(user1);
        usdc.approve(address(rentalManager), totalCost);
        vm.prank(user1);
        rentalManager.purchaseAccess(address(datasetToken), 10);

        // Check accumulated revenue (should be 100% of rental, not just 95%)
        assertEq(
            rentalManager.accumulatedRevenue(address(datasetToken)),
            totalCost,
            "Accumulated revenue should be 100% of rental"
        );
    }

    function test_TotalCollected() public {
        uint256 cost1 = HOURLY_RATE * 5;
        uint256 cost2 = HOURLY_RATE * 3;

        // User1 purchases
        vm.prank(user1);
        usdc.approve(address(rentalManager), cost1);
        vm.prank(user1);
        rentalManager.purchaseAccess(address(datasetToken), 5);

        // User2 purchases
        vm.prank(user2);
        usdc.approve(address(rentalManager), cost2);
        vm.prank(user2);
        rentalManager.purchaseAccess(address(datasetToken), 3);

        assertEq(
            rentalManager.totalCollected(address(datasetToken)),
            cost1 + cost2,
            "Total collected should be sum of all purchases"
        );
    }

    function test_SetRentalPool() public {
        RentalManager newManager = new RentalManager(address(usdc), owner);
        address newPool = makeAddr("newPool");

        newManager.setRentalPool(newPool);
        assertEq(newManager.rentalPool(), newPool, "RentalPool should be set");
    }

    function test_RevertSetRentalPool_AlreadySet() public {
        address newPool = makeAddr("newPool");

        vm.expectRevert(RentalManager.AlreadySet.selector);
        rentalManager.setRentalPool(newPool);
    }

    function test_SetProtocolTreasury() public {
        RentalManager newManager = new RentalManager(address(usdc), owner);
        address newTreasury = makeAddr("newTreasury");

        newManager.setProtocolTreasury(newTreasury);
        assertEq(
            newManager.protocolTreasury(),
            newTreasury,
            "ProtocolTreasury should be set"
        );
    }

    function test_SetDatasetManager() public {
        RentalManager newManager = new RentalManager(address(usdc), owner);
        address newManager_ = makeAddr("newManager");

        newManager.setDatasetManager(newManager_);
        assertEq(
            newManager.datasetManager(),
            newManager_,
            "DatasetManager should be set"
        );
    }

    function test_SetAuthorizedBackend() public {
        address newBackend = makeAddr("newBackend");

        rentalManager.setAuthorizedBackend(newBackend, true);
        assertTrue(
            rentalManager.authorizedBackends(newBackend),
            "Backend should be authorized"
        );

        rentalManager.setAuthorizedBackend(newBackend, false);
        assertFalse(
            rentalManager.authorizedBackends(newBackend),
            "Backend should be deauthorized"
        );
    }
}

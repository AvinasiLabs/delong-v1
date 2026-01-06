// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./TestBase.sol";
import "../src/RentalOnly.sol";

/**
 * @title RentalOnlyTest
 * @notice Unit tests for RentalOnly contract
 */
contract RentalOnlyTest is DeLongTestBase {
    // Re-declare events for testing
    event AccessPurchased(
        address indexed user,
        uint256 hoursCount,
        uint256 cost,
        uint256 expiresAt
    );
    event HourlyRateUpdated(uint256 oldRate, uint256 newRate);
    event MetadataUpdated(string newURI, uint256 version);
    event Withdrawn(address indexed owner, uint256 amount);
    event Deactivated();
    RentalOnly public rentalOnly;
    RentalOnly public rentalOnlyImpl;

    uint256 constant HOURLY_RATE = 10e6; // 10 USDC per hour
    string constant METADATA_URI = "ipfs://QmTest123";

    function setUp() public override {
        super.setUp();

        // Deploy implementations
        DatasetToken tokenImpl = new DatasetToken();
        RentalPool poolImpl = new RentalPool();
        IDO idoImpl = new IDO();
        Governance governanceImpl = new Governance();
        rentalOnlyImpl = new RentalOnly();

        // Deploy Factory
        factory = new Factory(
            address(usdc),
            owner,
            address(tokenImpl),
            address(poolImpl),
            address(idoImpl),
            address(governanceImpl)
        );

        // Configure Factory
        address uniswapRouter = makeAddr("uniswapRouter");
        address uniswapFactory = makeAddr("uniswapFactory");
        factory.configure(feeTo, uniswapRouter, uniswapFactory);

        // Set RentalOnly implementation
        factory.setRentalOnlyImplementation(address(rentalOnlyImpl));

        // Deploy RentalOnly via Factory
        (, address rentalOnlyAddr) = factory.deployRentalOnly(
            projectAddress,
            METADATA_URI,
            HOURLY_RATE
        );
        rentalOnly = RentalOnly(rentalOnlyAddr);

        vm.label(address(rentalOnly), "RentalOnly");
    }

    // ========== Initialization Tests ==========

    function test_InitialState() public view {
        assertEq(rentalOnly.owner(), projectAddress);
        assertEq(rentalOnly.usdcToken(), address(usdc));
        assertEq(rentalOnly.feeTo(), feeTo);
        assertEq(rentalOnly.metadataURI(), METADATA_URI);
        assertEq(rentalOnly.hourlyRate(), HOURLY_RATE);
        assertTrue(rentalOnly.isActive());
    }

    function test_InitialMetadataHistory() public view {
        assertEq(rentalOnly.getMetadataHistoryLength(), 1);
        (string memory uri, uint256 timestamp) = rentalOnly.metadataHistory(0);
        assertEq(uri, METADATA_URI);
        assertGt(timestamp, 0);
    }

    function test_InitialBalances() public view {
        assertEq(rentalOnly.pendingWithdrawal(), 0);
        assertEq(rentalOnly.totalRentalCollected(), 0);
    }

    // ========== purchaseAccess Tests ==========

    function test_PurchaseAccess() public {
        uint256 hoursCount = 24;
        uint256 expectedCost = HOURLY_RATE * hoursCount;

        approveUSDC(user1, address(rentalOnly), expectedCost);

        uint256 user1BalanceBefore = getUSDCBalance(user1);

        vm.prank(user1);
        rentalOnly.purchaseAccess(hoursCount);

        // Check user spent correct amount
        assertEq(getUSDCBalance(user1), user1BalanceBefore - expectedCost);

        // Check access expiration is set correctly
        uint256 expectedExpiry = block.timestamp + hoursCount * 1 hours;
        assertEq(rentalOnly.accessExpiresAt(user1), expectedExpiry);

        // Check hasAccess returns true
        assertTrue(rentalOnly.hasAccess(user1));
    }

    function test_PurchaseAccessMultipleTimes() public {
        uint256 hoursCount1 = 10;
        uint256 hoursCount2 = 5;
        uint256 cost1 = HOURLY_RATE * hoursCount1;
        uint256 cost2 = HOURLY_RATE * hoursCount2;

        approveUSDC(user1, address(rentalOnly), cost1 + cost2);

        vm.prank(user1);
        rentalOnly.purchaseAccess(hoursCount1);

        uint256 firstExpiry = rentalOnly.accessExpiresAt(user1);

        vm.prank(user1);
        rentalOnly.purchaseAccess(hoursCount2);

        // Second purchase should extend from first expiry
        uint256 secondExpiry = rentalOnly.accessExpiresAt(user1);
        assertEq(secondExpiry, firstExpiry + hoursCount2 * 1 hours);
    }

    function test_PurchaseAccessExtendExpired() public {
        uint256 hoursCount = 1;
        uint256 cost = HOURLY_RATE * hoursCount;

        approveUSDC(user1, address(rentalOnly), cost * 2);

        vm.prank(user1);
        rentalOnly.purchaseAccess(hoursCount);

        // Fast forward past expiration
        advanceTime(2 hours);
        assertFalse(rentalOnly.hasAccess(user1));

        // Purchase again - should start from current time
        vm.prank(user1);
        rentalOnly.purchaseAccess(hoursCount);

        uint256 newExpiry = rentalOnly.accessExpiresAt(user1);
        assertEq(newExpiry, block.timestamp + hoursCount * 1 hours);
    }

    function test_PurchaseAccessFeeDistribution() public {
        uint256 hoursCount = 100;
        uint256 totalCost = HOURLY_RATE * hoursCount;
        uint256 expectedProtocolFee = (totalCost * 500) / 10000; // 5%
        uint256 expectedOwnerShare = totalCost - expectedProtocolFee;

        approveUSDC(user1, address(rentalOnly), totalCost);

        uint256 feeToBalanceBefore = getUSDCBalance(feeTo);

        vm.prank(user1);
        rentalOnly.purchaseAccess(hoursCount);

        // Check protocol fee transferred
        assertEq(getUSDCBalance(feeTo), feeToBalanceBefore + expectedProtocolFee);

        // Check owner share accumulated
        assertEq(rentalOnly.pendingWithdrawal(), expectedOwnerShare);

        // Check total rental collected
        assertEq(rentalOnly.totalRentalCollected(), totalCost);
    }

    function test_RevertPurchaseAccess_ZeroHours() public {
        vm.prank(user1);
        vm.expectRevert(RentalOnly.HoursMustBePositive.selector);
        rentalOnly.purchaseAccess(0);
    }

    function test_RevertPurchaseAccess_Deactivated() public {
        vm.prank(projectAddress);
        rentalOnly.deactivate();

        approveUSDC(user1, address(rentalOnly), HOURLY_RATE);

        vm.prank(user1);
        vm.expectRevert(RentalOnly.ContractDeactivated.selector);
        rentalOnly.purchaseAccess(1);
    }

    function test_RevertPurchaseAccess_InsufficientAllowance() public {
        // Don't approve any USDC
        vm.prank(user1);
        vm.expectRevert();
        rentalOnly.purchaseAccess(1);
    }

    // ========== withdraw Tests ==========

    function test_Withdraw() public {
        uint256 hoursCount = 50;
        uint256 totalCost = HOURLY_RATE * hoursCount;
        uint256 expectedOwnerShare = (totalCost * 9500) / 10000; // 95%

        approveUSDC(user1, address(rentalOnly), totalCost);

        vm.prank(user1);
        rentalOnly.purchaseAccess(hoursCount);

        uint256 ownerBalanceBefore = getUSDCBalance(projectAddress);

        vm.prank(projectAddress);
        rentalOnly.withdraw();

        // Check owner received funds
        assertEq(getUSDCBalance(projectAddress), ownerBalanceBefore + expectedOwnerShare);

        // Check pending withdrawal is zero
        assertEq(rentalOnly.pendingWithdrawal(), 0);
    }

    function test_WithdrawMultipleRentals() public {
        uint256 hours1 = 10;
        uint256 hours2 = 20;
        uint256 cost1 = HOURLY_RATE * hours1;
        uint256 cost2 = HOURLY_RATE * hours2;
        uint256 totalCost = cost1 + cost2;
        uint256 expectedOwnerShare = (totalCost * 9500) / 10000;

        // User1 purchases
        approveUSDC(user1, address(rentalOnly), cost1);
        vm.prank(user1);
        rentalOnly.purchaseAccess(hours1);

        // User2 purchases
        approveUSDC(user2, address(rentalOnly), cost2);
        vm.prank(user2);
        rentalOnly.purchaseAccess(hours2);

        uint256 ownerBalanceBefore = getUSDCBalance(projectAddress);

        // Single withdrawal
        vm.prank(projectAddress);
        rentalOnly.withdraw();

        assertEq(getUSDCBalance(projectAddress), ownerBalanceBefore + expectedOwnerShare);
    }

    function test_RevertWithdraw_NotOwner() public {
        vm.prank(user1);
        vm.expectRevert(RentalOnly.NotOwner.selector);
        rentalOnly.withdraw();
    }

    function test_RevertWithdraw_NothingToWithdraw() public {
        vm.prank(projectAddress);
        vm.expectRevert(RentalOnly.NothingToWithdraw.selector);
        rentalOnly.withdraw();
    }

    // ========== updateHourlyRate Tests ==========

    function test_UpdateHourlyRate() public {
        uint256 newRate = 20e6; // 20 USDC

        vm.prank(projectAddress);
        rentalOnly.updateHourlyRate(newRate);

        assertEq(rentalOnly.hourlyRate(), newRate);
    }

    function test_RevertUpdateHourlyRate_NotOwner() public {
        vm.prank(user1);
        vm.expectRevert(RentalOnly.NotOwner.selector);
        rentalOnly.updateHourlyRate(20e6);
    }

    function test_RevertUpdateHourlyRate_Deactivated() public {
        vm.prank(projectAddress);
        rentalOnly.deactivate();

        vm.prank(projectAddress);
        vm.expectRevert(RentalOnly.ContractDeactivated.selector);
        rentalOnly.updateHourlyRate(20e6);
    }

    // ========== updateMetadata Tests ==========

    function test_UpdateMetadata() public {
        string memory newURI = "ipfs://QmNewMetadata456";

        vm.prank(projectAddress);
        rentalOnly.updateMetadata(newURI);

        assertEq(rentalOnly.metadataURI(), newURI);
        assertEq(rentalOnly.getMetadataHistoryLength(), 2);
    }

    function test_UpdateMetadataMultipleTimes() public {
        string memory uri1 = "ipfs://QmVersion1";
        string memory uri2 = "ipfs://QmVersion2";
        string memory uri3 = "ipfs://QmVersion3";

        vm.startPrank(projectAddress);
        rentalOnly.updateMetadata(uri1);
        rentalOnly.updateMetadata(uri2);
        rentalOnly.updateMetadata(uri3);
        vm.stopPrank();

        assertEq(rentalOnly.metadataURI(), uri3);
        assertEq(rentalOnly.getMetadataHistoryLength(), 4); // original + 3 updates

        // Verify history is preserved
        (string memory historyUri0, ) = rentalOnly.metadataHistory(0);
        (string memory historyUri1, ) = rentalOnly.metadataHistory(1);
        (string memory historyUri2, ) = rentalOnly.metadataHistory(2);
        (string memory historyUri3, ) = rentalOnly.metadataHistory(3);

        assertEq(historyUri0, METADATA_URI);
        assertEq(historyUri1, uri1);
        assertEq(historyUri2, uri2);
        assertEq(historyUri3, uri3);
    }

    function test_RevertUpdateMetadata_NotOwner() public {
        vm.prank(user1);
        vm.expectRevert(RentalOnly.NotOwner.selector);
        rentalOnly.updateMetadata("ipfs://QmNew");
    }

    function test_RevertUpdateMetadata_Deactivated() public {
        vm.prank(projectAddress);
        rentalOnly.deactivate();

        vm.prank(projectAddress);
        vm.expectRevert(RentalOnly.ContractDeactivated.selector);
        rentalOnly.updateMetadata("ipfs://QmNew");
    }

    // ========== deactivate Tests ==========

    function test_Deactivate() public {
        vm.prank(projectAddress);
        rentalOnly.deactivate();

        assertFalse(rentalOnly.isActive());
    }

    function test_DeactivateAllowsWithdraw() public {
        // Purchase some access first
        uint256 hoursCount = 10;
        uint256 cost = HOURLY_RATE * hoursCount;
        approveUSDC(user1, address(rentalOnly), cost);

        vm.prank(user1);
        rentalOnly.purchaseAccess(hoursCount);

        // Deactivate
        vm.prank(projectAddress);
        rentalOnly.deactivate();

        // Owner should still be able to withdraw
        uint256 ownerBalanceBefore = getUSDCBalance(projectAddress);
        uint256 expectedAmount = rentalOnly.pendingWithdrawal();

        vm.prank(projectAddress);
        rentalOnly.withdraw();

        assertEq(getUSDCBalance(projectAddress), ownerBalanceBefore + expectedAmount);
    }

    function test_RevertDeactivate_AlreadyDeactivated() public {
        vm.prank(projectAddress);
        rentalOnly.deactivate();

        vm.prank(projectAddress);
        vm.expectRevert(RentalOnly.AlreadyDeactivated.selector);
        rentalOnly.deactivate();
    }

    // ========== hasAccess Tests ==========

    function test_HasAccess_Valid() public {
        approveUSDC(user1, address(rentalOnly), HOURLY_RATE * 24);

        vm.prank(user1);
        rentalOnly.purchaseAccess(24);

        assertTrue(rentalOnly.hasAccess(user1));
    }

    function test_HasAccess_Expired() public {
        approveUSDC(user1, address(rentalOnly), HOURLY_RATE);

        vm.prank(user1);
        rentalOnly.purchaseAccess(1);

        // Fast forward past expiration
        advanceTime(2 hours);

        assertFalse(rentalOnly.hasAccess(user1));
    }

    function test_HasAccess_NeverPurchased() public view {
        assertFalse(rentalOnly.hasAccess(user1));
    }

    // ========== Event Tests ==========

    function test_EmitAccessPurchased() public {
        uint256 hoursCount = 5;
        uint256 cost = HOURLY_RATE * hoursCount;
        uint256 expectedExpiry = block.timestamp + hoursCount * 1 hours;

        approveUSDC(user1, address(rentalOnly), cost);

        vm.expectEmit(true, false, false, true);
        emit AccessPurchased(user1, hoursCount, cost, expectedExpiry);

        vm.prank(user1);
        rentalOnly.purchaseAccess(hoursCount);
    }

    function test_EmitHourlyRateUpdated() public {
        uint256 newRate = 25e6;

        vm.expectEmit(false, false, false, true);
        emit HourlyRateUpdated(HOURLY_RATE, newRate);

        vm.prank(projectAddress);
        rentalOnly.updateHourlyRate(newRate);
    }

    function test_EmitMetadataUpdated() public {
        string memory newURI = "ipfs://QmNewURI";

        vm.expectEmit(false, false, false, true);
        emit MetadataUpdated(newURI, 2);

        vm.prank(projectAddress);
        rentalOnly.updateMetadata(newURI);
    }

    function test_EmitWithdrawn() public {
        // Setup: user purchases access
        uint256 hoursCount = 10;
        uint256 cost = HOURLY_RATE * hoursCount;
        uint256 expectedAmount = (cost * 9500) / 10000;

        approveUSDC(user1, address(rentalOnly), cost);
        vm.prank(user1);
        rentalOnly.purchaseAccess(hoursCount);

        vm.expectEmit(true, false, false, true);
        emit Withdrawn(projectAddress, expectedAmount);

        vm.prank(projectAddress);
        rentalOnly.withdraw();
    }

    function test_EmitDeactivated() public {
        vm.expectEmit(false, false, false, false);
        emit Deactivated();

        vm.prank(projectAddress);
        rentalOnly.deactivate();
    }
}

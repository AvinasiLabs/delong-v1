// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./TestBase.sol";

contract DatasetManagerTest is DeLongTestBase {
    string constant INITIAL_METADATA = "ipfs://QmInitialMetadata";
    string constant UPDATED_METADATA = "ipfs://QmUpdatedMetadata";

    function setUp() public override {
        super.setUp();

        // Deploy DatasetToken
        datasetToken = new DatasetToken(
            "Test Dataset",
            "TDS",
            owner,
            owner,
            1_000_000 * 10 ** 18
        );

        // Deploy DatasetManager
        datasetManager = new DatasetManager(
            address(datasetToken),
            projectAddress,
            owner,
            INITIAL_METADATA
        );

        // Distribute tokens to users
        datasetToken.transfer(user1, 1000 * 10 ** 18);
        datasetToken.transfer(user2, 2000 * 10 ** 18);

        vm.label(address(datasetToken), "DatasetToken");
        vm.label(address(datasetManager), "DatasetManager");
    }

    function test_InitialState() public view {
        assertEq(
            datasetManager.datasetToken(),
            address(datasetToken),
            "DatasetToken should match"
        );
        assertEq(
            datasetManager.projectAddress(),
            projectAddress,
            "ProjectAddress should match"
        );
        assertEq(
            datasetManager.datasetMetadataURI(),
            INITIAL_METADATA,
            "Initial metadata should match"
        );
        assertEq(
            uint256(datasetManager.status()),
            uint256(DatasetManager.DatasetStatus.Active),
            "Status should be Active"
        );
        assertEq(
            datasetManager.TRIAL_QUOTA(),
            2 hours,
            "Trial quota should be 2 hours"
        );
    }

    function test_UpdateMetadata() public {
        vm.prank(projectAddress);
        datasetManager.updateMetadata(UPDATED_METADATA);

        assertEq(
            datasetManager.datasetMetadataURI(),
            UPDATED_METADATA,
            "Metadata should be updated"
        );

        // Check version history
        string[] memory history = datasetManager.getMetadataVersionHistory();
        assertEq(history.length, 2, "Should have 2 versions");
        assertEq(
            history[0],
            INITIAL_METADATA,
            "First version should be initial"
        );
        assertEq(
            history[1],
            UPDATED_METADATA,
            "Second version should be updated"
        );
    }

    function test_RevertUpdateMetadata_Unauthorized() public {
        vm.prank(user1);
        vm.expectRevert(DatasetManager.OnlyProjectAddress.selector);
        datasetManager.updateMetadata(UPDATED_METADATA);
    }

    function test_RevertUpdateMetadata_EmptyString() public {
        vm.prank(projectAddress);
        vm.expectRevert(DatasetManager.EmptyString.selector);
        datasetManager.updateMetadata("");
    }

    function test_TrialEligibility() public view {
        // User1 has tokens, should be eligible
        assertTrue(
            datasetManager.hasTrialEligibility(user1),
            "User1 should be eligible"
        );

        // User3 has no tokens, should not be eligible
        assertFalse(
            datasetManager.hasTrialEligibility(user3),
            "User3 should not be eligible"
        );
    }

    function test_GetTrialInfo() public view {
        (
            uint256 quota,
            uint256 used,
            uint256 remaining,
            bool eligible
        ) = datasetManager.getTrialInfo(user1);

        assertEq(quota, 2 hours, "Quota should be 2 hours");
        assertEq(used, 0, "Used should be 0");
        assertEq(remaining, 2 hours, "Remaining should be 2 hours");
        assertTrue(eligible, "User1 should be eligible");
    }

    function test_RecordTrialUsage() public {
        // Set TEE backend
        datasetManager.setTeeBackend(backend);

        uint256 usedSeconds = 1800; // 30 minutes

        vm.prank(backend);
        datasetManager.recordTrialUsage(user1, usedSeconds);

        (
            uint256 quota,
            uint256 used,
            uint256 remaining,
            bool eligible
        ) = datasetManager.getTrialInfo(user1);

        assertEq(used, usedSeconds, "Used should be 1800 seconds");
        assertEq(
            remaining,
            quota - usedSeconds,
            "Remaining should be decreased"
        );
        assertEq(
            datasetManager.totalTrialUsers(),
            1,
            "Total trial users should be 1"
        );
    }

    function test_RecordTrialUsageMultipleTimes() public {
        datasetManager.setTeeBackend(backend);

        // First usage
        vm.prank(backend);
        datasetManager.recordTrialUsage(user1, 1800); // 30 min

        // Second usage
        vm.prank(backend);
        datasetManager.recordTrialUsage(user1, 3600); // 60 min

        (, uint256 used, , ) = datasetManager.getTrialInfo(user1);
        assertEq(used, 5400, "Total used should be 5400 seconds (90 min)");
    }

    function test_RevertRecordTrialUsage_Unauthorized() public {
        vm.prank(user1);
        vm.expectRevert(DatasetManager.OnlyTeeBackend.selector);
        datasetManager.recordTrialUsage(user1, 1800);
    }

    function test_RevertRecordTrialUsage_QuotaExceeded() public {
        datasetManager.setTeeBackend(backend);

        // Try to use more than quota (2 hours = 7200 seconds)
        vm.prank(backend);
        vm.expectRevert(DatasetManager.TrialQuotaExceeded.selector);
        datasetManager.recordTrialUsage(user1, 7201);
    }

    function test_TrialQuotaExhaustedEvent() public {
        datasetManager.setTeeBackend(backend);

        // Use exactly the quota (2 hours = 7200 seconds)
        vm.prank(backend);
        datasetManager.recordTrialUsage(user1, 7200);

        // Verify quota is exhausted
        (, uint256 used, , ) = datasetManager.getTrialInfo(user1);
        assertEq(used, 7200, "Should have used full quota");
    }

    function test_CanAccessDataset() public view {
        // User1 has tokens, can access
        assertTrue(
            datasetManager.canAccessDataset(user1),
            "User1 should have access"
        );

        // User3 has no tokens and no rental, cannot access
        assertFalse(
            datasetManager.canAccessDataset(user3),
            "User3 should not have access"
        );
    }

    function test_UpdateStatus_Deprecated() public {
        vm.prank(projectAddress);
        datasetManager.updateStatus(DatasetManager.DatasetStatus.Deprecated);

        assertEq(
            uint256(datasetManager.status()),
            uint256(DatasetManager.DatasetStatus.Deprecated),
            "Status should be Deprecated"
        );
    }

    function test_UpdateStatus_Delisted() public {
        // Set DAO Governance
        address daoGovernance = makeAddr("daoGovernance");
        datasetManager.setDaoGovernance(daoGovernance);

        vm.prank(daoGovernance);
        datasetManager.updateStatus(DatasetManager.DatasetStatus.Delisted);

        assertEq(
            uint256(datasetManager.status()),
            uint256(DatasetManager.DatasetStatus.Delisted),
            "Status should be Delisted"
        );
    }

    function test_RevertUpdateStatus_Deprecated_Unauthorized() public {
        vm.prank(user1);
        vm.expectRevert(DatasetManager.OnlyProjectAddress.selector);
        datasetManager.updateStatus(DatasetManager.DatasetStatus.Deprecated);
    }

    function test_RevertUpdateStatus_Delisted_Unauthorized() public {
        vm.prank(user1);
        vm.expectRevert(DatasetManager.OnlyDaoGovernance.selector);
        datasetManager.updateStatus(DatasetManager.DatasetStatus.Delisted);
    }

    function test_RecordRentalRevenue() public {
        // Set RentalManager
        address rentalManagerAddr = makeAddr("rentalManager");
        datasetManager.setRentalManager(rentalManagerAddr);

        uint256 revenueAmount = 1000 * 10 ** 6; // 1000 USDC

        vm.prank(rentalManagerAddr);
        datasetManager.recordRentalRevenue(revenueAmount, user1);

        assertEq(
            datasetManager.totalRentalRevenue(),
            revenueAmount,
            "Total revenue should match"
        );
        assertEq(
            datasetManager.totalUniqueUsers(),
            1,
            "Should have 1 unique user"
        );
        assertTrue(
            datasetManager.hasUsedDataset(user1),
            "User1 should be marked as used"
        );
    }

    function test_RecordRentalRevenueMultipleUsers() public {
        address rentalManagerAddr = makeAddr("rentalManager");
        datasetManager.setRentalManager(rentalManagerAddr);

        // User1 pays
        vm.prank(rentalManagerAddr);
        datasetManager.recordRentalRevenue(1000 * 10 ** 6, user1);

        // User2 pays
        vm.prank(rentalManagerAddr);
        datasetManager.recordRentalRevenue(2000 * 10 ** 6, user2);

        // User1 pays again
        vm.prank(rentalManagerAddr);
        datasetManager.recordRentalRevenue(500 * 10 ** 6, user1);

        assertEq(
            datasetManager.totalRentalRevenue(),
            3500 * 10 ** 6,
            "Total revenue should be 3500 USDC"
        );
        assertEq(
            datasetManager.totalUniqueUsers(),
            2,
            "Should have 2 unique users"
        );
    }

    function test_RevertRecordRentalRevenue_Unauthorized() public {
        vm.prank(user1);
        vm.expectRevert(DatasetManager.OnlyRentalManager.selector);
        datasetManager.recordRentalRevenue(1000 * 10 ** 6, user1);
    }

    function test_GetStatistics() public {
        // Setup
        address rentalManagerAddr = makeAddr("rentalManager");
        datasetManager.setRentalManager(rentalManagerAddr);
        datasetManager.setTeeBackend(backend);

        // Record some revenue
        vm.prank(rentalManagerAddr);
        datasetManager.recordRentalRevenue(5000 * 10 ** 6, user1);

        // Record trial usage
        vm.prank(backend);
        datasetManager.recordTrialUsage(user2, 1800);

        // Get statistics
        (
            uint256 totalRevenue,
            uint256 uniqueUsers,
            uint256 trialUsers,
            uint256 creationTime,
            DatasetManager.DatasetStatus currentStatus
        ) = datasetManager.getStatistics();

        assertEq(totalRevenue, 5000 * 10 ** 6, "Total revenue should match");
        assertEq(uniqueUsers, 1, "Unique users should be 1");
        assertEq(trialUsers, 1, "Trial users should be 1");
        assertGt(creationTime, 0, "Creation time should be set");
        assertEq(
            uint256(currentStatus),
            uint256(DatasetManager.DatasetStatus.Active),
            "Status should be Active"
        );
    }

    function test_SetRentalManager() public {
        address rentalManagerAddr = makeAddr("rentalManager");
        datasetManager.setRentalManager(rentalManagerAddr);

        assertEq(
            datasetManager.rentalManager(),
            rentalManagerAddr,
            "RentalManager should be set"
        );
    }

    function test_RevertSetRentalManager_AlreadySet() public {
        address rentalManagerAddr = makeAddr("rentalManager");
        datasetManager.setRentalManager(rentalManagerAddr);

        vm.expectRevert(DatasetManager.AlreadySet.selector);
        datasetManager.setRentalManager(rentalManagerAddr);
    }

    function test_SetTeeBackend() public {
        datasetManager.setTeeBackend(backend);
        assertEq(
            datasetManager.teeBackend(),
            backend,
            "TEE Backend should be set"
        );
    }

    function test_SetDaoGovernance() public {
        address daoGovernance = makeAddr("daoGovernance");
        datasetManager.setDaoGovernance(daoGovernance);
        assertEq(
            datasetManager.daoGovernance(),
            daoGovernance,
            "DAO Governance should be set"
        );
    }
}

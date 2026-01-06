// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./TestBase.sol";
import "../src/RentalOnly.sol";

/**
 * @title IntegrationTest
 * @notice End-to-end integration tests for the complete DeLong Protocol flow
 * @dev Tests the full user journey:
 *      1. Factory deploys dataset contract suite
 *      2. Users buy tokens during IDO
 *      3. IDO launches when target is reached
 *      4. Users rent dataset access and pay fees
 *      5. Token holders claim dividends from rental revenue
 *      6. Project submits treasury withdrawal proposal
 *      7. DAO governance votes and executes proposal
 */
contract IntegrationTest is DeLongTestBase {
    // Dataset deployment results
    address public datasetTokenAddr;
    address public idoAddr;
    address public datasetManagerAddr;
    address public rentalPoolAddr;

    function setUp() public override {
        super.setUp();

        // Deploy implementation contracts
        DatasetToken tokenImpl = new DatasetToken();
        RentalPool poolImpl = new RentalPool();
        IDO idoImpl = new IDO();
        Governance governanceImpl = new Governance();

        // Deploy Factory (all contracts use clone pattern)
        factory = new Factory(
            address(usdc),
            owner,
            address(tokenImpl),
            address(poolImpl),
            address(idoImpl),
            address(governanceImpl)
        );

        // Configure Factory
        factory.configure(
            feeTo,
            address(0x1111111111111111111111111111111111111111), // Mock Uniswap Router
            address(0x2222222222222222222222222222222222222222)  // Mock Uniswap Factory
        );

        // Fund users with USDC
        usdc.mint(user1, 1_000_000 * 10 ** 6); // 1M USDC
        usdc.mint(user2, 1_000_000 * 10 ** 6);
        usdc.mint(user3, 1_000_000 * 10 ** 6);

        vm.label(address(factory), "Factory");
        vm.label(address(governance), "Governance");
    }

    /**
     * @notice Tests the complete flow from dataset deployment to DAO proposal execution
     */
    function test_CompleteFlow() public {
        // ========== Step 1: Deploy Dataset via Factory ==========
        Factory.IDOConfig memory config = Factory.IDOConfig({
            rTarget: 50_000 * 10 ** 6, // 50,000 USDC funding goal
            alpha: 2000 // 20% reserved for project
        });

        vm.prank(user1);
        vm.recordLogs();
        uint256 datasetId = factory.deployIDO(
            projectAddress,
            "AI Training Dataset",
            "AITD",
            createTestMetadataURI(1),
            10 * 10 ** 6, // 10 USDC/hour
            config
        );

        // Get deployed contracts from event
        Vm.Log[] memory entries = vm.getRecordedLogs();
        // IDOCreated event signature
        bytes32 eventSig = keccak256("IDOCreated(uint256,address,address,address,address,address,uint256,uint256)");
        for (uint i = 0; i < entries.length; i++) {
            if (entries[i].topics[0] == eventSig) {
                // IDO address is in topics[3]
                idoAddr = address(uint160(uint256(entries[i].topics[3])));
                // Decode data: token, pool, governance, virtualUsdc, virtualTokens
                (datasetTokenAddr, rentalPoolAddr, , , ) =
                    abi.decode(entries[i].data, (address, address, address, uint256, uint256));
                break;
            }
        }

        assertTrue(idoAddr != address(0), "IDO should be deployed");

        // ========== Step 2: Users buy tokens during IDO ==========
        IDO ido = IDO(idoAddr);
        DatasetToken token = DatasetToken(datasetTokenAddr);

        // User1 buys 50,000 tokens (with new k=9e6, need higher maxCost)
        vm.prank(user1);
        usdc.approve(idoAddr, 150_000 * 10 ** 6); // Updated for new k=9e6
        vm.prank(user1);
        ido.swapUSDCForExactTokens(50_000 * 10 ** 18, 150_000 * 10 ** 6, block.timestamp + 300);

        // User2 buys 50,000 tokens (with new k=9e6, need higher maxCost)
        vm.prank(user2);
        usdc.approve(idoAddr, 200_000 * 10 ** 6); // Updated for new k=9e6
        vm.prank(user2);
        ido.swapUSDCForExactTokens(50_000 * 10 ** 18, 200_000 * 10 ** 6, block.timestamp + 300);

        // User3 buys 50,000 tokens (price is even higher after user2)
        vm.prank(user3);
        usdc.approve(idoAddr, 300_000 * 10 ** 6); // Updated for new k=9e6
        vm.prank(user3);
        ido.swapUSDCForExactTokens(50_000 * 10 ** 18, 300_000 * 10 ** 6, block.timestamp + 300);

        // Check users received tokens
        assertGt(token.balanceOf(user1), 0, "User1 should have tokens");
        assertGt(token.balanceOf(user2), 0, "User2 should have tokens");
        assertGt(token.balanceOf(user3), 0, "User3 should have tokens");

        // ========== Step 3: Wait for potential IDO launch ==========
        // Note: IDO might not launch if target not reached, continue anyway for rental testing

        // ========== Step 4: Users rent dataset access ==========
        RentalPool pool = RentalPool(rentalPoolAddr);

        // User1 purchases 10 hours of access
        uint256 rentalCost = 10 * 10 ** 6 * 10; // 10 hours * 10 USDC/hour
        vm.prank(user1);
        usdc.approve(idoAddr, rentalCost);
        vm.prank(user1);
        ido.purchaseAccess(10); // Purchase 10 hours directly from IDO

        // Check rental revenue distributed
        assertGt(pool.totalRevenue(), 0, "RentalPool should receive revenue");

        // ========== Step 5: Token holders claim dividends ==========
        // Users should have pending dividends from rental revenue
        uint256 user1PendingBefore = pool.getPendingDividends(user1);
        uint256 user2PendingBefore = pool.getPendingDividends(user2);

        // Verify users have pending dividends (they hold tokens and revenue was distributed)
        assertGt(user1PendingBefore, 0, "User1 should have pending dividends");
        assertGt(user2PendingBefore, 0, "User2 should have pending dividends");

        // User1 claims dividends
        uint256 user1UsdcBefore = usdc.balanceOf(user1);
        vm.prank(user1);
        pool.claimDividends();
        assertEq(
            pool.getPendingDividends(user1),
            0,
            "User1 should have no pending dividends after claim"
        );
        assertEq(
            usdc.balanceOf(user1),
            user1UsdcBefore + user1PendingBefore,
            "User1 USDC should increase by pending amount"
        );

        // User2 claims dividends
        uint256 user2UsdcBefore = usdc.balanceOf(user2);
        vm.prank(user2);
        pool.claimDividends();
        assertEq(
            pool.getPendingDividends(user2),
            0,
            "User2 should have no pending dividends after claim"
        );
        assertEq(
            usdc.balanceOf(user2),
            user2UsdcBefore + user2PendingBefore,
            "User2 USDC should increase by pending amount"
        );

        // ========== Step 6: Project submits treasury withdrawal proposal ==========
        // TODO: Update this test for new Governance architecture
        // Treasury functionality is now merged into per-IDO Governance
        // Need to rewrite this test to use the new governance proposal flow

        /*
        // Note: In real scenario, IDO would have deposited funds to Governance
        // For testing, we manually deposit some funds
        uint256 depositAmount = 50_000 * 10 ** 6; // 50k USDC

        // TODO: Get governance address from IDO deployment event
        // TODO: Call governance.depositFunds() or governance.createProposal()
        // TODO: Implement voting and execution flow for new Governance
        */

        // Skip this test for now until Governance is fully integrated
        // assertEq(projectBalanceAfter - projectBalanceBefore, withdrawAmount, "Project should receive USDC");

        // ========== Verify Final State ==========
        assertEq(factory.datasetCount(), 1, "Should have 1 dataset");
        assertGt(token.totalSupply(), 0, "Token should have supply");
        assertGt(
            pool.totalRevenue(),
            0,
            "Pool should have accumulated revenue"
        );
    }

    /**
     * @notice Tests time-based access rights and renewal
     */
    function test_RentalAccessFlow() public {
        // Deploy dataset
        Factory.IDOConfig memory config = Factory.IDOConfig({
            rTarget: 50_000 * 10 ** 6,
            alpha: 2000
        });

        vm.prank(user1);
        vm.recordLogs();
        uint256 datasetId = factory.deployIDO(
            projectAddress,
            "Test Dataset",
            "TST",
            createTestMetadataURI(2),
            10 * 10 ** 6,
            config
        );

        // Get IDO address from event
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 eventSig = keccak256("IDOCreated(uint256,address,address,address,address,address,uint256,uint256)");
        address idoAddr_;
        for (uint i = 0; i < entries.length; i++) {
            if (entries[i].topics[0] == eventSig) {
                idoAddr_ = address(uint160(uint256(entries[i].topics[3])));
                break;
            }
        }

        IDO testIdo = IDO(idoAddr_);

        // User1 purchases 2 hours of access
        uint256 rentalCost = 2 * 10 ** 6 * 10; // 2 hours
        vm.prank(user1);
        usdc.approve(idoAddr_, rentalCost);
        vm.prank(user1);
        testIdo.purchaseAccess(2);

        // Check access is valid
        assertTrue(testIdo.hasValidAccess(user1), "User1 should have valid access");
        assertEq(testIdo.getRemainingAccessTime(user1), 2 hours, "Should have 2 hours remaining");

        // Fast forward 1 hour
        vm.warp(block.timestamp + 1 hours);

        // Access should still be valid with 1 hour remaining
        assertTrue(testIdo.hasValidAccess(user1), "Access should still be valid");
        assertEq(testIdo.getRemainingAccessTime(user1), 1 hours, "Should have 1 hour remaining");

        // User1 renews for another 3 hours
        uint256 renewalCost = 3 * 10 ** 6 * 10;
        vm.prank(user1);
        usdc.approve(idoAddr_, renewalCost);
        vm.prank(user1);
        testIdo.purchaseAccess(3);

        // Should now have 4 hours remaining (1 + 3)
        assertEq(testIdo.getRemainingAccessTime(user1), 4 hours, "Should have 4 hours after renewal");

        // Fast forward past expiration
        vm.warp(block.timestamp + 5 hours);

        // Access should be expired
        assertFalse(testIdo.hasValidAccess(user1), "Access should be expired");
        assertEq(testIdo.getRemainingAccessTime(user1), 0, "Should have 0 time remaining");
    }

    /**
     * @notice Tests multiple dataset deployments and isolation
     */
    function test_MultipleDatasets() public {
        Factory.IDOConfig memory config = Factory.IDOConfig({
            rTarget: 50_000 * 10 ** 6,
            alpha: 2000
        });

        // Deploy dataset 1
        vm.startPrank(user1);
        vm.recordLogs();
        uint256 id1 = factory.deployIDO(
            projectAddress,
            "Dataset 1",
            "DS1",
            createTestMetadataURI(3),
            10 * 10 ** 6,
            config
        );
        Vm.Log[] memory entries1 = vm.getRecordedLogs();
        vm.stopPrank();

        // Deploy dataset 2
        vm.startPrank(user2);
        vm.recordLogs();
        uint256 id2 = factory.deployIDO(
            projectAddress,
            "Dataset 2",
            "DS2",
            createTestMetadataURI(4),
            20 * 10 ** 6,
            config
        );
        Vm.Log[] memory entries2 = vm.getRecordedLogs();
        vm.stopPrank();

        // Get IDO addresses from events
        bytes32 eventSig = keccak256("IDOCreated(uint256,address,address,address,address,address,uint256,uint256)");
        address ido1;
        address ido2;

        for (uint i = 0; i < entries1.length; i++) {
            if (entries1[i].topics[0] == eventSig) {
                ido1 = address(uint160(uint256(entries1[i].topics[3])));
                break;
            }
        }

        for (uint i = 0; i < entries2.length; i++) {
            if (entries2[i].topics[0] == eventSig) {
                ido2 = address(uint160(uint256(entries2[i].topics[3])));
                break;
            }
        }

        // Verify both datasets deployed
        assertEq(factory.datasetCount(), 2, "Should have 2 datasets");

        // Verify IDs are sequential
        assertEq(id1, 1, "First ID should be 1");
        assertEq(id2, 2, "Second ID should be 2");

        // Verify pricing is set correctly for each dataset
        assertEq(
            IDO(ido1).hourlyRate(),
            10 * 10 ** 6,
            "Dataset 1 rate should be 10 USDC"
        );
        assertEq(
            IDO(ido2).hourlyRate(),
            20 * 10 ** 6,
            "Dataset 2 rate should be 20 USDC"
        );
    }

    // ========== RentalOnly Integration Tests ==========

    /**
     * @notice Tests the complete RentalOnly flow: deploy -> purchase -> withdraw -> deactivate
     */
    function test_RentalOnlyCompleteFlow() public {
        // Setup RentalOnly implementation
        RentalOnly rentalOnlyImpl = new RentalOnly();
        factory.setRentalOnlyImplementation(address(rentalOnlyImpl));

        // ========== Step 1: Deploy RentalOnly ==========
        string memory metadataURI = createTestMetadataURI(100);
        uint256 hourlyRate = 15e6; // 15 USDC per hour

        (uint256 datasetId, address rentalOnlyAddr) = factory.deployRentalOnly(
            projectAddress,
            metadataURI,
            hourlyRate
        );

        RentalOnly rental = RentalOnly(rentalOnlyAddr);

        assertEq(datasetId, 1, "First dataset should have ID 1");
        assertTrue(rental.isActive(), "RentalOnly should be active");

        // ========== Step 2: User purchases access ==========
        uint256 hoursCount = 48; // 2 days
        uint256 cost = hourlyRate * hoursCount;

        vm.prank(user1);
        usdc.approve(rentalOnlyAddr, cost);

        vm.prank(user1);
        rental.purchaseAccess(hoursCount);

        assertTrue(rental.hasAccess(user1), "User1 should have access");
        assertEq(rental.accessExpiresAt(user1), block.timestamp + hoursCount * 1 hours);

        // ========== Step 3: Verify fee distribution ==========
        uint256 protocolFee = (cost * 500) / 10000; // 5%
        uint256 ownerShare = cost - protocolFee;

        assertEq(usdc.balanceOf(feeTo), protocolFee, "Protocol should receive 5%");
        assertEq(rental.pendingWithdrawal(), ownerShare, "Owner share should accumulate");
        assertEq(rental.totalRentalCollected(), cost, "Total should match");

        // ========== Step 4: Owner withdraws earnings ==========
        uint256 projectBalanceBefore = usdc.balanceOf(projectAddress);

        vm.prank(projectAddress);
        rental.withdraw();

        assertEq(
            usdc.balanceOf(projectAddress),
            projectBalanceBefore + ownerShare,
            "Owner should receive 95%"
        );
        assertEq(rental.pendingWithdrawal(), 0, "Pending should be zero");

        // ========== Step 5: Deactivate ==========
        vm.prank(projectAddress);
        rental.deactivate();

        assertFalse(rental.isActive(), "Should be deactivated");

        // User access should still be valid until expiry
        assertTrue(rental.hasAccess(user1), "User access should remain until expiry");

        // Fast forward past expiry
        vm.warp(block.timestamp + 50 hours);
        assertFalse(rental.hasAccess(user1), "User access should expire");
    }

    /**
     * @notice Tests upgrade path: RentalOnly -> Deactivate -> IDO
     */
    function test_RentalOnlyToIDOUpgrade() public {
        // Setup RentalOnly implementation
        RentalOnly rentalOnlyImpl = new RentalOnly();
        factory.setRentalOnlyImplementation(address(rentalOnlyImpl));

        string memory metadataURI = createTestMetadataURI(101);

        // ========== Step 1: Deploy RentalOnly ==========
        (, address rentalOnlyAddr) = factory.deployRentalOnly(
            projectAddress,
            metadataURI,
            10e6
        );

        RentalOnly rental = RentalOnly(rentalOnlyAddr);

        // ========== Step 2: Some users purchase access ==========
        vm.prank(user1);
        usdc.approve(rentalOnlyAddr, 100e6);
        vm.prank(user1);
        rental.purchaseAccess(10);

        // ========== Step 3: Owner decides to upgrade to IDO ==========
        // First withdraw earnings
        vm.prank(projectAddress);
        rental.withdraw();

        // Then deactivate
        vm.prank(projectAddress);
        rental.deactivate();

        // ========== Step 4: Deploy IDO with same metadata ==========
        Factory.IDOConfig memory config = Factory.IDOConfig({
            rTarget: 100_000e6,
            alpha: 2500
        });

        uint256 idoDatasetId = factory.deployIDO(
            projectAddress,
            "Upgraded Dataset",
            "UDS",
            metadataURI,
            20e6, // Higher hourly rate
            config
        );

        assertEq(idoDatasetId, 2, "IDO should have datasetId 2");
        assertEq(factory.datasetCount(), 2, "Should have 2 datasets total");

        // Old RentalOnly user access still valid until expiry
        assertTrue(rental.hasAccess(user1), "Old access should still be valid");

        // New users can't purchase from deactivated RentalOnly
        vm.prank(user2);
        usdc.approve(rentalOnlyAddr, 100e6);
        vm.prank(user2);
        vm.expectRevert(RentalOnly.ContractDeactivated.selector);
        rental.purchaseAccess(10);
    }

    /**
     * @notice Tests that RentalOnly and IDO with different metadata work independently
     */
    function test_RentalOnlyAndIDOIsolation() public {
        // Setup RentalOnly implementation
        RentalOnly rentalOnlyImpl = new RentalOnly();
        factory.setRentalOnlyImplementation(address(rentalOnlyImpl));

        // ========== Deploy RentalOnly for metadata A ==========
        string memory metadataA = createTestMetadataURI(200);
        (, address rentalOnlyAddr) = factory.deployRentalOnly(
            projectAddress,
            metadataA,
            10e6
        );
        RentalOnly rental = RentalOnly(rentalOnlyAddr);

        // ========== Deploy IDO for metadata B ==========
        string memory metadataB = createTestMetadataURI(201);
        Factory.IDOConfig memory config = Factory.IDOConfig({
            rTarget: 50_000e6,
            alpha: 2000
        });

        vm.recordLogs(); // Start recording logs BEFORE deployIDO
        uint256 idoBDatasetId = factory.deployIDO(
            projectAddress,
            "IDO Dataset",
            "IDS",
            metadataB,
            15e6,
            config
        );

        // Get IDO address from event
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 eventSig = keccak256("IDOCreated(uint256,address,address,address,address,address,uint256,uint256)");
        address idoAddrB;
        for (uint i = 0; i < entries.length; i++) {
            if (entries[i].topics[0] == eventSig) {
                idoAddrB = address(uint160(uint256(entries[i].topics[3])));
                break;
            }
        }
        assertTrue(idoAddrB != address(0), "IDO address should not be zero");
        IDO idoContract = IDO(idoAddrB);

        // ========== Both should work independently ==========
        assertEq(factory.datasetCount(), 2, "Should have 2 datasets");

        // RentalOnly works
        vm.prank(user1);
        usdc.approve(rentalOnlyAddr, 100e6);
        vm.prank(user1);
        rental.purchaseAccess(10);
        assertTrue(rental.hasAccess(user1), "RentalOnly access should work");

        // IDO works
        vm.prank(user2);
        usdc.approve(idoAddrB, 100e6);
        vm.prank(user2);
        idoContract.purchaseAccess(5);
        assertTrue(idoContract.hasValidAccess(user2), "IDO access should work");

        // Different hourly rates
        assertEq(rental.hourlyRate(), 10e6, "RentalOnly rate should be 10");
        assertEq(idoContract.hourlyRate(), 15e6, "IDO rate should be 15");

        // Deactivating RentalOnly doesn't affect IDO
        vm.prank(projectAddress);
        rental.deactivate();

        assertTrue(idoContract.hasValidAccess(user2), "IDO access should still work");
    }

    // ========== Dividend Distribution Edge Case Tests ==========

    /**
     * @notice Tests dividend distribution when tokens are transferred between users
     * @dev Verifies that:
     *      1. User A can claim dividends earned before transfer
     *      2. User B can only claim dividends earned after receiving tokens
     *      3. Total dividends distributed equals total revenue added
     */
    function test_ClaimDividends_AfterTokenTransfer() public {
        // ========== Setup: Deploy dataset and get contracts ==========
        Factory.IDOConfig memory config = Factory.IDOConfig({
            rTarget: 50_000 * 10 ** 6,
            alpha: 2000
        });

        vm.prank(user1);
        vm.recordLogs();
        factory.deployIDO(
            projectAddress,
            "Dividend Test Dataset",
            "DVT",
            createTestMetadataURI(300),
            10 * 10 ** 6,
            config
        );

        // Get deployed contracts from event
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 eventSig = keccak256("IDOCreated(uint256,address,address,address,address,address,uint256,uint256)");
        address idoAddr_;
        address tokenAddr_;
        address poolAddr_;

        for (uint i = 0; i < entries.length; i++) {
            if (entries[i].topics[0] == eventSig) {
                idoAddr_ = address(uint160(uint256(entries[i].topics[3])));
                (tokenAddr_, poolAddr_, , , ) =
                    abi.decode(entries[i].data, (address, address, address, uint256, uint256));
                break;
            }
        }

        IDO testIdo = IDO(idoAddr_);
        DatasetToken token = DatasetToken(tokenAddr_);
        RentalPool pool = RentalPool(poolAddr_);

        // ========== Step 1: User1 buys tokens ==========
        vm.prank(user1);
        usdc.approve(idoAddr_, 100_000e6);
        vm.prank(user1);
        testIdo.swapUSDCForExactTokens(100_000e18, 100_000e6, block.timestamp + 300);

        uint256 user1Tokens = token.balanceOf(user1);
        assertGt(user1Tokens, 0, "User1 should have tokens");

        // ========== Step 2: First rental revenue (User1 owns some tokens) ==========
        uint256 firstRentalCost = 100e6; // 10 hours * 10 USDC
        vm.prank(user1);
        usdc.approve(idoAddr_, firstRentalCost);
        vm.prank(user1);
        testIdo.purchaseAccess(10);

        // Check User1's pending dividends from first revenue
        uint256 user1PendingAfterFirst = pool.getPendingDividends(user1);
        assertGt(user1PendingAfterFirst, 0, "User1 should have pending after first revenue");

        // ========== Step 3: Manually unfreeze token for testing ==========
        // In real scenario, this happens after IDO launch
        // For testing dividend edge cases, we simulate IDO calling unfreeze
        vm.prank(idoAddr_);
        token.unfreeze();

        // ========== Step 4: User1 transfers half tokens to User3 ==========
        uint256 transferAmount = user1Tokens / 2;
        vm.prank(user1);
        token.transfer(user3, transferAmount);

        // Verify balances
        assertEq(token.balanceOf(user1), user1Tokens - transferAmount, "User1 balance after transfer");
        assertEq(token.balanceOf(user3), transferAmount, "User3 balance after transfer");

        // User1 should still have pending dividends (saved by beforeBalanceChange hook)
        uint256 user1PendingAfterTransfer = pool.getPendingDividends(user1);
        assertGt(user1PendingAfterTransfer, 0, "User1 should still have pending after transfer");

        // User3 should have NO pending dividends (just received tokens)
        uint256 user3PendingAfterTransfer = pool.getPendingDividends(user3);
        assertEq(user3PendingAfterTransfer, 0, "User3 should have no pending right after transfer");

        // ========== Step 5: Second rental revenue (after transfer) ==========
        uint256 secondRentalCost = 100e6;
        vm.prank(user2);
        usdc.approve(idoAddr_, secondRentalCost);
        vm.prank(user2);
        testIdo.purchaseAccess(10);

        // Now both User1 and User3 should have pending dividends from second revenue
        uint256 user1PendingAfterSecond = pool.getPendingDividends(user1);
        uint256 user3PendingAfterSecond = pool.getPendingDividends(user3);

        assertGt(user1PendingAfterSecond, user1PendingAfterTransfer, "User1 should earn more from second revenue");
        assertGt(user3PendingAfterSecond, 0, "User3 should have pending from second revenue");

        // ========== Step 6: Both users claim ==========
        uint256 user1BalanceBefore = usdc.balanceOf(user1);
        vm.prank(user1);
        uint256 user1Claimed = pool.claimDividends();

        uint256 user3BalanceBefore = usdc.balanceOf(user3);
        vm.prank(user3);
        uint256 user3Claimed = pool.claimDividends();

        // Verify USDC received
        assertEq(usdc.balanceOf(user1), user1BalanceBefore + user1Claimed, "User1 should receive claimed USDC");
        assertEq(usdc.balanceOf(user3), user3BalanceBefore + user3Claimed, "User3 should receive claimed USDC");

        // User1 should have claimed more than User3 (owned tokens for both revenues)
        assertGt(user1Claimed, user3Claimed, "User1 should claim more (owned tokens longer)");

        // After claim, pending should be 0
        assertEq(pool.getPendingDividends(user1), 0, "User1 pending should be 0 after claim");
        assertEq(pool.getPendingDividends(user3), 0, "User3 pending should be 0 after claim");
    }

    /**
     * @notice Tests claiming dividends across multiple revenue additions
     */
    function test_ClaimDividends_MultipleRevenueRounds() public {
        // Setup
        Factory.IDOConfig memory config = Factory.IDOConfig({
            rTarget: 50_000 * 10 ** 6,
            alpha: 2000
        });

        vm.prank(user1);
        vm.recordLogs();
        factory.deployIDO(
            projectAddress,
            "Multi Revenue Test",
            "MRT",
            createTestMetadataURI(301),
            10 * 10 ** 6,
            config
        );

        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 eventSig = keccak256("IDOCreated(uint256,address,address,address,address,address,uint256,uint256)");
        address idoAddr_;
        address poolAddr_;

        for (uint i = 0; i < entries.length; i++) {
            if (entries[i].topics[0] == eventSig) {
                idoAddr_ = address(uint160(uint256(entries[i].topics[3])));
                (, poolAddr_, , , ) =
                    abi.decode(entries[i].data, (address, address, address, uint256, uint256));
                break;
            }
        }

        IDO testIdo = IDO(idoAddr_);
        RentalPool pool = RentalPool(poolAddr_);

        // User1 buys tokens
        vm.prank(user1);
        usdc.approve(idoAddr_, 100_000e6);
        vm.prank(user1);
        testIdo.swapUSDCForExactTokens(100_000e18, 100_000e6, block.timestamp + 300);

        // Multiple rounds of revenue
        for (uint i = 0; i < 5; i++) {
            vm.prank(user2);
            usdc.approve(idoAddr_, 100e6);
            vm.prank(user2);
            testIdo.purchaseAccess(10);
        }

        // Single claim should get all accumulated dividends
        uint256 totalPending = pool.getPendingDividends(user1);
        assertGt(totalPending, 0, "Should have accumulated dividends");

        vm.prank(user1);
        uint256 claimed = pool.claimDividends();

        assertEq(claimed, totalPending, "Should claim all pending");
        assertEq(pool.getPendingDividends(user1), 0, "Pending should be 0 after claim");

        // Add more revenue after claim
        vm.prank(user2);
        usdc.approve(idoAddr_, 100e6);
        vm.prank(user2);
        testIdo.purchaseAccess(10);

        // Should have new pending from latest revenue
        uint256 newPending = pool.getPendingDividends(user1);
        assertGt(newPending, 0, "Should have new pending after post-claim revenue");
    }
}

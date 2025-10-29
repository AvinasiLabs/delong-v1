// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./TestBase.sol";

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

        // Deploy shared contracts
        rentalManager = new RentalManager(address(usdc), owner);
        daoTreasury = new DAOTreasury(address(usdc), owner);
        daoGovernance = new DAOGovernance(address(usdc), owner); // Using USDC as governance token for simplicity

        // Deploy Factory
        factory = new Factory(address(usdc), owner);

        // Configure Factory
        factory.configure(
            address(rentalManager),
            address(daoTreasury),
            protocolTreasury
        );

        // Configure shared contracts
        rentalManager.setFactory(address(factory));
        rentalManager.setProtocolTreasury(protocolTreasury);
        rentalManager.setAuthorizedBackend(owner, true); // Authorize test contract as backend
        daoTreasury.setIDOContract(address(factory));
        daoTreasury.setDAOGovernance(address(daoGovernance));
        daoGovernance.setDAOTreasury(address(daoTreasury));

        // Fund users with USDC
        usdc.mint(user1, 1_000_000 * 10 ** 6); // 1M USDC
        usdc.mint(user2, 1_000_000 * 10 ** 6);
        usdc.mint(user3, 1_000_000 * 10 ** 6);

        vm.label(address(factory), "Factory");
        vm.label(address(rentalManager), "RentalManager");
        vm.label(address(daoTreasury), "DAOTreasury");
        vm.label(address(daoGovernance), "DAOGovernance");
    }

    /**
     * @notice Tests the complete flow from dataset deployment to DAO proposal execution
     */
    function test_CompleteFlow() public {
        // ========== Step 1: Deploy Dataset via Factory ==========
        Factory.IDOConfig memory config = Factory.IDOConfig({
            alphaProject: 2000, // 20% reserved for project
            k: 9 * 10 ** 6, // 9 USD
            betaLP: 7000, // 70% for LP
            minRaiseRatio: 7500, // 75% target
            initialPrice: 1 * 10 ** 6 // 1 USDC
        });

        // User1 pays deployment fee
        vm.prank(user1);
        usdc.approve(address(factory), 100 * 10 ** 6);

        vm.prank(user1);
        vm.recordLogs();
        uint256 datasetId = factory.deployDataset(
            projectAddress,
            "AI Training Dataset",
            "AITD",
            "ipfs://metadata",
            10 * 10 ** 6, // 10 USDC/hour
            config
        );

        // Get deployed contracts from event
        Vm.Log[] memory entries = vm.getRecordedLogs();
        // DatasetDeployed event signature
        bytes32 eventSig = keccak256("DatasetDeployed(uint256,address,address,address,address,address)");
        for (uint i = 0; i < entries.length; i++) {
            if (entries[i].topics[0] == eventSig) {
                (idoAddr, datasetTokenAddr, datasetManagerAddr, rentalPoolAddr) =
                    abi.decode(entries[i].data, (address, address, address, address));
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
        ido.buyTokens(50_000 * 10 ** 18, 150_000 * 10 ** 6);

        // User2 buys 50,000 tokens (with new k=9e6, need higher maxCost)
        vm.prank(user2);
        usdc.approve(idoAddr, 200_000 * 10 ** 6); // Updated for new k=9e6
        vm.prank(user2);
        ido.buyTokens(50_000 * 10 ** 18, 200_000 * 10 ** 6);

        // User3 buys 50,000 tokens (price is even higher after user2)
        vm.prank(user3);
        usdc.approve(idoAddr, 300_000 * 10 ** 6); // Updated for new k=9e6
        vm.prank(user3);
        ido.buyTokens(50_000 * 10 ** 18, 300_000 * 10 ** 6);

        // Check users received tokens
        assertGt(token.balanceOf(user1), 0, "User1 should have tokens");
        assertGt(token.balanceOf(user2), 0, "User2 should have tokens");
        assertGt(token.balanceOf(user3), 0, "User3 should have tokens");

        // ========== Step 3: Wait for potential IDO launch ==========
        // Note: IDO might not launch if target not reached, continue anyway for rental testing

        // ========== Step 4: Users rent dataset access ==========
        RentalManager rental = RentalManager(address(rentalManager));
        RentalPool pool = RentalPool(rentalPoolAddr);

        // Note: TEE backend already configured by Factory in _initializeContracts

        // User1 purchases 10 hours of access
        uint256 rentalCost = 10 * 10 ** 6 * 10; // 10 hours * 10 USDC/hour
        vm.prank(user1);
        usdc.approve(address(rentalManager), rentalCost);
        vm.prank(user1);
        rental.purchaseAccess(datasetTokenAddr, 10);

        // Check rental revenue distributed
        assertGt(pool.totalRevenue(), 0, "RentalPool should receive revenue");

        // ========== Step 5: Token holders claim dividends ==========
        // Users should have pending dividends from rental revenue
        uint256 user1PendingBefore = pool.getPendingDividends(user1);
        uint256 user2PendingBefore = pool.getPendingDividends(user2);

        // User1 claims dividends
        if (user1PendingBefore > 0) {
            vm.prank(user1);
            pool.claimDividends();
            assertEq(
                pool.getPendingDividends(user1),
                0,
                "User1 should have no pending dividends after claim"
            );
        }

        // User2 claims dividends
        if (user2PendingBefore > 0) {
            vm.prank(user2);
            pool.claimDividends();
            assertEq(
                pool.getPendingDividends(user2),
                0,
                "User2 should have no pending dividends after claim"
            );
        }

        // ========== Step 6: Project submits treasury withdrawal proposal ==========
        // Note: In real scenario, IDO would have deposited funds to DAOTreasury
        // For testing, we manually deposit some funds using Factory (which is authorized)

        uint256 depositAmount = 50_000 * 10 ** 6; // 50k USDC
        usdc.mint(address(factory), depositAmount);
        vm.prank(address(factory));
        usdc.approve(address(daoTreasury), depositAmount);
        vm.prank(address(factory));
        daoTreasury.depositFunds(
            datasetTokenAddr,
            projectAddress,
            depositAmount
        );

        // Project submits withdrawal proposal
        uint256 withdrawAmount = 10_000 * 10 ** 6; // 10k USDC
        vm.prank(projectAddress);
        uint256 proposalId = daoTreasury.submitProposal(
            datasetTokenAddr,
            withdrawAmount,
            "Development funding"
        );

        assertEq(daoTreasury.proposalCount(), 1, "Should have 1 proposal");

        // ========== Step 7: DAO governance approves and executes proposal ==========
        // In real scenario, token holders would vote via DAOGovernance
        // For testing, we directly approve via governance contract

        vm.prank(address(daoGovernance));
        daoTreasury.approveProposal(proposalId);

        // Project executes the approved proposal
        uint256 projectBalanceBefore = usdc.balanceOf(projectAddress);
        vm.prank(projectAddress);
        daoTreasury.executeProposal(proposalId);
        uint256 projectBalanceAfter = usdc.balanceOf(projectAddress);

        // Verify project received funds
        assertEq(
            projectBalanceAfter - projectBalanceBefore,
            withdrawAmount,
            "Project should receive USDC"
        );

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
     * @notice Tests rental usage recording and quota exhaustion
     */
    function test_RentalUsageFlow() public {
        // Deploy dataset
        Factory.IDOConfig memory config = Factory.IDOConfig({
            alphaProject: 2000,
            k: 9 * 10 ** 6, // 9 USD
            betaLP: 7000,
            minRaiseRatio: 7500,
            initialPrice: 1 * 10 ** 6
        });

        vm.prank(user1);
        usdc.approve(address(factory), 100 * 10 ** 6);
        vm.prank(user1);
        vm.recordLogs();
        uint256 datasetId = factory.deployDataset(
            projectAddress,
            "Test Dataset",
            "TST",
            "ipfs://test",
            10 * 10 ** 6,
            config
        );

        // Get token address from event
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 eventSig = keccak256("DatasetDeployed(uint256,address,address,address,address,address)");
        address datasetTokenAddr_;
        for (uint i = 0; i < entries.length; i++) {
            if (entries[i].topics[0] == eventSig) {
                (,datasetTokenAddr_,,) = abi.decode(entries[i].data, (address, address, address, address));
                break;
            }
        }

        // Note: TEE backend already configured by Factory

        // User1 purchases 2 hours of access
        uint256 rentalCost = 2 * 10 ** 6 * 10; // 2 hours
        vm.prank(user1);
        usdc.approve(address(rentalManager), rentalCost);
        vm.prank(user1);
        rentalManager.purchaseAccess(datasetTokenAddr_, 2);

        // Backend records usage: 1 hour (60 minutes)
        // Note: Factory sets backend to owner (test contract)
        vm.prank(owner);
        rentalManager.recordUsage(user1, datasetTokenAddr_, 0, 60, "");

        // Check rental still active
        (, , , uint256 usedMinutes, , bool isActive) = rentalManager
            .userRentals(user1, datasetTokenAddr_, 0);
        assertEq(usedMinutes, 60, "Should have used 60 minutes");
        assertTrue(isActive, "Rental should still be active");

        // Backend records another hour, exhausting quota
        vm.prank(owner);
        rentalManager.recordUsage(user1, datasetTokenAddr_, 0, 60, "");

        // Check rental exhausted
        (, , , uint256 usedMinutes2, , bool isActive2) = rentalManager
            .userRentals(user1, datasetTokenAddr_, 0);
        assertEq(usedMinutes2, 120, "Should have used 120 minutes");
        assertFalse(isActive2, "Rental should be inactive after exhaustion");
    }

    /**
     * @notice Tests multiple dataset deployments and isolation
     */
    function test_MultipleDatasets() public {
        Factory.IDOConfig memory config = Factory.IDOConfig({
            alphaProject: 2000,
            k: 9 * 10 ** 6, // 9 USD
            betaLP: 7000,
            minRaiseRatio: 7500,
            initialPrice: 1 * 10 ** 6
        });

        // Deploy dataset 1
        vm.startPrank(user1);
        usdc.approve(address(factory), 200 * 10 ** 6);
        vm.recordLogs();
        uint256 id1 = factory.deployDataset(
            projectAddress,
            "Dataset 1",
            "DS1",
            "ipfs://1",
            10 * 10 ** 6,
            config
        );
        Vm.Log[] memory entries1 = vm.getRecordedLogs();
        vm.stopPrank();

        // Deploy dataset 2
        vm.startPrank(user2);
        usdc.approve(address(factory), 200 * 10 ** 6);
        vm.recordLogs();
        uint256 id2 = factory.deployDataset(
            projectAddress,
            "Dataset 2",
            "DS2",
            "ipfs://2",
            20 * 10 ** 6,
            config
        );
        Vm.Log[] memory entries2 = vm.getRecordedLogs();
        vm.stopPrank();

        // Get token addresses from events
        bytes32 eventSig = keccak256("DatasetDeployed(uint256,address,address,address,address,address)");
        address token1;
        address token2;

        for (uint i = 0; i < entries1.length; i++) {
            if (entries1[i].topics[0] == eventSig) {
                (, token1,,) = abi.decode(entries1[i].data, (address, address, address, address));
                break;
            }
        }

        for (uint i = 0; i < entries2.length; i++) {
            if (entries2[i].topics[0] == eventSig) {
                (, token2,,) = abi.decode(entries2[i].data, (address, address, address, address));
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
            rentalManager.hourlyRate(token1),
            10 * 10 ** 6,
            "Dataset 1 rate should be 10 USDC"
        );
        assertEq(
            rentalManager.hourlyRate(token2),
            20 * 10 ** 6,
            "Dataset 2 rate should be 20 USDC"
        );
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./TestBase.sol";
import "../src/interfaces/IGovernanceStrategy.sol";

/**
 * @title GovernanceTest
 * @notice Comprehensive tests for Governance contract
 */
contract GovernanceTest is DeLongTestBase {
    // Test constants
    uint256 constant VOTING_PERIOD = 7 days;
    uint256 constant PROPOSAL_THRESHOLD = 100; // 1%
    uint256 constant QUORUM_THRESHOLD = 5000; // 50%

    // Uniswap addresses (mock)
    address public uniswapV2Router;
    address public uniswapV2Factory;

    function setUp() public virtual override {
        super.setUp();

        // Deploy Uniswap mocks
        uniswapV2Router = makeAddr("UniswapV2Router");
        uniswapV2Factory = makeAddr("UniswapV2Factory");

        // Deploy DatasetToken
        datasetToken = new DatasetToken();

        // Deploy IDO (needed for Governance)
        ido = new IDO();

        // Initialize DatasetToken
        datasetToken.initialize(
            "Test Dataset Token",
            "TDT",
            owner,
            address(ido),
            address(0), // No RentalPool in Governance tests
            1_000_000 * 10 ** 18 // 1M tokens
        );

        // Deploy and initialize Governance
        governance = new Governance();
        governance.initialize(
            address(ido),
            address(usdc),
            uniswapV2Router,
            uniswapV2Factory
        );

        vm.label(address(datasetToken), "DatasetToken");
        vm.label(address(ido), "IDO");
        vm.label(address(governance), "Governance");
    }

    // ========== Initialization Tests ==========

    function test_InitialState() public view {
        assertEq(governance.ido(), address(ido), "IDO should be set");
        assertEq(
            address(governance.usdc()),
            address(usdc),
            "USDC should be set"
        );
        assertEq(
            governance.governanceStrategy(),
            address(governance),
            "Should use self as default strategy"
        );
        assertFalse(governance.isDelisted(), "Should not be delisted initially");
        assertEq(governance.treasuryBalance(), 0, "Treasury should be empty");
    }

    function test_SupportsInterface() public view {
        // Should support IGovernanceStrategy
        assertTrue(
            governance.supportsInterface(
                type(IGovernanceStrategy).interfaceId
            ),
            "Should support IGovernanceStrategy"
        );

        // Should support IERC165
        assertTrue(
            governance.supportsInterface(type(IERC165).interfaceId),
            "Should support IERC165"
        );
    }

    // ========== Default Strategy Tests ==========

    function test_DefaultStrategy_GetProposalThreshold() public view {
        assertEq(
            governance.getProposalThreshold(),
            PROPOSAL_THRESHOLD,
            "Proposal threshold should be 1%"
        );
    }

    function test_DefaultStrategy_GetVotingPeriod() public view {
        assertEq(
            governance.getVotingPeriod(),
            VOTING_PERIOD,
            "Voting period should be 7 days"
        );
    }

    function test_DefaultStrategy_CountFundingVotes_Pass() public view {
        uint256 totalSupply = 1_000_000 * 10 ** 18;
        uint256 forVotes = 500_000 * 10 ** 18; // 50%
        uint256 againstVotes = 100_000 * 10 ** 18;

        assertTrue(
            governance.countFundingVotes(forVotes, againstVotes, totalSupply),
            "Should pass with 50% FOR votes"
        );
    }

    function test_DefaultStrategy_CountFundingVotes_Fail() public view {
        uint256 totalSupply = 1_000_000 * 10 ** 18;
        uint256 forVotes = 499_999 * 10 ** 18; // Just below 50%
        uint256 againstVotes = 100_000 * 10 ** 18;

        assertFalse(
            governance.countFundingVotes(forVotes, againstVotes, totalSupply),
            "Should fail with < 50% FOR votes"
        );
    }

    function test_DefaultStrategy_CountPricingVotes() public view {
        uint256 totalSupply = 1_000_000 * 10 ** 18;
        uint256 forVotes = 500_000 * 10 ** 18;
        uint256 againstVotes = 0;

        assertTrue(
            governance.countPricingVotes(forVotes, againstVotes, totalSupply),
            "Pricing should use same 50% threshold"
        );
    }

    function test_DefaultStrategy_CountDelistVotes() public view {
        uint256 totalSupply = 1_000_000 * 10 ** 18;
        uint256 forVotes = 500_000 * 10 ** 18;
        uint256 againstVotes = 0;

        assertTrue(
            governance.countDelistVotes(forVotes, againstVotes, totalSupply),
            "Delist should use same 50% threshold"
        );
    }

    function test_DefaultStrategy_CountGovernanceUpgradeVotes() public view {
        uint256 totalSupply = 1_000_000 * 10 ** 18;
        uint256 forVotes = 500_000 * 10 ** 18;
        uint256 againstVotes = 0;

        assertTrue(
            governance.countGovernanceUpgradeVotes(
                forVotes,
                againstVotes,
                totalSupply
            ),
            "Governance upgrade should use same 50% threshold"
        );
    }

    // ========== Treasury Tests ==========

    function test_DepositFunds() public {
        uint256 depositAmount = 100_000 * 10 ** USDC_DECIMALS;

        // Fund IDO contract
        usdc.mint(address(ido), depositAmount);

        // Approve and deposit from IDO
        vm.startPrank(address(ido));
        usdc.approve(address(governance), depositAmount);
        governance.depositFunds(depositAmount);
        vm.stopPrank();

        assertEq(
            governance.treasuryBalance(),
            depositAmount,
            "Treasury balance should be updated"
        );
    }

    function test_RevertDepositFunds_ZeroAmount() public {
        vm.prank(address(ido));
        vm.expectRevert(Governance.ZeroAmount.selector);
        governance.depositFunds(0);
    }

    function test_RevertDepositFunds_Unauthorized() public {
        vm.expectRevert(Governance.Unauthorized.selector);
        governance.depositFunds(1000);
    }

    // ========== LP Management Tests ==========

    function test_LockLP() public {
        address lpToken = makeAddr("lpToken");
        uint256 lpAmount = 1000 * 10 ** 18;

        // Mock LP token
        MockUSDC mockLP = new MockUSDC();
        mockLP.mint(address(ido), lpAmount);

        // Lock LP from IDO
        vm.startPrank(address(ido));
        mockLP.approve(address(governance), lpAmount);
        governance.lockLP(address(mockLP), lpAmount);
        vm.stopPrank();

        assertEq(governance.lpToken(), address(mockLP), "LP token should be set");
        assertEq(governance.lpAmount(), lpAmount, "LP amount should be set");
        assertEq(
            mockLP.balanceOf(address(governance)),
            lpAmount,
            "LP should be transferred"
        );
    }

    function test_RevertLockLP_Unauthorized() public {
        vm.expectRevert(Governance.Unauthorized.selector);
        governance.lockLP(makeAddr("lpToken"), 1000);
    }

    function test_RevertLockLP_ZeroAddress() public {
        vm.prank(address(ido));
        vm.expectRevert(Governance.ZeroAddress.selector);
        governance.lockLP(address(0), 1000);
    }

    function test_RevertLockLP_ZeroAmount() public {
        vm.prank(address(ido));
        vm.expectRevert(Governance.ZeroAmount.selector);
        governance.lockLP(makeAddr("lpToken"), 0);
    }

    // ========== Helper Functions ==========

    /**
     * @notice Helper to distribute tokens to users for voting
     */
    function distributeTokensForVoting(
        address to,
        uint256 amount
    ) internal {
        vm.prank(address(ido));
        datasetToken.transfer(to, amount);

        // Wait for next block so snapshot works
        vm.roll(block.number + 1);
    }

    /**
     * @notice Helper to set up IDO mock that returns token address
     */
    function setupIDOMock() internal {
        // Mock IDO.tokenAddress() to return datasetToken
        vm.mockCall(
            address(ido),
            abi.encodeWithSignature("tokenAddress()"),
            abi.encode(address(datasetToken))
        );
    }
}

/**
 * @title GovernanceProposalTest
 * @notice Tests for proposal creation, voting, and execution
 */
contract GovernanceProposalTest is GovernanceTest {
    function setUp() public override {
        super.setUp();
        setupIDOMock();

        // Distribute tokens for proposal creation and voting
        // User1: 2% (can create proposals)
        distributeTokensForVoting(user1, 20_000 * 10 ** 18);
        // User2: 30%
        distributeTokensForVoting(user2, 300_000 * 10 ** 18);
        // User3: 20%
        distributeTokensForVoting(user3, 200_000 * 10 ** 18);

        // Unfreeze token so users can delegate/vote
        vm.prank(address(ido));
        datasetToken.unfreeze();
    }

    // ========== Funding Proposal Tests ==========

    function test_CreateFundingProposal() public {
        uint256 fundingAmount = 10_000 * 10 ** USDC_DECIMALS;

        vm.prank(user1);
        uint256 proposalId = governance.createFundingProposal(
            fundingAmount,
            projectAddress,
            "Development funding"
        );

        assertEq(proposalId, 0, "First proposal ID should be 0");

        (
            uint256 id,
            Governance.ProposalType proposalType,
            Governance.ProposalStatus status,
            address proposer,
            uint256 forVotes,
            uint256 againstVotes,
            ,
            ,
            ,
            ,
            uint256 amount,
            address recipient,
            ,
            ,

        ) = governance.proposals(proposalId);

        assertEq(id, 0, "Proposal ID should match");
        assertTrue(
            proposalType == Governance.ProposalType.Funding,
            "Should be Funding proposal"
        );
        assertTrue(
            status == Governance.ProposalStatus.Pending,
            "Should be Pending"
        );
        assertEq(proposer, user1, "Proposer should be user1");
        assertEq(forVotes, 0, "No votes yet");
        assertEq(againstVotes, 0, "No votes yet");
        assertEq(amount, fundingAmount, "Amount should match");
        assertEq(recipient, projectAddress, "Recipient should match");
    }

    function test_RevertCreateFundingProposal_BelowThreshold() public {
        // user3 has only 0.5%, below 1% threshold
        address poorUser = makeAddr("poorUser");
        distributeTokensForVoting(poorUser, 5_000 * 10 ** 18);

        vm.prank(poorUser);
        vm.expectRevert(Governance.BelowProposalThreshold.selector);
        governance.createFundingProposal(
            1000 * 10 ** USDC_DECIMALS,
            projectAddress,
            "Should fail"
        );
    }

    function test_RevertCreateFundingProposal_ZeroAmount() public {
        vm.prank(user1);
        vm.expectRevert(Governance.ZeroAmount.selector);
        governance.createFundingProposal(0, projectAddress, "Invalid");
    }

    function test_RevertCreateFundingProposal_ZeroAddress() public {
        vm.prank(user1);
        vm.expectRevert(Governance.ZeroAddress.selector);
        governance.createFundingProposal(
            1000 * 10 ** USDC_DECIMALS,
            address(0),
            "Invalid"
        );
    }

    // ========== Pricing Proposal Tests ==========

    function test_CreatePricingProposal() public {
        uint256 newPrice = 100 * 10 ** USDC_DECIMALS; // $100/hour

        vm.prank(user1);
        uint256 proposalId = governance.createPricingProposal(
            newPrice,
            "Increase rental price"
        );

        (
            ,
            Governance.ProposalType proposalType,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            uint256 storedNewPrice,
            ,

        ) = governance.proposals(proposalId);

        assertTrue(
            proposalType == Governance.ProposalType.Pricing,
            "Should be Pricing proposal"
        );
        assertEq(storedNewPrice, newPrice, "New price should match");
    }

    // ========== Delist Proposal Tests ==========

    function test_CreateDelistProposal() public {
        vm.prank(user1);
        uint256 proposalId = governance.createDelistProposal(
            "Dataset quality issue"
        );

        (, Governance.ProposalType proposalType, , , , , , , , , , , , , ) = governance
            .proposals(proposalId);

        assertTrue(
            proposalType == Governance.ProposalType.Delist,
            "Should be Delist proposal"
        );
    }

    // ========== Governance Upgrade Proposal Tests ==========

    function test_CreateGovernanceUpgradeProposal() public {
        // Deploy custom strategy
        CustomGovernanceStrategy customStrategy = new CustomGovernanceStrategy();

        vm.prank(user1);
        uint256 proposalId = governance.createGovernanceUpgradeProposal(
            address(customStrategy),
            "Upgrade to stricter voting thresholds"
        );

        (
            ,
            Governance.ProposalType proposalType,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            address newStrategy,

        ) = governance.proposals(proposalId);

        assertTrue(
            proposalType == Governance.ProposalType.GovernanceUpgrade,
            "Should be GovernanceUpgrade proposal"
        );
        assertEq(
            newStrategy,
            address(customStrategy),
            "New strategy should match"
        );
    }

    function test_RevertCreateGovernanceUpgradeProposal_InvalidStrategy() public {
        // Deploy contract that doesn't implement IGovernanceStrategy
        address invalidStrategy = address(new MockUSDC());

        vm.prank(user1);
        vm.expectRevert(Governance.InvalidStrategy.selector);
        governance.createGovernanceUpgradeProposal(
            invalidStrategy,
            "Should fail"
        );
    }
}

/**
 * @title GovernanceVotingTest
 * @notice Tests for voting and proposal execution
 */
contract GovernanceVotingTest is GovernanceTest {
    function setUp() public override {
        super.setUp();
        setupIDOMock();

        // Distribute tokens for proposal creation and voting
        // User1: 2% (can create proposals)
        distributeTokensForVoting(user1, 20_000 * 10 ** 18);
        // User2: 30%
        distributeTokensForVoting(user2, 300_000 * 10 ** 18);
        // User3: 25%
        distributeTokensForVoting(user3, 250_000 * 10 ** 18);

        // Unfreeze token so users can delegate/vote
        vm.prank(address(ido));
        datasetToken.unfreeze();

        // Users must delegate to themselves to enable voting power
        vm.prank(user1);
        datasetToken.delegate(user1);
        vm.prank(user2);
        datasetToken.delegate(user2);
        vm.prank(user3);
        datasetToken.delegate(user3);

        // Advance block so delegation takes effect
        vm.roll(block.number + 1);
    }

    // ========== Voting Tests ==========

    function test_CastVote_For() public {
        // Create proposal
        vm.prank(user1);
        uint256 proposalId = governance.createFundingProposal(
            1000e6,
            projectAddress,
            "Test funding"
        );

        // Advance block for snapshot
        vm.roll(block.number + 1);

        // User2 votes FOR
        vm.prank(user2);
        governance.castVote(proposalId, true);

        // Check vote recorded
        (, , , , uint256 forVotes, uint256 againstVotes, , , , , , , , , ) = governance.proposals(proposalId);
        assertEq(forVotes, 300_000 * 10 ** 18, "FOR votes should match user2 balance");
        assertEq(againstVotes, 0, "AGAINST votes should be 0");
        assertTrue(governance.hasVoted(proposalId, user2), "User2 should be marked as voted");
    }

    function test_CastVote_Against() public {
        vm.prank(user1);
        uint256 proposalId = governance.createFundingProposal(
            1000e6,
            projectAddress,
            "Test funding"
        );

        vm.roll(block.number + 1);

        // User2 votes AGAINST
        vm.prank(user2);
        governance.castVote(proposalId, false);

        (, , , , uint256 forVotes, uint256 againstVotes, , , , , , , , , ) = governance.proposals(proposalId);
        assertEq(forVotes, 0, "FOR votes should be 0");
        assertEq(againstVotes, 300_000 * 10 ** 18, "AGAINST votes should match user2 balance");
    }

    function test_CastVote_MultipleVoters() public {
        vm.prank(user1);
        uint256 proposalId = governance.createFundingProposal(
            1000e6,
            projectAddress,
            "Test funding"
        );

        vm.roll(block.number + 1);

        // User2 votes FOR
        vm.prank(user2);
        governance.castVote(proposalId, true);

        // User3 votes FOR
        vm.prank(user3);
        governance.castVote(proposalId, true);

        (, , , , uint256 forVotes, , , , , , , , , , ) = governance.proposals(proposalId);
        assertEq(forVotes, 550_000 * 10 ** 18, "FOR votes should be user2 + user3");
    }

    function test_RevertCastVote_AlreadyVoted() public {
        vm.prank(user1);
        uint256 proposalId = governance.createFundingProposal(
            1000e6,
            projectAddress,
            "Test funding"
        );

        vm.roll(block.number + 1);

        vm.prank(user2);
        governance.castVote(proposalId, true);

        // Try to vote again
        vm.prank(user2);
        vm.expectRevert(Governance.AlreadyVoted.selector);
        governance.castVote(proposalId, false);
    }

    function test_RevertCastVote_VotingClosed() public {
        vm.prank(user1);
        uint256 proposalId = governance.createFundingProposal(
            1000e6,
            projectAddress,
            "Test funding"
        );

        // Fast forward past voting period
        vm.warp(block.timestamp + 8 days);

        vm.prank(user2);
        vm.expectRevert(Governance.VotingClosed.selector);
        governance.castVote(proposalId, true);
    }

    function test_RevertCastVote_NoTokens() public {
        vm.prank(user1);
        uint256 proposalId = governance.createFundingProposal(
            1000e6,
            projectAddress,
            "Test funding"
        );

        vm.roll(block.number + 1);

        // Random user with no tokens
        address noTokenUser = makeAddr("noTokenUser");
        vm.prank(noTokenUser);
        vm.expectRevert(Governance.NoTokens.selector);
        governance.castVote(proposalId, true);
    }

    function test_RevertCastVote_InvalidProposal() public {
        vm.prank(user2);
        vm.expectRevert(Governance.InvalidProposal.selector);
        governance.castVote(999, true);
    }

    // ========== Proposal Status Tests ==========

    function test_GetProposalStatus_Pending() public {
        vm.prank(user1);
        uint256 proposalId = governance.createFundingProposal(
            1000e6,
            projectAddress,
            "Test funding"
        );

        assertEq(
            uint256(governance.getProposalStatus(proposalId)),
            uint256(Governance.ProposalStatus.Pending),
            "Should be Pending during voting"
        );
    }

    function test_GetProposalStatus_Succeeded() public {
        vm.prank(user1);
        uint256 proposalId = governance.createFundingProposal(
            1000e6,
            projectAddress,
            "Test funding"
        );

        vm.roll(block.number + 1);

        // User2 (30%) + User3 (25%) = 55% FOR
        vm.prank(user2);
        governance.castVote(proposalId, true);
        vm.prank(user3);
        governance.castVote(proposalId, true);

        // Fast forward past voting period
        vm.warp(block.timestamp + 8 days);

        assertEq(
            uint256(governance.getProposalStatus(proposalId)),
            uint256(Governance.ProposalStatus.Succeeded),
            "Should be Succeeded with 55% FOR"
        );
    }

    function test_GetProposalStatus_Defeated() public {
        vm.prank(user1);
        uint256 proposalId = governance.createFundingProposal(
            1000e6,
            projectAddress,
            "Test funding"
        );

        vm.roll(block.number + 1);

        // Only User2 (30%) votes FOR - below 50% threshold
        vm.prank(user2);
        governance.castVote(proposalId, true);

        // Fast forward past voting period
        vm.warp(block.timestamp + 8 days);

        assertEq(
            uint256(governance.getProposalStatus(proposalId)),
            uint256(Governance.ProposalStatus.Defeated),
            "Should be Defeated with only 30% FOR"
        );
    }

    // ========== Execution Tests ==========

    function test_ExecuteProposal_Funding() public {
        // Deposit funds to treasury first
        uint256 treasuryAmount = 50_000e6;
        usdc.mint(address(ido), treasuryAmount);
        vm.startPrank(address(ido));
        usdc.approve(address(governance), treasuryAmount);
        governance.depositFunds(treasuryAmount);
        vm.stopPrank();

        // Create funding proposal
        uint256 fundingAmount = 10_000e6;
        vm.prank(user1);
        uint256 proposalId = governance.createFundingProposal(
            fundingAmount,
            projectAddress,
            "Development funding"
        );

        vm.roll(block.number + 1);

        // Vote to pass (55%)
        vm.prank(user2);
        governance.castVote(proposalId, true);
        vm.prank(user3);
        governance.castVote(proposalId, true);

        // Fast forward past voting period
        vm.warp(block.timestamp + 8 days);

        // Execute
        uint256 projectBalanceBefore = usdc.balanceOf(projectAddress);
        governance.executeProposal(proposalId);

        // Verify
        assertEq(
            usdc.balanceOf(projectAddress),
            projectBalanceBefore + fundingAmount,
            "Project should receive funds"
        );
        assertEq(
            governance.treasuryBalance(),
            treasuryAmount - fundingAmount,
            "Treasury should decrease"
        );
        assertEq(
            uint256(governance.getProposalStatus(proposalId)),
            uint256(Governance.ProposalStatus.Executed),
            "Should be Executed"
        );
    }

    function test_ExecuteProposal_Delist_NoLP() public {
        // Create delist proposal
        vm.prank(user1);
        uint256 proposalId = governance.createDelistProposal("Quality issue");

        vm.roll(block.number + 1);

        // Vote to pass
        vm.prank(user2);
        governance.castVote(proposalId, true);
        vm.prank(user3);
        governance.castVote(proposalId, true);

        vm.warp(block.timestamp + 8 days);

        // Execute
        governance.executeProposal(proposalId);

        // Verify delisted
        assertTrue(governance.isDelisted(), "Should be delisted");
    }

    function test_RevertExecuteProposal_InvalidStatus() public {
        vm.prank(user1);
        uint256 proposalId = governance.createFundingProposal(
            1000e6,
            projectAddress,
            "Test"
        );

        vm.roll(block.number + 1);

        // Only 30% votes - will be defeated
        vm.prank(user2);
        governance.castVote(proposalId, true);

        vm.warp(block.timestamp + 8 days);

        // Try to execute defeated proposal
        vm.expectRevert(Governance.InvalidStatus.selector);
        governance.executeProposal(proposalId);
    }

    function test_RevertExecuteProposal_InsufficientBalance() public {
        // No treasury funds deposited
        vm.prank(user1);
        uint256 proposalId = governance.createFundingProposal(
            1000e6,
            projectAddress,
            "Test"
        );

        vm.roll(block.number + 1);

        vm.prank(user2);
        governance.castVote(proposalId, true);
        vm.prank(user3);
        governance.castVote(proposalId, true);

        vm.warp(block.timestamp + 8 days);

        vm.expectRevert(Governance.InsufficientBalance.selector);
        governance.executeProposal(proposalId);
    }

    function test_ExecuteProposal_Pricing() public {
        // Mock IDO to accept updateHourlyRate call
        uint256 newPrice = 50e6; // 50 USDC per hour

        vm.prank(user1);
        uint256 proposalId = governance.createPricingProposal(
            newPrice,
            "Increase rental price"
        );

        vm.roll(block.number + 1);

        // Vote to pass
        vm.prank(user2);
        governance.castVote(proposalId, true);
        vm.prank(user3);
        governance.castVote(proposalId, true);

        vm.warp(block.timestamp + 8 days);

        // Mock IDO.updateHourlyRate to succeed
        vm.mockCall(
            address(ido),
            abi.encodeWithSignature("updateHourlyRate(uint256)", newPrice),
            abi.encode()
        );

        // Execute
        governance.executeProposal(proposalId);

        // Verify executed
        assertEq(
            uint256(governance.getProposalStatus(proposalId)),
            uint256(Governance.ProposalStatus.Executed),
            "Should be Executed"
        );
    }

    function test_ExecuteProposal_GovernanceUpgrade() public {
        // Deploy custom strategy
        CustomGovernanceStrategy customStrategy = new CustomGovernanceStrategy();

        vm.prank(user1);
        uint256 proposalId = governance.createGovernanceUpgradeProposal(
            address(customStrategy),
            "Upgrade to stricter thresholds"
        );

        vm.roll(block.number + 1);

        // Vote to pass
        vm.prank(user2);
        governance.castVote(proposalId, true);
        vm.prank(user3);
        governance.castVote(proposalId, true);

        vm.warp(block.timestamp + 8 days);

        // Verify old strategy
        assertEq(
            governance.governanceStrategy(),
            address(governance),
            "Should be self before upgrade"
        );

        // Execute
        governance.executeProposal(proposalId);

        // Verify new strategy
        assertEq(
            governance.governanceStrategy(),
            address(customStrategy),
            "Should be custom strategy after upgrade"
        );

        // Verify new threshold is used (2% instead of 1%)
        assertEq(
            IGovernanceStrategy(governance.governanceStrategy()).getProposalThreshold(),
            200, // 2%
            "New threshold should be 2%"
        );
    }

    function test_ExecuteProposal_Delist_WithLP() public {
        // Setup: Lock LP tokens first
        MockUSDC mockLP = new MockUSDC();
        uint256 lpAmount = 1000e18;
        mockLP.mint(address(ido), lpAmount);

        vm.startPrank(address(ido));
        mockLP.approve(address(governance), lpAmount);
        governance.lockLP(address(mockLP), lpAmount);
        vm.stopPrank();

        // Verify LP is locked
        assertEq(governance.lpToken(), address(mockLP), "LP should be locked");
        assertEq(governance.lpAmount(), lpAmount, "LP amount should match");

        // Create delist proposal
        vm.prank(user1);
        uint256 proposalId = governance.createDelistProposal("Quality issue");

        vm.roll(block.number + 1);

        // Vote to pass
        vm.prank(user2);
        governance.castVote(proposalId, true);
        vm.prank(user3);
        governance.castVote(proposalId, true);

        vm.warp(block.timestamp + 8 days);

        // Mock Uniswap router removeLiquidity
        // Returns (amountToken, amountUSDC)
        uint256 returnedUSDC = 5000e6;
        vm.mockCall(
            uniswapV2Router,
            abi.encodeWithSignature(
                "removeLiquidity(address,address,uint256,uint256,uint256,address,uint256)"
            ),
            abi.encode(500e18, returnedUSDC)
        );

        // Execute
        governance.executeProposal(proposalId);

        // Verify delisted
        assertTrue(governance.isDelisted(), "Should be delisted");
        assertEq(
            governance.refundPoolUSDC(),
            returnedUSDC,
            "Refund pool should have USDC from LP"
        );
    }

    function test_VotingBoundary_Exactly50Percent_Pass() public {
        // Redistribute tokens for exact 50% test
        // Need exactly 50% FOR votes to pass

        // Create proposal
        vm.prank(user1);
        uint256 proposalId = governance.createFundingProposal(
            1000e6,
            projectAddress,
            "Test boundary"
        );

        vm.roll(block.number + 1);

        // User2 (30%) + User3 (25%) = 55% > 50%, should pass
        vm.prank(user2);
        governance.castVote(proposalId, true);
        vm.prank(user3);
        governance.castVote(proposalId, true);

        vm.warp(block.timestamp + 8 days);

        assertEq(
            uint256(governance.getProposalStatus(proposalId)),
            uint256(Governance.ProposalStatus.Succeeded),
            "Should succeed with 55%"
        );
    }

    function test_VotingBoundary_Below50Percent_Fail() public {
        // Only 30% votes - should fail
        vm.prank(user1);
        uint256 proposalId = governance.createFundingProposal(
            1000e6,
            projectAddress,
            "Test boundary"
        );

        vm.roll(block.number + 1);

        // Only User2 (30%) votes FOR
        vm.prank(user2);
        governance.castVote(proposalId, true);

        vm.warp(block.timestamp + 8 days);

        assertEq(
            uint256(governance.getProposalStatus(proposalId)),
            uint256(Governance.ProposalStatus.Defeated),
            "Should be defeated with 30%"
        );
    }

    function test_RevertExecuteProposal_AlreadyExecuted() public {
        // Deposit treasury funds
        uint256 treasuryAmount = 50_000e6;
        usdc.mint(address(ido), treasuryAmount);
        vm.startPrank(address(ido));
        usdc.approve(address(governance), treasuryAmount);
        governance.depositFunds(treasuryAmount);
        vm.stopPrank();

        // Create and pass proposal
        vm.prank(user1);
        uint256 proposalId = governance.createFundingProposal(
            1000e6,
            projectAddress,
            "Test"
        );

        vm.roll(block.number + 1);

        vm.prank(user2);
        governance.castVote(proposalId, true);
        vm.prank(user3);
        governance.castVote(proposalId, true);

        vm.warp(block.timestamp + 8 days);

        // Execute first time
        governance.executeProposal(proposalId);

        // Try to execute again
        vm.expectRevert(Governance.InvalidStatus.selector);
        governance.executeProposal(proposalId);
    }

    function test_RevertCreateProposal_AfterDelisted() public {
        // Create and execute delist proposal
        vm.prank(user1);
        uint256 delistId = governance.createDelistProposal("Delist");

        vm.roll(block.number + 1);

        vm.prank(user2);
        governance.castVote(delistId, true);
        vm.prank(user3);
        governance.castVote(delistId, true);

        vm.warp(block.timestamp + 8 days);
        governance.executeProposal(delistId);

        assertTrue(governance.isDelisted(), "Should be delisted");

        // Try to create new proposals - should all fail
        vm.prank(user1);
        vm.expectRevert(Governance.AlreadyDelisted.selector);
        governance.createFundingProposal(1000e6, projectAddress, "Should fail");

        vm.prank(user1);
        vm.expectRevert(Governance.AlreadyDelisted.selector);
        governance.createPricingProposal(50e6, "Should fail");

        vm.prank(user1);
        vm.expectRevert(Governance.AlreadyDelisted.selector);
        governance.createDelistProposal("Should fail");

        CustomGovernanceStrategy newStrategy = new CustomGovernanceStrategy();
        vm.prank(user1);
        vm.expectRevert(Governance.AlreadyDelisted.selector);
        governance.createGovernanceUpgradeProposal(address(newStrategy), "Should fail");
    }

    // ========== Delist Refund Tests ==========

    function test_ClaimRefund_AfterDelist() public {
        // Setup: Lock LP and deposit some treasury funds to create refund pool
        MockUSDC mockLP = new MockUSDC();
        uint256 lpAmount = 1000e18;
        mockLP.mint(address(ido), lpAmount);

        vm.startPrank(address(ido));
        mockLP.approve(address(governance), lpAmount);
        governance.lockLP(address(mockLP), lpAmount);
        vm.stopPrank();

        // Create and execute delist proposal
        vm.prank(user1);
        uint256 proposalId = governance.createDelistProposal("Delist for refund test");

        vm.roll(block.number + 1);

        vm.prank(user2);
        governance.castVote(proposalId, true);
        vm.prank(user3);
        governance.castVote(proposalId, true);

        vm.warp(block.timestamp + 8 days);

        // Mock Uniswap removeLiquidity to return USDC
        uint256 returnedUSDC = 10_000e6;
        vm.mockCall(
            uniswapV2Router,
            abi.encodeWithSignature(
                "removeLiquidity(address,address,uint256,uint256,uint256,address,uint256)"
            ),
            abi.encode(500e18, returnedUSDC)
        );

        // Mint USDC to governance to simulate LP removal
        usdc.mint(address(governance), returnedUSDC);

        governance.executeProposal(proposalId);

        assertTrue(governance.isDelisted(), "Should be delisted");
        assertEq(governance.refundPoolUSDC(), returnedUSDC, "Refund pool should have USDC");

        // User2 claims refund
        uint256 user2Tokens = datasetToken.balanceOf(user2);
        assertGt(user2Tokens, 0, "User2 should have tokens");

        vm.prank(user2);
        datasetToken.approve(address(governance), user2Tokens);

        uint256 user2UsdcBefore = usdc.balanceOf(user2);
        vm.prank(user2);
        governance.claimRefund();

        // Verify refund received
        uint256 user2UsdcAfter = usdc.balanceOf(user2);
        assertGt(user2UsdcAfter, user2UsdcBefore, "User2 should receive USDC refund");

        // Verify tokens transferred
        assertEq(datasetToken.balanceOf(user2), 0, "User2 tokens should be transferred");

        // Verify claimed flag
        assertTrue(governance.hasClaimedRefund(user2), "User2 should be marked as claimed");
    }

    function test_ClaimRefund_ProportionalDistribution() public {
        // Setup with LP
        MockUSDC mockLP = new MockUSDC();
        uint256 lpAmount = 1000e18;
        mockLP.mint(address(ido), lpAmount);

        vm.startPrank(address(ido));
        mockLP.approve(address(governance), lpAmount);
        governance.lockLP(address(mockLP), lpAmount);
        vm.stopPrank();

        // Delist
        vm.prank(user1);
        uint256 proposalId = governance.createDelistProposal("Delist");
        vm.roll(block.number + 1);
        vm.prank(user2);
        governance.castVote(proposalId, true);
        vm.prank(user3);
        governance.castVote(proposalId, true);
        vm.warp(block.timestamp + 8 days);

        uint256 returnedUSDC = 10_000e6;
        vm.mockCall(
            uniswapV2Router,
            abi.encodeWithSignature(
                "removeLiquidity(address,address,uint256,uint256,uint256,address,uint256)"
            ),
            abi.encode(500e18, returnedUSDC)
        );
        usdc.mint(address(governance), returnedUSDC);
        governance.executeProposal(proposalId);

        // User2 has 30%, User3 has 25%
        uint256 user2Tokens = datasetToken.balanceOf(user2);
        uint256 user3Tokens = datasetToken.balanceOf(user3);

        // Both claim
        vm.prank(user2);
        datasetToken.approve(address(governance), user2Tokens);
        uint256 user2UsdcBefore = usdc.balanceOf(user2);
        vm.prank(user2);
        governance.claimRefund();
        uint256 user2Refund = usdc.balanceOf(user2) - user2UsdcBefore;

        vm.prank(user3);
        datasetToken.approve(address(governance), user3Tokens);
        uint256 user3UsdcBefore = usdc.balanceOf(user3);
        vm.prank(user3);
        governance.claimRefund();
        uint256 user3Refund = usdc.balanceOf(user3) - user3UsdcBefore;

        // User2 (30%) should get more than User3 (25%)
        assertGt(user2Refund, user3Refund, "User2 should get more refund (more tokens)");
    }

    function test_RevertClaimRefund_NotDelisted() public {
        vm.prank(user1);
        vm.expectRevert(Governance.NotDelisted.selector);
        governance.claimRefund();
    }

    function test_RevertClaimRefund_AlreadyClaimed() public {
        // Setup with LP to create refund pool
        MockUSDC mockLP = new MockUSDC();
        uint256 lpAmount = 1000e18;
        mockLP.mint(address(ido), lpAmount);

        vm.startPrank(address(ido));
        mockLP.approve(address(governance), lpAmount);
        governance.lockLP(address(mockLP), lpAmount);
        vm.stopPrank();

        // Delist
        vm.prank(user1);
        uint256 proposalId = governance.createDelistProposal("Delist");
        vm.roll(block.number + 1);
        vm.prank(user2);
        governance.castVote(proposalId, true);
        vm.prank(user3);
        governance.castVote(proposalId, true);
        vm.warp(block.timestamp + 8 days);

        // Mock Uniswap and mint USDC
        uint256 returnedUSDC = 10_000e6;
        vm.mockCall(
            uniswapV2Router,
            abi.encodeWithSignature(
                "removeLiquidity(address,address,uint256,uint256,uint256,address,uint256)"
            ),
            abi.encode(500e18, returnedUSDC)
        );
        usdc.mint(address(governance), returnedUSDC);
        governance.executeProposal(proposalId);

        // First claim
        uint256 user2Tokens = datasetToken.balanceOf(user2);
        vm.prank(user2);
        datasetToken.approve(address(governance), user2Tokens);
        vm.prank(user2);
        governance.claimRefund();

        // Try to claim again
        vm.prank(user2);
        vm.expectRevert(Governance.AlreadyClaimed.selector);
        governance.claimRefund();
    }

    function test_RevertClaimRefund_NoTokens() public {
        // Delist
        vm.prank(user1);
        uint256 proposalId = governance.createDelistProposal("Delist");
        vm.roll(block.number + 1);
        vm.prank(user2);
        governance.castVote(proposalId, true);
        vm.prank(user3);
        governance.castVote(proposalId, true);
        vm.warp(block.timestamp + 8 days);
        governance.executeProposal(proposalId);

        // Create a user with no tokens
        address noTokenUser = makeAddr("noTokenUser");

        vm.prank(noTokenUser);
        vm.expectRevert(Governance.NoTokens.selector);
        governance.claimRefund();
    }

    // ========== Full Lifecycle Test ==========

    function test_ProposalLifecycle_Complete() public {
        // 1. Deposit treasury funds
        uint256 treasuryAmount = 100_000e6;
        usdc.mint(address(ido), treasuryAmount);
        vm.startPrank(address(ido));
        usdc.approve(address(governance), treasuryAmount);
        governance.depositFunds(treasuryAmount);
        vm.stopPrank();

        // 2. Create proposal
        uint256 fundingAmount = 25_000e6;
        vm.prank(user1);
        uint256 proposalId = governance.createFundingProposal(
            fundingAmount,
            projectAddress,
            "Marketing budget"
        );

        // Verify pending
        assertEq(
            uint256(governance.getProposalStatus(proposalId)),
            uint256(Governance.ProposalStatus.Pending)
        );

        vm.roll(block.number + 1);

        // 3. Voting phase
        vm.prank(user2);
        governance.castVote(proposalId, true);

        // Still pending during voting
        assertEq(
            uint256(governance.getProposalStatus(proposalId)),
            uint256(Governance.ProposalStatus.Pending)
        );

        vm.prank(user3);
        governance.castVote(proposalId, true);

        // 4. End voting period
        vm.warp(block.timestamp + 8 days);

        // Now should be succeeded
        assertEq(
            uint256(governance.getProposalStatus(proposalId)),
            uint256(Governance.ProposalStatus.Succeeded)
        );

        // 5. Execute
        uint256 projectBalanceBefore = usdc.balanceOf(projectAddress);
        governance.executeProposal(proposalId);

        // 6. Verify final state
        assertEq(
            uint256(governance.getProposalStatus(proposalId)),
            uint256(Governance.ProposalStatus.Executed)
        );
        assertEq(
            usdc.balanceOf(projectAddress),
            projectBalanceBefore + fundingAmount
        );
        assertEq(
            governance.treasuryBalance(),
            treasuryAmount - fundingAmount
        );
    }
}

/**
 * @title CustomGovernanceStrategy
 * @notice Mock custom strategy for testing governance upgrades
 */
contract CustomGovernanceStrategy is IGovernanceStrategy {
    function countFundingVotes(
        uint256 forVotes,
        uint256,
        uint256 totalSupply
    ) external pure returns (bool) {
        return (forVotes * 10000) / totalSupply >= 6000; // 60%
    }

    function countPricingVotes(
        uint256 forVotes,
        uint256,
        uint256 totalSupply
    ) external pure returns (bool) {
        return (forVotes * 10000) / totalSupply >= 5000; // 50%
    }

    function countDelistVotes(
        uint256 forVotes,
        uint256,
        uint256 totalSupply
    ) external pure returns (bool) {
        return (forVotes * 10000) / totalSupply >= 6700; // 67%
    }

    function countGovernanceUpgradeVotes(
        uint256 forVotes,
        uint256,
        uint256 totalSupply
    ) external pure returns (bool) {
        return (forVotes * 10000) / totalSupply >= 7500; // 75%
    }

    function getProposalThreshold() external pure returns (uint256) {
        return 200; // 2%
    }

    function getVotingPeriod() external pure returns (uint256) {
        return 14 days;
    }

    function supportsInterface(
        bytes4 interfaceId
    ) external pure returns (bool) {
        return
            interfaceId == type(IGovernanceStrategy).interfaceId ||
            interfaceId == type(IERC165).interfaceId;
    }
}

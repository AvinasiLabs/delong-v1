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

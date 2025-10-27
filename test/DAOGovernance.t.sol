// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./TestBase.sol";

contract DAOGovernanceTest is DeLongTestBase {
    DatasetToken public governanceToken; // DLP token for governance

    function setUp() public override {
        super.setUp();

        // Deploy governance token (simulating DLP token)
        governanceToken = new DatasetToken();
        governanceToken.initialize(
            "DeLong Platform Token",
            "DLP",
            owner,
            owner, // owner acts as IDO - tokens minted directly to owner
            1_000_000 * 10 ** 18
        );
        governanceToken.unfreeze();

        // Deploy DAO Governance
        daoGovernance = new DAOGovernance(address(governanceToken), owner);

        // Deploy DAOTreasury
        daoTreasury = new DAOTreasury(address(usdc), owner);
        daoTreasury.setDAOGovernance(address(daoGovernance));
        daoGovernance.setDAOTreasury(address(daoTreasury));

        // Distribute governance tokens to users
        governanceToken.transfer(user1, 100_000 * 10 ** 18); // 10%
        governanceToken.transfer(user2, 200_000 * 10 ** 18); // 20%
        governanceToken.transfer(user3, 300_000 * 10 ** 18); // 30%

        vm.label(address(daoGovernance), "DAOGovernance");
        vm.label(address(governanceToken), "GovernanceToken");
    }

    function test_InitialState() public view {
        assertEq(
            address(daoGovernance.governanceToken()),
            address(governanceToken),
            "Governance token should match"
        );
        assertEq(
            daoGovernance.daoTreasury(),
            address(daoTreasury),
            "DAO Treasury should match"
        );
        assertEq(
            daoGovernance.proposalCount(),
            0,
            "Initial proposal count should be 0"
        );
        assertEq(
            daoGovernance.VOTING_PERIOD(),
            7 days,
            "Voting period should be 7 days"
        );
        assertEq(daoGovernance.QUORUM_PERCENTAGE(), 20, "Quorum should be 20%");
        assertEq(
            daoGovernance.APPROVAL_THRESHOLD(),
            51,
            "Approval threshold should be 51%"
        );
    }

    function test_CreateProposal() public {
        bytes memory callData = abi.encode(123); // Treasury proposal ID
        string memory description = "Approve treasury withdrawal";

        vm.prank(user1);
        uint256 proposalId = daoGovernance.createProposal(
            DAOGovernance.ProposalType.TreasuryWithdrawal,
            address(daoTreasury),
            callData,
            description
        );

        assertEq(proposalId, 0, "First proposal ID should be 0");

        // Check proposal details
        (
            uint256 id,
            address proposer,
            DAOGovernance.ProposalType proposalType,
            ,
            ,
            string memory desc,
            ,
            uint256 votingEnds,
            ,
            ,
            ,
            ,
            DAOGovernance.ProposalState state,

        ) = daoGovernance.proposals(proposalId);

        assertEq(id, proposalId, "Proposal ID should match");
        assertEq(proposer, user1, "Proposer should be user1");
        assertEq(
            uint256(proposalType),
            uint256(DAOGovernance.ProposalType.TreasuryWithdrawal),
            "Type should match"
        );
        assertEq(desc, description, "Description should match");
        assertEq(
            uint256(state),
            uint256(DAOGovernance.ProposalState.Active),
            "State should be Active"
        );
        assertGt(
            votingEnds,
            block.timestamp,
            "Voting end time should be in future"
        );
    }

    function test_CastVote() public {
        // Create proposal
        vm.prank(user1);
        uint256 proposalId = daoGovernance.createProposal(
            DAOGovernance.ProposalType.General,
            address(0),
            "",
            "Test proposal"
        );

        // User2 votes For
        vm.prank(user2);
        daoGovernance.castVote(proposalId, DAOGovernance.VoteChoice.For);

        // Check vote recorded
        DAOGovernance.VoteRecord memory voteRecord = daoGovernance.getVote(
            proposalId,
            user2
        );

        assertTrue(voteRecord.hasVoted, "Should have voted");
        assertEq(
            uint256(voteRecord.choice),
            uint256(DAOGovernance.VoteChoice.For),
            "Vote should be For"
        );
        assertEq(
            voteRecord.weight,
            200_000 * 10 ** 18,
            "Voting weight should match balance"
        );

        // Check proposal vote counts
        (, , , , , , , , uint256 forVotes, , , , , ) = daoGovernance.proposals(
            proposalId
        );
        assertEq(forVotes, 200_000 * 10 ** 18, "For votes should be recorded");
    }

    function test_MultipleVotes() public {
        // Create proposal
        vm.prank(user1);
        uint256 proposalId = daoGovernance.createProposal(
            DAOGovernance.ProposalType.General,
            address(0),
            "",
            "Test proposal"
        );

        // User1 votes For
        vm.prank(user1);
        daoGovernance.castVote(proposalId, DAOGovernance.VoteChoice.For);

        // User2 votes Against
        vm.prank(user2);
        daoGovernance.castVote(proposalId, DAOGovernance.VoteChoice.Against);

        // User3 votes Abstain
        vm.prank(user3);
        daoGovernance.castVote(proposalId, DAOGovernance.VoteChoice.Abstain);

        // Check vote counts
        (
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            uint256 forVotes,
            uint256 againstVotes,
            uint256 abstainVotes,
            ,
            ,

        ) = daoGovernance.proposals(proposalId);

        assertEq(forVotes, 100_000 * 10 ** 18, "For votes should be 100k");
        assertEq(
            againstVotes,
            200_000 * 10 ** 18,
            "Against votes should be 200k"
        );
        assertEq(
            abstainVotes,
            300_000 * 10 ** 18,
            "Abstain votes should be 300k"
        );
    }

    function test_RevertCastVote_AlreadyVoted() public {
        vm.prank(user1);
        uint256 proposalId = daoGovernance.createProposal(
            DAOGovernance.ProposalType.General,
            address(0),
            "",
            "Test"
        );

        vm.prank(user1);
        daoGovernance.castVote(proposalId, DAOGovernance.VoteChoice.For);

        // Try to vote again
        vm.prank(user1);
        vm.expectRevert(DAOGovernance.AlreadyVoted.selector);
        daoGovernance.castVote(proposalId, DAOGovernance.VoteChoice.Against);
    }

    function test_FinalizeProposal_QuorumReached() public {
        // Create proposal
        vm.prank(user1);
        uint256 proposalId = daoGovernance.createProposal(
            DAOGovernance.ProposalType.General,
            address(0),
            "",
            "Test proposal"
        );

        // User2 (20%) and User3 (30%) vote For = 50% total
        // This meets quorum (20%) and approval threshold (51%)
        vm.prank(user2);
        daoGovernance.castVote(proposalId, DAOGovernance.VoteChoice.For);

        vm.prank(user3);
        daoGovernance.castVote(proposalId, DAOGovernance.VoteChoice.For);

        // Fast forward past voting period
        vm.warp(block.timestamp + 8 days);

        // Finalize proposal
        daoGovernance.finalizeProposal(proposalId);

        // Check state
        DAOGovernance.ProposalState state = daoGovernance.getProposalState(
            proposalId
        );
        assertEq(
            uint256(state),
            uint256(DAOGovernance.ProposalState.Succeeded),
            "Proposal should succeed"
        );
    }

    function test_FinalizeProposal_QuorumNotReached() public {
        // Create proposal
        vm.prank(user1);
        uint256 proposalId = daoGovernance.createProposal(
            DAOGovernance.ProposalType.General,
            address(0),
            "",
            "Test proposal"
        );

        // Only user1 (10%) votes - doesn't meet 20% quorum
        vm.prank(user1);
        daoGovernance.castVote(proposalId, DAOGovernance.VoteChoice.For);

        // Fast forward
        vm.warp(block.timestamp + 8 days);

        // Finalize
        daoGovernance.finalizeProposal(proposalId);

        // Should be defeated
        DAOGovernance.ProposalState state = daoGovernance.getProposalState(
            proposalId
        );
        assertEq(
            uint256(state),
            uint256(DAOGovernance.ProposalState.Defeated),
            "Proposal should be defeated"
        );
    }

    function test_CancelProposal() public {
        vm.prank(user1);
        uint256 proposalId = daoGovernance.createProposal(
            DAOGovernance.ProposalType.General,
            address(0),
            "",
            "Test"
        );

        vm.prank(user1);
        daoGovernance.cancelProposal(proposalId);

        DAOGovernance.ProposalState state = daoGovernance.getProposalState(
            proposalId
        );
        assertEq(
            uint256(state),
            uint256(DAOGovernance.ProposalState.Cancelled),
            "Should be cancelled"
        );
    }

    function test_SetDefaultVotingDelegate() public {
        address delegate = makeAddr("delegate");

        daoGovernance.setDefaultVotingDelegate(delegate);

        assertEq(
            daoGovernance.defaultVotingDelegate(),
            delegate,
            "Delegate should be set"
        );
    }

    function test_GetVotingPower() public view {
        uint256 votingPower = daoGovernance.getVotingPower(user2);
        assertEq(
            votingPower,
            200_000 * 10 ** 18,
            "Voting power should match token balance"
        );
    }

    function test_RevertCreateProposal_NoVotingPower() public {
        // User with no tokens tries to create proposal
        vm.prank(makeAddr("nobody"));
        vm.expectRevert(DAOGovernance.NoVotingPower.selector);
        daoGovernance.createProposal(
            DAOGovernance.ProposalType.General,
            address(0),
            "",
            "Test"
        );
    }
}

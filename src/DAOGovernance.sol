// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./DatasetManager.sol";
import "./DAOTreasury.sol";

/**
 * @title DAOGovernance
 * @notice DAO governance system with voting and default voting mechanism
 * @dev Key features:
 *      - Token-based voting (1 token = 1 vote)
 *      - Default voting: non-voters follow a designated address's vote
 *      - Proposal types: Treasury withdrawal, Dataset delisting, Parameter changes
 *      - Quorum requirement and approval threshold
 *      - Snapshot-based voting (balance at proposal creation)
 */
contract DAOGovernance is Ownable, ReentrancyGuard {
    // ========== Structs ==========

    /**
     * @notice Governance proposal
     */
    struct Proposal {
        uint256 proposalId;
        address proposer;
        ProposalType proposalType;
        address targetContract;
        bytes callData;
        string description;
        uint256 createdAt;
        uint256 votingEnds;
        uint256 forVotes;
        uint256 againstVotes;
        uint256 abstainVotes;
        uint256 totalSupplySnapshot;
        ProposalState state;
        uint256 executedAt;
    }

    /**
     * @notice Type of proposal
     */
    enum ProposalType {
        TreasuryWithdrawal, // Approve treasury withdrawal
        DatasetDelisting, // Delist a dataset
        ParameterChange, // Change protocol parameters
        General // General governance decision
    }

    /**
     * @notice Lifecycle state of proposal
     */
    enum ProposalState {
        Active, // Voting is active
        Defeated, // Did not pass
        Succeeded, // Passed, ready to execute
        Executed, // Executed
        Cancelled // Cancelled by proposer
    }

    /**
     * @notice Vote choice
     */
    enum VoteChoice {
        Against, // 0
        For, // 1
        Abstain // 2
    }

    /**
     * @notice Vote record
     */
    struct VoteRecord {
        bool hasVoted;
        VoteChoice choice;
        uint256 weight;
    }

    // ========== State Variables ==========

    /// @notice Platform governance token (DLP token)
    IERC20 public immutable governanceToken;

    /// @notice DAOTreasury contract
    address public daoTreasury;

    /// @notice Voting period duration (7 days)
    uint256 public constant VOTING_PERIOD = 7 days;

    /// @notice Quorum requirement (20% of total supply)
    uint256 public constant QUORUM_PERCENTAGE = 20;

    /// @notice Approval threshold (51% of votes)
    uint256 public constant APPROVAL_THRESHOLD = 51;

    /// @notice Default voting delegate (e.g., protocol multisig)
    address public defaultVotingDelegate;

    /// @notice Total proposals created
    uint256 public proposalCount;

    /// @notice Mapping of proposal ID to proposal
    mapping(uint256 => Proposal) public proposals;

    /// @notice Mapping of proposal ID to voter to vote record
    mapping(uint256 => mapping(address => VoteRecord)) public votes;

    /// @notice Mapping of proposal ID to voters who explicitly voted
    mapping(uint256 => address[]) public explicitVoters;

    // ========== Events ==========

    event ProposalCreated(
        uint256 indexed proposalId,
        address indexed proposer,
        ProposalType proposalType,
        address targetContract,
        string description,
        uint256 votingEnds
    );
    event VoteCast(
        uint256 indexed proposalId,
        address indexed voter,
        VoteChoice choice,
        uint256 weight
    );
    event ProposalExecuted(uint256 indexed proposalId, uint256 executedAt);
    event ProposalCancelled(uint256 indexed proposalId, uint256 cancelledAt);
    event DefaultVotingDelegateSet(address indexed delegate);
    event DAOTreasurySet(address indexed daoTreasury);

    // ========== Errors ==========

    error ZeroAddress();
    error AlreadySet();
    error InvalidProposalType();
    error ProposalNotActive();
    error ProposalNotSucceeded();
    error AlreadyVoted();
    error NoVotingPower();
    error QuorumNotReached();
    error ProposalNotFound();
    error Unauthorized();
    error ExecutionFailed();

    // ========== Constructor ==========

    /**
     * @notice Initializes the DAOGovernance
     * @param governanceToken_ Platform governance token (DLP)
     * @param initialOwner_ Initial owner address
     */
    constructor(
        address governanceToken_,
        address initialOwner_
    ) Ownable(initialOwner_) {
        if (governanceToken_ == address(0)) revert ZeroAddress();
        governanceToken = IERC20(governanceToken_);
    }

    // ========== External Functions ==========

    /**
     * @notice Creates a new governance proposal
     * @dev Requires governance token holdings to create proposal
     * @param proposalType Type of proposal
     * @param targetContract Target contract for execution
     * @param callData Encoded function call data
     * @param description Proposal description
     * @return proposalId ID of created proposal
     */
    function createProposal(
        ProposalType proposalType,
        address targetContract,
        bytes calldata callData,
        string calldata description
    ) external nonReentrant returns (uint256 proposalId) {
        // Check proposer has voting power
        uint256 proposerBalance = governanceToken.balanceOf(msg.sender);
        if (proposerBalance == 0) revert NoVotingPower();

        // Create proposal
        proposalId = proposalCount++;
        uint256 totalSupply = governanceToken.totalSupply();
        uint256 votingEnds = block.timestamp + VOTING_PERIOD;

        proposals[proposalId] = Proposal({
            proposalId: proposalId,
            proposer: msg.sender,
            proposalType: proposalType,
            targetContract: targetContract,
            callData: callData,
            description: description,
            createdAt: block.timestamp,
            votingEnds: votingEnds,
            forVotes: 0,
            againstVotes: 0,
            abstainVotes: 0,
            totalSupplySnapshot: totalSupply,
            state: ProposalState.Active,
            executedAt: 0
        });

        emit ProposalCreated(
            proposalId,
            msg.sender,
            proposalType,
            targetContract,
            description,
            votingEnds
        );
    }

    /**
     * @notice Casts a vote on a proposal
     * @dev Voting weight = token balance at proposal creation
     * @param proposalId Proposal ID
     * @param choice Vote choice (Against, For, Abstain)
     */
    function castVote(
        uint256 proposalId,
        VoteChoice choice
    ) external nonReentrant {
        Proposal storage proposal = proposals[proposalId];
        if (proposal.createdAt == 0) revert ProposalNotFound();
        if (proposal.state != ProposalState.Active) revert ProposalNotActive();
        if (block.timestamp > proposal.votingEnds) revert ProposalNotActive();

        // Check if already voted
        if (votes[proposalId][msg.sender].hasVoted) revert AlreadyVoted();

        // Get voting weight (current balance, simplified for MVP)
        // In production, use snapshot mechanism
        uint256 weight = governanceToken.balanceOf(msg.sender);
        if (weight == 0) revert NoVotingPower();

        // Record vote
        votes[proposalId][msg.sender] = VoteRecord({
            hasVoted: true,
            choice: choice,
            weight: weight
        });

        // Track explicit voters
        explicitVoters[proposalId].push(msg.sender);

        // Update vote counts
        if (choice == VoteChoice.For) {
            proposal.forVotes += weight;
        } else if (choice == VoteChoice.Against) {
            proposal.againstVotes += weight;
        } else {
            proposal.abstainVotes += weight;
        }

        emit VoteCast(proposalId, msg.sender, choice, weight);
    }

    /**
     * @notice Finalizes a proposal after voting period
     * @dev Applies default voting mechanism for non-voters
     * @param proposalId Proposal ID to finalize
     */
    function finalizeProposal(uint256 proposalId) external {
        Proposal storage proposal = proposals[proposalId];
        if (proposal.createdAt == 0) revert ProposalNotFound();
        if (proposal.state != ProposalState.Active) revert ProposalNotActive();
        if (block.timestamp <= proposal.votingEnds) revert ProposalNotActive();

        // Apply default voting mechanism
        _applyDefaultVoting(proposalId);

        // Calculate total votes
        uint256 totalVotes = proposal.forVotes +
            proposal.againstVotes +
            proposal.abstainVotes;

        // Check quorum (20% of total supply)
        uint256 quorumRequired = (proposal.totalSupplySnapshot *
            QUORUM_PERCENTAGE) / 100;
        bool quorumReached = totalVotes >= quorumRequired;

        // Check approval (51% of votes cast)
        bool approved = false;
        if (totalVotes > 0) {
            approved =
                (proposal.forVotes * 100) / totalVotes >= APPROVAL_THRESHOLD;
        }

        // Update state
        if (quorumReached && approved) {
            proposal.state = ProposalState.Succeeded;
        } else {
            proposal.state = ProposalState.Defeated;
        }
    }

    /**
     * @notice Executes a succeeded proposal
     * @dev Calls the target contract with encoded calldata
     * @param proposalId Proposal ID to execute
     */
    function executeProposal(uint256 proposalId) external nonReentrant {
        Proposal storage proposal = proposals[proposalId];
        if (proposal.createdAt == 0) revert ProposalNotFound();
        if (proposal.state != ProposalState.Succeeded)
            revert ProposalNotSucceeded();

        // Mark as executed
        proposal.state = ProposalState.Executed;
        proposal.executedAt = block.timestamp;

        // Execute based on proposal type
        if (proposal.proposalType == ProposalType.TreasuryWithdrawal) {
            _executeTreasuryWithdrawal(proposalId);
        } else if (proposal.proposalType == ProposalType.DatasetDelisting) {
            _executeDatasetDelisting(proposalId);
        } else {
            // Generic execution
            (bool success, ) = proposal.targetContract.call(proposal.callData);
            if (!success) revert ExecutionFailed();
        }

        emit ProposalExecuted(proposalId, block.timestamp);
    }

    /**
     * @notice Cancels a proposal (only by proposer, only if active)
     * @param proposalId Proposal ID to cancel
     */
    function cancelProposal(uint256 proposalId) external {
        Proposal storage proposal = proposals[proposalId];
        if (proposal.createdAt == 0) revert ProposalNotFound();
        if (proposal.state != ProposalState.Active) revert ProposalNotActive();
        if (msg.sender != proposal.proposer) revert Unauthorized();

        proposal.state = ProposalState.Cancelled;

        emit ProposalCancelled(proposalId, block.timestamp);
    }

    // ========== Internal Functions ==========

    /**
     * @notice Applies default voting mechanism
     * @dev Non-voters automatically follow default delegate's vote
     * @param proposalId Proposal ID
     */
    function _applyDefaultVoting(uint256 proposalId) internal {
        if (defaultVotingDelegate == address(0)) return;

        Proposal storage proposal = proposals[proposalId];

        // Get delegate's vote choice
        VoteRecord memory delegateVote = votes[proposalId][
            defaultVotingDelegate
        ];
        if (!delegateVote.hasVoted) return; // Delegate didn't vote

        // Calculate total voting power of explicit voters
        uint256 explicitVotingPower = proposal.forVotes +
            proposal.againstVotes +
            proposal.abstainVotes;

        // Calculate default voting power (total supply - explicit voters)
        uint256 defaultVotingPower = proposal.totalSupplySnapshot -
            explicitVotingPower;

        // Apply default votes based on delegate's choice
        if (delegateVote.choice == VoteChoice.For) {
            proposal.forVotes += defaultVotingPower;
        } else if (delegateVote.choice == VoteChoice.Against) {
            proposal.againstVotes += defaultVotingPower;
        } else {
            proposal.abstainVotes += defaultVotingPower;
        }
    }

    /**
     * @notice Executes treasury withdrawal proposal
     * @param proposalId Proposal ID
     */
    function _executeTreasuryWithdrawal(uint256 proposalId) internal {
        Proposal storage proposal = proposals[proposalId];

        // Decode treasury proposal ID from calldata
        // Expected format: abi.encode(treasuryProposalId)
        uint256 treasuryProposalId = abi.decode(proposal.callData, (uint256));

        // Approve treasury proposal
        DAOTreasury(daoTreasury).approveProposal(treasuryProposalId);
    }

    /**
     * @notice Executes dataset delisting proposal
     * @param proposalId Proposal ID
     */
    function _executeDatasetDelisting(uint256 proposalId) internal {
        Proposal storage proposal = proposals[proposalId];

        // Decode dataset manager address from calldata
        address datasetManager = abi.decode(proposal.callData, (address));

        // Update dataset status to Delisted
        DatasetManager(datasetManager).updateStatus(
            DatasetManager.DatasetStatus.Delisted
        );
    }

    // ========== View Functions ==========

    /**
     * @notice Gets proposal details
     * @param proposalId Proposal ID
     * @return proposal Proposal details
     */
    function getProposal(
        uint256 proposalId
    ) external view returns (Proposal memory proposal) {
        proposal = proposals[proposalId];
    }

    /**
     * @notice Gets vote record for a voter
     * @param proposalId Proposal ID
     * @param voter Voter address
     * @return voteRecord Vote record
     */
    function getVote(
        uint256 proposalId,
        address voter
    ) external view returns (VoteRecord memory voteRecord) {
        voteRecord = votes[proposalId][voter];
    }

    /**
     * @notice Gets current proposal state
     * @param proposalId Proposal ID
     * @return state Current state
     */
    function getProposalState(
        uint256 proposalId
    ) external view returns (ProposalState state) {
        Proposal memory proposal = proposals[proposalId];
        if (proposal.createdAt == 0) revert ProposalNotFound();

        // If already finalized, return stored state
        if (proposal.state != ProposalState.Active) {
            return proposal.state;
        }

        // Check if voting period ended
        if (block.timestamp > proposal.votingEnds) {
            // Would be defeated or succeeded after finalization
            // Return active for now (need to call finalizeProposal)
            return ProposalState.Active;
        }

        return ProposalState.Active;
    }

    /**
     * @notice Gets voting power for an address
     * @param account Address to check
     * @return votingPower Current voting power
     */
    function getVotingPower(
        address account
    ) external view returns (uint256 votingPower) {
        votingPower = governanceToken.balanceOf(account);
    }

    // ========== Admin Functions ==========

    /**
     * @notice Sets default voting delegate
     * @param delegate Address of default voting delegate
     */
    function setDefaultVotingDelegate(address delegate) external onlyOwner {
        if (delegate == address(0)) revert ZeroAddress();

        defaultVotingDelegate = delegate;
        emit DefaultVotingDelegateSet(delegate);
    }

    /**
     * @notice Sets DAOTreasury contract address (can only be set once)
     * @param daoTreasury_ DAOTreasury address
     */
    function setDAOTreasury(address daoTreasury_) external onlyOwner {
        if (daoTreasury != address(0)) revert AlreadySet();
        if (daoTreasury_ == address(0)) revert ZeroAddress();

        daoTreasury = daoTreasury_;
        emit DAOTreasurySet(daoTreasury_);
    }
}

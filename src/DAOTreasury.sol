// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title DAOTreasury
 * @notice Manages project operational funds from IDO with DAO governance
 * @dev Key features:
 *      - Escrows USDC raised from IDO for project operations
 *      - Projects submit withdrawal proposals
 *      - DAO Governance approves/rejects proposals via voting
 *      - Transparent fund tracking and usage history
 *      - Emergency pause mechanism for security
 */
contract DAOTreasury is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ========== Structs ==========

    /**
     * @notice Withdrawal proposal submitted by project
     */
    struct WithdrawalProposal {
        uint256 proposalId;
        address projectAddress;
        address datasetToken;
        uint256 amount;
        string purpose;
        uint256 submittedAt;
        ProposalStatus status;
        uint256 approvedAt;
        uint256 executedAt;
    }

    /**
     * @notice Proposal lifecycle status
     */
    enum ProposalStatus {
        Pending, // Submitted, waiting for DAO vote
        Approved, // DAO approved, ready to execute
        Rejected, // DAO rejected
        Executed, // Funds withdrawn
        Cancelled // Cancelled by project
    }

    // ========== State Variables ==========

    /// @notice USDC token contract
    IERC20 public immutable usdc;

    /// @notice DAO Governance contract address
    address public daoGovernance;

    /// @notice IDO contract address
    address public idoContract;

    /// @notice Emergency pause flag
    bool public paused;

    /// @notice Total proposals submitted
    uint256 public proposalCount;

    /// @notice Mapping of proposal ID to proposal details
    mapping(uint256 => WithdrawalProposal) public proposals;

    /// @notice Mapping of dataset token to available balance
    mapping(address => uint256) public availableBalance;

    /// @notice Mapping of dataset token to total withdrawn
    mapping(address => uint256) public totalWithdrawn;

    /// @notice Mapping of dataset token to total deposited
    mapping(address => uint256) public totalDeposited;

    /// @notice Mapping of dataset token to project address
    mapping(address => address) public projectAddresses;

    // ========== Events ==========

    event FundsDeposited(
        address indexed datasetToken,
        uint256 amount,
        uint256 totalDeposited
    );
    event ProposalSubmitted(
        uint256 indexed proposalId,
        address indexed projectAddress,
        address indexed datasetToken,
        uint256 amount,
        string purpose
    );
    event ProposalApproved(uint256 indexed proposalId, uint256 approvedAt);
    event ProposalRejected(uint256 indexed proposalId, uint256 rejectedAt);
    event ProposalExecuted(
        uint256 indexed proposalId,
        uint256 executedAt,
        uint256 amount
    );
    event ProposalCancelled(uint256 indexed proposalId, uint256 cancelledAt);
    event DAOGovernanceSet(address indexed daoGovernance);
    event IDOContractSet(address indexed idoContract);
    event Paused(uint256 timestamp);
    event Unpaused(uint256 timestamp);

    // ========== Errors ==========

    error ZeroAddress();
    error ZeroAmount();
    error AlreadySet();
    error Unauthorized();
    error ContractPaused();
    error ProposalNotFound();
    error InvalidProposalStatus();
    error InsufficientBalance();
    error EmptyString();

    // ========== Constructor ==========

    /**
     * @notice Initializes the DAOTreasury
     * @param usdc_ USDC token address
     * @param initialOwner_ Initial owner address
     */
    constructor(address usdc_, address initialOwner_) Ownable(initialOwner_) {
        if (usdc_ == address(0)) revert ZeroAddress();
        usdc = IERC20(usdc_);
    }

    // ========== External Functions ==========

    /**
     * @notice Deposits funds from IDO into treasury
     * @dev Only IDO contract can deposit
     * @param datasetToken Dataset token address
     * @param projectAddress Project owner address
     * @param amount Amount of USDC to deposit
     */
    function depositFunds(
        address datasetToken,
        address projectAddress,
        uint256 amount
    ) external nonReentrant {
        if (msg.sender != idoContract) revert Unauthorized();
        if (amount == 0) revert ZeroAmount();
        if (datasetToken == address(0) || projectAddress == address(0))
            revert ZeroAddress();

        // Transfer USDC from IDO contract
        usdc.safeTransferFrom(msg.sender, address(this), amount);

        // Update balances
        availableBalance[datasetToken] += amount;
        totalDeposited[datasetToken] += amount;

        // Store project address
        if (projectAddresses[datasetToken] == address(0)) {
            projectAddresses[datasetToken] = projectAddress;
        }

        emit FundsDeposited(datasetToken, amount, totalDeposited[datasetToken]);
    }

    /**
     * @notice Submits a withdrawal proposal
     * @dev Only project address can submit proposals
     * @param datasetToken Dataset token address
     * @param amount Amount of USDC to withdraw
     * @param purpose Description of fund usage purpose
     * @return proposalId ID of the created proposal
     */
    function submitProposal(
        address datasetToken,
        uint256 amount,
        string calldata purpose
    ) external nonReentrant returns (uint256 proposalId) {
        if (paused) revert ContractPaused();
        if (msg.sender != projectAddresses[datasetToken]) revert Unauthorized();
        if (amount == 0) revert ZeroAmount();
        if (amount > availableBalance[datasetToken])
            revert InsufficientBalance();
        if (bytes(purpose).length == 0) revert EmptyString();

        // Create proposal
        proposalId = proposalCount++;
        proposals[proposalId] = WithdrawalProposal({
            proposalId: proposalId,
            projectAddress: msg.sender,
            datasetToken: datasetToken,
            amount: amount,
            purpose: purpose,
            submittedAt: block.timestamp,
            status: ProposalStatus.Pending,
            approvedAt: 0,
            executedAt: 0
        });

        emit ProposalSubmitted(
            proposalId,
            msg.sender,
            datasetToken,
            amount,
            purpose
        );
    }

    /**
     * @notice Approves a withdrawal proposal
     * @dev Only DAO Governance can approve
     * @param proposalId Proposal ID to approve
     */
    function approveProposal(uint256 proposalId) external {
        if (msg.sender != daoGovernance) revert Unauthorized();

        WithdrawalProposal storage proposal = proposals[proposalId];
        if (proposal.submittedAt == 0) revert ProposalNotFound();
        if (proposal.status != ProposalStatus.Pending)
            revert InvalidProposalStatus();

        proposal.status = ProposalStatus.Approved;
        proposal.approvedAt = block.timestamp;

        emit ProposalApproved(proposalId, block.timestamp);
    }

    /**
     * @notice Rejects a withdrawal proposal
     * @dev Only DAO Governance can reject
     * @param proposalId Proposal ID to reject
     */
    function rejectProposal(uint256 proposalId) external {
        if (msg.sender != daoGovernance) revert Unauthorized();

        WithdrawalProposal storage proposal = proposals[proposalId];
        if (proposal.submittedAt == 0) revert ProposalNotFound();
        if (proposal.status != ProposalStatus.Pending)
            revert InvalidProposalStatus();

        proposal.status = ProposalStatus.Rejected;

        emit ProposalRejected(proposalId, block.timestamp);
    }

    /**
     * @notice Executes an approved proposal and transfers funds
     * @dev Project can execute after DAO approval
     * @param proposalId Proposal ID to execute
     */
    function executeProposal(uint256 proposalId) external nonReentrant {
        if (paused) revert ContractPaused();

        WithdrawalProposal storage proposal = proposals[proposalId];
        if (proposal.submittedAt == 0) revert ProposalNotFound();
        if (proposal.status != ProposalStatus.Approved)
            revert InvalidProposalStatus();
        if (msg.sender != proposal.projectAddress) revert Unauthorized();

        // Check balance
        if (proposal.amount > availableBalance[proposal.datasetToken])
            revert InsufficientBalance();

        // Update state
        proposal.status = ProposalStatus.Executed;
        proposal.executedAt = block.timestamp;
        availableBalance[proposal.datasetToken] -= proposal.amount;
        totalWithdrawn[proposal.datasetToken] += proposal.amount;

        // Transfer USDC to project
        usdc.safeTransfer(proposal.projectAddress, proposal.amount);

        emit ProposalExecuted(proposalId, block.timestamp, proposal.amount);
    }

    /**
     * @notice Cancels a pending proposal
     * @dev Only project can cancel their own pending proposals
     * @param proposalId Proposal ID to cancel
     */
    function cancelProposal(uint256 proposalId) external {
        WithdrawalProposal storage proposal = proposals[proposalId];
        if (proposal.submittedAt == 0) revert ProposalNotFound();
        if (proposal.status != ProposalStatus.Pending)
            revert InvalidProposalStatus();
        if (msg.sender != proposal.projectAddress) revert Unauthorized();

        proposal.status = ProposalStatus.Cancelled;

        emit ProposalCancelled(proposalId, block.timestamp);
    }

    // ========== View Functions ==========

    /**
     * @notice Gets proposal details
     * @param proposalId Proposal ID
     * @return proposal Proposal details
     */
    function getProposal(
        uint256 proposalId
    ) external view returns (WithdrawalProposal memory proposal) {
        proposal = proposals[proposalId];
    }

    /**
     * @notice Gets treasury balance for a dataset
     * @param datasetToken Dataset token address
     * @return available Available balance
     * @return withdrawn Total withdrawn amount
     * @return deposited Total deposited amount
     */
    function getTreasuryBalance(
        address datasetToken
    )
        external
        view
        returns (uint256 available, uint256 withdrawn, uint256 deposited)
    {
        available = availableBalance[datasetToken];
        withdrawn = totalWithdrawn[datasetToken];
        deposited = totalDeposited[datasetToken];
    }

    /**
     * @notice Gets contract's USDC balance
     * @return USDC balance of this contract
     */
    function getContractBalance() external view returns (uint256) {
        return usdc.balanceOf(address(this));
    }

    // ========== Admin Functions ==========

    /**
     * @notice Sets DAO Governance contract address (can only be set once)
     * @param daoGovernance_ DAO Governance address
     */
    function setDAOGovernance(address daoGovernance_) external onlyOwner {
        if (daoGovernance != address(0)) revert AlreadySet();
        if (daoGovernance_ == address(0)) revert ZeroAddress();

        daoGovernance = daoGovernance_;
        emit DAOGovernanceSet(daoGovernance_);
    }

    /**
     * @notice Sets IDO contract address (can only be set once)
     * @param idoContract_ IDO contract address
     */
    function setIDOContract(address idoContract_) external onlyOwner {
        if (idoContract != address(0)) revert AlreadySet();
        if (idoContract_ == address(0)) revert ZeroAddress();

        idoContract = idoContract_;
        emit IDOContractSet(idoContract_);
    }

    /**
     * @notice Pauses the contract (emergency only)
     * @dev Prevents new proposals and executions
     */
    function pause() external onlyOwner {
        paused = true;
        emit Paused(block.timestamp);
    }

    /**
     * @notice Unpauses the contract
     */
    function unpause() external onlyOwner {
        paused = false;
        emit Unpaused(block.timestamp);
    }
}

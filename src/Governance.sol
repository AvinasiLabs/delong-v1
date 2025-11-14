// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/governance/utils/IVotes.sol";
import "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import "./interfaces/IUniswap.sol";
import "./interfaces/IIDO.sol";
import "./interfaces/IGovernanceStrategy.sol";

/**
 * @title Governance
 * @notice Per-IDO governance with integrated treasury and LP management
 * @dev Key features:
 *      - Bound to single IDO instance
 *      - Pluggable governance strategy (allows custom voting rules)
 *      - Default voting mechanism: simple majority (50% quorum)
 *      - Integrated treasury for fund custody
 *      - LP token management (locked until delisting)
 *      - Four proposal types: Funding, Pricing, Delist, GovernanceUpgrade
 *
 * Strategy Pattern:
 *      - Implements IGovernanceStrategy interface internally (default strategy)
 *      - Can switch to external strategy via governance upgrade proposal
 *      - External strategies call back to this contract's execution methods
 */
contract Governance is ReentrancyGuard, ERC165, IGovernanceStrategy {
    using SafeERC20 for IERC20;

    // ========== Core Binding ==========

    /// @notice IDO contract address (immutable, single source of truth)
    address public immutable ido;

    /// @notice USDC token
    IERC20 public immutable usdc;

    // ========== Governance Strategy ==========

    /// @notice Current governance strategy (can be upgraded via proposal)
    /// @dev When governanceStrategy == address(this), uses internal default strategy
    ///      When governanceStrategy != address(this), delegates to external strategy
    address public governanceStrategy;

    // ========== Proposal Types ==========

    enum ProposalType {
        Funding, // Treasury withdrawal
        Pricing, // Rental price change
        Delist, // Dataset delisting
        GovernanceUpgrade // Upgrade governance strategy
    }

    enum ProposalStatus {
        Pending, // Voting in progress
        Succeeded, // Passed, waiting for timelock
        Defeated, // Failed
        Executed, // Executed
        Canceled // Canceled
    }

    // ========== Proposal Structure ==========

    struct Proposal {
        uint256 id;
        ProposalType proposalType;
        ProposalStatus status;
        address proposer;
        // Voting data
        uint256 forVotes; // Explicit votes FOR
        uint256 againstVotes; // Explicit votes AGAINST
        uint256 totalSupply; // Snapshot of token supply at creation
        uint256 snapshotBlock; // Block number for voting power snapshot (prevents double voting)
        // Timing
        uint256 startTime;
        uint256 endTime; // startTime + VOTING_PERIOD
        // Proposal-specific data
        uint256 amount; // For Funding proposals
        address recipient; // For Funding proposals
        uint256 newPrice; // For Pricing proposals
        address newStrategy; // For GovernanceUpgrade proposals
        string description;
    }

    // ========== State Variables ==========

    /// @notice All proposals
    Proposal[] public proposals;

    /// @notice Voting records: proposalId => voter => hasVoted
    mapping(uint256 => mapping(address => bool)) public hasVoted;

    // ========== Treasury (integrated from old Treasury contract) ==========

    /// @notice Available treasury balance
    uint256 public treasuryBalance;

    // ========== LP Management ==========

    /// @notice Uniswap V2 LP token address
    address public lpToken;

    /// @notice Amount of LP tokens locked
    uint256 public lpAmount;

    /// @notice Whether dataset has been delisted
    bool public isDelisted;

    /// @notice Uniswap V2 Router
    address public immutable uniswapV2Router;

    /// @notice Uniswap V2 Factory
    address public immutable uniswapV2Factory;

    /// @notice Total USDC available for refund after delisting
    uint256 public refundPoolUSDC;

    /// @notice Total token supply snapshot at delisting (for refund calculation)
    uint256 public refundPoolTokenSupply;

    /// @notice User refund claim status
    mapping(address => bool) public hasClaimedRefund;

    // ========== Constants ==========

    uint256 public constant VOTING_PERIOD = 7 days;

    // Proposal threshold (basis points, 10000 = 100%)
    uint256 public constant PROPOSAL_THRESHOLD = 100; // 1% of total supply

    // Voting threshold (basis points, 10000 = 100%)
    // All proposals require explicit FOR votes >= 50% of total supply to pass
    uint256 public constant QUORUM_THRESHOLD = 5000; // 50% simple majority

    // ========== Events ==========

    event FundingProposalCreated(
        uint256 indexed proposalId,
        address indexed proposer,
        address indexed recipient,
        uint256 amount,
        string description,
        uint256 startTime,
        uint256 endTime
    );

    event PricingProposalCreated(
        uint256 indexed proposalId,
        address indexed proposer,
        uint256 newPrice,
        string description,
        uint256 startTime,
        uint256 endTime
    );

    event DelistProposalCreated(
        uint256 indexed proposalId,
        address indexed proposer,
        string description,
        uint256 startTime,
        uint256 endTime
    );

    event GovernanceUpgradeProposalCreated(
        uint256 indexed proposalId,
        address indexed proposer,
        address indexed newStrategy,
        string description,
        uint256 startTime,
        uint256 endTime
    );

    event VoteCast(
        address indexed voter,
        uint256 indexed proposalId,
        bool support,
        uint256 weight
    );

    event ProposalExecuted(
        uint256 indexed proposalId,
        ProposalType proposalType
    );

    event FundsDeposited(uint256 amount, uint256 totalBalance);
    event FundsWithdrawn(
        uint256 indexed proposalId,
        address indexed recipient,
        uint256 amount
    );
    event PriceUpdated(uint256 indexed proposalId, uint256 newPrice);

    event LPLocked(address indexed lpToken, uint256 amount);
    event DatasetDelisted(uint256 totalUSDC, uint256 totalTokenSupply);
    event RefundClaimed(
        address indexed user,
        uint256 tokenAmount,
        uint256 usdcAmount
    );
    event GovernanceStrategyUpdated(
        address indexed oldStrategy,
        address indexed newStrategy
    );

    // ========== Errors ==========

    error Unauthorized();
    error ZeroAddress();
    error ZeroAmount();
    error InvalidProposal();
    error BelowProposalThreshold(); // Proposer holds less than required threshold
    error AlreadyVoted();
    error VotingClosed();
    error InvalidStatus();
    error InsufficientBalance();
    error AlreadyDelisted();
    error NotDelisted();
    error AlreadyClaimed();
    error NoTokens();
    error InvalidStrategy(); // New strategy doesn't implement IGovernanceStrategy
    error OnlyStrategy(); // Only current governance strategy can call this function

    // ========== Constructor ==========

    /**
     * @notice Initialize governance for a specific IDO
     * @param ido_ IDO contract address
     * @param usdc_ USDC token address
     * @param uniswapV2Router_ Uniswap V2 Router address
     * @param uniswapV2Factory_ Uniswap V2 Factory address
     */
    constructor(
        address ido_,
        address usdc_,
        address uniswapV2Router_,
        address uniswapV2Factory_
    ) {
        if (ido_ == address(0) || usdc_ == address(0)) revert ZeroAddress();
        if (uniswapV2Router_ == address(0) || uniswapV2Factory_ == address(0))
            revert ZeroAddress();

        ido = ido_;
        usdc = IERC20(usdc_);
        uniswapV2Router = uniswapV2Router_;
        uniswapV2Factory = uniswapV2Factory_;

        // Initialize with default strategy (self)
        governanceStrategy = address(this);
    }

    // ========== Proposal Creation ==========

    /**
     * @notice Create funding proposal
     * @param amount Amount to withdraw
     * @param recipient Recipient address
     * @param description Proposal description
     */
    function createFundingProposal(
        uint256 amount,
        address recipient,
        string calldata description
    ) external returns (uint256 proposalId) {
        if (amount == 0) revert ZeroAmount();
        if (recipient == address(0)) revert ZeroAddress();
        if (isDelisted) revert AlreadyDelisted();

        proposalId = _createProposal(ProposalType.Funding, description);
        Proposal storage p = proposals[proposalId];
        p.amount = amount;
        p.recipient = recipient;

        emit FundingProposalCreated(
            proposalId,
            msg.sender,
            recipient,
            amount,
            description,
            p.startTime,
            p.endTime
        );
    }

    /**
     * @notice Create pricing proposal
     * @param newPrice New rental price (USDC per hour, 6 decimals)
     * @param description Proposal description
     */
    function createPricingProposal(
        uint256 newPrice,
        string calldata description
    ) external returns (uint256 proposalId) {
        if (newPrice == 0) revert ZeroAmount();
        if (isDelisted) revert AlreadyDelisted();

        proposalId = _createProposal(ProposalType.Pricing, description);
        Proposal storage p = proposals[proposalId];
        p.newPrice = newPrice;

        emit PricingProposalCreated(
            proposalId,
            msg.sender,
            newPrice,
            description,
            p.startTime,
            p.endTime
        );
    }

    /**
     * @notice Create delisting proposal
     * @param description Reason for delisting
     */
    function createDelistProposal(
        string calldata description
    ) external returns (uint256 proposalId) {
        if (isDelisted) revert AlreadyDelisted();

        proposalId = _createProposal(ProposalType.Delist, description);
        Proposal storage p = proposals[proposalId];

        emit DelistProposalCreated(
            proposalId,
            msg.sender,
            description,
            p.startTime,
            p.endTime
        );
    }

    /**
     * @notice Create governance upgrade proposal
     * @dev Allows switching to custom governance strategy
     * @param newStrategy_ Address of new strategy contract
     * @param description Reason for upgrade
     */
    function createGovernanceUpgradeProposal(
        address newStrategy_,
        string calldata description
    ) external returns (uint256 proposalId) {
        if (newStrategy_ == address(0)) revert ZeroAddress();
        if (isDelisted) revert AlreadyDelisted();

        // Validate that newStrategy implements IGovernanceStrategy using ERC-165
        try
            IERC165(newStrategy_).supportsInterface(
                type(IGovernanceStrategy).interfaceId
            )
        returns (bool supported) {
            if (!supported) revert InvalidStrategy();
        } catch {
            revert InvalidStrategy();
        }

        proposalId = _createProposal(
            ProposalType.GovernanceUpgrade,
            description
        );
        Proposal storage p = proposals[proposalId];
        p.newStrategy = newStrategy_;

        emit GovernanceUpgradeProposalCreated(
            proposalId,
            msg.sender,
            newStrategy_,
            description,
            p.startTime,
            p.endTime
        );
    }

    /**
     * @notice Internal: Create proposal
     * @dev Checks that proposer meets threshold using current governance strategy
     */
    function _createProposal(
        ProposalType proposalType,
        string calldata description
    ) internal returns (uint256 proposalId) {
        address token = IIDO(ido).tokenAddress();
        uint256 totalSupply = IERC20(token).totalSupply();
        uint256 proposerBalance = IERC20(token).balanceOf(msg.sender);

        // Use governance strategy to check proposal threshold
        uint256 threshold = IGovernanceStrategy(governanceStrategy)
            .getProposalThreshold();
        if (proposerBalance * 10000 < totalSupply * threshold) {
            revert BelowProposalThreshold();
        }

        proposalId = proposals.length;
        uint256 startTime = block.timestamp;
        uint256 endTime = startTime + VOTING_PERIOD;
        uint256 snapshotBlock = block.number - 1; // Use previous block for snapshot

        proposals.push(
            Proposal({
                id: proposalId,
                proposalType: proposalType,
                status: ProposalStatus.Pending,
                proposer: msg.sender,
                forVotes: 0,
                againstVotes: 0,
                totalSupply: totalSupply,
                snapshotBlock: snapshotBlock,
                startTime: startTime,
                endTime: endTime,
                amount: 0,
                recipient: address(0),
                newPrice: 0,
                newStrategy: address(0),
                description: description
            })
        );
    }

    // ========== Voting ==========

    /**
     * @notice Cast vote on a proposal
     * @dev Uses snapshot voting power to prevent double voting via token transfers
     *      Tokens that don't vote are counted as AGAINST (default reject)
     * @param proposalId Proposal ID
     * @param support True for FOR, false for AGAINST
     */
    function castVote(uint256 proposalId, bool support) external {
        if (proposalId >= proposals.length) revert InvalidProposal();

        Proposal storage p = proposals[proposalId];

        if (block.timestamp >= p.endTime) revert VotingClosed();
        if (hasVoted[proposalId][msg.sender]) revert AlreadyVoted();

        address token = IIDO(ido).tokenAddress();

        // Use voting power at snapshot block (prevents double voting)
        uint256 weight = IVotes(token).getPastVotes(
            msg.sender,
            p.snapshotBlock
        );
        if (weight == 0) revert NoTokens();

        hasVoted[proposalId][msg.sender] = true;

        if (support) {
            p.forVotes += weight;
        } else {
            p.againstVotes += weight;
        }

        emit VoteCast(msg.sender, proposalId, support, weight);
    }

    // ========== Proposal Execution ==========

    /**
     * @notice Execute a passed proposal
     * @dev Can be executed immediately after voting period ends (no timelock)
     * @param proposalId Proposal ID
     */
    function executeProposal(uint256 proposalId) external nonReentrant {
        if (proposalId >= proposals.length) revert InvalidProposal();

        Proposal storage p = proposals[proposalId];

        // Update status if voting period ended
        if (
            p.status == ProposalStatus.Pending && block.timestamp >= p.endTime
        ) {
            ProposalStatus newStatus = getProposalStatus(proposalId);
            p.status = newStatus;
        }

        if (p.status != ProposalStatus.Succeeded) revert InvalidStatus();

        p.status = ProposalStatus.Executed;

        if (p.proposalType == ProposalType.Funding) {
            _executeFunding(p);
        } else if (p.proposalType == ProposalType.Pricing) {
            _executePricing(p);
        } else if (p.proposalType == ProposalType.Delist) {
            _executeDelist();
        } else if (p.proposalType == ProposalType.GovernanceUpgrade) {
            _executeGovernanceUpgrade(p);
        }

        emit ProposalExecuted(proposalId, p.proposalType);
    }

    /**
     * @notice Execute funding proposal
     */
    function _executeFunding(Proposal storage p) internal {
        if (p.amount > treasuryBalance) revert InsufficientBalance();

        treasuryBalance -= p.amount;

        usdc.safeTransfer(p.recipient, p.amount);

        emit FundsWithdrawn(p.id, p.recipient, p.amount);
    }

    /**
     * @notice Execute pricing proposal
     */
    function _executePricing(Proposal storage p) internal {
        // Call IDO contract to update hourly rate
        IIDO(ido).updateHourlyRate(p.newPrice);

        emit PriceUpdated(p.id, p.newPrice);
    }

    /**
     * @notice Execute delist proposal
     */
    function _executeDelist() internal {
        if (lpToken == address(0) || lpAmount == 0) {
            // No LP to remove, just mark as delisted
            isDelisted = true;
            emit DatasetDelisted(0, 0);
            return;
        }

        isDelisted = true;

        address token = IIDO(ido).tokenAddress();
        uint256 tokenSupply = IERC20(token).totalSupply();

        // Remove liquidity from Uniswap
        IERC20(lpToken).forceApprove(uniswapV2Router, lpAmount);

        (, uint256 amountUSDC) = IUniswapV2Router02(uniswapV2Router)
            .removeLiquidity(
            token,
            address(usdc),
            lpAmount,
            0, // Accept any amount
            0, // Accept any amount
            address(this),
            block.timestamp + 300
        );

        // Note: Dataset tokens returned from LP are sent to address(this)
        // They remain locked here (not burned, but effectively removed from circulation)

        // Record refund pool info
        uint256 totalRefundUSDC = amountUSDC + treasuryBalance;
        refundPoolUSDC = totalRefundUSDC;
        refundPoolTokenSupply = tokenSupply;

        // Clear treasury balance (now in refund pool)
        treasuryBalance = 0;

        emit DatasetDelisted(totalRefundUSDC, tokenSupply);
    }

    /**
     * @notice Execute governance upgrade proposal
     */
    function _executeGovernanceUpgrade(Proposal storage p) internal {
        address oldStrategy = governanceStrategy;
        governanceStrategy = p.newStrategy;

        emit GovernanceStrategyUpdated(oldStrategy, p.newStrategy);
    }

    // ========== Refund Claims (after delisting) ==========

    /**
     * @notice Claim refund after delisting
     * @dev User must transfer their tokens to this contract to claim refund
     */
    function claimRefund() external nonReentrant {
        if (!isDelisted) revert NotDelisted();
        if (hasClaimedRefund[msg.sender]) revert AlreadyClaimed();

        address token = IIDO(ido).tokenAddress();
        uint256 userTokens = IERC20(token).balanceOf(msg.sender);
        if (userTokens == 0) revert NoTokens();

        hasClaimedRefund[msg.sender] = true;

        // Transfer user's tokens to this contract (burn/lock them)
        IERC20(token).safeTransferFrom(msg.sender, address(this), userTokens);

        // Calculate refund: (userTokens / totalSupply) * totalUSDC
        uint256 refundAmount = (userTokens * refundPoolUSDC) /
            refundPoolTokenSupply;

        usdc.safeTransfer(msg.sender, refundAmount);

        emit RefundClaimed(msg.sender, userTokens, refundAmount);
    }

    // ========== Treasury Management ==========

    /**
     * @notice Deposit funds from IDO (called after successful launch)
     * @param amount Amount of USDC to deposit
     */
    function depositFunds(uint256 amount) external {
        if (msg.sender != ido) revert Unauthorized();
        if (amount == 0) revert ZeroAmount();

        usdc.safeTransferFrom(msg.sender, address(this), amount);

        treasuryBalance += amount;

        emit FundsDeposited(amount, treasuryBalance);
    }

    // ========== LP Management ==========

    /**
     * @notice Lock LP tokens (called by IDO after launch)
     * @param lpToken_ LP token address
     * @param amount LP token amount
     */
    function lockLP(address lpToken_, uint256 amount) external {
        if (msg.sender != ido) revert Unauthorized();
        if (lpToken_ == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        // Transfer LP tokens from IDO to Governance for locking
        IERC20(lpToken_).safeTransferFrom(msg.sender, address(this), amount);

        lpToken = lpToken_;
        lpAmount = amount;

        emit LPLocked(lpToken_, amount);
    }

    // ========== View Functions ==========

    /**
     * @notice Get proposal status (with default voting logic)
     */
    function getProposalStatus(
        uint256 proposalId
    ) public view returns (ProposalStatus) {
        if (proposalId >= proposals.length) revert InvalidProposal();

        Proposal storage p = proposals[proposalId];

        // If already executed or canceled, return that status
        if (
            p.status == ProposalStatus.Executed ||
            p.status == ProposalStatus.Canceled
        ) {
            return p.status;
        }

        // If voting period not ended, return Pending
        if (block.timestamp < p.endTime) {
            return ProposalStatus.Pending;
        }

        // Count votes using governance strategy (type-safe per proposal type)
        bool passed;
        if (p.proposalType == ProposalType.Funding) {
            passed = IGovernanceStrategy(governanceStrategy).countFundingVotes(
                p.forVotes,
                p.againstVotes,
                p.totalSupply
            );
        } else if (p.proposalType == ProposalType.Pricing) {
            passed = IGovernanceStrategy(governanceStrategy).countPricingVotes(
                p.forVotes,
                p.againstVotes,
                p.totalSupply
            );
        } else if (p.proposalType == ProposalType.Delist) {
            passed = IGovernanceStrategy(governanceStrategy).countDelistVotes(
                p.forVotes,
                p.againstVotes,
                p.totalSupply
            );
        } else {
            // ProposalType.GovernanceUpgrade
            passed = IGovernanceStrategy(governanceStrategy)
                .countGovernanceUpgradeVotes(
                    p.forVotes,
                    p.againstVotes,
                    p.totalSupply
                );
        }

        return passed ? ProposalStatus.Succeeded : ProposalStatus.Defeated;
    }

    // ========== ERC-165 Interface Detection ==========

    /**
     * @notice Check if contract implements an interface
     * @dev Implements ERC-165 standard
     * @param interfaceId Interface identifier
     * @return True if contract implements the interface
     */
    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override(ERC165, IERC165) returns (bool) {
        return
            interfaceId == type(IGovernanceStrategy).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    // ========== IGovernanceStrategy Implementation (Default Strategy) ==========

    /**
     * @notice Count votes for funding proposal
     * @dev Default strategy: 50% simple majority
     */
    function countFundingVotes(
        uint256 forVotes,
        uint256 againstVotes,
        uint256 totalSupply
    ) external view override returns (bool) {
        return ((forVotes * 10000) / totalSupply) >= QUORUM_THRESHOLD;
    }

    /**
     * @notice Count votes for pricing proposal
     * @dev Default strategy: 50% simple majority
     */
    function countPricingVotes(
        uint256 forVotes,
        uint256 againstVotes,
        uint256 totalSupply
    ) external view override returns (bool) {
        return ((forVotes * 10000) / totalSupply) >= QUORUM_THRESHOLD;
    }

    /**
     * @notice Count votes for delist proposal
     * @dev Default strategy: 50% simple majority
     */
    function countDelistVotes(
        uint256 forVotes,
        uint256 againstVotes,
        uint256 totalSupply
    ) external view override returns (bool) {
        return ((forVotes * 10000) / totalSupply) >= QUORUM_THRESHOLD;
    }

    /**
     * @notice Count votes for governance upgrade proposal
     * @dev Default strategy: 50% simple majority
     */
    function countGovernanceUpgradeVotes(
        uint256 forVotes,
        uint256 againstVotes,
        uint256 totalSupply
    ) external view override returns (bool) {
        return ((forVotes * 10000) / totalSupply) >= QUORUM_THRESHOLD;
    }

    /**
     * @notice Get the proposal creation threshold
     * @dev Default strategy: 1% (100 basis points)
     * @return Threshold in basis points
     */
    function getProposalThreshold() external pure override returns (uint256) {
        return PROPOSAL_THRESHOLD;
    }

    /**
     * @notice Get the voting period duration
     * @dev Default strategy: 7 days
     * @return Duration in seconds
     */
    function getVotingPeriod() external pure override returns (uint256) {
        return VOTING_PERIOD;
    }
}

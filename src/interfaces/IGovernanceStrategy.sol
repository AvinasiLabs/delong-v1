// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/**
 * @title IGovernanceStrategy
 * @notice Interface for pluggable governance voting strategies
 * @dev Allows projects to customize voting rules while keeping execution layer unchanged
 *
 * Core Design:
 * - Strategy Layer: Implements voting logic (this interface)
 * - Execution Layer: Governance contract that holds funds and executes proposals
 * - Uses ERC-165 for interface detection
 *
 * Default Strategy:
 * - Governance contract implements this interface internally
 * - Uses simple majority voting (50% quorum for all proposal types)
 *
 * Custom Strategy:
 * - Projects can deploy custom strategy contracts
 * - Must implement IERC165 and return true for supportsInterface(type(IGovernanceStrategy).interfaceId)
 * - Use governance upgrade proposal to switch strategy
 */
interface IGovernanceStrategy is IERC165 {
    /**
     * @notice Count votes for funding proposal
     * @dev Determines if a funding withdrawal proposal passes
     * @param forVotes Number of FOR votes
     * @param againstVotes Number of AGAINST votes
     * @param totalSupply Total token supply at snapshot
     * @return Whether the proposal passed
     */
    function countFundingVotes(
        uint256 forVotes,
        uint256 againstVotes,
        uint256 totalSupply
    ) external view returns (bool);

    /**
     * @notice Count votes for pricing proposal
     * @dev Determines if a rental price change proposal passes
     * @param forVotes Number of FOR votes
     * @param againstVotes Number of AGAINST votes
     * @param totalSupply Total token supply at snapshot
     * @return Whether the proposal passed
     */
    function countPricingVotes(
        uint256 forVotes,
        uint256 againstVotes,
        uint256 totalSupply
    ) external view returns (bool);

    /**
     * @notice Count votes for delist proposal
     * @dev Determines if a dataset delisting proposal passes
     * @param forVotes Number of FOR votes
     * @param againstVotes Number of AGAINST votes
     * @param totalSupply Total token supply at snapshot
     * @return Whether the proposal passed
     */
    function countDelistVotes(
        uint256 forVotes,
        uint256 againstVotes,
        uint256 totalSupply
    ) external view returns (bool);

    /**
     * @notice Count votes for governance upgrade proposal
     * @dev Determines if a governance strategy upgrade proposal passes
     * @param forVotes Number of FOR votes
     * @param againstVotes Number of AGAINST votes
     * @param totalSupply Total token supply at snapshot
     * @return Whether the proposal passed
     */
    function countGovernanceUpgradeVotes(
        uint256 forVotes,
        uint256 againstVotes,
        uint256 totalSupply
    ) external view returns (bool);

    /**
     * @notice Get the proposal creation threshold
     * @dev Minimum percentage of total supply required to create proposal
     * @return Threshold in basis points (e.g., 100 = 1%)
     */
    function getProposalThreshold() external view returns (uint256);

    /**
     * @notice Get the voting period duration
     * @return Duration in seconds
     */
    function getVotingPeriod() external view returns (uint256);
}

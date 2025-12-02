// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IGovernance
 * @notice Interface for Governance contract functions called by IDO
 */
interface IGovernance {
    /**
     * @notice Deposit USDC funds to treasury (called by IDO on launch)
     * @param amount Amount of USDC to deposit
     */
    function depositFunds(uint256 amount) external;

    /**
     * @notice Lock LP tokens permanently (called by IDO on launch)
     * @param lpToken Address of the LP token
     * @param amount Amount of LP tokens to lock
     */
    function lockLP(address lpToken, uint256 amount) external;
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IIDO
 * @notice Interface for IDO contract methods called by Governance
 */
interface IIDO {
    /**
     * @notice Update hourly rental rate
     * @param newRate New rental price (USDC per hour, 6 decimals)
     */
    function updateHourlyRate(uint256 newRate) external;

    /**
     * @notice Get dataset token address
     * @return Dataset token address
     */
    function tokenAddress() external view returns (address);

    /**
     * @notice Get project owner address
     * @return Project owner address
     */
    function projectAddress() external view returns (address);
}

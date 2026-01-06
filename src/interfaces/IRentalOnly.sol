// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IRentalOnly
 * @notice Interface for RentalOnly contract - simple data rental without IDO
 */
interface IRentalOnly {
    // ========== View Functions ==========

    /// @notice Check if user has active access
    /// @param user Address to check
    /// @return True if user has valid access
    function hasAccess(address user) external view returns (bool);

    /// @notice Get user's access expiration timestamp
    /// @param user Address to check
    /// @return Unix timestamp when access expires (0 if never purchased)
    function accessExpiresAt(address user) external view returns (uint256);

    /// @notice Get metadata URI (IPFS CID)
    /// @return Current metadata URI
    function metadataURI() external view returns (string memory);

    /// @notice Check if contract is active
    /// @return True if contract is active
    function isActive() external view returns (bool);

    /// @notice Get rental price per hour
    /// @return Price in USDC (6 decimals)
    function hourlyRate() external view returns (uint256);

    /// @notice Get contract owner
    /// @return Owner address
    function owner() external view returns (address);

    /// @notice Get total rental collected
    /// @return Total USDC collected (including protocol fee)
    function totalRentalCollected() external view returns (uint256);

    /// @notice Get pending withdrawal amount
    /// @return USDC available for owner to withdraw
    function pendingWithdrawal() external view returns (uint256);

    /// @notice Get metadata history length
    /// @return Number of metadata versions
    function getMetadataHistoryLength() external view returns (uint256);

    // ========== Events ==========

    event AccessPurchased(
        address indexed user,
        uint256 hoursCount,
        uint256 cost,
        uint256 expiresAt
    );

    event HourlyRateUpdated(uint256 oldRate, uint256 newRate);

    event MetadataUpdated(string newURI, uint256 version);

    event Withdrawn(address indexed owner, uint256 amount);

    event Deactivated();
}

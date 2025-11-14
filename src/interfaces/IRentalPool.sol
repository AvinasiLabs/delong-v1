// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IRentalPool
 * @notice Interface for RentalPool contract
 * @dev Called by DatasetToken during token transfers to settle dividends
 */
interface IRentalPool {
    /**
     * @notice Hook called before token balance changes
     * @dev Settles pending dividends based on old balance
     * @param user Address whose balance is changing
     * @param oldBalance User's balance before the change
     */
    function beforeBalanceChange(address user, uint256 oldBalance) external;

    /**
     * @notice Hook called after token balance changes
     * @dev Updates debt baseline based on new balance
     * @param user Address whose balance changed
     * @param newBalance User's balance after the change
     */
    function afterBalanceChange(address user, uint256 newBalance) external;
}

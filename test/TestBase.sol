// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/mocks/MockUSDC.sol";
import "../src/DatasetToken.sol";
import "../src/DatasetManager.sol";
import "../src/RentalPool.sol";
import "../src/RentalManager.sol";
import "../src/IDO.sol";
import "../src/DAOTreasury.sol";
import "../src/DAOGovernance.sol";
import "../src/Factory.sol";

/**
 * @title DeLongTestBase
 * @notice Base contract for all tests with common setup and utilities
 */
abstract contract DeLongTestBase is Test {
    // ========== Test Accounts ==========

    address public owner;
    address public protocolTreasury;
    address public projectAddress;
    address public user1;
    address public user2;
    address public user3;
    address public backend;

    // ========== Core Contracts ==========

    MockUSDC public usdc;
    DatasetToken public datasetToken;
    DatasetManager public datasetManager;
    RentalPool public rentalPool;
    RentalManager public rentalManager;
    IDO public ido;
    DAOTreasury public daoTreasury;
    DAOGovernance public daoGovernance;
    Factory public factory;

    // ========== Constants ==========

    uint256 constant USDC_DECIMALS = 6;
    uint256 constant TOKEN_DECIMALS = 18;
    uint256 constant INITIAL_USDC_BALANCE = 1_000_000 * 10 ** USDC_DECIMALS; // 1M USDC per user

    // ========== Setup ==========

    function setUp() public virtual {
        // Create test accounts
        owner = address(this);
        protocolTreasury = makeAddr("protocolTreasury");
        projectAddress = makeAddr("projectAddress");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        user3 = makeAddr("user3");
        backend = makeAddr("backend");

        // Label accounts for better trace output
        vm.label(owner, "Owner");
        vm.label(protocolTreasury, "ProtocolTreasury");
        vm.label(projectAddress, "ProjectAddress");
        vm.label(user1, "User1");
        vm.label(user2, "User2");
        vm.label(user3, "User3");
        vm.label(backend, "Backend");

        // Deploy mock USDC
        usdc = new MockUSDC();
        vm.label(address(usdc), "USDC");

        // Fund test accounts with USDC
        usdc.mint(user1, INITIAL_USDC_BALANCE);
        usdc.mint(user2, INITIAL_USDC_BALANCE);
        usdc.mint(user3, INITIAL_USDC_BALANCE);
    }

    // ========== Helper Functions ==========

    /**
     * @notice Approves USDC spending for a user
     */
    function approveUSDC(
        address user,
        address spender,
        uint256 amount
    ) internal {
        vm.prank(user);
        usdc.approve(spender, amount);
    }

    /**
     * @notice Gets USDC balance with proper decimals
     */
    function getUSDCBalance(address account) internal view returns (uint256) {
        return usdc.balanceOf(account);
    }

    /**
     * @notice Formats USDC amount for display
     */
    function formatUSDC(uint256 amount) internal pure returns (uint256) {
        return amount / 10 ** USDC_DECIMALS;
    }

    /**
     * @notice Formats token amount for display
     */
    function formatToken(uint256 amount) internal pure returns (uint256) {
        return amount / 10 ** TOKEN_DECIMALS;
    }

    /**
     * @notice Advances time by specified seconds
     */
    function advanceTime(uint256 seconds_) internal {
        vm.warp(block.timestamp + seconds_);
    }

    /**
     * @notice Advances blocks by specified number
     */
    function advanceBlocks(uint256 blocks_) internal {
        vm.roll(block.number + blocks_);
    }
}

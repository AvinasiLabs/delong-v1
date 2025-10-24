// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title MockUSDC
 * @notice Mock USDC token for testing purposes
 * @dev This contract is only for testnet use. In production, use real USDC.
 *      Allows anyone to mint tokens for easy testing.
 */
contract MockUSDC is ERC20 {
    /**
     * @notice Initializes the MockUSDC token with name and symbol
     * @dev Sets up the token with USDC branding for testing
     */
    constructor() ERC20("Mock USDC", "USDC") {}

    /**
     * @notice USDC uses 6 decimals (matching mainnet USDC)
     * @dev Overrides the default 18 decimals to match real USDC
     * @return uint8 Number of decimals (6)
     */
    function decimals() public pure override returns (uint8) {
        return 6;
    }

    /**
     * @notice Mints tokens to a specified address
     * @dev Anyone can call this function for testing purposes
     * @param to Address to receive the minted tokens
     * @param amount Amount of tokens to mint (in 6 decimal format)
     */
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /**
     * @notice Faucet function that gives caller 10,000 USDC
     * @dev Convenience function for quick testing without specifying amount
     */
    function faucet() external {
        _mint(msg.sender, 10_000 * 1e6);
    }
}

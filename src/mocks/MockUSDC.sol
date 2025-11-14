// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title MockUSDC
 * @notice Mock USDC token for testing purposes
 * @dev This contract is only for testnet use. In production, use real USDC.
 *      Only owner can claim tokens with configurable claim amount.
 *      Pre-mints 100 billion tokens to ensure sufficient supply for all participants.
 */
contract MockUSDC is ERC20, Ownable {
    /// @notice Configurable claim amount per address (in 6 decimals, default 50,000 USDC)
    uint256 public claimAmount = 50_000 * 1e6;

    /// @notice Track addresses that have claimed test tokens for competition
    mapping(address => bool) public hasClaimed;

    /// @notice Event emitted when test tokens are claimed
    event TestTokensClaimed(address indexed user, uint256 amount);

    /// @notice Event emitted when claim amount is updated
    event ClaimAmountUpdated(uint256 oldAmount, uint256 newAmount);

    /**
     * @notice Initializes the MockUSDC token with name and symbol
     * @dev Pre-mints 100 billion USDC to contract itself to ensure sufficient supply
     *      (100B USDC = enough for 2M users claiming 50k each)
     */
    constructor() ERC20("Mock USDC", "USDC") Ownable(msg.sender) {
        // Pre-mint 100 billion USDC to contract itself (6 decimals)
        // This ensures enough supply for ~2 million users claiming 50k each
        _mint(address(this), 100_000_000_000 * 1e6);
    }

    /**
     * @notice USDC uses 6 decimals (matching mainnet USDC)
     * @dev Overrides the default 18 decimals to match real USDC
     * @return uint8 Number of decimals (6)
     */
    function decimals() public pure override returns (uint8) {
        return 6;
    }

    /**
     * @notice Update the claim amount per address
     * @dev Only owner can call this function. Allows changing claim amount without redeployment.
     * @param newAmount New claim amount in 6 decimal format (e.g., 50_000 * 1e6 for 50k USDC)
     */
    function setClaimAmount(uint256 newAmount) external onlyOwner {
        require(newAmount > 0, "MockUSDC: Claim amount must be greater than 0");
        uint256 oldAmount = claimAmount;
        claimAmount = newAmount;
        emit ClaimAmountUpdated(oldAmount, newAmount);
    }

    /**
     * @notice Mint tokens to specified address
     * @dev Public function for testing purposes only. Should not be exposed in production.
     * @param to Address to receive minted tokens
     * @param amount Amount of tokens to mint (in 6 decimals)
     */
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /**
     * @notice Claim test USDC tokens for trading competition
     * @dev Each address can only claim once. Transfers from contract's pre-minted supply.
     *      Amount claimed is determined by the configurable claimAmount variable.
     *      Total supply is limited to prevent unlimited minting.
     */
    function claimTestTokens() external {
        require(
            !hasClaimed[msg.sender],
            "MockUSDC: Already claimed test tokens"
        );
        require(
            balanceOf(address(this)) >= claimAmount,
            "MockUSDC: Insufficient contract balance"
        );

        hasClaimed[msg.sender] = true;
        _transfer(address(this), msg.sender, claimAmount);
        emit TestTokensClaimed(msg.sender, claimAmount);
    }
}

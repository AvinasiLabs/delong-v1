// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./interfaces/IRentalPool.sol";

/**
 * @title DatasetToken
 * @notice ERC-20 token for dataset with freezing, voting, and dividend integration
 * @dev Implements:
 *      - Freezing mechanism during IDO period
 *      - Automatic dividend settlement on transfers via _update hook
 *      - Voting power checkpoints (ERC20Votes) for governance
 *      - Links to RentalPool for dividend distribution
 */
contract DatasetToken is ERC20, ERC20Votes, Ownable {
    // ========== Initialization Guard ==========

    /// @notice Prevents reinitialization
    bool private _initialized;

    // ========== Token Metadata (for proxy pattern) ==========

    string private _tokenName;
    string private _tokenSymbol;

    // ========== Associated Contracts ==========

    /// @notice Address of the RentalPool contract for dividend distribution
    address public rentalPool;

    /// @notice Address of the IDO contract that can freeze/unfreeze tokens
    address public idoContract;

    /// @notice Address of the DAO Governance contract that can burn tokens (for delisting)
    address public governanceContract;

    // ========== Freezing Mechanism ==========

    /// @notice Whether tokens are currently frozen (only transfers from/to exempt addresses allowed)
    bool public isFrozen;

    /// @notice Mapping of addresses exempt from freezing restrictions
    mapping(address => bool) public frozenExempt;

    // ========== Events ==========

    /**
     * @notice Emitted when tokens are unfrozen
     * @param timestamp Time when tokens were unfrozen
     */
    event Unfrozen(uint256 timestamp);

    /**
     * @notice Emitted when RentalPool address is set
     * @param rentalPool Address of the RentalPool contract
     */
    event RentalPoolSet(address indexed rentalPool);

    // ========== Errors ==========

    error TokenFrozen();
    error OnlyIDOContract();
    error AlreadyUnfrozen();
    error AlreadySet();
    error ZeroAddress();
    error AlreadyInitialized();
    error Unauthorized();

    // ========== Constructor (for implementation contract) ==========

    /**
     * @notice Constructor sets dummy values for implementation contract
     * @dev The implementation contract is never used directly, only cloned
     */
    constructor()
        ERC20("DatasetToken Implementation", "DT-IMPL")
        EIP712("DatasetToken", "1")
        Ownable(msg.sender)
    {
        // Note: EIP712 domain is set at deployment and shared across all clones
        // This is acceptable as voting is done via Governance contract, not signatures
    }

    // ========== Initializer (called after cloning) ==========

    /**
     * @notice Initializes the cloned dataset token
     * @param name_ Token name (e.g., "DeLong Dataset AI Training")
     * @param symbol_ Token symbol (e.g., "DLAI")
     * @param initialOwner_ Initial owner address (usually Factory)
     * @param idoContract_ IDO contract address
     * @param initialSupply_ Initial token supply (minted to this contract, then transferred to IDO)
     */
    function initialize(
        string memory name_,
        string memory symbol_,
        address initialOwner_,
        address idoContract_,
        uint256 initialSupply_
    ) external {
        if (_initialized) revert AlreadyInitialized();
        _initialized = true;

        // Set token metadata
        _tokenName = name_;
        _tokenSymbol = symbol_;

        // Transfer ownership
        _transferOwnership(initialOwner_);

        // Mark initial owner (usually Factory) as exempt from freezing
        frozenExempt[initialOwner_] = true;

        // Set IDO contract
        if (idoContract_ == address(0)) revert ZeroAddress();
        idoContract = idoContract_;
        frozenExempt[idoContract_] = true;

        // Mint initial supply directly to IDO contract
        if (initialSupply_ > 0) {
            _mint(idoContract_, initialSupply_);
        }

        // Start in frozen state
        isFrozen = true;
    }

    // ========== Overrides for proxy pattern ==========

    /**
     * @notice Returns the name of the token
     * @dev Overrides ERC20.name() to return custom name set in initialize()
     */
    function name() public view override returns (string memory) {
        return bytes(_tokenName).length > 0 ? _tokenName : super.name();
    }

    /**
     * @notice Returns the symbol of the token
     * @dev Overrides ERC20.symbol() to return custom symbol set in initialize()
     */
    function symbol() public view override returns (string memory) {
        return bytes(_tokenSymbol).length > 0 ? _tokenSymbol : super.symbol();
    }

    // ========== External Functions ==========

    /**
     * @notice Sets the IDO contract address (can only be set once)
     * @dev Called by owner (Factory) after deployment to link IDO contract
     * @param idoContract_ Address of the IDO contract
     */
    function setIDOContract(address idoContract_) external onlyOwner {
        if (idoContract != address(0)) revert AlreadySet();
        if (idoContract_ == address(0)) revert ZeroAddress();

        idoContract = idoContract_;
        frozenExempt[idoContract_] = true;
    }

    /**
     * @notice Unfreezes tokens, allowing free transfers
     * @dev Can only be called once by IDO contract when IDO launches
     *      This operation is irreversible
     */
    function unfreeze() external {
        if (msg.sender != idoContract) revert OnlyIDOContract();
        if (!isFrozen) revert AlreadyUnfrozen();

        isFrozen = false;
        emit Unfrozen(block.timestamp);
    }

    /**
     * @notice Sets the RentalPool address (can only be set once)
     * @dev Called after deployment to link dividend distribution system
     * @param rentalPool_ Address of the RentalPool contract
     */
    function setRentalPool(address rentalPool_) external onlyOwner {
        if (rentalPool != address(0)) revert AlreadySet();
        if (rentalPool_ == address(0)) revert ZeroAddress();

        rentalPool = rentalPool_;
        emit RentalPoolSet(rentalPool_);
    }

    /**
     * @notice Adds an address to the frozen-exempt list
     * @dev Useful for adding Uniswap pool or other contracts that need to operate during freeze
     * @param account Address to mark as exempt
     */
    function addFrozenExempt(address account) external onlyOwner {
        frozenExempt[account] = true;
    }

    /**
     * @notice Removes an address from the frozen-exempt list
     * @param account Address to remove from exempt list
     */
    function removeFrozenExempt(address account) external onlyOwner {
        frozenExempt[account] = false;
    }

    /**
     * @notice Sets the Governance contract address (can only be set once)
     * @dev Called after deployment to enable delisting functionality
     * @param governanceContract_ Address of the DAO Governance contract
     */
    function setGovernanceContract(
        address governanceContract_
    ) external onlyOwner {
        if (governanceContract != address(0)) revert AlreadySet();
        if (governanceContract_ == address(0)) revert ZeroAddress();

        governanceContract = governanceContract_;
    }

    /**
     * @notice Burns tokens from a specified address
     * @dev Only callable by Governance contract during delisting or refund claims
     * @param from Address to burn tokens from
     * @param amount Amount of tokens to burn
     */
    function burn(address from, uint256 amount) external {
        if (msg.sender != governanceContract) revert Unauthorized();
        _burn(from, amount);
    }

    // ========== Internal Functions ==========

    /**
     * @notice Hook that is called before any token transfer
     * @dev Implements:
     *      1. Freezing check: reverts if token is frozen and neither party is exempt
     *      2. Dividend settlement: calls RentalPool before/after balance changes
     *      This ensures fair dividend distribution during transfers
     * @param from Address sending tokens (address(0) for minting)
     * @param to Address receiving tokens (address(0) for burning)
     * @param amount Amount of tokens being transferred
     */
    function _update(
        address from,
        address to,
        uint256 amount
    ) internal override(ERC20, ERC20Votes) {
        // Check freezing status
        if (isFrozen) {
            // Allow transfers if from/to is exempt or if minting (from == address(0))
            if (
                !frozenExempt[from] && !frozenExempt[to] && from != address(0)
            ) {
                revert TokenFrozen();
            }
        }

        // If RentalPool is set, settle dividends before balance changes
        if (rentalPool != address(0)) {
            // Settle sender's dividends based on old balance
            if (from != address(0) && from != to) {
                IRentalPool(rentalPool).beforeBalanceChange(
                    from,
                    balanceOf(from)
                );
            }

            // Settle receiver's dividends based on old balance
            if (to != address(0) && to != from) {
                IRentalPool(rentalPool).beforeBalanceChange(to, balanceOf(to));
            }
        }

        // Execute the actual balance change
        // ERC20Votes._update internally calls ERC20._update and updates voting checkpoints
        ERC20Votes._update(from, to, amount);

        // If RentalPool is set, update debt baseline after balance changes
        if (rentalPool != address(0)) {
            // Update sender's debt baseline based on new balance
            if (from != address(0) && from != to) {
                IRentalPool(rentalPool).afterBalanceChange(
                    from,
                    balanceOf(from)
                );
            }

            // Update receiver's debt baseline based on new balance
            if (to != address(0) && to != from) {
                IRentalPool(rentalPool).afterBalanceChange(to, balanceOf(to));
            }
        }
    }
}

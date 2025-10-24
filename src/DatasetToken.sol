// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title IRentalPool
 * @notice Interface for RentalPool contract
 */
interface IRentalPool {
    function beforeBalanceChange(address user, uint256 oldBalance) external;

    function afterBalanceChange(address user, uint256 newBalance) external;
}

/**
 * @title DatasetToken
 * @notice ERC-20 token for dataset with freezing and dividend integration
 * @dev Implements:
 *      - Freezing mechanism during IDO period
 *      - Automatic dividend settlement on transfers via _update hook
 *      - Links to DatasetManager for business logic
 *      - Links to RentalPool for dividend distribution
 */
contract DatasetToken is ERC20, Ownable {
    // ========== Associated Contracts ==========

    /// @notice Address of the RentalPool contract for dividend distribution
    address public rentalPool;

    /// @notice Address of the DatasetManager contract for business logic
    address public datasetManager;

    /// @notice Address of the IDO contract that can freeze/unfreeze tokens
    address public dleContract;

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

    /**
     * @notice Emitted when DatasetManager address is set
     * @param datasetManager Address of the DatasetManager contract
     */
    event DatasetManagerSet(address indexed datasetManager);

    // ========== Errors ==========

    error TokenFrozen();
    error OnlyIDOContract();
    error AlreadyUnfrozen();
    error AlreadySet();
    error ZeroAddress();

    // ========== Constructor ==========

    /**
     * @notice Initializes the dataset token
     * @param name_ Token name (e.g., "DeLong Dataset AI Training")
     * @param symbol_ Token symbol (e.g., "DLAI")
     * @param initialOwner_ Initial owner address (usually IDO contract)
     * @param dleContract_ IDO contract address (can be zero, set later via setDLEContract)
     * @param initialSupply_ Initial token supply (usually minted to IDO contract)
     */
    constructor(
        string memory name_,
        string memory symbol_,
        address initialOwner_,
        address dleContract_,
        uint256 initialSupply_
    ) ERC20(name_, symbol_) Ownable(initialOwner_) {
        // Mark initial owner (usually Factory) as exempt from freezing
        frozenExempt[initialOwner_] = true;

        // Allow zero address, can be set later via setDLEContract
        if (dleContract_ != address(0)) {
            dleContract = dleContract_;
            // Mark IDO contract as exempt from freezing
            frozenExempt[dleContract_] = true;

            // Mint initial supply to IDO contract
            if (initialSupply_ > 0) {
                _mint(dleContract_, initialSupply_);
            }
        } else {
            // If IDO not set yet, mint to owner (usually Factory)
            if (initialSupply_ > 0) {
                _mint(initialOwner_, initialSupply_);
            }
        }

        isFrozen = true; // Start in frozen state
    }

    // ========== External Functions ==========

    /**
     * @notice Sets the IDO contract address (can only be set once)
     * @dev Called by owner (Factory) after deployment to link IDO contract
     * @param dleContract_ Address of the IDO contract
     */
    function setDLEContract(address dleContract_) external onlyOwner {
        if (dleContract != address(0)) revert AlreadySet();
        if (dleContract_ == address(0)) revert ZeroAddress();

        dleContract = dleContract_;
        frozenExempt[dleContract_] = true;
    }

    /**
     * @notice Unfreezes tokens, allowing free transfers
     * @dev Can only be called once by IDO contract when IDO launches
     *      This operation is irreversible
     */
    function unfreeze() external {
        if (msg.sender != dleContract) revert OnlyIDOContract();
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
     * @notice Sets the DatasetManager address (can only be set once)
     * @dev Called after deployment to link business logic
     * @param datasetManager_ Address of the DatasetManager contract
     */
    function setDatasetManager(address datasetManager_) external onlyOwner {
        if (datasetManager != address(0)) revert AlreadySet();
        if (datasetManager_ == address(0)) revert ZeroAddress();

        datasetManager = datasetManager_;
        emit DatasetManagerSet(datasetManager_);
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
    ) internal override {
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
        super._update(from, to, amount);

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

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

/**
 * @title RentalOnly
 * @notice Simple data rental contract without IDO - allows direct data access sales
 * @dev Uses EIP-1167 minimal proxy pattern for deployment via Factory
 *
 * Key features:
 * - Owner receives 95% of rental fees, 5% goes to protocol
 * - No token, no investors, no governance
 * - Owner can withdraw accumulated earnings anytime
 * - Can be deactivated to stop accepting new purchases
 */
contract RentalOnly is Initializable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ========== Constants ==========

    uint256 public constant PROTOCOL_FEE_RATE = 500; // 5%
    uint256 public constant FEE_DENOMINATOR = 10000;

    // ========== State Variables ==========

    address public owner;
    address public usdcToken;
    address public feeTo;

    string public metadataURI;
    uint256 public hourlyRate;
    bool public isActive;

    mapping(address => uint256) public accessExpiresAt;
    uint256 public totalRentalCollected;
    uint256 public pendingWithdrawal;

    // ========== Metadata History ==========

    struct MetadataVersion {
        string metadataURI;
        uint256 timestamp;
    }
    MetadataVersion[] public metadataHistory;

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

    // ========== Errors ==========

    error NotOwner();
    error ContractDeactivated();
    error AlreadyDeactivated();
    error HoursMustBePositive();
    error NothingToWithdraw();

    // ========== Modifiers ==========

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    // ========== Initialization ==========

    /**
     * @notice Initialize the RentalOnly contract
     * @param owner_ Project owner address
     * @param usdcToken_ USDC token address
     * @param feeTo_ Protocol fee recipient
     * @param metadataURI_ IPFS CID for dataset metadata
     * @param hourlyRate_ Rental price per hour in USDC (6 decimals)
     */
    function initialize(
        address owner_,
        address usdcToken_,
        address feeTo_,
        string memory metadataURI_,
        uint256 hourlyRate_
    ) external initializer {
        owner = owner_;
        usdcToken = usdcToken_;
        feeTo = feeTo_;
        metadataURI = metadataURI_;
        hourlyRate = hourlyRate_;
        isActive = true;
        metadataHistory.push(MetadataVersion(metadataURI_, block.timestamp));
    }

    // ========== Core Functions ==========

    /**
     * @notice Purchase access to the dataset
     * @param hoursCount Number of hours to purchase
     * @dev Extends existing access if not expired, starts from now if expired
     */
    function purchaseAccess(uint256 hoursCount) external nonReentrant {
        if (!isActive) revert ContractDeactivated();
        if (hoursCount == 0) revert HoursMustBePositive();

        uint256 cost = hourlyRate * hoursCount;
        IERC20(usdcToken).safeTransferFrom(msg.sender, address(this), cost);

        // Calculate protocol fee (5%)
        uint256 protocolFee = (cost * PROTOCOL_FEE_RATE) / FEE_DENOMINATOR;
        uint256 ownerShare = cost - protocolFee;

        // Transfer protocol fee
        IERC20(usdcToken).safeTransfer(feeTo, protocolFee);

        // Accumulate owner's share
        pendingWithdrawal += ownerShare;
        totalRentalCollected += cost;

        // Update access expiration
        uint256 currentExpiry = accessExpiresAt[msg.sender];
        uint256 newExpiry = (currentExpiry > block.timestamp)
            ? currentExpiry + hoursCount * 1 hours
            : block.timestamp + hoursCount * 1 hours;
        accessExpiresAt[msg.sender] = newExpiry;

        emit AccessPurchased(msg.sender, hoursCount, cost, newExpiry);
    }

    /**
     * @notice Withdraw accumulated earnings
     * @dev Can be called even after deactivation
     */
    function withdraw() external onlyOwner nonReentrant {
        uint256 amount = pendingWithdrawal;
        if (amount == 0) revert NothingToWithdraw();

        pendingWithdrawal = 0;
        IERC20(usdcToken).safeTransfer(owner, amount);

        emit Withdrawn(owner, amount);
    }

    // ========== Admin Functions ==========

    /**
     * @notice Update the hourly rental rate
     * @param newRate New price per hour in USDC (6 decimals)
     */
    function updateHourlyRate(uint256 newRate) external onlyOwner {
        if (!isActive) revert ContractDeactivated();

        uint256 oldRate = hourlyRate;
        hourlyRate = newRate;

        emit HourlyRateUpdated(oldRate, newRate);
    }

    /**
     * @notice Update dataset metadata URI
     * @param newURI New IPFS CID
     * @dev Old URIs are preserved in metadataHistory
     */
    function updateMetadata(string calldata newURI) external onlyOwner {
        if (!isActive) revert ContractDeactivated();

        metadataURI = newURI;
        metadataHistory.push(MetadataVersion(newURI, block.timestamp));

        emit MetadataUpdated(newURI, metadataHistory.length);
    }

    /**
     * @notice Deactivate the contract to stop accepting new purchases
     * @dev Existing access remains valid until expiration
     *      Owner can still withdraw pending earnings
     */
    function deactivate() external onlyOwner {
        if (!isActive) revert AlreadyDeactivated();

        isActive = false;

        emit Deactivated();
    }

    // ========== View Functions ==========

    /**
     * @notice Check if user has active access
     * @param user Address to check
     * @return True if user's access has not expired
     */
    function hasAccess(address user) external view returns (bool) {
        return accessExpiresAt[user] > block.timestamp;
    }

    /**
     * @notice Get number of metadata versions
     * @return Length of metadataHistory array
     */
    function getMetadataHistoryLength() external view returns (uint256) {
        return metadataHistory.length;
    }
}

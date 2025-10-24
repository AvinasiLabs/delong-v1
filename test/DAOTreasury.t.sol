// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./TestBase.sol";

contract DAOTreasuryTest is DeLongTestBase {
    address public daoGovernanceAddr;
    address public idoContractAddr;

    function setUp() public override {
        super.setUp();

        daoTreasury = new DAOTreasury(address(usdc), owner);

        daoGovernanceAddr = makeAddr("daoGovernance");
        idoContractAddr = makeAddr("idoContract");

        daoTreasury.setDAOGovernance(daoGovernanceAddr);
        daoTreasury.setIDOContract(idoContractAddr);

        // Fund IDO contract with USDC
        usdc.mint(idoContractAddr, 1_000_000 * 10 ** 6);

        vm.label(address(daoTreasury), "DAOTreasury");
    }

    function test_InitialState() public view {
        assertEq(
            address(daoTreasury.usdc()),
            address(usdc),
            "USDC should match"
        );
        assertEq(
            daoTreasury.daoGovernance(),
            daoGovernanceAddr,
            "DAO Governance should match"
        );
        assertEq(
            daoTreasury.idoContract(),
            idoContractAddr,
            "IDO contract should match"
        );
        assertEq(
            daoTreasury.proposalCount(),
            0,
            "Initial proposal count should be 0"
        );
    }

    function test_DepositFunds() public {
        address datasetTokenAddr = makeAddr("datasetToken");
        uint256 depositAmount = 100_000 * 10 ** 6; // 100k USDC

        vm.prank(idoContractAddr);
        usdc.approve(address(daoTreasury), depositAmount);

        vm.prank(idoContractAddr);
        daoTreasury.depositFunds(
            datasetTokenAddr,
            projectAddress,
            depositAmount
        );

        assertEq(
            daoTreasury.availableBalance(datasetTokenAddr),
            depositAmount,
            "Available balance should match deposit"
        );
        assertEq(
            daoTreasury.totalDeposited(datasetTokenAddr),
            depositAmount,
            "Total deposited should match deposit"
        );
        assertEq(
            daoTreasury.projectAddresses(datasetTokenAddr),
            projectAddress,
            "Project address should be stored"
        );
    }

    function test_RevertDepositFunds_Unauthorized() public {
        address datasetTokenAddr = makeAddr("datasetToken");

        vm.prank(user1);
        vm.expectRevert(DAOTreasury.Unauthorized.selector);
        daoTreasury.depositFunds(
            datasetTokenAddr,
            projectAddress,
            1000 * 10 ** 6
        );
    }

    function test_SubmitProposal() public {
        // Deposit funds first
        address datasetTokenAddr = makeAddr("datasetToken");
        uint256 depositAmount = 100_000 * 10 ** 6;

        vm.prank(idoContractAddr);
        usdc.approve(address(daoTreasury), depositAmount);
        vm.prank(idoContractAddr);
        daoTreasury.depositFunds(
            datasetTokenAddr,
            projectAddress,
            depositAmount
        );

        // Submit proposal
        uint256 withdrawAmount = 10_000 * 10 ** 6;
        string memory purpose = "Development costs";

        vm.prank(projectAddress);
        uint256 proposalId = daoTreasury.submitProposal(
            datasetTokenAddr,
            withdrawAmount,
            purpose
        );

        assertEq(proposalId, 0, "First proposal ID should be 0");

        // Check proposal details
        (
            uint256 id,
            address proposalProject,
            address datasetToken,
            uint256 amount,
            string memory proposalPurpose,
            uint256 submittedAt,
            DAOTreasury.ProposalStatus status,
            ,

        ) = daoTreasury.proposals(proposalId);

        assertEq(id, proposalId, "Proposal ID should match");
        assertEq(
            proposalProject,
            projectAddress,
            "Project address should match"
        );
        assertEq(datasetToken, datasetTokenAddr, "Dataset token should match");
        assertEq(amount, withdrawAmount, "Amount should match");
        assertEq(proposalPurpose, purpose, "Purpose should match");
        assertGt(submittedAt, 0, "Submitted timestamp should be set");
        assertEq(
            uint256(status),
            uint256(DAOTreasury.ProposalStatus.Pending),
            "Status should be Pending"
        );
    }

    function test_RevertSubmitProposal_Unauthorized() public {
        address datasetTokenAddr = makeAddr("datasetToken");

        vm.prank(user1);
        vm.expectRevert(DAOTreasury.Unauthorized.selector);
        daoTreasury.submitProposal(datasetTokenAddr, 1000 * 10 ** 6, "Test");
    }

    function test_ApproveProposal() public {
        // Setup: deposit and submit proposal
        address datasetTokenAddr = makeAddr("datasetToken");
        uint256 depositAmount = 100_000 * 10 ** 6;

        vm.prank(idoContractAddr);
        usdc.approve(address(daoTreasury), depositAmount);
        vm.prank(idoContractAddr);
        daoTreasury.depositFunds(
            datasetTokenAddr,
            projectAddress,
            depositAmount
        );

        vm.prank(projectAddress);
        uint256 proposalId = daoTreasury.submitProposal(
            datasetTokenAddr,
            10_000 * 10 ** 6,
            "Development"
        );

        // Approve proposal
        vm.prank(daoGovernanceAddr);
        daoTreasury.approveProposal(proposalId);

        // Check status
        (, , , , , , DAOTreasury.ProposalStatus status, , ) = daoTreasury
            .proposals(proposalId);
        assertEq(
            uint256(status),
            uint256(DAOTreasury.ProposalStatus.Approved),
            "Status should be Approved"
        );
    }

    function test_RejectProposal() public {
        // Setup
        address datasetTokenAddr = makeAddr("datasetToken");
        uint256 depositAmount = 100_000 * 10 ** 6;

        vm.prank(idoContractAddr);
        usdc.approve(address(daoTreasury), depositAmount);
        vm.prank(idoContractAddr);
        daoTreasury.depositFunds(
            datasetTokenAddr,
            projectAddress,
            depositAmount
        );

        vm.prank(projectAddress);
        uint256 proposalId = daoTreasury.submitProposal(
            datasetTokenAddr,
            10_000 * 10 ** 6,
            "Development"
        );

        // Reject proposal
        vm.prank(daoGovernanceAddr);
        daoTreasury.rejectProposal(proposalId);

        // Check status
        (, , , , , , DAOTreasury.ProposalStatus status, , ) = daoTreasury
            .proposals(proposalId);
        assertEq(
            uint256(status),
            uint256(DAOTreasury.ProposalStatus.Rejected),
            "Status should be Rejected"
        );
    }

    function test_ExecuteProposal() public {
        // Setup
        address datasetTokenAddr = makeAddr("datasetToken");
        uint256 depositAmount = 100_000 * 10 ** 6;
        uint256 withdrawAmount = 10_000 * 10 ** 6;

        vm.prank(idoContractAddr);
        usdc.approve(address(daoTreasury), depositAmount);
        vm.prank(idoContractAddr);
        daoTreasury.depositFunds(
            datasetTokenAddr,
            projectAddress,
            depositAmount
        );

        vm.prank(projectAddress);
        uint256 proposalId = daoTreasury.submitProposal(
            datasetTokenAddr,
            withdrawAmount,
            "Development"
        );

        vm.prank(daoGovernanceAddr);
        daoTreasury.approveProposal(proposalId);

        // Execute proposal
        uint256 projectBalanceBefore = usdc.balanceOf(projectAddress);

        vm.prank(projectAddress);
        daoTreasury.executeProposal(proposalId);

        uint256 projectBalanceAfter = usdc.balanceOf(projectAddress);

        // Verify transfer
        assertEq(
            projectBalanceAfter - projectBalanceBefore,
            withdrawAmount,
            "Project should receive USDC"
        );

        // Check balances updated
        assertEq(
            daoTreasury.availableBalance(datasetTokenAddr),
            depositAmount - withdrawAmount,
            "Available balance should decrease"
        );
        assertEq(
            daoTreasury.totalWithdrawn(datasetTokenAddr),
            withdrawAmount,
            "Total withdrawn should increase"
        );

        // Check proposal status
        (, , , , , , DAOTreasury.ProposalStatus status, , ) = daoTreasury
            .proposals(proposalId);
        assertEq(
            uint256(status),
            uint256(DAOTreasury.ProposalStatus.Executed),
            "Status should be Executed"
        );
    }

    function test_CancelProposal() public {
        // Setup
        address datasetTokenAddr = makeAddr("datasetToken");
        uint256 depositAmount = 100_000 * 10 ** 6;

        vm.prank(idoContractAddr);
        usdc.approve(address(daoTreasury), depositAmount);
        vm.prank(idoContractAddr);
        daoTreasury.depositFunds(
            datasetTokenAddr,
            projectAddress,
            depositAmount
        );

        vm.prank(projectAddress);
        uint256 proposalId = daoTreasury.submitProposal(
            datasetTokenAddr,
            10_000 * 10 ** 6,
            "Development"
        );

        // Cancel proposal
        vm.prank(projectAddress);
        daoTreasury.cancelProposal(proposalId);

        // Check status
        (, , , , , , DAOTreasury.ProposalStatus status, , ) = daoTreasury
            .proposals(proposalId);
        assertEq(
            uint256(status),
            uint256(DAOTreasury.ProposalStatus.Cancelled),
            "Status should be Cancelled"
        );
    }

    function test_GetTreasuryBalance() public {
        address datasetTokenAddr = makeAddr("datasetToken");
        uint256 depositAmount = 100_000 * 10 ** 6;

        vm.prank(idoContractAddr);
        usdc.approve(address(daoTreasury), depositAmount);
        vm.prank(idoContractAddr);
        daoTreasury.depositFunds(
            datasetTokenAddr,
            projectAddress,
            depositAmount
        );

        (uint256 available, uint256 withdrawn, uint256 deposited) = daoTreasury
            .getTreasuryBalance(datasetTokenAddr);

        assertEq(available, depositAmount, "Available should match deposit");
        assertEq(withdrawn, 0, "Withdrawn should be 0");
        assertEq(deposited, depositAmount, "Deposited should match deposit");
    }

    function test_PauseAndUnpause() public {
        daoTreasury.pause();
        assertTrue(daoTreasury.paused(), "Should be paused");

        daoTreasury.unpause();
        assertFalse(daoTreasury.paused(), "Should be unpaused");
    }

    function test_RevertWhenPaused() public {
        address datasetTokenAddr = makeAddr("datasetToken");

        daoTreasury.pause();

        vm.prank(projectAddress);
        vm.expectRevert(DAOTreasury.ContractPaused.selector);
        daoTreasury.submitProposal(datasetTokenAddr, 1000 * 10 ** 6, "Test");
    }
}

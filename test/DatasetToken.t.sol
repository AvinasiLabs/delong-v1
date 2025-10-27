// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./TestBase.sol";

contract DatasetTokenTest is DeLongTestBase {
    address public idoContract;

    function setUp() public override {
        super.setUp();

        // Deploy DatasetToken with frozen state
        idoContract = makeAddr("idoContract");
        datasetToken = new DatasetToken();
        datasetToken.initialize(
            "Test Dataset Token",
            "TDT",
            owner,
            idoContract,
            1_000_000 * 10 ** 18 // 1M tokens - minted directly to idoContract
        );

        vm.label(address(datasetToken), "DatasetToken");
    }

    function test_InitialState() public view {
        assertEq(
            datasetToken.name(),
            "Test Dataset Token",
            "Token name should match"
        );
        assertEq(datasetToken.symbol(), "TDT", "Token symbol should match");
        assertEq(
            datasetToken.totalSupply(),
            1_000_000 * 10 ** 18,
            "Total supply should match"
        );
        assertTrue(datasetToken.isFrozen(), "Token should be frozen initially");
        assertTrue(
            datasetToken.frozenExempt(idoContract),
            "IDO contract should be exempt"
        );
    }

    function test_Unfreeze() public {
        // Only IDO contract can unfreeze
        vm.prank(idoContract);
        datasetToken.unfreeze();

        assertFalse(datasetToken.isFrozen(), "Token should be unfrozen");
    }

    function test_RevertUnfreeze_Unauthorized() public {
        vm.prank(user1);
        vm.expectRevert(DatasetToken.OnlyIDOContract.selector);
        datasetToken.unfreeze();
    }

    function test_RevertUnfreeze_AlreadyUnfrozen() public {
        vm.prank(idoContract);
        datasetToken.unfreeze();

        vm.prank(idoContract);
        vm.expectRevert(DatasetToken.AlreadyUnfrozen.selector);
        datasetToken.unfreeze();
    }

    function test_TransferWhileFrozen_FromExempt() public {
        // IDO contract can transfer while frozen
        uint256 transferAmount = 1000 * 10 ** 18;

        vm.prank(idoContract);
        datasetToken.transfer(user1, transferAmount);

        assertEq(
            datasetToken.balanceOf(user1),
            transferAmount,
            "User1 should receive tokens"
        );
    }

    function test_RevertTransferWhileFrozen_NotExempt() public {
        // Transfer tokens to user1 first (from exempt address)
        vm.prank(idoContract);
        datasetToken.transfer(user1, 1000 * 10 ** 18);

        // User1 cannot transfer while frozen
        vm.prank(user1);
        vm.expectRevert(DatasetToken.TokenFrozen.selector);
        datasetToken.transfer(user2, 100 * 10 ** 18);
    }

    function test_TransferAfterUnfreeze() public {
        // Transfer to user1
        vm.prank(idoContract);
        datasetToken.transfer(user1, 1000 * 10 ** 18);

        // Unfreeze
        vm.prank(idoContract);
        datasetToken.unfreeze();

        // Now user1 can transfer
        vm.prank(user1);
        datasetToken.transfer(user2, 100 * 10 ** 18);

        assertEq(
            datasetToken.balanceOf(user2),
            100 * 10 ** 18,
            "User2 should receive tokens"
        );
    }

    function test_SetRentalPool() public {
        address rentalPoolAddr = makeAddr("rentalPool");

        datasetToken.setRentalPool(rentalPoolAddr);

        assertEq(
            datasetToken.rentalPool(),
            rentalPoolAddr,
            "RentalPool should be set"
        );
    }

    function test_RevertSetRentalPool_AlreadySet() public {
        address rentalPoolAddr = makeAddr("rentalPool");
        datasetToken.setRentalPool(rentalPoolAddr);

        vm.expectRevert(DatasetToken.AlreadySet.selector);
        datasetToken.setRentalPool(rentalPoolAddr);
    }

    function test_SetDatasetManager() public {
        address managerAddr = makeAddr("datasetManager");

        datasetToken.setDatasetManager(managerAddr);

        assertEq(
            datasetToken.datasetManager(),
            managerAddr,
            "DatasetManager should be set"
        );
    }

    function test_AddFrozenExempt() public {
        address exemptAddr = makeAddr("exemptAddress");

        datasetToken.addFrozenExempt(exemptAddr);

        assertTrue(
            datasetToken.frozenExempt(exemptAddr),
            "Address should be exempt"
        );
    }

    function test_RemoveFrozenExempt() public {
        address exemptAddr = makeAddr("exemptAddress");
        datasetToken.addFrozenExempt(exemptAddr);

        datasetToken.removeFrozenExempt(exemptAddr);

        assertFalse(
            datasetToken.frozenExempt(exemptAddr),
            "Address should not be exempt"
        );
    }
}

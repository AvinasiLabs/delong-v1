// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./TestBase.sol";

contract FactoryTest is DeLongTestBase {
    function setUp() public override {
        super.setUp();

        // Deploy core shared contracts
        rentalManager = new RentalManager(address(usdc), owner);
        daoTreasury = new DAOTreasury(address(usdc), owner);

        // Deploy Factory
        factory = new Factory(address(usdc), owner);

        // Configure Factory
        factory.configure(
            address(rentalManager),
            address(daoTreasury),
            protocolTreasury
        );

        // Configure shared contracts
        rentalManager.setFactory(address(factory)); // Allow Factory to set prices
        rentalManager.setProtocolTreasury(protocolTreasury);
        daoTreasury.setIDOContract(address(factory)); // Factory can act as IDO for testing

        vm.label(address(factory), "Factory");
    }

    function test_InitialState() public view {
        assertEq(address(factory.usdc()), address(usdc), "USDC should match");
        assertEq(
            factory.rentalManager(),
            address(rentalManager),
            "RentalManager should match"
        );
        assertEq(
            factory.daoTreasury(),
            address(daoTreasury),
            "DAOTreasury should match"
        );
        assertEq(
            factory.protocolTreasury(),
            protocolTreasury,
            "ProtocolTreasury should match"
        );
        assertEq(
            factory.datasetCount(),
            0,
            "Initial dataset count should be 0"
        );
    }

    function test_DeployDataset() public {
        // Prepare deployment parameters
        Factory.IDOConfig memory config = Factory.IDOConfig({
            alphaProject: 2000, // 20%
            k: 1000,
            betaLP: 7000, // 70%
            minRaiseRatio: 7500, // 75%
            initialPrice: 1 * 10 ** 6 // 1 USDC
        });

        // Deploy dataset
        vm.prank(user1);
        uint256 datasetId = factory.deployDataset(
            projectAddress,
            "Test Dataset",
            "TDS",
            "ipfs://metadata",
            10 * 10 ** 6, // 10 USDC per hour
            config
        );

        assertEq(datasetId, 0, "First dataset ID should be 0");
        assertEq(factory.datasetCount(), 1, "Dataset count should be 1");
    }

    function test_DeployDatasetCreatesAllContracts() public {
        Factory.IDOConfig memory config = Factory.IDOConfig({
            alphaProject: 2000,
            k: 1000,
            betaLP: 7000,
            minRaiseRatio: 7500,
            initialPrice: 1 * 10 ** 6
        });

        vm.prank(user1);
        vm.recordLogs();
        uint256 datasetId = factory.deployDataset(
            projectAddress,
            "Test Dataset",
            "TDS",
            "ipfs://metadata",
            10 * 10 ** 6,
            config
        );

        // Get deployed addresses from event
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 eventSig = keccak256("DatasetDeployed(uint256,address,address,address,address,address)");

        address ido;
        address datasetToken;
        address datasetManagerAddr;
        address rentalPoolAddr;

        for (uint i = 0; i < entries.length; i++) {
            if (entries[i].topics[0] == eventSig) {
                (ido, datasetToken, datasetManagerAddr, rentalPoolAddr) =
                    abi.decode(entries[i].data, (address, address, address, address));
                break;
            }
        }

        // Verify all contracts created
        assertTrue(ido != address(0), "IDO should be created");
        assertTrue(datasetToken != address(0), "DatasetToken should be created");
        assertTrue(datasetManagerAddr != address(0), "DatasetManager should be created");
        assertTrue(rentalPoolAddr != address(0), "RentalPool should be created");
    }

    function test_GetDatasetById() public {
        Factory.IDOConfig memory config = Factory.IDOConfig({
            alphaProject: 2000,
            k: 1000,
            betaLP: 7000,
            minRaiseRatio: 7500,
            initialPrice: 1 * 10 ** 6
        });

        vm.prank(user1);
        vm.recordLogs();
        uint256 datasetId = factory.deployDataset(
            projectAddress,
            "Test",
            "TST",
            "ipfs://test",
            10 * 10 ** 6,
            config
        );

        // Verify via event
        Vm.Log[] memory entries = vm.getRecordedLogs();
        assertEq(datasetId, 1, "Dataset ID should be 1");
        assertTrue(entries.length > 0, "Should emit event");
    }

    function test_MultipleDatasetDeployment() public {
        Factory.IDOConfig memory config = Factory.IDOConfig({
            alphaProject: 2000,
            k: 1000,
            betaLP: 7000,
            minRaiseRatio: 7500,
            initialPrice: 1 * 10 ** 6
        });

        // Deploy 3 datasets
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(user1);
            uint256 id = factory.deployDataset(
                projectAddress,
                "Test",
                "TST",
                "ipfs://test",
                10 * 10 ** 6,
                config
            );
            assertEq(id, i + 1, "Dataset ID should increment");
        }

        assertEq(factory.datasetCount(), 3, "Should have 3 datasets");
    }

    function test_Configure() public {
        address newManager = makeAddr("newManager");

        factory.configure(newManager, address(0), address(0));

        assertEq(factory.rentalManager(), newManager, "Manager should be updated");
    }

    // Deployment fee feature has been removed
    // Test removed: test_DeploymentFeeCollection

    function test_ConfigureOnlyOwner() public {
        address newManager = makeAddr("newManager");

        vm.prank(user1);
        vm.expectRevert();
        factory.configure(newManager, address(0), address(0));
    }

    function test_DatasetCounter() public {
        assertEq(factory.datasetCount(), 0, "Initial count should be 0");

        // Deploy one dataset
        Factory.IDOConfig memory config = Factory.IDOConfig({
            alphaProject: 2000,
            k: 1000,
            betaLP: 7000,
            minRaiseRatio: 7500,
            initialPrice: 1 * 10 ** 6
        });

        vm.prank(user1);
        factory.deployDataset(
            projectAddress,
            "Test",
            "TST",
            "ipfs://test",
            10 * 10 ** 6,
            config
        );

        assertEq(
            factory.datasetCount(),
            1,
            "Count should be 1 after deployment"
        );
    }
}

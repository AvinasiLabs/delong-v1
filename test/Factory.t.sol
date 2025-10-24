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
        factory.setRentalManager(address(rentalManager));
        factory.setDAOTreasury(address(daoTreasury));
        factory.setProtocolTreasury(protocolTreasury);

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
        assertEq(
            factory.deploymentFee(),
            100 * 10 ** 6,
            "Default deployment fee should be 100 USDC"
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

        // Pay deployment fee
        usdc.mint(user1, 100 * 10 ** 6);
        vm.prank(user1);
        usdc.approve(address(factory), 100 * 10 ** 6);

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

        usdc.mint(user1, 100 * 10 ** 6);
        vm.prank(user1);
        usdc.approve(address(factory), 100 * 10 ** 6);

        vm.prank(user1);
        uint256 datasetId = factory.deployDataset(
            projectAddress,
            "Test Dataset",
            "TDS",
            "ipfs://metadata",
            10 * 10 ** 6,
            config
        );

        // Get dataset suite
        (
            address ido,
            address datasetToken,
            address datasetManagerAddr,
            address rentalPoolAddr,
            address project,
            uint256 createdAt,
            bool exists
        ) = factory.datasets(datasetId);

        // Verify all contracts created
        assertTrue(ido != address(0), "IDO should be created");
        assertTrue(
            datasetToken != address(0),
            "DatasetToken should be created"
        );
        assertTrue(
            datasetManagerAddr != address(0),
            "DatasetManager should be created"
        );
        assertTrue(
            rentalPoolAddr != address(0),
            "RentalPool should be created"
        );
        assertEq(project, projectAddress, "Project address should match");
        assertGt(createdAt, 0, "Created timestamp should be set");
        assertTrue(exists, "Dataset should exist");
    }

    function test_GetDatasetById() public {
        Factory.IDOConfig memory config = Factory.IDOConfig({
            alphaProject: 2000,
            k: 1000,
            betaLP: 7000,
            minRaiseRatio: 7500,
            initialPrice: 1 * 10 ** 6
        });

        usdc.mint(user1, 100 * 10 ** 6);
        vm.prank(user1);
        usdc.approve(address(factory), 100 * 10 ** 6);

        vm.prank(user1);
        uint256 datasetId = factory.deployDataset(
            projectAddress,
            "Test",
            "TST",
            "ipfs://test",
            10 * 10 ** 6,
            config
        );

        Factory.DatasetSuite memory suite = factory.getDataset(datasetId);

        assertTrue(suite.ido != address(0), "IDO should exist");
        assertTrue(suite.datasetToken != address(0), "Token should exist");
        assertTrue(suite.exists, "Suite should exist");
    }

    function test_GetAllDatasetIds() public {
        Factory.IDOConfig memory config = Factory.IDOConfig({
            alphaProject: 2000,
            k: 1000,
            betaLP: 7000,
            minRaiseRatio: 7500,
            initialPrice: 1 * 10 ** 6
        });

        // Deploy 3 datasets
        for (uint256 i = 0; i < 3; i++) {
            usdc.mint(user1, 100 * 10 ** 6);
            vm.prank(user1);
            usdc.approve(address(factory), 100 * 10 ** 6);

            vm.prank(user1);
            factory.deployDataset(
                projectAddress,
                "Test",
                "TST",
                "ipfs://test",
                10 * 10 ** 6,
                config
            );
        }

        uint256[] memory ids = factory.getAllDatasetIds();
        assertEq(ids.length, 3, "Should have 3 dataset IDs");
        assertEq(ids[0], 0, "First ID should be 0");
        assertEq(ids[1], 1, "Second ID should be 1");
        assertEq(ids[2], 2, "Third ID should be 2");
    }

    function test_SetDeploymentFee() public {
        uint256 newFee = 200 * 10 ** 6; // 200 USDC

        factory.setDeploymentFee(newFee);

        assertEq(
            factory.deploymentFee(),
            newFee,
            "Deployment fee should be updated"
        );
    }

    function test_DeploymentFeeCollection() public {
        Factory.IDOConfig memory config = Factory.IDOConfig({
            alphaProject: 2000,
            k: 1000,
            betaLP: 7000,
            minRaiseRatio: 7500,
            initialPrice: 1 * 10 ** 6
        });

        uint256 fee = 100 * 10 ** 6;
        usdc.mint(user1, fee);
        vm.prank(user1);
        usdc.approve(address(factory), fee);

        uint256 treasuryBefore = usdc.balanceOf(protocolTreasury);

        vm.prank(user1);
        factory.deployDataset(
            projectAddress,
            "Test",
            "TST",
            "ipfs://test",
            10 * 10 ** 6,
            config
        );

        uint256 treasuryAfter = usdc.balanceOf(protocolTreasury);

        assertEq(
            treasuryAfter - treasuryBefore,
            fee,
            "Protocol treasury should receive deployment fee"
        );
    }

    function test_RevertSetRentalManager_AlreadySet() public {
        address newManager = makeAddr("newManager");

        vm.expectRevert(Factory.AlreadySet.selector);
        factory.setRentalManager(newManager);
    }

    function test_GetTotalDatasets() public {
        assertEq(factory.getTotalDatasets(), 0, "Initial count should be 0");

        // Deploy one dataset
        Factory.IDOConfig memory config = Factory.IDOConfig({
            alphaProject: 2000,
            k: 1000,
            betaLP: 7000,
            minRaiseRatio: 7500,
            initialPrice: 1 * 10 ** 6
        });

        usdc.mint(user1, 100 * 10 ** 6);
        vm.prank(user1);
        usdc.approve(address(factory), 100 * 10 ** 6);

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
            factory.getTotalDatasets(),
            1,
            "Count should be 1 after deployment"
        );
    }
}

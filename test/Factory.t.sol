// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./TestBase.sol";

contract FactoryTest is DeLongTestBase {
    function setUp() public override {
        super.setUp();

        // Deploy implementation contracts
        DatasetToken tokenImpl = new DatasetToken();
        RentalPool poolImpl = new RentalPool();
        IDO idoImpl = new IDO();
        Governance governanceImpl = new Governance();

        // Deploy Factory (all contracts use clone pattern)
        factory = new Factory(
            address(usdc),
            owner,
            address(tokenImpl),
            address(poolImpl),
            address(idoImpl),
            address(governanceImpl)
        );

        // Configure Factory
        factory.configure(
            feeTo,
            address(0x1111111111111111111111111111111111111111), // Mock Uniswap Router
            address(0x2222222222222222222222222222222222222222)  // Mock Uniswap Factory
        );

        vm.label(address(factory), "Factory");
    }

    function test_InitialState() public view {
        assertEq(address(factory.usdc()), address(usdc), "USDC should match");
        assertEq(
            factory.feeTo(),
            feeTo,
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
            rTarget: 50_000 * 10 ** 6, // 50,000 USDC
            alpha: 2000 // 20%
        });

        // Deploy dataset
        vm.prank(user1);
        uint256 datasetId = factory.deployIDO(
            projectAddress,
            "Test Dataset",
            "TDS",
            createTestMetadataURI(1),
            10 * 10 ** 6, // 10 USDC per hour
            config
        );

        assertEq(datasetId, 1, "First dataset ID should be 1");
        assertEq(factory.datasetCount(), 1, "Dataset count should be 1");
    }

    function test_DeployDatasetCreatesAllContracts() public {
        Factory.IDOConfig memory config = Factory.IDOConfig({
            rTarget: 50_000 * 10 ** 6,
            alpha: 2000
        });

        vm.prank(user1);
        vm.recordLogs();
        uint256 datasetId = factory.deployIDO(
            projectAddress,
            "Test Dataset",
            "TDS",
            createTestMetadataURI(2),
            10 * 10 ** 6,
            config
        );

        // Get deployed addresses from event
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 eventSig = keccak256("IDOCreated(uint256,address,address,address,address,address,uint256,uint256)");

        address ido;
        address datasetToken;
        address rentalPoolAddr;
        address governanceAddr;

        for (uint i = 0; i < entries.length; i++) {
            if (entries[i].topics[0] == eventSig) {
                // IDO address is in topics[3]
                ido = address(uint160(uint256(entries[i].topics[3])));
                // Decode data: token, pool, governance, virtualUsdc, virtualTokens
                (datasetToken, rentalPoolAddr, governanceAddr, , ) =
                    abi.decode(entries[i].data, (address, address, address, uint256, uint256));
                break;
            }
        }

        // Verify all contracts created
        assertTrue(ido != address(0), "IDO should be created");
        assertTrue(datasetToken != address(0), "DatasetToken should be created");
        assertTrue(rentalPoolAddr != address(0), "RentalPool should be created");
        assertTrue(governanceAddr != address(0), "Governance should be created");
    }

    function test_GetDatasetById() public {
        Factory.IDOConfig memory config = Factory.IDOConfig({
            rTarget: 50_000 * 10 ** 6,
            alpha: 2000
        });

        vm.prank(user1);
        vm.recordLogs();
        uint256 datasetId = factory.deployIDO(
            projectAddress,
            "Test",
            "TST",
            createTestMetadataURI(3),
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
            rTarget: 50_000 * 10 ** 6,
            alpha: 2000
        });

        // Deploy 3 datasets
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(user1);
            uint256 id = factory.deployIDO(
                projectAddress,
                "Test",
                "TST",
                createTestMetadataURI(4 + i),
                10 * 10 ** 6,
                config
            );
            assertEq(id, i + 1, "Dataset ID should increment");
        }

        assertEq(factory.datasetCount(), 3, "Should have 3 datasets");
    }

    function test_Configure() public view {
        // Verify configuration was set correctly in setUp
        assertEq(factory.feeTo(), feeTo, "FeeTo should match");
    }

    function test_ConfigureOnlyOnce() public {
        // Deploy a new unconfigured factory
        DatasetToken tokenImpl = new DatasetToken();
        RentalPool poolImpl = new RentalPool();
        IDO idoImpl = new IDO();
        Governance governanceImpl = new Governance();
        Factory newFactory = new Factory(
            address(usdc),
            owner,
            address(tokenImpl),
            address(poolImpl),
            address(idoImpl),
            address(governanceImpl)
        );

        address newFeeTo = makeAddr("newFeeTo");

        // First configure should succeed
        newFactory.configure(
            newFeeTo,
            address(0x1111111111111111111111111111111111111111),
            address(0x2222222222222222222222222222222222222222)
        );

        // Second configure should revert
        vm.expectRevert(Factory.AlreadyConfigured.selector);
        newFactory.configure(
            newFeeTo,
            address(0x1111111111111111111111111111111111111111),
            address(0x2222222222222222222222222222222222222222)
        );
    }

    function test_ConfigureRequiresAllAddresses() public {
        // Deploy a new unconfigured factory
        DatasetToken tokenImpl = new DatasetToken();
        RentalPool poolImpl = new RentalPool();
        IDO idoImpl = new IDO();
        Governance governanceImpl = new Governance();
        Factory newFactory = new Factory(address(usdc), owner, address(tokenImpl), address(poolImpl), address(idoImpl), address(governanceImpl));

        // Should revert if any address is zero
        vm.expectRevert(Factory.ZeroAddress.selector);
        newFactory.configure(
            address(0), // Missing feeTo
            address(0x1111111111111111111111111111111111111111),
            address(0x2222222222222222222222222222222222222222)
        );
    }

    // Deployment fee feature has been removed
    // Test removed: test_DeploymentFeeCollection

    function test_ConfigureOnlyOwner() public {
        // Deploy a new unconfigured factory
        DatasetToken tokenImpl = new DatasetToken();
        RentalPool poolImpl = new RentalPool();
        IDO idoImpl = new IDO();
        Governance governanceImpl = new Governance();
        Factory newFactory = new Factory(address(usdc), owner, address(tokenImpl), address(poolImpl), address(idoImpl), address(governanceImpl));

        vm.prank(user1);
        vm.expectRevert();
        newFactory.configure(
            feeTo,
            address(0x1111111111111111111111111111111111111111),
            address(0x2222222222222222222222222222222222222222)
        );
    }

    function test_DatasetCounter() public {
        assertEq(factory.datasetCount(), 0, "Initial count should be 0");

        // Deploy one dataset
        Factory.IDOConfig memory config = Factory.IDOConfig({
            rTarget: 50_000 * 10 ** 6,
            alpha: 2000
        });

        vm.prank(user1);
        factory.deployIDO(
            projectAddress,
            "Test",
            "TST",
            createTestMetadataURI(7),
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

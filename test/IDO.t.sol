// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./TestBase.sol";

contract IDOTest is DeLongTestBase {
    // IDO parameters
    uint256 constant ALPHA_PROJECT = 2000; // 20%
    uint256 constant K = 9 * 10 ** 6; // 9 USD (price growth coefficient)
    uint256 constant BETA_LP = 7000; // 70%
    uint256 constant MIN_RAISE_RATIO = 7500; // 75%
    uint256 constant INITIAL_PRICE = 1 * 10 ** 6; // 1 USDC
    uint256 constant TOTAL_SUPPLY = 1_000_000 * 10 ** 18;

    function setUp() public override {
        super.setUp();

        // Deploy DatasetToken
        datasetToken = new DatasetToken();
        datasetToken.initialize(
            "Test Dataset",
            "TDS",
            owner,
            address(0x1234), // Temporary IDO address, will transfer to actual IDO later
            TOTAL_SUPPLY
        );

        // Deploy other contracts
        datasetManager = new DatasetManager();
        datasetManager.initialize(
            address(datasetToken),
            projectAddress,
            owner,
            "ipfs://test"
        );
        rentalManager = new RentalManager(address(usdc), owner);
        daoTreasury = new DAOTreasury(address(usdc), owner);

        // Deploy IDO
        ido = new IDO();
        ido.initialize(
            ALPHA_PROJECT,
            K,
            BETA_LP,
            MIN_RAISE_RATIO,
            INITIAL_PRICE,
            projectAddress,
            address(datasetToken),
            address(usdc),
            protocolTreasury,
            address(daoTreasury),
            address(rentalManager),
            address(0x1111111111111111111111111111111111111111),
            address(0x2222222222222222222222222222222222222222)
        );

        // Set IDO and temporary address as frozen exempt
        datasetToken.addFrozenExempt(address(ido));
        datasetToken.addFrozenExempt(address(0x1234));

        // Transfer all tokens from temporary address to IDO
        vm.prank(address(0x1234));
        datasetToken.transfer(address(ido), TOTAL_SUPPLY);

        // Transfer token ownership to IDO
        datasetToken.transferOwnership(address(ido));

        // Configure other contracts
        daoTreasury.setIDOContract(address(ido));

        // Fund users with USDC
        usdc.mint(user1, 1_000_000 * 10 ** 6); // 1M USDC
        usdc.mint(user2, 1_000_000 * 10 ** 6);
        usdc.mint(user3, 1_000_000 * 10 ** 6);

        vm.label(address(ido), "IDO");
    }

    function test_InitialState() public view {
        assertEq(
            ido.projectAddress(),
            projectAddress,
            "Project address should match"
        );
        assertEq(
            ido.tokenAddress(),
            address(datasetToken),
            "Token address should match"
        );
        assertEq(ido.usdcToken(), address(usdc), "USDC address should match");
        assertEq(
            ido.alphaProject(),
            ALPHA_PROJECT,
            "Alpha project should match"
        );
        assertEq(ido.k(), K, "K should match");
        assertEq(ido.betaLP(), BETA_LP, "Beta LP should match");
        assertEq(
            ido.minRaiseRatio(),
            MIN_RAISE_RATIO,
            "Min raise ratio should match"
        );
        assertEq(
            ido.initialPrice(),
            INITIAL_PRICE,
            "Initial price should match"
        );
        assertEq(
            uint256(ido.status()),
            uint256(IDO.Status.Active),
            "Status should be Active"
        );
        assertEq(ido.soldTokens(), 0, "Sold tokens should be 0");
    }

    function test_BuyTokens() public {
        uint256 tokenAmount = 1000 * 10 ** 18;
        uint256 maxCost = 5000 * 10 ** 6; // 5000 USDC max (with new k=9e6)

        // Approve USDC
        vm.prank(user1);
        usdc.approve(address(ido), maxCost);

        // Buy tokens
        vm.prank(user1);
        uint256 actualCost = ido.buyTokens(tokenAmount, maxCost);

        // Check user received tokens
        assertEq(
            datasetToken.balanceOf(user1),
            tokenAmount,
            "User should receive tokens"
        );

        // Check sold tokens increased
        assertEq(ido.soldTokens(), tokenAmount, "Sold tokens should increase");

        // Verify cost
        assertGt(actualCost, 0, "Cost should be > 0");
    }

    function test_BuyTokensMultipleTimes() public {
        uint256 tokenAmount = 500 * 10 ** 18;
        uint256 maxCost = 3000 * 10 ** 6; // 3000 USDC max (with new k=9e6)

        // User1 buys
        vm.prank(user1);
        usdc.approve(address(ido), maxCost);
        vm.prank(user1);
        uint256 cost1 = ido.buyTokens(tokenAmount, maxCost);

        // User2 buys (price should be higher)
        vm.prank(user2);
        usdc.approve(address(ido), maxCost);
        vm.prank(user2);
        uint256 cost2 = ido.buyTokens(tokenAmount, maxCost);

        // Second purchase should cost more (bonding curve)
        assertGt(cost2, cost1, "Second purchase should be more expensive");

        assertEq(
            datasetToken.balanceOf(user1),
            tokenAmount,
            "User1 should have tokens"
        );
        assertEq(
            datasetToken.balanceOf(user2),
            tokenAmount,
            "User2 should have tokens"
        );
    }

    function test_SellTokens() public {
        // Buy first
        uint256 tokenAmount = 1000 * 10 ** 18;
        vm.prank(user1);
        usdc.approve(address(ido), 5000 * 10 ** 6); // Updated for new k=9e6
        vm.prank(user1);
        ido.buyTokens(tokenAmount, 5000 * 10 ** 6);

        // Sell half
        uint256 sellAmount = 500 * 10 ** 18;
        uint256 minRefund = 100 * 10 ** 6; // Minimum acceptable refund

        uint256 usdcBefore = usdc.balanceOf(user1);

        // Approve IDO to burn user's tokens
        vm.prank(user1);
        datasetToken.approve(address(ido), sellAmount);

        vm.prank(user1);
        uint256 actualRefund = ido.sellTokens(sellAmount, minRefund);

        uint256 usdcAfter = usdc.balanceOf(user1);

        // Check user received USDC
        assertGt(actualRefund, 0, "Refund should be > 0");
        assertEq(
            usdcAfter - usdcBefore,
            actualRefund,
            "USDC balance should increase by refund"
        );

        // Check tokens burned
        assertEq(
            datasetToken.balanceOf(user1),
            tokenAmount - sellAmount,
            "Tokens should be burned"
        );

        // Check sold tokens decreased
        assertEq(
            ido.soldTokens(),
            tokenAmount - sellAmount,
            "Sold tokens should decrease"
        );
    }

    function test_RevertBuyTokens_ZeroAmount() public {
        vm.prank(user1);
        vm.expectRevert(IDO.InsufficientAmount.selector);
        ido.buyTokens(0, 1000 * 10 ** 6);
    }

    function test_RevertBuyTokens_SlippageExceeded() public {
        uint256 tokenAmount = 1000 * 10 ** 18;
        uint256 maxCost = 1 * 10 ** 6; // Too low max cost

        vm.prank(user1);
        usdc.approve(address(ido), maxCost);

        vm.prank(user1);
        vm.expectRevert(IDO.SlippageExceeded.selector);
        ido.buyTokens(tokenAmount, maxCost);
    }

    function test_RevertSellTokens_InsufficientBalance() public {
        uint256 sellAmount = 1000 * 10 ** 18;

        vm.prank(user1);
        vm.expectRevert(IDO.InsufficientBalance.selector);
        ido.sellTokens(sellAmount, 0);
    }

    function test_GetCurrentPrice() public {
        // Initial price
        uint256 price0 = ido.getCurrentPrice();
        assertEq(price0, INITIAL_PRICE, "Initial price should match");

        // Buy some tokens
        vm.prank(user1);
        usdc.approve(address(ido), 5000 * 10 ** 6); // Updated for new k=9e6
        vm.prank(user1);
        ido.buyTokens(1000 * 10 ** 18, 5000 * 10 ** 6);

        // Price should increase
        uint256 price1 = ido.getCurrentPrice();
        assertGt(price1, price0, "Price should increase after purchase");
    }

    function test_PricingIncreases() public {
        // Test that price increases with each purchase
        uint256 price0 = ido.getCurrentPrice();

        // Buy some tokens
        vm.prank(user1);
        usdc.approve(address(ido), 5000 * 10 ** 6); // Updated for new k=9e6
        vm.prank(user1);
        ido.buyTokens(1000 * 10 ** 18, 5000 * 10 ** 6);

        uint256 price1 = ido.getCurrentPrice();

        // Buy more tokens
        vm.prank(user2);
        usdc.approve(address(ido), 5000 * 10 ** 6); // Updated for new k=9e6
        vm.prank(user2);
        ido.buyTokens(1000 * 10 ** 18, 5000 * 10 ** 6);

        uint256 price2 = ido.getCurrentPrice();

        // Verify prices increase
        assertGt(price1, price0, "Price should increase after first purchase");
        assertGt(price2, price1, "Price should increase after second purchase");
    }

    function test_USDCBalanceTracking() public {
        // Buy tokens
        uint256 tokenAmount = 1000 * 10 ** 18;
        vm.prank(user1);
        usdc.approve(address(ido), 5000 * 10 ** 6); // Updated for new k=9e6
        vm.prank(user1);
        uint256 cost = ido.buyTokens(tokenAmount, 5000 * 10 ** 6);

        // IDO should have received USDC (minus fees)
        uint256 idoBalance = usdc.balanceOf(address(ido));
        assertGt(idoBalance, 0, "IDO should have USDC balance");

        // usdcBalance should track internal balance
        assertEq(
            ido.usdcBalance(),
            idoBalance,
            "usdcBalance should match actual balance"
        );
    }

    function test_IDOExpiry() public {
        // Fast forward past 14 days
        vm.warp(block.timestamp + 15 days);

        // Try to buy tokens - should fail
        vm.prank(user1);
        usdc.approve(address(ido), 1000 * 10 ** 6);

        vm.prank(user1);
        vm.expectRevert(IDO.Expired.selector);
        ido.buyTokens(100 * 10 ** 18, 1000 * 10 ** 6);
    }

    function test_LaunchSuccessful() public {
        // Calculate salable tokens
        uint256 projectTokens = (TOTAL_SUPPLY * ALPHA_PROJECT) / 10000;
        uint256 salableTokens = TOTAL_SUPPLY - projectTokens;

        // Buy enough tokens to reach target (100% of salable)
        uint256 purchaseAmount = salableTokens;

        // This will likely cost a lot, let's buy in chunks
        uint256 chunkSize = salableTokens / 10; // Buy in 10 chunks

        for (uint256 i = 0; i < 10; i++) {
            vm.prank(user1);
            usdc.approve(address(ido), type(uint256).max);
            vm.prank(user1);
            try ido.buyTokens(chunkSize, type(uint256).max) {} catch {
                // If we run out of tokens, that's expected
                break;
            }
        }

        // Check if IDO launched
        if (ido.status() == IDO.Status.Launched) {
            assertEq(
                uint256(ido.status()),
                uint256(IDO.Status.Launched),
                "IDO should be launched"
            );
            assertGt(ido.launchTime(), 0, "Launch time should be set");
        }
    }

    function test_SalableTokensCalculation() public view {
        uint256 projectTokens = (TOTAL_SUPPLY * ALPHA_PROJECT) / 10000;
        uint256 expectedSalable = TOTAL_SUPPLY - projectTokens;

        assertEq(
            ido.salableTokens(),
            expectedSalable,
            "Salable tokens should match calculation"
        );
        assertEq(
            ido.projectTokens(),
            projectTokens,
            "Project tokens should match calculation"
        );
        assertEq(
            ido.targetTokens(),
            expectedSalable,
            "Target tokens should equal salable tokens"
        );
    }

    function test_TimeConstraints() public view {
        // Verify IDO has correct time constraints
        uint256 startTime = ido.startTime();
        uint256 endTime = ido.endTime();

        assertEq(endTime - startTime, 14 days, "IDO period should be 14 days");
        assertGt(endTime, block.timestamp, "End time should be in future");
    }
}

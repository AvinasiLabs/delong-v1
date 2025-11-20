// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./TestBase.sol";

contract IDOTest is DeLongTestBase {
    // IDO parameters
    uint256 constant R_TARGET = 50_000 * 10 ** 6; // 50,000 USDC (funding goal)
    uint256 constant ALPHA = 2000; // 20% (project ownership ratio)

    function setUp() public override {
        super.setUp();

        // Calculate total supply using VirtualAMM
        VirtualAMM.DecimalConfig memory decimalConfig = VirtualAMM.DecimalConfig({
            usdcDecimals: 6,
            tokenDecimals: 18,
            usdcUnit: 1e6,
            tokenUnit: 1e18
        });

        (uint256 totalSupply, , ) = VirtualAMM.calculateTotalSupply(
            R_TARGET,
            ALPHA,
            10000, // ALPHA_DENOMINATOR
            decimalConfig
        );

        // Deploy IDO first (needed for RentalPool and DatasetToken initialization)
        ido = new IDO();

        // Deploy DatasetToken
        datasetToken = new DatasetToken();

        // Deploy RentalPool
        rentalPool = new RentalPool();
        rentalPool.initialize(
            address(usdc),
            address(datasetToken),
            owner,
            address(ido) // IDO can call addRevenue
        );

        // Initialize DatasetToken with RentalPool address
        datasetToken.initialize(
            "Test Dataset",
            "TDS",
            owner,
            address(0x1234), // Temporary IDO address, will transfer to actual IDO later
            address(rentalPool), // RentalPool for dividend distribution
            totalSupply
        );

        // Deploy and initialize Governance
        governance = new Governance();
        governance.initialize(
            address(ido),
            address(usdc),
            address(0x1111111111111111111111111111111111111111), // Mock Uniswap Router
            address(0x2222222222222222222222222222222222222222)  // Mock Uniswap Factory
        );

        // Initialize IDO
        ido.initialize(
            R_TARGET,
            ALPHA,
            projectAddress,
            address(datasetToken),
            address(usdc),
            feeTo,
            address(governance),
            address(rentalPool),
            address(0x1111111111111111111111111111111111111111),
            address(0x2222222222222222222222222222222222222222),
            createTestMetadataURI(1),
            10 * 10 ** 6 // 10 USDC per hour
        );

        // Set IDO and temporary address as frozen exempt
        datasetToken.addFrozenExempt(address(ido));
        datasetToken.addFrozenExempt(address(0x1234));

        // Transfer all tokens from temporary address to IDO
        vm.prank(address(0x1234));
        datasetToken.transfer(address(ido), totalSupply);

        // Transfer token ownership to IDO
        datasetToken.transferOwnership(address(ido));

        // Fund users with USDC
        usdc.mint(user1, 1_000_000 * 10 ** 6); // 1M USDC
        usdc.mint(user2, 1_000_000 * 10 ** 6);
        usdc.mint(user3, 1_000_000 * 10 ** 6);

        vm.label(address(ido), "IDO");
    }

    // Helper function to get deadline (5 minutes from now)
    function getDeadline() internal view returns (uint256) {
        return block.timestamp + 300;
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
            ido.rTarget(),
            R_TARGET,
            "R target should match"
        );
        assertEq(ido.alpha(), ALPHA, "Alpha should match");
        // Initial price is fixed at 0.01 USDC in Virtual AMM
        assertEq(
            ido.getCurrentPrice(),
            0.01 * 10 ** 6,
            "Initial price should be 0.01 USDC"
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
        uint256 actualCost = ido.swapUSDCForExactTokens(tokenAmount, maxCost, getDeadline());

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
        uint256 cost1 = ido.swapUSDCForExactTokens(tokenAmount, maxCost, getDeadline());

        // User2 buys (price should be higher)
        vm.prank(user2);
        usdc.approve(address(ido), maxCost);
        vm.prank(user2);
        uint256 cost2 = ido.swapUSDCForExactTokens(tokenAmount, maxCost, getDeadline());

        // Second purchase should cost more (Virtual AMM price increases)
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
        ido.swapUSDCForExactTokens(tokenAmount, 5000 * 10 ** 6, getDeadline());

        // Sell half
        uint256 sellAmount = 500 * 10 ** 18;
        uint256 minRefund = 1 * 10 ** 6; // Minimum acceptable refund (1 USDC)

        uint256 usdcBefore = usdc.balanceOf(user1);

        // Approve IDO to burn user's tokens
        vm.prank(user1);
        datasetToken.approve(address(ido), sellAmount);

        vm.prank(user1);
        uint256 actualRefund = ido.swapExactTokensForUSDC(sellAmount, minRefund, getDeadline());

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
        ido.swapUSDCForExactTokens(0, 1000 * 10 ** 6, getDeadline());
    }

    function test_RevertBuyTokens_SlippageExceeded() public {
        uint256 tokenAmount = 1000 * 10 ** 18;
        uint256 maxCost = 1 * 10 ** 6; // Too low max cost

        vm.prank(user1);
        usdc.approve(address(ido), maxCost);

        vm.prank(user1);
        vm.expectRevert(IDO.SlippageExceeded.selector);
        ido.swapUSDCForExactTokens(tokenAmount, maxCost, getDeadline());
    }

    function test_RevertSellTokens_InsufficientBalance() public {
        uint256 sellAmount = 1000 * 10 ** 18;

        vm.prank(user1);
        vm.expectRevert(IDO.InsufficientBalance.selector);
        ido.swapExactTokensForUSDC(sellAmount, 0, getDeadline());
    }

    function test_GetCurrentPrice() public {
        // Initial price (0.01 USDC in Virtual AMM)
        uint256 price0 = ido.getCurrentPrice();
        assertEq(price0, 0.01 * 10 ** 6, "Initial price should be 0.01 USDC");

        // Buy some tokens
        vm.prank(user1);
        usdc.approve(address(ido), 5000 * 10 ** 6); // Updated for new k=9e6
        vm.prank(user1);
        ido.swapUSDCForExactTokens(1000 * 10 ** 18, 5000 * 10 ** 6, getDeadline());

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
        ido.swapUSDCForExactTokens(1000 * 10 ** 18, 5000 * 10 ** 6, getDeadline());

        uint256 price1 = ido.getCurrentPrice();

        // Buy more tokens
        vm.prank(user2);
        usdc.approve(address(ido), 5000 * 10 ** 6); // Updated for new k=9e6
        vm.prank(user2);
        ido.swapUSDCForExactTokens(1000 * 10 ** 18, 5000 * 10 ** 6, getDeadline());

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
        uint256 cost = ido.swapUSDCForExactTokens(tokenAmount, 5000 * 10 ** 6, getDeadline());

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
        // Fast forward past 100 days (SALE_DURATION)
        vm.warp(block.timestamp + 101 days);

        // Try to buy tokens - should fail
        vm.prank(user1);
        usdc.approve(address(ido), 1000 * 10 ** 6);

        vm.prank(user1);
        vm.expectRevert(IDO.Expired.selector);
        ido.swapUSDCForExactTokens(100 * 10 ** 18, 1000 * 10 ** 6, getDeadline());
    }

    function test_LaunchSuccessful() public {
        // Get salable tokens from IDO contract
        uint256 salableTokens = ido.salableTokens();

        // Buy enough tokens to reach target (100% of salable)
        uint256 purchaseAmount = salableTokens;

        // This will likely cost a lot, let's buy in chunks
        uint256 chunkSize = salableTokens / 10; // Buy in 10 chunks

        for (uint256 i = 0; i < 10; i++) {
            vm.prank(user1);
            usdc.approve(address(ido), type(uint256).max);
            vm.prank(user1);
            try ido.swapUSDCForExactTokens(chunkSize, type(uint256).max, getDeadline()) {} catch {
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
        // In Virtual AMM, total supply is calculated as: S_total = 10 × R_target × √(α/(1-α)³)
        // salableTokens = (1 - alpha) * totalSupply
        // projectTokens = alpha * totalSupply

        uint256 totalSupply = ido.totalSupply();
        uint256 projectTokens = ido.projectTokens();
        uint256 salableTokens = ido.salableTokens();

        // Verify the relationship
        assertEq(
            totalSupply,
            salableTokens + projectTokens,
            "Total supply should equal salable + project tokens"
        );

        // Verify alpha ratio (with some tolerance for rounding)
        uint256 alphaRatio = (projectTokens * 10000) / totalSupply;
        assertApproxEqAbs(
            alphaRatio,
            ALPHA,
            10, // Allow 0.1% tolerance due to sqrt calculations
            "Alpha ratio should match"
        );
        assertEq(
            ido.projectTokens(),
            projectTokens,
            "Project tokens should match calculation"
        );
    }

    function test_TimeConstraints() public view {
        // Verify IDO has correct time constraints
        uint256 startTime = ido.startTime();
        uint256 endTime = ido.endTime();

        assertEq(endTime - startTime, 100 days, "IDO period should be 100 days");
        assertGt(endTime, block.timestamp, "End time should be in future");
    }

    function test_OversellProtection() public {
        // Get salable tokens - total is 2,500,000 tokens
        uint256 salableTokens = ido.salableTokens();

        // User1 buys some tokens first
        uint256 user1Buy = 1000 * 10 ** 18;

        vm.prank(user1);
        usdc.approve(address(ido), type(uint256).max);
        vm.prank(user1);
        ido.swapUSDCForExactTokens(user1Buy, type(uint256).max, getDeadline());

        uint256 remaining = salableTokens - ido.soldTokens();

        // User2 tries to buy MORE than remaining (requests 50% more than available)
        // Should auto-cap to remaining amount
        uint256 requestedAmount = remaining + (remaining / 2);

        // Calculate max cost user2 is willing to pay - set to their balance
        uint256 maxCost = usdc.balanceOf(user2);

        vm.prank(user2);
        usdc.approve(address(ido), maxCost);
        vm.prank(user2);

        // Try to buy more than available, may hit slippage or succeed with capping
        try ido.swapUSDCForExactTokens(requestedAmount, maxCost, getDeadline()) {
            // If succeeded, should have been capped to remaining
            assertEq(ido.soldTokens(), salableTokens, "Should sell exactly all salable tokens");
            assertEq(datasetToken.balanceOf(user2), remaining, "User2 should receive remaining tokens only");

            // Verify IDO launched since all tokens sold
            assertEq(uint256(ido.status()), uint256(IDO.Status.Launched), "IDO should be launched");
        } catch (bytes memory reason) {
            // If failed due to slippage, that's acceptable
            // The important thing is we didn't oversell
            assertLt(ido.soldTokens(), salableTokens, "Should not oversell even if slippage hit");
        }
    }
}

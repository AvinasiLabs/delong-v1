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

    // Uniswap mock addresses from setUp
    address constant UNISWAP_ROUTER = 0x1111111111111111111111111111111111111111;
    address constant UNISWAP_FACTORY = 0x2222222222222222222222222222222222222222;
    address constant MOCK_LP_PAIR = 0x3333333333333333333333333333333333333333;

    // Helper to set up Uniswap mocks for launch testing
    function _setupUniswapMocks(uint256 expectedLpTokens) internal {
        // Mock getPair to return address(0) (pair doesn't exist yet)
        vm.mockCall(
            UNISWAP_FACTORY,
            abi.encodeWithSignature("getPair(address,address)", address(usdc), address(datasetToken)),
            abi.encode(address(0))
        );

        // Mock createPair to return mock LP pair address
        vm.mockCall(
            UNISWAP_FACTORY,
            abi.encodeWithSignature("createPair(address,address)", address(usdc), address(datasetToken)),
            abi.encode(MOCK_LP_PAIR)
        );

        // Mock addLiquidity to return expected values
        // Signature: addLiquidity(address,address,uint256,uint256,uint256,uint256,address,uint256)
        // Returns: (amountA, amountB, liquidity)
        vm.mockCall(
            UNISWAP_ROUTER,
            abi.encodeWithSelector(
                bytes4(keccak256("addLiquidity(address,address,uint256,uint256,uint256,uint256,address,uint256)"))
            ),
            abi.encode(1e6, 1e18, expectedLpTokens) // amountUSDC, amountToken, lpTokens
        );

        // Mock LP pair's approve and transfer functions
        vm.mockCall(
            MOCK_LP_PAIR,
            abi.encodeWithSignature("approve(address,uint256)", address(governance), expectedLpTokens),
            abi.encode(true)
        );

        // Mock LP pair balance for governance lockLP
        vm.mockCall(
            MOCK_LP_PAIR,
            abi.encodeWithSignature("balanceOf(address)", address(ido)),
            abi.encode(expectedLpTokens)
        );

        // Mock LP pair transferFrom for governance lockLP
        vm.mockCall(
            MOCK_LP_PAIR,
            abi.encodeWithSelector(bytes4(keccak256("transferFrom(address,address,uint256)"))),
            abi.encode(true)
        );

        // Mock DatasetToken unfreeze (IDO contract in DatasetToken is 0x1234, not actual IDO)
        // We need to mock the unfreeze call from IDO contract perspective
        vm.mockCall(
            address(datasetToken),
            abi.encodeWithSignature("unfreeze()"),
            abi.encode()
        );
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
        // Setup Uniswap mocks for successful launch
        uint256 expectedLpTokens = 1000e18;
        _setupUniswapMocks(expectedLpTokens);

        // Get salable tokens from IDO contract
        uint256 salableTokens = ido.salableTokens();

        // Buy in chunks until all sold
        uint256 chunkSize = salableTokens / 10;

        // Approve unlimited USDC for user1
        vm.prank(user1);
        usdc.approve(address(ido), type(uint256).max);

        for (uint256 i = 0; i < 10; i++) {
            uint256 remaining = salableTokens - ido.soldTokens();
            if (remaining == 0) break;

            uint256 buyAmount = remaining < chunkSize ? remaining : chunkSize;
            vm.prank(user1);
            ido.swapUSDCForExactTokens(buyAmount, type(uint256).max, getDeadline());
        }

        // Verify IDO launched successfully
        assertEq(
            uint256(ido.status()),
            uint256(IDO.Status.Launched),
            "IDO should be launched"
        );
        assertGt(ido.launchTime(), 0, "Launch time should be set");
        assertEq(ido.soldTokens(), salableTokens, "All salable tokens should be sold");
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
        // Setup Uniswap mocks for successful launch
        uint256 expectedLpTokens = 1000e18;
        _setupUniswapMocks(expectedLpTokens);

        // Get salable tokens - total is 2,500,000 tokens
        uint256 salableTokens = ido.salableTokens();

        // User1 buys most tokens first (leave only 1000 tokens)
        uint256 remainingTarget = 1000 * 10 ** 18;
        uint256 user1Buy = salableTokens - remainingTarget;

        vm.prank(user1);
        usdc.approve(address(ido), type(uint256).max);
        vm.prank(user1);
        ido.swapUSDCForExactTokens(user1Buy, type(uint256).max, getDeadline());

        uint256 remaining = salableTokens - ido.soldTokens();
        assertEq(remaining, remainingTarget, "Should have exactly 1000 tokens remaining");

        // User2 tries to buy MORE than remaining (requests 150% of remaining)
        // Should auto-cap to remaining amount
        uint256 requestedAmount = remaining + (remaining / 2);

        vm.prank(user2);
        usdc.approve(address(ido), type(uint256).max);
        vm.prank(user2);
        ido.swapUSDCForExactTokens(requestedAmount, type(uint256).max, getDeadline());

        // Verify auto-cap: user2 should only receive remaining tokens, not requested amount
        assertEq(datasetToken.balanceOf(user2), remaining, "User2 should receive remaining tokens only (auto-capped)");
        assertEq(ido.soldTokens(), salableTokens, "Should sell exactly all salable tokens");

        // Verify IDO launched since all tokens sold
        assertEq(uint256(ido.status()), uint256(IDO.Status.Launched), "IDO should be launched");
    }

    // ========== Refund Tests ==========

    function test_TriggerRefund() public {
        // User1 buys some tokens (but not all)
        uint256 tokenAmount = 10_000 * 10 ** 18;
        vm.prank(user1);
        usdc.approve(address(ido), 50_000e6);
        vm.prank(user1);
        ido.swapUSDCForExactTokens(tokenAmount, 50_000e6, getDeadline());

        // Fast forward past 100 days
        vm.warp(block.timestamp + 101 days);

        // Trigger refund
        ido.triggerRefund();

        // Verify status is Failed
        assertEq(
            uint256(ido.status()),
            uint256(IDO.Status.Failed),
            "Status should be Failed"
        );

        // Verify refund rate is set
        assertGt(ido.refundRate(), 0, "Refund rate should be set");
    }

    function test_ClaimRefund_AfterFailed() public {
        // User1 buys some tokens
        uint256 tokenAmount = 10_000 * 10 ** 18;
        vm.prank(user1);
        usdc.approve(address(ido), 50_000e6);
        vm.prank(user1);
        ido.swapUSDCForExactTokens(tokenAmount, 50_000e6, getDeadline());

        uint256 user1TokenBalance = datasetToken.balanceOf(user1);
        assertEq(user1TokenBalance, tokenAmount, "User1 should have tokens");

        // Fast forward and trigger refund
        vm.warp(block.timestamp + 101 days);
        ido.triggerRefund();

        // User1 approves tokens for refund
        vm.prank(user1);
        datasetToken.approve(address(ido), user1TokenBalance);

        // User1 claims refund
        uint256 usdcBefore = usdc.balanceOf(user1);
        vm.prank(user1);
        uint256 refundAmount = ido.claimRefund();

        // Verify refund received
        assertGt(refundAmount, 0, "Refund should be > 0");
        assertEq(
            usdc.balanceOf(user1),
            usdcBefore + refundAmount,
            "USDC balance should increase"
        );

        // Verify tokens were transferred back
        assertEq(
            datasetToken.balanceOf(user1),
            0,
            "User1 tokens should be transferred to IDO"
        );

        // Verify claim recorded
        assertTrue(ido.hasClaimedRefund(user1), "User1 should be marked as claimed");
    }

    function test_ClaimRefund_MultipleUsers() public {
        // User1 buys tokens
        vm.prank(user1);
        usdc.approve(address(ido), 50_000e6);
        vm.prank(user1);
        ido.swapUSDCForExactTokens(10_000 * 10 ** 18, 50_000e6, getDeadline());

        // User2 buys tokens
        vm.prank(user2);
        usdc.approve(address(ido), 50_000e6);
        vm.prank(user2);
        ido.swapUSDCForExactTokens(5_000 * 10 ** 18, 50_000e6, getDeadline());

        uint256 user1Tokens = datasetToken.balanceOf(user1);
        uint256 user2Tokens = datasetToken.balanceOf(user2);

        // Trigger refund
        vm.warp(block.timestamp + 101 days);
        ido.triggerRefund();

        // Both users claim
        vm.prank(user1);
        datasetToken.approve(address(ido), user1Tokens);
        vm.prank(user1);
        uint256 refund1 = ido.claimRefund();

        vm.prank(user2);
        datasetToken.approve(address(ido), user2Tokens);
        vm.prank(user2);
        uint256 refund2 = ido.claimRefund();

        // User1 had more tokens, should get proportionally more refund
        assertGt(refund1, refund2, "User1 should get more refund (more tokens)");

        // Both should have claimed
        assertTrue(ido.hasClaimedRefund(user1), "User1 claimed");
        assertTrue(ido.hasClaimedRefund(user2), "User2 claimed");
    }

    function test_ClaimRefund_ExactAmountCalculation() public {
        // This test verifies the exact refund calculation
        // User pays X USDC (including 5% protocol fee)
        // Contract receives X * 0.95 USDC (after fee deduction)
        // Refund should return the proportional amount based on tokens held

        uint256 tokenAmount = 10_000 * 10 ** 18;

        // Record USDC balance before purchase
        uint256 user1UsdcBefore = usdc.balanceOf(user1);

        // User1 buys tokens
        vm.prank(user1);
        usdc.approve(address(ido), type(uint256).max);
        vm.prank(user1);
        uint256 actualCost = ido.swapUSDCForExactTokens(tokenAmount, type(uint256).max, getDeadline());

        // Calculate what went into the contract (after 0.3% buy fee)
        // actualCost includes fee, so contract received: costWithoutFee
        uint256 usdcInContract = ido.usdcBalance();

        // Verify user spent the right amount
        assertEq(
            user1UsdcBefore - usdc.balanceOf(user1),
            actualCost,
            "User should have spent actualCost"
        );

        // Trigger refund
        vm.warp(block.timestamp + 101 days);
        ido.triggerRefund();

        // Verify refund rate calculation
        // refundRate = (usdcBalance * 1e18) / soldTokens
        uint256 expectedRefundRate = (usdcInContract * 1e18) / ido.soldTokens();
        assertEq(ido.refundRate(), expectedRefundRate, "Refund rate should match");

        // User claims refund
        uint256 user1Tokens = datasetToken.balanceOf(user1);
        vm.prank(user1);
        datasetToken.approve(address(ido), user1Tokens);

        uint256 usdcBeforeClaim = usdc.balanceOf(user1);
        vm.prank(user1);
        uint256 refundAmount = ido.claimRefund();

        // Verify exact refund amount
        // refundAmount = (tokenBalance * refundRate) / 1e18
        uint256 expectedRefund = (user1Tokens * expectedRefundRate) / 1e18;
        assertEq(refundAmount, expectedRefund, "Refund amount should match calculation");

        // Verify USDC balance increased by refund amount
        assertEq(
            usdc.balanceOf(user1),
            usdcBeforeClaim + refundAmount,
            "USDC balance should increase by refund amount"
        );

        // Verify user gets back less than they paid (due to buy fee)
        // BUY_FEE_RATE = 30 / 10000 = 0.3%
        // User paid: costWithoutFee + fee, contract only keeps costWithoutFee
        assertLt(
            refundAmount,
            actualCost,
            "Refund should be less than original cost (buy fee deducted)"
        );

        // Verify the loss is approximately the buy fee (0.3%)
        // actualCost = costWithoutFee + fee where fee = costWithoutFee * 30 / 10000
        // So: actualCost = costWithoutFee * (1 + 30/10000) = costWithoutFee * 10030 / 10000
        // costWithoutFee = actualCost * 10000 / 10030
        // fee = actualCost - costWithoutFee = actualCost * 30 / 10030
        uint256 loss = actualCost - refundAmount;
        uint256 expectedLoss = (actualCost * 30) / 10030; // 0.3% of total cost
        assertApproxEqAbs(
            loss,
            expectedLoss,
            1000, // Allow rounding error due to integer division
            "Loss should approximately equal buy fee (0.3%)"
        );
    }

    function test_RevertTriggerRefund_NotExpired() public {
        // User1 buys some tokens
        vm.prank(user1);
        usdc.approve(address(ido), 50_000e6);
        vm.prank(user1);
        ido.swapUSDCForExactTokens(10_000 * 10 ** 18, 50_000e6, getDeadline());

        // Try to trigger refund before expiry
        vm.expectRevert(IDO.NotExpired.selector);
        ido.triggerRefund();
    }

    function test_RevertTriggerRefund_AfterLaunch() public {
        // Setup Uniswap mocks for successful launch
        uint256 expectedLpTokens = 1000e18;
        _setupUniswapMocks(expectedLpTokens);

        // Buy ALL salable tokens - triggers launch
        uint256 salableTokens = ido.salableTokens();
        uint256 chunkSize = salableTokens / 10;

        vm.prank(user1);
        usdc.approve(address(ido), type(uint256).max);

        for (uint256 i = 0; i < 10; i++) {
            uint256 remaining = salableTokens - ido.soldTokens();
            if (remaining == 0) break;

            uint256 buyAmount = remaining < chunkSize ? remaining : chunkSize;
            vm.prank(user1);
            ido.swapUSDCForExactTokens(buyAmount, type(uint256).max, getDeadline());
        }

        // Verify launch succeeded
        assertEq(uint256(ido.status()), uint256(IDO.Status.Launched), "IDO should be launched");

        // Fast forward past original expiry time
        vm.warp(block.timestamp + 101 days);

        // Try to trigger refund - should fail because IDO already launched
        vm.expectRevert(IDO.NotActive.selector);
        ido.triggerRefund();
    }

    function test_RevertClaimRefund_NotFailed() public {
        // Try to claim without triggering refund first
        vm.prank(user1);
        vm.expectRevert(IDO.NotFailed.selector);
        ido.claimRefund();
    }

    function test_RevertClaimRefund_AlreadyClaimed() public {
        // User1 buys tokens
        vm.prank(user1);
        usdc.approve(address(ido), 50_000e6);
        vm.prank(user1);
        ido.swapUSDCForExactTokens(10_000 * 10 ** 18, 50_000e6, getDeadline());

        // Trigger refund
        vm.warp(block.timestamp + 101 days);
        ido.triggerRefund();

        // User1 claims
        uint256 user1Tokens = datasetToken.balanceOf(user1);
        vm.prank(user1);
        datasetToken.approve(address(ido), user1Tokens);
        vm.prank(user1);
        ido.claimRefund();

        // Try to claim again
        vm.prank(user1);
        vm.expectRevert(IDO.AlreadyClaimed.selector);
        ido.claimRefund();
    }

    function test_RevertClaimRefund_NoTokens() public {
        // User1 buys tokens (not user3)
        vm.prank(user1);
        usdc.approve(address(ido), 50_000e6);
        vm.prank(user1);
        ido.swapUSDCForExactTokens(10_000 * 10 ** 18, 50_000e6, getDeadline());

        // Trigger refund
        vm.warp(block.timestamp + 101 days);
        ido.triggerRefund();

        // User3 (who has no tokens) tries to claim
        vm.prank(user3);
        vm.expectRevert(IDO.InsufficientBalance.selector);
        ido.claimRefund();
    }
}

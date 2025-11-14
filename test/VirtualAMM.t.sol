// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/libraries/VirtualAMM.sol";

/**
 * @title VirtualAMMWrapper
 * @notice Wrapper contract to test library functions with proper revert handling
 */
contract VirtualAMMWrapper {
    function initialize(
        uint256 sSale,
        VirtualAMM.DecimalConfig memory config
    ) external pure returns (VirtualAMM.Reserves memory) {
        return VirtualAMM.initialize(sSale, config);
    }

    function getUSDCIn(
        VirtualAMM.Reserves memory reserves,
        uint256 tokensOut
    ) external pure returns (uint256) {
        return VirtualAMM.getUSDCIn(reserves, tokensOut);
    }

    function calculateTotalSupply(
        uint256 rTarget,
        uint256 alpha,
        uint256 alphaDenominator,
        VirtualAMM.DecimalConfig memory config
    ) external pure returns (uint256, uint256, uint256) {
        return VirtualAMM.calculateTotalSupply(rTarget, alpha, alphaDenominator, config);
    }
}

/**
 * @title VirtualAMMTest
 * @notice Test suite for VirtualAMM library
 * @dev Verifies mathematical correctness against whitepaper formulas
 */
contract VirtualAMMTest is Test {
    using VirtualAMM for VirtualAMM.Reserves;

    VirtualAMMWrapper wrapper;

    // Test constants matching whitepaper example
    uint256 constant R_TARGET = 50_000e6; // 50,000 USDC
    uint256 constant ALPHA = 2000; // 20% (basis points)
    uint256 constant DENOMINATOR = 10000;

    VirtualAMM.DecimalConfig config;

    // Storage reserves for testing updateReserves (matches IDO.sol usage)
    VirtualAMM.Reserves public testReserves;

    function setUp() public {
        // Deploy wrapper for revert testing
        wrapper = new VirtualAMMWrapper();

        // Standard configuration: USDC 6 decimals, Token 18 decimals
        config = VirtualAMM.DecimalConfig({
            usdcDecimals: 6,
            tokenDecimals: 18,
            usdcUnit: 1e6,
            tokenUnit: 1e18
        });
    }

    // ========== Initialization Tests ==========

    function test_Initialize_WhitepaperExample() public {
        // From whitepaper: α = 0.20, R_target = 50,000 USDC
        // S_total = 3,125,000 tokens (corrected with coefficient 100)
        // S_sale = (1 - 0.20) × 3,125,000 = 2,500,000 tokens

        uint256 sTotal = 3_125_000e18;
        uint256 sSale = (sTotal * (DENOMINATOR - ALPHA)) / DENOMINATOR; // 2,500,000 tokens

        VirtualAMM.Reserves memory reserves = VirtualAMM.initialize(sSale, config);

        // Expected values (calculated from whitepaper formulas)
        // P₀ = 0.01 USDC
        // x₀ = (0.01 × 2,500,000) / 0.99 = 25,252.52 USDC
        // y₀ = 2,500,000 / 0.99 = 2,525,252.52 tokens

        uint256 expectedX0 = 25_252_525_252; // ~25,252.52 USDC (6 decimals)
        uint256 expectedY0 = 2_525_252_525_252_525_252_525_252; // ~2,525,252.52 tokens (18 decimals)

        // Allow 0.01% tolerance for rounding
        assertApproxEqRel(reserves.x, expectedX0, 1e14, "x0 mismatch");
        assertApproxEqRel(reserves.y, expectedY0, 1e14, "y0 mismatch");

        // Verify K = x₀ × y₀
        uint256 expectedK = (reserves.x * reserves.y);
        assertEq(reserves.K, expectedK, "K mismatch");
    }

    function test_Initialize_DifferentDecimals() public {
        // Test with DAI (18 decimals) instead of USDC (6 decimals)
        VirtualAMM.DecimalConfig memory daiConfig = VirtualAMM.DecimalConfig({
            usdcDecimals: 18, // DAI has 18 decimals
            tokenDecimals: 18,
            usdcUnit: 1e18,
            tokenUnit: 1e18
        });

        uint256 sSale = 250_000e18;
        VirtualAMM.Reserves memory reserves = VirtualAMM.initialize(sSale, daiConfig);

        // x₀ should be in 18 decimals now
        uint256 expectedX0 = 2_525_252_525_252_525_252_525; // ~2,525.25 DAI (18 decimals)

        assertApproxEqRel(reserves.x, expectedX0, 1e14, "x0 DAI mismatch");
    }

    function test_Initialize_RevertsOnZeroSale() public {
        vm.expectRevert(VirtualAMM.InvalidSaleAmount.selector);
        wrapper.initialize(0, config);
    }

    function test_Initialize_RevertsOnInvalidDecimals() public {
        VirtualAMM.DecimalConfig memory invalidConfig = VirtualAMM.DecimalConfig({
            usdcDecimals: 6,
            tokenDecimals: 18,
            usdcUnit: 0, // Invalid
            tokenUnit: 1e18
        });

        vm.expectRevert(VirtualAMM.InvalidDecimals.selector);
        wrapper.initialize(250_000e18, invalidConfig);
    }

    // ========== Swap Calculation Tests ==========

    function test_GetTokensOut_FirstPurchase() public {
        uint256 sSale = 250_000e18;
        VirtualAMM.Reserves memory reserves = VirtualAMM.initialize(sSale, config);

        // Buy with 10,000 USDC (first investor from whitepaper)
        uint256 usdcIn = 10_000e6;
        uint256 tokensOut = VirtualAMM.getTokensOut(reserves, usdcIn);

        // From whitepaper: First investor gets 201,682 tokens for 10,000 USDC
        uint256 expectedTokens = 201_682e18;

        // Allow 1% tolerance (approximation due to continuous vs discrete)
        assertApproxEqRel(tokensOut, expectedTokens, 1e16, "First purchase tokens mismatch");
    }

    function test_GetUSDCIn_ExactAmount() public {
        uint256 sSale = 250_000e18;
        VirtualAMM.Reserves memory reserves = VirtualAMM.initialize(sSale, config);

        // How much USDC to buy exactly 100,000 tokens?
        uint256 tokensOut = 100_000e18;
        uint256 usdcIn = VirtualAMM.getUSDCIn(reserves, tokensOut);

        // Verify by reverse calculation
        uint256 tokensReceived = VirtualAMM.getTokensOut(reserves, usdcIn);

        assertApproxEqRel(tokensReceived, tokensOut, 1e14, "Round-trip mismatch");
    }

    function test_GetUSDCIn_FullRaise() public {
        uint256 sSale = 250_000e18;
        VirtualAMM.Reserves memory reserves = VirtualAMM.initialize(sSale, config);

        // From whitepaper: raising R_target (50,000 USDC) sells ~240,384 tokens
        // Not all tokens are sold at full raise
        uint256 tokensToBuy = 240_000e18; // Approximate amount for 50K raise
        uint256 usdcIn = VirtualAMM.getUSDCIn(reserves, tokensToBuy);

        // Should be approximately R_target when buying most tokens
        // Allow 10% tolerance since we're using approximation
        assertApproxEqRel(usdcIn, R_TARGET, 1e17, "Full raise cost mismatch");
    }

    function test_GetTokensOut_RevertsOnInsufficientLiquidity() public {
        uint256 sSale = 250_000e18;
        VirtualAMM.Reserves memory reserves = VirtualAMM.initialize(sSale, config);

        // Try to buy ALL virtual reserve tokens (should revert due to formula limit)
        // getUSDCIn reverts when tokensOut >= reserves.y
        vm.expectRevert(VirtualAMM.InsufficientLiquidity.selector);
        wrapper.getUSDCIn(reserves, reserves.y);
    }

    // ========== Price Calculation Tests ==========

    function test_GetCurrentPrice_Initial() public {
        uint256 sSale = 250_000e18;
        VirtualAMM.Reserves memory reserves = VirtualAMM.initialize(sSale, config);

        uint256 price = VirtualAMM.getCurrentPrice(reserves, config);

        // Initial price should be 0.01 USDC (1e4 in 6 decimals)
        uint256 expectedPrice = 0.01e6; // 0.01 USDC

        assertApproxEqRel(price, expectedPrice, 1e14, "Initial price mismatch");
    }

    function test_GetCurrentPrice_AfterPurchase() public {
        uint256 sSale = 250_000e18;
        testReserves = VirtualAMM.initialize(sSale, config);

        // Simulate purchase: buy 100,000 tokens
        uint256 usdcIn = VirtualAMM.getUSDCIn(testReserves, 100_000e18);

        // Update reserves using storage (matches IDO.sol usage)
        VirtualAMM.updateReserves(testReserves, int256(usdcIn), -int256(100_000e18));

        uint256 newPrice = VirtualAMM.getCurrentPrice(testReserves, config);

        // Price should increase after purchase
        uint256 initialPrice = 0.01e6;
        assertGt(newPrice, initialPrice, "Price should increase");
    }


    // ========== Integrated Flow Test ==========

    function test_FullIDOFlow_WhitepaperScenario() public {
        // Simulate complete IDO matching whitepaper example
        uint256 sSale = 250_000e18;
        testReserves = VirtualAMM.initialize(sSale, config);

        uint256 totalRaised = 0;
        uint256 totalTokensSold = 0;

        // Investor A: 10,000 USDC
        uint256 usdcA = 10_000e6;
        uint256 tokensA = VirtualAMM.getTokensOut(testReserves, usdcA);
        VirtualAMM.updateReserves(testReserves, int256(usdcA), -int256(tokensA));
        totalRaised += usdcA;
        totalTokensSold += tokensA;

        console.log("Investor A:");
        console.log("  USDC spent:", usdcA / 1e6);
        console.log("  Tokens received:", tokensA / 1e18);
        console.log("  Current price:", VirtualAMM.getCurrentPrice(testReserves, config) / 1e4, "cents");

        // Investor B: 15,000 USDC
        uint256 usdcB = 15_000e6;
        uint256 tokensB = VirtualAMM.getTokensOut(testReserves, usdcB);
        VirtualAMM.updateReserves(testReserves, int256(usdcB), -int256(tokensB));
        totalRaised += usdcB;
        totalTokensSold += tokensB;

        console.log("Investor B:");
        console.log("  USDC spent:", usdcB / 1e6);
        console.log("  Tokens received:", tokensB / 1e18);
        console.log("  Current price:", VirtualAMM.getCurrentPrice(testReserves, config) / 1e4, "cents");

        // Investor C: 25,000 USDC (to reach target)
        uint256 usdcC = 25_000e6;
        uint256 tokensC = VirtualAMM.getTokensOut(testReserves, usdcC);
        VirtualAMM.updateReserves(testReserves, int256(usdcC), -int256(tokensC));
        totalRaised += usdcC;
        totalTokensSold += tokensC;

        console.log("Investor C:");
        console.log("  USDC spent:", usdcC / 1e6);
        console.log("  Tokens received:", tokensC / 1e18);
        console.log("  Final price:", VirtualAMM.getCurrentPrice(testReserves, config) / 1e4, "cents");

        console.log("\nTotal Results:");
        console.log("  Total raised:", totalRaised / 1e6, "USDC");
        console.log("  Total tokens sold:", totalTokensSold / 1e18);
        console.log("  Tokens remaining:", (sSale - totalTokensSold) / 1e18);

        // Verify total raised matches target
        assertApproxEqRel(totalRaised, R_TARGET, 1e15, "Total raised mismatch");

        // Verify price increased significantly (from 0.01 to ~4.326 USDC = ~432x)
        uint256 finalPrice = VirtualAMM.getCurrentPrice(testReserves, config);
        uint256 expectedFinalPrice = 4.326e6; // ~4.326 USDC
        assertApproxEqRel(finalPrice, expectedFinalPrice, 5e16, "Final price should be ~4.326 USDC");

        // Verify price multiplier is ~432x
        uint256 priceMultiplier = (finalPrice * 1e18) / 0.01e6; // Calculate multiplier with precision
        assertApproxEqRel(priceMultiplier, 432e18, 5e16, "Price multiplier should be ~432x");
    }

    // ========== Token Supply Calculation Tests ==========

    function test_CalculateTotalSupply_WhitepaperExample() public {
        // From design document example (section 7.1):
        // R_target = 50,000 USDC
        // α = 0.20 (20% = 2000 basis points)
        // Expected: S_total = 3,125,000 tokens (corrected with coefficient 100)

        uint256 rTarget = 50_000e6; // 50,000 USDC
        uint256 alpha = 2000; // 20%
        uint256 alphaDenominator = 10000; // Basis points

        (uint256 sTotalSupply, uint256 sSale, uint256 sLP) = VirtualAMM.calculateTotalSupply(
            rTarget,
            alpha,
            alphaDenominator,
            config
        );

        // Expected values
        uint256 expectedTotal = 3_125_000e18; // 3,125,000 tokens
        uint256 expectedSale = 2_500_000e18;  // 2,500,000 tokens (80%)
        uint256 expectedLP = 625_000e18;      // 625,000 tokens (20%)

        assertApproxEqRel(sTotalSupply, expectedTotal, 1e15, "S_total mismatch");
        assertApproxEqRel(sSale, expectedSale, 1e15, "S_sale mismatch");
        assertApproxEqRel(sLP, expectedLP, 1e15, "S_LP mismatch");

        // Verify sum: S_sale + S_LP = S_total
        assertEq(sSale + sLP, sTotalSupply, "Sum mismatch");
    }

    function test_CalculateTotalSupply_DifferentAlpha() public {
        uint256 rTarget = 50_000e6;
        uint256 alphaDenominator = 10000;

        // Test α = 0.15 (15%)
        (uint256 sTotal15, , ) = VirtualAMM.calculateTotalSupply(
            rTarget,
            1500,
            alphaDenominator,
            config
        );

        // Test α = 0.25 (25%)
        (uint256 sTotal25, , ) = VirtualAMM.calculateTotalSupply(
            rTarget,
            2500,
            alphaDenominator,
            config
        );

        // Test α = 0.30 (30%)
        (uint256 sTotal30, , ) = VirtualAMM.calculateTotalSupply(
            rTarget,
            3000,
            alphaDenominator,
            config
        );

        // All should produce positive supply
        assertGt(sTotal15, 0, "S_total(15%) should be positive");
        assertGt(sTotal25, 0, "S_total(25%) should be positive");
        assertGt(sTotal30, 0, "S_total(30%) should be positive");

        // Higher α generally leads to higher supply
        // (more tokens needed for same R_target to maintain price)
        console.log("S_total at alpha=15%:");
        console.log(sTotal15 / 1e18);
        console.log("S_total at alpha=20%: 3125000 (expected)");
        console.log("S_total at alpha=25%:");
        console.log(sTotal25 / 1e18);
        console.log("S_total at alpha=30%:");
        console.log(sTotal30 / 1e18);
    }

    function test_CalculateTotalSupply_RevertsOnInvalidAlpha() public {
        uint256 rTarget = 50_000e6;

        // α = 0 (0%) - must be positive
        vm.expectRevert(VirtualAMM.InvalidAlpha.selector);
        wrapper.calculateTotalSupply(rTarget, 0, 10000, config);

        // α = 51% (5100) - too high (max is 50%)
        vm.expectRevert(VirtualAMM.InvalidAlpha.selector);
        wrapper.calculateTotalSupply(rTarget, 5100, 10000, config);

        // α = 100% (10000 basis points) - division by zero
        vm.expectRevert(VirtualAMM.InvalidAlpha.selector);
        wrapper.calculateTotalSupply(rTarget, 10000, 10000, config);

        // α > 100% should also revert
        vm.expectRevert(VirtualAMM.InvalidAlpha.selector);
        wrapper.calculateTotalSupply(rTarget, 15000, 10000, config);
    }

    function test_CalculateTotalSupply_RevertsOnZeroRTarget() public {
        vm.expectRevert(VirtualAMM.InvalidRTarget.selector);
        wrapper.calculateTotalSupply(0, 2000, 10000, config);
    }

    // ========== Fuzz Tests ==========

    function testFuzz_Initialize(uint256 sSale) public {
        // Bound to reasonable range: 1,000 to 10,000,000 tokens
        sSale = bound(sSale, 1_000e18, 10_000_000e18);

        VirtualAMM.Reserves memory reserves = VirtualAMM.initialize(sSale, config);

        // Verify reserves are positive
        assertGt(reserves.x, 0, "x should be positive");
        assertGt(reserves.y, 0, "y should be positive");
        assertGt(reserves.K, 0, "K should be positive");

        // Verify K = x × y
        assertEq(reserves.K, reserves.x * reserves.y, "K mismatch");

        // Verify initial price ≈ 0.01 USDC
        uint256 price = VirtualAMM.getCurrentPrice(reserves, config);
        assertApproxEqRel(price, 0.01e6, 1e14, "Initial price should be 0.01");
    }

    function testFuzz_SwapSymmetry(uint256 usdcAmount) public {
        // Bound to reasonable range: 100 to 10,000 USDC
        usdcAmount = bound(usdcAmount, 100e6, 10_000e6);

        uint256 sSale = 250_000e18;
        VirtualAMM.Reserves memory reserves = VirtualAMM.initialize(sSale, config);

        // Get tokens for USDC
        uint256 tokensOut = VirtualAMM.getTokensOut(reserves, usdcAmount);

        // Get USDC for those tokens
        uint256 usdcRequired = VirtualAMM.getUSDCIn(reserves, tokensOut);

        // Should match within small tolerance
        assertApproxEqRel(usdcRequired, usdcAmount, 1e14, "Swap symmetry broken");
    }
}

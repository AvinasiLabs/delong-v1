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
        uint256 rTarget,
        VirtualAMM.DecimalConfig memory config
    ) external pure returns (VirtualAMM.Reserves memory) {
        return VirtualAMM.initialize(sSale, rTarget, config);
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

    // Test rTarget for tests using sSale = 250_000e18
    // Calculated such that P₀ × sSale < rTarget
    uint256 constant TEST_R_TARGET = 5_000e6; // 5,000 USDC

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

        // Using correct formula: y₀ = (R_target × S_sale) / (R_target - P₀ × S_sale)
        // P₀ × S_sale = 0.01 × 2,500,000 = 25,000 USDC
        // denominator = 50,000 - 25,000 = 25,000 USDC
        // y₀ = (50,000 × 2,500,000) / 25,000 = 5,000,000 tokens
        // x₀ = 0.01 × 5,000,000 = 50,000 USDC
        VirtualAMM.Reserves memory reserves = VirtualAMM.initialize(sSale, R_TARGET, config);

        // Expected values (calculated from correct formulas)
        // P₀ = 0.01 USDC
        // y₀ = (R_target × S_sale) / (R_target - P₀ × S_sale)
        //    = (50,000 × 2,500,000) / (50,000 - 25,000) = 5,000,000 tokens
        // x₀ = P₀ × y₀ = 0.01 × 5,000,000 = 50,000 USDC

        uint256 expectedX0 = 50_000e6; // 50,000 USDC (6 decimals)
        uint256 expectedY0 = 5_000_000e18; // 5,000,000 tokens (18 decimals)

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
        uint256 rTargetDai = 5_000e18; // 5,000 DAI (18 decimals)
        VirtualAMM.Reserves memory reserves = VirtualAMM.initialize(sSale, rTargetDai, daiConfig);

        // With correct formula:
        // P₀ × S_sale = 0.01 × 250,000 = 2,500 DAI
        // denominator = 5,000 - 2,500 = 2,500 DAI
        // y₀ = (5,000 × 250,000) / 2,500 = 500,000 tokens
        // x₀ = 0.01 × 500,000 = 5,000 DAI
        uint256 expectedX0 = 5_000e18; // 5,000 DAI (18 decimals)

        assertApproxEqRel(reserves.x, expectedX0, 1e14, "x0 DAI mismatch");
    }

    function test_Initialize_RevertsOnZeroSale() public {
        vm.expectRevert(VirtualAMM.InvalidSaleAmount.selector);
        wrapper.initialize(0, TEST_R_TARGET, config);
    }

    function test_Initialize_RevertsOnInvalidDecimals() public {
        VirtualAMM.DecimalConfig memory invalidConfig = VirtualAMM.DecimalConfig({
            usdcDecimals: 6,
            tokenDecimals: 18,
            usdcUnit: 0, // Invalid
            tokenUnit: 1e18
        });

        vm.expectRevert(VirtualAMM.InvalidDecimals.selector);
        wrapper.initialize(250_000e18, TEST_R_TARGET, invalidConfig);
    }

    // ========== Swap Calculation Tests ==========

    function test_GetTokensOut_FirstPurchase() public {
        uint256 sSale = 250_000e18;
        VirtualAMM.Reserves memory reserves = VirtualAMM.initialize(sSale, TEST_R_TARGET, config);

        // Buy with 1,000 USDC (first investor)
        uint256 usdcIn = 1_000e6;
        uint256 tokensOut = VirtualAMM.getTokensOut(reserves, usdcIn);

        // With correct formula: y₀ = 500,000 tokens, x₀ = 5,000 USDC
        // tokensOut = (y × Δx) / (x + Δx) = (500,000 × 1,000) / (5,000 + 1,000) = 83,333 tokens
        uint256 expectedTokens = 83_333e18;

        // Allow 1% tolerance (approximation due to continuous vs discrete)
        assertApproxEqRel(tokensOut, expectedTokens, 1e16, "First purchase tokens mismatch");
    }

    function test_GetUSDCIn_ExactAmount() public {
        uint256 sSale = 250_000e18;
        VirtualAMM.Reserves memory reserves = VirtualAMM.initialize(sSale, TEST_R_TARGET, config);

        // How much USDC to buy exactly 100,000 tokens?
        uint256 tokensOut = 100_000e18;
        uint256 usdcIn = VirtualAMM.getUSDCIn(reserves, tokensOut);

        // Verify by reverse calculation
        uint256 tokensReceived = VirtualAMM.getTokensOut(reserves, usdcIn);

        assertApproxEqRel(tokensReceived, tokensOut, 1e14, "Round-trip mismatch");
    }

    function test_GetUSDCIn_FullRaise() public {
        uint256 sSale = 250_000e18;
        VirtualAMM.Reserves memory reserves = VirtualAMM.initialize(sSale, TEST_R_TARGET, config);

        // With correct formula: to raise all TEST_R_TARGET (5,000 USDC),
        // we need to sell all 250,000 sSale tokens
        // Testing with all salable tokens
        uint256 tokensToBuy = sSale;
        uint256 usdcIn = VirtualAMM.getUSDCIn(reserves, tokensToBuy);

        // Should be approximately TEST_R_TARGET when buying all salable tokens
        // Allow 1% tolerance
        assertApproxEqRel(usdcIn, TEST_R_TARGET, 1e16, "Full raise cost mismatch");
    }

    function test_GetTokensOut_RevertsOnInsufficientLiquidity() public {
        uint256 sSale = 250_000e18;
        VirtualAMM.Reserves memory reserves = VirtualAMM.initialize(sSale, TEST_R_TARGET, config);

        // Try to buy ALL virtual reserve tokens (should revert due to formula limit)
        // getUSDCIn reverts when tokensOut >= reserves.y
        vm.expectRevert(VirtualAMM.InsufficientLiquidity.selector);
        wrapper.getUSDCIn(reserves, reserves.y);
    }

    // ========== Price Calculation Tests ==========

    function test_GetCurrentPrice_Initial() public {
        uint256 sSale = 250_000e18;
        VirtualAMM.Reserves memory reserves = VirtualAMM.initialize(sSale, TEST_R_TARGET, config);

        uint256 price = VirtualAMM.getCurrentPrice(reserves, config);

        // Initial price should be 0.01 USDC (1e4 in 6 decimals)
        uint256 expectedPrice = 0.01e6; // 0.01 USDC

        assertApproxEqRel(price, expectedPrice, 1e14, "Initial price mismatch");
    }

    function test_GetCurrentPrice_AfterPurchase() public {
        uint256 sSale = 250_000e18;
        testReserves = VirtualAMM.initialize(sSale, TEST_R_TARGET, config);

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
        // Simulate complete IDO using whitepaper example:
        // R_target = 50,000 USDC, alpha = 20%
        // S_total = 3,125,000 tokens, S_sale = 2,500,000 tokens
        uint256 sTotal = 3_125_000e18;
        uint256 sSale = (sTotal * (DENOMINATOR - ALPHA)) / DENOMINATOR; // 2,500,000 tokens
        testReserves = VirtualAMM.initialize(sSale, R_TARGET, config);

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

        // With correct formula, price appreciation is different
        // Final price depends on how many tokens are sold
        uint256 finalPrice = VirtualAMM.getCurrentPrice(testReserves, config);

        // Price should increase significantly from initial 0.01 USDC
        assertGt(finalPrice, 0.01e6, "Final price should be higher than initial");

        // Log final price for verification
        console.log("  Final price (USDC):", finalPrice);
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

    function testFuzz_Initialize(uint256 sSale, uint256 rTarget) public {
        // Bound to reasonable range: 1,000 to 10,000,000 tokens
        sSale = bound(sSale, 1_000e18, 10_000_000e18);

        // rTarget must be > P₀ × sSale
        // P₀ × sSale (in USDC) = 0.01 × sSale_tokens = sSale / 100 / 1e12 (converting from 18 to 6 decimals)
        uint256 p0TimesSale = (sSale * 1 * 1e6) / (1e18 * 100);
        // Bound rTarget to be sufficiently larger than p0TimesSale
        rTarget = bound(rTarget, p0TimesSale + 1e6, p0TimesSale * 10);

        VirtualAMM.Reserves memory reserves = VirtualAMM.initialize(sSale, rTarget, config);

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
        // Bound to reasonable range: 100 to 1,000 USDC (within TEST_R_TARGET)
        usdcAmount = bound(usdcAmount, 100e6, 1_000e6);

        uint256 sSale = 250_000e18;
        VirtualAMM.Reserves memory reserves = VirtualAMM.initialize(sSale, TEST_R_TARGET, config);

        // Get tokens for USDC
        uint256 tokensOut = VirtualAMM.getTokensOut(reserves, usdcAmount);

        // Get USDC for those tokens
        uint256 usdcRequired = VirtualAMM.getUSDCIn(reserves, tokensOut);

        // Should match within small tolerance
        assertApproxEqRel(usdcRequired, usdcAmount, 1e14, "Swap symmetry broken");
    }
}

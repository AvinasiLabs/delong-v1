// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {UD60x18, ud, convert} from "@prb/math/src/UD60x18.sol";

/**
 * @title VirtualAMM
 * @notice Virtual Automated Market Maker library for IDO pricing
 * @dev Implements constant product formula (x * y = K) similar to Uniswap V2
 *      with virtual reserves to establish initial price
 *
 * Key features:
 * - Virtual reserves initialization for smooth price discovery
 * - Constant product invariant (K = x * y)
 * - Support for custom decimals (USDC 6, Token 18)
 * - Uses PRBMath UD60x18 for precise fixed-point arithmetic
 *
 * Mathematical Model:
 * - Initial price P₀ = 0.01 USDC (fixed)
 * - Virtual USDC reserve: x₀ = (P₀ × S_sale) / (1 - P₀)
 * - Virtual token reserve: y₀ = S_sale / (1 - P₀)
 * - Constant product: K = x₀ × y₀
 * - Swap formula: Δy = (y × Δx) / (x + Δx)
 * - Final price after full raise: P_final = (x₀ + R_target)² / K
 */
library VirtualAMM {
    // ========== Structs ==========

    /**
     * @notice Virtual reserve state
     * @param x Virtual USDC reserve (USDC decimals)
     * @param y Virtual token reserve (token decimals)
     * @param K Constant product invariant (x decimals + y decimals)
     */
    struct Reserves {
        uint256 x; // USDC reserve
        uint256 y; // Token reserve
        uint256 K; // Constant product
    }

    /**
     * @notice Configuration for decimal handling
     * @param usdcDecimals USDC token decimals (typically 6)
     * @param tokenDecimals Dataset token decimals (typically 18)
     * @param usdcUnit Base unit for USDC (10^usdcDecimals)
     * @param tokenUnit Base unit for tokens (10^tokenDecimals)
     */
    struct DecimalConfig {
        uint8 usdcDecimals;
        uint8 tokenDecimals;
        uint256 usdcUnit;
        uint256 tokenUnit;
    }

    // ========== Constants ==========

    /// @notice Fixed initial price: 0.01 USDC per token
    /// @dev P_0 = 0.01 means 1 cent, or 0.01 USDC
    uint256 private constant P0_NUMERATOR = 1; // 0.01 = 1/100
    uint256 private constant P0_DENOMINATOR = 100;

    // ========== Errors ==========

    error InvalidSaleAmount();
    error InvalidDecimals();
    error InsufficientLiquidity();
    error InvalidAlpha();
    error InvalidRTarget();

    // ========== Public Functions ==========

    /**
     * @notice Initialize virtual reserves for Virtual AMM
     * @dev Calculates x₀ and y₀ from salable tokens and initial price
     *
     * Formula:
     * x₀ = (P₀ × S_sale) / (1 - P₀)
     * y₀ = S_sale / (1 - P₀)
     * K = x₀ × y₀
     *
     * @param sSale Amount of tokens for sale (token decimals)
     * @param config Decimal configuration
     * @return reserves Initialized virtual reserves
     */
    function initialize(
        uint256 sSale,
        DecimalConfig memory config
    ) internal pure returns (Reserves memory reserves) {
        if (sSale == 0) revert InvalidSaleAmount();
        if (config.usdcUnit == 0 || config.tokenUnit == 0) {
            revert InvalidDecimals();
        }

        // P₀ = 0.01 = 1/100
        // (1 - P₀) = 0.99 = 99/100
        uint256 oneMinusP0Numerator = P0_DENOMINATOR - P0_NUMERATOR; // 99

        // x₀ = (P₀ × S_sale) / (1 - P₀)
        // = (0.01 × S_sale) / 0.99
        // = (S_sale / 100) / 0.99
        // = S_sale × 1 / (100 × 0.99)
        // = S_sale / 99
        //
        // Converting units:
        // S_sale is in token decimals (e.g., 250,000e18)
        // x₀ should be in USDC decimals (e.g., 2,525.25e6)
        //
        // x₀ = (S_sale / tokenUnit) × P₀ / (1 - P₀) × usdcUnit
        // = (S_sale × P0_NUMERATOR × usdcUnit) / (tokenUnit × P0_DENOMINATOR × oneMinusP0Numerator)
        reserves.x =
            (sSale * P0_NUMERATOR * config.usdcUnit) /
            (config.tokenUnit * oneMinusP0Numerator);

        // y₀ = S_sale / (1 - P₀)
        // = S_sale / 0.99
        // = S_sale × 100 / 99
        reserves.y = (sSale * P0_DENOMINATOR) / oneMinusP0Numerator;

        // K = x₀ × y₀
        reserves.K = reserves.x * reserves.y;
    }

    /**
     * @notice Calculate tokens received for USDC input
     * @dev Uses constant product formula: Δy = (y × Δx) / (x + Δx)
     *
     * @param reserves Current reserve state
     * @param usdcIn Amount of USDC to spend (USDC decimals)
     * @return tokensOut Amount of tokens received (token decimals)
     */
    function getTokensOut(
        Reserves memory reserves,
        uint256 usdcIn
    ) internal pure returns (uint256 tokensOut) {
        if (usdcIn == 0) return 0;
        if (reserves.y == 0) revert InsufficientLiquidity();

        // Δy = (y × Δx) / (x + Δx)
        tokensOut = (reserves.y * usdcIn) / (reserves.x + usdcIn);
    }

    /**
     * @notice Calculate USDC cost for token output
     * @dev Uses constant product formula: Δx = (x × Δy) / (y - Δy)
     *
     * @param reserves Current reserve state
     * @param tokensOut Amount of tokens to buy (token decimals)
     * @return usdcIn Amount of USDC required (USDC decimals)
     */
    function getUSDCIn(
        Reserves memory reserves,
        uint256 tokensOut
    ) internal pure returns (uint256 usdcIn) {
        if (tokensOut == 0) return 0;
        if (tokensOut >= reserves.y) revert InsufficientLiquidity();

        // Δx = (x × Δy) / (y - Δy)
        // Rearranged from K = (x + Δx)(y - Δy)
        // Add 1 to round up, ensuring K never decreases (same as Uniswap V2)
        usdcIn = (reserves.x * tokensOut) / (reserves.y - tokensOut) + 1;
    }

    /**
     * @notice Calculate USDC received for token input (selling tokens)
     * @dev Uses constant product formula: Δx = (x × Δy) / (y + Δy)
     *
     * When selling tokens to the AMM:
     * - Tokens flow INTO reserves (y increases)
     * - USDC flows OUT of reserves (x decreases)
     * - K = x × y = (x - Δx) × (y + Δy)
     * - Solving for Δx: Δx = (x × Δy) / (y + Δy)
     *
     * @param reserves Current reserve state
     * @param tokensIn Amount of tokens to sell (token decimals)
     * @return usdcOut Amount of USDC received (USDC decimals)
     */
    function getUSDCOut(
        Reserves memory reserves,
        uint256 tokensIn
    ) internal pure returns (uint256 usdcOut) {
        if (tokensIn == 0) return 0;

        // Δx = (x × Δy) / (y + Δy)
        // Rearranged from K = (x - Δx)(y + Δy)
        usdcOut = (reserves.x * tokensIn) / (reserves.y + tokensIn);
    }

    /**
     * @notice Calculate tokens required for USDC output (selling tokens for exact USDC)
     * @dev Uses constant product formula: Δy = (y × Δx) / (x - Δx)
     *
     * When selling tokens to get exact USDC amount:
     * - USDC flows OUT of reserves (x decreases by Δx)
     * - Tokens flow INTO reserves (y increases by Δy)
     * - K = x × y = (x - Δx) × (y + Δy)
     * - Solving for Δy: Δy = (y × Δx) / (x - Δx)
     *
     * @param reserves Current reserve state
     * @param usdcOut Amount of USDC to receive (USDC decimals)
     * @return tokensIn Amount of tokens required (token decimals)
     */
    function getTokensIn(
        Reserves memory reserves,
        uint256 usdcOut
    ) internal pure returns (uint256 tokensIn) {
        if (usdcOut == 0) return 0;
        if (usdcOut >= reserves.x) revert InsufficientLiquidity();

        // Δy = (y × Δx) / (x - Δx)
        // Rearranged from K = (x - Δx)(y + Δy)
        // Add 1 to round up, ensuring K never decreases (same as Uniswap V2)
        tokensIn = (reserves.y * usdcOut) / (reserves.x - usdcOut) + 1;
    }

    /**
     * @notice Get current price (USDC per token)
     * @dev Price = x / y (ratio of reserves)
     *
     * Formula explanation:
     * - x is in USDC decimals (e.g., 6)
     * - y is in token decimals (e.g., 18)
     * - We want price in USDC decimals
     *
     * Price (in real units) = (x / usdcUnit) / (y / tokenUnit)
     *                       = (x × tokenUnit) / (y × usdcUnit)
     *
     * To avoid loss of precision, we compute:
     * Price (in USDC decimals) = x × (10^decimalsDiff) / y
     *                          where decimalsDiff = tokenDecimals - usdcDecimals
     *
     * @param reserves Current reserve state
     * @param config Decimal configuration
     * @return price Current price (USDC decimals)
     */
    function getCurrentPrice(
        Reserves memory reserves,
        DecimalConfig memory config
    ) internal pure returns (uint256 price) {
        if (reserves.y == 0) revert InsufficientLiquidity();

        // Price = x / y in real units
        // x is in USDC decimals (e.g., 6)
        // y is in token decimals (e.g., 18)
        // We want price in USDC decimals (e.g., 6)
        //
        // Real price = (x / 10^usdcDecimals) / (y / 10^tokenDecimals)
        //            = (x × 10^tokenDecimals) / (y × 10^usdcDecimals)
        //            = (x × tokenUnit) / (y × usdcUnit)
        //
        // To express in USDC decimals:
        // Price (in USDC decimals) = [(x × tokenUnit) / (y × usdcUnit)] × usdcUnit
        //                          = (x × tokenUnit) / y
        //
        // Use rounding to minimize precision loss: (a + b/2) / b rounds to nearest integer
        price = (reserves.x * config.tokenUnit + reserves.y / 2) / reserves.y;
    }

    /**
     * @notice Update reserves after a swap
     * @dev Modifies reserves in place - MUST use storage reference!
     *
     * @param reserves Reserve state to update (storage reference)
     * @param usdcDelta Change in USDC reserve (signed)
     * @param tokenDelta Change in token reserve (signed)
     */
    function updateReserves(
        Reserves storage reserves,
        int256 usdcDelta,
        int256 tokenDelta
    ) internal {
        if (usdcDelta > 0) {
            reserves.x += uint256(usdcDelta);
        } else if (usdcDelta < 0) {
            reserves.x -= uint256(-usdcDelta);
        }

        if (tokenDelta > 0) {
            reserves.y += uint256(tokenDelta);
        } else if (tokenDelta < 0) {
            reserves.y -= uint256(-tokenDelta);
        }
    }


    /**
     * @notice Calculate total token supply using geometric mean strategy
     * @dev S_total = 100 × R_target × √(α / (1-α)³)
     *
     * From design document section 2.4:
     * - Uses geometric mean between S_min and S_max
     * - Ensures balanced LP/Funding allocation
     * - α range: (0, 0.5] (0% to 50%, exclusive of 0)
     *
     * Implementation uses PRBMath UD60x18 for precise fixed-point arithmetic:
     * - Automatically manages 18-decimal precision
     * - Eliminates manual PRECISION scaling
     * - Reduces risk of precision errors
     *
     * @param rTarget Funding goal in USDC decimals (e.g., 50,000e6)
     * @param alpha Project ownership ratio in basis points (e.g., 2000 = 20%)
     * @param alphaDenominator Denominator for alpha (e.g., 10000 for basis points)
     * @param config Decimal configuration
     * @return sTotalSupply Total token supply (token decimals)
     * @return sSale Tokens for public sale (token decimals)
     * @return sLP Tokens for LP pairing (token decimals)
     */
    function calculateTotalSupply(
        uint256 rTarget,
        uint256 alpha,
        uint256 alphaDenominator,
        DecimalConfig memory config
    ) internal pure returns (uint256 sTotalSupply, uint256 sSale, uint256 sLP) {
        if (rTarget == 0) revert InvalidRTarget();
        if (alpha == 0 || alpha >= alphaDenominator) revert InvalidAlpha();

        // Validate alpha range: 0 < α <= 0.5 (0 < alpha <= 5000 for basis points)
        // Mathematical constraint: α must be positive and less than 1 to avoid division by zero
        // Economic constraint: α <= 0.5 to prevent excessive project ownership (>50%)
        uint256 maxAlpha = alphaDenominator / 2; // 50% = 5000 basis points
        if (alpha > maxAlpha) revert InvalidAlpha();

        // Calculate (1 - α)
        uint256 oneMinusAlpha = alphaDenominator - alpha;

        // Calculate α/(1-α)³ using PRBMath UD60x18
        // Convert alpha and oneMinusAlpha to UD60x18 (18-decimal fixed-point)
        UD60x18 alphaUD = convert(alpha);
        UD60x18 oneMinusAlphaUD = convert(oneMinusAlpha);
        UD60x18 alphaDenomUD = convert(alphaDenominator);

        // α_ratio = alpha / alphaDenominator (in UD60x18)
        UD60x18 alphaRatio = alphaUD.div(alphaDenomUD);

        // (1-α)_ratio = oneMinusAlpha / alphaDenominator
        UD60x18 oneMinusAlphaRatio = oneMinusAlphaUD.div(alphaDenomUD);

        // (1-α)³ = (1-α) × (1-α) × (1-α)
        UD60x18 oneMinusAlphaCubed = oneMinusAlphaRatio
            .mul(oneMinusAlphaRatio)
            .mul(oneMinusAlphaRatio);

        // α/(1-α)³
        UD60x18 ratio = alphaRatio.div(oneMinusAlphaCubed);

        // √(α/(1-α)³)
        UD60x18 sqrtRatioUD = ratio.sqrt();

        // S_total = 100 × R_target × √(α / (1-α)³)
        //
        // R_target is in USDC decimals (e.g., 50,000e6)
        // sqrtRatioUD is a UD60x18 number (already scaled by 1e18 internally)
        // When we use convert() to get back uint256, it divides by 1e18
        // So sqrtRatio is actually the real decimal value (e.g., 0.625 represented as plain uint)
        //
        // We need to recalculate using UD60x18 throughout to avoid precision loss
        //
        // Formula (from design doc section 2.4):
        // S_total = 100 × R_target × √(α / (1-α)³)

        // Convert R_target from USDC decimals to real value using UD60x18
        // R_target_real = R_target / usdcUnit
        // But we want to keep precision, so we work directly with the raw values

        // S_total (in token decimals) = 100 × (R_target / usdcUnit) × sqrtRatioUD × tokenUnit
        //                              = (100 × R_target × sqrtRatioUD × tokenUnit) / usdcUnit
        //
        // sqrtRatioUD is UD60x18, so we need to multiply and then unwrap properly
        UD60x18 hundred = convert(100);
        UD60x18 rTargetUD = convert(rTarget);
        UD60x18 usdcUnitUD = convert(config.usdcUnit);

        // result_UD = 100 × (R_target / usdcUnit) × sqrtRatioUD
        UD60x18 resultUD = hundred.mul(rTargetUD).mul(sqrtRatioUD).div(
            usdcUnitUD
        );

        // Convert back to uint256 (this divides by 1e18)
        // The result is in base units (e.g., actual token count like 3125000)
        // We need to multiply by tokenUnit to get token decimals
        uint256 resultBaseUnits = convert(resultUD);
        sTotalSupply = resultBaseUnits * config.tokenUnit;

        // S_sale = (1 - α) × S_total
        sSale = (sTotalSupply * oneMinusAlpha) / alphaDenominator;

        // S_LP = α × S_total
        sLP = (sTotalSupply * alpha) / alphaDenominator;
    }
}

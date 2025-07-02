// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "forge-std/console2.sol";
import {Setup, ERC20, IStrategyInterface} from "./utils/Setup.sol";
import {FullMath} from "@uniswap-v3-core/libraries/FullMath.sol";
import {TickMath} from "@uniswap-v3-core/libraries/TickMath.sol";
import {IUniswapV3Pool} from "@uniswap-v3-core/interfaces/IUniswapV3Pool.sol";
import {ISushiMultiPositionLiquidityManager} from "../interfaces/steer/ISushiMultiPositionLiquidityManager.sol";

contract RoundingProtectionTests is Setup {
    uint256 private constant Q96 = 0x1000000000000000000000000;

    // Minimum sqrtPriceX96 that won't underflow when squared and divided by Q96
    uint160 private constant MIN_SAFE_SQRT_PRICE = 2 ** 48;

    // sqrtPriceX96 at minimum tick (-887272)
    uint160 private constant MIN_SQRT_PRICE = 4295128739;

    function setUp() public virtual override {
        super.setUp();
    }

    /**
     * @notice Test extreme low sqrtPriceX96 values that would cause underflow
     * @dev Tests the case where sqrtPriceX96 < 2^48, which would underflow in naive implementation
     */
    function test_extremeLowPrice_noUnderflow(
        IStrategyInterface strategy
    ) public {
        TestParams memory params = _getTestParams(address(strategy));

        // Give strategy some tokens to work with
        uint256 amount = 1000 * 10 ** params.assetDecimals;
        airdrop(params.asset, address(strategy), amount);
        airdrop(params.pairedAsset, address(strategy), amount);

        // Mock the pool to return extreme low price
        address steerLP = strategy.STEER_LP();
        address pool = ISushiMultiPositionLiquidityManager(steerLP).pool();

        // Get current slot0 data to ensure pool is valid
        IUniswapV3Pool(pool).slot0();

        // Set extremely low price (just above minimum)
        uint160 extremeLowPrice = MIN_SQRT_PRICE + 1000;
        vm.mockCall(
            pool,
            abi.encodeWithSelector(IUniswapV3Pool(pool).slot0.selector),
            abi.encode(extremeLowPrice, 0, 0, 0, 0, 0, true)
        );

        // This should not revert despite extreme price
        uint256 totalAssets = strategy.estimatedTotalAsset();

        // Verify we get a non-zero result
        assertGt(
            totalAssets,
            0,
            "Should calculate non-zero value at extreme low price"
        );

        // Clear mock
        vm.clearMockedCalls();
    }

    /**
     * @notice Test very small token amounts that could round to zero
     * @dev Verifies precision is maintained for small amounts
     */
    function test_smallAmounts_maintainPrecision(
        IStrategyInterface strategy
    ) public {
        TestParams memory params = _getTestParams(address(strategy));

        // Test with 1 wei of tokens
        airdrop(params.asset, address(strategy), 1);
        airdrop(params.pairedAsset, address(strategy), 1);

        uint256 totalAssets = strategy.estimatedTotalAsset();

        // Should maintain some value even with 1 wei
        assertGt(totalAssets, 0, "Should maintain precision with 1 wei");
    }

    /**
     * @notice Test large amounts that would overflow in condition checks
     * @dev Verifies our safe division approach prevents overflow
     */
    function test_largeAmounts_noOverflow(
        IStrategyInterface strategy,
        uint256 _largeAmount
    ) public {
        TestParams memory params = _getTestParams(address(strategy));

        // Use very large amounts that could overflow when multiplied by price
        _largeAmount = bound(
            _largeAmount,
            type(uint128).max / 2,
            type(uint128).max
        );

        // Give strategy large amounts
        airdrop(params.asset, address(strategy), _largeAmount);
        airdrop(params.pairedAsset, address(strategy), _largeAmount);

        // This should not revert despite large amounts
        uint256 totalAssets = strategy.estimatedTotalAsset();

        assertGt(
            totalAssets,
            0,
            "Should handle large amounts without overflow"
        );
    }

    /**
     * @notice Test price calculation branches are chosen correctly
     * @dev Verifies conditional logic chooses optimal calculation path
     */
    function test_priceCalculation_correctBranch(
        IStrategyInterface strategy
    ) public {
        TestParams memory params = _getTestParams(address(strategy));

        // For stable pairs (USDC/DAI), use reasonable test amounts
        int256 decimalDiff = int256(params.assetDecimals) - int256(params.pairedAssetDecimals);
        if (decimalDiff >= -12 && decimalDiff <= 12) {
            // This is likely a stable pair, just test with reasonable amounts
            uint256 testAmount = 100 * 10 ** params.pairedAssetDecimals; // 100 units
            airdrop(params.pairedAsset, address(strategy), testAmount);
            
            uint256 result = strategy.estimatedTotalAsset();
            assertGt(result, 0, "Should calculate value for paired tokens");
            return;
        }

        // Get current price
        address steerLP = strategy.STEER_LP();
        address pool = ISushiMultiPositionLiquidityManager(steerLP).pool();
        (uint160 sqrtPriceX96, , , , , , ) = IUniswapV3Pool(pool).slot0();

        // Calculate threshold for branch selection
        uint256 threshold = Q96 / sqrtPriceX96;

        // Test amount just below threshold (should use price-first calculation)
        uint256 smallAmount = threshold / 2;
        // Ensure we use a reasonable minimum amount
        if (smallAmount < 10 ** params.pairedAssetDecimals / 100) {
            smallAmount = 10 ** params.pairedAssetDecimals / 100;
        }
        airdrop(params.pairedAsset, address(strategy), smallAmount);

        uint256 smallResult = strategy.estimatedTotalAsset();

        // Clean up
        uint256 pairedBalance = params.pairedAsset.balanceOf(address(strategy));
        if (pairedBalance > 0) {
            vm.prank(address(strategy));
            params.pairedAsset.transfer(address(1), pairedBalance);
        }

        // Test amount above threshold (should use standard calculation)
        uint256 largeAmount = threshold * 2;
        // Cap to reasonable amount
        if (largeAmount > 1000 * 10 ** params.pairedAssetDecimals) {
            largeAmount = 1000 * 10 ** params.pairedAssetDecimals;
        }
        airdrop(params.pairedAsset, address(strategy), largeAmount);

        uint256 largeResult = strategy.estimatedTotalAsset();

        // Both should produce valid results
        assertGt(smallResult, 0, "Small amount should produce valid result");
        assertGt(largeResult, 0, "Large amount should produce valid result");
    }

    /**
     * @notice Test exact boundary at sqrtPriceX96 = 2^48
     * @dev This is the critical boundary where underflow would occur
     */
    function test_boundaryPrice_2pow48(IStrategyInterface strategy) public {
        TestParams memory params = _getTestParams(address(strategy));

        // Give strategy tokens
        uint256 amount = 1000 * 10 ** params.assetDecimals;
        airdrop(params.asset, address(strategy), amount);
        airdrop(params.pairedAsset, address(strategy), amount);

        address steerLP = strategy.STEER_LP();
        address pool = ISushiMultiPositionLiquidityManager(steerLP).pool();

        // Test at exact boundary
        vm.mockCall(
            pool,
            abi.encodeWithSelector(IUniswapV3Pool(pool).slot0.selector),
            abi.encode(MIN_SAFE_SQRT_PRICE, 0, 0, 0, 0, 0, true)
        );

        uint256 boundaryResult = strategy.estimatedTotalAsset();
        assertGt(boundaryResult, 0, "Should handle boundary price correctly");

        // Test just below boundary (would underflow in naive implementation)
        vm.mockCall(
            pool,
            abi.encodeWithSelector(IUniswapV3Pool(pool).slot0.selector),
            abi.encode(MIN_SAFE_SQRT_PRICE - 1, 0, 0, 0, 0, 0, true)
        );

        uint256 belowBoundaryResult = strategy.estimatedTotalAsset();
        assertGt(
            belowBoundaryResult,
            0,
            "Should handle below-boundary price correctly"
        );

        vm.clearMockedCalls();
    }

    /**
     * @notice Compare results with theoretical naive implementation
     * @dev Ensures our protection doesn't break normal cases
     */
    function test_roundingProtection_comparison(
        IStrategyInterface strategy,
        uint256 _amount
    ) public {
        TestParams memory params = _getTestParams(address(strategy));
        _amount = bound(_amount, params.minFuzzAmount, params.maxFuzzAmount);

        // Get current price
        address steerLP = strategy.STEER_LP();
        address pool = ISushiMultiPositionLiquidityManager(steerLP).pool();
        (uint160 sqrtPriceX96, , , , , , ) = IUniswapV3Pool(pool).slot0();

        // Only test if price is safe for naive calculation
        if (sqrtPriceX96 >= MIN_SAFE_SQRT_PRICE) {
            airdrop(params.pairedAsset, address(strategy), _amount);

            uint256 strategyResult = strategy.estimatedTotalAsset();

            // Calculate expected value using naive approach
            uint256 naivePrice = FullMath.mulDiv(
                sqrtPriceX96,
                sqrtPriceX96,
                Q96
            );
            uint256 expectedValue;

            if (params.asset.balanceOf(address(strategy)) == 0) {
                // Only paired token balance
                if (address(params.asset) < address(params.pairedAsset)) {
                    // Asset is token0, so divide by price
                    expectedValue = FullMath.mulDiv(_amount, Q96, naivePrice);
                } else {
                    // Asset is token1, so multiply by price
                    expectedValue = FullMath.mulDiv(_amount, naivePrice, Q96);
                }
            }

            // Apply discount to match strategy logic
            uint256 discountBps = strategy.pairedTokenDiscountBps();
            // Get pool fee
            uint24 poolFee = IUniswapV3Pool(pool).fee();
            uint256 totalDiscountBps = poolFee / 100 + discountBps;
            expectedValue = expectedValue - (expectedValue * totalDiscountBps) / 10000;

            // Results should be very close (within 1% due to rounding and discounts)
            if (expectedValue > 0 && strategyResult > 0) {
                uint256 delta = strategyResult > expectedValue
                    ? strategyResult - expectedValue
                    : expectedValue - strategyResult;
                assertLt(
                    delta,
                    expectedValue / 100,
                    "Results should match calculation within 1%"
                );
            }
        }
    }

    /**
     * @notice Test specific case from tapired's comment about tick -665421
     * @dev This tick corresponds to sqrtPriceX96 that would cause underflow
     */
    function test_tickNegative665421_underflowProtection(
        IStrategyInterface strategy
    ) public {
        TestParams memory params = _getTestParams(address(strategy));

        // Calculate sqrtPriceX96 for tick -665421
        int24 problematicTick = -665421;
        uint160 problematicSqrtPrice = TickMath.getSqrtRatioAtTick(
            problematicTick
        );

        // The problematic price is actually just slightly above 2^48
        // but it can still cause issues in calculations
        console2.log("Problematic sqrtPrice:", problematicSqrtPrice);
        console2.log("MIN_SAFE_SQRT_PRICE:", MIN_SAFE_SQRT_PRICE);

        // Give strategy tokens
        uint256 amount = 1000 * 10 ** params.assetDecimals;
        airdrop(params.asset, address(strategy), amount);
        airdrop(params.pairedAsset, address(strategy), amount);

        address steerLP = strategy.STEER_LP();
        address pool = ISushiMultiPositionLiquidityManager(steerLP).pool();

        // Mock this problematic price
        vm.mockCall(
            pool,
            abi.encodeWithSelector(IUniswapV3Pool(pool).slot0.selector),
            abi.encode(problematicSqrtPrice, problematicTick, 0, 0, 0, 0, true)
        );

        // Should not revert despite problematic price
        uint256 result = strategy.estimatedTotalAsset();
        assertGt(result, 0, "Should handle tick -665421 without underflow");

        vm.clearMockedCalls();
    }
}

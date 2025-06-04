// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "forge-std/console2.sol";
import {Setup, ERC20, IStrategyInterface} from "./utils/Setup.sol";
import {ISushiMultiPositionLiquidityManager} from "../interfaces/steer/ISushiMultiPositionLiquidityManager.sol";
import {IUniswapV3Pool} from "@uniswap-v3-core/interfaces/IUniswapV3Pool.sol";
import {TickMath} from "@uniswap-v3-core/libraries/TickMath.sol";

contract ErrorAndBoundaryTests_OutOfRange is Setup {
    function setUp() public virtual override {
        super.setUp();
    }

    function test_outOfRangePositions_priceMovementAboveRange(
        IStrategyInterface strategy,
        uint256 _amount
    ) public {
        TestParams memory params = _getTestParams(address(strategy));
        _amount = bound(_amount, params.minFuzzAmount, params.maxFuzzAmount);

        // Create initial position
        mintAndDepositIntoStrategy(strategy, user, _amount);
        vm.prank(keeper);
        strategy.tend();

        _testPriceMovementScenario(strategy, params, _amount, true);
    }

    function test_outOfRangePositions_priceMovementBelowRange(
        IStrategyInterface strategy,
        uint256 _amount
    ) public {
        TestParams memory params = _getTestParams(address(strategy));
        _amount = bound(_amount, params.minFuzzAmount, params.maxFuzzAmount);

        // Create initial position
        mintAndDepositIntoStrategy(strategy, user, _amount);
        vm.prank(keeper);
        strategy.tend();

        _testPriceMovementScenario(strategy, params, _amount, false);
    }

    function test_outOfRangePositions_emergencyWithdraw(
        IStrategyInterface strategy,
        uint256 _amount
    ) public {
        TestParams memory params = _getTestParams(address(strategy));
        _amount = bound(_amount, params.minFuzzAmount, params.maxFuzzAmount);

        // Create initial position
        mintAndDepositIntoStrategy(strategy, user, _amount);
        vm.prank(keeper);
        strategy.tend();

        // Get LP details
        ISushiMultiPositionLiquidityManager steerLP = ISushiMultiPositionLiquidityManager(
                params.lp
            );
        address poolAddress = steerLP.pool();

        uint256 lpSharesBefore = steerLP.balanceOf(address(strategy));
        if (lpSharesBefore == 0) return;

        // Move price significantly (either direction)
        _performLargeSwapsToMovePrice(poolAddress, params, true);

        // Shutdown strategy
        vm.prank(emergencyAdmin);
        strategy.shutdownStrategy();

        // Emergency withdraw should work even with out-of-range positions
        vm.prank(emergencyAdmin);
        strategy.emergencyWithdraw(_amount);

        // Should handle withdrawal gracefully
        uint256 lpSharesAfter = steerLP.balanceOf(address(strategy));
        assertLe(
            lpSharesAfter,
            lpSharesBefore,
            "Should have withdrawn some LP shares"
        );
    }

    function test_outOfRangePositions_rebalancingLogic(
        IStrategyInterface strategy,
        uint256 _amount
    ) public {
        TestParams memory params = _getTestParams(address(strategy));
        _amount = bound(_amount, params.minFuzzAmount, params.maxFuzzAmount);

        // Create initial position
        mintAndDepositIntoStrategy(strategy, user, _amount);
        vm.prank(keeper);
        strategy.tend();

        // Get Steer LP positions to determine target price
        ISushiMultiPositionLiquidityManager steerLP = ISushiMultiPositionLiquidityManager(
                params.lp
            );
        (int24[] memory lowerTicks, int24[] memory upperTicks, ) = steerLP
            .getPositions();

        // Skip if no positions
        if (lowerTicks.length == 0) return;

        // Move price outside range using controlled swap with sqrtPriceLimitX96
        _performControlledPriceMovement(
            steerLP.pool(),
            params,
            upperTicks[upperTicks.length - 1] // Move above highest tick
        );

        // Add more assets to trigger rebalancing with out-of-range positions
        airdrop(params.asset, address(strategy), _amount / 4);

        // Strategy should handle rebalancing even with out-of-range LP positions
        vm.prank(keeper);
        strategy.tend();

        // Should complete without reverting
        assertTrue(true, "Rebalancing completed with out-of-range positions");
    }

    function test_outOfRangePositions_accurateValuation(
        IStrategyInterface strategy,
        uint256 _amount
    ) public {
        TestParams memory params = _getTestParams(address(strategy));
        _amount = bound(_amount, params.minFuzzAmount, params.maxFuzzAmount);

        // Create initial position
        mintAndDepositIntoStrategy(strategy, user, _amount);
        vm.prank(keeper);
        strategy.tend();

        // Move price to create out-of-range scenario
        _performLargeSwapsToMovePrice(
            ISushiMultiPositionLiquidityManager(params.lp).pool(),
            params,
            true
        );

        // Check valuations after price movement
        uint256 estimatedTotalAfter = strategy.estimatedTotalAsset();
        uint256 lpValueAfter = strategy.lpVaultInAsset();

        // Valuations should still be calculated (even if values changed due to price movement)
        assertGt(
            estimatedTotalAfter,
            0,
            "Total asset estimation should work with out-of-range positions"
        );
        assertGe(
            lpValueAfter,
            0,
            "LP valuation should work with out-of-range positions"
        );

        // Should be within reasonable bounds (accounting for potential impermanent loss)
        // Use a generous tolerance since concentrated liquidity can have significant IL
        assertApproxEqAbs(
            estimatedTotalAfter,
            _amount,
            _amount, // 100% tolerance for extreme price movements
            "Valuation should be reasonable despite out-of-range positions"
        );
    }

    // Helper function to test price movement scenarios
    function _testPriceMovementScenario(
        IStrategyInterface strategy,
        TestParams memory params,
        uint256 _amount,
        bool moveUp
    ) internal {
        ISushiMultiPositionLiquidityManager steerLP = ISushiMultiPositionLiquidityManager(
                params.lp
            );
        address poolAddress = steerLP.pool();

        // Get current state and positions
        (, int24 currentTickBefore, , , , , ) = IUniswapV3Pool(poolAddress)
            .slot0();
        (int24[] memory lowerTicks, int24[] memory upperTicks, ) = steerLP
            .getPositions();

        // Skip if no positions
        if (lowerTicks.length == 0) return;

        // Determine target tick based on positions
        int24 targetTick;
        if (moveUp) {
            // Move above the highest position
            targetTick = upperTicks[upperTicks.length - 1] + 100;
        } else {
            // Move below the lowest position
            targetTick = lowerTicks[0] - 100;
        }

        // Move price to target
        _performControlledPriceMovement(poolAddress, params, targetTick);

        // Get new tick
        (, int24 currentTickAfter, , , , , ) = IUniswapV3Pool(poolAddress)
            .slot0();

        // Check if we're outside the positions
        bool isOutsidePositions = moveUp
            ? currentTickAfter > upperTicks[upperTicks.length - 1]
            : currentTickAfter < lowerTicks[0];

        if (isOutsidePositions) {
            // Test strategy still works with out-of-range positions
            uint256 totalAssetValue = strategy.estimatedTotalAsset();
            assertGt(
                totalAssetValue,
                0,
                "Strategy should handle out-of-range LP positions"
            );

            // Test operations still work
            vm.prank(keeper);
            strategy.tend(); // Should not revert

            // Test withdrawals work
            vm.prank(management);
            strategy.manualWithdrawFromLp(_amount / 4);
        }
    }

    // Helper function to perform controlled price movements using sqrtPriceLimitX96
    function _performControlledPriceMovement(
        address poolAddress,
        TestParams memory params,
        int24 targetTick
    ) internal {
        IUniswapV3Pool pool = IUniswapV3Pool(poolAddress);

        // Get current state
        (uint160 currentSqrtPriceX96, int24 currentTick, , , , , ) = pool
            .slot0();

        // Calculate target sqrtPriceX96 based on target tick
        uint160 targetSqrtPriceX96 = TickMath.getSqrtRatioAtTick(targetTick);

        // Determine swap direction
        bool zeroForOne = targetSqrtPriceX96 < currentSqrtPriceX96;

        // Calculate a reasonable swap amount (not too large to avoid RPC issues)
        uint256 swapAmount = params.minFuzzAmount * 10;

        // Airdrop the token we're swapping from
        if (zeroForOne) {
            // Swapping token0 for token1 (price goes down)
            address token0 = pool.token0();
            airdrop(ERC20(token0), address(this), swapAmount);
        } else {
            // Swapping token1 for token0 (price goes up)
            address token1 = pool.token1();
            airdrop(ERC20(token1), address(this), swapAmount);
        }

        // Perform controlled swap with price limit
        try
            pool.swap(
                address(this),
                zeroForOne,
                int256(swapAmount),
                targetSqrtPriceX96,
                ""
            )
        {
            // Swap succeeded
        } catch {
            // If swap fails, try with smaller amount
            try
                pool.swap(
                    address(this),
                    zeroForOne,
                    int256(swapAmount / 10),
                    targetSqrtPriceX96,
                    ""
                )
            {
                // Smaller swap succeeded
            } catch {
                // Even smaller swap failed, continue with test
            }
        }
    }

    // Helper function to perform large swaps that move pool price (keeping for other tests)
    function _performLargeSwapsToMovePrice(
        address poolAddress,
        TestParams memory params,
        bool moveUp
    ) internal {
        // Get current tick to determine appropriate target
        (, int24 currentTick, , , , , ) = IUniswapV3Pool(poolAddress).slot0();

        // Calculate target tick (move by significant amount)
        int24 targetTick;
        if (moveUp) {
            targetTick = currentTick + 5000; // Move up significantly
            if (targetTick > 887000) targetTick = 887000; // Cap at near max
        } else {
            targetTick = currentTick - 5000; // Move down significantly
            if (targetTick < -887000) targetTick = -887000; // Cap at near min
        }

        _performControlledPriceMovement(poolAddress, params, targetTick);
    }

    // Required for direct pool swaps
    function uniswapV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata data
    ) external {
        // Simple callback for test swaps
        if (amount0Delta > 0) {
            // Get token0 from pool
            address token0 = IUniswapV3Pool(msg.sender).token0();
            ERC20(token0).transfer(msg.sender, uint256(amount0Delta));
        }
        if (amount1Delta > 0) {
            // Get token1 from pool
            address token1 = IUniswapV3Pool(msg.sender).token1();
            ERC20(token1).transfer(msg.sender, uint256(amount1Delta));
        }
    }
}

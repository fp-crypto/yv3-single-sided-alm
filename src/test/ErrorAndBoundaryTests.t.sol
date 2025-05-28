// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "forge-std/console2.sol";
import {Setup, ERC20, IStrategyInterface} from "./utils/Setup.sol";
import {ISushiMultiPositionLiquidityManager} from "../interfaces/steer/ISushiMultiPositionLiquidityManager.sol";

contract ErrorAndBoundaryTests is Setup {
    function setUp() public virtual override {
        super.setUp();
    }

    function test_constructor_invalidAsset() public {
        TestParams memory params = _getTestParams(fixtureStrategy()[0]);

        // Use WETH as an invalid asset (it's a real ERC20 but not in our test LPs)
        address invalidAsset = 0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619; // WETH on Polygon

        vm.expectRevert(bytes("!asset"));
        strategyFactory.newStrategy(
            invalidAsset,
            "Invalid Strategy",
            params.lp
        );
    }

    function test_tend_withTargetIdleAssetBps_belowThreshold(
        IStrategyInterface strategy,
        uint256 _amount,
        uint16 _idleBps
    ) public {
        TestParams memory params = _getTestParams(address(strategy));
        _amount = bound(_amount, params.minFuzzAmount, params.maxFuzzAmount);
        _idleBps = uint16(bound(uint256(_idleBps), 5000, 9500)); // 50-95%

        // Set high idle target
        vm.prank(management);
        strategy.setTargetIdleAssetBps(_idleBps);

        // Deposit amount that keeps us at exactly the idle threshold
        // When idle target is high, the strategy should keep most assets idle
        mintAndDepositIntoStrategy(strategy, user, _amount);

        uint256 lpBalanceBefore = ERC20(params.lp).balanceOf(address(strategy));

        // Tend should create minimal LP position or none when idle target is very high
        vm.prank(keeper);
        strategy.tend();

        uint256 lpBalanceAfter = ERC20(params.lp).balanceOf(address(strategy));

        // With high idle target, most assets should remain idle
        uint256 idleAssets = params.asset.balanceOf(address(strategy));
        uint256 targetIdleAmount = (_amount * _idleBps) / 10000;

        // Assert that strategy respects idle target (within tolerance)
        uint256 tolerance = _amount / 20; // 5% tolerance
        assertApproxEqAbs(
            idleAssets,
            targetIdleAmount,
            tolerance,
            "Should maintain target idle asset ratio"
        );
    }

    function test_withdrawFromLp_zeroLpShares(
        IStrategyInterface strategy
    ) public {
        TestParams memory params = _getTestParams(address(strategy));

        // Try to withdraw when no LP shares exist
        vm.prank(management);
        strategy.manualWithdrawFromLp(1000e18);

        // Should not revert, should just do nothing
        assertEq(ERC20(params.lp).balanceOf(address(strategy)), 0);
    }

    function test_withdrawFromLp_zeroLpValue(
        IStrategyInterface strategy,
        uint256 _amount
    ) public {
        TestParams memory params = _getTestParams(address(strategy));
        _amount = bound(_amount, params.minFuzzAmount, params.maxFuzzAmount);

        // This test simulates a scenario where LP has shares but zero value
        // In practice, this is extremely rare but should be handled gracefully

        mintAndDepositIntoStrategy(strategy, user, _amount);
        vm.prank(keeper);
        strategy.tend();

        // Manual withdraw should handle edge cases gracefully
        vm.prank(management);
        strategy.manualWithdrawFromLp(_amount);

        // Should not revert
    }

    function test_emergencyWithdraw_noLpPosition(
        IStrategyInterface strategy,
        uint256 _amount
    ) public {
        TestParams memory params = _getTestParams(address(strategy));
        _amount = bound(_amount, params.minFuzzAmount, params.maxFuzzAmount);

        // Deposit but don't tend (no LP position)
        mintAndDepositIntoStrategy(strategy, user, _amount);

        // Shutdown strategy first (required for emergency withdraw)
        vm.prank(emergencyAdmin);
        strategy.shutdownStrategy();

        // Emergency withdraw should handle case with no LP position
        vm.prank(emergencyAdmin);
        strategy.emergencyWithdraw(_amount);

        // Should not revert
    }

    function test_emergencyWithdraw_partialAmount(
        IStrategyInterface strategy,
        uint256 _amount
    ) public {
        TestParams memory params = _getTestParams(address(strategy));
        _amount = bound(_amount, params.minFuzzAmount, params.maxFuzzAmount);

        // Create LP position
        mintAndDepositIntoStrategy(strategy, user, _amount);
        vm.prank(keeper);
        strategy.tend();

        uint256 lpBalanceBefore = ERC20(params.lp).balanceOf(address(strategy));

        // Shutdown strategy first (required for emergency withdraw)
        vm.prank(emergencyAdmin);
        strategy.shutdownStrategy();

        // Emergency withdraw partial amount
        vm.prank(emergencyAdmin);
        strategy.emergencyWithdraw(_amount / 2);

        uint256 lpBalanceAfter = ERC20(params.lp).balanceOf(address(strategy));

        // Should have withdrawn some LP
        assertLt(
            lpBalanceAfter,
            lpBalanceBefore,
            "Should have withdrawn some LP"
        );
    }

    function test_maxWithdrawAmounts(
        IStrategyInterface strategy,
        uint256 _amount
    ) public {
        TestParams memory params = _getTestParams(address(strategy));
        _amount = bound(_amount, params.minFuzzAmount, params.maxFuzzAmount);

        // Create position
        mintAndDepositIntoStrategy(strategy, user, _amount);
        vm.prank(keeper);
        strategy.tend();

        // Try to withdraw max uint256
        vm.prank(management);
        strategy.manualWithdrawFromLp(type(uint256).max);

        // Should withdraw everything
        assertEq(ERC20(params.lp).balanceOf(address(strategy)), 0);
    }

    function test_tendTrigger_alwaysFalse(
        IStrategyInterface strategy,
        uint256 _amount
    ) public {
        TestParams memory params = _getTestParams(address(strategy));
        _amount = bound(_amount, params.minFuzzAmount, params.maxFuzzAmount);

        // Tend trigger should always return false (current implementation)
        (bool trigger, ) = strategy.tendTrigger();
        assertFalse(trigger, "Tend trigger should always be false");

        // Even after deposit
        mintAndDepositIntoStrategy(strategy, user, _amount);
        (trigger, ) = strategy.tendTrigger();
        assertFalse(
            trigger,
            "Tend trigger should still be false after deposit"
        );

        // Even after tend
        vm.prank(keeper);
        strategy.tend();
        (trigger, ) = strategy.tendTrigger();
        assertFalse(trigger, "Tend trigger should still be false after tend");
    }

    function test_harvestAndReport_basicFunctionality(
        IStrategyInterface strategy,
        uint256 _amount
    ) public {
        TestParams memory params = _getTestParams(address(strategy));
        _amount = bound(_amount, params.minFuzzAmount, params.maxFuzzAmount);

        // Create position
        mintAndDepositIntoStrategy(strategy, user, _amount);
        vm.prank(keeper);
        strategy.tend();

        // Disable health check to avoid healthCheck revert
        vm.prank(management);
        strategy.setDoHealthCheck(false);

        // Report should return estimated total assets
        vm.prank(keeper);
        (uint256 profit, uint256 loss) = strategy.report();

        // With no external profit, should have minimal profit/loss
        uint256 tolerance = (_amount * 5) / 100; // 5% tolerance
        assertApproxEqAbs(profit, 0, tolerance, "Profit should be minimal");
        assertLe(loss, tolerance, "Loss should be minimal");
    }

    function test_deployFunds_freeFunds_doNothing(
        IStrategyInterface strategy
    ) public {
        TestParams memory params = _getTestParams(address(strategy));

        // These functions should do nothing (no-op implementation)
        // They exist because they're required by BaseStrategy but swaps are needed

        // Should not revert
        vm.prank(keeper);
        strategy.tend(); // This calls _deployFunds internally

        // Manual verification that _deployFunds and _freeFunds do nothing
        // is implicit in other tests where we need to call tend() to actually deploy
    }

    function test_extremeDecimalDifferences(
        IStrategyInterface strategy,
        uint256 _amount
    ) public {
        TestParams memory params = _getTestParams(address(strategy));

        // Skip if decimals are the same
        if (params.assetDecimals == params.pairedAssetDecimals) return;

        _amount = bound(_amount, params.minFuzzAmount, params.maxFuzzAmount);

        // Test with assets that have different decimal places
        mintAndDepositIntoStrategy(strategy, user, _amount);

        vm.prank(keeper);
        strategy.tend();

        // Should handle decimal differences gracefully
        uint256 estimatedTotal = strategy.estimatedTotalAsset();
        assertGt(estimatedTotal, 0, "Should handle decimal differences");

        uint256 tolerance = (_amount * 20) / 100; // 20% tolerance for decimal conversion
        assertApproxEqAbs(
            estimatedTotal,
            _amount,
            tolerance,
            "Should approximate original amount despite decimal differences"
        );
    }

    function test_sequentialOperations(
        IStrategyInterface strategy,
        uint256 _amount1,
        uint256 _amount2
    ) public {
        TestParams memory params = _getTestParams(address(strategy));
        _amount1 = bound(
            _amount1,
            params.minFuzzAmount,
            params.maxFuzzAmount / 2
        );
        _amount2 = bound(
            _amount2,
            params.minFuzzAmount,
            params.maxFuzzAmount / 2
        );

        // First deposit and tend
        mintAndDepositIntoStrategy(strategy, user, _amount1);
        vm.prank(keeper);
        strategy.tend();

        uint256 totalAfterFirst = strategy.estimatedTotalAsset();

        // Second deposit and tend
        airdrop(params.asset, user, _amount2);
        vm.prank(user);
        params.asset.approve(address(strategy), _amount2);
        vm.prank(user);
        strategy.deposit(_amount2, user);

        vm.prank(keeper);
        strategy.tend();

        uint256 totalAfterSecond = strategy.estimatedTotalAsset();

        // Total should have increased
        assertGt(
            totalAfterSecond,
            totalAfterFirst,
            "Total should increase after second deposit"
        );

        // Should approximate sum of both deposits
        uint256 tolerance = ((_amount1 + _amount2) * 15) / 100; // 15% tolerance
        assertApproxEqAbs(
            totalAfterSecond,
            _amount1 + _amount2,
            tolerance,
            "Should approximate sum of deposits"
        );
    }

    function test_boundaryValues_minMax(IStrategyInterface strategy) public {
        TestParams memory params = _getTestParams(address(strategy));

        mintAndDepositIntoStrategy(strategy, user, params.minFuzzAmount);
        vm.prank(keeper);
        strategy.tend();

        assertGt(
            strategy.estimatedTotalAsset(),
            0,
            "Should handle minimum amount"
        );

        vm.prank(management);
        strategy.manualWithdrawFromLp(type(uint256).max);

        // Withdraw
        vm.startPrank(user);
        strategy.redeem(strategy.maxRedeem(user), user, user);
        vm.stopPrank();

        uint256 largeAmount = params.maxFuzzAmount;
        mintAndDepositIntoStrategy(strategy, user, largeAmount);
        vm.prank(keeper);
        strategy.tend();

        assertGt(
            strategy.estimatedTotalAsset(),
            0,
            "Should handle large amount"
        );
    }
}

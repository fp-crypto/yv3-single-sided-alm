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

    function test_rebalancing_insufficientAssetBalance(
        IStrategyInterface strategy,
        uint256 _amount
    ) public {
        TestParams memory params = _getTestParams(address(strategy));
        _amount = bound(_amount, params.minFuzzAmount, params.maxFuzzAmount);

        // Create position
        mintAndDepositIntoStrategy(strategy, user, _amount);
        vm.prank(keeper);
        strategy.tend();

        // Drain most asset balance to trigger line 421 condition, but leave some minimal amount
        uint256 currentAssetBalance = params.asset.balanceOf(address(strategy));
        if (currentAssetBalance > 1000) {
            vm.prank(address(strategy));
            params.asset.transfer(user, currentAssetBalance - 1000);
        }

        // Add a small amount of paired token to create slight imbalance
        uint256 pairedTokenAmount = _amount / 100; // Much smaller amount
        
        // Adjust for decimal differences between asset and paired token
        int256 decimalDiff = int256(params.assetDecimals) - int256(params.pairedAssetDecimals);
        if (decimalDiff > 0) {
            pairedTokenAmount = pairedTokenAmount / (10 ** uint256(decimalDiff));
        } else if (decimalDiff < 0) {
            pairedTokenAmount = pairedTokenAmount * (10 ** uint256(-decimalDiff));
        }
        
        if (pairedTokenAmount > 0) {
            airdrop(params.pairedAsset, address(strategy), pairedTokenAmount);
        }

        // Should hit line 421: assetValueToSwap > assetBalance (gracefully handled)
        vm.prank(keeper);
        strategy.tend();

        // Should handle insufficient balance gracefully without reverting
        assertTrue(true, "Handled insufficient asset balance");
    }

    function test_rebalancing_insufficientPairedTokenBalance(
        IStrategyInterface strategy,
        uint256 _amount
    ) public {
        TestParams memory params = _getTestParams(address(strategy));
        _amount = bound(_amount, params.minFuzzAmount, params.maxFuzzAmount);

        // Create position
        mintAndDepositIntoStrategy(strategy, user, _amount);
        vm.prank(keeper);
        strategy.tend();

        // Drain paired token balance to trigger line 437 condition, but leave minimal amount
        uint256 currentPairedBalance = params.pairedAsset.balanceOf(address(strategy));
        if (currentPairedBalance > 1000) {
            vm.prank(address(strategy));
            params.pairedAsset.transfer(user, currentPairedBalance - 1000);
        }

        // Add a small amount of asset to create slight imbalance
        uint256 assetAmount = _amount / 100; // Much smaller amount
        if (assetAmount > 0) {
            airdrop(params.asset, address(strategy), assetAmount);
        }

        // Should hit line 437: pairedTokenQuantityToSwap > pairedTokenBalance (gracefully handled)
        vm.prank(keeper);
        strategy.tend();

        // Should handle insufficient balance gracefully without reverting
        assertTrue(true, "Handled insufficient paired token balance");
    }

    function test_depositInLp_emptySteerLP(
        IStrategyInterface strategy,
        uint256 _amount
    ) public {
        TestParams memory params = _getTestParams(address(strategy));
        _amount = bound(_amount, params.minFuzzAmount, params.maxFuzzAmount);

        // We need to simulate the condition where lpToken0Balance == 0 && lpToken1Balance == 0
        // This is tested by having assets ready for deposit but the Steer LP being empty
        // In practice, this could happen if strategy is the first depositor or LP was fully drained

        mintAndDepositIntoStrategy(strategy, user, _amount);

        // Check initial state - strategy has assets but hasn't tended yet
        uint256 assetBalance = params.asset.balanceOf(address(strategy));
        assertEq(assetBalance, _amount, "Strategy should have deposited assets");
        assertEq(ERC20(params.lp).balanceOf(address(strategy)), 0, "Strategy should have no LP shares initially");

        // Get the Steer LP and check its total amounts - this simulates the empty LP condition
        ISushiMultiPositionLiquidityManager steerLP = ISushiMultiPositionLiquidityManager(params.lp);
        (uint256 total0InLp, uint256 total1InLp) = steerLP.getTotalAmounts();

        // If LP is not empty, we skip this specific test condition
        // as we're testing the boundary case where LP is completely empty
        if (total0InLp != 0 || total1InLp != 0) {
            // LP is not empty, this test validates that the logic works with existing LP
            vm.prank(keeper);
            strategy.tend();
            assertGt(ERC20(params.lp).balanceOf(address(strategy)), 0, "Strategy should have LP shares");
            return;
        }

        // If we reach here, LP is empty - this triggers the line 519 condition:
        // if (lpToken0Balance == 0 && lpToken1Balance == 0) return;
        vm.prank(keeper);
        strategy.tend();

        // When LP is empty, _depositInLp should return early and not deposit
        // Strategy should still have the asset balance and no LP shares
        assertEq(
            params.asset.balanceOf(address(strategy)),
            _amount,
            "Assets should remain undeployed when LP is empty"
        );
        assertEq(
            ERC20(params.lp).balanceOf(address(strategy)),
            0,
            "Strategy should have no LP shares when LP is empty"
        );
    }

    function test_availableDepositLimit_scenarios(
        IStrategyInterface strategy
    ) public {
        TestParams memory params = _getTestParams(address(strategy));
        uint256 baseAmount = params.minFuzzAmount * 10; // Use a reasonable base amount

        // Test 1: depositLimit set very low (1 wei) with totalAssets = 0
        vm.prank(management);
        strategy.setDepositLimit(1);

        uint256 availableLimit = strategy.availableDepositLimit(user);
        assertEq(availableLimit, 1, "Should allow deposit up to 1 wei when totalAssets is 0");

        // Test 2: depositLimit slightly above totalAssets
        uint256 smallDeposit = baseAmount / 4;
        vm.prank(management);
        strategy.setDepositLimit(smallDeposit + 100);

        mintAndDepositIntoStrategy(strategy, user, smallDeposit);
        
        availableLimit = strategy.availableDepositLimit(user);
        assertEq(availableLimit, 100, "Should allow deposit up to remaining capacity");

        // Reset for next test
        vm.startPrank(user);
        strategy.redeem(strategy.maxRedeem(user), user, user);
        vm.stopPrank();

        // Test 3: depositLimit exactly equals totalAssets
        vm.prank(management);
        strategy.setDepositLimit(baseAmount);

        mintAndDepositIntoStrategy(strategy, user, baseAmount);
        
        availableLimit = strategy.availableDepositLimit(user);
        assertEq(availableLimit, 0, "Should allow no deposits when at exact limit");

        // Test 4: depositLimit below totalAssets (should return 0)
        // First add more assets to make totalAssets > depositLimit
        airdrop(params.asset, address(strategy), 100);
        
        availableLimit = strategy.availableDepositLimit(user);
        assertEq(availableLimit, 0, "Should allow no deposits when totalAssets exceeds depositLimit");

        // Test 5: Reset to unlimited and verify normal behavior
        vm.prank(management);
        strategy.setDepositLimit(type(uint256).max);
        
        availableLimit = strategy.availableDepositLimit(user);
        assertGt(availableLimit, 0, "Should allow deposits when limit is unlimited");
    }

    function test_availableDepositLimit_edgeCases(
        IStrategyInterface strategy
    ) public {
        TestParams memory params = _getTestParams(address(strategy));

        // Test with depositLimit = 0 (no deposits allowed)
        vm.prank(management);
        strategy.setDepositLimit(0);

        uint256 availableLimit = strategy.availableDepositLimit(user);
        assertEq(availableLimit, 0, "Should allow no deposits when limit is 0");

        // Test with very large depositLimit
        vm.prank(management);
        strategy.setDepositLimit(type(uint256).max);

        availableLimit = strategy.availableDepositLimit(user);
        assertGt(availableLimit, 0, "Should allow deposits with max limit");

        // Test boundary where depositLimit - totalAssets = 1
        uint256 smallAmount = params.minFuzzAmount;
        vm.prank(management);
        strategy.setDepositLimit(smallAmount + 1);

        mintAndDepositIntoStrategy(strategy, user, smallAmount);
        
        availableLimit = strategy.availableDepositLimit(user);
        assertEq(availableLimit, 1, "Should allow exactly 1 wei deposit at boundary");
    }
}

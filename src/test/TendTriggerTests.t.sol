// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "forge-std/console2.sol";
import {Setup, ERC20, IStrategyInterface} from "./utils/Setup.sol";

contract TendTriggerTests is Setup {
    function setUp() public virtual override {
        super.setUp();
    }

    function test_tendTrigger_defaultParameters(
        IStrategyInterface strategy
    ) public {
        TestParams memory params = _getTestParams(address(strategy));

        // Check initial default values
        assertEq(strategy.minTendWait(), 5 minutes, "default minTendWait");
        assertEq(
            strategy.maxTendBaseFeeGwei(),
            100,
            "default maxTendBaseFeeGwei"
        );
        assertEq(strategy.lastTend(), 0, "initial lastTend");

        // Initially should be false (no idle assets)
        (bool trigger, ) = strategy.tendTrigger();
        assertFalse(trigger, "initial trigger should be false");
    }

    function test_tendTrigger_withIdleAssets(
        IStrategyInterface strategy,
        uint256 _amount
    ) public {
        TestParams memory params = _getTestParams(address(strategy));
        _amount = bound(_amount, params.minFuzzAmount, params.maxFuzzAmount);

        // Deposit assets to create idle balance
        mintAndDepositIntoStrategy(strategy, user, _amount);

        // Should trigger with idle assets
        (bool trigger, ) = strategy.tendTrigger();
        assertTrue(trigger, "should trigger with idle assets");

        // Tend to deposit idle assets
        vm.prank(keeper);
        strategy.tend();

        // Should not trigger immediately after tend (minWait not passed)
        (trigger, ) = strategy.tendTrigger();
        assertFalse(trigger, "should not trigger immediately after tend");

        // Fast forward past minWait
        skip(5 minutes + 1);

        // Check if there are still idle assets after tend
        uint256 idleAfterTend = params.asset.balanceOf(address(strategy));
        if (idleAfterTend > 0) {
            // If there are idle assets, trigger should be true
            (trigger, ) = strategy.tendTrigger();
            assertTrue(trigger, "should trigger with remaining idle assets");
        } else {
            // If no idle assets, trigger should be false
            (trigger, ) = strategy.tendTrigger();
            assertFalse(trigger, "should not trigger without idle assets");
        }
    }

    function test_tendTrigger_minWaitEnforcement(
        IStrategyInterface strategy,
        uint256 _amount,
        uint24 _minWait
    ) public {
        TestParams memory params = _getTestParams(address(strategy));
        _amount = bound(_amount, params.minFuzzAmount, params.maxFuzzAmount);
        _minWait = uint24(bound(uint256(_minWait), 1 minutes, 7 days));

        // Set custom minWait
        vm.prank(management);
        strategy.setMinTendWait(_minWait);

        // Deposit and tend
        mintAndDepositIntoStrategy(strategy, user, _amount);
        vm.prank(keeper);
        strategy.tend();

        // Deposit more to create idle assets
        mintAndDepositIntoStrategy(strategy, user, _amount);

        // Should not trigger before minWait
        (bool trigger, ) = strategy.tendTrigger();
        assertFalse(trigger, "should not trigger before minWait");

        // Fast forward to just before minWait
        skip(_minWait - 1);
        (trigger, ) = strategy.tendTrigger();
        assertFalse(trigger, "should not trigger just before minWait");

        // Fast forward past minWait
        skip(2);
        (trigger, ) = strategy.tendTrigger();
        assertTrue(trigger, "should trigger after minWait");
    }

    function test_tendTrigger_baseFeeCheck(
        IStrategyInterface strategy,
        uint256 _amount,
        uint8 _maxBaseFeeGwei
    ) public {
        TestParams memory params = _getTestParams(address(strategy));
        _amount = bound(_amount, params.minFuzzAmount, params.maxFuzzAmount);
        _maxBaseFeeGwei = uint8(bound(uint256(_maxBaseFeeGwei), 1, 255));

        // Set custom maxBaseFee
        vm.prank(management);
        strategy.setMaxTendBaseFee(_maxBaseFeeGwei);

        // Deposit to create idle assets
        mintAndDepositIntoStrategy(strategy, user, _amount);

        // Mock high base fee
        vm.fee(uint256(_maxBaseFeeGwei) * 1 gwei + 1);
        (bool trigger, ) = strategy.tendTrigger();
        assertFalse(trigger, "should not trigger with high base fee");

        // Mock acceptable base fee
        vm.fee(uint256(_maxBaseFeeGwei) * 1 gwei);
        (trigger, ) = strategy.tendTrigger();
        assertTrue(trigger, "should trigger with acceptable base fee");

        // Mock low base fee
        vm.fee((uint256(_maxBaseFeeGwei) * 1 gwei) / 2);
        (trigger, ) = strategy.tendTrigger();
        assertTrue(trigger, "should trigger with low base fee");
    }

    function test_tendTrigger_targetIdleAssetBps(
        IStrategyInterface strategy,
        uint256 _amount,
        uint16 _targetIdleBps
    ) public {
        TestParams memory params = _getTestParams(address(strategy));
        _amount = bound(_amount, params.minFuzzAmount, params.maxFuzzAmount);
        _targetIdleBps = uint16(bound(uint256(_targetIdleBps), 100, 5000)); // 1% to 50%

        // Set target idle
        vm.prank(management);
        strategy.setTargetIdleAssetBps(_targetIdleBps);

        // Deposit and tend to get assets into LP
        mintAndDepositIntoStrategy(strategy, user, _amount);
        vm.prank(keeper);
        strategy.tend();

        // Skip minWait
        skip(5 minutes + 1);

        // Calculate target idle amount based on current total assets
        uint256 totalAssets = strategy.totalAssets();
        uint256 targetIdle = (totalAssets * _targetIdleBps) / 10000;

        // Calculate the buffer threshold (110% of target)
        uint256 bufferThreshold = (targetIdle * 110) / 100;

        // Get current idle balance
        uint256 currentIdle = params.asset.balanceOf(address(strategy));

        if (currentIdle < bufferThreshold) {
            // Deposit to get just below buffer threshold
            uint256 toDeposit = bufferThreshold - currentIdle - 1;
            if (toDeposit > 0) {
                mintAndDepositIntoStrategy(strategy, user, toDeposit);
            }

            // Should not trigger when below buffer
            (bool trigger, ) = strategy.tendTrigger();
            assertFalse(trigger, "should not trigger below buffer");

            // Deposit more to exceed buffer
            mintAndDepositIntoStrategy(strategy, user, targetIdle / 2);
        }

        // Should trigger when above buffer
        (bool trigger, ) = strategy.tendTrigger();
        assertTrue(trigger, "should trigger above buffer");
    }

    function test_tendTrigger_allConditionsCombined(
        IStrategyInterface strategy,
        uint256 _amount
    ) public {
        TestParams memory params = _getTestParams(address(strategy));
        _amount = bound(_amount, params.minFuzzAmount, params.maxFuzzAmount);

        // Set parameters
        vm.startPrank(management);
        strategy.setMinTendWait(2 hours);
        strategy.setMaxTendBaseFee(50); // 50 gwei
        strategy.setTargetIdleAssetBps(1000); // 10%
        vm.stopPrank();

        // Initial deposit and tend
        mintAndDepositIntoStrategy(strategy, user, _amount);
        vm.prank(keeper);
        strategy.tend();

        // Test 1: All conditions fail
        vm.fee(100 gwei); // High base fee
        mintAndDepositIntoStrategy(strategy, user, _amount / 20); // Small idle
        (bool trigger, ) = strategy.tendTrigger();
        assertFalse(trigger, "all conditions fail");

        // Test 2: Only time passes
        skip(3 hours);
        (trigger, ) = strategy.tendTrigger();
        assertFalse(trigger, "only time condition met");

        // Test 3: Time and base fee ok, check idle assets
        vm.fee(25 gwei);
        uint256 idleBalance = params.asset.balanceOf(address(strategy));
        uint256 totalAssets = strategy.totalAssets();
        uint256 targetIdle = (totalAssets * 1000) / 10000; // 10%
        uint256 bufferThreshold = (targetIdle * 110) / 100;

        if (idleBalance <= bufferThreshold) {
            (trigger, ) = strategy.tendTrigger();
            assertFalse(trigger, "insufficient idle assets");

            // Test 4: All conditions met - deposit enough to exceed buffer
            uint256 toDeposit = bufferThreshold - idleBalance + _amount / 10;
            mintAndDepositIntoStrategy(strategy, user, toDeposit);
        }

        (trigger, ) = strategy.tendTrigger();
        assertTrue(trigger, "all conditions met");
    }

    function test_setMinTendWait_onlyManagement(
        IStrategyInterface strategy
    ) public {
        TestParams memory params = _getTestParams(address(strategy));

        vm.expectRevert("!management");
        strategy.setMinTendWait(2 hours);

        vm.prank(management);
        strategy.setMinTendWait(2 hours);
        assertEq(strategy.minTendWait(), 2 hours, "minTendWait updated");
    }

    function test_setMaxTendBaseFee_onlyManagement(
        IStrategyInterface strategy
    ) public {
        TestParams memory params = _getTestParams(address(strategy));

        vm.expectRevert("!management");
        strategy.setMaxTendBaseFee(200);

        vm.prank(management);
        strategy.setMaxTendBaseFee(200);
        assertEq(
            strategy.maxTendBaseFeeGwei(),
            200,
            "maxTendBaseFeeGwei updated"
        );
    }

    function test_tendTrigger_zeroIdleAssets(
        IStrategyInterface strategy
    ) public {
        TestParams memory params = _getTestParams(address(strategy));

        // Ensure no idle assets
        assertEq(
            params.asset.balanceOf(address(strategy)),
            0,
            "no idle assets"
        );

        // Should not trigger with zero idle
        (bool trigger, ) = strategy.tendTrigger();
        assertFalse(trigger, "should not trigger with zero idle");
    }

    function test_tendTrigger_noTargetIdleSet(
        IStrategyInterface strategy,
        uint256 _amount
    ) public {
        TestParams memory params = _getTestParams(address(strategy));
        _amount = bound(_amount, params.minFuzzAmount, params.maxFuzzAmount);

        // Ensure target idle is 0
        assertEq(strategy.targetIdleAssetBps(), 0, "no target idle");

        // Deposit to create idle assets
        mintAndDepositIntoStrategy(strategy, user, _amount);

        // Should trigger with any idle assets when no target is set
        (bool trigger, ) = strategy.tendTrigger();
        assertTrue(trigger, "should trigger with idle and no target");
    }

    function test_setMinAsset_onlyManagement(
        IStrategyInterface strategy
    ) public {
        TestParams memory params = _getTestParams(address(strategy));

        vm.expectRevert("!management");
        strategy.setMinAsset(1e18);

        vm.prank(management);
        strategy.setMinAsset(1e18);
        assertEq(strategy.minAsset(), 1e18, "minAsset updated");
    }

    function test_tend_withTargetIdleDeficit(
        IStrategyInterface strategy,
        uint256 _amount
    ) public {
        TestParams memory params = _getTestParams(address(strategy));
        _amount = bound(
            _amount,
            params.minFuzzAmount * 10,
            params.maxFuzzAmount
        );

        // Setup: Deposit and tend to get everything into LP
        mintAndDepositIntoStrategy(strategy, user, _amount);
        vm.prank(keeper);
        strategy.tend();

        // Verify most assets are in LP
        uint256 lpBalanceInitial = ERC20(params.lp).balanceOf(
            address(strategy)
        );
        assertGt(lpBalanceInitial, 0, "Should have LP tokens");

        // Set a high target idle (50%)
        vm.prank(management);
        strategy.setTargetIdleAssetBps(5000);

        // Skip time to allow another tend
        skip(strategy.minTendWait() + 1);

        // Tend should trigger because idle is below target
        (bool shouldTrigger, ) = strategy.tendTrigger();
        assertTrue(shouldTrigger, "Should trigger tend with idle deficit");

        // Now tend should withdraw from LP to meet target idle
        uint256 lpBefore = ERC20(params.lp).balanceOf(address(strategy));
        vm.prank(keeper);
        strategy.tend();

        uint256 lpAfter = ERC20(params.lp).balanceOf(address(strategy));
        uint256 idleAfter = params.asset.balanceOf(address(strategy));

        // Verify LP decreased and idle increased
        assertLt(lpAfter, lpBefore, "LP should decrease");
        assertGt(idleAfter, 0, "Should have idle assets");

        // Verify idle is approximately target (50% of total assets)
        uint256 targetIdle = (strategy.totalAssets() * 5000) / 10000;
        // Allow for some deviation due to swaps and price movements
        assertApproxEqRel(idleAfter, targetIdle, 0.2e18, "Idle should be ~50%");
    }
}

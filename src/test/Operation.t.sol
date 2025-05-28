// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "forge-std/console2.sol";
import {Setup, ERC20, IStrategyInterface} from "./utils/Setup.sol";

contract OperationTest is Setup {
    function setUp() public virtual override {
        super.setUp();
    }

    function test_setupStrategyOK() public {
        console2.log("address of strategy", address(strategy));
        assertTrue(address(0) != address(strategy));
        assertEq(strategy.asset(), address(asset));
        assertEq(strategy.management(), management);
        assertEq(strategy.performanceFeeRecipient(), performanceFeeRecipient);
        assertEq(strategy.keeper(), keeper);
    }

    function test_operation(uint256 _amount) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        uint256 maxDelta = (_amount * 0.10e18) / 1e18; // allow a 10% deviation

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        assertEq(strategy.totalAssets(), _amount, "!totalAssets");

        vm.prank(keeper);
        strategy.tend();
        logStrategyInfo();
        assertApproxEqAbs(
            strategy.estimatedTotalAsset(),
            _amount,
            maxDelta,
            "!eta"
        );
        assertGt(ERC20(lp).balanceOf(address(strategy)), 0, "no lp");
        assertApproxEqAbs(
            asset.balanceOf(address(strategy)),
            0,
            maxDelta,
            "too much idle asset"
        );
        assertApproxEqAbs(
            otherAsset.balanceOf(address(strategy)),
            0,
            maxDelta / 10 ** 12, // TODO: correct decimals conversion
            "too much idle otherAsset"
        );

        // Earn Interest
        skip(1 days);

        vm.prank(management);
        strategy.setDoHealthCheck(false);

        // Report profit
        vm.prank(keeper);
        (uint256 profit, uint256 loss) = strategy.report();

        // Check return Values
        assertApproxEqAbs(profit, 0, maxDelta, "!profit");
        assertApproxEqAbs(loss, 0, maxDelta, "!loss");

        skip(strategy.profitMaxUnlockTime());

        vm.prank(management);
        strategy.manualWithdrawFromLp(type(uint256).max);
        logStrategyInfo();

        uint256 balanceBefore = asset.balanceOf(user);

        // Withdraw all funds
        vm.startPrank(user);
        strategy.redeem(strategy.maxRedeem(user), user, user);
        vm.stopPrank();

        assertApproxEqAbs(
            asset.balanceOf(user),
            balanceBefore + _amount,
            maxDelta,
            "!final balance"
        );
    }

    function test_idle(uint256 _amount, uint16 _idleBps) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        _idleBps = uint16(bound(uint256(_idleBps), 0, 10_000));
        uint256 maxDelta = (_amount * 0.05e18) / 1e18; // allow a 5% deviation

        vm.prank(management);
        strategy.setTargetIdleAssetBps(_idleBps);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        assertEq(strategy.totalAssets(), _amount, "!totalAssets");

        vm.prank(keeper);
        strategy.tend();

        logStrategyInfo();
        assertApproxEqAbs(
            strategy.estimatedTotalAsset(),
            _amount,
            maxDelta,
            "!eta"
        );
        if (_idleBps != 10_000)
            assertGt(ERC20(lp).balanceOf(address(strategy)), 0, "no lp");
        else assertEq(ERC20(lp).balanceOf(address(strategy)), 0, "lp");
        assertApproxEqAbs(
            asset.balanceOf(address(strategy)),
            (_amount * _idleBps) / 10000,
            0.01e18,
            "too much idle asset"
        );

        vm.prank(management);
        strategy.manualWithdrawFromLp(type(uint256).max);
        logStrategyInfo();

        uint256 balanceBefore = asset.balanceOf(user);

        // Withdraw all funds
        vm.startPrank(user);
        strategy.redeem(strategy.maxRedeem(user), user, user);
        vm.stopPrank();

        assertApproxEqAbs(
            asset.balanceOf(user),
            balanceBefore + _amount,
            maxDelta,
            "!final balance"
        );
    }

    function test_profitableReport(
        uint256 _amount,
        uint16 _profitFactor
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        _profitFactor = uint16(bound(uint256(_profitFactor), 10, MAX_BPS));

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        assertEq(strategy.totalAssets(), _amount, "!totalAssets");

        // Earn Interest
        skip(1 days);

        // TODO: implement logic to simulate earning interest.
        uint256 toAirdrop = (_amount * _profitFactor) / MAX_BPS;
        airdrop(asset, address(strategy), toAirdrop);

        // Report profit
        vm.prank(keeper);
        (uint256 profit, uint256 loss) = strategy.report();

        // Check return Values
        assertGe(profit, toAirdrop, "!profit");
        assertEq(loss, 0, "!loss");

        skip(strategy.profitMaxUnlockTime());

        uint256 balanceBefore = asset.balanceOf(user);

        // Withdraw all funds
        vm.startPrank(user);
        strategy.redeem(strategy.maxRedeem(user), user, user);
        vm.stopPrank();

        assertGe(
            asset.balanceOf(user),
            balanceBefore + _amount,
            "!final balance"
        );
    }

    function test_tendTrigger(uint256 _amount) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);

        (bool trigger, ) = strategy.tendTrigger();
        assertTrue(!trigger);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        (trigger, ) = strategy.tendTrigger();
        assertTrue(!trigger);

        // Skip some time
        skip(1 days);

        (trigger, ) = strategy.tendTrigger();
        assertTrue(!trigger);

        vm.prank(keeper);
        strategy.report();

        (trigger, ) = strategy.tendTrigger();
        assertTrue(!trigger);

        // Unlock Profits
        skip(strategy.profitMaxUnlockTime());

        (trigger, ) = strategy.tendTrigger();
        assertTrue(!trigger);

        vm.prank(user);
        strategy.redeem(_amount, user, user);

        (trigger, ) = strategy.tendTrigger();
        assertTrue(!trigger);
    }
}

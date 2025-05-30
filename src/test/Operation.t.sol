// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "forge-std/console2.sol";
import {Setup, ERC20, IStrategyInterface} from "./utils/Setup.sol";

contract OperationTest is Setup {
    function setUp() public virtual override {
        super.setUp();
    }

    function _calculatePairedAssetDelta(
        TestParams memory params,
        uint256 maxDelta,
        bool isVolatile
    ) internal pure returns (uint256) {
        int256 decimalDiff = int256(params.assetDecimals) -
            int256(params.pairedAssetDecimals);
        uint256 pairedAssetMaxDelta;

        if (decimalDiff >= 0) {
            pairedAssetMaxDelta = maxDelta / 10 ** uint256(decimalDiff);
        } else {
            pairedAssetMaxDelta = maxDelta * 10 ** uint256(-decimalDiff);
        }

        // Use higher minimum for volatile pairs
        uint256 minPairedDelta = isVolatile ? 10000 : 1000;
        if (pairedAssetMaxDelta < minPairedDelta) {
            pairedAssetMaxDelta = minPairedDelta;
        }

        return pairedAssetMaxDelta;
    }

    function test_setupStrategyOK(IStrategyInterface strategy) public {
        TestParams memory params = _getTestParams(address(strategy));
        ERC20 asset = params.asset;

        console2.log("address of strategy", address(strategy));
        assertTrue(address(0) != address(strategy));
        assertEq(strategy.asset(), address(asset));
        assertEq(strategy.management(), management);
        assertEq(strategy.performanceFeeRecipient(), performanceFeeRecipient);
        assertEq(strategy.keeper(), keeper);
    }

    function test_operation(
        IStrategyInterface strategy,
        uint256 _amount
    ) public {
        TestParams memory params = _getTestParams(address(strategy));
        _amount = bound(_amount, params.minFuzzAmount, params.maxFuzzAmount);

        // Use higher tolerance for volatile pairs (non-stable pairs)
        uint256 maxDelta = !params.isStable
            ? (_amount * 0.20e18) / 1e18 // 20% tolerance for volatile pairs
            : (_amount * 0.10e18) / 1e18; // 10% tolerance for stable pairs

        _performOperationTest(
            strategy,
            params,
            _amount,
            maxDelta,
            !params.isStable
        );
    }

    function _performOperationTest(
        IStrategyInterface strategy,
        TestParams memory params,
        uint256 _amount,
        uint256 maxDelta,
        bool isVolatile
    ) internal {
        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        assertEq(strategy.totalAssets(), _amount, "!totalAssets");

        vm.prank(keeper);
        strategy.tend();
        logStrategyInfo(params);
        assertApproxEqAbs(
            strategy.estimatedTotalAsset(),
            _amount,
            maxDelta,
            "!eta"
        );
        assertGt(ERC20(params.lp).balanceOf(address(strategy)), 0, "no lp");
        assertApproxEqAbs(
            params.asset.balanceOf(address(strategy)),
            0,
            maxDelta,
            "too much idle asset"
        );

        // For paired asset, adjust delta based on decimal differences
        assertApproxEqAbs(
            params.pairedAsset.balanceOf(address(strategy)),
            0,
            _calculatePairedAssetDelta(params, maxDelta, isVolatile),
            "too much idle pairedAsset"
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
        logStrategyInfo(params);

        uint256 balanceBefore = params.asset.balanceOf(user);

        // Withdraw all funds
        vm.startPrank(user);
        strategy.redeem(strategy.maxRedeem(user), user, user);
        vm.stopPrank();

        assertApproxEqAbs(
            params.asset.balanceOf(user),
            balanceBefore + _amount,
            maxDelta,
            "!final balance"
        );
    }

    function test_twoDeposits(
        IStrategyInterface strategy,
        uint256 _amount,
        uint16 _initialDepositBps
    ) public {
        TestParams memory params = _getTestParams(address(strategy));
        _amount = bound(_amount, params.minFuzzAmount, params.maxFuzzAmount);
        _initialDepositBps = uint16(
            bound(uint256(_initialDepositBps), 1000, 9000)
        );

        // Use higher tolerance for volatile pairs (non-stable pairs)
        uint256 maxDelta = !params.isStable
            ? (_amount * 0.20e18) / 1e18 // 20% tolerance for volatile pairs
            : (_amount * 0.10e18) / 1e18; // 10% tolerance for stable pairs

        _performTwoDepositsTest(
            strategy,
            params,
            _amount,
            _initialDepositBps,
            maxDelta,
            !params.isStable
        );
    }

    function _performTwoDepositsTest(
        IStrategyInterface strategy,
        TestParams memory params,
        uint256 _amount,
        uint16 _initialDepositBps,
        uint256 maxDelta,
        bool isVolatile
    ) internal {
        // Deposit into strategy
        airdrop(params.asset, user, _amount);

        uint256 _initialDepositAmount = (_amount * _initialDepositBps) /
            MAX_BPS;
        depositIntoStrategy(strategy, user, _initialDepositAmount);

        assertEq(strategy.totalAssets(), _initialDepositAmount, "!totalAssets");

        vm.prank(keeper);
        strategy.tend();
        logStrategyInfo(params);
        assertApproxEqAbs(
            strategy.estimatedTotalAsset(),
            _initialDepositAmount,
            maxDelta,
            "!eta"
        );
        assertGt(ERC20(params.lp).balanceOf(address(strategy)), 0, "no lp");
        assertApproxEqAbs(
            params.asset.balanceOf(address(strategy)),
            0,
            maxDelta,
            "too much idle asset"
        );

        // For paired asset, adjust delta based on decimal differences
        uint256 pairedAssetMaxDelta = _calculatePairedAssetDelta(
            params,
            maxDelta,
            isVolatile
        );
        assertApproxEqAbs(
            params.pairedAsset.balanceOf(address(strategy)),
            0,
            pairedAssetMaxDelta,
            "too much idle pairedAsset"
        );

        skip(1 days);

        uint256 _subsequentDepositAmount = params.asset.balanceOf(user);
        depositIntoStrategy(strategy, user, _subsequentDepositAmount);

        assertEq(strategy.totalAssets(), _amount, "!totalAssets");

        vm.prank(keeper);
        strategy.tend();
        logStrategyInfo(params);
        assertApproxEqAbs(
            strategy.estimatedTotalAsset(),
            _amount,
            maxDelta,
            "!eta"
        );
        assertGt(ERC20(params.lp).balanceOf(address(strategy)), 0, "no lp");
        assertApproxEqAbs(
            params.asset.balanceOf(address(strategy)),
            0,
            maxDelta,
            "too much idle asset"
        );
        assertApproxEqAbs(
            params.pairedAsset.balanceOf(address(strategy)),
            0,
            pairedAssetMaxDelta,
            "too much idle pairedAsset"
        );

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
        logStrategyInfo(params);

        uint256 balanceBefore = params.asset.balanceOf(user);

        // Withdraw all funds
        vm.startPrank(user);
        strategy.redeem(strategy.maxRedeem(user), user, user);
        vm.stopPrank();

        assertApproxEqAbs(
            params.asset.balanceOf(user),
            balanceBefore + _amount,
            maxDelta,
            "!final balance"
        );
    }

    function test_idle(
        IStrategyInterface strategy,
        uint256 _amount,
        uint16 _idleBps
    ) public {
        TestParams memory params = _getTestParams(address(strategy));
        _amount = bound(_amount, params.minFuzzAmount, params.maxFuzzAmount);
        _idleBps = uint16(bound(uint256(_idleBps), 0, MAX_BPS));
        uint256 maxDelta = (_amount * 0.05e18) / 1e18; // allow a 5% deviation

        vm.prank(management);
        strategy.setTargetIdleAssetBps(_idleBps);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        assertEq(strategy.totalAssets(), _amount, "!totalAssets");

        vm.prank(keeper);
        strategy.tend();

        logStrategyInfo(params);
        assertApproxEqAbs(
            strategy.estimatedTotalAsset(),
            _amount,
            maxDelta,
            "!eta"
        );
        if (_idleBps != 10_000)
            assertGt(ERC20(params.lp).balanceOf(address(strategy)), 0, "no lp");
        else assertEq(ERC20(params.lp).balanceOf(address(strategy)), 0, "lp");
        assertGe(
            params.asset.balanceOf(address(strategy)),
            (_amount * _idleBps) / MAX_BPS,
            "too little idle"
        );
        assertApproxEqAbs(
            params.asset.balanceOf(address(strategy)),
            (_amount * _idleBps) / MAX_BPS,
            maxDelta,
            "too much idle asset"
        );

        vm.prank(management);
        strategy.manualWithdrawFromLp(type(uint256).max);
        logStrategyInfo(params);

        uint256 balanceBefore = params.asset.balanceOf(user);

        // Withdraw all funds
        vm.startPrank(user);
        strategy.redeem(strategy.maxRedeem(user), user, user);
        vm.stopPrank();

        assertApproxEqAbs(
            params.asset.balanceOf(user),
            balanceBefore + _amount,
            maxDelta,
            "!final balance"
        );
    }

    function test_profitableReport(
        IStrategyInterface strategy,
        uint256 _amount,
        uint16 _profitFactor
    ) public {
        TestParams memory params = _getTestParams(address(strategy));
        _amount = bound(_amount, params.minFuzzAmount, params.maxFuzzAmount);
        _profitFactor = uint16(bound(uint256(_profitFactor), 10, MAX_BPS));

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        assertEq(strategy.totalAssets(), _amount, "!totalAssets");

        // Earn Interest
        skip(1 days);

        uint256 toAirdrop = (_amount * _profitFactor) / MAX_BPS;
        airdrop(params.asset, address(strategy), toAirdrop);

        // Report profit
        vm.prank(keeper);
        (uint256 profit, uint256 loss) = strategy.report();

        // Check return Values
        assertGe(profit, toAirdrop, "!profit");
        assertEq(loss, 0, "!loss");

        skip(strategy.profitMaxUnlockTime());

        uint256 balanceBefore = params.asset.balanceOf(user);

        // Withdraw all funds
        vm.startPrank(user);
        strategy.redeem(strategy.maxRedeem(user), user, user);
        vm.stopPrank();

        assertGe(
            params.asset.balanceOf(user),
            balanceBefore + _amount,
            "!final balance"
        );
    }

    function test_tendTrigger(
        IStrategyInterface strategy,
        uint256 _amount
    ) public {
        TestParams memory params = _getTestParams(address(strategy));
        _amount = bound(_amount, params.minFuzzAmount, params.maxFuzzAmount);

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

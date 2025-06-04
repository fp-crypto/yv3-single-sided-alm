// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "forge-std/console2.sol";
import {Setup, ERC20, IStrategyInterface} from "./utils/Setup.sol";
import {ISushiMultiPositionLiquidityManager} from "../interfaces/steer/ISushiMultiPositionLiquidityManager.sol";
import {IUniswapV3Pool} from "@uniswap-v3-core/interfaces/IUniswapV3Pool.sol";

contract PriceCalculationTests is Setup {
    function setUp() public virtual override {
        super.setUp();
    }

    function test_estimatedTotalAsset_zeroBalances(
        IStrategyInterface strategy
    ) public {
        _getTestParams(address(strategy));

        // Should return 0 when everything is empty
        assertEq(strategy.estimatedTotalAsset(), 0);
    }

    function test_estimatedTotalAsset_onlyAssetBalance(
        IStrategyInterface strategy,
        uint256 _amount
    ) public {
        TestParams memory params = _getTestParams(address(strategy));
        _amount = bound(_amount, params.minFuzzAmount, params.maxFuzzAmount);

        // Give strategy some asset tokens
        airdrop(params.asset, address(strategy), _amount);

        assertEq(strategy.estimatedTotalAsset(), _amount);
    }

    function test_estimatedTotalAsset_onlyPairedTokenBalance(
        IStrategyInterface strategy,
        uint256 _amount
    ) public {
        TestParams memory params = _getTestParams(address(strategy));

        // Set reasonable bounds based on paired asset decimals
        uint256 minAmount = 10 ** params.pairedAssetDecimals / 100; // 0.01 units
        uint256 maxAmount = 100 * 10 ** params.pairedAssetDecimals; // 100 units
        _amount = bound(_amount, minAmount, maxAmount);

        // Give strategy some paired tokens
        airdrop(params.pairedAsset, address(strategy), _amount);

        uint256 estimatedTotal = strategy.estimatedTotalAsset();
        assertGt(estimatedTotal, 0, "Should have positive estimated total");
    }

    function test_estimatedTotalAsset_withLpPosition(
        IStrategyInterface strategy,
        uint256 _amount
    ) public {
        TestParams memory params = _getTestParams(address(strategy));
        _amount = bound(_amount, params.minFuzzAmount, params.maxFuzzAmount);

        // Deposit and tend to create LP position
        mintAndDepositIntoStrategy(strategy, user, _amount);

        vm.prank(keeper);
        strategy.tend();

        uint256 estimatedTotal = strategy.estimatedTotalAsset();
        uint256 tolerance = (_amount * 15) / 100; // 15% tolerance for slippage

        assertApproxEqAbs(
            estimatedTotal,
            _amount,
            tolerance,
            "Estimated total should approximate deposit amount"
        );
        assertGt(estimatedTotal, 0, "Should have positive estimated total");
    }

    function test_lpVaultInAsset_noLpShares(
        IStrategyInterface strategy
    ) public {
        _getTestParams(address(strategy));

        // Should return 0 when no LP shares
        assertEq(strategy.lpVaultInAsset(), 0);
    }

    function test_lpVaultInAsset_withLpShares(
        IStrategyInterface strategy,
        uint256 _amount
    ) public {
        TestParams memory params = _getTestParams(address(strategy));
        _amount = bound(_amount, params.minFuzzAmount, params.maxFuzzAmount);

        // Deposit and tend to create LP position
        mintAndDepositIntoStrategy(strategy, user, _amount);

        vm.prank(keeper);
        strategy.tend();

        uint256 lpValue = strategy.lpVaultInAsset();
        assertGt(lpValue, 0, "LP value should be positive");

        // LP value should be reasonable compared to deposited amount
        uint256 tolerance = (_amount * 20) / 100; // 20% tolerance
        assertApproxEqAbs(
            lpValue,
            _amount,
            tolerance,
            "LP value should approximate deposit amount"
        );
    }

    function test_availableWithdrawLimit_onlyLooseAssets(
        IStrategyInterface strategy,
        uint256 _amount
    ) public {
        TestParams memory params = _getTestParams(address(strategy));
        _amount = bound(_amount, params.minFuzzAmount, params.maxFuzzAmount);

        // Give strategy some loose assets
        airdrop(params.asset, address(strategy), _amount);

        assertEq(
            strategy.availableWithdrawLimit(user),
            _amount,
            "Available withdraw should equal loose asset balance"
        );
    }

    function test_availableWithdrawLimit_withLpPosition(
        IStrategyInterface strategy,
        uint256 _amount
    ) public {
        TestParams memory params = _getTestParams(address(strategy));
        _amount = bound(_amount, params.minFuzzAmount, params.maxFuzzAmount);

        // Deposit and tend to create LP position
        mintAndDepositIntoStrategy(strategy, user, _amount);

        vm.prank(keeper);
        strategy.tend();

        // Available withdraw should be minimal (only loose assets)
        uint256 availableWithdraw = strategy.availableWithdrawLimit(user);
        uint256 tolerance = (_amount * 10) / 100; // 10% tolerance

        assertLe(
            availableWithdraw,
            tolerance,
            "Available withdraw should be low when assets are in LP"
        );
    }

    function test_availableDepositLimit_noLimit(
        IStrategyInterface strategy
    ) public {
        _getTestParams(address(strategy));

        // Default deposit limit should be max uint256
        uint256 availableDeposit = strategy.availableDepositLimit(user);
        assertEq(
            availableDeposit,
            type(uint256).max,
            "Default should be max uint256"
        );
    }

    function test_availableDepositLimit_withCustomLimit(
        IStrategyInterface strategy,
        uint256 _limit
    ) public {
        TestParams memory params = _getTestParams(address(strategy));
        _limit = bound(_limit, params.minFuzzAmount, params.maxFuzzAmount);

        // Set custom deposit limit
        vm.prank(management);
        strategy.setDepositLimit(_limit);

        uint256 availableDeposit = strategy.availableDepositLimit(user);
        assertEq(availableDeposit, _limit, "Should equal custom limit");
    }

    function test_tend_initialDeposit_createsLp(
        IStrategyInterface strategy,
        uint256 _amount
    ) public {
        TestParams memory params = _getTestParams(address(strategy));
        _amount = bound(_amount, params.minFuzzAmount, params.maxFuzzAmount);

        // Give strategy some assets but don't create LP position
        airdrop(params.asset, address(strategy), _amount);

        // When strategy has no LP position, tend should create one
        // Note: This assumes the Steer LP is not empty (strategy won't be first depositor)
        vm.prank(keeper);
        strategy.tend();

        // Check that some swap occurred and LP position was created
        assertGt(
            ERC20(params.lp).balanceOf(address(strategy)),
            0,
            "Should have created LP position"
        );
    }

    function test_rebalancing_excessPairedToken(
        IStrategyInterface strategy,
        uint256 _amount
    ) public {
        TestParams memory params = _getTestParams(address(strategy));
        _amount = bound(
            _amount,
            params.minFuzzAmount,
            params.maxFuzzAmount / 10
        );

        // Calculate appropriate paired token amount based on decimals
        uint256 pairedAmount;
        if (params.pairedAssetDecimals < params.assetDecimals) {
            pairedAmount =
                _amount /
                (10 ** (params.assetDecimals - params.pairedAssetDecimals));
            if (pairedAmount == 0) pairedAmount = 1;
        } else if (params.pairedAssetDecimals > params.assetDecimals) {
            pairedAmount =
                _amount *
                (10 ** (params.pairedAssetDecimals - params.assetDecimals));
        } else {
            pairedAmount = _amount;
        }

        // Give strategy excess paired tokens
        airdrop(params.asset, address(strategy), _amount);
        airdrop(params.pairedAsset, address(strategy), pairedAmount * 3); // 3x normal amount

        uint256 pairedBalanceBefore = params.pairedAsset.balanceOf(
            address(strategy)
        );

        // Tend should rebalance by swapping excess paired tokens
        vm.prank(keeper);
        strategy.tend();

        // Should have less paired tokens after rebalancing
        assertLt(
            params.pairedAsset.balanceOf(address(strategy)),
            pairedBalanceBefore,
            "Should have swapped excess paired tokens"
        );
    }

    function test_extremePriceScenarios(
        IStrategyInterface strategy,
        uint256 _amount
    ) public {
        TestParams memory params = _getTestParams(address(strategy));
        _amount = bound(
            _amount,
            params.minFuzzAmount,
            params.maxFuzzAmount / 10
        );

        // This test verifies the strategy doesn't break with current pool prices
        // In production, extreme prices could cause issues, but we test current state

        mintAndDepositIntoStrategy(strategy, user, _amount);

        vm.prank(keeper);
        strategy.tend();

        // Should successfully create position regardless of current price
        assertGt(
            ERC20(params.lp).balanceOf(address(strategy)),
            0,
            "Should create LP position with current price"
        );

        // Price calculations should not overflow or underflow
        uint256 lpValue = strategy.lpVaultInAsset();
        assertGt(lpValue, 0, "LP value calculation should work");

        uint256 totalAssets = strategy.estimatedTotalAsset();
        assertGt(totalAssets, 0, "Total assets calculation should work");
    }

    function test_zeroAmountHandling(IStrategyInterface strategy) public {
        _getTestParams(address(strategy));

        // All calculations should handle zero amounts gracefully
        assertEq(strategy.estimatedTotalAsset(), 0);
        assertEq(strategy.lpVaultInAsset(), 0);
        assertEq(strategy.availableWithdrawLimit(user), 0);

        // Should not revert on zero amounts
        vm.prank(keeper);
        strategy.tend(); // Should not do anything but shouldn't revert
    }

    function test_pairedTokenDiscountValuation(
        IStrategyInterface strategy,
        uint256 _amount
    ) public {
        TestParams memory params = _getTestParams(address(strategy));
        _amount = bound(_amount, params.minFuzzAmount, params.maxFuzzAmount);

        // Airdrop paired token to strategy
        uint256 pairedAmount = _amount / 2;

        // Adjust for decimal differences
        int256 decimalDiff = int256(params.assetDecimals) -
            int256(params.pairedAssetDecimals);
        if (decimalDiff > 0) {
            pairedAmount = pairedAmount / (10 ** uint256(decimalDiff));
        } else if (decimalDiff < 0) {
            pairedAmount = pairedAmount * (10 ** uint256(-decimalDiff));
        }

        if (pairedAmount == 0) pairedAmount = 1e6; // Minimum amount
        airdrop(params.pairedAsset, address(strategy), pairedAmount);

        // Get pool fee
        address poolAddress = ISushiMultiPositionLiquidityManager(params.lp)
            .pool();
        uint24 poolFee = IUniswapV3Pool(poolAddress).fee();

        // Test 1: Verify default discount
        uint256 valuationWithDefaultDiscount = strategy.estimatedTotalAsset();

        // Test 2: Set zero discount and compare
        vm.prank(management);
        strategy.setPairedTokenDiscountBps(0);

        uint256 valuationWithZeroDiscount = strategy.estimatedTotalAsset();

        // Valuation with zero discount should be higher than with default discount
        assertGt(
            valuationWithZeroDiscount,
            valuationWithDefaultDiscount,
            "Zero discount should give higher valuation"
        );

        // Test 3: Set max discount (10%)
        vm.prank(management);
        strategy.setPairedTokenDiscountBps(1000); // 10%

        uint256 valuationWithMaxDiscount = strategy.estimatedTotalAsset();

        // Valuation with max discount should be lower than default
        assertLt(
            valuationWithMaxDiscount,
            valuationWithDefaultDiscount,
            "Max discount should give lower valuation"
        );

        // Test 4: Verify the discount is being applied
        // The valuation should be between zero discount and max discount
        assertGt(
            valuationWithZeroDiscount,
            valuationWithDefaultDiscount,
            "Default discount should reduce valuation"
        );

        assertGt(
            valuationWithDefaultDiscount,
            valuationWithMaxDiscount,
            "Default discount should be less than max discount"
        );

        // Test 5: Verify discount calculation on paired token portion only
        // Get the paired token balance and its raw value
        params.pairedAsset.balanceOf(address(strategy));

        // Calculate expected discount = poolFee/100 + additionalDiscount
        uint256 expectedDiscountBps = poolFee / 100 + 50;

        // The difference between zero and default discount should approximately equal
        // the discount applied to the paired token value
        uint256 valueDifference = valuationWithZeroDiscount -
            valuationWithDefaultDiscount;
        uint256 expectedDifference = (valuationWithZeroDiscount *
            expectedDiscountBps) / 10000;

        // Use a percentage tolerance since we're only discounting the paired token portion
        uint256 tolerance = valuationWithZeroDiscount / 100; // 1% tolerance
        assertLe(
            valueDifference,
            expectedDifference + tolerance,
            "Discount should be applied correctly"
        );
    }

    function test_setPairedTokenDiscountBps_onlyManagement(
        IStrategyInterface strategy
    ) public {
        _getTestParams(address(strategy));

        vm.expectRevert("!management");
        strategy.setPairedTokenDiscountBps(100);

        vm.prank(management);
        strategy.setPairedTokenDiscountBps(100);
        assertEq(strategy.pairedTokenDiscountBps(), 100, "discount updated");
    }

    function test_setPairedTokenDiscountBps_maxLimit(
        IStrategyInterface strategy
    ) public {
        _getTestParams(address(strategy));

        // Should revert if discount > 1000 bps (10%)
        vm.prank(management);
        vm.expectRevert("!discount");
        strategy.setPairedTokenDiscountBps(1001);

        // Should work at exactly 1000 bps
        vm.prank(management);
        strategy.setPairedTokenDiscountBps(1000);
        assertEq(strategy.pairedTokenDiscountBps(), 1000, "max discount set");
    }

    function test_lpValuationWithDiscount(
        IStrategyInterface strategy,
        uint256 _amount
    ) public {
        TestParams memory params = _getTestParams(address(strategy));
        _amount = bound(_amount, params.minFuzzAmount, params.maxFuzzAmount);

        // Deposit and create LP position
        mintAndDepositIntoStrategy(strategy, user, _amount);
        vm.prank(keeper);
        strategy.tend();

        // Skip if no LP was created
        if (ERC20(params.lp).balanceOf(address(strategy)) == 0) return;

        // Test LP valuation with different discounts
        uint256 lpValueDefault = strategy.lpVaultInAsset();

        // Set zero discount
        vm.prank(management);
        strategy.setPairedTokenDiscountBps(0);
        uint256 lpValueNoDiscount = strategy.lpVaultInAsset();

        // LP value should be higher without discount (or equal if LP has only asset)
        assertGe(
            lpValueNoDiscount,
            lpValueDefault,
            "LP value without discount should be >= default"
        );

        // Set high discount
        vm.prank(management);
        strategy.setPairedTokenDiscountBps(500); // 5%
        uint256 lpValueHighDiscount = strategy.lpVaultInAsset();

        // LP value should be lower with high discount (or equal if LP has only asset)
        assertLe(
            lpValueHighDiscount,
            lpValueDefault,
            "LP value with high discount should be <= default"
        );
    }
}

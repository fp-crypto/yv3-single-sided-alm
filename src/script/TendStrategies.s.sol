// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import {console2 as console} from "forge-std/console2.sol";
import {Script} from "forge-std/Script.sol";
import {StrategyFactory} from "../StrategyFactory.sol";
import {ISushiMultiPositionLiquidityManager} from "../interfaces/steer/ISushiMultiPositionLiquidityManager.sol";
import {ERC20} from "../Strategy.sol";
import {IStrategyInterface} from "../interfaces/IStrategyInterface.sol";

contract TendStrategies is Script {
    address private signer = 0x787aba336583f4A1D4f8cBBFDFFD49f3a38De665;

    StrategyFactory factory =
        StrategyFactory(0xE59870870286Aec8e2e10e7A09d15D7113312f94);

    address[] strats;

    uint256 maxSwapValueUsd = 50_000;
    uint256 minAssetUsd = 2;
    uint16 pairedTokenDiscountBps = 5;

    bool arbMode = false;

    function run() public {
        //strats.push(0xb2f33a48F79cbc9d3f9b32FDA0cBC89cF67af0AC); // usdc-usdt usdt
        //strats.push(0xF0a8A393ABE6dC35E873FF795D013aDcc72604d2); // usdc-usdt usdc
        //strats.push(0x4d38547d24e607C7390717F22ae373529cffF90C); // vbWBTC-BTCK vbWBTC
        //strats.push(0x3e7236AA960155159A8d3D7303896Fc2A21D2154); // AUSD-vbUSDC AUSD
        //strats.push(0x1Ea30764fF9ceaCe69E55e9bf49eB37CdBa8e1De); // AUSD-vbUSDC vbUSDC
        //strats.push(0x38663f9A0e89eBc29A2906d355A0ab86964A0BAd); // weETH-vbETh 5bps
        strats.push(0x9cd74e38036691a3E64E859C0DB27A9Fe038410d); // vbWBTC-LBTC 5bps

        vm.startBroadcast(signer);

        if (arbMode) {
            for (uint256 i; i < strats.length; ++i) {
                IStrategyInterface strat = IStrategyInterface(strats[i]);
                ERC20 asset = ERC20(strat.asset());
                ERC20 pairedAsset = ERC20(getPairedToken(strat));
                console.log();

                printStrategyDetails(strat, asset, pairedAsset);
                if (strat.lpValueInAsset() <= strat.minAsset()) continue;
                if (strat.maxSwapValue() != 0) strat.setMaxSwapValue(0);
                strat.manualWithdrawFromLp(type(uint256).max);
                printStrategyDetails(strat, asset, pairedAsset);
            }
        }

        console.log("=======================\n");

        for (uint256 i; i < strats.length; ++i) {
            IStrategyInterface strat = IStrategyInterface(strats[i]);
            ERC20 asset = ERC20(strat.asset());
            ERC20 pairedAsset = ERC20(getPairedToken(strat));
            //address sushiPool = ISushiMultiPositionLiquidityManager(strat.STEER_LP()).pool();

            uint256 maxSwapValue;
            uint128 minAsset;
            uint256 decimals = asset.decimals();
            if (decimals == 6) {
                maxSwapValue = maxSwapValueUsd * 1e6;
                minAsset = minAsset * 1e6;
            } else if (decimals == 18) {
                maxSwapValue = (maxSwapValueUsd * 1e18) / 2_400;
                minAsset = (minAsset * 1e18) / 2_400;
            } else if (decimals == 8) {
                maxSwapValue = (maxSwapValueUsd * 1e8) / 100_000;
                minAsset = (minAsset * 1e8) / 100_000;
            }

            if (strat.pendingManagement() == signer) strat.acceptManagement();
            if (strat.keeper() != signer) strat.setKeeper(signer);

            if (strat.estimatedTotalAsset() == 0) {
                continue;
            }

            //console.log("depositLimit: %e", strat.depositLimit());
            //if (strat.depositLimit() != 10_000_000e6) {
            //    strat.setDepositLimit(10_000_000e6);
            //    continue;
            //}

            if (strat.targetIdleAssetBps() != 0) strat.setTargetIdleAssetBps(0);
            if (strat.maxSwapValue() != maxSwapValue)
                strat.setMaxSwapValue(maxSwapValue);
            if (strat.minAsset() != minAsset) strat.setMinAsset(minAsset);
            //if (strat.pairedTokenDiscountBps() != pairedTokenDiscountBps)
            //    strat.setPairedTokenDiscountBps(pairedTokenDiscountBps);

            printStrategyDetails(strat, asset, pairedAsset);
            if (
                asset.balanceOf(address(strat)) <= strat.minAsset() &&
                pairedAsset.balanceOf(address(strat)) <= strat.minAsset()
            ) continue;
            strat.tend();
            printStrategyDetails(strat, asset, pairedAsset);

            //if (strat.depositLimit() != 0) {
            //    strat.setDepositLimit(0);
            //}
        }

        vm.stopBroadcast();
    }

    function getPairedToken(
        IStrategyInterface strategy
    ) internal view returns (address) {
        ISushiMultiPositionLiquidityManager lp = ISushiMultiPositionLiquidityManager(
                strategy.STEER_LP()
            );
        address asset = strategy.asset();
        address token0 = lp.token0();
        address token1 = lp.token1();
        return asset == token1 ? token0 : token1;
    }

    function printStrategyDetails(
        IStrategyInterface strat,
        ERC20 asset,
        ERC20 pairedAsset
    ) internal view {
        uint256 totalAssets = strat.totalAssets();
        uint256 estimatedTotalAsset = strat.estimatedTotalAsset();

        console.log("Strat: %s", strat.name());
        console.log("Total assets: %e", totalAssets);
        console.log("ETA: %e", estimatedTotalAsset);
        console.log(
            "PnL: %e",
            int256(estimatedTotalAsset) - int256(totalAssets)
        );
        console.log(
            "PnL %: %d bps",
            ((int256(estimatedTotalAsset) - int256(totalAssets)) * 10000) /
                int256(totalAssets)
        );
        console.log("LP value: %e", strat.lpValueInAsset());
        console.log("Idle asset: %e", asset.balanceOf(address(strat)));
        console.log(
            "Idle paired asset: %e",
            pairedAsset.balanceOf(address(strat))
        );
    }
}

// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import {console2 as console} from "forge-std/console2.sol";
import {Script} from "forge-std/Script.sol";
import {StrategyFactory} from "../StrategyFactory.sol";
import {ISushiMultiPositionLiquidityManager} from "../interfaces/steer/ISushiMultiPositionLiquidityManager.sol";
import {ERC20} from "../Strategy.sol";
import {IStrategyInterface} from "../interfaces/IStrategyInterface.sol";
import {IAuction} from "../interfaces/IAuction.sol";

contract PrintStrategyDetails is Script {
    address private signer = 0x787aba336583f4A1D4f8cBBFDFFD49f3a38De665;

    StrategyFactory internal factory =
        StrategyFactory(0xE59870870286Aec8e2e10e7A09d15D7113312f94);

    address[] internal strats;

    function run() public {
        strats.push(0xb2f33a48F79cbc9d3f9b32FDA0cBC89cF67af0AC); // usdc-usdt usdt
        strats.push(0xF0a8A393ABE6dC35E873FF795D013aDcc72604d2); // usdc-usdt usdc
        strats.push(0x4d38547d24e607C7390717F22ae373529cffF90C); // vbWBTC-BTCK vbWBTC
        strats.push(0x3e7236AA960155159A8d3D7303896Fc2A21D2154); // AUSD-vbUSDC AUSD
        strats.push(0x1Ea30764fF9ceaCe69E55e9bf49eB37CdBa8e1De); // AUSD-vbUSDC vbUSDC
        strats.push(0x38663f9A0e89eBc29A2906d355A0ab86964A0BAd); // weETH-vbETh 5bps
        strats.push(0x9cd74e38036691a3E64E859C0DB27A9Fe038410d); // vbWBTC-LBTC 5bps

        for (uint256 i; i < strats.length; ++i) {
            IStrategyInterface strat = IStrategyInterface(strats[i]);
            ERC20 asset = ERC20(strat.asset());
            ERC20 pairedAsset = ERC20(getPairedToken(strat));

            console.log();
            console.log("=======================\n");
            printStrategyDetails(strat, asset, pairedAsset);
        }
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

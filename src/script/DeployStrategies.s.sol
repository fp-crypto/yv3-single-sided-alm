// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "forge-std/console.sol";
import {Script} from "forge-std/Script.sol";
import {CreateXScript, ICreateX} from "../../lib/createx-forge/script/CreateXScript.sol";
import {StrategyFactory} from "../StrategyFactory.sol";
import {ISushiMultiPositionLiquidityManager} from "../interfaces/steer/ISushiMultiPositionLiquidityManager.sol";
import {ERC20} from "../Strategy.sol";

contract DeployStrategies is Script {
    address private signer = 0x787aba336583f4A1D4f8cBBFDFFD49f3a38De665;

    StrategyFactory factory =
        StrategyFactory(0xE59870870286Aec8e2e10e7A09d15D7113312f94);

    address[] steerVaults;

    address[] newStrategies;

    function run() public {
        steerVaults.push(0x59719861Fc440A75D38202e5a297cFE68E149691); // vbUSDC-vbUSDT
        steerVaults.push(0xae3Be272487D86a07d0408FcEe718FB33F2ABf69); // AUSD-vbUSDT
        steerVaults.push(0x83aFE7CD638318410ce789581cae11DC8880e384); // weETH-vbETh
        steerVaults.push(0xB67EA549d2B72BA513cCB9734F0B12fc87f61B72); // vbWBTC-LBTC
        steerVaults.push(0x7413dfc9b4E60cd731C7D703ab032eB1A38E6eF8); // vbWBTC-BTCK
        steerVaults.push(0x8Dc76B0dcF92A1F5C163896F1D04557ef3DB21cE); // AUSD-vbUSDC
        steerVaults.push(0xb2D5bf32A55940b8469dA6887dEcC137C645f2BA); // weETH-vbETh 5bps
        steerVaults.push(0x433ebd9268a3B76413DbE94698bFdb589Ff95D8E); // vbWBTC-LBTC 5bps

        for (uint256 i; i < steerVaults.length; ++i) {
            ISushiMultiPositionLiquidityManager steerVault = ISushiMultiPositionLiquidityManager(
                    steerVaults[i]
                );

            address token0 = steerVault.token0();
            address token1 = steerVault.token1();
            uint256 decimals = ERC20(token0).decimals();
            uint128 minAsset = 0.001e6; // default for 6 decimal stable
            uint256 maxSwapValue = 1000e6; // default for 6 decimal stable

            if (decimals == 18) {
                minAsset = 0.001e18;
                maxSwapValue = 1e18;
            } else if (decimals == 8) {
                minAsset = 0.00002e8;
                maxSwapValue = 0.02e8;
            }

            vm.startBroadcast(signer);

            if (
                factory.getStrategyForAssetLpPair(
                    address(token0),
                    address(steerVault)
                ) == address(0)
            ) {
                newStrategies.push(
                    factory.newStrategy(
                        token0,
                        string.concat(
                            "Single Sided Steer ",
                            ERC20(token0).symbol(),
                            "-",
                            ERC20(token1).symbol(),
                            " ",
                            ERC20(token0).symbol()
                        ),
                        address(steerVault),
                        minAsset,
                        maxSwapValue
                    )
                );
            }

            if (
                factory.getStrategyForAssetLpPair(
                    address(token1),
                    address(steerVault)
                ) == address(0)
            ) {
                newStrategies.push(
                    factory.newStrategy(
                        token1,
                        string.concat(
                            "Single Sided Steer ",
                            ERC20(token0).symbol(),
                            "-",
                            ERC20(token1).symbol(),
                            " ",
                            ERC20(token1).symbol()
                        ),
                        address(steerVault),
                        minAsset,
                        maxSwapValue
                    )
                );
            }

            vm.stopBroadcast();
        }

        console.log("New Strategies:");
        for (uint i; i < newStrategies.length; ++i) {
            console.log(newStrategies[i]);
        }
    }
}

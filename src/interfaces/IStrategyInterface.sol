// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {IStrategy} from "@tokenized-strategy/interfaces/IStrategy.sol";

interface IStrategyInterface is IStrategy {
    function lpVaultInAsset()
        external
        view
        returns (uint256 valueLpInAssetTerms);

    function STEER_LP() external view returns (address);

    function uniswapV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata _data
    ) external;
    //TODO: Add your specific implementation interface in here.
}

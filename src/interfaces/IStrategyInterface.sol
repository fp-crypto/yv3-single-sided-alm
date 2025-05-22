// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {IStrategy} from "@tokenized-strategy/interfaces/IStrategy.sol";

interface IStrategyInterface is IStrategy {
    function lpVaultInAsset() external view returns (uint256 valueLpInAssetTerms);
    //TODO: Add your specific implementation interface in here.
}

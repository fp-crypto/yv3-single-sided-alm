// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {IBaseHealthCheck} from "@periphery/Bases/HealthCheck/IBaseHealthCheck.sol";
import {IMerklDistributor} from "./IMerklDistributor.sol";

interface IStrategyInterface is IBaseHealthCheck {
    function lpVaultInAsset()
        external
        view
        returns (uint256 valueLpInAssetTerms);

    function STEER_LP() external view returns (address);
    function MERKL_DISTRIBUTOR() external view returns (IMerklDistributor);

    function estimatedTotalAsset() external view returns (uint256);

    function uniswapV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata _data
    ) external;

    // Management parameters
    function targetIdleAssetBps() external view returns (uint16);
    function depositLimit() external view returns (uint256);
    function maxSwapValue() external view returns (uint256);
    function useAuctions() external view returns (bool);
    function auction() external view returns (address);
    function minTendWait() external view returns (uint24);
    function maxTendBaseFeeGwei() external view returns (uint8);
    function lastTend() external view returns (uint256);

    // Management functions
    function setAuction(address _auction) external;
    function setDepositLimit(uint256 _depositLimit) external;
    function setTargetIdleAssetBps(uint16 _targetIdleAssetBps) external;
    function setMaxSwapValue(uint256 _maxSwapValue) external;
    function setUseAuctions(bool _useAuctions) external;
    function setMinTendWait(uint24 _minTendWait) external;
    function setMaxTendBaseFee(uint8 _maxTendBaseFeeGwei) external;
    function manualSwapPairedTokenToAsset(uint256 _amount) external;
    function manualWithdrawFromLp(uint256 _amount) external;

    // Auction functions
    function kickAuction(address _from) external returns (uint256);
    function claim(
        address[] calldata users,
        address[] calldata tokens,
        uint256[] calldata amounts,
        bytes32[][] calldata proofs
    ) external;
}

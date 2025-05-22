// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {BaseStrategy, ERC20} from "@tokenized-strategy/BaseStrategy.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ISushiMultiPositionLiquidityManager} from "./interfaces/steer/ISushiMultiPositionLiquidityManager.sol";
import {IUniswapV3SwapCallback} from "@uniswap-v3-core/interfaces/callback/IUniswapV3SwapCallback.sol";

contract Strategy is BaseStrategy, IUniswapV3SwapCallback {
    using SafeERC20 for ERC20;

    ISushiMultiPositionLiquidityManager public immutable STEER_LP;

    address private immutable _POOL;
    address private immutable _OTHER_TOKEN;
    bool private immutable _ASSET_IS_TOKEN_0;

    constructor(
        address _asset,
        string memory _name,
        address _steerLP
    ) BaseStrategy(_asset, _name) {
        STEER_LP = ISushiMultiPositionLiquidityManager(_steerLP);
        _POOL = ISushiMultiPositionLiquidityManager(_steerLP).pool();
        address _token0 = ISushiMultiPositionLiquidityManager(_steerLP)
            .token0();
        if (address(asset) == _token0) {
            _ASSET_IS_TOKEN_0 = true;
            _OTHER_TOKEN = ISushiMultiPositionLiquidityManager(_steerLP)
                .token1();
        } else {
            _OTHER_TOKEN = _token0;
        }
    }

    /*//////////////////////////////////////////////////////////////
                NEEDED TO BE OVERRIDDEN BY STRATEGIST
    //////////////////////////////////////////////////////////////*/

    // @inheritdoc BaseStrategy
    function _deployFunds(uint256 _amount) internal override {
        // do nothing since a swap is required
    }

    // @inheritdoc BaseStrategy
    function _freeFunds(uint256 _amount) internal override {
        // do nothing since a swap is required
    }

    // @inheritdoc BaseStrategy
    function _harvestAndReport()
        internal
        override
        returns (uint256 _totalAssets)
    {
        // TODO: Implement harvesting logic and accurate accounting EX:
        _totalAssets = asset.balanceOf(address(this));
    }

    // @inheritdoc BaseStrategy
    // @dev only return the loose asset balance
    function availableWithdrawLimit(
        address /*_owner*/
    ) public view override returns (uint256) {
        return asset.balanceOf(address(this));
    }

    // @inheritdoc BaseStrategy
    function availableDepositLimit(
        address _owner
    ) public view override returns (uint256) {
        // TODO: come up with some heuristic
        return super.availableDepositLimit(_owner);
    }

    // @inheritdoc BaseStrategy
    function _tend(uint256 _totalIdle) internal override {
        // TODO: deposit in LP
        _depositInLp();
    }

    // @inheritdoc BaseStrategy
    function _tendTrigger() internal view override returns (bool) {}

    // @inheritdoc BaseStrategy
    function _emergencyWithdraw(uint256 _amount) internal override {}

    function _depositInLp() internal {
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 assetBalance = asset.balanceOf(address(this));
        if (_ASSET_IS_TOKEN_0) {
            amount0Desired = assetBalance;
        } else {
            amount1Desired = assetBalance;
        }
        STEER_LP.deposit(amount0Desired, amount1Desired, 0, 0, address(this));
    }

    function uniswapV3SwapCallback(
        int256 amount0Wanted,
        int256 amount1Wanted,
        bytes calldata data
    ) external {}
}

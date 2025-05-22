// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {BaseStrategy, ERC20} from "@tokenized-strategy/BaseStrategy.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ISushiMultiPositionLiquidityManager} from "./interfaces/steer/ISushiMultiPositionLiquidityManager.sol";
import {IUniswapV3SwapCallback} from "@uniswap-v3-core/interfaces/callback/IUniswapV3SwapCallback.sol";
import {IUniswapV3Pool} from "@uniswap-v3-core/interfaces/IUniswapV3Pool.sol";
import {FullMath} from "@uniswap-v3-core/libraries/FullMath.sol";

contract Strategy is BaseStrategy, IUniswapV3SwapCallback {
    using SafeERC20 for ERC20;

    ISushiMultiPositionLiquidityManager public immutable STEER_LP;

    address private immutable _POOL;
    address private immutable _OTHER_TOKEN;
    bool private immutable _ASSET_IS_TOKEN_0;

    // Q96 constant (2**96)
    uint256 private constant Q96 = 0x1000000000000000000000000;


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
        if (_totalIdle > 0) {
            _depositInLp();
        }
    }

    // @inheritdoc BaseStrategy
    function _tendTrigger() internal view override returns (bool) {}

    // @inheritdoc BaseStrategy
    function _emergencyWithdraw(uint256 _amount) internal override {}

    function _depositInLp() internal {
        uint256 assetBalance = asset.balanceOf(address(this));
        if (assetBalance == 0) {
            return;
        }

        (uint256 total0InLp, uint256 total1InLp) = STEER_LP.getTotalAmounts();
        (uint160 sqrtPriceX96, , , , , , ) = IUniswapV3Pool(_POOL).slot0();

        uint256 amountToSwap;

        if (total0InLp == 0 && total1InLp == 0) {
            // TODO: Implement fallback logic
        } else {
            if (_ASSET_IS_TOKEN_0) {
                // Asset is token0. We want to swap asset (token0) for _OTHER_TOKEN (token1).
                // Calculate value of total0 and total1 in LP in terms of token0.
                // value_total0_in_t0 = total0InLp
                // value_total1_in_t0 = total1InLp * price_token1_in_token0
                // price_token1_in_token0 = (sqrtPriceX96 / Q96)^2
                // So, value_total1_in_t0 = total1InLp * sqrtPriceX96^2 / Q96^2
                
                uint256 valueTotal0InLp_asToken0 = total0InLp; // Already in terms of token0
                uint256 valueTotal1InLp_asToken0 = FullMath.mulDiv(FullMath.mulDiv(total1InLp, sqrtPriceX96, Q96), sqrtPriceX96, Q96);

                uint256 totalLpValue_asToken0 = valueTotal0InLp_asToken0 + valueTotal1InLp_asToken0;
                
                if (totalLpValue_asToken0 == 0) { // Should ideally not happen if total0/total1 > 0 unless price is extreme
                    amountToSwap = assetBalance / 2; // Fallback
                } else {
                    // Proportion of value that should be token1 = valueTotal1InLp_asToken0 / totalLpValue_asToken0
                    amountToSwap = FullMath.mulDiv(assetBalance, valueTotal1InLp_asToken0, totalLpValue_asToken0);
                }
            } else {
                // Asset is token1. We want to swap asset (token1) for _OTHER_TOKEN (token0).
                // Calculate value of total0 and total1 in LP in terms of token1.
                // value_total1_in_t1 = total1InLp
                // value_total0_in_t1 = total0InLp * price_token0_in_token1
                // price_token0_in_token1 = (Q96 / sqrtPriceX96)^2
                // So, value_total0_in_t1 = total0InLp * Q96^2 / sqrtPriceX96^2

                uint256 valueTotal1InLp_asToken1 = total1InLp; // Already in terms of token1
                uint256 valueTotal0InLp_asToken1 = FullMath.mulDiv(FullMath.mulDiv(total0InLp, Q96, sqrtPriceX96), Q96, sqrtPriceX96);
                
                uint256 totalLpValue_asToken1 = valueTotal1InLp_asToken1 + valueTotal0InLp_asToken1;

                if (totalLpValue_asToken1 == 0) { // Fallback
                    amountToSwap = assetBalance / 2;
                } else {
                    // Proportion of value that should be token0 = valueTotal0InLp_asToken1 / totalLpValue_asToken1
                    amountToSwap = FullMath.mulDiv(assetBalance, valueTotal0InLp_asToken1, totalLpValue_asToken1);
                }
            }
        }
        
        if (amountToSwap > assetBalance) amountToSwap = assetBalance; // Cap swap amount
        if (amountToSwap == 0 && assetBalance > 0) { // No swap needed or possible, try to deposit as is
            asset.safeApprove(address(STEER_LP), 0);
            asset.safeApprove(address(STEER_LP), assetBalance);
            ERC20(_OTHER_TOKEN).safeApprove(address(STEER_LP), 0); 

            uint256 amount0ToDeposit;
            uint256 amount1ToDeposit;
            if (_ASSET_IS_TOKEN_0) {
                amount0ToDeposit = assetBalance;
                amount1ToDeposit = 0;
            } else {
                amount0ToDeposit = 0;
                amount1ToDeposit = assetBalance;
            }
            STEER_LP.deposit(amount0ToDeposit, amount1ToDeposit, 0, 0, address(this));
            return;
        }
         if (amountToSwap == 0 && assetBalance == 0) { // Should have been caught by initial check
             return;
        }


        asset.safeApprove(_POOL, 0);
        asset.safeApprove(_POOL, amountToSwap);

        bytes memory data = abi.encode(address(asset)); 

        if (_ASSET_IS_TOKEN_0) {
            IUniswapV3Pool(_POOL).swap(
                address(this), 
                true, 
                int256(amountToSwap), 
                sqrtPriceX96 - 1, 
                data
            );
        } else {
            IUniswapV3Pool(_POOL).swap(
                address(this), 
                false, 
                int256(amountToSwap), 
                sqrtPriceX96 + 1, 
                data
            );
        }

        uint256 remainingAssetBalance = asset.balanceOf(address(this));
        uint256 otherTokenBalance = ERC20(_OTHER_TOKEN).balanceOf(address(this));

        asset.safeApprove(address(STEER_LP), 0);
        asset.safeApprove(address(STEER_LP), remainingAssetBalance);
        ERC20(_OTHER_TOKEN).safeApprove(address(STEER_LP), 0);
        ERC20(_OTHER_TOKEN).safeApprove(address(STEER_LP), otherTokenBalance);

        uint256 amount0ToDeposit;
        uint256 amount1ToDeposit;

        if (_ASSET_IS_TOKEN_0) {
            amount0ToDeposit = remainingAssetBalance;
            amount1ToDeposit = otherTokenBalance;
        } else {
            amount0ToDeposit = otherTokenBalance;
            amount1ToDeposit = remainingAssetBalance;
        }
        
        STEER_LP.deposit(amount0ToDeposit, amount1ToDeposit, 0, 0, address(this));
    }

    function uniswapV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata _data
    ) external override {
        require(msg.sender == _POOL, "Strategy: Invalid caller");

        address tokenPaidByStrategy = abi.decode(_data, (address));
        require(tokenPaidByStrategy == address(asset), "Strategy: Callback token mismatch");

        if (_ASSET_IS_TOKEN_0) {
            // Asset is token0. Strategy sold asset (token0) for _OTHER_TOKEN (token1).
            // Pool expects payment of token0. amount0Delta is negative.
            require(amount0Delta < 0, "Strategy: amount0Delta should be negative");
            asset.safeTransfer(_POOL, uint256(-amount0Delta));
        } else {
            // Asset is token1. Strategy sold asset (token1) for _OTHER_TOKEN (token0).
            // Pool expects payment of token1. amount1Delta is negative.
            require(amount1Delta < 0, "Strategy: amount1Delta should be negative");
            asset.safeTransfer(_POOL, uint256(-amount1Delta));
        }
    }
}

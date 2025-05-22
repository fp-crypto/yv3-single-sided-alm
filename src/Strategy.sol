// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {BaseStrategy, ERC20} from "@tokenized-strategy/BaseStrategy.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ISushiMultiPositionLiquidityManager} from "./interfaces/steer/ISushiMultiPositionLiquidityManager.sol";
import {IUniswapV3SwapCallback} from "@uniswap-v3-core/interfaces/callback/IUniswapV3SwapCallback.sol";
import {IUniswapV3Pool} from "@uniswap-v3-core/interfaces/IUniswapV3Pool.sol";
import {FullMath} from "@uniswap-v3-core/libraries/FullMath.sol";
import {TickMath} from "@uniswap-v3-core/libraries/TickMath.sol";

contract Strategy is BaseStrategy, IUniswapV3SwapCallback {
    using SafeERC20 for ERC20;

    ISushiMultiPositionLiquidityManager public immutable STEER_LP;

    address private immutable _POOL;
    address private immutable _OTHER_TOKEN;
    bool private immutable _ASSET_IS_TOKEN_0;

    // Q96 constant (2**96)
    uint256 private constant Q96 = 0x1000000000000000000000000;

    struct SwapCallbackData {
        address tokenToPay;
        uint256 amountToPay; // The amount the strategy intends to pay
    }

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
        if (_amount == 0) return;
        uint256 availableAsset = asset.balanceOf(address(this));
        if (availableAsset >= _amount) {
            return;
        }
        uint256 neededFromLp = _amount - availableAsset;
        _withdrawFromLp(neededFromLp);
    }

    // @inheritdoc BaseStrategy
    function _harvestAndReport()
        internal
        override
        returns (uint256 _totalAssets)
    {
        // TODO: position adjustments?
        _totalAssets = asset.balanceOf(address(this)) + lpVaultInAsset();
    }

    /*//////////////////////////////////////////////////////////////
                    VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function lpVaultInAsset()
        public
        view
        returns (uint256 valueLpInAssetTerms)
    {
        uint256 myShares = STEER_LP.balanceOf(address(this));
        if (myShares == 0) return 0;

        (uint256 total0InLp, uint256 total1InLp) = STEER_LP.getTotalAmounts();
        uint256 totalLpShares = STEER_LP.totalSupply();
        if (totalLpShares == 0) return 0; // this should never happen

        uint256 myHoldingsToken0 = FullMath.mulDiv(
            myShares,
            total0InLp,
            totalLpShares
        );
        uint256 myHoldingsToken1 = FullMath.mulDiv(
            myShares,
            total1InLp,
            totalLpShares
        );
        (uint160 sqrtPriceX96, , , , , , ) = IUniswapV3Pool(_POOL).slot0();

        if (_ASSET_IS_TOKEN_0) { // asset is token0. Convert token1 to token0: myHoldingsToken1 / Price(token1/token0)
            uint256 valueMyToken1InAssetTerms = FullMath.mulDiv(
                FullMath.mulDiv(myHoldingsToken1, Q96, sqrtPriceX96), // Swapped logic
                Q96,
                sqrtPriceX96
            );
            valueLpInAssetTerms = myHoldingsToken0 + valueMyToken1InAssetTerms;
        } else { // asset is token1. Convert token0 to token1: myHoldingsToken0 * Price(token1/token0)
            uint256 valueMyToken0InAssetTerms = FullMath.mulDiv(
                FullMath.mulDiv(myHoldingsToken0, sqrtPriceX96, Q96), // Swapped logic
                sqrtPriceX96,
                Q96
            );
            valueLpInAssetTerms = myHoldingsToken1 + valueMyToken0InAssetTerms;
        }
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
    function _emergencyWithdraw(uint256 _amount) internal override {
        _withdrawFromLp(_amount);
    }

    function _calculateAmountToSwapForDeposit(
        uint256 assetBalance,
        uint256 total0InLp,
        uint256 total1InLp,
        uint160 sqrtPriceX96
    ) internal view returns (uint256 amountToSwap) {
        if (total0InLp == 0 && total1InLp == 0) {
            amountToSwap = assetBalance / 2; // Fallback: LP is empty, aim for a 50/50 value split by swapping half the asset.
        } else {
            uint256 valueLpHoldingOfOtherToken_inAssetTokenTerms;
            uint256 totalLpValue_inAssetTokenTerms;

            if (_ASSET_IS_TOKEN_0) {
                // Our asset is token0. The "other token" is token1.
                // Calculate value of LP's token1 holdings, in terms of token0 (our asset).
                // value = total1InLp / Price(token1/token0)
                valueLpHoldingOfOtherToken_inAssetTokenTerms = FullMath.mulDiv( // Swapped logic
                    FullMath.mulDiv(total1InLp, Q96, sqrtPriceX96),
                    Q96,
                    sqrtPriceX96
                );
                // Calculate total LP value in terms of token0 (our asset).
                totalLpValue_inAssetTokenTerms =
                    total0InLp +
                    valueLpHoldingOfOtherToken_inAssetTokenTerms;
            } else {
                // Our asset is token1. The "other token" is token0.
                // Calculate value of LP's token0 holdings, in terms of token1 (our asset).
                // value = total0InLp * Price(token1/token0)
                valueLpHoldingOfOtherToken_inAssetTokenTerms = FullMath.mulDiv( // Swapped logic
                    FullMath.mulDiv(total0InLp, sqrtPriceX96, Q96),
                    sqrtPriceX96,
                    Q96
                );
                // Calculate total LP value in terms of token1 (our asset).
                totalLpValue_inAssetTokenTerms =
                    total1InLp +
                    valueLpHoldingOfOtherToken_inAssetTokenTerms;
            }

            if (totalLpValue_inAssetTokenTerms == 0) {
                amountToSwap = assetBalance / 2; // Fallback: Total LP value is zero, aim for 50/50.
            } else {
                // Calculate how much of our asset to swap to get the "other token"
                // in proportion to its value representation in the LP.
                amountToSwap = FullMath.mulDiv(
                    assetBalance,
                    valueLpHoldingOfOtherToken_inAssetTokenTerms,
                    totalLpValue_inAssetTokenTerms
                );
            }
        }
    }

    function _depositInLp() internal {
        uint256 assetBalance = asset.balanceOf(address(this));
        if (assetBalance == 0) {
            return;
        }

        (uint256 total0InLp, uint256 total1InLp) = STEER_LP.getTotalAmounts();
        (uint160 sqrtPriceX96, , , , , , ) = IUniswapV3Pool(_POOL).slot0();

        uint256 amountToSwap = _calculateAmountToSwapForDeposit(
            assetBalance,
            total0InLp,
            total1InLp,
            sqrtPriceX96
        );

        if (amountToSwap > assetBalance) amountToSwap = assetBalance;

        uint256 assetBalanceForDeposit;
        uint256 otherTokenBalanceForDeposit;

        if (amountToSwap == 0) {
            // Assume _OTHER_TOKEN balance is 0 or irrelevant if not swapping.
            assetBalanceForDeposit = assetBalance;
            otherTokenBalanceForDeposit = ERC20(_OTHER_TOKEN).balanceOf(
                address(this)
            );
        } else {
            // asset.forceApprove(_POOL, amountToSwap);
            SwapCallbackData memory callbackData = SwapCallbackData(
                address(asset),
                amountToSwap
            );
            bytes memory data = abi.encode(callbackData);

            if (_ASSET_IS_TOKEN_0) {
                IUniswapV3Pool(_POOL).swap(
                    address(this),
                    true, // zeroForOne: true (selling asset (token0) for _OTHER_TOKEN (token1))
                    int256(amountToSwap),
                    sqrtPriceX96 - 1, // Price limit for selling token0
                    data
                );
            } else {
                IUniswapV3Pool(_POOL).swap(
                    address(this),
                    false, // zeroForOne: false (selling asset (token1) for _OTHER_TOKEN (token0))
                    int256(amountToSwap),
                    sqrtPriceX96 + 1, // Price limit for selling token1
                    data
                );
            }
            assetBalanceForDeposit = asset.balanceOf(address(this));
            otherTokenBalanceForDeposit = ERC20(_OTHER_TOKEN).balanceOf(
                address(this)
            );
        }

        asset.forceApprove(address(STEER_LP), assetBalanceForDeposit);
        ERC20(_OTHER_TOKEN).forceApprove(
            address(STEER_LP),
            otherTokenBalanceForDeposit
        );

        uint256 amount0ToDeposit;
        uint256 amount1ToDeposit;

        if (_ASSET_IS_TOKEN_0) {
            amount0ToDeposit = assetBalanceForDeposit;
            amount1ToDeposit = otherTokenBalanceForDeposit;
        } else {
            amount0ToDeposit = otherTokenBalanceForDeposit;
            amount1ToDeposit = assetBalanceForDeposit;
        }

        STEER_LP.deposit(
            amount0ToDeposit,
            amount1ToDeposit,
            0,
            0,
            address(this)
        );
    }

    function _withdrawFromLp(uint256 _amountAssetToWithdraw) internal {
        if (_amountAssetToWithdraw == 0) return;

        uint256 myShares = STEER_LP.balanceOf(address(this));
        if (myShares == 0) return;

        uint256 totalValueOfMyHoldingsInAssetTerms = lpVaultInAsset();
        if (totalValueOfMyHoldingsInAssetTerms == 0) return;

        uint256 sharesToWithdraw;
        if (_amountAssetToWithdraw >= totalValueOfMyHoldingsInAssetTerms) {
            sharesToWithdraw = myShares;
        } else {
            sharesToWithdraw = FullMath.mulDiv(
                _amountAssetToWithdraw,
                myShares,
                totalValueOfMyHoldingsInAssetTerms
            );
        }

        if (sharesToWithdraw == 0) return;

        uint256 otherTokenBalanceBeforeWithdraw = ERC20(_OTHER_TOKEN).balanceOf(
            address(this)
        );

        STEER_LP.withdraw(sharesToWithdraw, 0, 0, address(this));

        uint256 otherTokenReceivedFromLp = ERC20(_OTHER_TOKEN).balanceOf(
            address(this)
        ) - otherTokenBalanceBeforeWithdraw;

        if (otherTokenReceivedFromLp > 0) {
            SwapCallbackData memory callbackData = SwapCallbackData(
                address(_OTHER_TOKEN),
                otherTokenReceivedFromLp
            );
            bytes memory data = abi.encode(callbackData);

            if (_ASSET_IS_TOKEN_0) {
                // Selling _OTHER_TOKEN (token1) for asset (token0)
                IUniswapV3Pool(_POOL).swap(
                    address(this),
                    false, // zeroForOne is false (token1 -> token0)
                    int256(otherTokenReceivedFromLp),
                    TickMath.MIN_SQRT_RATIO + 1, // Price limit for selling token1 for token0
                    data
                );
            } else {
                // Selling _OTHER_TOKEN (token0) for asset (token1)
                IUniswapV3Pool(_POOL).swap(
                    address(this),
                    true, // zeroForOne is true (token0 -> token1)
                    int256(otherTokenReceivedFromLp),
                    TickMath.MAX_SQRT_RATIO - 1, // Price limit for selling token0 for token1
                    data
                );
            }
        }
    }

    // @inheritdoc IUniswapV3SwapCallback
    function uniswapV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata _data
    ) external override {
        require(msg.sender == _POOL, "Strategy: Invalid caller");

        SwapCallbackData memory cbData = abi.decode(_data, (SwapCallbackData));
        uint256 actualAmountPaidByStrategy;

        if (_ASSET_IS_TOKEN_0) {
            // asset is token0, _OTHER_TOKEN is token1
            if (cbData.tokenToPay == address(asset)) {
                // Paying token0 (asset)
                require(
                    amount0Delta < 0,
                    "Strategy: amount0Delta should be < 0 for asset payment"
                );
                actualAmountPaidByStrategy = uint256(-amount0Delta);
            } else if (cbData.tokenToPay == _OTHER_TOKEN) {
                // Paying token1 (_OTHER_TOKEN)
                require(
                    amount1Delta < 0,
                    "Strategy: amount1Delta should be < 0 for other token payment"
                );
                actualAmountPaidByStrategy = uint256(-amount1Delta);
            } else {
                revert("Strategy: Invalid tokenToPay in callback");
            }
        } else {
            // asset is token1, _OTHER_TOKEN is token0
            if (cbData.tokenToPay == address(asset)) {
                // Paying token1 (asset)
                require(
                    amount1Delta < 0,
                    "Strategy: amount1Delta should be < 0 for asset payment"
                );
                actualAmountPaidByStrategy = uint256(-amount1Delta);
            } else if (cbData.tokenToPay == _OTHER_TOKEN) {
                // Paying token0 (_OTHER_TOKEN)
                require(
                    amount0Delta < 0,
                    "Strategy: amount0Delta should be < 0 for other token payment"
                );
                actualAmountPaidByStrategy = uint256(-amount0Delta);
            } else {
                revert("Strategy: Invalid tokenToPay in callback");
            }
        }

        require(
            actualAmountPaidByStrategy == cbData.amountToPay,
            "Strategy: Paid amount mismatch"
        );
        ERC20(cbData.tokenToPay).safeTransfer(
            _POOL,
            actualAmountPaidByStrategy
        );
    }
}

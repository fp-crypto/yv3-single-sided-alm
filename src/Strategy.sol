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
    uint256 private immutable _ASSET_DECIMALS;
    uint256 private immutable _OTHER_TOKEN_DECIMALS;

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
        _ASSET_DECIMALS = asset.decimals();
        _OTHER_TOKEN_DECIMALS = ERC20(_OTHER_TOKEN).decimals();
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
        _totalAssets = estimatedTotalAsset();
    }

    /*//////////////////////////////////////////////////////////////
                    VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function estimatedTotalAsset() public view returns (uint256) {
        uint256 _assetBalance = asset.balanceOf(address(this));
        uint256 _otherTokenBalance = ERC20(_OTHER_TOKEN).balanceOf(
            address(this)
        );
        uint256 _otherTokenBalanceInAsset = _valueOfOtherTokenInAsset(
            _otherTokenBalance
        );
        uint256 _lpBalanceInAsset = lpVaultInAsset();
        return _assetBalance + _otherTokenBalanceInAsset + _lpBalanceInAsset;
    }

    /**
     * @notice Calculates the total value of the strategy's holdings in the Steer LP,
     *         denominated in the strategy's underlying asset.
     * @dev This function considers the strategy's share of both token0 and token1
     *      in the LP and converts their value to the asset's denomination using the
     *      current pool price.
     * @return valueLpInAssetTerms The total value of LP holdings in terms of the asset.
     */
    function lpVaultInAsset()
        public
        view
        returns (uint256 valueLpInAssetTerms)
    {
        uint256 balanceOfLpShares = STEER_LP.balanceOf(address(this));
        if (balanceOfLpShares == 0) return 0;

        (uint256 total0InLp, uint256 total1InLp) = STEER_LP.getTotalAmounts();
        uint256 totalLpShares = STEER_LP.totalSupply();
        if (totalLpShares == 0) return 0; // this should never happen

        uint256 balanceOfToken0InLp = FullMath.mulDiv(
            balanceOfLpShares,
            total0InLp,
            totalLpShares
        );
        uint256 balanceOfToken1InLp = FullMath.mulDiv(
            balanceOfLpShares,
            total1InLp,
            totalLpShares
        );
        (uint160 sqrtPriceX96, , , , , , ) = IUniswapV3Pool(_POOL).slot0();
        uint256 valueOtherTokenInAsset;

        if (_ASSET_IS_TOKEN_0) {
            // asset is token0 (e.g., USDC). Other is token1 (e.g., DAI).
            valueOtherTokenInAsset = _valueOfOtherTokenInAsset(
                balanceOfToken1InLp,
                sqrtPriceX96
            );
            valueLpInAssetTerms = balanceOfToken0InLp + valueOtherTokenInAsset;
        } else {
            // asset is token1 (e.g., DAI). Other is token0 (e.g., USDC).
            valueOtherTokenInAsset = _valueOfOtherTokenInAsset(
                balanceOfToken0InLp,
                sqrtPriceX96
            );
            valueLpInAssetTerms = balanceOfToken1InLp + valueOtherTokenInAsset;
        }
    }

    function _valueOfOtherTokenInAsset(
        uint256 amountOfOtherToken
    ) internal view returns (uint256 value) {
        if (amountOfOtherToken == 0) return 0;
        (uint160 sqrtPriceX96, , , , , , ) = IUniswapV3Pool(_POOL).slot0();
        return _valueOfOtherTokenInAsset(amountOfOtherToken, sqrtPriceX96);
    }

    /**
     * @notice Calculates the value of a given amount of the "other token" (not the strategy's asset)
     *         in terms of the strategy's underlying asset.
     * @dev This function uses the provided sqrtPriceX96 to convert the value of the other token
     *      to the asset's denomination, accounting for decimal differences.
     * @param amountOfOtherToken The amount of the other token.
     * @param sqrtPriceX96 The current sqrt price (Q64.96) of the Uniswap V3 pool.
     * @return value The calculated value in terms of the strategy's asset.
     */
    function _valueOfOtherTokenInAsset(
        uint256 amountOfOtherToken,
        uint160 sqrtPriceX96
    ) internal view returns (uint256 value) {
        if (amountOfOtherToken == 0) return 0;
        if (_ASSET_IS_TOKEN_0) {
            // asset is token0. Other is token1.
            // value is value of otherToken (token1) holdings in asset (token0) terms (unscaled)
            // Convert token1 to token0: amount1 * (Q96^2 / sqrtPriceX96^2)
            value = FullMath.mulDiv(
                amountOfOtherToken,
                Q96,
                FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, Q96)
            );
        } else {
            // asset is token1. Other is token0.
            // value is value of otherToken (token0) holdings in asset (token1) terms (unscaled)
            value = FullMath.mulDiv(
                FullMath.mulDiv(amountOfOtherToken, sqrtPriceX96, Q96),
                sqrtPriceX96,
                Q96
            );
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

    /**
     * @notice Calculates the amount of the strategy's asset to swap to achieve a balanced
     *         deposit into the Uniswap V3 LP, based on the current LP composition.
     * @dev If the LP is empty, it aims for a 50/50 value split by swapping half the asset.
     *      Otherwise, it calculates the swap amount to match the LP's current token value ratio.
     * @param assetBalance The current balance of the strategy's asset available for deposit.
     * @param total0InLp The total amount of token0 in the Uniswap V3 LP.
     * @param total1InLp The total amount of token1 in the Uniswap V3 LP.
     * @param sqrtPriceX96 The current sqrt price (Q64.96) of the Uniswap V3 pool.
     * @return amountToSwap The calculated amount of asset to swap.
     */
    function _calculateAmountToSwapForDeposit(
        uint256 assetBalance,
        uint256 total0InLp,
        uint256 total1InLp,
        uint160 sqrtPriceX96
    ) internal view returns (uint256 amountToSwap) {
        if (total0InLp == 0 && total1InLp == 0) {
            amountToSwap = assetBalance / 2; // Fallback: LP is empty, aim for a 50/50 value split by swapping half the asset.
        } else {
            uint256 otherTokenValueInAsset;
            uint256 totalLpValueInAsset;

            if (_ASSET_IS_TOKEN_0) {
                // Asset is token0. Other token is token1.
                // otherTokenValueInAsset is value of LP's token1 holdings, in terms of token0 (asset), unscaled.
                // Convert token1 to token0: amount1 * (Q96^2 / sqrtPriceX96^2)
                otherTokenValueInAsset = FullMath.mulDiv(
                    total1InLp,
                    Q96,
                    FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, Q96)
                );
                // total0InLp is already in asset's (token0) decimals.
                totalLpValueInAsset = total0InLp + otherTokenValueInAsset;
            } else {
                // Asset is token1. Other token is token0.
                // otherTokenValueInAsset is value of LP's token0 holdings, in terms of token1 (asset), unscaled.
                otherTokenValueInAsset = FullMath.mulDiv(
                    FullMath.mulDiv(total0InLp, sqrtPriceX96, Q96),
                    sqrtPriceX96,
                    Q96
                );
                // total1InLp is already in asset's (token1) decimals.
                totalLpValueInAsset = total1InLp + otherTokenValueInAsset;
            }

            if (totalLpValueInAsset == 0) {
                amountToSwap = assetBalance / 2; // Fallback: Total LP value is zero, aim for 50/50.
            } else {
                // Calculate how much of our asset to swap to get the "other token"
                // in proportion to its value representation in the LP.
                amountToSwap = FullMath.mulDiv(
                    assetBalance,
                    otherTokenValueInAsset,
                    totalLpValueInAsset
                );
            }
        }
    }

    /**
     * @notice Deposits assets into the Steer LP.
     * @dev This function first calculates the optimal amount of the strategy's asset to swap
     *      to achieve a balanced deposit. It then performs the swap (if necessary) and
     *      deposits both the remaining asset and the acquired other token into the Steer LP.
     */
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
                    TickMath.MIN_SQRT_RATIO + 1, // Price limit for selling token0 for token1
                    data
                );
            } else {
                IUniswapV3Pool(_POOL).swap(
                    address(this),
                    false, // zeroForOne: false (selling asset (token1) for _OTHER_TOKEN (token0))
                    int256(amountToSwap),
                    TickMath.MAX_SQRT_RATIO - 1, // Price limit for selling token1 for token0
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

    /**
     * @notice Withdraws a specified amount of the strategy's asset from the Steer LP.
     * @dev Calculates the number of LP shares to withdraw based on the desired asset amount.
     *      After withdrawing from the Steer LP, if any "other token" is received,
     *      it is swapped back to the strategy's asset.
     * @param assetToWithdraw The amount of the strategy's asset to withdraw from the LP.
     */
    function _withdrawFromLp(uint256 assetToWithdraw) internal {
        if (assetToWithdraw == 0) return;

        uint256 balanceOfLpShares = STEER_LP.balanceOf(address(this));
        if (balanceOfLpShares == 0) return;

        uint256 lpValueInAsset = lpVaultInAsset();
        if (lpValueInAsset == 0) return;

        uint256 sharesToWithdraw;
        if (assetToWithdraw >= lpValueInAsset) {
            sharesToWithdraw = balanceOfLpShares;
        } else {
            sharesToWithdraw = FullMath.mulDiv(
                assetToWithdraw,
                balanceOfLpShares,
                lpValueInAsset
            );
        }

        if (sharesToWithdraw == 0) return;

        uint256 otherTokenBalanceBefore = ERC20(_OTHER_TOKEN).balanceOf(
            address(this)
        );

        STEER_LP.withdraw(sharesToWithdraw, 0, 0, address(this));

        uint256 otherTokenFromLp = ERC20(_OTHER_TOKEN).balanceOf(
            address(this)
        ) - otherTokenBalanceBefore;

        if (otherTokenFromLp > 0) {
            SwapCallbackData memory callbackData = SwapCallbackData( // Renamed cbData to callbackData
                address(_OTHER_TOKEN),
                otherTokenFromLp
            );
            bytes memory data = abi.encode(callbackData); // Use renamed callbackData

            if (_ASSET_IS_TOKEN_0) {
                // Selling _OTHER_TOKEN (token1) for asset (token0)
                IUniswapV3Pool(_POOL).swap(
                    address(this),
                    false, // zeroForOne is false (token1 -> token0)
                    int256(otherTokenFromLp),
                    TickMath.MAX_SQRT_RATIO - 1, // Price limit for selling token1 for token0
                    data
                );
            } else {
                // Selling _OTHER_TOKEN (token0) for asset (token1)
                IUniswapV3Pool(_POOL).swap(
                    address(this),
                    true, // zeroForOne is true (token0 -> token1)
                    int256(otherTokenFromLp),
                    TickMath.MIN_SQRT_RATIO + 1, // Price limit for selling token0 for token1
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

        SwapCallbackData memory callbackData = abi.decode(
            _data,
            (SwapCallbackData)
        );
        uint256 amountPaid;

        if (_ASSET_IS_TOKEN_0) {
            // asset is token0, _OTHER_TOKEN is token1
            if (callbackData.tokenToPay == address(asset)) {
                // Paying token0 (asset) to pool
                require(amount0Delta > 0, "S: T0 pay, T0 delta !>0"); // Pool received token0
                amountPaid = uint256(amount0Delta);
                require(amount1Delta < 0, "S: T0 pay, T1 delta !<0"); // Pool sent token1
            } else if (callbackData.tokenToPay == _OTHER_TOKEN) {
                // Paying token1 (_OTHER_TOKEN) to pool
                require(amount1Delta > 0, "S: T1 pay, T1 delta !>0"); // Pool received token1
                amountPaid = uint256(amount1Delta);
                require(amount0Delta < 0, "S: T1 pay, T0 delta !<0"); // Pool sent token0
            } else {
                revert("Strategy: Invalid tokenToPay in callback");
            }
        } else {
            // asset is token1, _OTHER_TOKEN is token0
            if (callbackData.tokenToPay == address(asset)) {
                // Paying token1 (asset) to pool
                require(amount1Delta > 0, "S: T1 pay, T1 delta !>0"); // Pool received token1
                amountPaid = uint256(amount1Delta);
                require(amount0Delta < 0, "S: T1 pay, T0 delta !<0"); // Pool sent token0
            } else if (callbackData.tokenToPay == _OTHER_TOKEN) {
                // Paying token0 (_OTHER_TOKEN) to pool
                require(amount0Delta > 0, "S: T0 pay, T0 delta !>0"); // Pool received token0
                amountPaid = uint256(amount0Delta);
                require(amount1Delta < 0, "S: T0 pay, T1 delta !<0"); // Pool sent token1
            } else {
                revert("Strategy: Invalid tokenToPay in callback");
            }
        }

        require(
            amountPaid == callbackData.amountToPay,
            "Strategy: Paid amount mismatch"
        );
        ERC20(callbackData.tokenToPay).safeTransfer(_POOL, amountPaid);
    }
}

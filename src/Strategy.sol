// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {BaseHealthCheck, ERC20} from "@periphery/Bases/HealthCheck/BaseHealthCheck.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ISushiMultiPositionLiquidityManager} from "./interfaces/steer/ISushiMultiPositionLiquidityManager.sol";
import {IUniswapV3SwapCallback} from "@uniswap-v3-core/interfaces/callback/IUniswapV3SwapCallback.sol";
import {IUniswapV3Pool} from "@uniswap-v3-core/interfaces/IUniswapV3Pool.sol";
import {FullMath} from "@uniswap-v3-core/libraries/FullMath.sol";
import {TickMath} from "@uniswap-v3-core/libraries/TickMath.sol";
import {IAuction} from "./interfaces/IAuction.sol";
import {IMerklDistributor} from "./interfaces/IMerklDistributor.sol";

contract Strategy is BaseHealthCheck, IUniswapV3SwapCallback {
    using SafeERC20 for ERC20;

    /*//////////////////////////////////////////////////////////////
                            CONSTANTS
    //////////////////////////////////////////////////////////////*/

    // Q96 constant (2**96)
    uint256 private constant Q96 = 0x1000000000000000000000000;

    /// @notice The Merkl Distributor contract for claiming rewards
    IMerklDistributor public constant MERKL_DISTRIBUTOR =
        IMerklDistributor(0x3Ef3D8bA38EBe18DB133cEc108f4D14CE00Dd9Ae);

    /*//////////////////////////////////////////////////////////////
                          IMMUTABLE VARIABLES
    //////////////////////////////////////////////////////////////*/

    ISushiMultiPositionLiquidityManager public immutable STEER_LP;
    address private immutable _POOL;
    address private immutable _PAIRED_TOKEN;
    bool private immutable _ASSET_IS_TOKEN_0;
    uint256 private immutable _ASSET_DECIMALS;
    uint256 private immutable _PAIRED_TOKEN_DECIMALS;

    /*//////////////////////////////////////////////////////////////
                          STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Flag to enable using auctions for token swaps
    bool public useAuctions;

    /// @notice Address of the auction contract used for token swaps
    address public auction;

    /// @notice Target idle asset in basis points
    uint16 public targetIdleAssetBps;

    /// @notice Buffer for target idle asset in basis points (e.g., 1000 = 10% buffer)
    uint16 public targetIdleBufferBps = 1000; // 10% default

    /// @notice Additional discount applied to paired token valuations in basis points
    uint16 public pairedTokenDiscountBps = 50; // 0.5% default

    /// @notice Maximum acceptable base fee for tends in gwei
    uint8 public maxTendBaseFeeGwei = 100;

    /// @notice Minimum wait time between tends in seconds
    uint24 public minTendWait = 5 minutes;

    /// @notice Timestamp of the last tend
    uint64 public lastTend;

    /// @notice Minimum asset amount for any operation (dust threshold)
    uint128 public minAsset;

    /// @notice The strategy deposit limit
    uint256 public depositLimit = type(uint256).max;

    /// @notice Maximum value that can be swapped in a single transaction (in asset terms)
    uint256 public maxSwapValue = type(uint256).max;

    /*//////////////////////////////////////////////////////////////
                              STRUCTS
    //////////////////////////////////////////////////////////////*/

    struct SwapCallbackData {
        address tokenToPay;
        uint256 amountToPay;
    }

    constructor(
        address _asset,
        string memory _name,
        address _steerLP
    ) BaseHealthCheck(_asset, _name) {
        require(_steerLP != address(0), "!0");
        STEER_LP = ISushiMultiPositionLiquidityManager(_steerLP);
        _POOL = ISushiMultiPositionLiquidityManager(_steerLP).pool();
        address _token0 = ISushiMultiPositionLiquidityManager(_steerLP)
            .token0();
        address _token1 = ISushiMultiPositionLiquidityManager(_steerLP)
            .token1();
        if (address(asset) == _token0) {
            _ASSET_IS_TOKEN_0 = true;
            _PAIRED_TOKEN = _token1;
        } else {
            require(address(asset) == _token1, "!asset");
            _PAIRED_TOKEN = _token0;
        }
        _ASSET_DECIMALS = asset.decimals();
        _PAIRED_TOKEN_DECIMALS = ERC20(_PAIRED_TOKEN).decimals();
    }

    /*//////////////////////////////////////////////////////////////
                         BASE STRATEGY OVERRIDES
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
        // TODO: position adjustments?
        _totalAssets = estimatedTotalAsset();
    }

    // @inheritdoc BaseStrategy
    function _tend(uint256 _totalIdle) internal override {
        uint256 _targetIdleAssetBps = uint256(targetIdleAssetBps);
        uint256 _minAsset = uint256(minAsset);

        if (_targetIdleAssetBps > 0) {
            // We have a target idle, check if we need to rebalance
            uint256 totalAssets = TokenizedStrategy.totalAssets();
            uint256 targetIdleAmount = (totalAssets * _targetIdleAssetBps) /
                MAX_BPS;

            if (_totalIdle > targetIdleAmount) {
                // Check if excess is above minAsset threshold
                uint256 excess = _totalIdle - targetIdleAmount;
                if (excess >= _minAsset) {
                    _depositInLp();
                }
            } else if (_totalIdle < targetIdleAmount) {
                // Check if deficit is above minAsset threshold
                uint256 deficit = targetIdleAmount - _totalIdle;
                if (deficit >= _minAsset) {
                    _withdrawFromLp(deficit);
                }
            }
        } else if (_totalIdle >= _minAsset) {
            // No target set, deposit idle assets if above threshold
            _depositInLp();
        }

        lastTend = uint64(block.timestamp);
    }

    // @inheritdoc BaseStrategy
    function _tendTrigger() internal view override returns (bool) {
        // Check if minimum wait time has passed
        if (block.timestamp < lastTend + uint256(minTendWait)) {
            return false;
        }

        // Check if base fee is acceptable
        if (block.basefee > uint256(maxTendBaseFeeGwei) * 1 gwei) {
            return false;
        }

        // Get current idle assets
        uint256 idleAsset = asset.balanceOf(address(this));

        // If target idle is set, check if we need to rebalance
        uint256 _targetIdleAssetBps = uint256(targetIdleAssetBps);
        if (_targetIdleAssetBps > 0) {
            uint256 totalAssets = TokenizedStrategy.totalAssets();
            uint256 targetIdleAmount = (totalAssets * _targetIdleAssetBps) /
                MAX_BPS;

            // Calculate bounds using configurable buffer
            uint256 bufferAmount = (targetIdleAmount *
                uint256(targetIdleBufferBps)) / MAX_BPS;
            uint256 upperBound = targetIdleAmount + bufferAmount;
            uint256 lowerBound = targetIdleAmount > bufferAmount
                ? targetIdleAmount - bufferAmount
                : 0;

            // Trigger if we're outside the acceptable range
            // Let _tend handle minAsset checks
            return idleAsset > upperBound || idleAsset < lowerBound;
        }

        // If no target is set, only trigger if we have idle assets
        // Let _tend handle minAsset checks
        return idleAsset > 0;
    }

    // @inheritdoc BaseStrategy
    function _emergencyWithdraw(uint256 _amount) internal override {
        _withdrawFromLp(_amount);
    }

    // @inheritdoc BaseStrategy
    // Only return the loose asset balance
    function availableWithdrawLimit(
        address /*_owner*/
    ) public view override returns (uint256) {
        return asset.balanceOf(address(this));
    }

    // @inheritdoc BaseStrategy
    function availableDepositLimit(
        address _owner
    ) public view override returns (uint256) {
        uint256 baseLimit = super.availableDepositLimit(_owner);
        uint256 currentAssets = TokenizedStrategy.totalAssets();

        if (currentAssets >= depositLimit) {
            return 0;
        }

        uint256 remainingCapacity = depositLimit - currentAssets;
        return baseLimit < remainingCapacity ? baseLimit : remainingCapacity;
    }

    /*//////////////////////////////////////////////////////////////
                         VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Estimates the total value of all strategy holdings in asset terms
     * @return Total estimated value including loose tokens and LP positions
     * @dev Sums loose asset balance, paired token value, and LP position value
     *      all denominated in the strategy's primary asset
     */
    function estimatedTotalAsset() public view returns (uint256) {
        uint256 _assetBalance = asset.balanceOf(address(this));
        uint256 _pairedTokenBalance = ERC20(_PAIRED_TOKEN).balanceOf(
            address(this)
        );
        uint256 _pairedTokenBalanceInAsset = _valueOfPairedTokenInAsset(
            _pairedTokenBalance
        );
        uint256 _lpBalanceInAsset = lpVaultInAsset();
        return _assetBalance + _pairedTokenBalanceInAsset + _lpBalanceInAsset;
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
        if (totalLpShares == 0) return 0;

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
        uint256 valuePairedTokenInAsset;

        if (_ASSET_IS_TOKEN_0) {
            valuePairedTokenInAsset = _valueOfPairedTokenInAsset(
                balanceOfToken1InLp,
                sqrtPriceX96
            );
            valueLpInAssetTerms = balanceOfToken0InLp + valuePairedTokenInAsset;
        } else {
            valuePairedTokenInAsset = _valueOfPairedTokenInAsset(
                balanceOfToken0InLp,
                sqrtPriceX96
            );
            valueLpInAssetTerms = balanceOfToken1InLp + valuePairedTokenInAsset;
        }
    }

    /**
     * @notice Calculates the value of the paired token in terms of the strategy's asset using current pool price.
     * @param amountOfPairedToken The amount of the paired token
     * @return value The calculated value in terms of the strategy's asset
     */
    function _valueOfPairedTokenInAsset(
        uint256 amountOfPairedToken
    ) internal view returns (uint256 value) {
        if (amountOfPairedToken == 0) return 0;
        (uint160 sqrtPriceX96, , , , , , ) = IUniswapV3Pool(_POOL).slot0();
        return _valueOfPairedTokenInAsset(amountOfPairedToken, sqrtPriceX96);
    }

    /**
     * @notice Calculates the value of the paired token in terms of the strategy's asset.
     * @param amountOfPairedToken The amount of the paired token
     * @param sqrtPriceX96 The current sqrt price (Q64.96) of the Uniswap V3 pool
     * @return value The calculated value in terms of the strategy's asset
     */
    function _valueOfPairedTokenInAsset(
        uint256 amountOfPairedToken,
        uint160 sqrtPriceX96
    ) internal view returns (uint256 value) {
        if (amountOfPairedToken == 0) return 0;

        // Get raw value without discount
        value = _valueOfPairedTokenInAssetRaw(
            amountOfPairedToken,
            sqrtPriceX96
        );

        // Apply discount for pool fee + additional discount
        uint24 poolFee = IUniswapV3Pool(_POOL).fee(); // e.g., 3000 = 0.3%
        uint256 totalDiscountBps = poolFee /
            100 +
            uint256(pairedTokenDiscountBps); // Convert fee to bps

        // Apply discount: value * (10000 - totalDiscountBps) / 10000
        value = (value * (MAX_BPS - totalDiscountBps)) / MAX_BPS;
    }

    /**
     * @notice Calculates the raw value of the paired token without any discounts.
     * @param amountOfPairedToken The amount of the paired token
     * @param sqrtPriceX96 The current sqrt price (Q64.96) of the Uniswap V3 pool
     * @return value The raw calculated value in terms of the strategy's asset
     */
    function _valueOfPairedTokenInAssetRaw(
        uint256 amountOfPairedToken,
        uint160 sqrtPriceX96
    ) internal view returns (uint256 value) {
        if (amountOfPairedToken == 0) return 0;
        if (_ASSET_IS_TOKEN_0) {
            // Convert token1 to token0: amount1 * (Q96^2 / sqrtPriceX96^2)
            value = FullMath.mulDiv(
                amountOfPairedToken,
                Q96,
                FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, Q96)
            );
        } else {
            // Convert token0 to token1: amount0 * (sqrtPriceX96^2 / Q96^2)
            value = FullMath.mulDiv(
                FullMath.mulDiv(amountOfPairedToken, sqrtPriceX96, Q96),
                sqrtPriceX96,
                Q96
            );
        }
    }

    /**
     * @notice Converts asset value to paired token quantity (inverse of _valueOfPairedTokenInAsset).
     * @param _valueInAssetTerms The value denominated in the strategy's primary asset
     * @param _sqrtPriceX96 The current sqrt price (Q64.96) of the Uniswap V3 pool
     * @return _amountOfPairedToken The corresponding quantity of paired token
     */
    function _assetValueToPairedAmount(
        uint256 _valueInAssetTerms,
        uint160 _sqrtPriceX96
    ) internal view returns (uint256 _amountOfPairedToken) {
        if (_valueInAssetTerms == 0) return 0;
        if (_ASSET_IS_TOKEN_0) {
            _amountOfPairedToken = FullMath.mulDiv(
                _valueInAssetTerms,
                FullMath.mulDiv(_sqrtPriceX96, _sqrtPriceX96, Q96),
                Q96
            );
        } else {
            _amountOfPairedToken = FullMath.mulDiv(
                _valueInAssetTerms,
                Q96,
                FullMath.mulDiv(_sqrtPriceX96, _sqrtPriceX96, Q96)
            );
        }
    }

    /*//////////////////////////////////////////////////////////////
                         INTERNAL LOGIC
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Calculates the amount of the strategy's asset to swap to achieve a balanced
     *         deposit into the Uniswap V3 LP, based on the current LP composition.
     * @dev If the LP is empty, returns 0.Otherwise, it calculates the swap amount
     *      to match the LP's current token value ratio.
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
        if (total0InLp == 0 && total1InLp == 0) return 0;

        uint256 pairedTokenValueInAsset;
        uint256 totalLpValueInAsset;

        if (_ASSET_IS_TOKEN_0) {
            pairedTokenValueInAsset = FullMath.mulDiv(
                total1InLp,
                Q96,
                FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, Q96)
            );
            totalLpValueInAsset = total0InLp + pairedTokenValueInAsset;
        } else {
            pairedTokenValueInAsset = FullMath.mulDiv(
                FullMath.mulDiv(total0InLp, sqrtPriceX96, Q96),
                sqrtPriceX96,
                Q96
            );
            totalLpValueInAsset = total1InLp + pairedTokenValueInAsset;
        }

        if (totalLpValueInAsset == 0) return 0;
        // Calculate swap amount to match LP's token value ratio
        amountToSwap = FullMath.mulDiv(
            assetBalance,
            pairedTokenValueInAsset,
            totalLpValueInAsset
        );
    }

    /**
     * @notice Swaps asset for paired token via Uniswap V3 pool.
     * @param amountToSwap The amount of asset to swap
     */
    function _swapAssetForPairedToken(uint256 amountToSwap) internal {
        _performSwap(address(asset), amountToSwap, _ASSET_IS_TOKEN_0);
    }

    /**
     * @notice Swaps paired token for asset via Uniswap V3 pool.
     * @param amountToSwap The amount of paired token to swap
     */
    function _swapPairedTokenForAsset(uint256 amountToSwap) internal {
        _performSwap(address(_PAIRED_TOKEN), amountToSwap, !_ASSET_IS_TOKEN_0);
    }

    /**
     * @notice Internal helper to perform token swaps via Uniswap V3 pool.
     * @param tokenIn The address of the token being swapped
     * @param amountToSwap The amount of token to swap
     * @param zeroForOne The direction of the swap (true = token0 -> token1, false = token1 -> token0)
     */
    function _performSwap(
        address tokenIn,
        uint256 amountToSwap,
        bool zeroForOne
    ) internal {
        // Apply maxSwapValue limit if not set to max
        uint256 _maxSwapValue = maxSwapValue;
        if (_maxSwapValue != type(uint256).max) {
            uint256 swapValueInAsset;
            if (tokenIn == address(asset)) {
                // Swapping asset, amount is already in asset terms
                swapValueInAsset = amountToSwap;
            } else {
                // Swapping paired token, convert to asset value
                swapValueInAsset = _valueOfPairedTokenInAsset(amountToSwap);
            }

            if (swapValueInAsset > _maxSwapValue) {
                // Reduce swap amount to respect limit
                if (tokenIn == address(asset)) {
                    amountToSwap = _maxSwapValue;
                } else {
                    // Convert maxSwapValue back to paired token amount
                    (uint160 sqrtPriceX96, , , , , , ) = IUniswapV3Pool(_POOL)
                        .slot0();
                    amountToSwap = _assetValueToPairedAmount(
                        _maxSwapValue,
                        sqrtPriceX96
                    );
                }
            }
        }

        // Apply minAsset check after all amount adjustments
        uint256 _minAsset = uint256(minAsset);
        if (_minAsset > 0) {
            uint256 swapValueInAsset;
            if (tokenIn == address(asset)) {
                // Swapping asset, amount is already in asset terms
                swapValueInAsset = amountToSwap;
            } else {
                // Swapping paired token, convert to asset value
                swapValueInAsset = _valueOfPairedTokenInAsset(amountToSwap);
            }

            // Skip swap if below minimum threshold
            if (swapValueInAsset < _minAsset) {
                return;
            }
        }

        if (amountToSwap == 0) return;

        SwapCallbackData memory callbackData = SwapCallbackData(
            tokenIn,
            amountToSwap
        );
        bytes memory data = abi.encode(callbackData);

        IUniswapV3Pool(_POOL).swap(
            address(this),
            zeroForOne,
            int256(amountToSwap),
            zeroForOne
                ? TickMath.MIN_SQRT_RATIO + 1
                : TickMath.MAX_SQRT_RATIO - 1,
            data
        );
    }

    /**
     * @notice Performs rebalancing swaps to achieve target token allocation for LP deposit.
     * @param currentPairedTokenValueInAsset Current value of paired token holdings in asset terms
     * @param targetPairedTokenValueInAsset Target value of paired token holdings in asset terms
     * @param assetBalance Current asset balance
     * @param pairedTokenBalance Current paired token balance
     * @param sqrtPriceX96 Current pool price
     */
    function _performRebalancingSwap(
        uint256 currentPairedTokenValueInAsset,
        uint256 targetPairedTokenValueInAsset,
        uint256 assetBalance,
        uint256 pairedTokenBalance,
        uint160 sqrtPriceX96
    ) internal {
        if (targetPairedTokenValueInAsset > currentPairedTokenValueInAsset) {
            // Need more paired token
            uint256 assetValueToSwap = targetPairedTokenValueInAsset -
                currentPairedTokenValueInAsset;
            if (assetValueToSwap > assetBalance) {
                assetValueToSwap = assetBalance;
            }
            if (assetValueToSwap > 0) {
                _swapAssetForPairedToken(assetValueToSwap);
            }
        } else if (
            currentPairedTokenValueInAsset > targetPairedTokenValueInAsset
        ) {
            // Have excess paired token
            uint256 excessPairedTokenValueInAsset = currentPairedTokenValueInAsset -
                    targetPairedTokenValueInAsset;
            uint256 pairedTokenQuantityToSwap = _assetValueToPairedAmount(
                excessPairedTokenValueInAsset,
                sqrtPriceX96
            );
            if (pairedTokenQuantityToSwap > pairedTokenBalance) {
                pairedTokenQuantityToSwap = pairedTokenBalance;
            }
            if (pairedTokenQuantityToSwap > 0) {
                _swapPairedTokenForAsset(pairedTokenQuantityToSwap);
            }
        }
    }

    /**
     * @notice Deposits balanced tokens into the Steer LP.
     * @param assetForDeposit Amount of asset to deposit
     */
    function _performLpDeposit(uint256 assetForDeposit) internal {
        uint256 pairedTokenBalanceForDeposit = ERC20(_PAIRED_TOKEN).balanceOf(
            address(this)
        );

        asset.forceApprove(address(STEER_LP), assetForDeposit);
        ERC20(_PAIRED_TOKEN).forceApprove(
            address(STEER_LP),
            pairedTokenBalanceForDeposit
        );

        uint256 token0DepositAmount;
        uint256 token1DepositAmount;

        if (_ASSET_IS_TOKEN_0) {
            token0DepositAmount = assetForDeposit;
            token1DepositAmount = pairedTokenBalanceForDeposit;
        } else {
            token0DepositAmount = pairedTokenBalanceForDeposit;
            token1DepositAmount = assetForDeposit;
        }

        STEER_LP.deposit(
            token0DepositAmount,
            token1DepositAmount,
            0,
            0,
            address(this)
        );
    }

    /**
     * @notice Deposits assets into the Steer LP.
     * @dev This function first calculates the optimal amount of the strategy's asset to swap
     *      to achieve a balanced deposit. It then performs the swap (if necessary) and
     *      deposits both the remaining asset and the acquired other token into the Steer LP.
     *      Respects the targetIdleAssetBps to maintain a percentage of assets idle.
     */
    function _depositInLp() internal {
        uint256 assetBalance = asset.balanceOf(address(this));
        uint256 pairedTokenBalance = ERC20(_PAIRED_TOKEN).balanceOf(
            address(this)
        );

        uint256 availableForDeposit = assetBalance;
        uint256 targetIdleAmount;

        // Apply idle asset target
        uint256 _targetIdleAssetBps = uint256(targetIdleAssetBps);
        if (_targetIdleAssetBps > 0) {
            uint256 totalAssets = TokenizedStrategy.totalAssets();
            targetIdleAmount = (totalAssets * _targetIdleAssetBps) / MAX_BPS;

            // Only deposit if above target idle amount
            if (assetBalance <= targetIdleAmount) return;

            // Calculate amount available for deposit
            availableForDeposit = assetBalance - targetIdleAmount;
        }

        (uint160 sqrtPriceX96, , , , , , ) = IUniswapV3Pool(_POOL).slot0();

        uint256 pairedTokenValueInAsset = _valueOfPairedTokenInAsset(
            pairedTokenBalance,
            sqrtPriceX96
        );
        uint256 totalDepositValueInAsset = availableForDeposit +
            pairedTokenValueInAsset;

        if (totalDepositValueInAsset == 0) return;

        (uint256 lpToken0Balance, uint256 lpToken1Balance) = STEER_LP
            .getTotalAmounts();

        if (lpToken0Balance == 0 && lpToken1Balance == 0) return; // do not be first lp

        // Early exit if maxSwapValue = 0 and LP needs both tokens but we can't swap
        if (maxSwapValue == 0) {
            bool lpIsOutOfRange = (lpToken0Balance == 0) ||
                (lpToken1Balance == 0);
            bool weHaveOnlyOneToken = (pairedTokenBalance == 0) ||
                (availableForDeposit == 0);

            if (!lpIsOutOfRange && weHaveOnlyOneToken) {
                return; // LP needs both tokens but we can't swap to get them
            }
        }

        // Calculate target allocation and perform rebalancing swap
        uint256 targetPairedTokenValueInAsset = _calculateAmountToSwapForDeposit(
                totalDepositValueInAsset,
                lpToken0Balance,
                lpToken1Balance,
                sqrtPriceX96
            );
        _performRebalancingSwap(
            pairedTokenValueInAsset,
            targetPairedTokenValueInAsset,
            availableForDeposit,
            pairedTokenBalance,
            sqrtPriceX96
        );

        availableForDeposit = asset.balanceOf(address(this));
        if (availableForDeposit <= targetIdleAmount) return;

        _performLpDeposit(availableForDeposit - targetIdleAmount);
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

        uint256 lpSharesBalance = STEER_LP.balanceOf(address(this));
        if (lpSharesBalance == 0) return;

        uint256 lpValueInAsset = lpVaultInAsset();
        if (lpValueInAsset == 0) return;

        uint256 sharesToWithdraw;
        if (assetToWithdraw >= lpValueInAsset) {
            sharesToWithdraw = lpSharesBalance;
        } else {
            sharesToWithdraw = FullMath.mulDiv(
                assetToWithdraw,
                lpSharesBalance,
                lpValueInAsset
            );
        }

        if (sharesToWithdraw == 0) return;

        STEER_LP.withdraw(sharesToWithdraw, 0, 0, address(this));

        uint256 pairedTokenBalance = ERC20(_PAIRED_TOKEN).balanceOf(
            address(this)
        );

        if (pairedTokenBalance > 0) {
            _swapPairedTokenForAsset(pairedTokenBalance);
        }
    }

    /*//////////////////////////////////////////////////////////////
                         UNISWAP V3 CALLBACK
    //////////////////////////////////////////////////////////////*/

    // @inheritdoc IUniswapV3SwapCallback
    function uniswapV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata _data
    ) external override {
        require(msg.sender == _POOL, "!caller"); // dev: Only pool can call swap callback

        SwapCallbackData memory callbackData = abi.decode(
            _data,
            (SwapCallbackData)
        );

        uint256 amountPaid = _validateAndGetAmountPaid(
            amount0Delta,
            amount1Delta,
            callbackData.tokenToPay
        );

        require(amountPaid == callbackData.amountToPay, "!amount"); // dev: amount mismatch
        ERC20(callbackData.tokenToPay).safeTransfer(_POOL, amountPaid);
    }

    /**
     * @notice Validates swap callback deltas and returns the amount to be paid
     * @param amount0Delta Amount delta for token0
     * @param amount1Delta Amount delta for token1
     * @param tokenToPay Address of the token being paid
     * @return amountPaid The validated amount to pay
     */
    function _validateAndGetAmountPaid(
        int256 amount0Delta,
        int256 amount1Delta,
        address tokenToPay
    ) internal view returns (uint256 amountPaid) {
        bool isPayingAsset = tokenToPay == address(asset);
        bool isPayingPairedToken = tokenToPay == _PAIRED_TOKEN;

        require(isPayingAsset || isPayingPairedToken, "!token"); // dev: invalid token to pay

        if (_ASSET_IS_TOKEN_0) {
            if (isPayingAsset) {
                require(amount0Delta > 0, "!amount0+"); // dev: paying asset as token0
                require(amount1Delta < 0, "!amount1-"); // dev: paying asset as token0
                amountPaid = uint256(amount0Delta);
            } else {
                require(amount1Delta > 0, "!amount1+"); // dev: paying paired token as token1
                require(amount0Delta < 0, "!amount0-"); // dev: paying paired token as token1
                amountPaid = uint256(amount1Delta);
            }
        } else {
            if (isPayingAsset) {
                require(amount1Delta > 0, "!amount1+"); // dev: paying asset as token1
                require(amount0Delta < 0, "!amount0-"); // dev: paying asset as token1
                amountPaid = uint256(amount1Delta);
            } else {
                require(amount0Delta > 0, "!amount0+"); // dev: paying paired token as token0
                require(amount1Delta < 0, "!amount1-"); // dev: paying paired token as token0
                amountPaid = uint256(amount0Delta);
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                        MANAGEMENT FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Sets the deposit limit for the strategy
     * @param _depositLimit New deposit limit
     */
    function setDepositLimit(uint256 _depositLimit) external onlyManagement {
        depositLimit = _depositLimit;
    }

    /**
     * @notice Sets the target idle asset percentage in basis points
     * @param _targetIdleAssetBps Target idle asset percentage in basis points (e.g., 500 = 5%)
     */
    function setTargetIdleAssetBps(
        uint16 _targetIdleAssetBps
    ) external onlyManagement {
        require(_targetIdleAssetBps <= MAX_BPS, "!bps"); // dev: Target idle asset cannot exceed 100% (10000 bps)
        targetIdleAssetBps = _targetIdleAssetBps;
    }

    /**
     * @notice Sets the maximum swap value per transaction
     * @param _maxSwapValue Maximum value that can be swapped in a single transaction (in asset terms)
     * @dev Set to type(uint256).max to disable the limit
     */
    function setMaxSwapValue(uint256 _maxSwapValue) external onlyManagement {
        maxSwapValue = _maxSwapValue;
    }

    /**
     * @notice Sets the minimum wait time between tends
     * @param _minTendWait Minimum wait time in seconds
     * @dev Can only be called by management
     */
    function setMinTendWait(uint24 _minTendWait) external onlyManagement {
        minTendWait = _minTendWait;
    }

    /**
     * @notice Sets the maximum acceptable base fee for tends
     * @param _maxTendBaseFeeGwei Maximum base fee in gwei
     * @dev Can only be called by management
     */
    function setMaxTendBaseFee(
        uint8 _maxTendBaseFeeGwei
    ) external onlyManagement {
        maxTendBaseFeeGwei = _maxTendBaseFeeGwei;
    }

    /**
     * @notice Sets the target idle buffer in basis points
     * @param _targetIdleBufferBps Buffer in basis points (e.g., 1000 = 10%)
     * @dev Can only be called by management
     */
    function setTargetIdleBufferBps(
        uint16 _targetIdleBufferBps
    ) external onlyManagement {
        require(_targetIdleBufferBps <= MAX_BPS, "!bps"); // dev: Buffer cannot exceed 100%
        targetIdleBufferBps = _targetIdleBufferBps;
    }

    /**
     * @notice Sets the additional discount for paired token valuations
     * @param _pairedTokenDiscountBps Discount in basis points (e.g., 50 = 0.5%)
     * @dev Can only be called by management
     */
    function setPairedTokenDiscountBps(
        uint16 _pairedTokenDiscountBps
    ) external onlyManagement {
        require(_pairedTokenDiscountBps <= 1000, "!discount"); // dev: Discount cannot exceed 10%
        pairedTokenDiscountBps = _pairedTokenDiscountBps;
    }

    /**
     * @notice Sets the minimum asset amount for any operation (dust threshold)
     * @param _minAsset Minimum amount of assets for any operation
     * @dev Can only be called by management
     */
    function setMinAsset(uint128 _minAsset) external onlyManagement {
        minAsset = _minAsset;
    }

    /**
     * @notice Sets whether to use auctions for token swaps
     * @param _useAuctions New value for useAuctions flag
     * @dev Can only be called by management
     * @dev When enabled, the strategy will attempt to kick auctions during harvest
     * @dev When disabled, the strategy will not use auctions and rewards will accumulate
     */
    function setUseAuctions(bool _useAuctions) external onlyManagement {
        useAuctions = _useAuctions;
    }

    /**
     * @notice Sets the auction contract address
     * @param _auction Address of the auction contract
     * @dev Can only be called by management
     * @dev Verifies the auction contract is compatible with this strategy by:
     *      1. Checking that auction's want matches the strategy's asset
     *      2. Ensuring the auction contract's receiver is this strategy
     */
    function setAuction(address _auction) external onlyManagement {
        if (_auction != address(0)) {
            require(IAuction(_auction).want() == address(asset), "!want"); // dev: Auction want token must match strategy asset
            require(
                IAuction(_auction).receiver() == address(this),
                "!receiver"
            ); // dev: Auction receiver must be this strategy
        }
        auction = _auction;
    }

    /**
     * @notice Manually swaps paired token for asset
     * @param _amount Amount of paired token to swap
     */
    function manualSwapPairedTokenToAsset(
        uint256 _amount
    ) external onlyManagement {
        require(_amount > 0, "!amount"); // dev: Amount must be greater than 0
        uint256 pairedTokenBalance = ERC20(_PAIRED_TOKEN).balanceOf(
            address(this)
        );
        require(_amount <= pairedTokenBalance, "!balance"); // dev: Insufficient paired token balance

        _swapPairedTokenForAsset(_amount);
    }

    /**
     * @notice Manually withdraws from LP position
     * @param _amount Amount of asset value to withdraw from LP
     */
    function manualWithdrawFromLp(uint256 _amount) external onlyManagement {
        require(_amount > 0, "!amount"); // dev: Amount must be greater than 0
        _withdrawFromLp(_amount);
    }

    /*//////////////////////////////////////////////////////////////
                        AUCTION FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Initiates an auction for a given token
     * @dev Transfers tokens to auction contract and starts auction
     * @param _from The token to be sold in the auction
     * @return The available amount for bidding on in the auction
     */
    function kickAuction(
        address _from
    ) external virtual onlyManagement returns (uint256) {
        (bool _success, uint256 _amount) = _tryKickAuction(auction, _from);
        require(_success, "!kick");
        return _amount;
    }

    /**
     * @notice Attempts to kick an auction for a given token
     * @param _auction The auction contract address
     * @param _from The token to be sold in the auction
     * @return success Whether the auction was successfully started
     * @return amount The amount available for bidding
     */
    function _tryKickAuction(
        address _auction,
        address _from
    ) internal virtual returns (bool, uint256) {
        if (!useAuctions || _auction == address(0)) return (false, 0);
        if (_from == address(asset) || _from == address(STEER_LP))
            return (false, 0);
        if (
            IAuction(_auction).isActive(address(asset)) ||
            IAuction(_auction).available(address(asset)) != 0
        ) return (false, 0);
        uint256 _strategyBalance = ERC20(_from).balanceOf(address(this));
        uint256 _totalBalance = _strategyBalance +
            ERC20(_from).balanceOf(_auction);
        if (_totalBalance == 0) return (false, 0);
        ERC20(_from).safeTransfer(_auction, _strategyBalance);
        uint256 _amountKicked = IAuction(_auction).kick(_from);
        return (_amountKicked != 0, _amountKicked);
    }

    /*//////////////////////////////////////////////////////////////
                        REWARDS FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Claims rewards from Merkl distributor
     * @param users Recipients of tokens
     * @param tokens ERC20 tokens being claimed
     * @param amounts Amounts of tokens that will be sent to the corresponding users
     * @param proofs Array of Merkle proofs verifying the claims
     */
    function claim(
        address[] calldata users,
        address[] calldata tokens,
        uint256[] calldata amounts,
        bytes32[][] calldata proofs
    ) external {
        MERKL_DISTRIBUTOR.claim(users, tokens, amounts, proofs);
    }
}

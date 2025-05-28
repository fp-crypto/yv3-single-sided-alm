// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "forge-std/console2.sol";
import {Setup, ERC20, IStrategyInterface} from "./utils/Setup.sol";
import {IUniswapV3Pool} from "@uniswap-v3-core/interfaces/IUniswapV3Pool.sol";
import {ISushiMultiPositionLiquidityManager} from "../interfaces/steer/ISushiMultiPositionLiquidityManager.sol";

contract CallbackTests is Setup {
    function setUp() public virtual override {
        super.setUp();
    }

    function test_uniswapV3SwapCallback_unauthorizedCaller(
        IStrategyInterface strategy
    ) public {
        TestParams memory params = _getTestParams(address(strategy));
        ERC20 asset = params.asset;
        ERC20 pairedAsset = params.pairedAsset;
        
        bytes memory callbackData = abi.encode(
            address(asset),
            1000
        );

        vm.expectRevert("!caller");
        strategy.uniswapV3SwapCallback(100, -100, callbackData);
    }

    function test_uniswapV3SwapCallback_invalidToken(
        IStrategyInterface strategy
    ) public {
        TestParams memory params = _getTestParams(address(strategy));
        ERC20 asset = params.asset;
        ERC20 pairedAsset = params.pairedAsset;
        address pool = ISushiMultiPositionLiquidityManager(params.lp).pool();
        
        bytes memory callbackData = abi.encode(
            address(0x1234567890123456789012345678901234567890), // invalid token
            1000
        );

        vm.prank(pool);
        vm.expectRevert("!token");
        strategy.uniswapV3SwapCallback(100, -100, callbackData);
    }

    function test_uniswapV3SwapCallback_amountMismatch(
        IStrategyInterface strategy
    ) public {
        TestParams memory params = _getTestParams(address(strategy));
        ERC20 asset = params.asset;
        ERC20 pairedAsset = params.pairedAsset;
        address pool = ISushiMultiPositionLiquidityManager(params.lp).pool();
        
        bytes memory callbackData = abi.encode(
            address(asset),
            1000 // wrong amount
        );

        vm.prank(pool);
        vm.expectRevert("!amount");
        strategy.uniswapV3SwapCallback(500, -200, callbackData); // 500 != 1000
    }

    function test_uniswapV3SwapCallback_invalidDeltas_assetAsToken0(
        IStrategyInterface strategy
    ) public {
        TestParams memory params = _getTestParams(address(strategy));
        ERC20 asset = params.asset;
        ERC20 pairedAsset = params.pairedAsset;
        address pool = ISushiMultiPositionLiquidityManager(params.lp).pool();
        address token0 = ISushiMultiPositionLiquidityManager(params.lp).token0();
        
        // Only test if asset is token0
        if (address(asset) != token0) return;
        
        bytes memory callbackData = abi.encode(
            address(asset),
            100
        );

        vm.prank(pool);
        // When paying asset as token0, amount0Delta should be positive
        vm.expectRevert("!amount0+");
        strategy.uniswapV3SwapCallback(-100, 50, callbackData);
    }

    function test_uniswapV3SwapCallback_invalidDeltas_assetAsToken1(
        IStrategyInterface strategy
    ) public {
        TestParams memory params = _getTestParams(address(strategy));
        ERC20 asset = params.asset;
        ERC20 pairedAsset = params.pairedAsset;
        address pool = ISushiMultiPositionLiquidityManager(params.lp).pool();
        address token1 = ISushiMultiPositionLiquidityManager(params.lp).token1();
        
        // Only test if asset is token1
        if (address(asset) != token1) return;
        
        bytes memory callbackData = abi.encode(
            address(asset),
            100
        );

        vm.prank(pool);
        // When paying asset as token1, amount1Delta should be positive
        vm.expectRevert("!amount1+");
        strategy.uniswapV3SwapCallback(50, -100, callbackData);
    }

    function test_uniswapV3SwapCallback_invalidDeltas_pairedTokenAsToken0(
        IStrategyInterface strategy
    ) public {
        TestParams memory params = _getTestParams(address(strategy));
        ERC20 asset = params.asset;
        ERC20 pairedAsset = params.pairedAsset;
        address pool = ISushiMultiPositionLiquidityManager(params.lp).pool();
        address token0 = ISushiMultiPositionLiquidityManager(params.lp).token0();
        
        // Only test if paired asset is token0
        if (address(pairedAsset) != token0) return;
        
        bytes memory callbackData = abi.encode(
            address(pairedAsset),
            100
        );

        vm.prank(pool);
        // When paying paired token as token0, amount0Delta should be positive
        vm.expectRevert("!amount0+");
        strategy.uniswapV3SwapCallback(-100, 50, callbackData);
    }

    function test_uniswapV3SwapCallback_invalidDeltas_pairedTokenAsToken1(
        IStrategyInterface strategy
    ) public {
        TestParams memory params = _getTestParams(address(strategy));
        ERC20 asset = params.asset;
        ERC20 pairedAsset = params.pairedAsset;
        address pool = ISushiMultiPositionLiquidityManager(params.lp).pool();
        address token1 = ISushiMultiPositionLiquidityManager(params.lp).token1();
        
        // Only test if paired asset is token1
        if (address(pairedAsset) != token1) return;
        
        bytes memory callbackData = abi.encode(
            address(pairedAsset),
            100
        );

        vm.prank(pool);
        // When paying paired token as token1, amount1Delta should be positive
        vm.expectRevert("!amount1+");
        strategy.uniswapV3SwapCallback(50, -100, callbackData);
    }

    function test_uniswapV3SwapCallback_validCall_assetPayment(
        IStrategyInterface strategy,
        uint256 _amount
    ) public {
        TestParams memory params = _getTestParams(address(strategy));
        ERC20 asset = params.asset;
        ERC20 pairedAsset = params.pairedAsset;
        _amount = bound(_amount, params.minFuzzAmount, params.maxFuzzAmount / 10);
        address pool = ISushiMultiPositionLiquidityManager(params.lp).pool();
        address token0 = ISushiMultiPositionLiquidityManager(params.lp).token0();
        bool assetIsToken0 = address(asset) == token0;
        
        // Give strategy some tokens to pay
        airdrop(asset, address(strategy), _amount);
        
        bytes memory callbackData = abi.encode(
            address(asset),
            _amount
        );

        uint256 balanceBefore = asset.balanceOf(pool);
        
        vm.prank(pool);
        if (assetIsToken0) {
            strategy.uniswapV3SwapCallback(
                int256(_amount), 
                -int256(_amount / 2), 
                callbackData
            );
        } else {
            strategy.uniswapV3SwapCallback(
                -int256(_amount / 2), 
                int256(_amount), 
                callbackData
            );
        }
        
        // Verify payment was made
        assertEq(
            asset.balanceOf(pool), 
            balanceBefore + _amount,
            "Payment not made to pool"
        );
    }

    function test_uniswapV3SwapCallback_validCall_pairedTokenPayment(
        IStrategyInterface strategy,
        uint256 _amount
    ) public {
        TestParams memory params = _getTestParams(address(strategy));
        ERC20 asset = params.asset;
        ERC20 pairedAsset = params.pairedAsset;
        _amount = bound(_amount, 1e6, params.maxFuzzAmount / 10); // Use smaller amounts for paired token
        address pool = ISushiMultiPositionLiquidityManager(params.lp).pool();
        address token0 = ISushiMultiPositionLiquidityManager(params.lp).token0();
        bool pairedIsToken0 = address(pairedAsset) == token0;
        
        // Adjust amount for paired asset decimals
        if (params.pairedAssetDecimals < params.assetDecimals) {
            _amount = _amount / (10 ** (params.assetDecimals - params.pairedAssetDecimals));
        }
        
        // Give strategy some paired tokens to pay
        airdrop(pairedAsset, address(strategy), _amount);
        
        bytes memory callbackData = abi.encode(
            address(pairedAsset),
            _amount
        );

        uint256 balanceBefore = pairedAsset.balanceOf(pool);
        
        vm.prank(pool);
        if (pairedIsToken0) {
            strategy.uniswapV3SwapCallback(
                int256(_amount), 
                -int256(_amount / 2), 
                callbackData
            );
        } else {
            strategy.uniswapV3SwapCallback(
                -int256(_amount / 2), 
                int256(_amount), 
                callbackData
            );
        }
        
        // Verify payment was made
        assertEq(
            pairedAsset.balanceOf(pool), 
            balanceBefore + _amount,
            "Payment not made to pool"
        );
    }
}
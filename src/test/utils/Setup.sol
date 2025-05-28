// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import "forge-std/console2.sol";
import {Test} from "forge-std/Test.sol";

import {Strategy, ERC20, ISushiMultiPositionLiquidityManager} from "../../Strategy.sol";
import {StrategyFactory} from "../../StrategyFactory.sol";
import {IStrategyInterface} from "../../interfaces/IStrategyInterface.sol";

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
//import {EnumerableMap} from "@openzeppelin/contracts/utils/structs/EnumerableMap.sol";

// Inherit the events so they can be checked if desired.
import {IEvents} from "@tokenized-strategy/interfaces/IEvents.sol";

interface IFactory {
    function governance() external view returns (address);

    function set_protocol_fee_bps(uint16) external;

    function set_protocol_fee_recipient(address) external;
}

contract Setup is Test, IEvents {
    using EnumerableSet for EnumerableSet.AddressSet;
    //using EnumerableMap for EnumerableMap.AddressToAddressMap;

    struct TestParams {
        IStrategyInterface strategy;
        address lp;
        ERC20 asset;
        ERC20 pairedAsset;
        uint256 minFuzzAmount;
        uint256 maxFuzzAmount;
        uint256 assetDecimals;
        uint256 pairedAssetDecimals;
        bool isStable;
    }

    StrategyFactory public strategyFactory;

    mapping(string => address) public tokenAddrs;

    EnumerableSet.AddressSet internal lps;
    EnumerableSet.AddressSet internal assets;
    EnumerableSet.AddressSet internal strategies;

    // Addresses for different roles we will use repeatedly.
    address public user = address(10);
    address public keeper = address(4);
    address public management = address(1);
    address public performanceFeeRecipient = address(3);
    address public emergencyAdmin = address(5);

    // Address of the real deployed Factory
    address public factory;

    // Integer variables that will be used repeatedly.
    uint256 public MAX_BPS = 10_000;

    mapping(address => uint256) public minFuzzAmount;
    mapping(address => uint256) public maxFuzzAmount;

    // Default profit max unlock time is set for 10 days
    uint256 public profitMaxUnlockTime = 10 days;

    function setUp() public virtual {
        _setTokenAddrs();
        _setFuzzLimits();

        strategyFactory = new StrategyFactory(
            management,
            performanceFeeRecipient,
            keeper,
            emergencyAdmin
        );

        // Deploy strategy and set variables
        _setupStrategies(tokenAddrs["steerDAIUSDC"]);
        _setupStrategies(tokenAddrs["steerUSDCWPOL"]);

        // label all the used addresses for traces
        vm.label(keeper, "keeper");
        vm.label(factory, "factory");
        vm.label(management, "management");
        vm.label(performanceFeeRecipient, "performanceFeeRecipient");
    }

    function setUpStrategy() public returns (address) {}

    function depositIntoStrategy(
        IStrategyInterface _strategy,
        address _user,
        uint256 _amount
    ) public {
        ERC20 asset = ERC20(_strategy.asset());

        vm.prank(_user);
        asset.approve(address(_strategy), _amount);

        vm.prank(_user);
        _strategy.deposit(_amount, _user);
    }

    function mintAndDepositIntoStrategy(
        IStrategyInterface _strategy,
        address _user,
        uint256 _amount
    ) public {
        ERC20 asset = ERC20(_strategy.asset());
        airdrop(asset, _user, _amount);
        depositIntoStrategy(_strategy, _user, _amount);
    }

    // For checking the amounts in the strategy
    function checkStrategyTotals(
        IStrategyInterface _strategy,
        uint256 _totalAssets,
        uint256 _totalDebt,
        uint256 _totalIdle
    ) public {
        uint256 _assets = _strategy.totalAssets();
        uint256 _balance = ERC20(_strategy.asset()).balanceOf(
            address(_strategy)
        );
        uint256 _idle = _balance > _assets ? _assets : _balance;
        uint256 _debt = _assets - _idle;
        assertEq(_assets, _totalAssets, "!totalAssets");
        assertEq(_debt, _totalDebt, "!totalDebt");
        assertEq(_idle, _totalIdle, "!totalIdle");
        assertEq(_totalAssets, _totalDebt + _totalIdle, "!Added");
    }

    function airdrop(ERC20 _asset, address _to, uint256 _amount) public {
        uint256 balanceBefore = _asset.balanceOf(_to);
        deal(address(_asset), _to, balanceBefore + _amount);
    }

    function setFees(
        IStrategyInterface strategy,
        uint16 _protocolFee,
        uint16 _performanceFee
    ) public {
        address gov = IFactory(factory).governance();

        // Need to make sure there is a protocol fee recipient to set the fee.
        vm.prank(gov);
        IFactory(factory).set_protocol_fee_recipient(gov);

        vm.prank(gov);
        IFactory(factory).set_protocol_fee_bps(_protocolFee);

        vm.prank(management);
        strategy.setPerformanceFee(_performanceFee);
    }

    function _setTokenAddrs() internal {
        tokenAddrs["DAI"] = 0x8f3Cf7ad23Cd3CaDbD9735AFf958023239c6A063;
        tokenAddrs["USDC"] = 0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174;
        tokenAddrs["WPOL"] = 0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270;
        tokenAddrs["steerDAIUSDC"] = 0x77ce0a6ddCBb30d69015105726D106686a054719;
        tokenAddrs[
            "steerUSDCWPOL"
        ] = 0x89E895C79Fc74f53CB13Ee880E38A31149E7802B;
    }

    function _setFuzzLimits() internal {
        maxFuzzAmount[tokenAddrs["USDC"]] = 10e6;
        minFuzzAmount[tokenAddrs["USDC"]] = 1e6;
        maxFuzzAmount[tokenAddrs["DAI"]] = 10e18;
        minFuzzAmount[tokenAddrs["DAI"]] = 1e18;
        maxFuzzAmount[tokenAddrs["WPOL"]] = 1e18;
        minFuzzAmount[tokenAddrs["WPOL"]] = 0.1e18;
    }

    function _setupStrategies(address lp) private {
        IStrategyInterface _strategy0 = IStrategyInterface(
            address(
                strategyFactory.newStrategy(
                    ISushiMultiPositionLiquidityManager(lp).token0(),
                    "Tokenized Strategy",
                    lp
                )
            )
        );

        IStrategyInterface _strategy1 = IStrategyInterface(
            address(
                strategyFactory.newStrategy(
                    ISushiMultiPositionLiquidityManager(lp).token1(),
                    "Tokenized Strategy",
                    lp
                )
            )
        );

        lps.add(lp);
        assets.add(_strategy0.asset());
        assets.add(_strategy1.asset());
        strategies.add(address(_strategy0));
        strategies.add(address(_strategy1));

        vm.startPrank(management);
        _strategy0.acceptManagement();
        _strategy1.acceptManagement();
        vm.stopPrank();
    }

    function fixtureStrategy() public returns (address[] memory) {
        return strategies.values();
    }

    function _isFixtureStrategy(
        address _strategy
    ) internal view returns (bool) {
        return strategies.contains(_strategy);
    }

    function _getTestParams(
        address _strategy
    ) internal returns (TestParams memory) {
        vm.assume(_isFixtureStrategy(_strategy));

        IStrategyInterface strategy = IStrategyInterface(_strategy);
        ISushiMultiPositionLiquidityManager lp = ISushiMultiPositionLiquidityManager(
                strategy.STEER_LP()
            );
        address asset = address(strategy.asset());
        address pairedAsset = lp.token0() == asset ? lp.token1() : lp.token0();
        return
            TestParams(
                strategy,
                address(lp),
                ERC20(asset),
                ERC20(pairedAsset),
                minFuzzAmount[asset],
                maxFuzzAmount[asset],
                ERC20(asset).decimals(),
                ERC20(pairedAsset).decimals(),
                asset != tokenAddrs["WPOL"] && pairedAsset != tokenAddrs["WPOL"]
            );
    }

    function logStrategyInfo(TestParams memory params) internal view {
        console2.log("==== Strategy Info ====");
        console2.log(
            "Asset/PairedAsset: %s/%s",
            params.asset.symbol(),
            params.pairedAsset.symbol()
        );
        console2.log("Total Assets: %e", params.strategy.totalAssets());
        console2.log("ETA: %e", params.strategy.estimatedTotalAsset());
        console2.log(
            "Idle asset: %e",
            params.asset.balanceOf(address(params.strategy))
        );
        console2.log(
            "Idle pairedAsset: %e",
            params.pairedAsset.balanceOf(address(params.strategy))
        );
        console2.log(
            "LP balance: %e",
            ERC20(params.lp).balanceOf(address(params.strategy))
        );
        console2.log("LP in asset: %e", params.strategy.lpVaultInAsset());
        console2.log("======================");
    }
}

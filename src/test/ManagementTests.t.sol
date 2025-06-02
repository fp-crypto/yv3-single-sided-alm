// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "forge-std/console2.sol";
import {Setup, ERC20, IStrategyInterface} from "./utils/Setup.sol";
import {IAuction} from "../interfaces/IAuction.sol";

// Mock auction contract for testing
contract MockAuction {
    address public want;
    address public receiver;
    bool public isActiveValue;
    uint256 public availableValue;

    constructor(address _want, address _receiver) {
        want = _want;
        receiver = _receiver;
    }

    function setActive(bool _active) external {
        isActiveValue = _active;
    }

    function setAvailable(uint256 _available) external {
        availableValue = _available;
    }

    function isActive(address) external view returns (bool) {
        return isActiveValue;
    }

    function available(address) external view returns (uint256) {
        return availableValue;
    }

    function kick(address) external returns (uint256) {
        return 1000;
    }
}

contract ManagementTests is Setup {
    function setUp() public virtual override {
        super.setUp();
    }

    function test_setTargetIdleAssetBps_exceedsMax(
        IStrategyInterface strategy
    ) public {
        TestParams memory params = _getTestParams(address(strategy));
        ERC20 asset = params.asset;

        vm.prank(management);
        vm.expectRevert(bytes("!bps"));
        strategy.setTargetIdleAssetBps(10001); // > 10000
    }

    function test_setTargetIdleAssetBps_maxValue(
        IStrategyInterface strategy
    ) public {
        TestParams memory params = _getTestParams(address(strategy));

        vm.prank(management);
        strategy.setTargetIdleAssetBps(10000); // Exactly 10000 should work

        assertEq(strategy.targetIdleAssetBps(), 10000);
    }

    function test_setTargetIdleAssetBps_zero(
        IStrategyInterface strategy
    ) public {
        TestParams memory params = _getTestParams(address(strategy));

        vm.prank(management);
        strategy.setTargetIdleAssetBps(0);

        assertEq(strategy.targetIdleAssetBps(), 0);
    }

    function test_setTargetIdleAssetBps_onlyManagement(
        IStrategyInterface strategy
    ) public {
        TestParams memory params = _getTestParams(address(strategy));

        vm.prank(user);
        vm.expectRevert();
        strategy.setTargetIdleAssetBps(5000);
    }

    function test_setDepositLimit_various(
        IStrategyInterface strategy,
        uint256 _limit
    ) public {
        TestParams memory params = _getTestParams(address(strategy));
        _limit = bound(_limit, 0, type(uint256).max);

        vm.prank(management);
        strategy.setDepositLimit(_limit);

        assertEq(strategy.depositLimit(), _limit);
    }

    function test_setDepositLimit_onlyManagement(
        IStrategyInterface strategy
    ) public {
        TestParams memory params = _getTestParams(address(strategy));

        vm.prank(user);
        vm.expectRevert();
        strategy.setDepositLimit(1000e18);
    }

    function test_setAuction_invalidWantToken(
        IStrategyInterface strategy
    ) public {
        TestParams memory params = _getTestParams(address(strategy));

        // Create mock auction with wrong want token
        MockAuction mockAuction = new MockAuction(
            address(params.pairedAsset), // Wrong token
            address(strategy)
        );

        vm.prank(management);
        vm.expectRevert("!want");
        strategy.setAuction(address(mockAuction));
    }

    function test_setAuction_invalidReceiver(
        IStrategyInterface strategy
    ) public {
        TestParams memory params = _getTestParams(address(strategy));

        // Create mock auction with wrong receiver
        MockAuction mockAuction = new MockAuction(
            address(params.asset),
            address(0x1234567890123456789012345678901234567890) // Wrong receiver
        );

        vm.prank(management);
        vm.expectRevert("!receiver");
        strategy.setAuction(address(mockAuction));
    }

    function test_setAuction_validAuction(IStrategyInterface strategy) public {
        TestParams memory params = _getTestParams(address(strategy));

        // Create valid mock auction
        MockAuction mockAuction = new MockAuction(
            address(params.asset),
            address(strategy)
        );

        vm.prank(management);
        strategy.setAuction(address(mockAuction));

        assertEq(strategy.auction(), address(mockAuction));
    }

    function test_setAuction_setToZero(IStrategyInterface strategy) public {
        TestParams memory params = _getTestParams(address(strategy));

        vm.prank(management);
        strategy.setAuction(address(0));

        assertEq(strategy.auction(), address(0));
    }

    function test_setAuction_onlyManagement(
        IStrategyInterface strategy
    ) public {
        TestParams memory params = _getTestParams(address(strategy));

        vm.prank(user);
        vm.expectRevert();
        strategy.setAuction(address(0));
    }

    function test_setUseAuctions_toggle(IStrategyInterface strategy) public {
        TestParams memory params = _getTestParams(address(strategy));

        bool initialValue = strategy.useAuctions();

        vm.prank(management);
        strategy.setUseAuctions(!initialValue);

        assertEq(strategy.useAuctions(), !initialValue);
    }

    function test_setUseAuctions_onlyManagement(
        IStrategyInterface strategy
    ) public {
        TestParams memory params = _getTestParams(address(strategy));

        vm.prank(user);
        vm.expectRevert();
        strategy.setUseAuctions(true);
    }

    function test_manualSwapPairedTokenToAsset_zeroAmount(
        IStrategyInterface strategy
    ) public {
        TestParams memory params = _getTestParams(address(strategy));

        vm.prank(management);
        vm.expectRevert("!amount");
        strategy.manualSwapPairedTokenToAsset(0);
    }

    function test_manualSwapPairedTokenToAsset_insufficientBalance(
        IStrategyInterface strategy
    ) public {
        TestParams memory params = _getTestParams(address(strategy));
        uint256 amount = 1000;

        // Ensure strategy has less than amount
        uint256 currentBalance = params.pairedAsset.balanceOf(
            address(strategy)
        );
        if (currentBalance >= amount) {
            return; // Skip if strategy already has enough balance
        }

        vm.prank(management);
        vm.expectRevert("!balance");
        strategy.manualSwapPairedTokenToAsset(amount);
    }

    function test_manualSwapPairedTokenToAsset_validAmount(
        IStrategyInterface strategy,
        uint256 _amount
    ) public {
        TestParams memory params = _getTestParams(address(strategy));

        // Set reasonable bounds based on paired asset decimals
        uint256 minAmount = 10 ** params.pairedAssetDecimals / 100; // 0.01 units
        uint256 maxAmount = 10 * 10 ** params.pairedAssetDecimals; // 10 units
        _amount = bound(_amount, minAmount, maxAmount);

        // Give strategy some paired tokens
        airdrop(params.pairedAsset, address(strategy), _amount);

        uint256 balanceBefore = params.pairedAsset.balanceOf(address(strategy));

        vm.prank(management);
        strategy.manualSwapPairedTokenToAsset(_amount);

        // Should have less paired tokens after swap
        assertLt(
            params.pairedAsset.balanceOf(address(strategy)),
            balanceBefore,
            "Paired token balance should decrease"
        );
    }

    function test_manualSwapPairedTokenToAsset_onlyManagement(
        IStrategyInterface strategy
    ) public {
        TestParams memory params = _getTestParams(address(strategy));

        vm.prank(user);
        vm.expectRevert();
        strategy.manualSwapPairedTokenToAsset(1000);
    }

    function test_manualWithdrawFromLp_zeroAmount(
        IStrategyInterface strategy
    ) public {
        TestParams memory params = _getTestParams(address(strategy));

        vm.prank(management);
        vm.expectRevert("!amount");
        strategy.manualWithdrawFromLp(0);
    }

    function test_manualWithdrawFromLp_onlyManagement(
        IStrategyInterface strategy
    ) public {
        TestParams memory params = _getTestParams(address(strategy));

        vm.prank(user);
        vm.expectRevert();
        strategy.manualWithdrawFromLp(1000e18);
    }

    function test_availableDepositLimit_exceedsDepositLimit(
        IStrategyInterface strategy,
        uint256 _depositLimit
    ) public {
        TestParams memory params = _getTestParams(address(strategy));
        _depositLimit = bound(_depositLimit, 1, params.maxFuzzAmount);

        // Set a low deposit limit
        vm.prank(management);
        strategy.setDepositLimit(_depositLimit);

        // Deposit up to the limit
        mintAndDepositIntoStrategy(strategy, user, _depositLimit);

        // Available deposit limit should be 0
        assertEq(strategy.availableDepositLimit(user), 0);
    }

    function test_availableDepositLimit_belowDepositLimit(
        IStrategyInterface strategy,
        uint256 _depositLimit,
        uint256 _currentDeposit
    ) public {
        TestParams memory params = _getTestParams(address(strategy));
        _depositLimit = bound(
            _depositLimit,
            params.minFuzzAmount * 2,
            params.maxFuzzAmount
        );
        _currentDeposit = bound(
            _currentDeposit,
            params.minFuzzAmount,
            _depositLimit / 2
        );

        // Set deposit limit
        vm.prank(management);
        strategy.setDepositLimit(_depositLimit);

        // Deposit less than limit
        mintAndDepositIntoStrategy(strategy, user, _currentDeposit);

        // Available deposit limit should be positive
        assertGt(strategy.availableDepositLimit(user), 0);
        assertLe(
            strategy.availableDepositLimit(user),
            _depositLimit - _currentDeposit
        );
    }

    function test_setTargetIdleBufferBps_various(
        IStrategyInterface strategy
    ) public {
        TestParams memory params = _getTestParams(address(strategy));

        // Test setting valid values
        vm.startPrank(management);

        // Test 5% buffer
        strategy.setTargetIdleBufferBps(500);
        assertEq(strategy.targetIdleBufferBps(), 500, "!500 bps");

        // Test 20% buffer
        strategy.setTargetIdleBufferBps(2000);
        assertEq(strategy.targetIdleBufferBps(), 2000, "!2000 bps");

        // Test 0% buffer
        strategy.setTargetIdleBufferBps(0);
        assertEq(strategy.targetIdleBufferBps(), 0, "!0 bps");

        // Test maximum 100% buffer
        strategy.setTargetIdleBufferBps(10000);
        assertEq(strategy.targetIdleBufferBps(), 10000, "!10000 bps");

        vm.stopPrank();
    }

    function test_setTargetIdleBufferBps_exceedsMax(
        IStrategyInterface strategy
    ) public {
        TestParams memory params = _getTestParams(address(strategy));

        // Test invalid value (over 100%)
        vm.prank(management);
        vm.expectRevert();
        strategy.setTargetIdleBufferBps(10001);
    }

    function test_setTargetIdleBufferBps_onlyManagement(
        IStrategyInterface strategy
    ) public {
        TestParams memory params = _getTestParams(address(strategy));

        // Test access control
        vm.prank(user);
        vm.expectRevert("!management");
        strategy.setTargetIdleBufferBps(1000);
    }
}

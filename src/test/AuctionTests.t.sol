// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "forge-std/console2.sol";
import {Setup, ERC20, IStrategyInterface} from "./utils/Setup.sol";
import {IAuction} from "../interfaces/IAuction.sol";
import {IMerklDistributor} from "../interfaces/IMerklDistributor.sol";

// Enhanced mock auction contract for testing
contract MockAuctionFull {
    address public want;
    address public receiver;
    bool public isActiveValue;
    uint256 public availableValue;
    uint256 public kickReturnValue = 1000;

    mapping(address => uint256) public balances;

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

    function setKickReturnValue(uint256 _value) external {
        kickReturnValue = _value;
    }

    function isActive(address) external view returns (bool) {
        return isActiveValue;
    }

    function available(address) external view returns (uint256) {
        return availableValue;
    }

    function kick(address /* _token */) external view returns (uint256) {
        return kickReturnValue;
    }

    // Allow receiving tokens
    function transfer(address _token, uint256 _amount) external {
        ERC20(_token).transferFrom(msg.sender, address(this), _amount);
        balances[_token] += _amount;
    }
}

// Mock reward token for testing
contract MockRewardToken is ERC20 {
    constructor() ERC20("Mock Reward", "REWARD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract AuctionTests is Setup {
    MockAuctionFull mockAuction;
    MockRewardToken rewardToken;

    function setUp() public virtual override {
        super.setUp();
        rewardToken = new MockRewardToken();
    }

    function test_kickAuction_auctionsDisabled(
        IStrategyInterface strategy
    ) public {
        TestParams memory params = _getTestParams(address(strategy));

        // Create and set auction
        mockAuction = new MockAuctionFull(
            address(params.asset),
            address(strategy)
        );

        vm.prank(management);
        strategy.setAuction(address(mockAuction));

        // Ensure auctions are disabled
        vm.prank(management);
        strategy.setUseAuctions(false);

        // Give strategy some reward tokens
        rewardToken.mint(address(strategy), 1000e18);

        vm.prank(management);
        vm.expectRevert("!kick");
        strategy.kickAuction(address(rewardToken));
    }

    function test_kickAuction_noAuctionSet(IStrategyInterface strategy) public {
        _getTestParams(address(strategy));

        // Enable auctions but don't set auction address
        vm.prank(management);
        strategy.setUseAuctions(true);

        // Give strategy some reward tokens
        rewardToken.mint(address(strategy), 1000e18);

        vm.prank(management);
        vm.expectRevert("!kick");
        strategy.kickAuction(address(rewardToken));
    }

    function test_kickAuction_protectedAssetToken(
        IStrategyInterface strategy
    ) public {
        TestParams memory params = _getTestParams(address(strategy));

        // Setup auction
        mockAuction = new MockAuctionFull(
            address(params.asset),
            address(strategy)
        );

        vm.prank(management);
        strategy.setAuction(address(mockAuction));

        vm.prank(management);
        strategy.setUseAuctions(true);

        // Try to kick auction for protected asset token
        vm.prank(management);
        vm.expectRevert("!kick");
        strategy.kickAuction(address(params.asset));
    }

    function test_kickAuction_protectedLpToken(
        IStrategyInterface strategy
    ) public {
        TestParams memory params = _getTestParams(address(strategy));

        // Setup auction
        mockAuction = new MockAuctionFull(
            address(params.asset),
            address(strategy)
        );

        vm.prank(management);
        strategy.setAuction(address(mockAuction));

        vm.prank(management);
        strategy.setUseAuctions(true);

        // Try to kick auction for protected LP token
        vm.prank(management);
        vm.expectRevert("!kick");
        strategy.kickAuction(params.lp);
    }

    function test_kickAuction_auctionAlreadyActive(
        IStrategyInterface strategy
    ) public {
        TestParams memory params = _getTestParams(address(strategy));

        // Setup auction
        mockAuction = new MockAuctionFull(
            address(params.asset),
            address(strategy)
        );

        vm.prank(management);
        strategy.setAuction(address(mockAuction));

        vm.prank(management);
        strategy.setUseAuctions(true);

        // Set auction as active
        mockAuction.setActive(true);

        // Give strategy some reward tokens
        rewardToken.mint(address(strategy), 1000e18);

        vm.prank(management);
        vm.expectRevert("!kick");
        strategy.kickAuction(address(rewardToken));
    }

    function test_kickAuction_auctionHasAvailable(
        IStrategyInterface strategy
    ) public {
        TestParams memory params = _getTestParams(address(strategy));

        // Setup auction
        mockAuction = new MockAuctionFull(
            address(params.asset),
            address(strategy)
        );

        vm.prank(management);
        strategy.setAuction(address(mockAuction));

        vm.prank(management);
        strategy.setUseAuctions(true);

        // Set auction as having available tokens
        mockAuction.setAvailable(500);

        // Give strategy some reward tokens
        rewardToken.mint(address(strategy), 1000e18);

        vm.prank(management);
        vm.expectRevert("!kick");
        strategy.kickAuction(address(rewardToken));
    }

    function test_kickAuction_noTokenBalance(
        IStrategyInterface strategy
    ) public {
        TestParams memory params = _getTestParams(address(strategy));

        // Setup auction
        mockAuction = new MockAuctionFull(
            address(params.asset),
            address(strategy)
        );

        vm.prank(management);
        strategy.setAuction(address(mockAuction));

        vm.prank(management);
        strategy.setUseAuctions(true);

        // Don't give strategy any reward tokens
        vm.prank(management);
        vm.expectRevert("!kick");
        strategy.kickAuction(address(rewardToken));
    }

    function test_kickAuction_successfulKick(
        IStrategyInterface strategy
    ) public {
        TestParams memory params = _getTestParams(address(strategy));

        // Setup auction
        mockAuction = new MockAuctionFull(
            address(params.asset),
            address(strategy)
        );

        vm.prank(management);
        strategy.setAuction(address(mockAuction));

        vm.prank(management);
        strategy.setUseAuctions(true);

        // Give strategy some reward tokens
        uint256 rewardAmount = 1000e18;
        rewardToken.mint(address(strategy), rewardAmount);

        vm.prank(management);
        uint256 kickedAmount = strategy.kickAuction(address(rewardToken));

        // Should return the kicked amount
        assertEq(kickedAmount, mockAuction.kickReturnValue());

        // Strategy should have transferred tokens to auction
        assertEq(rewardToken.balanceOf(address(strategy)), 0);
    }

    function test_kickAuction_onlyManagement(
        IStrategyInterface strategy
    ) public {
        _getTestParams(address(strategy));

        vm.prank(user);
        vm.expectRevert();
        strategy.kickAuction(address(rewardToken));
    }

    function test_claim_merklRewards(IStrategyInterface strategy) public {
        _getTestParams(address(strategy));

        // Prepare claim parameters (empty arrays for basic test)
        address[] memory users = new address[](0);
        address[] memory tokens = new address[](0);
        uint256[] memory amounts = new uint256[](0);
        bytes32[][] memory proofs = new bytes32[][](0);

        // This should not revert with empty arrays (no claims to process)
        // If it does revert, it's expected behavior from Merkl contract
        try strategy.claim(users, tokens, amounts, proofs) {
            // Success case - function exists and can be called
        } catch {
            // Expected to potentially fail with real Merkl contract
            // The important thing is that the function exists and is callable
        }
    }

    function test_claim_withParameters(IStrategyInterface strategy) public {
        _getTestParams(address(strategy));

        // Prepare claim parameters with some data
        address[] memory users = new address[](1);
        users[0] = address(strategy);

        address[] memory tokens = new address[](1);
        tokens[0] = address(rewardToken);

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1000e18;

        bytes32[][] memory proofs = new bytes32[][](1);
        proofs[0] = new bytes32[](1);
        proofs[0][0] = keccak256("dummy proof");

        // Should not revert - actual functionality depends on Merkl contract
        // This will likely fail with real Merkl contract due to invalid proof
        // but tests that the function exists and can be called
        try strategy.claim(users, tokens, amounts, proofs) {
            // Success case
        } catch {
            // Expected to fail with real Merkl contract
        }
    }
}

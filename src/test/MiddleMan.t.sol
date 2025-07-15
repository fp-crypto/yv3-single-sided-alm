// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {AuctionMiddleMan, IAuctionFactory} from "../AuctionMiddleMan.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IAuction} from "../interfaces/IAuction.sol";
import {IDistributionCreator} from "../interfaces/IDistributionCreator.sol";

// Mock contracts for testing
contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockStrategy {
    address public asset;
    address public management;
    address public auction;

    constructor(address _asset, address _management) {
        asset = _asset;
        management = _management;
    }

    function setAuction(address _auction) external {
        auction = _auction;
    }
}

interface IKat {
    function setLockExemption(address, bool) external;
}

contract TestAuctionMiddleMan is Test {
    AuctionMiddleMan public middleman;

    IAuctionFactory public auctionFactory =
        IAuctionFactory(0xCfA510188884F199fcC6e750764FAAbE6e56ec40);

    IDistributionCreator public distributionCreator =
        IDistributionCreator(0x8BB4C975Ff3c250e0ceEA271728547f3802B36Fd);

    ERC20 public kat = ERC20(0x7F1f4b4b29f5058fA32CC7a97141b8D7e5ABDC2d);

    ERC20 public wkat = ERC20(0x6E9C1F88a960fE63387eb4b71BC525a9313d8461);

    address public katManager = 0x92D8Ce89fF02C640daf0B7c23d497cCF1880C390;

    MockERC20 public otherToken;
    MockStrategy public strategy;
    IAuction public auction;

    address public governance = address(this);
    address public user = address(0x123);
    address public feeRecipient = address(0x999);
    event StrategyAdded(address indexed strategy, address auction);
    event StrategyRemoved(address indexed strategy);
    event CampaignCreated(uint256 amount);

    function setUp() public {
        // Deploy mock tokens
        otherToken = new MockERC20("OTHER", "OTHER");

        strategy = new MockStrategy(address(otherToken), governance);

        middleman = new AuctionMiddleMan(governance, feeRecipient);

        middleman.setKatFee(0);

        vm.prank(katManager);
        IKat(address(kat)).setLockExemption(address(middleman), true);
        vm.prank(katManager);
        IKat(address(kat)).setLockExemption(address(strategy), true);

        // Setup initial balances
        deal(address(kat), address(middleman), 1000e18);
        deal(address(wkat), address(middleman), 1000e18);
        deal(address(otherToken), address(middleman), 1000e18);
    }

    function test_Constructor() public {
        assertEq(middleman.governance(), governance);
        assertEq(middleman.campaignDuration(), 1 weeks);
        assertEq(middleman.feeRecipient(), feeRecipient);
        assertEq(middleman.katFee(), 0);
    }

    function test_AddStrategy() public {
        bytes memory campaignData = abi.encode("test campaign");

        middleman.addStrategy(address(strategy), campaignData);

        (address auction, bytes memory data) = middleman.strategies(
            address(strategy)
        );
        assertTrue(auction != address(0));
        assertEq(data, campaignData);
    }

    function test_AddStrategy_RevertIfAlreadyAdded() public {
        bytes memory campaignData = abi.encode("test campaign");

        middleman.addStrategy(address(strategy), campaignData);

        vm.expectRevert("AuctionMiddleMan: Strategy already added");
        middleman.addStrategy(address(strategy), campaignData);
    }

    function test_AddStrategy_RevertIfNoCampaignData() public {
        bytes memory campaignData = "";

        vm.expectRevert("AuctionMiddleMan: campaign data");
        middleman.addStrategy(address(strategy), campaignData);
    }

    function test_AddStrategy_RevertIfNotGovernance() public {
        bytes memory campaignData = abi.encode("test campaign");

        vm.prank(user);
        vm.expectRevert();
        middleman.addStrategy(address(strategy), campaignData);
    }

    function test_RemoveStrategy() public {
        bytes memory campaignData = abi.encode("test campaign");
        middleman.addStrategy(address(strategy), campaignData);

        vm.expectEmit(true, false, false, false);
        emit StrategyRemoved(address(strategy));

        middleman.removeStrategy(address(strategy));

        (address auction, bytes memory data) = middleman.strategies(
            address(strategy)
        );
        assertEq(auction, address(0));
        assertEq(data.length, 0);
    }

    function test_RemoveStrategy_RevertIfNotAdded() public {
        vm.expectRevert("AuctionMiddleMan: Strategy not added");
        middleman.removeStrategy(address(strategy));
    }

    function test_RemoveStrategy_RevertIfNotGovernance() public {
        bytes memory campaignData = abi.encode("test campaign");
        middleman.addStrategy(address(strategy), campaignData);

        vm.prank(user);
        vm.expectRevert();
        middleman.removeStrategy(address(strategy));
    }

    function test_SetAuction() public {
        bytes memory campaignData = abi.encode("test campaign");
        middleman.addStrategy(address(strategy), campaignData);

        address newAuction = address(0x789);
        middleman.setAuction(address(strategy), newAuction);

        (address auction, ) = middleman.strategies(address(strategy));
        assertEq(auction, newAuction);
    }

    function test_SetAuction_RevertIfNotAdded() public {
        address newAuction = address(0x789);
        vm.expectRevert("AuctionMiddleMan: Strategy not added");
        middleman.setAuction(address(strategy), newAuction);
    }

    function test_SetAuction_RevertIfZeroAddress() public {
        bytes memory campaignData = abi.encode("test campaign");
        middleman.addStrategy(address(strategy), campaignData);

        vm.expectRevert("AuctionMiddleMan: zero address");
        middleman.setAuction(address(strategy), address(0));
    }

    function test_SetCampaignData() public {
        bytes memory campaignData = abi.encode("test campaign");
        middleman.addStrategy(address(strategy), campaignData);

        bytes memory newCampaignData = abi.encode("new campaign data");
        middleman.setCampaignData(address(strategy), newCampaignData);

        (, bytes memory data) = middleman.strategies(address(strategy));
        assertEq(data, newCampaignData);
    }

    function test_SetCampaignData_RevertIfNotAdded() public {
        bytes memory newCampaignData = abi.encode("new campaign data");
        vm.expectRevert("AuctionMiddleMan: Strategy not added");
        middleman.setCampaignData(address(strategy), newCampaignData);
    }

    function test_SetCampaignData_RevertIfEmptyData() public {
        bytes memory campaignData = abi.encode("test campaign");
        middleman.addStrategy(address(strategy), campaignData);

        vm.expectRevert("AuctionMiddleMan: campaign data");
        middleman.setCampaignData(address(strategy), "");
    }

    function test_SetCampaignDuration() public {
        uint32 newDuration = 2 weeks;
        middleman.setCampaignDuration(newDuration);

        assertEq(middleman.campaignDuration(), newDuration);
    }

    function test_SetCampaignDuration_RevertIfTooShort() public {
        uint32 shortDuration = 12 hours;
        vm.expectRevert("AuctionMiddleMan: Campaign duration");
        middleman.setCampaignDuration(shortDuration);
    }

    function test_SetKatFee() public {
        uint256 newFee = 1000;
        middleman.setKatFee(newFee);
        assertEq(middleman.katFee(), newFee);
    }

    function test_SetKatFee_RevertIfTooHigh() public {
        uint256 newFee = 1001;
        vm.expectRevert("AuctionMiddleMan: kat fee");
        middleman.setKatFee(newFee);
    }

    function test_SetFeeRecipient() public {
        address newRecipient = address(0x998);
        middleman.setFeeRecipient(newRecipient);
        assertEq(middleman.feeRecipient(), newRecipient);
    }

    function test_Kick_NonKatToken() public {
        MockERC20 toKick = new MockERC20("TOK", "TOK");

        bytes memory campaignData = abi.encode("test campaign");
        middleman.addStrategy(address(strategy), campaignData);

        (address auction, ) = middleman.strategies(address(strategy));

        IAuction(auction).enable(address(toKick));

        deal(address(toKick), address(middleman), 100e18);

        vm.prank(address(strategy));
        uint256 kicked = middleman.kick(address(toKick));

        assertGt(kicked, 0);
    }

    function test_Kick_KatToken() public {
        bytes memory campaignData = abi.encode("test campaign");
        middleman.addStrategy(address(strategy), campaignData);

        // Setup initial KAT balance
        uint256 katBalance = kat.balanceOf(address(middleman));

        vm.prank(address(strategy));
        uint256 kicked = middleman.kick(address(kat));

        assertEq(kicked, katBalance);
    }

    function test_Kick_KatToken_WithKatFee() public {
        uint256 katFee = 500;
        middleman.setKatFee(katFee);

        bytes memory campaignData = abi.encode("test campaign");
        middleman.addStrategy(address(strategy), campaignData);

        uint256 katBalance = kat.balanceOf(address(middleman));
        uint256 fee = (katBalance * katFee) / 10_000;

        vm.prank(address(strategy));
        uint256 kicked = middleman.kick(address(kat));

        assertEq(kicked, katBalance - fee);
        assertEq(kat.balanceOf(feeRecipient), fee);
        assertEq(middleman.lastKatBalance(), katBalance - fee);
    }

    function test_Kick_RevertIfNotStrategy() public {
        vm.prank(user);
        vm.expectRevert("AuctionMiddleMan: Not a strategy");
        middleman.kick(address(otherToken));
    }

    function test_Kick_KatToken_RevertIfNotEnoughWkat() public {
        bytes memory campaignData = abi.encode("test campaign");
        middleman.addStrategy(address(strategy), campaignData);

        // Setup initial KAT balance
        middleman.sweep(address(wkat), 100e18, address(user));

        vm.prank(address(strategy));
        vm.expectRevert("AuctionMiddleMan: not enough WKAT");
        middleman.kick(address(kat));
    }

    function test_WrapKat() public {
        middleman.syncKatBalance();
        uint256 wrapAmount = 100e18;
        uint256 initialKatBalance = kat.balanceOf(address(middleman));
        uint256 currentKatBalance = middleman.lastKatBalance();
        uint256 wrapperKatBalance = kat.balanceOf(address(wkat));

        middleman.wrapKat(wrapAmount);

        assertEq(
            kat.balanceOf(address(middleman)),
            initialKatBalance - wrapAmount
        );
        assertEq(kat.balanceOf(address(wkat)), wrapperKatBalance + wrapAmount);
        assertEq(middleman.lastKatBalance(), currentKatBalance - wrapAmount);
    }

    function test_WrapKat_RevertIfNotEnoughKat() public {
        uint256 tooMuch = kat.balanceOf(address(middleman)) + 1;

        vm.expectRevert("AuctionMiddleMan: not enough KAT");
        middleman.wrapKat(tooMuch);
    }

    function test_WrapKat_RevertIfNotGovernance() public {
        vm.prank(user);
        vm.expectRevert();
        middleman.wrapKat(100e18);
    }

    function test_SyncKatBalance() public {
        uint256 currentBalance = kat.balanceOf(address(middleman));
        middleman.syncKatBalance();

        assertEq(middleman.lastKatBalance(), currentBalance);
    }

    function test_SyncKatBalance_RevertIfNotGovernance() public {
        vm.prank(user);
        vm.expectRevert();
        middleman.syncKatBalance();
    }

    function test_Sweep() public {
        address recipient = address(0x999);
        uint256 sweepAmount = 50e18;

        uint256 initialBalance = otherToken.balanceOf(address(middleman));
        uint256 recipientInitialBalance = otherToken.balanceOf(recipient);

        middleman.sweep(address(otherToken), sweepAmount, recipient);

        assertEq(
            otherToken.balanceOf(address(middleman)),
            initialBalance - sweepAmount
        );
        assertEq(
            otherToken.balanceOf(recipient),
            recipientInitialBalance + sweepAmount
        );
    }

    function test_Sweep_KatToken() public {
        address recipient = address(0x999);
        uint256 sweepAmount = 50e18;
        middleman.syncKatBalance();
        uint256 initialLastKatBalance = middleman.lastKatBalance();

        middleman.sweep(address(kat), sweepAmount, recipient);

        assertEq(
            middleman.lastKatBalance(),
            initialLastKatBalance - sweepAmount
        );
    }

    function test_Sweep_MoreThanBalance() public {
        address recipient = address(0x999);
        uint256 balance = otherToken.balanceOf(address(middleman));
        uint256 tooMuch = balance + 1000e18;

        uint256 recipientInitialBalance = otherToken.balanceOf(recipient);

        middleman.sweep(address(otherToken), tooMuch, recipient);

        // Should sweep only the available balance
        assertEq(otherToken.balanceOf(address(middleman)), 0);
        assertEq(
            otherToken.balanceOf(recipient),
            recipientInitialBalance + balance
        );
    }

    function test_Sweep_RevertIfNotGovernance() public {
        vm.prank(user);
        vm.expectRevert();
        middleman.sweep(address(otherToken), 50e18, address(0x999));
    }

    function testFuzz_AddStrategyWithDifferentData(
        bytes calldata campaignData
    ) public {
        vm.assume(campaignData.length > 0);
        vm.assume(campaignData.length < 1000); // Reasonable size limit

        middleman.addStrategy(address(strategy), campaignData);

        (, bytes memory storedData) = middleman.strategies(address(strategy));
        assertEq(storedData, campaignData);
    }

    function testFuzz_SetCampaignDuration(uint32 duration) public {
        vm.assume(duration > 1 days);
        vm.assume(duration <= 365 days); // Reasonable upper limit

        middleman.setCampaignDuration(duration);

        assertEq(middleman.campaignDuration(), duration);
    }

    function testFuzz_Sweep(uint256 amount) public {
        address recipient = address(0x999);
        uint256 balance = otherToken.balanceOf(address(middleman));

        middleman.sweep(address(otherToken), amount, recipient);

        uint256 expectedSwept = amount > balance ? balance : amount;
        assertEq(otherToken.balanceOf(recipient), expectedSwept);
    }
}

// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import {Governance} from "@periphery/utils/Governance.sol";
import {IAuction} from "./interfaces/IAuction.sol";
import {IStrategyInterface} from "./interfaces/IStrategyInterface.sol";
import {IDistributionCreator, CampaignParameters} from "./interfaces/IDistributionCreator.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IAuctionFactory {
    function createNewAuction(
        address _want,
        address _receiver,
        address _governance
    ) external returns (address);
}

/// @title AuctionMiddleMan
/// @dev Serves as the `auction` contract for strategies that receive KAT tokens.
///    Will simply forward any kicks to a real auction contract for non-KAT tokens.
///    For KAT tokens, it will create a campaign with MERKL for the amount kicked.
contract AuctionMiddleMan is Governance {
    using SafeERC20 for ERC20;

    modifier onlyAddedStrategy() {
        require(
            _isAddedStrategy(msg.sender),
            "AuctionMiddleMan: Not a strategy"
        );
        _;
    }

    function _isAddedStrategy(address _strategy) internal view returns (bool) {
        return auctions[_strategy] != address(0);
    }

    IAuctionFactory public constant AUCTION_FACTORY =
        IAuctionFactory(0xCfA510188884F199fcC6e750764FAAbE6e56ec40);

    IDistributionCreator public constant DISTRIBUTION_CREATOR =
        IDistributionCreator(0x8BB4C975Ff3c250e0ceEA271728547f3802B36Fd);

    address public constant KAT = 0x7F1f4b4b29f5058fA32CC7a97141b8D7e5ABDC2d;

    address public constant WKAT = 0x3ba1fbC4c3aEA775d335b31fb53778f46FD3a330;

    address public constant KAT_WRAPPER =
        0xF057afeEc22E220f47AD4220871364e9E828b2e9;

    mapping(address => address) public auctions;

    uint256 public lastKatBalance;

    uint32 public campaignDuration;

    constructor(address _governance) Governance(_governance) {
        campaignDuration = 1 weeks;
    }

    function addStrategy(address _strategy) external onlyGovernance {
        require(
            auctions[_strategy] == address(0),
            "AuctionMiddleMan: Strategy already added"
        );
        address asset = IStrategyInterface(_strategy).asset();
        address management = IStrategyInterface(_strategy).management();
        address auction = AUCTION_FACTORY.createNewAuction(
            asset,
            management,
            address(this)
        );
        auctions[_strategy] = auction;
    }

    function removeStrategy(address _strategy) external onlyGovernance {
        address auction = auctions[_strategy];
        require(auction != address(0), "AuctionMiddleMan: not added");
        auctions[_strategy] = address(0);
    }

    function setAuction(
        address _strategy,
        address _auction
    ) external onlyGovernance {
        require(
            auctions[_strategy] != address(0),
            "AuctionMiddleMan: not added"
        );
        require(_auction != address(0), "AuctionMiddleMan: zero address");
        auctions[_strategy] = _auction;
    }

    function setCampaignDuration(
        uint32 _campaignDuration
    ) external onlyGovernance {
        require(
            _campaignDuration > 1 days,
            "AuctionMiddleMan: Campaign duration"
        );
        campaignDuration = _campaignDuration;
    }

    function isActive(address _token) external view returns (bool) {
        return IAuction(auctions[msg.sender]).isActive(_token);
    }

    function available(address _token) external view returns (uint256) {
        return IAuction(auctions[msg.sender]).available(_token);
    }

    function kick(address _token) external onlyAddedStrategy returns (uint256) {
        if (_token == KAT || _token == WKAT) {
            _createCampaign(msg.sender);
        } else {
            uint256 _kicked = ERC20(_token).balanceOf(address(this));

            if (_kicked > 0) {
                ERC20(_token).safeTransfer(auctions[msg.sender], _kicked);
            }

            return IAuction(auctions[msg.sender]).kick(_token);
        }
    }

    function _createCampaign(address _strategy) internal {
        uint256 katBalance = ERC20(KAT).balanceOf(address(this));
        uint256 kicked = katBalance - lastKatBalance;

        if (kicked == 0) return;

        require(
            ERC20(WKAT).balanceOf(address(this)) >= kicked,
            "AuctionMiddleMan: not enough WKAT"
        );

        // Update lastKatBalance for next kick
        lastKatBalance = katBalance;

        ERC20(WKAT).forceApprove(address(DISTRIBUTION_CREATOR), kicked);

        DISTRIBUTION_CREATOR.createCampaign(
            CampaignParameters({
                campaignId: bytes32(0),
                creator: address(0),
                rewardToken: WKAT,
                amount: kicked,
                campaignType: 4, // ??
                startTimestamp: uint32(block.timestamp),
                duration: campaignDuration,
                campaignData: "" // ???
            })
        );
    }

    function wrapKat(uint256 _amount) external onlyGovernance {
        require(
            ERC20(KAT).balanceOf(address(this)) >= _amount,
            "AuctionMiddleMan: not enough KAT"
        );
        ERC20(KAT).safeTransfer(KAT_WRAPPER, _amount);

        lastKatBalance -= _amount;
    }

    function syncKatBalance() external onlyGovernance {
        lastKatBalance = ERC20(KAT).balanceOf(address(this));
    }

    function sweep(
        address _token,
        uint256 _amount,
        address _to
    ) external onlyGovernance {
        uint256 balance = ERC20(_token).balanceOf(address(this));
        if (balance < _amount) {
            _amount = balance;
        }

        if (_token == KAT) {
            lastKatBalance -= _amount;
        }

        ERC20(_token).safeTransfer(_to, _amount);
    }
}

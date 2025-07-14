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

    struct Strategy {
        address auction;
        bytes campaignData;
    }

    modifier onlyAddedStrategy() {
        require(
            _isAddedStrategy(msg.sender),
            "AuctionMiddleMan: Not a strategy"
        );
        _;
    }

    function _isAddedStrategy(address _strategy) internal view returns (bool) {
        return strategies[_strategy].auction != address(0);
    }

    IAuctionFactory public constant AUCTION_FACTORY =
        IAuctionFactory(0xCfA510188884F199fcC6e750764FAAbE6e56ec40);

    IDistributionCreator public constant DISTRIBUTION_CREATOR =
        IDistributionCreator(0x8BB4C975Ff3c250e0ceEA271728547f3802B36Fd);

    address public constant KAT = 0x7F1f4b4b29f5058fA32CC7a97141b8D7e5ABDC2d;

    address public constant WKAT = 0x6E9C1F88a960fE63387eb4b71BC525a9313d8461;

    mapping(address => Strategy) public strategies;

    uint256 public lastKatBalance;

    uint32 public campaignDuration;

    constructor(address _governance) Governance(_governance) {
        campaignDuration = 1 weeks;
        DISTRIBUTION_CREATOR.acceptConditions();
    }

    function addStrategy(
        address _strategy,
        bytes calldata _campaignData
    ) external onlyGovernance {
        require(
            !_isAddedStrategy(_strategy),
            "AuctionMiddleMan: Strategy already added"
        );
        require(_campaignData.length > 0, "AuctionMiddleMan: campaign data");

        address asset = IStrategyInterface(_strategy).asset();
        address management = IStrategyInterface(_strategy).management();
        address auction = AUCTION_FACTORY.createNewAuction(
            asset, // want
            _strategy, // receiver
            management // governance
        );
    
        strategies[_strategy] = Strategy({
            auction: auction,
            campaignData: _campaignData
        });
    }

    function removeStrategy(address _strategy) external onlyGovernance {
        require(
            _isAddedStrategy(_strategy),
            "AuctionMiddleMan: Strategy not added"
        );
        delete strategies[_strategy];
    }

    function setAuction(
        address _strategy,
        address _auction
    ) external onlyGovernance {
        require(
            _isAddedStrategy(_strategy),
            "AuctionMiddleMan: Strategy not added"
        );
        require(_auction != address(0), "AuctionMiddleMan: zero address");
        strategies[_strategy].auction = _auction;
    }

    function setCampaignData(
        address _strategy,
        bytes calldata _campaignData
    ) external onlyGovernance {
        require(
            _isAddedStrategy(_strategy),
            "AuctionMiddleMan: Strategy not added"
        );
        require(_campaignData.length > 0, "AuctionMiddleMan: campaign data");
        strategies[_strategy].campaignData = _campaignData;
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
        return IAuction(strategies[msg.sender].auction).isActive(_token);
    }

    function available(address _token) external view returns (uint256) {
        return IAuction(strategies[msg.sender].auction).available(_token);
    }

    function kick(address _token) external onlyAddedStrategy returns (uint256) {
        if (_token == KAT || _token == WKAT) {
            return _createCampaign(strategies[msg.sender].campaignData);
        } else {
            uint256 _kicked = ERC20(_token).balanceOf(address(this));
            address auction = strategies[msg.sender].auction;

            if (_kicked > 0) {
                ERC20(_token).safeTransfer(auction, _kicked);
            }

            return IAuction(auction).kick(_token);
        }
    }

    function _createCampaign(
        bytes memory _campaignData
    ) internal returns (uint256) {
        uint256 katBalance = ERC20(KAT).balanceOf(address(this));
        uint256 kicked = katBalance - lastKatBalance;

        if (kicked == 0) return 0;

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
                campaignType: 18,
                startTimestamp: uint32(block.timestamp),
                duration: campaignDuration,
                campaignData: _campaignData
            })
        );

        return kicked;
    }

    function wrapKat(uint256 _amount) external onlyGovernance {
        require(
            ERC20(KAT).balanceOf(address(this)) >= _amount,
            "AuctionMiddleMan: not enough KAT"
        );
        ERC20(KAT).safeTransfer(WKAT, _amount);

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

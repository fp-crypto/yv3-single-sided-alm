// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

interface IAuctionMiddleMan {
    event CampaignDurationSet(uint32 campaignDuration);
    event FeeRecipientSet(address feeRecipient);
    event GovernanceTransferred(address indexed previousGovernance, address indexed newGovernance);
    event KatFeeSet(uint256 katFee);
    event StrategyAdded(address indexed strategy);
    event StrategyRemoved(address indexed strategy);
    function AUCTION_FACTORY() external view returns (address);
    function DISTRIBUTION_CREATOR() external view returns (address);
    function KAT() external view returns (address);
    function WKAT() external view returns (address);
    function addStrategy(address _strategy, bytes calldata _campaignData) external;
    function available(address _token) external view returns (uint256);
    function campaignDuration() external view returns (uint32);
    function feeRecipient() external view returns (address);
    function governance() external view returns (address);
    function isActive(address _token) external view returns (bool);
    function katFee() external view returns (uint256);
    function kick(address _token) external returns (uint256);
    function lastKatBalance() external view returns (uint256);
    function receiver() external view returns (address);
    function removeStrategy(address _strategy) external;
    function setAuction(address _strategy, address _auction) external;
    function setCampaignData(address _strategy, bytes calldata _campaignData) external;
    function setCampaignDuration(uint32 _campaignDuration) external;
    function setFeeRecipient(address _feeRecipient) external;
    function setKatFee(uint256 _katFee) external;
    function strategies(address ) external view returns (address auction, bytes memory campaignData);
    function sweep(address _token, uint256 _amount, address _to) external;
    function syncKatBalance() external;
    function transferGovernance(address _newGovernance) external;
    function want() external view returns (address);
    function wrapKat(uint256 _amount) external;
}


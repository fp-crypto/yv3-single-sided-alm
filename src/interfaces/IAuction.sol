// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

interface IAuction {
    event AuctionDisabled(address indexed from, address indexed to);
    event AuctionEnabled(address indexed from, address indexed to);
    event AuctionKicked(address from, uint256 available);
    event GovernanceTransferred(
        address indexed previousGovernance,
        address indexed newGovernance
    );
    event UpdatePendingGovernance(address indexed newPendingGovernance);
    event UpdatedStartingPrice(uint256 startingPrice);

    struct AuctionInfo {
        uint64 kicked;
        uint64 scaler;
        uint128 initialAvailable;
    }

    function acceptGovernance() external;
    function auctionLength() external view returns (uint256);
    function auctions(address) external view returns (AuctionInfo memory);
    function available(address _from) external view returns (uint256);
    function disable(address _from) external;
    function disable(address _from, uint256 _index) external;
    function enable(address _from) external;
    function enabledAuctions(uint256) external view returns (address);
    function getAllEnabledAuctions() external view returns (address[] memory);
    function getAmountNeeded(address _from) external view returns (uint256);
    function getAmountNeeded(
        address _from,
        uint256 _amountToTake,
        uint256 _timestamp
    ) external view returns (uint256);
    function getAmountNeeded(
        address _from,
        uint256 _amountToTake
    ) external view returns (uint256);
    function governance() external view returns (address);
    function initialize(
        address _want,
        address _receiver,
        address _governance,
        uint256 _auctionLength,
        uint256 _startingPrice
    ) external;
    function isActive(address _from) external view returns (bool);
    function isValidSignature(
        bytes32 _hash,
        bytes calldata signature
    ) external view returns (bytes4);
    function kick(address _from) external returns (uint256 _available);
    function kickable(address _from) external view returns (uint256);
    function kicked(address _from) external view returns (uint256);
    function pendingGovernance() external view returns (address);
    function price(
        address _from,
        uint256 _timestamp
    ) external view returns (uint256);
    function price(address _from) external view returns (uint256);
    function receiver() external view returns (address);
    function setStartingPrice(uint256 _startingPrice) external;
    function settle(address _from) external;
    function startingPrice() external view returns (uint256);
    function sweep(address _token) external;
    function take(address _from) external returns (uint256);
    function take(address _from, uint256 _maxAmount) external returns (uint256);
    function take(
        address _from,
        uint256 _maxAmount,
        address _receiver,
        bytes calldata _data
    ) external returns (uint256);
    function take(
        address _from,
        uint256 _maxAmount,
        address _receiver
    ) external returns (uint256);
    function transferGovernance(address _newGovernance) external;
    function want() external view returns (address);
}

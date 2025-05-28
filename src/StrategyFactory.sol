// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

import {Strategy} from "./Strategy.sol";
import {IStrategyInterface} from "./interfaces/IStrategyInterface.sol";

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {EnumerableMap} from "@openzeppelin/contracts/utils/structs/EnumerableMap.sol";

contract StrategyFactory {
    using EnumerableSet for EnumerableSet.AddressSet;
    using EnumerableMap for EnumerableMap.Bytes32ToAddressMap;

    event NewStrategy(
        address indexed strategy,
        address indexed asset,
        address indexed lp
    );

    address public immutable emergencyAdmin;

    address public management;
    address public performanceFeeRecipient;
    address public keeper;

    /// @notice Track the deployments keccak(asset+lp) => strategy
    EnumerableMap.Bytes32ToAddressMap private _deploymentMapping;
    EnumerableSet.AddressSet private _deployments;

    constructor(
        address _management,
        address _performanceFeeRecipient,
        address _keeper,
        address _emergencyAdmin
    ) {
        management = _management;
        performanceFeeRecipient = _performanceFeeRecipient;
        keeper = _keeper;
        emergencyAdmin = _emergencyAdmin;
    }

    /**
     * @notice Deploys a new Strategy.
     * @param _asset The underlying asset for the strategy to use
     * @param _name The name for the strategy
     * @param _steerLP The Steer LP contract address
     * @return The address of the new strategy
     */
    function newStrategy(
        address _asset,
        string calldata _name,
        address _steerLP
    ) external virtual returns (address) {
        bytes32 strategyKey = getStrategyKey(_asset, _steerLP);
        require(!_deploymentMapping.contains(strategyKey), "!new");

        // tokenized strategies available setters.
        IStrategyInterface _newStrategy = IStrategyInterface(
            address(new Strategy(_asset, _name, _steerLP))
        );

        _newStrategy.setPerformanceFeeRecipient(performanceFeeRecipient);
        _newStrategy.setKeeper(keeper);
        _newStrategy.setPendingManagement(management);
        _newStrategy.setEmergencyAdmin(emergencyAdmin);

        emit NewStrategy(address(_newStrategy), _asset, _steerLP);

        _deployments.add(address(_newStrategy));
        _deploymentMapping.set(strategyKey, address(_newStrategy));
        return address(_newStrategy);
    }

    /**
     * @notice Sets the factory addresses
     * @param _management New management address
     * @param _performanceFeeRecipient New performance fee recipient address
     * @param _keeper New keeper address
     */
    function setAddresses(
        address _management,
        address _performanceFeeRecipient,
        address _keeper
    ) external {
        require(msg.sender == management, "!management");
        management = _management;
        performanceFeeRecipient = _performanceFeeRecipient;
        keeper = _keeper;
    }

    function deployments() external view returns (address[] memory) {
        return _deployments.values();
    }

    /**
     * @notice Checks if a strategy was deployed by this factory
     * @param _strategy The strategy address to check
     * @return Whether the strategy was deployed by this factory
     */
    function isDeployedStrategy(
        address _strategy
    ) external view returns (bool) {
        return _deployments.contains(_strategy);
    }

    function getStrategyForAssetLpPair(
        address _asset,
        address _lp
    ) external view returns (address _strategy) {
        bytes32 strategyKey = getStrategyKey(_asset, _lp);
        (, _strategy) = _deploymentMapping.tryGet(strategyKey);
    }

    function getStrategyKey(
        address _asset,
        address _lp
    ) private pure returns (bytes32) {
        return keccak256(abi.encodePacked(_asset, _lp));
    }
}

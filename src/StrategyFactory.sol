// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

import {Strategy} from "./Strategy.sol";
import {IStrategyInterface} from "./interfaces/IStrategyInterface.sol";

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

contract StrategyFactory {
    using EnumerableSet for EnumerableSet.AddressSet;

    event NewStrategy(
        address indexed strategy,
        address indexed asset,
        address indexed lp
    );

    address public immutable emergencyAdmin;

    address public management;
    address public performanceFeeRecipient;
    address public keeper;

    /// @notice Track the deployments asset => lp => strategy
    mapping(address => mapping(address => address)) private _deploymentMapping;
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
        require(_deploymentMapping[_asset][_steerLP] == address(0), "!new");

        // tokenized strategies available setters.
        IStrategyInterface _newStrategy = IStrategyInterface(
            address(new Strategy(_asset, _name, _steerLP))
        );
        emit NewStrategy(address(_newStrategy), _asset, _steerLP);
        _deployments.add(address(_newStrategy));
        _deploymentMapping[_asset][_steerLP] = address(_newStrategy);

        _newStrategy.setPerformanceFeeRecipient(performanceFeeRecipient);
        _newStrategy.setKeeper(keeper);
        _newStrategy.setPendingManagement(management);
        _newStrategy.setEmergencyAdmin(emergencyAdmin);

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
        return _deploymentMapping[_asset][_lp];
    }
}

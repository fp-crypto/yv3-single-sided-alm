// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "forge-std/console.sol";
import {Script} from "forge-std/Script.sol";
import {CreateXScript, ICreateX} from "../../lib/createx-forge/script/CreateXScript.sol";
import {StrategyFactory} from "../StrategyFactory.sol";

contract DeployCreateX is Script, CreateXScript {
    bytes32 private constant SALT = keccak256("Yearn Vaults V3");
    address private me = 0x787aba336583f4A1D4f8cBBFDFFD49f3a38De665;
    address private sms = 0xBe7c7efc1ef3245d37E3157F76A512108D6D7aE6;
    address private tks = 0x283132390eA87D6ecc20255B59Ba94329eE17961;

    function run() public {
        bytes memory constructorArgs = abi.encode(
            me, // address _management,
            sms, // address _performanceFeeRecipient,
            tks, // address _keeper,
            sms // address _emergencyAdmin,
        );

        console.log("msg.sender: %s", msg.sender);
        console.log("constructorArgs");
        console.logBytes(constructorArgs);

        bytes memory initCode = abi.encodePacked(
            type(StrategyFactory).creationCode,
            constructorArgs
        );

        // Calculate the predetermined address of the contract
        address computedAddress = CreateX.computeCreate2Address(
            keccak256(abi.encodePacked(SALT)),
            keccak256(initCode)
        );

        console.log("Computed: %s", computedAddress);

        // Deploy using CREATE2
        vm.startBroadcast(me);
        address deployedAddress = CreateX.deployCreate2(SALT, initCode);
        vm.stopBroadcast();

        console.log("Deployed: %s", deployedAddress);

        // Check to make sure that contract is on the expected address
        require(computedAddress == deployedAddress, "!match");
    }
}

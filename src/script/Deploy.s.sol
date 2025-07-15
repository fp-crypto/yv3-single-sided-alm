// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {AuctionMiddleMan} from "../../src/AuctionMiddleMan.sol";
import {console} from "forge-std/console.sol";

contract Deploy is Script {
    function run() public {
        address governance = 0xBe7c7efc1ef3245d37E3157F76A512108D6D7aE6;
        vm.startBroadcast();
        AuctionMiddleMan middleman = new AuctionMiddleMan(
            governance,
            governance
        );

        console.log("middleman", address(middleman));
        vm.stopBroadcast();
    }
}

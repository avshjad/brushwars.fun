// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {BrushWars} from "../contracts/BrushWars.sol";

contract Deploy is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        // For testing, operator == your dev address (acts as both owner & operator).
        // On MAINNET use a SEPARATE operator key.
        address operator = vm.envAddress("DEV_ADDRESS");

        // Tiny testnet prices so testing is cheap.
        uint256 normalPrice = 0.01 ether;  // "normal brush"
        uint256 goldenPrice = 0.05 ether;  // "golden brush"

        vm.startBroadcast(pk);
        BrushWars game = new BrushWars(normalPrice, goldenPrice, operator);
        game.startRound();
        vm.stopBroadcast();

        console.log("BrushWars deployed at:", address(game));
        console.log("Operator/owner:", operator);
    }
}

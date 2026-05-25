// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {BrushWars} from "../contracts/BrushWars.sol";

/*
 * Mainnet deploy with the owner/operator split.
 *   - OWNER  = the deployer (OWNER_PK) — your main/safe wallet. Receives 70%,
 *     can start rounds, set operator/prices. Keep this key safe.
 *   - OPERATOR = OPERATOR_ADDRESS — the dedicated gas-only wallet that runs the
 *     server. Can only report results; cannot touch funds.
 *
 * Set REAL prices for mainnet via env (in wei) so they match your intended
 * USD targets at the current MON price. Does NOT auto-start a round — you call
 * startRound() yourself when you're ready to go live.
 *
 * Required env:
 *   OWNER_PK           - private key of the owner/deployer wallet
 *   OPERATOR_ADDRESS   - address of the dedicated operator wallet
 *   NORMAL_PRICE_WEI   - normal brush price in wei
 *   GOLDEN_PRICE_WEI   - golden brush price in wei
 */
contract DeployMainnet is Script {
    function run() external {
        uint256 ownerPk    = vm.envUint("OWNER_PK");
        address operator   = vm.envAddress("OPERATOR_ADDRESS");
        uint256 normalPrice = vm.envUint("NORMAL_PRICE_WEI");
        uint256 goldenPrice = vm.envUint("GOLDEN_PRICE_WEI");

        require(operator != address(0), "operator unset");
        require(normalPrice > 0 && goldenPrice > 0, "prices unset");

        vm.startBroadcast(ownerPk);
        BrushWars game = new BrushWars(normalPrice, goldenPrice, operator);
        // NOTE: no startRound() here — start it manually when ready:
        //   cast send <addr> "startRound()" --rpc-url <monad> --private-key $OWNER_PK
        vm.stopBroadcast();

        console.log("BrushWars (mainnet) deployed at:", address(game));
        console.log("Owner = the deployer wallet (0x083a...)");
        console.log("Operator:", operator);
        console.log("Normal price (wei):", normalPrice);
        console.log("Golden price (wei):", goldenPrice);
    }
}

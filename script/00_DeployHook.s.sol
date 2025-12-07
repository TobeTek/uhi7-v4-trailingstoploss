// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {BaseScript} from "./base/BaseScript.sol";

import {TrailingLimitOrderHook} from "../src/TrailingLimitOrderHook.sol";

/// @notice Mines the address and deploys the TrailingLimitOrderHook.sol Hook contract
contract DeployHookScript is BaseScript {
    function run() public {
        // hook contracts must have specific flags encoded in the address
        uint160 flags = uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG);
        string memory hookURI = "https://metadata.example.com/{id}.json";

        // Mine a salt that will produce a hook address with the correct flags
        bytes memory constructorArgs = abi.encode(poolManager, hookURI);
        (address hookAddress, bytes32 salt) =
            HookMiner.find(CREATE2_FACTORY, flags, type(TrailingLimitOrderHook).creationCode, constructorArgs);

        // Deploy the hook using CREATE2
        vm.startBroadcast();
        TrailingLimitOrderHook trailingOrderHook = new TrailingLimitOrderHook{salt: salt}(poolManager, hookURI);
        vm.stopBroadcast();

        require(address(trailingOrderHook) == hookAddress, "DeployHookScript: Hook Address Mismatch");
    }
}

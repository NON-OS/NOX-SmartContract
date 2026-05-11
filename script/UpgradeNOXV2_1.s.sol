// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Script.sol";
import {NONOS_NOX_MAINNET_V2_1 as V21} from "../contracts/token/NOXTokenV2_1.sol";

interface IProxy {
    function upgradeToAndCall(address, bytes calldata) external payable;
}

contract UpgradeNOXV2_1 is Script {
    address constant PROXY = 0x0a26c80Be4E060e688d7C23aDdB92cBb5D2C9eCA;

    function run() external {
        uint256 maxChunk = vm.envUint("MAX_AUTOSWAP_CHUNK");
        address ethFb = vm.envAddress("ETH_FALLBACK_RECIPIENT");
        bool execute = vm.envOr("EXECUTE_UPGRADE", false);

        require(maxChunk > 0, "MAX_AUTOSWAP_CHUNK must be > 0");
        require(ethFb != address(0), "ETH_FALLBACK_RECIPIENT must be set");

        vm.startBroadcast();

        V21 impl = new V21();
        console2.log("New implementation:", address(impl));

        bytes memory initData = abi.encodeCall(V21.reinitV21, (maxChunk, ethFb));
        bytes memory upgradeCall = abi.encodeCall(IProxy.upgradeToAndCall, (address(impl), initData));

        console2.log("---- Calldata for upgradeToAndCall ----");
        console2.log("to:    ", PROXY);
        console2.log("data (hex):");
        console2.logBytes(upgradeCall);
        console2.log("---------------------------------------");
        console2.log("After upgrade succeeds, run setFees(250,250,0,1000,4000,2000,3000) via UpdateNOXFees.s.sol");

        if (execute) {
            console2.log("EXECUTE_UPGRADE=true; performing upgradeToAndCall now.");
            IProxy(PROXY).upgradeToAndCall(address(impl), initData);
        } else {
            console2.log("EXECUTE_UPGRADE not set; calldata printed only.");
        }

        vm.stopBroadcast();
    }
}

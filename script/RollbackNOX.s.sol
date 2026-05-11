// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Script.sol";

interface IProxy {
    function upgradeToAndCall(address, bytes calldata) external payable;
}

contract RollbackNOX is Script {
    address constant PROXY = 0x0a26c80Be4E060e688d7C23aDdB92cBb5D2C9eCA;
    address constant PRIOR_IMPL = 0xF57a30672A72Fa7fBC8004FfcB12DafC7ea882D7;

    function run() external {
        bool execute = vm.envOr("EXECUTE_ROLLBACK", false);

        bytes memory cd = abi.encodeCall(IProxy.upgradeToAndCall, (PRIOR_IMPL, ""));
        console2.log("---- ROLLBACK CALLDATA (sign with UPGRADER_ROLE) ----");
        console2.log("to:   ", PROXY);
        console2.log("data:");
        console2.logBytes(cd);
        console2.log("------------------------------------------------------");
        console2.log("AFTER ROLLBACK, immediately:");
        console2.log("  setAutoSwapConfig(1000e18, 100, false) to neutralise pre-V2.1 risks.");

        if (execute) {
            vm.startBroadcast();
            IProxy(PROXY).upgradeToAndCall(PRIOR_IMPL, "");
            console2.log("Rollback executed.");
            vm.stopBroadcast();
        } else {
            console2.log("EXECUTE_ROLLBACK not set; calldata printed only.");
        }
    }
}

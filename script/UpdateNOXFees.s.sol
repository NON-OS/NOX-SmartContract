// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Script.sol";

interface INOXFees {
    function setFees(
        uint16 buyBps,
        uint16 sellBps,
        uint16 transferBps,
        uint16 burnShareBps,
        uint16 liqShareBps,
        uint16 treShareBps,
        uint16 devShareBps
    ) external;
    function fees() external view returns (uint16, uint16, uint16, uint16, uint16, uint16, uint16);
}

contract UpdateNOXFees is Script {
    address constant PROXY = 0x0a26c80Be4E060e688d7C23aDdB92cBb5D2C9eCA;

    uint16 constant BUY_BPS = 250;
    uint16 constant SELL_BPS = 250;
    uint16 constant TRANSFER_BPS = 0;
    uint16 constant BURN_SHARE_BPS = 1000;
    uint16 constant LIQ_SHARE_BPS = 4000;
    uint16 constant TRE_SHARE_BPS = 2000;
    uint16 constant DEV_SHARE_BPS = 3000;

    function run() external {
        bool execute = vm.envOr("EXECUTE", false);

        bytes memory cd = abi.encodeCall(
            INOXFees.setFees,
            (BUY_BPS, SELL_BPS, TRANSFER_BPS, BURN_SHARE_BPS, LIQ_SHARE_BPS, TRE_SHARE_BPS, DEV_SHARE_BPS)
        );
        console2.log("---- setFees calldata (sign with GOVERNOR_ROLE) ----");
        console2.log("to:   ", PROXY);
        console2.log("data:");
        console2.logBytes(cd);
        console2.log("----------------------------------------------------");

        if (execute) {
            vm.startBroadcast();
            INOXFees(PROXY)
                .setFees(BUY_BPS, SELL_BPS, TRANSFER_BPS, BURN_SHARE_BPS, LIQ_SHARE_BPS, TRE_SHARE_BPS, DEV_SHARE_BPS);
            (uint16 buy, uint16 sell, uint16 transfer_,,,,) = INOXFees(PROXY).fees();
            require(buy == 250 && sell == 250 && transfer_ == 0, "fees not applied");
            console2.log("setFees applied: 2.5% / 2.5% / 0%.");
            vm.stopBroadcast();
        } else {
            console2.log("EXECUTE not set; calldata printed only.");
        }
    }
}

// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {FeeSwapRouter} from "../contracts/marketplace/revenue/FeeSwapRouter.sol";

contract DeployFeeSwapRouter is Script {
    address constant UNISWAP_V2_ROUTER = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
    address constant APP_TOKEN_FACTORY = 0xa248f486fD838B315883026197cda96387f9E7Dc;

    function run() external returns (address proxy, address impl) {
        uint256 pk = vm.envUint("DEPLOYER_PK");
        address admin    = vm.envAddress("FINAL_DAO_SAFE");
        address config   = vm.envOr("FINAL_CONFIG_SAFE", admin);
        address pauser   = vm.envOr("FINAL_PAUSER_SAFE", admin);
        address upgrader = vm.envOr("FINAL_UPGRADE_SAFE", admin);
        address treasury = vm.envOr("FINAL_TREASURY_SAFE", admin);
        uint256 feeBps   = vm.envOr("FEE_BPS", uint256(10));

        require(admin != address(0),    "FINAL_DAO_SAFE not set");
        require(treasury != address(0), "treasury not set");
        require(feeBps <= 100,          "FEE_BPS over cap");

        vm.startBroadcast(pk);

        FeeSwapRouter logic = new FeeSwapRouter();
        bytes memory init = abi.encodeCall(
            FeeSwapRouter.initialize,
            (admin, config, pauser, upgrader, treasury, uint16(feeBps))
        );
        ERC1967Proxy p = new ERC1967Proxy(address(logic), init);
        FeeSwapRouter router = FeeSwapRouter(payable(address(p)));

        router.setTargetApproved(UNISWAP_V2_ROUTER, true);
        router.setAppTokenFactory(APP_TOKEN_FACTORY);

        vm.stopBroadcast();

        console.log("impl:", address(logic));
        console.log("proxy:", address(p));
        console.log("admin:", admin);
        console.log("config:", config);
        console.log("pauser:", pauser);
        console.log("upgrader:", upgrader);
        console.log("treasury:", treasury);
        console.log("feeBps:", feeBps);
        console.log("v2 router approved:", UNISWAP_V2_ROUTER);
        console.log("app token factory wired:", APP_TOKEN_FACTORY);

        return (address(p), address(logic));
    }
}

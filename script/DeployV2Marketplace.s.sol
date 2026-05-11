// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";

import {AppBondingTokenV2}   from "../contracts/marketplace/core/AppBondingTokenV2.sol";
import {AppTokenFactoryV2}   from "../contracts/marketplace/core/AppTokenFactoryV2.sol";

contract DeployV2Marketplace is Script {
    address constant UNI_V2_FACTORY = 0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f;
    address constant UNI_V2_ROUTER  = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
    address constant WETH           = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant LP_BURN        = address(0x000000000000000000000000000000000000dEaD);

    address constant FACTORY_PROXY  = 0xa248f486fD838B315883026197cda96387f9E7Dc;

    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PK");
        address deployer = vm.addr(pk);

        console.log("== V2 Marketplace deploy ==");
        console.log("deployer       :", deployer);
        console.log("factory proxy  :", FACTORY_PROXY);
        console.log("uniV2 factory  :", UNI_V2_FACTORY);
        console.log("uniV2 router   :", UNI_V2_ROUTER);
        console.log("WETH           :", WETH);
        console.log("LP burn        :", LP_BURN);

        vm.startBroadcast(pk);

        AppBondingTokenV2 v2TokenImpl = new AppBondingTokenV2();
        console.log("AppBondingTokenV2 impl :", address(v2TokenImpl));

        AppTokenFactoryV2 v2FactoryImpl = new AppTokenFactoryV2();
        console.log("AppTokenFactoryV2 impl :", address(v2FactoryImpl));

        vm.stopBroadcast();

        console.log("");
        console.log("== Next steps (manual) ==");
        console.log("1. UpgradeFactoryV2.s.sol  : UUPS-upgrade %s to impl %s", FACTORY_PROXY, address(v2FactoryImpl));
        console.log("2. Call initializeV2(%s, WETH, UniV2Factory, UniV2Router, LP_BURN)", address(v2TokenImpl));
        console.log("3. (DO NOT) setLaunchEnabled(true) until fork dry-run + frontend wired + Safe rotation");
    }
}

contract UpgradeFactoryV2 is Script {
    address constant FACTORY_PROXY  = 0xa248f486fD838B315883026197cda96387f9E7Dc;
    address constant UNI_V2_FACTORY = 0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f;
    address constant UNI_V2_ROUTER  = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
    address constant WETH           = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant LP_BURN        = address(0x000000000000000000000000000000000000dEaD);

    function run() external {
        uint256 pk            = vm.envUint("DEPLOYER_PK");
        address newFactoryImpl = vm.envAddress("FACTORY_V2_IMPL");
        address tokenImplV2    = vm.envAddress("BONDING_TOKEN_V2_IMPL");
        address deployer       = vm.addr(pk);

        console.log("== Factory V2 upgrade + reinit ==");
        console.log("upgrader (must hold UPGRADER_ROLE) :", deployer);
        console.log("proxy                              :", FACTORY_PROXY);
        console.log("new factory impl                   :", newFactoryImpl);
        console.log("V2 bonding token impl              :", tokenImplV2);

        vm.startBroadcast(pk);

        AppTokenFactoryV2 proxy = AppTokenFactoryV2(FACTORY_PROXY);

        proxy.upgradeToAndCall(
            newFactoryImpl,
            abi.encodeCall(
                AppTokenFactoryV2.initializeV2,
                (tokenImplV2, WETH, UNI_V2_FACTORY, UNI_V2_ROUTER, LP_BURN)
            )
        );

        require(proxy.bondingTokenImplV2() == tokenImplV2, "V2 impl pointer not set");
        require(proxy.weth() == WETH,                       "WETH not set");
        require(proxy.uniV2Factory() == UNI_V2_FACTORY,     "uniV2Factory not set");
        require(proxy.uniV2Router() == UNI_V2_ROUTER,       "uniV2Router not set");
        require(proxy.lpBurnTo() == LP_BURN,                "lpBurnTo not set");
        require(!proxy.launchEnabled(),                     "launchEnabled must remain FALSE");

        vm.stopBroadcast();

        console.log("");
        console.log("== Post-conditions ==");
        console.log("bondingTokenImplV2() :", proxy.bondingTokenImplV2());
        console.log("weth()               :", proxy.weth());
        console.log("uniV2Factory()       :", proxy.uniV2Factory());
        console.log("uniV2Router()        :", proxy.uniV2Router());
        console.log("lpBurnTo()           :", proxy.lpBurnTo());
        console.log("launchEnabled()      :", proxy.launchEnabled());
    }
}

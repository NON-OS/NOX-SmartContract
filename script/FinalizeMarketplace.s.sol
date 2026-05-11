// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";

import {CapsuleRegistry}     from "../contracts/marketplace/core/CapsuleRegistry.sol";
import {AppTokenFactory}     from "../contracts/marketplace/core/AppTokenFactory.sol";
import {FeeRouter}           from "../contracts/marketplace/revenue/FeeRouter.sol";
import {EntitlementRegistry} from "../contracts/marketplace/entitlement/EntitlementRegistry.sol";
import {ReceiptSettlement}   from "../contracts/marketplace/entitlement/ReceiptSettlement.sol";

contract Finalize is Script {
    struct Targets {
        address admin;
        address upgrader;
        address pauser;
        address validator;
        address config;
        address treasury;
    }

    struct Deployments {
        address registry;
        address factory;
        address router;
        address entitlement;
        address settlement;
    }

    function run() external {
        uint256 deployerPk = vm.envUint("PRIVATE_KEY");
        address deployer  = vm.addr(deployerPk);

        Targets memory t;
        t.admin     = vm.envAddress("FINAL_DEFAULT_ADMIN");
        t.upgrader  = vm.envAddress("FINAL_UPGRADER");
        t.pauser    = vm.envAddress("FINAL_PAUSER");
        t.validator = vm.envAddress("FINAL_VALIDATOR");
        t.config    = vm.envAddress("FINAL_CONFIG");
        t.treasury  = vm.envAddress("FINAL_TREASURY");

        Deployments memory d;
        d.registry    = vm.envAddress("CAPSULE_REGISTRY");
        d.factory     = vm.envAddress("APP_TOKEN_FACTORY");
        d.router      = vm.envAddress("FEE_ROUTER");
        d.entitlement = vm.envAddress("ENTITLEMENT_REGISTRY");
        d.settlement  = vm.envAddress("RECEIPT_SETTLEMENT");

        bool allowTestnetRetain = vm.envOr("ALLOW_TESTNET_DEPLOYER_RETAIN", false);

        _requireAddrs(t, d);
        if (!allowTestnetRetain) _requireFinalNotDeployer(t, deployer);

        vm.startBroadcast(deployerPk);
        _grantAll(t, d);
        vm.stopBroadcast();

        _verifyGrants(t, d);

        vm.startBroadcast(deployerPk);
        _revokeFromDeployer(d, deployer);
        vm.stopBroadcast();

        _verifyDeployerHasNothing(d, deployer);

        console.log("=== finalization complete ===");
        console.log("deployer:               %s (revoked from all privileged roles)", deployer);
        console.log("DEFAULT_ADMIN_ROLE -> %s", t.admin);
        console.log("UPGRADER_ROLE      -> %s", t.upgrader);
        console.log("PAUSER_ROLE        -> %s", t.pauser);
        console.log("VALIDATOR_ROLE     -> %s (registry only)", t.validator);
        console.log("CONFIG_ROLE        -> %s (factory + router + entitlement + settlement)", t.config);
        console.log("TREASURY_ROLE      -> %s (router only)", t.treasury);
    }

    function _requireAddrs(Targets memory t, Deployments memory d) private pure {
        require(t.admin     != address(0), "FINAL_DEFAULT_ADMIN required");
        require(t.upgrader  != address(0), "FINAL_UPGRADER required");
        require(t.pauser    != address(0), "FINAL_PAUSER required");
        require(t.validator != address(0), "FINAL_VALIDATOR required");
        require(t.config    != address(0), "FINAL_CONFIG required");
        require(t.treasury  != address(0), "FINAL_TREASURY required");
        require(d.registry != address(0) && d.factory != address(0) && d.router != address(0)
                && d.entitlement != address(0) && d.settlement != address(0),
                "all 5 deployment addresses required");
    }

    function _requireFinalNotDeployer(Targets memory t, address deployer) private pure {
        require(t.admin     != deployer, "mainnet: admin must differ from deployer");
        require(t.upgrader  != deployer, "mainnet: upgrader must differ from deployer");
        require(t.pauser    != deployer, "mainnet: pauser must differ from deployer");
        require(t.validator != deployer, "mainnet: validator must differ from deployer");
        require(t.config    != deployer, "mainnet: config must differ from deployer");
        require(t.treasury  != deployer, "mainnet: treasury must differ from deployer");
    }

    function _grantAll(Targets memory t, Deployments memory d) private {
        CapsuleRegistry reg = CapsuleRegistry(d.registry);
        reg.grantRole(reg.DEFAULT_ADMIN_ROLE(), t.admin);
        reg.grantRole(reg.UPGRADER_ROLE(),      t.upgrader);
        reg.grantRole(reg.PAUSER_ROLE(),        t.pauser);
        reg.grantRole(reg.VALIDATOR_ROLE(),     t.validator);

        AppTokenFactory fac = AppTokenFactory(d.factory);
        fac.grantRole(fac.DEFAULT_ADMIN_ROLE(), t.admin);
        fac.grantRole(fac.UPGRADER_ROLE(),      t.upgrader);
        fac.grantRole(fac.PAUSER_ROLE(),        t.pauser);
        fac.grantRole(fac.CONFIG_ROLE(),        t.config);

        FeeRouter rt = FeeRouter(payable(d.router));
        rt.grantRole(rt.DEFAULT_ADMIN_ROLE(), t.admin);
        rt.grantRole(rt.UPGRADER_ROLE(),      t.upgrader);
        rt.grantRole(rt.PAUSER_ROLE(),        t.pauser);
        rt.grantRole(rt.CONFIG_ROLE(),        t.config);
        rt.grantRole(rt.TREASURY_ROLE(),      t.treasury);

        EntitlementRegistry ent = EntitlementRegistry(d.entitlement);
        ent.grantRole(ent.DEFAULT_ADMIN_ROLE(), t.admin);
        ent.grantRole(ent.UPGRADER_ROLE(),      t.upgrader);
        ent.grantRole(ent.PAUSER_ROLE(),        t.pauser);
        ent.grantRole(ent.CONFIG_ROLE(),        t.config);

        ReceiptSettlement set = ReceiptSettlement(d.settlement);
        set.grantRole(set.DEFAULT_ADMIN_ROLE(), t.admin);
        set.grantRole(set.UPGRADER_ROLE(),      t.upgrader);
        set.grantRole(set.PAUSER_ROLE(),        t.pauser);
        set.grantRole(set.CONFIG_ROLE(),        t.config);
    }

    function _verifyGrants(Targets memory t, Deployments memory d) private view {
        CapsuleRegistry reg = CapsuleRegistry(d.registry);
        require(reg.hasRole(reg.DEFAULT_ADMIN_ROLE(), t.admin), "registry admin");
        require(reg.hasRole(reg.UPGRADER_ROLE(),      t.upgrader), "registry upgrader");
        require(reg.hasRole(reg.PAUSER_ROLE(),        t.pauser), "registry pauser");
        require(reg.hasRole(reg.VALIDATOR_ROLE(),     t.validator), "registry validator");

        AppTokenFactory fac = AppTokenFactory(d.factory);
        require(fac.hasRole(fac.DEFAULT_ADMIN_ROLE(), t.admin), "factory admin");
        require(fac.hasRole(fac.UPGRADER_ROLE(),      t.upgrader), "factory upgrader");
        require(fac.hasRole(fac.PAUSER_ROLE(),        t.pauser), "factory pauser");
        require(fac.hasRole(fac.CONFIG_ROLE(),        t.config), "factory config");

        FeeRouter rt = FeeRouter(payable(d.router));
        require(rt.hasRole(rt.DEFAULT_ADMIN_ROLE(), t.admin), "router admin");
        require(rt.hasRole(rt.UPGRADER_ROLE(),      t.upgrader), "router upgrader");
        require(rt.hasRole(rt.PAUSER_ROLE(),        t.pauser), "router pauser");
        require(rt.hasRole(rt.CONFIG_ROLE(),        t.config), "router config");
        require(rt.hasRole(rt.TREASURY_ROLE(),      t.treasury), "router treasury");

        EntitlementRegistry ent = EntitlementRegistry(d.entitlement);
        require(ent.hasRole(ent.DEFAULT_ADMIN_ROLE(), t.admin), "entitlement admin");
        require(ent.hasRole(ent.UPGRADER_ROLE(),      t.upgrader), "entitlement upgrader");
        require(ent.hasRole(ent.PAUSER_ROLE(),        t.pauser), "entitlement pauser");
        require(ent.hasRole(ent.CONFIG_ROLE(),        t.config), "entitlement config");

        ReceiptSettlement set = ReceiptSettlement(d.settlement);
        require(set.hasRole(set.DEFAULT_ADMIN_ROLE(), t.admin), "settlement admin");
        require(set.hasRole(set.UPGRADER_ROLE(),      t.upgrader), "settlement upgrader");
        require(set.hasRole(set.PAUSER_ROLE(),        t.pauser), "settlement pauser");
        require(set.hasRole(set.CONFIG_ROLE(),        t.config), "settlement config");
    }

    function _revokeFromDeployer(Deployments memory d, address deployer) private {
        CapsuleRegistry reg = CapsuleRegistry(d.registry);
        reg.revokeRole(reg.UPGRADER_ROLE(),      deployer);
        reg.revokeRole(reg.PAUSER_ROLE(),        deployer);
        reg.revokeRole(reg.VALIDATOR_ROLE(),     deployer);
        reg.revokeRole(reg.DEFAULT_ADMIN_ROLE(), deployer);

        AppTokenFactory fac = AppTokenFactory(d.factory);
        fac.revokeRole(fac.UPGRADER_ROLE(),      deployer);
        fac.revokeRole(fac.PAUSER_ROLE(),        deployer);
        fac.revokeRole(fac.CONFIG_ROLE(),        deployer);
        fac.revokeRole(fac.DEFAULT_ADMIN_ROLE(), deployer);

        FeeRouter rt = FeeRouter(payable(d.router));
        rt.revokeRole(rt.UPGRADER_ROLE(),      deployer);
        rt.revokeRole(rt.PAUSER_ROLE(),        deployer);
        rt.revokeRole(rt.CONFIG_ROLE(),        deployer);
        rt.revokeRole(rt.TREASURY_ROLE(),      deployer);
        rt.revokeRole(rt.DEFAULT_ADMIN_ROLE(), deployer);

        EntitlementRegistry ent = EntitlementRegistry(d.entitlement);
        ent.revokeRole(ent.UPGRADER_ROLE(),      deployer);
        ent.revokeRole(ent.PAUSER_ROLE(),        deployer);
        ent.revokeRole(ent.CONFIG_ROLE(),        deployer);
        ent.revokeRole(ent.DEFAULT_ADMIN_ROLE(), deployer);

        ReceiptSettlement set = ReceiptSettlement(d.settlement);
        set.revokeRole(set.UPGRADER_ROLE(),      deployer);
        set.revokeRole(set.PAUSER_ROLE(),        deployer);
        set.revokeRole(set.CONFIG_ROLE(),        deployer);
        set.revokeRole(set.DEFAULT_ADMIN_ROLE(), deployer);
    }

    function _verifyDeployerHasNothing(Deployments memory d, address deployer) private view {
        CapsuleRegistry reg = CapsuleRegistry(d.registry);
        require(!reg.hasRole(reg.DEFAULT_ADMIN_ROLE(), deployer), "registry admin not revoked");
        require(!reg.hasRole(reg.UPGRADER_ROLE(),      deployer), "registry upgrader not revoked");
        require(!reg.hasRole(reg.PAUSER_ROLE(),        deployer), "registry pauser not revoked");
        require(!reg.hasRole(reg.VALIDATOR_ROLE(),     deployer), "registry validator not revoked");

        AppTokenFactory fac = AppTokenFactory(d.factory);
        require(!fac.hasRole(fac.DEFAULT_ADMIN_ROLE(), deployer), "factory admin not revoked");
        require(!fac.hasRole(fac.UPGRADER_ROLE(),      deployer), "factory upgrader not revoked");
        require(!fac.hasRole(fac.PAUSER_ROLE(),        deployer), "factory pauser not revoked");
        require(!fac.hasRole(fac.CONFIG_ROLE(),        deployer), "factory config not revoked");

        FeeRouter rt = FeeRouter(payable(d.router));
        require(!rt.hasRole(rt.DEFAULT_ADMIN_ROLE(), deployer), "router admin not revoked");
        require(!rt.hasRole(rt.UPGRADER_ROLE(),      deployer), "router upgrader not revoked");
        require(!rt.hasRole(rt.PAUSER_ROLE(),        deployer), "router pauser not revoked");
        require(!rt.hasRole(rt.CONFIG_ROLE(),        deployer), "router config not revoked");
        require(!rt.hasRole(rt.TREASURY_ROLE(),      deployer), "router treasury not revoked");

        EntitlementRegistry ent = EntitlementRegistry(d.entitlement);
        require(!ent.hasRole(ent.DEFAULT_ADMIN_ROLE(), deployer), "entitlement admin not revoked");
        require(!ent.hasRole(ent.UPGRADER_ROLE(),      deployer), "entitlement upgrader not revoked");
        require(!ent.hasRole(ent.PAUSER_ROLE(),        deployer), "entitlement pauser not revoked");
        require(!ent.hasRole(ent.CONFIG_ROLE(),        deployer), "entitlement config not revoked");

        ReceiptSettlement set = ReceiptSettlement(d.settlement);
        require(!set.hasRole(set.DEFAULT_ADMIN_ROLE(), deployer), "settlement admin not revoked");
        require(!set.hasRole(set.UPGRADER_ROLE(),      deployer), "settlement upgrader not revoked");
        require(!set.hasRole(set.PAUSER_ROLE(),        deployer), "settlement pauser not revoked");
        require(!set.hasRole(set.CONFIG_ROLE(),        deployer), "settlement config not revoked");
    }
}

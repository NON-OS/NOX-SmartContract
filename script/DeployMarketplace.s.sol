// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {CapsuleRegistry}      from "../contracts/marketplace/core/CapsuleRegistry.sol";
import {AppTokenFactory}      from "../contracts/marketplace/core/AppTokenFactory.sol";
import {AppBondingToken}      from "../contracts/marketplace/core/AppBondingToken.sol";
import {FeeRouter}            from "../contracts/marketplace/revenue/FeeRouter.sol";
import {EntitlementRegistry}  from "../contracts/marketplace/entitlement/EntitlementRegistry.sol";
import {ReceiptSettlement}    from "../contracts/marketplace/entitlement/ReceiptSettlement.sol";

/// @notice Deploys the full v2 stack from B33.
/// @dev B33 is initial admin on every privileged role. Run Finalize.s.sol immediately after
///      to rotate roles to a Safe / timelock and revoke B33.
contract Deploy is Script {
    struct Deployment {
        address deployer;

        address registryImpl;
        address registry;

        address feeRouterImpl;
        address feeRouter;

        address bondingTokenImpl;

        address factoryImpl;
        address factory;

        address entitlementImpl;
        address entitlement;

        address settlementImpl;
        address settlement;

        address noxToken;
        address nftHoldersSink;
        address stakersSink;
        address treasurySink;
        uint256 launchFeeWei;
        uint256 receiptEpochDuration;
    }

    function run() external returns (Deployment memory d) {
        uint256 deployerPk           = vm.envUint("PRIVATE_KEY");
        d.deployer                   = vm.addr(deployerPk);
        d.noxToken                   = vm.envAddress("NOX_TOKEN");
        d.nftHoldersSink             = vm.envAddress("NFT_HOLDERS_SINK");
        d.stakersSink                = vm.envAddress("STAKERS_SINK");
        d.treasurySink               = vm.envAddress("TREASURY_SINK");
        d.launchFeeWei               = vm.envOr("LAUNCH_FEE_WEI", uint256(0));
        d.receiptEpochDuration       = vm.envOr("RECEIPT_EPOCH_DURATION", uint256(1 days));

        require(d.noxToken       != address(0), "NOX_TOKEN required");
        require(d.nftHoldersSink != address(0), "NFT_HOLDERS_SINK required");
        require(d.stakersSink    != address(0), "STAKERS_SINK required");
        require(d.treasurySink   != address(0), "TREASURY_SINK required");

        vm.startBroadcast(deployerPk);

        d.registryImpl = address(new CapsuleRegistry());
        d.registry     = address(new ERC1967Proxy(
            d.registryImpl,
            abi.encodeCall(CapsuleRegistry.initialize, (d.deployer))
        ));

        d.feeRouterImpl = address(new FeeRouter());
        d.feeRouter     = address(new ERC1967Proxy(
            d.feeRouterImpl,
            abi.encodeCall(
                FeeRouter.initialize,
                (d.deployer, d.nftHoldersSink, d.stakersSink, d.treasurySink)
            )
        ));

        d.bondingTokenImpl = address(new AppBondingToken());

        d.factoryImpl = address(new AppTokenFactory());
        d.factory     = address(new ERC1967Proxy(
            d.factoryImpl,
            abi.encodeCall(
                AppTokenFactory.initialize,
                (d.deployer, d.bondingTokenImpl, d.registry, d.feeRouter, d.launchFeeWei)
            )
        ));

        d.entitlementImpl = address(new EntitlementRegistry());
        d.entitlement     = address(new ERC1967Proxy(
            d.entitlementImpl,
            abi.encodeCall(
                EntitlementRegistry.initialize,
                (d.deployer, d.registry, d.factory, d.feeRouter, d.noxToken)
            )
        ));

        d.settlementImpl = address(new ReceiptSettlement());
        d.settlement     = address(new ERC1967Proxy(
            d.settlementImpl,
            abi.encodeCall(
                ReceiptSettlement.initialize,
                (d.deployer, d.registry, d.feeRouter, d.noxToken, d.receiptEpochDuration)
            )
        ));

        vm.stopBroadcast();

        _printAddresses(d);
    }

    function _printAddresses(Deployment memory d) internal pure {
        console.log("=== 0xNOX v2 deployment complete ===");
        console.log("deployer (B33):          %s", d.deployer);
        console.log("");
        console.log("CapsuleRegistry impl:    %s", d.registryImpl);
        console.log("CapsuleRegistry proxy:   %s", d.registry);
        console.log("FeeRouter impl:          %s", d.feeRouterImpl);
        console.log("FeeRouter proxy:         %s", d.feeRouter);
        console.log("AppBondingToken impl:    %s", d.bondingTokenImpl);
        console.log("AppTokenFactory impl:    %s", d.factoryImpl);
        console.log("AppTokenFactory proxy:   %s", d.factory);
        console.log("EntitlementRegistry impl:%s", d.entitlementImpl);
        console.log("EntitlementRegistry proxy:%s", d.entitlement);
        console.log("ReceiptSettlement impl:  %s", d.settlementImpl);
        console.log("ReceiptSettlement proxy: %s", d.settlement);
        console.log("");
        console.log("NOX token:               %s", d.noxToken);
        console.log("nftHoldersSink:          %s", d.nftHoldersSink);
        console.log("stakersSink:             %s", d.stakersSink);
        console.log("treasurySink:            %s", d.treasurySink);
        console.log("launchFeeWei:            %s", d.launchFeeWei);
        console.log("receiptEpochDuration:    %s", d.receiptEpochDuration);
        console.log("");
        console.log("ALL PRIVILEGED ROLES INITIALLY HELD BY DEPLOYER.");
        console.log("Run Finalize.s.sol BEFORE the contracts hold any user value.");
    }
}

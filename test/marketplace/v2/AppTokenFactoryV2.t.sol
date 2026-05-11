// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {AppTokenFactoryV2}     from "../../../contracts/marketplace/core/AppTokenFactoryV2.sol";
import {IAppTokenFactoryV2}    from "../../../contracts/marketplace/interfaces/IAppTokenFactoryV2.sol";
import {IAppTokenFactory}      from "../../../contracts/marketplace/interfaces/IAppTokenFactory.sol";
import {AppBondingTokenV2}     from "../../../contracts/marketplace/core/AppBondingTokenV2.sol";
import {IAppBondingTokenV2}    from "../../../contracts/marketplace/interfaces/IAppBondingTokenV2.sol";
import {CapsuleRegistry}       from "../../../contracts/marketplace/core/CapsuleRegistry.sol";
import {ICapsuleRegistry}      from "../../../contracts/marketplace/interfaces/ICapsuleRegistry.sol";
import {MockFeeRouter, MockUniV2Factory, MockUniV2Router} from "./Mocks.sol";
import {MockERC20}             from "../../mocks/MockERC20.sol";

contract AppTokenFactoryV2Test is Test {
    AppTokenFactoryV2 factory;
    AppBondingTokenV2 v2Impl;
    CapsuleRegistry   registry;
    MockFeeRouter     feeRouter;
    MockUniV2Factory  uniFactory;
    MockUniV2Router   uniRouter;
    MockERC20         wethToken;
    address           weth;

    address admin     = address(0xA1);
    address publisher = address(0xB2);
    address attacker  = address(0xC3);
    address constant LP_BURN = address(0x000000000000000000000000000000000000dEaD);

    bytes32 capsuleA      = keccak256("cap:A");
    bytes32 capsuleB      = keccak256("cap:B");
    bytes32 publisherKey  = keccak256("pub:key:1");
    bytes32 manifestHash  = keccak256("man:1");
    bytes32 packageHash   = keccak256("pkg:1");
    bytes32 capabilityH   = keccak256("caps:[display]");

    uint256 constant GRAD_SUPPLY    = 800_000 * 1e18;
    uint256 constant LP_RESERVE_CAP = 100_000_000 * 1e18;

    function setUp() public {
        wethToken  = new MockERC20("WETH","WETH");
        weth       = address(wethToken);
        feeRouter  = new MockFeeRouter();
        uniFactory = new MockUniV2Factory();
        uniRouter  = new MockUniV2Router(address(uniFactory), weth);
        v2Impl     = new AppBondingTokenV2();

        vm.startPrank(admin);

        CapsuleRegistry regImpl = new CapsuleRegistry();
        ERC1967Proxy regProxy = new ERC1967Proxy(
            address(regImpl),
            abi.encodeCall(CapsuleRegistry.initialize, (admin))
        );
        registry = CapsuleRegistry(address(regProxy));

        AppTokenFactoryV2 facImpl = new AppTokenFactoryV2();
        ERC1967Proxy facProxy = new ERC1967Proxy(
            address(facImpl),
            abi.encodeCall(AppTokenFactoryV2.initialize,
                (admin, address(0xDEAD), address(registry), address(feeRouter), 0))
        );
        factory = AppTokenFactoryV2(address(facProxy));

        factory.setBondingTokenImplV2(address(v2Impl));
        factory.setUniswapInfra(weth, address(uniFactory), address(uniRouter), LP_BURN);

        vm.stopPrank();

        _registerAndPublish(capsuleA);
    }

    function _registerAndPublish(bytes32 capsuleId) internal returns (bytes32 releaseId) {
        vm.startPrank(publisher);
        registry.registerApp(capsuleId, publisherKey, "ipfs://app");
        releaseId = registry.submitRelease(
            capsuleId, manifestHash, packageHash, capabilityH, "1.0", "ipfs://pkg"
        );
        vm.stopPrank();

        vm.prank(admin);
        registry.attachValidationResult(releaseId, true, "ipfs://report");

        vm.prank(publisher);
        registry.publishRelease(releaseId);
    }

    function _params(bytes32 capsuleId, bytes32 releaseId) internal pure returns (IAppTokenFactoryV2.LaunchParamsV2 memory) {
        return IAppTokenFactoryV2.LaunchParamsV2({
            capsuleId:        capsuleId,
            releaseId:        releaseId,
            name:             "App",
            symbol:           "APP",
            metadataURI:      "ipfs://meta",
            graduationSupply: GRAD_SUPPLY,
            lpReserveCap:     LP_RESERVE_CAP,
            tradingFeeBps:    100,
            graduationFeeBps: 100
        });
    }

    function test_launchFlagDefaultsFalse() public view {
        assertFalse(factory.launchEnabled(), "launch must default false");
    }

    function test_publicCannotLaunchWhileFlagFalse() public {
        bytes32 relA = registry.getApp(capsuleA).latestPublishedReleaseIndex == 0
            ? bytes32(0) : registry.getLatestPublishedRelease(capsuleA).releaseId;
        relA = registry.getLatestPublishedRelease(capsuleA).releaseId;

        vm.prank(publisher);
        vm.expectRevert(IAppTokenFactoryV2.LaunchDisabled.selector);
        factory.createAppTokenV2(_params(capsuleA, relA));
    }

    function test_v1LaunchPathHardDisabled() public {
        IAppTokenFactory.LaunchParams memory v1p = IAppTokenFactory.LaunchParams({
            capsuleId:        capsuleA,
            releaseId:        bytes32(0),
            name:             "App",
            symbol:           "APP",
            metadataURI:      "ipfs://meta",
            graduationSupply: GRAD_SUPPLY,
            feeBps:           100
        });
        vm.expectRevert(IAppTokenFactoryV2.LaunchDisabled.selector);
        factory.createAppToken(v1p);
    }

    function test_setLaunchEnabledOnlyConfigRole() public {
        vm.prank(attacker);
        vm.expectRevert();
        factory.setLaunchEnabled(true);

        vm.prank(admin);
        factory.setLaunchEnabled(true);
        assertTrue(factory.launchEnabled());
    }

    function test_setBondingTokenImplV2OnlyConfigRole() public {
        AppBondingTokenV2 newImpl = new AppBondingTokenV2();
        vm.prank(attacker);
        vm.expectRevert();
        factory.setBondingTokenImplV2(address(newImpl));

        vm.prank(admin);
        factory.setBondingTokenImplV2(address(newImpl));
        assertEq(factory.bondingTokenImplV2(), address(newImpl));
    }

    function test_launchSucceedsForPublishedReleaseAndPublisher() public {
        vm.prank(admin);
        factory.setLaunchEnabled(true);

        bytes32 rel = registry.getLatestPublishedRelease(capsuleA).releaseId;
        vm.prank(publisher);
        address token = factory.createAppTokenV2(_params(capsuleA, rel));

        assertTrue(token != address(0));
        assertEq(factory.tokenForCapsule(capsuleA), token);
        assertEq(factory.capsuleForToken(token), capsuleA);

        IAppBondingTokenV2.AppLink memory link = IAppBondingTokenV2(token).appLink();
        assertEq(link.capsuleId, capsuleA);
        assertEq(link.releaseId, rel);
        assertEq(link.manifestHash, manifestHash);
        assertEq(link.packageHash, packageHash);
        assertEq(link.publisher, publisher);
    }

    function test_launchRejectsAnonymousCaller() public {
        vm.prank(admin);
        factory.setLaunchEnabled(true);
        bytes32 rel = registry.getLatestPublishedRelease(capsuleA).releaseId;

        vm.prank(attacker);
        vm.expectRevert(IAppTokenFactoryV2.NotPublisher.selector);
        factory.createAppTokenV2(_params(capsuleA, rel));
    }

    function test_launchRejectsUnpublishedRelease() public {
        vm.prank(admin);
        factory.setLaunchEnabled(true);

        vm.startPrank(publisher);
        registry.registerApp(capsuleB, publisherKey, "ipfs://appB");
        bytes32 relB = registry.submitRelease(
            capsuleB, manifestHash, packageHash, capabilityH, "1.0", "ipfs://pkg"
        );
        vm.stopPrank();

        vm.prank(admin);
        registry.attachValidationResult(relB, true, "ipfs://report");

        vm.prank(publisher);
        vm.expectRevert(IAppTokenFactoryV2.ReleaseNotPublished.selector);
        factory.createAppTokenV2(_params(capsuleB, relB));
    }

    function test_launchRejectsReleaseFromDifferentCapsule() public {
        vm.prank(admin);
        factory.setLaunchEnabled(true);

        bytes32 relA = registry.getLatestPublishedRelease(capsuleA).releaseId;
        vm.startPrank(publisher);
        registry.registerApp(capsuleB, publisherKey, "ipfs://appB");
        vm.stopPrank();

        IAppTokenFactoryV2.LaunchParamsV2 memory p = _params(capsuleB, relA);
        vm.prank(publisher);
        vm.expectRevert(IAppTokenFactoryV2.ReleaseMismatch.selector);
        factory.createAppTokenV2(p);
    }

    function test_oneTokenPerCapsule() public {
        vm.prank(admin);
        factory.setLaunchEnabled(true);
        bytes32 rel = registry.getLatestPublishedRelease(capsuleA).releaseId;

        vm.prank(publisher);
        factory.createAppTokenV2(_params(capsuleA, rel));

        vm.prank(publisher);
        vm.expectRevert(IAppTokenFactoryV2.AlreadyLaunched.selector);
        factory.createAppTokenV2(_params(capsuleA, rel));
    }

    function test_launchRejectsZeroNameOrSymbol() public {
        vm.prank(admin);
        factory.setLaunchEnabled(true);
        bytes32 rel = registry.getLatestPublishedRelease(capsuleA).releaseId;

        IAppTokenFactoryV2.LaunchParamsV2 memory p = _params(capsuleA, rel);
        p.name = "";
        vm.prank(publisher);
        vm.expectRevert(IAppTokenFactoryV2.InvalidName.selector);
        factory.createAppTokenV2(p);

        p.name = "App";
        p.symbol = "";
        vm.prank(publisher);
        vm.expectRevert(IAppTokenFactoryV2.InvalidSymbol.selector);
        factory.createAppTokenV2(p);
    }

    function test_launchRejectsGraduationFeeAboveCap() public {
        vm.prank(admin);
        factory.setLaunchEnabled(true);
        bytes32 rel = registry.getLatestPublishedRelease(capsuleA).releaseId;

        IAppTokenFactoryV2.LaunchParamsV2 memory p = _params(capsuleA, rel);
        p.graduationFeeBps = 101;
        vm.prank(publisher);
        vm.expectRevert(abi.encodeWithSelector(IAppTokenFactoryV2.InvalidGraduationFee.selector, uint16(100), uint16(101)));
        factory.createAppTokenV2(p);
    }

    function test_launchRejectsWhenInfraUnset() public {
        vm.startPrank(admin);
        AppTokenFactoryV2 freshImpl = new AppTokenFactoryV2();
        ERC1967Proxy freshProxy = new ERC1967Proxy(
            address(freshImpl),
            abi.encodeCall(AppTokenFactoryV2.initialize,
                (admin, address(0xDEAD), address(registry), address(feeRouter), 0))
        );
        AppTokenFactoryV2 freshFac = AppTokenFactoryV2(address(freshProxy));
        freshFac.setBondingTokenImplV2(address(v2Impl));
        freshFac.setLaunchEnabled(true);
        vm.stopPrank();

        bytes32 rel = registry.getLatestPublishedRelease(capsuleA).releaseId;
        vm.prank(publisher);
        vm.expectRevert(IAppTokenFactoryV2.UniswapInfraUnset.selector);
        freshFac.createAppTokenV2(_params(capsuleA, rel));
    }

    function test_launchRejectsWhenV2ImplUnset() public {
        vm.startPrank(admin);
        AppTokenFactoryV2 freshImpl = new AppTokenFactoryV2();
        ERC1967Proxy freshProxy = new ERC1967Proxy(
            address(freshImpl),
            abi.encodeCall(AppTokenFactoryV2.initialize,
                (admin, address(0xDEAD), address(registry), address(feeRouter), 0))
        );
        AppTokenFactoryV2 freshFac = AppTokenFactoryV2(address(freshProxy));
        freshFac.setUniswapInfra(weth, address(uniFactory), address(uniRouter), LP_BURN);
        freshFac.setLaunchEnabled(true);
        vm.stopPrank();

        bytes32 rel = registry.getLatestPublishedRelease(capsuleA).releaseId;
        vm.prank(publisher);
        vm.expectRevert(IAppTokenFactoryV2.InvalidImplementation.selector);
        freshFac.createAppTokenV2(_params(capsuleA, rel));
    }

    function test_setLaunchEnabledEmitsEvent() public {
        vm.expectEmit(true, true, true, true);
        emit IAppTokenFactoryV2.LaunchEnabledChanged(false, true, admin);
        vm.prank(admin);
        factory.setLaunchEnabled(true);
    }

    function test_setBondingTokenImplV2EmitsEvent() public {
        AppBondingTokenV2 newImpl = new AppBondingTokenV2();
        vm.expectEmit(true, true, false, false);
        emit IAppTokenFactoryV2.BondingTokenImplV2Updated(address(v2Impl), address(newImpl));
        vm.prank(admin);
        factory.setBondingTokenImplV2(address(newImpl));
    }

    function test_pausedFactoryBlocksLaunch() public {
        vm.startPrank(admin);
        factory.setLaunchEnabled(true);
        factory.pause();
        vm.stopPrank();

        bytes32 rel = registry.getLatestPublishedRelease(capsuleA).releaseId;
        vm.prank(publisher);
        vm.expectRevert();
        factory.createAppTokenV2(_params(capsuleA, rel));
    }

    function test_factoryInitsV2WithExactAppLinkAndConfig() public {
        vm.prank(admin);
        factory.setLaunchEnabled(true);
        bytes32 rel = registry.getLatestPublishedRelease(capsuleA).releaseId;

        vm.prank(publisher);
        address token = factory.createAppTokenV2(_params(capsuleA, rel));

        AppBondingTokenV2 t = AppBondingTokenV2(payable(token));
        assertEq(t.graduationSupply(), GRAD_SUPPLY);
        assertEq(t.lpReserveCap(), LP_RESERVE_CAP);
        assertEq(t.feeBps(), 100);
        assertEq(t.graduationFeeBps(), 100);
        assertEq(t.weth(), weth);
        assertEq(t.lpBurnTo(), LP_BURN);
        assertEq(address(t.uniV2Factory()), address(uniFactory));
        assertEq(address(t.uniV2Router()), address(uniRouter));
    }
}

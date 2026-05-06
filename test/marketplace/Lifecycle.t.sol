// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {CapsuleRegistry}  from "../../contracts/marketplace/core/CapsuleRegistry.sol";
import {AppTokenFactory}  from "../../contracts/marketplace/core/AppTokenFactory.sol";
import {AppBondingToken}  from "../../contracts/marketplace/core/AppBondingToken.sol";
import {FeeRouter}        from "../../contracts/marketplace/revenue/FeeRouter.sol";
import {ICapsuleRegistry} from "../../contracts/marketplace/interfaces/ICapsuleRegistry.sol";
import {IAppTokenFactory} from "../../contracts/marketplace/interfaces/IAppTokenFactory.sol";
import {IFeeRouter}       from "../../contracts/marketplace/interfaces/IFeeRouter.sol";

contract LifecycleTest is Test {
    address admin     = address(0xA1);
    address publisher = address(0xB2);
    address attacker  = address(0xC3);
    address buyer     = address(0xD4);

    address nftSink   = address(0xE5);
    address stkSink   = address(0xE6);
    address treasury  = address(0xE7);

    CapsuleRegistry registry;
    AppTokenFactory factory;
    AppBondingToken bondingImpl;
    FeeRouter      router;

    bytes32 constant CAPSULE_ID    = keccak256("nonos:capsule:my-app");
    bytes32 constant PUB_KEY_HASH  = keccak256("publisher-ed25519-key");
    bytes32 constant MANIFEST_HASH = keccak256("manifest@v1");
    bytes32 constant PACKAGE_HASH  = keccak256("package@v1");
    bytes32 constant CAPABILITY_HASH = keccak256("caps:[display,input,vfs]");
    string  constant METADATA_URI   = "ipfs://app-metadata";
    string  constant PACKAGE_URI    = "ipfs://package-bytes";

    function setUp() public {
        vm.startPrank(admin);

        CapsuleRegistry regImpl = new CapsuleRegistry();
        ERC1967Proxy regProxy = new ERC1967Proxy(
            address(regImpl),
            abi.encodeCall(CapsuleRegistry.initialize, (admin))
        );
        registry = CapsuleRegistry(address(regProxy));

        FeeRouter routerImpl = new FeeRouter();
        ERC1967Proxy routerProxy = new ERC1967Proxy(
            address(routerImpl),
            abi.encodeCall(FeeRouter.initialize, (admin, nftSink, stkSink, treasury))
        );
        router = FeeRouter(payable(address(routerProxy)));

        bondingImpl = new AppBondingToken();

        AppTokenFactory factoryImpl = new AppTokenFactory();
        ERC1967Proxy factoryProxy = new ERC1967Proxy(
            address(factoryImpl),
            abi.encodeCall(
                AppTokenFactory.initialize,
                (admin, address(bondingImpl), address(registry), address(router), 0)
            )
        );
        factory = AppTokenFactory(address(factoryProxy));

        vm.stopPrank();

        vm.deal(publisher, 100 ether);
        vm.deal(attacker, 100 ether);
        vm.deal(buyer, 100 ether);
    }

    function _registerAndPublish() internal returns (bytes32 releaseId) {
        vm.prank(publisher);
        registry.registerApp(CAPSULE_ID, PUB_KEY_HASH, METADATA_URI);

        vm.prank(publisher);
        releaseId = registry.submitRelease(
            CAPSULE_ID, MANIFEST_HASH, PACKAGE_HASH, CAPABILITY_HASH, "1.0", PACKAGE_URI
        );

        vm.prank(admin);
        registry.attachValidationResult(releaseId, true, "ipfs://validation-report");

        vm.prank(publisher);
        registry.publishRelease(releaseId);
    }

    function test_appRegistration_andRelease_roundtrip() public {
        bytes32 releaseId = _registerAndPublish();
        ICapsuleRegistry.Release memory r = registry.getRelease(releaseId);
        assertEq(uint8(r.status), uint8(ICapsuleRegistry.ReleaseStatus.Published));
        assertTrue(registry.isReleasePublished(releaseId));
        assertEq(registry.publisherOf(CAPSULE_ID), publisher);
    }

    function test_publishRequiresValidation() public {
        vm.prank(publisher);
        registry.registerApp(CAPSULE_ID, PUB_KEY_HASH, METADATA_URI);
        vm.prank(publisher);
        bytes32 releaseId = registry.submitRelease(
            CAPSULE_ID, MANIFEST_HASH, PACKAGE_HASH, CAPABILITY_HASH, "1.0", PACKAGE_URI
        );

        vm.prank(publisher);
        vm.expectRevert();
        registry.publishRelease(releaseId);
    }

    function test_attackerCannotSubmitRelease() public {
        vm.prank(publisher);
        registry.registerApp(CAPSULE_ID, PUB_KEY_HASH, METADATA_URI);

        vm.prank(attacker);
        vm.expectRevert();
        registry.submitRelease(
            CAPSULE_ID, MANIFEST_HASH, PACKAGE_HASH, CAPABILITY_HASH, "1.0", PACKAGE_URI
        );
    }

    function test_zeroHashesReject() public {
        vm.prank(publisher);
        registry.registerApp(CAPSULE_ID, PUB_KEY_HASH, METADATA_URI);

        vm.prank(publisher);
        vm.expectRevert();
        registry.submitRelease(CAPSULE_ID, bytes32(0), PACKAGE_HASH, CAPABILITY_HASH, "1.0", PACKAGE_URI);

        vm.prank(publisher);
        vm.expectRevert();
        registry.submitRelease(CAPSULE_ID, MANIFEST_HASH, bytes32(0), CAPABILITY_HASH, "1.0", PACKAGE_URI);

        vm.prank(publisher);
        vm.expectRevert();
        registry.submitRelease(CAPSULE_ID, MANIFEST_HASH, PACKAGE_HASH, bytes32(0), "1.0", PACKAGE_URI);
    }

    function test_tokenLaunchRequiresPublishedRelease() public {
        vm.prank(publisher);
        registry.registerApp(CAPSULE_ID, PUB_KEY_HASH, METADATA_URI);
        vm.prank(publisher);
        bytes32 releaseId = registry.submitRelease(
            CAPSULE_ID, MANIFEST_HASH, PACKAGE_HASH, CAPABILITY_HASH, "1.0", PACKAGE_URI
        );

        IAppTokenFactory.LaunchParams memory p = IAppTokenFactory.LaunchParams({
            capsuleId: CAPSULE_ID,
            releaseId: releaseId,
            name: "MyApp Token",
            symbol: "MAT",
            metadataURI: "ipfs://token-meta",
            graduationSupply: 800_000_000 * 1e18,
            feeBps: 100
        });

        vm.prank(publisher);
        vm.expectRevert();
        factory.createAppToken(p);
    }

    function test_tokenLaunchByPublisher_succeeds() public {
        bytes32 releaseId = _registerAndPublish();
        IAppTokenFactory.LaunchParams memory p = IAppTokenFactory.LaunchParams({
            capsuleId: CAPSULE_ID,
            releaseId: releaseId,
            name: "MyApp Token",
            symbol: "MAT",
            metadataURI: "ipfs://token-meta",
            graduationSupply: 800_000_000 * 1e18,
            feeBps: 100
        });
        vm.prank(publisher);
        address tok = factory.createAppToken(p);
        assertTrue(tok != address(0));
        assertEq(factory.tokenForCapsule(CAPSULE_ID), tok);
        assertEq(factory.capsuleForToken(tok), CAPSULE_ID);
    }

    function test_tokenLaunchByAttacker_reverts() public {
        bytes32 releaseId = _registerAndPublish();
        IAppTokenFactory.LaunchParams memory p = IAppTokenFactory.LaunchParams({
            capsuleId: CAPSULE_ID,
            releaseId: releaseId,
            name: "Stolen", symbol: "STL",
            metadataURI: "ipfs://stolen",
            graduationSupply: 800_000_000 * 1e18,
            feeBps: 100
        });
        vm.prank(attacker);
        vm.expectRevert();
        factory.createAppToken(p);
    }

    function test_oneTokenPerApp() public {
        bytes32 releaseId = _registerAndPublish();
        IAppTokenFactory.LaunchParams memory p = IAppTokenFactory.LaunchParams({
            capsuleId: CAPSULE_ID,
            releaseId: releaseId,
            name: "First", symbol: "ONE",
            metadataURI: "ipfs://1",
            graduationSupply: 800_000_000 * 1e18,
            feeBps: 100
        });
        vm.prank(publisher);
        factory.createAppToken(p);

        vm.prank(publisher);
        vm.expectRevert();
        factory.createAppToken(p);
    }

    function test_buy_then_sell_executesAndPaysFee() public {
        bytes32 releaseId = _registerAndPublish();
        IAppTokenFactory.LaunchParams memory p = IAppTokenFactory.LaunchParams({
            capsuleId: CAPSULE_ID,
            releaseId: releaseId,
            name: "X", symbol: "X",
            metadataURI: "ipfs://x",
            graduationSupply: 800_000_000 * 1e18,
            feeBps: 100
        });
        vm.prank(publisher);
        address tok = factory.createAppToken(p);
        AppBondingToken bt = AppBondingToken(payable(tok));

        vm.prank(buyer);
        uint256 tokensOut = bt.buy{value: 2 ether}(0);
        assertGt(tokensOut, 0);
        assertEq(bt.balanceOf(buyer), tokensOut);

        vm.prank(buyer);
        uint256 ethBack = bt.sell(tokensOut, 0);
        assertGt(ethBack, 0);
        assertLt(ethBack, 2 ether, "must pay buy+sell fees");
    }

    function test_slippageProtection_reverts() public {
        bytes32 releaseId = _registerAndPublish();
        IAppTokenFactory.LaunchParams memory p = IAppTokenFactory.LaunchParams({
            capsuleId: CAPSULE_ID,
            releaseId: releaseId,
            name: "X", symbol: "X",
            metadataURI: "ipfs://x",
            graduationSupply: 800_000_000 * 1e18,
            feeBps: 100
        });
        vm.prank(publisher);
        address tok = factory.createAppToken(p);
        AppBondingToken bt = AppBondingToken(payable(tok));

        vm.prank(buyer);
        vm.expectRevert();
        bt.buy{value: 1 ether}(type(uint256).max);
    }

    function test_feeRouterSplitsCorrectly() public {
        bytes32 releaseId = _registerAndPublish();
        IAppTokenFactory.LaunchParams memory p = IAppTokenFactory.LaunchParams({
            capsuleId: CAPSULE_ID,
            releaseId: releaseId,
            name: "X", symbol: "X",
            metadataURI: "ipfs://x",
            graduationSupply: 800_000_000 * 1e18,
            feeBps: 100
        });
        vm.prank(publisher);
        address tok = factory.createAppToken(p);
        AppBondingToken bt = AppBondingToken(payable(tok));

        uint256 nftBefore = nftSink.balance;
        uint256 stkBefore = stkSink.balance;
        uint256 trsBefore = treasury.balance;
        uint256 pubBefore = publisher.balance;

        vm.prank(buyer);
        bt.buy{value: 10 ether}(0);

        uint256 nftDelta = nftSink.balance - nftBefore;
        uint256 stkDelta = stkSink.balance - stkBefore;
        uint256 trsDelta = treasury.balance - trsBefore;
        uint256 pubDelta = publisher.balance - pubBefore;

        assertGt(nftDelta + stkDelta + trsDelta + pubDelta, 0, "trading fee was distributed");
        assertGt(nftDelta, 0);
        assertGt(stkDelta, 0);
    }

    function test_invalidProfileSumReverts() public {
        IFeeRouter.SplitProfile memory bad = IFeeRouter.SplitProfile({
            publisherBps: 5000, nftHoldersBps: 5000, stakersBps: 1000, treasuryBps: 0,
            configured: true
        });
        vm.prank(admin);
        vm.expectRevert();
        router.setSplitProfile(IFeeRouter.RevenueSource.AppPurchase, bad);
    }

    function test_revokedAppCannotSubmitRelease() public {
        vm.prank(publisher);
        registry.registerApp(CAPSULE_ID, PUB_KEY_HASH, METADATA_URI);
        vm.prank(admin);
        registry.revokeApp(CAPSULE_ID, "violation");
        vm.prank(publisher);
        vm.expectRevert();
        registry.submitRelease(CAPSULE_ID, MANIFEST_HASH, PACKAGE_HASH, CAPABILITY_HASH, "1.0", PACKAGE_URI);
    }

    function test_upgradeAuth_unauthorizedCannotUpgrade() public {
        CapsuleRegistry newImpl = new CapsuleRegistry();
        vm.prank(attacker);
        vm.expectRevert();
        registry.upgradeToAndCall(address(newImpl), "");
    }
}

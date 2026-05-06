// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

import {Test, Vm} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {CapsuleRegistry}     from "../../contracts/marketplace/core/CapsuleRegistry.sol";
import {AppTokenFactory}     from "../../contracts/marketplace/core/AppTokenFactory.sol";
import {AppBondingToken}     from "../../contracts/marketplace/core/AppBondingToken.sol";
import {FeeRouter}           from "../../contracts/marketplace/revenue/FeeRouter.sol";
import {EntitlementRegistry} from "../../contracts/marketplace/entitlement/EntitlementRegistry.sol";
import {ReceiptSettlement}   from "../../contracts/marketplace/entitlement/ReceiptSettlement.sol";
import {ICapsuleRegistry}    from "../../contracts/marketplace/interfaces/ICapsuleRegistry.sol";
import {IEntitlementRegistry} from "../../contracts/marketplace/interfaces/IEntitlementRegistry.sol";
import {IReceiptSettlement}  from "../../contracts/marketplace/interfaces/IReceiptSettlement.sol";
import {IFeeRouter}          from "../../contracts/marketplace/interfaces/IFeeRouter.sol";

import {MockERC20}  from "../mocks/MockERC20.sol";
import {MockERC721} from "../mocks/MockERC721.sol";

contract EntitlementSettlementTest is Test {
    address admin    = address(0xA1);
    address publisher = address(0xB2);
    address attacker = address(0xC3);
    address user1    = address(0xD4);
    address user2    = address(0xD5);

    address nftSink   = address(0xE5);
    address stkSink   = address(0xE6);
    address treasury  = address(0xE7);

    CapsuleRegistry     registry;
    AppTokenFactory     factory;
    AppBondingToken     bondingImpl;
    FeeRouter           router;
    EntitlementRegistry ent;
    ReceiptSettlement   settle;
    MockERC20           nox;
    MockERC721          nftPass;

    bytes32 constant CAPSULE_ID    = keccak256("nonos:capsule:my-app");
    bytes32 constant PUB_KEY_HASH  = keccak256("publisher-ed25519");
    bytes32 constant MANIFEST_HASH = keccak256("manifest@1");
    bytes32 constant PACKAGE_HASH  = keccak256("package@1");
    bytes32 constant CAP_HASH      = keccak256("caps@1");

    function setUp() public {
        vm.startPrank(admin);

        nox = new MockERC20("NOX", "NOX");
        nftPass = new MockERC721("ZeroState Pass", "ZSP");

        registry = CapsuleRegistry(_proxy(
            address(new CapsuleRegistry()),
            abi.encodeCall(CapsuleRegistry.initialize, (admin))
        ));

        router = FeeRouter(payable(_proxy(
            address(new FeeRouter()),
            abi.encodeCall(FeeRouter.initialize, (admin, nftSink, stkSink, treasury))
        )));

        bondingImpl = new AppBondingToken();

        factory = AppTokenFactory(_proxy(
            address(new AppTokenFactory()),
            abi.encodeCall(
                AppTokenFactory.initialize,
                (admin, address(bondingImpl), address(registry), address(router), 0)
            )
        ));

        ent = EntitlementRegistry(_proxy(
            address(new EntitlementRegistry()),
            abi.encodeCall(
                EntitlementRegistry.initialize,
                (admin, address(registry), address(factory), address(router), address(nox))
            )
        ));

        settle = ReceiptSettlement(_proxy(
            address(new ReceiptSettlement()),
            abi.encodeCall(
                ReceiptSettlement.initialize,
                (admin, address(registry), address(router), address(nox), 1 days)
            )
        ));

        vm.stopPrank();

        _registerAndPublish();
    }

    function _proxy(address impl, bytes memory data) internal returns (address) {
        return address(new ERC1967Proxy(impl, data));
    }

    function _registerAndPublish() internal {
        vm.prank(publisher);
        registry.registerApp(CAPSULE_ID, PUB_KEY_HASH, "ipfs://meta");
        vm.prank(publisher);
        bytes32 rid = registry.submitRelease(CAPSULE_ID, MANIFEST_HASH, PACKAGE_HASH, CAP_HASH, "1.0", "ipfs://pkg");
        vm.prank(admin);
        registry.attachValidationResult(rid, true, "ipfs://report");
        vm.prank(publisher);
        registry.publishRelease(rid);
    }

    function _configureFree() internal {
        vm.prank(publisher);
        ent.configureEntitlement(
            CAPSULE_ID,
            IEntitlementRegistry.AccessConfig({
                mode: IEntitlementRegistry.AccessMode.Free,
                priceNoxWei: 0, subscriptionDuration: 0,
                gatingContract: address(0), gatingThreshold: 0,
                trialDuration: 0, configured: true
            })
        );
    }

    function _configureOneTime(uint256 price) internal {
        vm.prank(publisher);
        ent.configureEntitlement(
            CAPSULE_ID,
            IEntitlementRegistry.AccessConfig({
                mode: IEntitlementRegistry.AccessMode.OneTimeNOX,
                priceNoxWei: price, subscriptionDuration: 0,
                gatingContract: address(0), gatingThreshold: 0,
                trialDuration: 0, configured: true
            })
        );
    }

    function _configureSubscription(uint256 price, uint256 duration) internal {
        vm.prank(publisher);
        ent.configureEntitlement(
            CAPSULE_ID,
            IEntitlementRegistry.AccessConfig({
                mode: IEntitlementRegistry.AccessMode.Subscription,
                priceNoxWei: price, subscriptionDuration: duration,
                gatingContract: address(0), gatingThreshold: 0,
                trialDuration: 0, configured: true
            })
        );
    }

    function _configureTokenHolder(address tokenContract, uint256 threshold) internal {
        vm.prank(publisher);
        ent.configureEntitlement(
            CAPSULE_ID,
            IEntitlementRegistry.AccessConfig({
                mode: IEntitlementRegistry.AccessMode.TokenHolder,
                priceNoxWei: 0, subscriptionDuration: 0,
                gatingContract: tokenContract, gatingThreshold: threshold,
                trialDuration: 0, configured: true
            })
        );
    }

    function _configureNFT(address nftContract) internal {
        vm.prank(publisher);
        ent.configureEntitlement(
            CAPSULE_ID,
            IEntitlementRegistry.AccessConfig({
                mode: IEntitlementRegistry.AccessMode.NFTGated,
                priceNoxWei: 0, subscriptionDuration: 0,
                gatingContract: nftContract, gatingThreshold: 1,
                trialDuration: 0, configured: true
            })
        );
    }

    function test_freeEntitlement() public {
        _configureFree();
        assertTrue(ent.hasEntitlement(CAPSULE_ID, user1));
    }

    function test_oneTimePurchase() public {
        _configureOneTime(100 ether);
        nox.mint(user1, 1000 ether);
        vm.prank(user1);
        nox.approve(address(ent), 100 ether);

        uint256 trsBefore = nox.balanceOf(treasury);
        uint256 pubBefore = nox.balanceOf(publisher);

        vm.prank(user1);
        ent.purchase(CAPSULE_ID);

        assertTrue(ent.hasEntitlement(CAPSULE_ID, user1));
        assertGt(nox.balanceOf(treasury) + nox.balanceOf(nftSink) + nox.balanceOf(stkSink) + nox.balanceOf(publisher) - pubBefore - trsBefore, 0);
    }

    function test_subscriptionExpiry() public {
        _configureSubscription(50 ether, 30 days);
        nox.mint(user1, 200 ether);
        vm.prank(user1); nox.approve(address(ent), 50 ether);
        vm.prank(user1); ent.purchase(CAPSULE_ID);

        assertTrue(ent.hasEntitlement(CAPSULE_ID, user1));

        vm.warp(block.timestamp + 30 days + 1);
        assertFalse(ent.hasEntitlement(CAPSULE_ID, user1));
    }

    function test_tokenHolderGatedAccess() public {
        MockERC20 appToken = new MockERC20("APP", "APP");
        appToken.mint(user1, 1000 ether);
        _configureTokenHolder(address(appToken), 500 ether);

        assertTrue(ent.hasEntitlement(CAPSULE_ID, user1));
        assertFalse(ent.hasEntitlement(CAPSULE_ID, user2));
    }

    function test_nftHolderGatedAccess() public {
        nftPass.mint(user1, 1);
        _configureNFT(address(nftPass));

        assertTrue(ent.hasEntitlement(CAPSULE_ID, user1));
        assertFalse(ent.hasEntitlement(CAPSULE_ID, user2));
    }

    function test_publisherGrantAndRevokeOverridesAccess() public {
        _configureFree();
        assertTrue(ent.hasEntitlement(CAPSULE_ID, user1));

        vm.prank(publisher);
        ent.grantEntitlement(CAPSULE_ID, user1, 0);
        assertTrue(ent.hasEntitlement(CAPSULE_ID, user1));

        vm.prank(publisher);
        ent.revokeEntitlement(CAPSULE_ID, user1);
        assertFalse(ent.hasEntitlement(CAPSULE_ID, user1));
    }

    function test_nonPublisherCannotGrant() public {
        _configureFree();
        vm.prank(attacker);
        vm.expectRevert();
        ent.grantEntitlement(CAPSULE_ID, user1, 0);
    }

    function test_purchaseRoutesThroughFeeRouter() public {
        _configureOneTime(100 ether);
        nox.mint(user1, 200 ether);
        vm.prank(user1); nox.approve(address(ent), 100 ether);

        uint256 capRevBefore = router.capsuleRevenue(CAPSULE_ID, address(nox));
        uint256 pubRevBefore = router.publisherRevenue(publisher, address(nox));

        vm.prank(user1);
        ent.purchase(CAPSULE_ID);

        assertEq(router.capsuleRevenue(CAPSULE_ID, address(nox)) - capRevBefore, 100 ether);
        assertGt(router.publisherRevenue(publisher, address(nox)) - pubRevBefore, 0);
    }

    function _signReceipt(uint256 userPk, IReceiptSettlement.Receipt memory r) internal view returns (bytes memory) {
        bytes32 sh = settle.hashReceipt(r);
        bytes32 domainSep = _domainSeparator();
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSep, sh));
        (uint8 v, bytes32 rr, bytes32 ss) = vm.sign(userPk, digest);
        return abi.encodePacked(rr, ss, v);
    }

    function _domainSeparator() internal view returns (bytes32) {
        bytes32 typeHash = keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
        return keccak256(
            abi.encode(
                typeHash,
                keccak256(bytes("0xNOX Receipt Settlement")),
                keccak256(bytes("1")),
                block.chainid,
                address(settle)
            )
        );
    }

    function test_validReceiptBatchSettles() public {
        (address userAddr, uint256 userPk) = makeAddrAndKey("user-recv");
        nox.mint(userAddr, 1000 ether);
        vm.prank(userAddr); nox.approve(address(settle), 500 ether);

        IReceiptSettlement.Receipt memory r1 = IReceiptSettlement.Receipt({
            capsuleId: CAPSULE_ID, user: userAddr, publisher: publisher,
            amountNox: 5 ether, nonce: 1, epoch: settle.currentEpoch(), expiry: 0,
            receiptType: keccak256("api-call"), signature: ""
        });
        r1.signature = _signReceipt(userPk, r1);

        IReceiptSettlement.Receipt[] memory batch = new IReceiptSettlement.Receipt[](1);
        batch[0] = r1;

        vm.prank(publisher);
        (uint256 settled, uint256 rejected) = settle.batchSettle(batch);
        assertEq(settled, 1);
        assertEq(rejected, 0);
        assertTrue(settle.isUsed(settle.hashReceipt(r1)));
    }

    function test_replayedReceiptRejected() public {
        (address userAddr, uint256 userPk) = makeAddrAndKey("user-replay");
        nox.mint(userAddr, 1000 ether);
        vm.prank(userAddr); nox.approve(address(settle), 500 ether);

        IReceiptSettlement.Receipt memory r1 = IReceiptSettlement.Receipt({
            capsuleId: CAPSULE_ID, user: userAddr, publisher: publisher,
            amountNox: 5 ether, nonce: 1, epoch: settle.currentEpoch(), expiry: 0,
            receiptType: keccak256("call"), signature: ""
        });
        r1.signature = _signReceipt(userPk, r1);

        IReceiptSettlement.Receipt[] memory batch = new IReceiptSettlement.Receipt[](1);
        batch[0] = r1;

        vm.prank(publisher); settle.batchSettle(batch);
        vm.prank(publisher);
        (uint256 settled, uint256 rejected) = settle.batchSettle(batch);
        assertEq(settled, 0);
        assertEq(rejected, 1);
    }

    function test_expiredReceiptRejected() public {
        (address userAddr, uint256 userPk) = makeAddrAndKey("user-exp");
        nox.mint(userAddr, 1000 ether);
        vm.prank(userAddr); nox.approve(address(settle), 500 ether);

        IReceiptSettlement.Receipt memory r1 = IReceiptSettlement.Receipt({
            capsuleId: CAPSULE_ID, user: userAddr, publisher: publisher,
            amountNox: 5 ether, nonce: 1, epoch: settle.currentEpoch(), expiry: block.timestamp + 100,
            receiptType: keccak256("call"), signature: ""
        });
        r1.signature = _signReceipt(userPk, r1);

        vm.warp(block.timestamp + 1000);

        IReceiptSettlement.Receipt[] memory batch = new IReceiptSettlement.Receipt[](1);
        batch[0] = r1;
        vm.prank(publisher);
        (uint256 settled, uint256 rejected) = settle.batchSettle(batch);
        assertEq(settled, 0);
        assertEq(rejected, 1);
    }

    function test_wrongSignerRejected() public {
        (address userAddr, ) = makeAddrAndKey("user-correct");
        (, uint256 attackerPk) = makeAddrAndKey("attacker-sig");
        nox.mint(userAddr, 1000 ether);
        vm.prank(userAddr); nox.approve(address(settle), 500 ether);

        IReceiptSettlement.Receipt memory r1 = IReceiptSettlement.Receipt({
            capsuleId: CAPSULE_ID, user: userAddr, publisher: publisher,
            amountNox: 5 ether, nonce: 1, epoch: settle.currentEpoch(), expiry: 0,
            receiptType: keccak256("call"), signature: ""
        });
        r1.signature = _signReceipt(attackerPk, r1);

        IReceiptSettlement.Receipt[] memory batch = new IReceiptSettlement.Receipt[](1);
        batch[0] = r1;
        vm.prank(publisher);
        (uint256 settled, uint256 rejected) = settle.batchSettle(batch);
        assertEq(settled, 0);
        assertEq(rejected, 1);
    }

    function test_wrongPublisherRejected() public {
        (address userAddr, uint256 userPk) = makeAddrAndKey("user-wp");
        nox.mint(userAddr, 1000 ether);
        vm.prank(userAddr); nox.approve(address(settle), 500 ether);

        IReceiptSettlement.Receipt memory r1 = IReceiptSettlement.Receipt({
            capsuleId: CAPSULE_ID, user: userAddr, publisher: attacker,
            amountNox: 5 ether, nonce: 1, epoch: settle.currentEpoch(), expiry: 0,
            receiptType: keccak256("call"), signature: ""
        });
        r1.signature = _signReceipt(userPk, r1);

        IReceiptSettlement.Receipt[] memory batch = new IReceiptSettlement.Receipt[](1);
        batch[0] = r1;
        vm.prank(attacker);
        (uint256 settled, uint256 rejected) = settle.batchSettle(batch);
        assertEq(settled, 0);
        assertEq(rejected, 1);
    }

    function test_pauseBlocksStateChangingPaths() public {
        _configureOneTime(50 ether);
        nox.mint(user1, 100 ether);
        vm.prank(user1); nox.approve(address(ent), 50 ether);

        vm.prank(admin); ent.pause();
        vm.prank(user1);
        vm.expectRevert();
        ent.purchase(CAPSULE_ID);

        vm.prank(admin); settle.pause();
        IReceiptSettlement.Receipt[] memory batch = new IReceiptSettlement.Receipt[](1);
        (address userAddr, uint256 userPk) = makeAddrAndKey("user-paused");
        IReceiptSettlement.Receipt memory r = IReceiptSettlement.Receipt({
            capsuleId: CAPSULE_ID, user: userAddr, publisher: publisher,
            amountNox: 1 ether, nonce: 1, epoch: settle.currentEpoch(), expiry: 0,
            receiptType: keccak256("c"), signature: ""
        });
        r.signature = _signReceipt(userPk, r);
        batch[0] = r;
        vm.prank(publisher);
        vm.expectRevert();
        settle.batchSettle(batch);
    }

    function test_upgradeAuthorization() public {
        EntitlementRegistry newImpl = new EntitlementRegistry();
        vm.prank(attacker);
        vm.expectRevert();
        ent.upgradeToAndCall(address(newImpl), "");
        vm.prank(admin);
        ent.upgradeToAndCall(address(newImpl), "");

        ReceiptSettlement newSettleImpl = new ReceiptSettlement();
        vm.prank(attacker);
        vm.expectRevert();
        settle.upgradeToAndCall(address(newSettleImpl), "");
        vm.prank(admin);
        settle.upgradeToAndCall(address(newSettleImpl), "");
    }
}

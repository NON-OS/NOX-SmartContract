// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {AppBondingTokenV2}     from "../../../contracts/marketplace/core/AppBondingTokenV2.sol";
import {AppTokenFactoryV2}     from "../../../contracts/marketplace/core/AppTokenFactoryV2.sol";
import {IAppTokenFactoryV2}    from "../../../contracts/marketplace/interfaces/IAppTokenFactoryV2.sol";
import {IAppTokenFactory}      from "../../../contracts/marketplace/interfaces/IAppTokenFactory.sol";
import {IAppBondingTokenV2}    from "../../../contracts/marketplace/interfaces/IAppBondingTokenV2.sol";
import {ICapsuleRegistry}      from "../../../contracts/marketplace/interfaces/ICapsuleRegistry.sol";
import {IUniswapV2Factory, IUniswapV2Pair} from "../../../contracts/marketplace/interfaces/IUniswapV2.sol";
import {BondingCurveLib}       from "../../../contracts/marketplace/libraries/BondingCurveLib.sol";

contract DeployedV2ForkTest is Test {
    address constant FACTORY_PROXY        = 0xa248f486fD838B315883026197cda96387f9E7Dc;
    address constant FACTORY_V2_IMPL_LIVE = 0x58A167A94365B6294900A1e2A4229807DCbcdC09;
    address constant TOKEN_V2_IMPL_LIVE   = 0x16caCbC81249c0A7d2d0271e77f0D05489AB35Dc;
    address constant CAPSULE_REGISTRY     = 0xcaBb848fac25Af95068d64Eb5501e689c88172a3;
    address constant UNI_V2_FACTORY       = 0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f;
    address constant UNI_V2_ROUTER        = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
    address constant WETH                 = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant LP_BURN              = address(0x000000000000000000000000000000000000dEaD);
    address constant B33_ADMIN            = 0xa12eCf0CDfC9D53FFafbdef43696cE615E662B33;

    bytes32 constant EIP1967_IMPL_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    bool _hasFork;

    function setUp() public {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        _hasFork = true;
    }

    function test_live_factoryProxyIsV2Impl() public view {
        if (!_hasFork) return;
        bytes32 slotVal = vm.load(FACTORY_PROXY, EIP1967_IMPL_SLOT);
        address impl = address(uint160(uint256(slotVal)));
        assertEq(impl, FACTORY_V2_IMPL_LIVE, "factory proxy implementation slot must equal deployed V2 impl");
    }

    function test_live_factoryConfigMatchesDeploy() public view {
        if (!_hasFork) return;
        AppTokenFactoryV2 f = AppTokenFactoryV2(FACTORY_PROXY);
        assertEq(f.bondingTokenImplV2(), TOKEN_V2_IMPL_LIVE);
        assertEq(f.weth(), WETH);
        assertEq(f.uniV2Factory(), UNI_V2_FACTORY);
        assertEq(f.uniV2Router(), UNI_V2_ROUTER);
        assertEq(f.lpBurnTo(), LP_BURN);
        assertFalse(f.launchEnabled(), "launch flag must remain false until explicit GO");
    }

    function test_live_v1CreateAppTokenReverts() public {
        if (!_hasFork) return;
        IAppTokenFactory.LaunchParams memory v1 = IAppTokenFactory.LaunchParams({
            capsuleId:        keccak256("anything"),
            releaseId:        bytes32(0),
            name:             "X",
            symbol:           "X",
            metadataURI:      "ipfs://x",
            graduationSupply: 800_000 * 1e18,
            feeBps:           uint16(100)
        });
        bytes memory v1Payload = abi.encodeWithSelector(IAppTokenFactory.createAppToken.selector, v1);
        (bool ok, bytes memory ret) = FACTORY_PROXY.call(v1Payload);
        assertFalse(ok, "V1 createAppToken must revert on the live proxy");
        bytes4 sel;
        assembly { sel := mload(add(ret, 32)) }
        assertEq(sel, IAppTokenFactoryV2.LaunchDisabled.selector, "expected LaunchDisabled() revert");
    }

    function test_live_endToEndLaunchAndGraduateUnderEnabledFlag() public {
        if (!_hasFork) return;
        AppTokenFactoryV2 f = AppTokenFactoryV2(FACTORY_PROXY);

        vm.prank(B33_ADMIN);
        f.setLaunchEnabled(true);
        assertTrue(f.launchEnabled());

        address publisher = address(0xB2F0);
        bytes32 capsuleId = keccak256(abi.encodePacked("forktest:capsule:V2:", block.timestamp));
        bytes32 publisherKeyHash = keccak256("forktest:pubkey");

        ICapsuleRegistry registry = ICapsuleRegistry(CAPSULE_REGISTRY);
        vm.startPrank(publisher);
        registry.registerApp(capsuleId, publisherKeyHash, "ipfs://forktest");
        bytes32 releaseId = registry.submitRelease(
            capsuleId,
            keccak256("forktest:manifest"),
            keccak256("forktest:package"),
            keccak256("forktest:caps"),
            "1.0",
            "ipfs://forktest:pkg"
        );
        vm.stopPrank();

        vm.prank(B33_ADMIN);
        registry.attachValidationResult(releaseId, true, "ipfs://forktest:report");
        vm.prank(publisher);
        registry.publishRelease(releaseId);

        IAppTokenFactoryV2.LaunchParamsV2 memory p = IAppTokenFactoryV2.LaunchParamsV2({
            capsuleId:        capsuleId,
            releaseId:        releaseId,
            name:             "ForkTest",
            symbol:           "FORK",
            metadataURI:      "ipfs://forktest:meta",
            graduationSupply: 800_000 * 1e18,
            lpReserveCap:     200_000_000 * 1e18,
            tradingFeeBps:    100,
            graduationFeeBps: 100
        });
        vm.prank(publisher);
        address tokenAddr = f.createAppTokenV2(p);
        assertTrue(tokenAddr != address(0));

        AppBondingTokenV2 token = AppBondingTokenV2(payable(tokenAddr));
        address buyer = address(0xD400);
        vm.deal(buyer, 5_000 ether);

        uint256 reserveAtGrad = BondingCurveLib.reserveAtSupply(800_000 * 1e18);
        uint256 ethIn = reserveAtGrad * 10_000 / 9_900 + 1;
        vm.prank(buyer);
        token.buy{value: ethIn}(0);
        if (token.totalSupply() < 800_000 * 1e18) {
            vm.prank(buyer);
            token.buy{value: 0.5 ether}(0);
        }

        token.graduate();
        assertTrue(token.isGraduated());
        assertEq(token.reserveBalance(), 0);
        assertEq(address(token).balance, 0);
        assertEq(token.balanceOf(address(token)), 0);

        address pair = IUniswapV2Factory(UNI_V2_FACTORY).getPair(address(token), WETH);
        assertTrue(pair != address(0));
        assertEq(token.pair(), pair);

        uint256 lpBurned = IERC20(pair).balanceOf(LP_BURN);
        assertGt(lpBurned, 0, "LP must be burned at 0xdead");

        (uint112 r0, uint112 r1, ) = IUniswapV2Pair(pair).getReserves();
        address t0 = IUniswapV2Pair(pair).token0();
        uint256 tokR; uint256 ethR;
        if (t0 == address(token)) { tokR = r0; ethR = r1; }
        else                      { tokR = r1; ethR = r0; }
        assertGt(tokR, 0); assertGt(ethR, 0);

        uint256 spotPerToken = (ethR * 1e18) / tokR;
        uint256 terminalPrice = token.terminalPriceWeiPerToken();
        assertApproxEqAbs(spotPerToken, terminalPrice, 1, "price continuity");
    }
}

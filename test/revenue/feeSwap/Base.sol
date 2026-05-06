// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {FeeSwapRouter} from "../../../contracts/marketplace/revenue/FeeSwapRouter.sol";
import {SwapParams} from "../../../contracts/marketplace/revenue/IFeeSwapRouter.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {MockSwapRouter} from "./Mocks.sol";

abstract contract FeeSwapBase is Test {
    address admin       = address(0xA001);
    address configSafe  = address(0xC001);
    address pauserSafe  = address(0xC002);
    address upgrader    = address(0xC003);
    address treasurySafe= address(0xD001);
    address attacker    = address(0xBAD);
    address user        = address(0xCAFE);

    bytes32 constant ROUTE_V2_ETH_NOX = keccak256("v2:eth-nox");
    bytes32 constant ROUTE_V2_NOX_ETH = keccak256("v2:nox-eth");

    FeeSwapRouter   router;
    MockERC20       nox;
    MockSwapRouter  target;

    function setUp() public virtual {
        nox = new MockERC20("NOX", "NOX");
        target = new MockSwapRouter(address(nox), 100e18);
        vm.deal(address(target), 100 ether);

        FeeSwapRouter impl = new FeeSwapRouter();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeCall(FeeSwapRouter.initialize, (admin, configSafe, pauserSafe, upgrader, treasurySafe, 10))
        );
        router = FeeSwapRouter(payable(address(proxy)));

        vm.prank(configSafe);
        router.setTargetApproved(address(target), true);

        vm.deal(user, 100 ether);
    }

    function _ethToTokenParams(uint256 amountIn, uint256 minOut) internal view returns (SwapParams memory) {
        return SwapParams({
            inputToken: address(0),
            amountIn: amountIn,
            target: address(target),
            data: abi.encodeCall(MockSwapRouter.buyTokenWithEth, (user, minOut)),
            outputToken: address(nox),
            minOut: minOut,
            receiver: user,
            routeId: ROUTE_V2_ETH_NOX
        });
    }
}

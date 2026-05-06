// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

import {FeeSwapBase} from "./Base.sol";
import {FeeSwapRouter} from "../../../contracts/marketplace/revenue/FeeSwapRouter.sol";
import {FeeSwapErrors} from "../../../contracts/marketplace/revenue/FeeSwapErrors.sol";
import {SwapParams} from "../../../contracts/marketplace/revenue/IFeeSwapRouter.sol";

contract FeeSwapPauseTest is FeeSwapBase {
    function test_pauseBlocksSwaps() public {
        vm.prank(pauserSafe); router.setPaused(true);
        assertTrue(router.paused());
        SwapParams memory p = _ethToTokenParams(1 ether, 0);
        vm.expectRevert(FeeSwapErrors.PausedError.selector);
        vm.prank(user); router.swap{value: 1 ether}(p);
    }

    function test_unpauseRestoresSwaps() public {
        vm.prank(pauserSafe); router.setPaused(true);
        vm.prank(pauserSafe); router.setPaused(false);
        assertFalse(router.paused());
        SwapParams memory p = _ethToTokenParams(1 ether, 0);
        vm.prank(user); router.swap{value: 1 ether}(p);
    }
}

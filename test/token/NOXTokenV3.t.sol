// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {NONOS_NOX_MAINNET_V3} from "../../contracts/token/NOXTokenV3.sol";

interface IUUPS {
    function upgradeToAndCall(address newImplementation, bytes calldata data) external payable;
}

interface INOX {
    function totalSupply() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
    function isBlacklisted(address) external view returns (bool);
    function totalBurned() external view returns (uint256);
    function fees() external view returns (uint16, uint16, uint16, uint16, uint16, uint16, uint16);
    function setFees(uint16, uint16, uint16, uint16, uint16, uint16, uint16) external;
    function setAutoSwapConfig(uint256, uint16, bool) external;
    function setMaxAutoSwapChunk(uint256) external;
    function triggerAutoSwap() external;
    function setExemptions(address, bool, bool) external;
    function setBlacklist(address, bool) external;
    function renounceBlacklist() external;
    function blacklistRenounced() external view returns (bool);
    function uniswapPair() external view returns (address);
    function noxVersion() external view returns (string memory);
}

interface IRouter {
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256, uint256, address[] calldata, address, uint256
    ) external;
    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint256, address[] calldata, address, uint256
    ) external payable;
}

interface IPair {
    function getReserves() external view returns (uint112, uint112, uint32);
    function balanceOf(address) external view returns (uint256);
}

/// @title NOX V3 upgrade test suite (mainnet fork).
/// @notice Validates the hardened upgrade end-to-end against live state:
///         state preservation, removed powers, fee model, auto-liquidity,
///         blacklist renounce, access control and supply integrity.
contract NOXTokenV3Test is Test {
    address constant PROXY = 0x0a26c80Be4E060e688d7C23aDdB92cBb5D2C9eCA;
    address constant SAFE = 0x3a52ea60F61036Afbbec25F46a64485Ac4477Ccc;
    address constant ROUTER = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant HOLDER = 0x9B90166E484a5C57608D3b2e78B79e10dA92c3b7;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address constant FROZEN = 0x6a1e6919Ad6B6c21f6D193dbab61d5eC822bd7d7;

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("mainnet"));
        NONOS_NOX_MAINNET_V3 impl = new NONOS_NOX_MAINNET_V3();
        vm.prank(SAFE);
        IUUPS(PROXY).upgradeToAndCall(address(impl), "");
        vm.startPrank(SAFE);
        INOX(PROXY).setFees(0, 300, 0, 1000, 9000, 0, 0);
        INOX(PROXY).setAutoSwapConfig(1, 300, true);
        INOX(PROXY).setMaxAutoSwapChunk(1_000_000 ether);
        vm.stopPrank();
    }

    function test_version_and_state_preserved() public view {
        assertGt(INOX(PROXY).totalSupply(), 0);
        assertEq(keccak256(bytes(INOX(PROXY).noxVersion())), keccak256("NONOS_NOX_MAINNET_V3"));
        assertTrue(INOX(PROXY).isBlacklisted(FROZEN), "blacklist state preserved");
    }

    function test_powers_removed() public {
        (bool a,) = PROXY.call(abi.encodeWithSignature("pause()"));
        (bool b,) = PROXY.call(
            abi.encodeWithSignature("setGuards(bool,bool,bool,uint16,uint16,uint64)", true, true, true, uint16(50), uint16(400), uint64(20))
        );
        (bool c,) = PROXY.call(abi.encodeWithSignature("setEmergencyStop(bool)", true));
        (bool d,) = PROXY.call(abi.encodeWithSignature("setDeflationParams(uint16,uint16,uint16)", uint16(100), uint16(0), uint16(0)));
        (bool e,) = PROXY.call(abi.encodeWithSignature("seizeBlacklisted(address,address)", FROZEN, SAFE));
        assertFalse(a || b || c || d || e, "all removed powers must revert");
    }

    function test_fee_cap_is_three_percent() public {
        vm.prank(SAFE);
        vm.expectRevert(bytes("a"));
        INOX(PROXY).setFees(0, 301, 0, 1000, 9000, 0, 0);
    }

    function test_buy_is_untaxed() public {
        address[] memory path = new address[](2);
        path[0] = WETH;
        path[1] = PROXY;
        vm.deal(address(0xB0B), 1 ether);
        uint256 before = INOX(PROXY).balanceOf(address(0xB0B));
        vm.prank(address(0xB0B));
        IRouter(ROUTER).swapExactETHForTokensSupportingFeeOnTransferTokens{value: 1 ether}(0, path, address(0xB0B), block.timestamp);
        assertGt(INOX(PROXY).balanceOf(address(0xB0B)), before);
    }

    function test_transfer_is_untaxed() public {
        vm.prank(HOLDER);
        INOX(PROXY).transfer(address(0xCAFE), 1000 ether);
        assertEq(INOX(PROXY).balanceOf(address(0xCAFE)), 1000 ether);
    }

    function test_sell_applies_burn_share() public {
        vm.prank(HOLDER);
        INOX(PROXY).transfer(address(0x5E11), 100_000 ether);
        uint256 burnedBefore = INOX(PROXY).totalBurned();
        address[] memory path = new address[](2);
        path[0] = PROXY;
        path[1] = WETH;
        vm.startPrank(address(0x5E11));
        INOX(PROXY).approve(ROUTER, 100_000 ether);
        IRouter(ROUTER).swapExactTokensForETHSupportingFeeOnTransferTokens(100_000 ether, 0, path, address(0x5E11), block.timestamp);
        vm.stopPrank();
        assertGt(INOX(PROXY).totalBurned(), burnedBefore);
    }

    function test_autoliquidity_locks_lp_to_dead() public {
        address pair = INOX(PROXY).uniswapPair();
        uint256 lpBefore = IPair(pair).balanceOf(DEAD);
        vm.prank(HOLDER);
        INOX(PROXY).transfer(PROXY, 200_000 ether);
        vm.prank(SAFE);
        INOX(PROXY).triggerAutoSwap();
        assertGt(IPair(pair).balanceOf(DEAD), lpBefore, "LP minted to dead -> liquidity permanently locked");
    }

    function test_fee_exempt_pays_nothing() public {
        vm.prank(SAFE);
        INOX(PROXY).setExemptions(address(0xE0E), true, true);
        vm.prank(HOLDER);
        INOX(PROXY).transfer(address(0xE0E), 50_000 ether);
        uint256 burnedBefore = INOX(PROXY).totalBurned();
        address[] memory path = new address[](2);
        path[0] = PROXY;
        path[1] = WETH;
        vm.startPrank(address(0xE0E));
        INOX(PROXY).approve(ROUTER, 50_000 ether);
        IRouter(ROUTER).swapExactTokensForETHSupportingFeeOnTransferTokens(50_000 ether, 0, path, address(0xE0E), block.timestamp);
        vm.stopPrank();
        assertEq(INOX(PROXY).totalBurned(), burnedBefore);
    }

    function test_blacklist_blocks_and_renounce_is_one_way() public {
        vm.prank(HOLDER);
        vm.expectRevert(bytes("g"));
        INOX(PROXY).transfer(FROZEN, 1 ether);

        vm.prank(SAFE);
        INOX(PROXY).renounceBlacklist();
        assertTrue(INOX(PROXY).blacklistRenounced());
        vm.prank(SAFE);
        vm.expectRevert(bytes("renounced"));
        INOX(PROXY).setBlacklist(FROZEN, false);
    }

    function test_access_control() public {
        vm.startPrank(address(0xBAD));
        vm.expectRevert();
        INOX(PROXY).setFees(0, 300, 0, 1000, 9000, 0, 0);
        vm.expectRevert();
        INOX(PROXY).triggerAutoSwap();
        vm.stopPrank();
    }

    function test_supply_never_inflates() public {
        uint256 s0 = INOX(PROXY).totalSupply();
        vm.prank(HOLDER);
        INOX(PROXY).transfer(address(0x5E11), 100_000 ether);
        address[] memory path = new address[](2);
        path[0] = PROXY;
        path[1] = WETH;
        vm.startPrank(address(0x5E11));
        INOX(PROXY).approve(ROUTER, 100_000 ether);
        IRouter(ROUTER).swapExactTokensForETHSupportingFeeOnTransferTokens(100_000 ether, 0, path, address(0x5E11), block.timestamp);
        vm.stopPrank();
        assertLe(INOX(PROXY).totalSupply(), s0);
    }

    function test_real_sell_never_reverts() public {
        address[] memory path = new address[](2);
        path[0] = PROXY;
        path[1] = WETH;
        uint256 ethBefore = HOLDER.balance;
        vm.startPrank(HOLDER);
        INOX(PROXY).approve(ROUTER, 100_000 ether);
        IRouter(ROUTER).swapExactTokensForETHSupportingFeeOnTransferTokens(100_000 ether, 0, path, HOLDER, block.timestamp);
        vm.stopPrank();
        assertGt(HOLDER.balance, ethBefore);
    }
}

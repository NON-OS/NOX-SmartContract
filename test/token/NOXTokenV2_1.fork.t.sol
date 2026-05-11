// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Test.sol";

interface IProxy {
    function totalSupply() external view returns (uint256);
    function uniswapPair() external view returns (address);
    function uniswapRouter() external view returns (address);
    function autoSwapEnabled() external view returns (bool);
    function autoSwapThreshold() external view returns (uint256);
    function autoSwapSlippageBps() external view returns (uint16);
    function maxAutoSwapChunk() external view returns (uint256);
    function ethFallbackRecipient() external view returns (address);
    function totalFailedEth() external view returns (uint256);
    function devWallet() external view returns (address);
    function treasury() external view returns (address);
    function feeExempt(address) external view returns (bool);
    function limitsExempt(address) external view returns (bool);
    function hasRole(bytes32, address) external view returns (bool);
    function fees() external view returns (uint16, uint16, uint16, uint16, uint16, uint16, uint16);
}

contract NOXForkPostMigrationInvariantsTest is Test {
    address constant PROXY = 0x0a26c80Be4E060e688d7C23aDdB92cBb5D2C9eCA;
    address constant EOA = 0xa12eCf0CDfC9D53FFafbdef43696cE615E662B33;
    address constant SAFE = 0x3a52ea60F61036Afbbec25F46a64485Ac4477Ccc;
    address constant NEW_IMPL = 0xBf0415ebFC762B4166e198736a15Ff0B53744e43;
    address constant PAIR = 0x07CE5889D2EB681Af3bD61db24Ab2602c502Bd1B;
    address constant ROUTER = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;

    bytes32 constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 constant GOVERNOR_ROLE = 0x7935bd0ae54bc31f548c14dba4d37c5c64b3f8ca900cb468fb8abd54d5894f55;
    bytes32 constant UPGRADER_ROLE = 0x189ab7a9244df0848122154315af71fe140f3db0fe014031783b0946b8c9d2e3;
    bytes32 constant EMERGENCY_ROLE = 0xbf233dd2aafeb4d50879c4aa5c81e96d92f6e6945c906a58f9f2d1c1631b4b26;
    bytes32 constant ERC1967_IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    function setUp() public {
        try vm.envString("ETH_RPC_URL") returns (string memory rpc) {
            vm.createSelectFork(rpc);
        } catch {
            vm.skip(true);
        }
    }

    function test_live_implementation_is_V2_1() public view {
        bytes32 implWord = vm.load(PROXY, ERC1967_IMPL_SLOT);
        assertEq(address(uint160(uint256(implWord))), NEW_IMPL, "live impl must be V2.1");
    }

    function test_live_addresses_unchanged() public view {
        IProxy p = IProxy(PROXY);
        assertEq(p.uniswapPair(), PAIR);
        assertEq(p.uniswapRouter(), ROUTER);
    }

    function test_live_v2_1_state_initialized() public view {
        IProxy p = IProxy(PROXY);
        assertEq(p.maxAutoSwapChunk(), 50_000e18);
        assertEq(p.ethFallbackRecipient(), SAFE);
    }

    function test_live_fees_at_2_5_percent() public view {
        (uint16 buy, uint16 sell, uint16 t,,,,) = IProxy(PROXY).fees();
        assertEq(buy, 250);
        assertEq(sell, 250);
        assertEq(t, 0);
    }

    function test_live_recipients_routed_to_safe() public view {
        IProxy p = IProxy(PROXY);
        assertEq(p.devWallet(), SAFE);
        assertEq(p.treasury(), SAFE);
    }

    function test_live_pair_protections_active() public view {
        IProxy p = IProxy(PROXY);
        assertTrue(p.limitsExempt(PAIR));
        assertFalse(p.feeExempt(PAIR));
    }

    function test_live_roles_migrated_to_safe() public view {
        IProxy p = IProxy(PROXY);

        assertTrue(p.hasRole(DEFAULT_ADMIN_ROLE, SAFE));
        assertTrue(p.hasRole(GOVERNOR_ROLE, SAFE));
        assertTrue(p.hasRole(UPGRADER_ROLE, SAFE));
        assertTrue(p.hasRole(EMERGENCY_ROLE, SAFE));

        assertFalse(p.hasRole(DEFAULT_ADMIN_ROLE, EOA));
        assertFalse(p.hasRole(GOVERNOR_ROLE, EOA));
        assertFalse(p.hasRole(UPGRADER_ROLE, EOA));
        assertFalse(p.hasRole(EMERGENCY_ROLE, EOA));
    }

    function test_live_auto_swap_enabled() public view {
        IProxy p = IProxy(PROXY);
        assertTrue(p.autoSwapEnabled());
        assertEq(p.autoSwapThreshold(), 1_000e18);
        assertEq(p.autoSwapSlippageBps(), 100);
    }

    function test_live_no_stuck_eth() public view {

        assertEq(IProxy(PROXY).totalFailedEth(), 0);
    }
}

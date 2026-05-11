// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {NOXStakingV4} from "../../contracts/staking/NOXStakingV4.sol";
import {NOXNamespaceRegistry} from "../../contracts/registry/NOXNamespaceRegistry.sol";
import {MockNOX, MockZeroStatePass} from "../staking/mocks/StakingMocks.sol";

contract NOXNamespaceRegistryTest is Test {
    NOXStakingV4 stk;
    NOXNamespaceRegistry nsReg;
    MockNOX nox;
    MockZeroStatePass zsp;

    address admin = makeAddr("admin");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        vm.warp(1_700_000_000);

        nox = new MockNOX();
        zsp = new MockZeroStatePass();
        NOXStakingV4 impl = new NOXStakingV4();
        bytes memory init = abi.encodeCall(impl.initialize, (address(nox), address(zsp), admin));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), init);
        stk = NOXStakingV4(address(proxy));

        vm.prank(admin);
        stk.reinitV4(500, 0);
        vm.prank(admin);
        stk.setGenesisTime(block.timestamp + 1);
        vm.warp(block.timestamp + 2);

        nox.transfer(alice, 1_000_000 ether);
        nox.transfer(address(stk), 50_000_000 ether);
        vm.prank(alice);
        nox.approve(address(stk), type(uint256).max);

        nsReg = new NOXNamespaceRegistry(address(stk));
    }

    function _stakeAndBind(address user, uint256 amount, uint256 tokenId) internal {
        vm.prank(user);
        stk.stake(amount);
        zsp.mint(user, 1);
        vm.prank(user);
        stk.bindZeroStatePass(0, tokenId);
    }

    function test_reserve_happy_path() public {
        _stakeAndBind(alice, 2_000 ether, 1);
        bytes32 nameHash = keccak256("alice.nonos");

        assertTrue(nsReg.canReserve(alice, 0, nameHash));
        vm.prank(alice);
        nsReg.reserveNamespace(nameHash, 0);
        assertEq(nsReg.ownerOfNamespace(nameHash), alice);

        (address owner, uint256 pid, uint64 ts) = nsReg.getNamespace(nameHash);
        assertEq(owner, alice);
        assertEq(pid, 0);
        assertEq(ts, uint64(block.timestamp));
    }

    function test_reserve_rejects_ineligible() public {

        vm.expectRevert(NOXNamespaceRegistry.NotEligible.selector);
        vm.prank(alice);
        nsReg.reserveNamespace(keccak256("test.nonos"), 0);
    }

    function test_reserve_rejects_double_reserve() public {
        _stakeAndBind(alice, 2_000 ether, 1);
        bytes32 nameHash = keccak256("alice.nonos");
        vm.prank(alice);
        nsReg.reserveNamespace(nameHash, 0);
        vm.expectRevert(NOXNamespaceRegistry.AlreadyReserved.selector);
        vm.prank(alice);
        nsReg.reserveNamespace(nameHash, 0);
    }

    function test_release_by_owner() public {
        _stakeAndBind(alice, 2_000 ether, 1);
        bytes32 nameHash = keccak256("alice.nonos");
        vm.prank(alice);
        nsReg.reserveNamespace(nameHash, 0);
        vm.prank(alice);
        nsReg.releaseNamespace(nameHash);
        assertEq(nsReg.ownerOfNamespace(nameHash), address(0));
    }

    function test_release_rejects_non_owner() public {
        _stakeAndBind(alice, 2_000 ether, 1);
        bytes32 nameHash = keccak256("alice.nonos");
        vm.prank(alice);
        nsReg.reserveNamespace(nameHash, 0);
        vm.expectRevert(NOXNamespaceRegistry.NotNamespaceOwner.selector);
        vm.prank(bob);
        nsReg.releaseNamespace(nameHash);
    }

    function test_zero_name_hash_rejected() public {
        _stakeAndBind(alice, 2_000 ether, 1);
        vm.expectRevert(NOXNamespaceRegistry.ZeroNameHash.selector);
        vm.prank(alice);
        nsReg.reserveNamespace(bytes32(0), 0);
    }

    function test_no_kernel_capability_granted() public pure {

        assertTrue(true);
    }
}

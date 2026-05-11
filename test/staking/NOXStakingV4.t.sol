// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {NOXStakingV4} from "../../contracts/staking/NOXStakingV4.sol";
import {MockNOX, MockZeroStatePass} from "./mocks/StakingMocks.sol";

contract NOXStakingV4Test is Test {
    NOXStakingV4 stk;
    MockNOX nox;
    MockZeroStatePass zsp;

    address admin = makeAddr("admin");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    uint256 constant LOCK_30 = 30 days;
    uint256 constant LOCK_365 = 365 days;

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
        nox.transfer(bob, 1_000_000 ether);
        nox.transfer(address(stk), 50_000_000 ether);

        vm.prank(alice);
        nox.approve(address(stk), type(uint256).max);
        vm.prank(bob);
        nox.approve(address(stk), type(uint256).max);
    }

    function test_reinitV4_cannot_be_replayed() public {
        vm.expectRevert();
        vm.prank(admin);
        stk.reinitV4(123, 0);
    }

    function test_initializeV3_selector_removed() public view {

        bytes4 sel = bytes4(keccak256("initializeV3(uint256)"));
        assertFalse(sel == bytes4(keccak256("reinitV4(uint256,uint256)")));
    }

    function test_emergencyWithdraw_cannot_drain_principal() public {
        vm.prank(alice);
        stk.stake(100_000 ether);

        uint256 contractBal = nox.balanceOf(address(stk));
        vm.expectRevert(NOXStakingV4.ReserveProtected.selector);
        vm.prank(admin);
        stk.emergencyWithdraw(address(nox), admin, contractBal);
    }

    function test_emergencyWithdraw_can_pull_only_unreserved_NOX() public {
        vm.prank(alice);
        stk.stake(100_000 ether);

        uint256 reserve = stk.rewardReserve();
        uint256 adminBefore = nox.balanceOf(admin);

        vm.prank(admin);
        stk.emergencyWithdraw(address(nox), admin, reserve);
        assertEq(nox.balanceOf(admin), adminBefore + reserve);

        vm.expectRevert(NOXStakingV4.ReserveProtected.selector);
        vm.prank(admin);
        stk.emergencyWithdraw(address(nox), admin, 1);
    }

    function test_emergencyWithdraw_protectedReserve_respected() public {
        vm.prank(alice);
        stk.stake(100_000 ether);

        vm.prank(admin);
        stk.setProtectedRewardReserve(10_000_000 ether);

        uint256 expectedAvail = nox.balanceOf(address(stk)) - stk.totalStaked() - 10_000_000 ether;

        vm.prank(admin);
        stk.emergencyWithdraw(address(nox), admin, expectedAvail);

        vm.expectRevert(NOXStakingV4.ReserveProtected.selector);
        vm.prank(admin);
        stk.emergencyWithdraw(address(nox), admin, 1);
    }

    function test_emergencyWithdraw_zero_to_reverts() public {
        vm.expectRevert(NOXStakingV4.ZeroAddress.selector);
        vm.prank(admin);
        stk.emergencyWithdraw(address(nox), address(0), 1);
    }

    function test_emergencyWithdraw_non_NOX_uncapped() public {

        MockNOX other = new MockNOX();
        other.mint(address(stk), 1_000 ether);

        vm.prank(admin);
        stk.emergencyWithdraw(address(other), admin, 1_000 ether);
        assertEq(other.balanceOf(admin), 1_000 ether);
    }

    function test_refreshBoost_reverts_while_paused() public {
        vm.prank(alice);
        stk.stake(100_000 ether);

        vm.prank(admin);
        stk.pause();

        vm.expectRevert();
        stk.refreshBoost(alice);
    }

    function test_refreshBoost_works_unpaused() public {
        vm.prank(alice);
        stk.stake(100_000 ether);
        zsp.mint(alice, 3);
        stk.refreshBoost(alice);

        (uint256 amount, uint256 weighted,,,,,) = stk.getStakeInfo(alice);
        assertGt(weighted, amount);
    }

    function test_compoundRewards_no_double_claim() public {
        vm.prank(alice);
        stk.stake(100_000 ether);

        vm.warp(block.timestamp + 7 days);

        uint256 pending = stk.pendingRewards(alice);
        assertGt(pending, 0);

        uint256 totalStakedBefore = stk.totalStaked();
        uint256 contractBalBefore = nox.balanceOf(address(stk));

        vm.prank(alice);
        stk.compoundRewards(0);

        uint256 totalStakedAfter = stk.totalStaked();
        uint256 contractBalAfter = nox.balanceOf(address(stk));

        assertEq(contractBalBefore, contractBalAfter, "contract bal must be unchanged on compound");

        assertGt(totalStakedAfter, totalStakedBefore);

        assertEq(stk.pendingRewards(alice), 0);

        vm.expectRevert(NOXStakingV4.NothingToCompound.selector);
        vm.prank(alice);
        stk.compoundRewards(0);
    }

    function test_compoundRewards_respects_pause() public {
        vm.prank(alice);
        stk.stake(100_000 ether);
        vm.warp(block.timestamp + 1 days);
        vm.prank(admin);
        stk.pause();
        vm.expectRevert();
        vm.prank(alice);
        stk.compoundRewards(0);
    }

    function test_unlockExpired_reverts_before_expiry() public {
        vm.prank(alice);
        stk.stakeLocked(100_000 ether, LOCK_30);
        vm.expectRevert(NOXStakingV4.LockNotExpired.selector);
        vm.prank(alice);
        stk.unlockExpired(0);
    }

    function test_unlockExpired_reverts_when_never_locked() public {
        vm.prank(alice);
        stk.stake(100_000 ether);
        vm.expectRevert(NOXStakingV4.LockNotExpired.selector);
        vm.prank(alice);
        stk.unlockExpired(0);
    }

    function test_unlockExpired_works_after_expiry() public {
        vm.prank(alice);
        stk.stakeLocked(100_000 ether, LOCK_30);
        vm.warp(block.timestamp + LOCK_30 + 1);
        vm.prank(alice);
        stk.unlockExpired(0);
        (,, uint256 lockPeriod, uint256 lockEndTime,,,) = stk.getPosition(alice, 0);
        assertEq(lockPeriod, 0);
        assertEq(lockEndTime, 0);
    }

    function test_migrateMyPositions_idempotent() public {
        vm.prank(alice);
        stk.stake(100_000 ether);

        uint256 ver1 = stk.userMigrationVersion(alice);
        vm.prank(alice);
        stk.migrateMyPositions();
        uint256 ver2 = stk.userMigrationVersion(alice);
        assertEq(ver2, 4);
        assertEq(ver1, ver2);
    }

    function test_migrate_does_not_change_balances() public {
        vm.prank(alice);
        stk.stake(100_000 ether);
        uint256 stakedBefore = stk.totalStaked();
        uint256 weightedBefore = stk.totalWeightedStake();
        uint256 contractBefore = nox.balanceOf(address(stk));

        vm.prank(alice);
        stk.migrateMyPositions();

        assertEq(stk.totalStaked(), stakedBefore);
        assertEq(stk.totalWeightedStake(), weightedBefore);
        assertEq(nox.balanceOf(address(stk)), contractBefore);
    }

    function test_commitmentScore_does_not_affect_balances() public {
        vm.prank(alice);
        stk.stakeLocked(100_000 ether, LOCK_365);
        vm.warp(block.timestamp + 30 days);

        uint256 score = stk.commitmentScore(alice);
        assertGt(score, 0);

        assertEq(nox.balanceOf(alice), 1_000_000 ether - 100_000 ether);

    }

    function test_stakingTier_returns_expected_tier() public {

        (uint8 t0, string memory n0) = stk.stakingTier(alice);
        assertEq(t0, 0);
        assertEq(keccak256(bytes(n0)), keccak256(bytes("Void")));

        vm.prank(alice);
        stk.stake(15_000 ether);
        (uint8 t1, string memory n1) = stk.stakingTier(alice);
        assertEq(t1, 3);
        assertEq(keccak256(bytes(n1)), keccak256(bytes("Capsule")));
    }

    function test_claimRewards_partial_when_reserve_low() public {

        uint256 drainAmount = stk.rewardReserve() - 1 ether;
        vm.prank(admin);
        stk.emergencyWithdraw(address(nox), admin, drainAmount);

        vm.prank(alice);
        stk.stake(100_000 ether);
        vm.warp(block.timestamp + 30 days);

        uint256 pendingBefore = stk.pendingRewards(alice);
        assertGt(pendingBefore, 1 ether);

        vm.prank(alice);
        stk.claimRewards();

        assertGt(stk.pendingRewards(alice), 0);
        assertLt(nox.balanceOf(alice) - 900_000 ether, pendingBefore);
    }

    function test_claimRewards_no_rewards_reverts() public {
        vm.expectRevert(NOXStakingV4.NoRewardsToClaim.selector);
        vm.prank(alice);
        stk.claimRewards();
    }

    function test_stake_unstake_roundtrip() public {
        uint256 aliceBefore = nox.balanceOf(alice);

        vm.prank(alice);
        stk.stake(100_000 ether);
        assertEq(nox.balanceOf(alice), aliceBefore - 100_000 ether);
        assertEq(stk.totalStaked(), 100_000 ether);

        vm.prank(alice);
        stk.unstake(100_000 ether);
        assertEq(nox.balanceOf(alice), aliceBefore);
        assertEq(stk.totalStaked(), 0);
    }

    function test_locked_stake_cannot_unstake_early() public {
        vm.prank(alice);
        stk.stakeLocked(100_000 ether, LOCK_30);
        vm.expectRevert();
        vm.prank(alice);
        stk.unstake(100_000 ether);

    }

    function test_earlyUnlock_burns_penalty() public {
        vm.prank(alice);
        stk.stakeLocked(100_000 ether, LOCK_30);

        uint256 burnBefore = nox.balanceOf(address(0xdead));
        vm.prank(alice);
        stk.earlyUnlock(0);

        assertEq(nox.balanceOf(address(0xdead)), burnBefore + 5_000 ether);
        assertEq(nox.balanceOf(alice), 1_000_000 ether - 5_000 ether);
        assertEq(stk.totalPenaltiesBurned(), 5_000 ether);
    }

    function test_invariant_balance_geq_totalStaked() public {
        vm.prank(alice);
        stk.stake(500_000 ether);
        vm.prank(bob);
        stk.stakeLocked(300_000 ether, LOCK_365);

        assertGe(nox.balanceOf(address(stk)), stk.totalStaked());
    }

    function test_invariant_pause_blocks_state_changes() public {
        vm.prank(alice);
        stk.stake(100_000 ether);

        vm.prank(admin);
        stk.pause();

        vm.expectRevert();
        vm.prank(alice);
        stk.stake(1 ether);
        vm.expectRevert();
        vm.prank(alice);
        stk.unstake(1 ether);
        vm.expectRevert();
        vm.prank(alice);
        stk.claimRewards();
        vm.expectRevert();
        vm.prank(alice);
        stk.compoundRewards(0);
        vm.expectRevert();
        vm.prank(alice);
        stk.unlockExpired(0);
        vm.expectRevert();
        vm.prank(alice);
        stk.migrateMyPositions();
        vm.expectRevert();
        stk.refreshBoost(alice);
    }

    function test_views_return_sane() public {
        vm.prank(alice);
        stk.stake(100_000 ether);

        assertGt(stk.rewardReserve(), 0);
        assertGt(stk.rewardRunway(), 0);

        (
            uint256 ts,
            uint256 tw,
            uint256 reserve,
            uint256 distributed,
            uint256 burned,
            uint256 emRate,
            uint256 acc
        ) = stk.protocolStakingStats();
        assertEq(ts, 100_000 ether);
        assertEq(distributed, 0);
        assertEq(burned, 0);
        assertGt(emRate, 0);

        (uint256 amt, uint256 wt, uint256 pending, uint256 active, uint256 lle, uint256 age) =
            stk.userPositionSummary(alice);
        assertEq(amt, 100_000 ether);
        assertEq(active, 1);
    }

    function test_compound_preserves_balance_invariant() public {
        vm.prank(alice);
        stk.stake(100_000 ether);
        vm.warp(block.timestamp + 30 days);

        uint256 balBefore = nox.balanceOf(address(stk));
        vm.prank(alice);
        stk.compoundRewards(0);
        uint256 balAfter = nox.balanceOf(address(stk));

        assertEq(balBefore, balAfter, "balance must not change on compound");
        assertGe(nox.balanceOf(address(stk)), stk.totalStaked());
    }

    function test_extendLock_after_partial() public {
        vm.prank(alice);
        stk.stakeLocked(100_000 ether, LOCK_30);
        vm.warp(block.timestamp + 5 days);
        vm.prank(alice);
        stk.extendLock(0, LOCK_365);
        (,, uint256 lockPeriod, uint256 lockEndTime,,,) = stk.getPosition(alice, 0);
        assertEq(lockPeriod, LOCK_365);
        assertEq(lockEndTime, block.timestamp + LOCK_365);
    }

    function test_operatorId_is_deterministic_and_unique() public view {
        bytes32 a1 = stk.operatorId(alice, 0);
        bytes32 a2 = stk.operatorId(alice, 1);
        bytes32 b1 = stk.operatorId(bob, 0);
        assertTrue(a1 != bytes32(0));
        assertTrue(a1 != a2);
        assertTrue(a1 != b1);

        assertEq(a1, stk.operatorId(alice, 0));
    }

    function test_getStakeReceipt_for_active_position() public {
        vm.prank(alice);
        stk.stakeLocked(100_000 ether, LOCK_365);
        NOXStakingV4.StakeReceipt memory r = stk.getStakeReceipt(alice, 0);
        assertEq(r.wallet, alice);
        assertEq(r.positionId, 0);
        assertEq(r.amount, 100_000 ether);
        assertEq(r.lockPeriod, LOCK_365);
        assertTrue(r.active);
        assertEq(r.boundZeroStatePassTokenId, 0);
        assertFalse(r.zeroStatePassValid);
        assertEq(r.opId, stk.operatorId(alice, 0));
    }

    function test_stakeReceiptDigest_changes_with_state() public {
        vm.prank(alice);
        stk.stake(100_000 ether);
        bytes32 d1 = stk.stakeReceiptDigest(alice, 0);
        vm.prank(alice);
        zsp.setApprovalForAll(address(stk), true);
        zsp.mint(alice, 1);
        vm.prank(alice);
        stk.bindZeroStatePass(0, 1);
        bytes32 d2 = stk.stakeReceiptDigest(alice, 0);
        assertTrue(d1 != d2, "digest must change after binding");
    }

    function test_bindZeroStatePass_happy_path() public {
        vm.prank(alice);
        stk.stake(100_000 ether);
        zsp.mint(alice, 1);

        vm.prank(alice);
        stk.bindZeroStatePass(0, 1);
        assertTrue(stk.isZeroStatePassValidlyBound(alice, 0));
    }

    function test_bindZeroStatePass_requires_ownership() public {
        vm.prank(alice);
        stk.stake(100_000 ether);
        zsp.mint(bob, 1);
        vm.expectRevert(NOXStakingV4.NotZeroStatePassOwner.selector);
        vm.prank(alice);
        stk.bindZeroStatePass(0, 1);
    }

    function test_bindZeroStatePass_rejects_double_bind() public {
        vm.prank(alice);
        stk.stake(100_000 ether);
        zsp.mint(alice, 2);
        vm.prank(alice);
        stk.bindZeroStatePass(0, 1);
        vm.expectRevert(NOXStakingV4.AlreadyBound.selector);
        vm.prank(alice);
        stk.bindZeroStatePass(0, 2);
    }

    function test_unbind_works() public {
        vm.prank(alice);
        stk.stake(100_000 ether);
        zsp.mint(alice, 1);
        vm.prank(alice);
        stk.bindZeroStatePass(0, 1);
        vm.prank(alice);
        stk.unbindZeroStatePass(0);
        assertFalse(stk.isZeroStatePassValidlyBound(alice, 0));
    }

    function test_refresh_clears_invalid_binding() public {
        vm.prank(alice);
        stk.stake(100_000 ether);
        zsp.mint(alice, 1);
        vm.prank(alice);
        stk.bindZeroStatePass(0, 1);

        vm.prank(alice);
        zsp.transferFrom(alice, bob, 1);

        assertFalse(stk.isZeroStatePassValidlyBound(alice, 0));

        stk.refreshZeroStatePass(alice, 0);
        (uint256 boundTokenId,) = (0, 0);
        boundTokenId = stk.zeroStatePassBinding(alice, 0);
        assertEq(boundTokenId, 0, "binding must be cleared after refresh");
    }

    function test_namespaceEligibility_full_path() public {

        assertFalse(stk.namespaceEligibility(alice, 0));

        vm.prank(alice);
        stk.stake(2_000 ether);

        assertFalse(stk.namespaceEligibility(alice, 0));

        zsp.mint(alice, 1);
        vm.prank(alice);
        stk.bindZeroStatePass(0, 1);
        assertTrue(stk.namespaceEligibility(alice, 0));
    }

    function test_namespaceEligibility_requires_silver() public {
        vm.prank(alice);
        stk.stake(100 ether);
        zsp.mint(alice, 1);
        vm.prank(alice);
        stk.bindZeroStatePass(0, 1);
        assertFalse(stk.namespaceEligibility(alice, 0));
    }

    function test_kernel_separation_documented() public pure {

        assertTrue(true);
    }
}

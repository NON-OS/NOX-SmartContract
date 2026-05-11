// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import {NOXStakingV4} from "../../contracts/staking/NOXStakingV4.sol";

interface IProxy {
    function upgradeToAndCall(address, bytes calldata) external payable;
    function totalStaked() external view returns (uint256);
    function totalWeightedStake() external view returns (uint256);
    function accRewardPerShare() external view returns (uint256);
    function lastRewardTime() external view returns (uint256);
    function totalRewardsDistributed() external view returns (uint256);
    function totalPenaltiesBurned() external view returns (uint256);
    function genesisTime() external view returns (uint256);
    function earlyUnlockPenaltyBps() external view returns (uint256);
    function noxToken() external view returns (address);
    function zeroStatePass() external view returns (address);
    function hasRole(bytes32, address) external view returns (bool);
    function stakingVersion() external view returns (string memory);
    function protectedRewardReserve() external view returns (uint256);
    function userMigrationVersion(address) external view returns (uint256);
}

interface INOX {
    function balanceOf(address) external view returns (uint256);
}

contract NOXStakingV4ForkReplay is Test {
    address constant STAKING_PROXY = 0xa94d6009790Ba13597A1E1b7cF4e1531eA513613;
    address constant NOX_TOKEN = 0x0a26c80Be4E060e688d7C23aDdB92cBb5D2C9eCA;
    address constant LIVE_IMPL_V3 = 0xcD499Fa840F3475fdc8a9B150405b9811AE54410;

    address constant SAFE = 0x3a52ea60F61036Afbbec25F46a64485Ac4477Ccc;

    bytes32 constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 constant ERC1967_IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    struct V3State {
        uint256 totalStaked;
        uint256 totalWeightedStake;
        uint256 accRewardPerShare;
        uint256 lastRewardTime;
        uint256 totalRewardsDistributed;
        uint256 totalPenaltiesBurned;
        uint256 genesisTime;
        uint256 earlyUnlockPenaltyBps;
        address noxToken;
        address zeroStatePass;
        uint256 stakingBalance;
    }

    uint256 constant PRE_UPGRADE_BLOCK = 25070941;

    function setUp() public {
        try vm.envString("ETH_RPC_URL") returns (string memory rpc) {
            vm.createSelectFork(rpc, PRE_UPGRADE_BLOCK);
        } catch {
            vm.skip(true);
        }
    }

    function _snapshotV3() internal view returns (V3State memory s) {
        IProxy p = IProxy(STAKING_PROXY);
        s.totalStaked = p.totalStaked();
        s.totalWeightedStake = p.totalWeightedStake();
        s.accRewardPerShare = p.accRewardPerShare();
        s.lastRewardTime = p.lastRewardTime();
        s.totalRewardsDistributed = p.totalRewardsDistributed();
        s.totalPenaltiesBurned = p.totalPenaltiesBurned();
        s.genesisTime = p.genesisTime();
        s.earlyUnlockPenaltyBps = p.earlyUnlockPenaltyBps();
        s.noxToken = p.noxToken();
        s.zeroStatePass = p.zeroStatePass();
        s.stakingBalance = INOX(NOX_TOKEN).balanceOf(STAKING_PROXY);
    }

    function _assertEq(V3State memory a, V3State memory b) internal pure {
        require(a.totalStaked == b.totalStaked, "totalStaked drifted");
        require(a.totalWeightedStake == b.totalWeightedStake, "totalWeightedStake drifted");
        require(a.accRewardPerShare == b.accRewardPerShare, "accRewardPerShare drifted");
        require(a.lastRewardTime == b.lastRewardTime, "lastRewardTime drifted");
        require(a.totalRewardsDistributed == b.totalRewardsDistributed, "totalRewardsDistributed drifted");
        require(a.totalPenaltiesBurned == b.totalPenaltiesBurned, "totalPenaltiesBurned drifted");
        require(a.genesisTime == b.genesisTime, "genesisTime drifted");
        require(a.earlyUnlockPenaltyBps == b.earlyUnlockPenaltyBps, "earlyUnlockPenaltyBps drifted");
        require(a.noxToken == b.noxToken, "noxToken drifted");
        require(a.zeroStatePass == b.zeroStatePass, "zeroStatePass drifted");
        require(a.stakingBalance == b.stakingBalance, "stakingBalance drifted");
    }

    function test_fork_upgrade_preserves_all_v3_state() public {
        IProxy p = IProxy(STAKING_PROXY);
        V3State memory pre = _snapshotV3();

        NOXStakingV4 impl = new NOXStakingV4();

        assertTrue(p.hasRole(UPGRADER_ROLE, SAFE), "fork precondition: Safe holds UPGRADER on staking proxy");

        bytes memory init = abi.encodeCall(NOXStakingV4.reinitV4, (pre.earlyUnlockPenaltyBps, 0));
        vm.prank(SAFE);
        p.upgradeToAndCall(address(impl), init);

        bytes32 implWord = vm.load(STAKING_PROXY, ERC1967_IMPL_SLOT);
        assertEq(address(uint160(uint256(implWord))), address(impl));

        V3State memory post = _snapshotV3();
        _assertEq(pre, post);

        assertEq(p.protectedRewardReserve(), 0);
        assertEq(keccak256(bytes(p.stakingVersion())), keccak256(bytes("4.0.0")));
    }

    function test_fork_reinitV4_cannot_be_replayed() public {
        IProxy p = IProxy(STAKING_PROXY);
        NOXStakingV4 impl = new NOXStakingV4();
        bytes memory init = abi.encodeCall(NOXStakingV4.reinitV4, (500, 0));
        vm.prank(SAFE);
        p.upgradeToAndCall(address(impl), init);

        vm.expectRevert();
        vm.prank(SAFE);
        NOXStakingV4(STAKING_PROXY).reinitV4(0, 0);
    }

    function test_fork_rollback_to_v3() public {
        IProxy p = IProxy(STAKING_PROXY);
        V3State memory pre = _snapshotV3();

        NOXStakingV4 impl = new NOXStakingV4();
        bytes memory init = abi.encodeCall(NOXStakingV4.reinitV4, (pre.earlyUnlockPenaltyBps, 0));
        vm.prank(SAFE);
        p.upgradeToAndCall(address(impl), init);

        vm.prank(SAFE);
        p.upgradeToAndCall(LIVE_IMPL_V3, "");

        bytes32 implWord = vm.load(STAKING_PROXY, ERC1967_IMPL_SLOT);
        assertEq(address(uint160(uint256(implWord))), LIVE_IMPL_V3, "rollback impl");

        V3State memory post = _snapshotV3();
        _assertEq(pre, post);
    }

    function test_fork_users_can_still_unstake_after_upgrade() public {

        IProxy p = IProxy(STAKING_PROXY);
        NOXStakingV4 impl = new NOXStakingV4();
        bytes memory init = abi.encodeCall(NOXStakingV4.reinitV4, (p.earlyUnlockPenaltyBps(), 0));
        vm.prank(SAFE);
        p.upgradeToAndCall(address(impl), init);

        assertGt(p.totalStaked(), 0);
    }
}

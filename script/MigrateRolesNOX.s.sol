// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Script.sol";

interface IAccessControl {
    function grantRole(bytes32, address) external;
    function revokeRole(bytes32, address) external;
    function renounceRole(bytes32, address) external;
    function hasRole(bytes32, address) external view returns (bool);
}

contract MigrateRolesNOX is Script {
    address constant PROXY = 0x0a26c80Be4E060e688d7C23aDdB92cBb5D2C9eCA;
    address constant EOA = 0xa12eCf0CDfC9D53FFafbdef43696cE615E662B33;

    bytes32 constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 constant GOVERNOR_ROLE = 0x7935bd0ae54bc31f548c14dba4d37c5c64b3f8ca900cb468fb8abd54d5894f55;
    bytes32 constant UPGRADER_ROLE = 0x189ab7a9244df0848122154315af71fe140f3db0fe014031783b0946b8c9d2e3;
    bytes32 constant EMERGENCY_ROLE = 0xbf233dd2aafeb4d50879c4aa5c81e96d92f6e6945c906a58f9f2d1c1631b4b26;

    function run() external view {
        address ms = vm.envAddress("NOX_MULTISIG_ADDRESS");
        require(ms != address(0), "NOX_MULTISIG_ADDRESS must be set");

        console2.log("============================================================");
        console2.log("STAGE 1 -- GRANT ROLES TO MULTISIG (sign each from EOA)");
        console2.log("============================================================");
        _printGrant(DEFAULT_ADMIN_ROLE, ms, "grantRole(DEFAULT_ADMIN_ROLE, multisig)");
        _printGrant(GOVERNOR_ROLE, ms, "grantRole(GOVERNOR_ROLE, multisig)");
        _printGrant(UPGRADER_ROLE, ms, "grantRole(UPGRADER_ROLE, multisig)");
        _printGrant(EMERGENCY_ROLE, ms, "grantRole(EMERGENCY_ROLE, multisig)");

        console2.log("");
        console2.log("============================================================");
        console2.log("STAGE 2 -- VERIFY (read-only)");
        console2.log("============================================================");
        IAccessControl p = IAccessControl(PROXY);
        console2.log("hasRole(ADMIN,     ms) ", p.hasRole(DEFAULT_ADMIN_ROLE, ms));
        console2.log("hasRole(GOVERNOR,  ms) ", p.hasRole(GOVERNOR_ROLE, ms));
        console2.log("hasRole(UPGRADER,  ms) ", p.hasRole(UPGRADER_ROLE, ms));
        console2.log("hasRole(EMERGENCY, ms) ", p.hasRole(EMERGENCY_ROLE, ms));
        console2.log("All four MUST be 'true' before continuing.");

        console2.log("");
        console2.log("============================================================");
        console2.log("STAGE 3 -- SAFE GOVERNANCE SMOKE TEST");
        console2.log("============================================================");
        console2.log("Through the Safe UI, sign+execute a harmless governance call:");
        console2.log("  to:   ", PROXY);
        bytes memory smoke = abi.encodeWithSignature("setBlacklist(address,bool)", address(0xdEaD), true);
        console2.log("  data: setBlacklist(0xdEaD, true)");
        console2.logBytes(smoke);
        bytes memory unset = abi.encodeWithSignature("setBlacklist(address,bool)", address(0xdEaD), false);
        console2.log("  then: setBlacklist(0xdEaD, false)");
        console2.logBytes(unset);

        console2.log("");
        console2.log("============================================================");
        console2.log("STAGE 4 -- RENOUNCE EOA ROLES (sign from EOA; admin LAST)");
        console2.log("============================================================");
        _printRenounce(UPGRADER_ROLE, EOA, "renounceRole(UPGRADER_ROLE, EOA)");
        _printRenounce(EMERGENCY_ROLE, EOA, "renounceRole(EMERGENCY_ROLE, EOA)");
        _printRenounce(GOVERNOR_ROLE, EOA, "renounceRole(GOVERNOR_ROLE, EOA)");
        _printRenounce(DEFAULT_ADMIN_ROLE, EOA, "renounceRole(DEFAULT_ADMIN_ROLE, EOA)  // LAST");

        console2.log("");
        console2.log("============================================================");
        console2.log("STAGE 5 -- FINAL VERIFY");
        console2.log("============================================================");
        console2.log("All four hasRole(*, EOA) must return false.");
    }

    function _printGrant(bytes32 role, address to, string memory label) internal pure {
        bytes memory cd = abi.encodeWithSelector(IAccessControl.grantRole.selector, role, to);
        console2.log(label);
        console2.log("  to:  ", PROXY);
        console2.log("  data:");
        console2.logBytes(cd);
    }

    function _printRenounce(bytes32 role, address who, string memory label) internal pure {
        bytes memory cd = abi.encodeWithSelector(IAccessControl.renounceRole.selector, role, who);
        console2.log(label);
        console2.log("  to:  ", PROXY);
        console2.log("  data:");
        console2.logBytes(cd);
    }
}

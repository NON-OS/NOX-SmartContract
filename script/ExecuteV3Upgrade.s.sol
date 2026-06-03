// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Script.sol";

interface ISafe {
    function nonce() external view returns (uint256);
    function getThreshold() external view returns (uint256);
    function getTransactionHash(
        address to, uint256 value, bytes calldata data, uint8 operation,
        uint256 safeTxGas, uint256 baseGas, uint256 gasPrice,
        address gasToken, address refundReceiver, uint256 _nonce
    ) external view returns (bytes32);
    function execTransaction(
        address to, uint256 value, bytes calldata data, uint8 operation,
        uint256 safeTxGas, uint256 baseGas, uint256 gasPrice,
        address gasToken, address payable refundReceiver, bytes calldata signatures
    ) external payable returns (bool);
}

interface IProxy { function upgradeToAndCall(address newImplementation, bytes calldata data) external payable; }

interface INOX {
    function setFees(uint16, uint16, uint16, uint16, uint16, uint16, uint16) external;
    function setAutoSwapConfig(uint256, uint16, bool) external;
    function setMaxAutoSwapChunk(uint256) external;
    function fees() external view returns (uint16, uint16, uint16, uint16, uint16, uint16, uint16);
    function noxVersion() external view returns (string memory);
}

/// 4-step NOX V3 upgrade ceremony via the 3-of-5 Safe:
///   1. upgradeToAndCall(V3_IMPL, "")         (UPGRADER_ROLE)
///   2. setFees(0, 300, 0, 1000, 9000, 0, 0)  (GOVERNOR_ROLE) buy0 sell3 burn10 liq90
///   3. setMaxAutoSwapChunk(500_000e18)        (GOVERNOR_ROLE)
///   4. setAutoSwapConfig(50_000e18, 300, true)(GOVERNOR_ROLE)
/// Dry-run by default; EXECUTE=true to broadcast.
contract ExecuteV3Upgrade is Script {
    address constant SAFE  = 0x3a52ea60F61036Afbbec25F46a64485Ac4477Ccc;
    address constant PROXY = 0x0a26c80Be4E060e688d7C23aDdB92cBb5D2C9eCA;

    function _loadKeys() internal view returns (uint256[3] memory ks, address[3] memory as_) {
        ks[0] = vm.envUint("NOX_SAFE_SIGNER_1_OWNER_PRIVATE_KEY");
        ks[1] = vm.envUint("NOX_SAFE_SIGNER_2_SECURITY_PRIVATE_KEY");
        ks[2] = vm.envUint("NOX_SAFE_SIGNER_3_TREASURY_PRIVATE_KEY");
        as_[0] = vm.addr(ks[0]); as_[1] = vm.addr(ks[1]); as_[2] = vm.addr(ks[2]);
        for (uint i; i < 3; i++) for (uint j = i+1; j < 3; j++) if (as_[j] < as_[i]) {
            (as_[i], as_[j]) = (as_[j], as_[i]); (ks[i], ks[j]) = (ks[j], ks[i]);
        }
    }
    function _sig(uint256 k, bytes32 h) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(k, h); return abi.encodePacked(r, s, v);
    }
    function _packSigs(bytes32 h, uint256[3] memory ks) internal pure returns (bytes memory) {
        return bytes.concat(_sig(ks[0], h), _sig(ks[1], h), _sig(ks[2], h));
    }
    function _hash(bytes memory data, uint256 n) internal view returns (bytes32) {
        return ISafe(SAFE).getTransactionHash(PROXY, 0, data, 0, 0, 0, 0, address(0), address(0), n);
    }
    function _exec(bytes memory data, bytes memory sigs) internal {
        require(ISafe(SAFE).execTransaction(PROXY, 0, data, 0, 0, 0, 0, address(0), payable(address(0)), sigs), "exec false");
    }

    function run() external {
        address impl = vm.envAddress("V3_IMPL");
        require(impl.code.length > 0, "V3_IMPL has no code");
        require(ISafe(SAFE).getThreshold() <= 3, "threshold>3");
        (uint256[3] memory ks,) = _loadKeys();
        bool execute = vm.envOr("EXECUTE", false);
        uint256 n = ISafe(SAFE).nonce();

        bytes memory upg  = abi.encodeCall(IProxy.upgradeToAndCall, (impl, ""));
        bytes memory fee  = abi.encodeCall(INOX.setFees, (0, 300, 0, 1000, 9000, 0, 0));
        bytes memory chunk = abi.encodeCall(INOX.setMaxAutoSwapChunk, (500_000 ether));
        bytes memory cfg  = abi.encodeCall(INOX.setAutoSwapConfig, (50_000 ether, 300, true));

        console2.log("=== NOX V3 UPGRADE CEREMONY ===");
        console2.log("Proxy:", PROXY);
        console2.log("V3 impl:", impl);
        console2.log("start nonce:", n);
        console2.log("tx0 upgrade hash:"); console2.logBytes32(_hash(upg, n));
        console2.log("tx1 setFees hash:"); console2.logBytes32(_hash(fee, n + 1));
        console2.log("tx2 maxChunk hash:"); console2.logBytes32(_hash(chunk, n + 2));
        console2.log("tx3 autoSwapCfg hash:"); console2.logBytes32(_hash(cfg, n + 3));

        if (!execute) { console2.log("EXECUTE=false (dry run)."); return; }

        vm.startBroadcast(ks[0]); _exec(upg, _packSigs(_hash(upg, n), ks)); vm.stopBroadcast();
        require(keccak256(bytes(INOX(PROXY).noxVersion())) == keccak256("NONOS_NOX_MAINNET_V3"), "not V3");
        console2.log("UPGRADE -> V3 done.");

        vm.startBroadcast(ks[0]); _exec(fee, _packSigs(_hash(fee, n + 1), ks)); vm.stopBroadcast();
        console2.log("setFees done.");
        vm.startBroadcast(ks[0]); _exec(chunk, _packSigs(_hash(chunk, n + 2), ks)); vm.stopBroadcast();
        console2.log("setMaxAutoSwapChunk done.");
        vm.startBroadcast(ks[0]); _exec(cfg, _packSigs(_hash(cfg, n + 3), ks)); vm.stopBroadcast();
        console2.log("setAutoSwapConfig done.");

        (uint16 b, uint16 s,,uint16 burnS, uint16 liqS,,) = INOX(PROXY).fees();
        require(b == 0 && s == 300 && burnS == 1000 && liqS == 9000, "fees not applied");
        console2.log("=== V3 LIVE: buy 0% / sell 3% / burn 10% / liq 90%. ===");
    }
}

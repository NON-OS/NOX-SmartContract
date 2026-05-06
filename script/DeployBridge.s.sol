// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../contracts/bridge/NOXBridge.sol";

contract DeployBridge is Script {
    address constant FEE_COLLECTOR = 0x2794B7535708029c1405C60f56df57144e5c53C0;
    address constant ADMIN = 0xa12eCf0CDfC9D53FFafbdef43696cE615E662B33;
    uint256 constant DAILY_LIMIT = 1_000_000 * 1e18;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        NOXBridge bridgeImpl = new NOXBridge();

        bytes memory initData = abi.encodeWithSelector(
            NOXBridge.initialize.selector,
            FEE_COLLECTOR,
            address(0),
            DAILY_LIMIT,
            ADMIN
        );

        ERC1967Proxy bridgeProxy = new ERC1967Proxy(
            address(bridgeImpl),
            initData
        );

        console.log("NOXBridge Implementation:", address(bridgeImpl));
        console.log("NOXBridge Proxy:", address(bridgeProxy));

        vm.stopBroadcast();
    }
}

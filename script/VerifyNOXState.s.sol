// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Script.sol";

interface INOX {
    function totalSupply() external view returns (uint256);
    function totalBurned() external view returns (uint256);
    function uniswapPair() external view returns (address);
    function uniswapRouter() external view returns (address);
    function autoSwapThreshold() external view returns (uint256);
    function autoSwapSlippageBps() external view returns (uint16);
    function autoSwapEnabled() external view returns (bool);
    function v2Initialized() external view returns (bool);
    function isPair(address) external view returns (bool);
    function feeExempt(address) external view returns (bool);
    function limitsExempt(address) external view returns (bool);
    function hasRole(bytes32, address) external view returns (bool);
    function maxAutoSwapChunk() external view returns (uint256);
    function ethFallbackRecipient() external view returns (address);
    function totalFailedEth() external view returns (uint256);
    function fees() external view returns (uint16, uint16, uint16, uint16, uint16, uint16, uint16);
}

contract VerifyNOXState is Script {
    address constant PROXY = 0x0a26c80Be4E060e688d7C23aDdB92cBb5D2C9eCA;
    address constant EOA = 0xa12eCf0CDfC9D53FFafbdef43696cE615E662B33;
    address constant PAIR = 0x07CE5889D2EB681Af3bD61db24Ab2602c502Bd1B;

    bytes32 constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 constant GOVERNOR_ROLE = 0x7935bd0ae54bc31f548c14dba4d37c5c64b3f8ca900cb468fb8abd54d5894f55;
    bytes32 constant UPGRADER_ROLE = 0x189ab7a9244df0848122154315af71fe140f3db0fe014031783b0946b8c9d2e3;
    bytes32 constant EMERGENCY_ROLE = 0xbf233dd2aafeb4d50879c4aa5c81e96d92f6e6945c906a58f9f2d1c1631b4b26;
    bytes32 constant ERC1967_IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    function run() external view {
        INOX p = INOX(PROXY);
        console2.log("=== NOX state @", PROXY, "===");
        console2.log("totalSupply        ", p.totalSupply());
        console2.log("totalBurned        ", p.totalBurned());
        console2.log("uniswapPair        ", p.uniswapPair());
        console2.log("uniswapRouter      ", p.uniswapRouter());
        console2.log("autoSwapThreshold  ", p.autoSwapThreshold());
        console2.log("autoSwapSlippageBps", p.autoSwapSlippageBps());
        console2.log("autoSwapEnabled    ", p.autoSwapEnabled());
        console2.log("v2Initialized      ", p.v2Initialized());
        console2.log("isPair(pair)       ", p.isPair(PAIR));
        console2.log("feeExempt(pair)    ", p.feeExempt(PAIR));
        console2.log("limitsExempt(pair) ", p.limitsExempt(PAIR));

        (uint16 buy, uint16 sell, uint16 transfer_, uint16 bShare, uint16 lShare, uint16 tShare, uint16 dShare) =
            p.fees();
        console2.log("fees.buyBps        ", buy);
        console2.log("fees.sellBps       ", sell);
        console2.log("fees.transferBps   ", transfer_);
        console2.log("fees.burnShareBps  ", bShare);
        console2.log("fees.liqShareBps   ", lShare);
        console2.log("fees.treShareBps   ", tShare);
        console2.log("fees.devShareBps   ", dShare);

        console2.log("hasRole ADMIN     EOA", p.hasRole(DEFAULT_ADMIN_ROLE, EOA));
        console2.log("hasRole GOVERNOR  EOA", p.hasRole(GOVERNOR_ROLE, EOA));
        console2.log("hasRole UPGRADER  EOA", p.hasRole(UPGRADER_ROLE, EOA));
        console2.log("hasRole EMERGENCY EOA", p.hasRole(EMERGENCY_ROLE, EOA));

        try p.maxAutoSwapChunk() returns (uint256 v) {
            console2.log("maxAutoSwapChunk    ", v);
        } catch {
            console2.log("maxAutoSwapChunk     <not present>");
        }
        try p.ethFallbackRecipient() returns (address v) {
            console2.log("ethFallbackRecipient", v);
        } catch {
            console2.log("ethFallbackRecipient <not present>");
        }
        try p.totalFailedEth() returns (uint256 v) {
            console2.log("totalFailedEth      ", v);
        } catch {
            console2.log("totalFailedEth       <not present>");
        }

        bytes32 implWord = vm.load(PROXY, ERC1967_IMPL_SLOT);
        console2.log("ERC1967 impl slot  ", address(uint160(uint256(implWord))));
    }
}

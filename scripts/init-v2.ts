import { ethers } from "hardhat";

const PROXY = "0x0a26c80Be4E060e688d7C23aDdB92cBb5D2C9eCA";
const ROUTER = "0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D";
const THRESHOLD = "1000000000000000000000"; // 1000 NOX
const SLIPPAGE = 100; // 1%

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Initializing V2 with:", deployer.address);

  const abi = [
    "function initializeV2(address _router, uint256 _swapThreshold, uint16 _slippageBps) external",
    "function v2Initialized() view returns (bool)",
    "function autoSwapEnabled() view returns (bool)",
    "function uniswapRouter() view returns (address)",
    "function autoSwapThreshold() view returns (uint256)",
  ];

  const proxy = new ethers.Contract(PROXY, abi, deployer);

  const alreadyInit = await proxy.v2Initialized();
  if (alreadyInit) {
    console.log("V2 already initialized!");
    return;
  }

  console.log("Calling initializeV2...");
  console.log("  Router:", ROUTER);
  console.log("  Threshold:", THRESHOLD, "(1000 NOX)");
  console.log("  Slippage:", SLIPPAGE, "bps (1%)");

  const tx = await proxy.initializeV2(ROUTER, THRESHOLD, SLIPPAGE, { gasLimit: 300000 });
  console.log("Tx hash:", tx.hash);

  await tx.wait();

  console.log("\n✅ V2 Initialized!");
  console.log("  autoSwapEnabled:", await proxy.autoSwapEnabled());
  console.log("  uniswapRouter:", await proxy.uniswapRouter());
  console.log("  autoSwapThreshold:", ethers.formatEther(await proxy.autoSwapThreshold()), "NOX");
}

main().catch((e) => { console.error(e); process.exit(1); });

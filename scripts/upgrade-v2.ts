import { ethers } from "hardhat";

const PROXY = "0x0a26c80Be4E060e688d7C23aDdB92cBb5D2C9eCA";
const NEW_IMPL = "0xf57a30672a72fa7fbc8004ffcb12dafc7ea882d7";

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Upgrading with:", deployer.address);

  const abi = [
    "function upgradeToAndCall(address newImplementation, bytes memory data) external",
  ];

  const proxy = new ethers.Contract(PROXY, abi, deployer);

  console.log("Calling upgradeToAndCall...");
  const tx = await proxy.upgradeToAndCall(NEW_IMPL, "0x", { gasLimit: 200000 });
  console.log("Tx hash:", tx.hash);

  const receipt = await tx.wait();
  console.log("Upgrade confirmed in block:", receipt?.blockNumber);
  console.log("\n✅ Proxy upgraded to V2!");
}

main().catch((e) => { console.error(e); process.exit(1); });

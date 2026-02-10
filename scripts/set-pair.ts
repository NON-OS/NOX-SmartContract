import { ethers } from "hardhat";

const PROXY = "0x0a26c80Be4E060e688d7C23aDdB92cBb5D2C9eCA";
const LP_PAIR = "0x07ce5889d2eb681af3bd61db24ab2602c502bd1b";

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Setting LP pair with:", deployer.address);

  const abi = [
    "function setPair(address pair, bool status) external",
    "function isPair(address) view returns (bool)",
  ];

  const proxy = new ethers.Contract(PROXY, abi, deployer);

  const before = await proxy.isPair(LP_PAIR);
  console.log("isPair before:", before);

  if (before) {
    console.log("Pair already registered!");
    return;
  }

  console.log("Calling setPair...");
  const tx = await proxy.setPair(LP_PAIR, true, { gasLimit: 100000 });
  console.log("Tx hash:", tx.hash);

  await tx.wait();

  const after = await proxy.isPair(LP_PAIR);
  console.log("\n✅ isPair after:", after);
}

main().catch((e) => { console.error(e); process.exit(1); });

import { ethers } from "hardhat";
import * as fs from "fs";

async function main() {
  console.log("Deploying V2 with raw transaction (bypassing gas estimation)...\n");

  const [deployer] = await ethers.getSigners();
  console.log("Deployer:", deployer.address);

  const balance = await ethers.provider.getBalance(deployer.address);
  console.log("Balance:", ethers.formatEther(balance), "ETH\n");

  // Get bytecode from forge build
  const artifact = JSON.parse(fs.readFileSync("out/noxtoken_v2.sol/NONOS_NOX_MAINNET_V2.json", "utf8"));
  const bytecode = artifact.bytecode.object;

  console.log("Bytecode length:", bytecode.length / 2 - 1, "bytes");

  // Create deployment transaction with manual gas
  const tx = {
    data: bytecode,
    gasLimit: 8000000, // Manual gas limit
    type: 0, // Legacy transaction
  };

  console.log("\nSending deployment transaction...");
  const response = await deployer.sendTransaction(tx);
  console.log("Tx hash:", response.hash);

  console.log("Waiting for confirmation...");
  const receipt = await response.wait();

  console.log("\n✅ V2 Implementation deployed at:", receipt?.contractAddress);
  console.log("\nVerify with:");
  console.log(`npx hardhat verify --network mainnet ${receipt?.contractAddress}`);
}

main().catch((e) => { console.error(e); process.exit(1); });

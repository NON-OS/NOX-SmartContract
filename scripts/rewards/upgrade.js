const { ethers, upgrades } = require("hardhat");

const PROXY_ADDRESS = "0xAcb70B0F83f676ef17abEA09101B9797b6bCF95f";

async function main() {
    const [deployer] = await ethers.getSigners();
    console.log("Upgrading with:", deployer.address);

    const currentImpl = await upgrades.erc1967.getImplementationAddress(PROXY_ADDRESS);
    console.log("Current implementation:", currentImpl);

    const NOXRewardsV2 = await ethers.getContractFactory("NOXRewardsV2");
    try {
        await upgrades.forceImport(PROXY_ADDRESS, NOXRewardsV2, { kind: "uups" });
    } catch (e) {}

    const NOXRewardsV3 = await ethers.getContractFactory("NOXRewardsV3");
    const upgraded = await upgrades.upgradeProxy(PROXY_ADDRESS, NOXRewardsV3, {
        unsafeAllow: ["constructor"]
    });
    await upgraded.waitForDeployment();

    const newImpl = await upgrades.erc1967.getImplementationAddress(PROXY_ADDRESS);
    console.log("New implementation:", newImpl);
    console.log("Version:", await upgraded.version());
}

main().catch(console.error);

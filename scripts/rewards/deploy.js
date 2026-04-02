const { ethers, upgrades } = require("hardhat");

const NOX_TOKEN = "0x0a26c80Be4E060e688d7C23aDdB92cBb5D2C9eCA";
const SIGNER = "0xa12eCf0CDfC9D53FFafbdef43696cE615E662B33";
const OWNER = "0xa12eCf0CDfC9D53FFafbdef43696cE615E662B33";

async function main() {
    console.log("Deploying NOXRewardsV3...");

    const NOXRewardsV3 = await ethers.getContractFactory("NOXRewardsV3");
    const proxy = await upgrades.deployProxy(NOXRewardsV3, [NOX_TOKEN, SIGNER, OWNER], {
        kind: "uups",
        unsafeAllow: ["constructor"]
    });
    await proxy.waitForDeployment();

    const proxyAddress = await proxy.getAddress();
    const implAddress = await upgrades.erc1967.getImplementationAddress(proxyAddress);

    console.log("Proxy:", proxyAddress);
    console.log("Implementation:", implAddress);
    console.log("Version:", await proxy.version());
}

main().catch(console.error);

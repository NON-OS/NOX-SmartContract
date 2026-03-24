const { ethers, upgrades } = require("hardhat");

const NOX_TOKEN = "0x0a26c80Be4E060e688d7C23aDdB92cBb5D2C9eCA";
const ZSP_NFT = "0x7b575DD8e8b111c52Ab1e872924d4Efd4DF403df";

async function main() {
    const [deployer] = await ethers.getSigners();

    console.log("Deployer:", deployer.address);

    const balance = await ethers.provider.getBalance(deployer.address);
    console.log("Balance:", ethers.formatEther(balance), "ETH");

    const NOXStaking = await ethers.getContractFactory("NOXStaking");

    const proxy = await upgrades.deployProxy(
        NOXStaking,
        [NOX_TOKEN, ZSP_NFT, deployer.address],
        {
            initializer: "initialize",
            kind: "uups",
        }
    );

    await proxy.waitForDeployment();
    const proxyAddress = await proxy.getAddress();
    const implAddress = await upgrades.erc1967.getImplementationAddress(proxyAddress);

    console.log("Proxy:", proxyAddress);
    console.log("Implementation:", implAddress);

    const genesisTime = Math.floor(Date.now() / 1000);
    const tx = await proxy.setGenesisTime(genesisTime);
    await tx.wait();
    console.log("Genesis:", genesisTime);

    return proxyAddress;
}

main()
    .then(() => process.exit(0))
    .catch(error => {
        console.error(error);
        process.exit(1);
    });

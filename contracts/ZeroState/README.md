# ZeroState
# NOX TOKEN & NFT REWARD SYSTEM  
Version 1 — Technical Specification Update (October 2025)

---

## 1. Overview

The NOX ecosystem is an on-chain architecture that links transactional activity with automated, epoch-based reward distribution for NFT holders.

Core elements:

- **NOX (ERC-20)** — utility token with a 2 % transaction tax mechanism.  
- **NFT Collection (ERC-721)** — 374 supply; holders receive revenue share and utility privileges.  
- **RewardVault (Contract)** — handles automated 30-day epoch distributions.  
- **TaxCollector (Contract)** — routes tax flows to destinations including rewards, liquidity, development, and treasury.  

The automated contracts will be deployed and activated **beginning next month**.  
**This month represents the final manual revenue share distribution** to NFT holders before the on-chain automation process begins.

## 2. Token Parameters

| Parameter | Value | Description |
|------------|--------|-------------|
| Symbol | NOX | ERC-20 token |
| Total Supply | 800,000,000 | Fixed, non-mintable |
| Genesis NFT Allocation | 1.5 % = 12,000,000 NOX | Reserved for NFT-linked rewards |
| Currently Released | 0.3 % = 2,400,000 NOX | Circulating portion |
| Locked Genesis Reserve | 1.2 % = 9,600,000 NOX | Scheduled for controlled release |
| Transaction Tax | 2 % | Applies to every transfer |
| Token Price | $0.01 | Current average |
| Market Cap | $7.3 M | Current total |
| Monthly Trading Volume | $2 M | Average for current period |
| NFTs Minted | 112 / 374 | Active holders currently 112 |


## 3. Tax Distribution Model

Each transaction routes a 2 % tax according to the following structure:

| Destination | % of Tax | % of Volume | Description |
|--------------|-----------|--------------|-------------|
| NFT Buybacks / Rewards | 40 % | 0.8 % | Deposited to RewardVault for NFT holders |
| Liquidity Pool | 30 % | 0.6 % | Added to liquidity pairs for stability |
| Development Fund | 20 % | 0.4 % | Ecosystem operations, marketing, and tooling |
| Treasury Reserve | 10 % | 0.2 % | Long-term reserve and emergency fund |

At a $2 M monthly volume, this yields approximately **$40,000 in total tax flow**.

## 4. Genesis Allocation Integration

The Genesis allocation (1.5 % = 12 M NOX) supports early liquidity and adoption:

1. **Initial Release:** 2.4 M NOX (0.3 %) used to bootstrap liquidity and early reward epochs.  
2. **Liquidity Enhancement:** NFT sales increased liquidity reserves by **10 ETH**, providing stronger depth and price stability in early markets.  
3. **Remaining Genesis Tokens:** 9.6 M NOX (1.2 %) to be used for scheduled reward boosts and incentive releases tied to NFT mint progression.

Genesis funds act as transitional support between manual and automated reward systems.

## 5. NFT Reward Distribution

### 5.1 Manual Phase (Current Month)

- Rewards for this cycle are distributed manually.  
- Calculation follows existing parameters:

```
Volume = $2,000,000
Tax (2%) = $40,000
NFT Allocation (40%) = $16,000
Token Price = $0.01
$16,000 ÷ $0.01 = 1,600,000 NOX total
1,600,000 ÷ 112 NFTs = 14,285 NOX per NFT ≈ $142.85
```

This model concludes after the current epoch.  

### 5.2 Automated Phase (Effective Next Month)

Rewards will be handled by the **RewardVault contract**.  
Key functionality:

1. Receives 40 % of all transactional taxes automatically.  
2. Operates on **30-day epochs**.  
3. Snapshots NFT ownership at epoch close.  
4. Calculates and stores `rewardPerNFT = totalTokens / totalEligibleNFTs`.  
5. NFT holders claim via `claim(uint256 tokenId)`.  
6. Unclaimed rewards remain in the vault or return to the treasury after expiration.

This ensures continuous, transparent payouts without manual intervention.

---

## 6. Dynamic Reward Formula

```
NFT_Reward_Tokens = 0.0008 × (Monthly_Volume ÷ Token_Price)
```

| Volume | Token Price | Total Reward (NOX) | $ Value | NFTs (Sold) | $/NFT |
|---------|--------------|--------------------|----------|--------------|-------|
| 1 M | 0.01 | 800 000 | 8 000 | 112 | 71 |
| 2 M | 0.01 | 1 600 000 | 16 000 | 112 | 143 |
| 3 M | 0.01 | 2 400 000 | 24 000 | 112 | 214 |
| 2 M | 0.02 | 800 000 | 16 000 | 112 | 143 |

---

## 7. NFT Utility Layer

NFTs function as more than reward entitlements.  
Holders receive:

1. **Protocol Privileges**  
   - Governance access and voting rights.  
   - Access to restricted ecosystem interfaces and early releases.

2. **ZK-Circuit Participation**  
   - Optional integration for holders willing to participate in zero-knowledge circuit computation.  
   - Verified contributors receive additional performance-based rewards.

3. **Partner Airdrops**  
   - Eligibility for token or asset distributions from future NOX collaborations and external ecosystems.

4. **Tiered Access**  
   - Higher-tier NFTs or verified contributors may receive proportionally greater allocations.

---

## 8. Contract Interfaces

```solidity
interface ITaxCollector {
    function distributeTax(uint256 amount) external;
    // 40% -> RewardVault, 30% -> LP, 20% -> Dev, 10% -> Treasury
}

interface IRewardVault {
    function startEpoch(uint256 epochId, uint256 totalTokens) external;
    function finalizeEpoch(uint256 epochId) external;
    function claim(uint256 tokenId) external;
}

interface INFTCollection {
    function ownerOf(uint256 tokenId) external view returns (address);
    function totalSupply() external view returns (uint256);
}
```

## 9. Economic Flow

```
Transaction → 2% Tax → TaxCollector
    ├── 40% → RewardVault (NFT rewards)
    ├── 30% → LiquidityPool
    ├── 20% → Development Fund
    └── 10% → Treasury Reserve

RewardVault → Monthly Snapshot → Per-NFT Allocation → Claim()
```

The system scales with transaction volume, creating a closed reward loop backed by real economic activity.

## 10. Governance and Security

- Claim-based rewards prevent batch distribution gas exhaustion.
  
- Snapshot timing ensures correct mapping of NFT ownership.
  
- Administrative functions controlled by multisig:
  - Epoch configuration.
  - Reward parameter adjustments.
  - Recovery of unclaimed balances.

- Optional proxy deployment for upgradability.

## 11. Summary

| Aspect | Description |
|--------|-------------|
| Reward Source | Transaction tax (non-inflationary) |
| Distribution Cycle | 30 days |
| NFTs | 374 supply (112 active holders) |
| Reward Method | On-chain claim via RewardVault |
| Manual Distribution | Final cycle this month |
| Automated Distribution | Launches next month |
| Liquidity Support | Genesis release improved LP by 10 ETH |
| Utilities | Governance, ZK-Circuits, Partner Airdrops |
| Inflation Model | Fixed supply |
| Long-Term Objective | Sustainable yield with price stability |

## 12. Future Additions

- Adaptive emission curve (gradual decay).  
- NFT staking interface for optional lockup yields.
  
- Cross-chain extension for secondary networks.
  
- DAO migration for full community governance.

## 13. Core Principle

The NOX model links market activity with measurable on-chain yield, also usage options and community holders participation. The system transitions from a manually managed phase to a fully automated architecture that redistributes verifiable value to NFT holders while reinforcing liquidity and long-term token integrity.

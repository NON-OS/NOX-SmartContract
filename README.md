# NOX-SmartContract

Solidity source for everything NOX runs on Ethereum mainnet.

The repo is split by what each contract does, not by deployment order.

```
contracts/
  token/         NOX (ERC-20) and NOX staking
  nft/           ZeroState Pass NFT
  bridge/        NOX bridge to Cellframe Backbone
  marketplace/   capsule registry, app-bound launchpad, fee router,
                 entitlement, pay-per-use receipts, fee swap router
```

`token/`, `nft/`, and `bridge/` are already live. The marketplace contracts
shipped on 5 May 2026 and are still on a single-key admin until the Finalize
script runs against a Safe address.

## Live mainnet addresses

| Contract | Address | Status |
|---|---|---|
| NOX V2 (ERC-20) | `0x0a26c80Be4E060e688d7C23aDdB92cBb5D2C9eCA` | live |
| NOX Staking V3 | `0xa94d6009790Ba13597A1E1b7cF4e1531eA513613` | live |
| ZeroState Pass NFT | `0x7b575DD8e8b111c52Ab1e872924d4Efd4DF403df` | live |
| NOX Bridge | `0x70Fb00075879E7D9d87EA5536c6c374cc2d14435` | live |
| CapsuleRegistry (proxy) | `0xcabb848fac25af95068d64eb5501e689c88172a3` | live, single-key admin |
| AppTokenFactory (proxy) | `0xa248f486fd838b315883026197cda96387f9e7dc` | live, single-key admin |
| AppBondingToken (impl) | `0x06b6bb8f225e9c1c278f8a2b47fe768af9a7a4f8` | live, clone target |
| FeeRouter (proxy) | `0x0d0dd1d8d2940ed4c1cf05635722528def612559` | live, single-key admin |
| EntitlementRegistry (proxy) | `0xb821d04f1fd49851e3adc89505e10241f8a01a4c` | live, single-key admin |
| ReceiptSettlement (proxy) | `0x1b522b9d62986f4ad0e7e881bad464b6e7e37317` | live, single-key admin |
| FeeSwapRouter | not yet deployed | code + tests + Slither in this repo |

Full deploy artifacts and tx hashes are in [`deployments/`](deployments/).

## Layout

### `contracts/token/`

`NOXTokenV2.sol` — the live ERC-20 (`NONOS_NOX_MAINNET_V2`). Deflationary on
transfer with configurable buy / sell / transfer fee splits and burn share.
The fee config is locked once the deployer renounces ownership.

`NOXStakingV3.sol` — the live staking contract (`NOXStakingV3`). Lock
periods with boost multipliers, NFT holder bonus through ZeroState Pass,
reward pool funded by deposits. Lives behind a UUPS proxy. V3 supersedes V1
and V2 (deprecated, not in this repo).

### `contracts/nft/`

ZeroState Pass — verified-source NFT live at the address above. The source
is on Etherscan; not duplicated in this repo.

### `contracts/bridge/`

`NOXBridge.sol` — three-of-three validator multisig bridging NOX between
Ethereum and Cellframe Backbone. Burns happen on the source side, mints on
the destination side. Daily limits, fee in NOX, pause path, and explicit
status codes for stuck transactions (`AlreadyCompleted`, `Expired`, etc.).
The reverse direction is driven by an off-chain validator service that
watches Cellframe and submits signed unlock transactions.

`CellframeBridge.sol` and `ICellframeBridge.sol` describe the Cellframe-side
artifacts the validators expect. The actual Cellframe contract is not
Solidity; the file documents the wire format.

### `contracts/marketplace/`

The contract suite that publishes capsule apps for NØNOS OS, mints
app-bound bonding-curve tokens for them, gates access through entitlements,
and settles per-call receipts.

```
core/
  CapsuleRegistry.sol     publisher + capsule + release lifecycle
  AppTokenFactory.sol     deploys EIP-1167 AppBondingToken clones, bound to a release
  AppBondingToken.sol     per-app bonding curve, NOX as reserve, graduation to DEX

revenue/
  FeeRouter.sol           4-way revenue split, configurable per-source profile
  FeeSwapRouter.sol       atomic fee-on-input swap wrapper (allowlisted targets)
  FeeSwapErrors.sol
  FeeSwapEvents.sol
  IFeeSwapRouter.sol

entitlement/
  EntitlementRegistry.sol free / one-time / subscription / NFT / token gates
  ReceiptSettlement.sol   batched EIP-712 receipts for pay-per-use

libraries/
  BondingCurveLib.sol     pure-integer cubic curve, integer cube root with proof bound

interfaces/                 minimal ABI for every contract above
```

The capsule format itself, the marketplace index format, the validator
pipeline, and the OS-side installer are documented separately in the
companion repo and on the operator site.

## Build, test, deploy

This repo uses Foundry. Forge resolves the OpenZeppelin imports through
`node_modules/@openzeppelin/`. Standard pnpm/npm install brings them in.

```
forge build
forge test
forge test --match-path "test/revenue/feeSwap/*.t.sol"
```

The fee-swap fork tests need `MAINNET_RPC_URL` set; they swap real ETH↔NOX
on the live Uniswap V2 router and verify the protocol fee flow end-to-end.

```
export MAINNET_RPC_URL=https://...
forge test --match-path test/revenue/feeSwap/Fork.t.sol
```

Deploy scripts live in `script/`. Each one reads its config from environment
variables only; nothing is hardcoded.

```
DEPLOYER_PK=...                 deployer key, only used for gas
FINAL_DAO_SAFE=0x...            Safe address that owns admin + receives fees
FINAL_CONFIG_SAFE=0x...         optional, defaults to FINAL_DAO_SAFE
FINAL_PAUSER_SAFE=0x...         optional
FINAL_UPGRADE_SAFE=0x...        optional
FINAL_TREASURY_SAFE=0x...       optional, where the protocol fee lands
FEE_BPS=10                      optional, default 10 bps (1.00% hard cap)

forge script script/DeployFeeSwapRouter.s.sol \
    --rpc-url $MAINNET_RPC_URL --broadcast --verify
```

The same pattern applies to `DeployMarketplace.s.sol`, `DeployBridge.s.sol`,
and `FinalizeMarketplace.s.sol`. The scripts print every constructor argument
and proxy address to stdout so the broadcast file is easy to reconcile.

## Audit and review status

Internal review only. No external audit firm has been engaged yet. The
Slither output for `FeeSwapRouter` is checked in at
[`docs/security/SLITHER_FeeSwapRouter.md`](docs/security/SLITHER_FeeSwapRouter.md)
with a per-finding rationale.

The marketplace and revenue contracts have all-green Foundry test suites
under `test/`, including a real mainnet fork test for the swap router.

Until external audit and Finalize complete, treat the marketplace contracts
as having a single-key admin. The bridge has been operating without
incident since deployment but carries the same audit status.

## Contact

eKisNonos · `ekisano@proton.me`

Repo: <https://github.com/NON-OS/NOX-SmartContract>

## License

MIT.

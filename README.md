# NOX-SmartContract

Solidity source for everything NOX runs on Ethereum mainnet.

The repo is split by what each contract does, not by deployment order.

```
contracts/
  token/         NOX (ERC-20), NOX staking, namespace + access registries
  nft/           ZeroState Pass NFT
  bridge/        NOX bridge to Cellframe Backbone
  marketplace/   capsule registry, app-bound launchpad, fee router,
                 entitlement, pay-per-use receipts, fee swap router
```

## Audit entry points

| Document | Purpose |
|---|---|
| [`docs/REPRODUCIBILITY.md`](docs/REPRODUCIBILITY.md) | Foundry version, install commands, build, offline + fork test commands, pinned fork blocks |
| [`docs/TESTING.md`](docs/TESTING.md) | Every test suite with file paths, counts, and intent |
| [`docs/DEPLOYMENTS.md`](docs/DEPLOYMENTS.md) | Mainnet addresses, implementation addresses, tx hashes, block numbers |
| [`docs/CONTRACT_REFERENCE.md`](docs/CONTRACT_REFERENCE.md) | Per-contract surface reference |
| [`docs/OS_BOUNDARY.md`](docs/OS_BOUNDARY.md) | Architectural rule: staking grants ecosystem identity only; kernel authority is not token-gated |

## Live mainnet addresses

| Contract | Address | Status |
|---|---|---|
| NOX token (proxy) | `0x0a26c80Be4E060e688d7C23aDdB92cBb5D2C9eCA` | live |
| NOX V2.1 implementation | `0xBf0415ebFC762B4166e198736a15Ff0B53744e43` | live, Safe-governed |
| NOX Staking (proxy) | `0xa94d6009790Ba13597A1E1b7cF4e1531eA513613` | live |
| NOX Staking V4 implementation | `0x415790B1f0aecd18B24D53BEaa25597573375B63` | live, Safe-governed |
| NOXNamespaceRegistry | `0xD554ae30A0D20CB988c40d6C3b3d907740B9FD5C` | live |
| NOXAccessRegistry | `0x31140F839E2BB03C903ca894A87DF40c7333d38b` | live, Safe-admin |
| Safe (3-of-5) | `0x3a52ea60F61036Afbbec25F46a64485Ac4477Ccc` | governor / upgrader on token and staking |
| ZeroState Pass NFT | `0x7b575DD8e8b111c52Ab1e872924d4Efd4DF403df` | live |
| NOX Bridge | `0x70Fb00075879E7D9d87EA5536c6c374cc2d14435` | live |
| CapsuleRegistry (proxy) | `0xcabb848fac25af95068d64eb5501e689c88172a3` | live, single-key admin |
| AppTokenFactory (proxy) | `0xa248f486fd838b315883026197cda96387f9e7dc` | live, single-key admin |
| AppBondingToken (impl) | `0x06b6bb8f225e9c1c278f8a2b47fe768af9a7a4f8` | live, clone target |
| FeeRouter (proxy) | `0x0d0dd1d8d2940ed4c1cf05635722528def612559` | live, single-key admin |
| EntitlementRegistry (proxy) | `0xb821d04f1fd49851e3adc89505e10241f8a01a4c` | live, single-key admin |
| ReceiptSettlement (proxy) | `0x1b522b9d62986f4ad0e7e881bad464b6e7e37317` | live, single-key admin |
| FeeSwapRouter | not yet deployed | code + tests + Slither in this repo |

Full deploy artifacts and tx hashes are in [`docs/DEPLOYMENTS.md`](docs/DEPLOYMENTS.md).

## Layout

### `contracts/token/`

`NOXTokenV2_1.sol` — the live ERC-20 implementation behind the proxy
`0x0a26c80B…9eCA`. Storage-safe UUPS upgrade of V2. Auto-swap with
reserve-quoted slippage, chunked output, router-allowance reset on failure;
ETH distribution with failed-eth parking and recovery; LP-pair safety;
validated fee policy.

`NOXStakingV4.sol` — the live staking implementation behind the proxy
`0xa94d6009…3613`. Storage-safe UUPS upgrade of V3. Adds `compoundRewards`,
`unlockExpired`, lazy V4 migration, Zero State Pass binding, namespace
eligibility, operator id + stake receipt + digest, NONOS-native tier names,
reward-reserve cap, `protectedRewardReserve` floor on emergency withdraws,
SafeERC20 everywhere, `reinitV4` replay protection.

`NOXStakingV3.sol` — prior staking implementation. Kept in-repo because fork
tests roll back to it to prove storage-safe V3→V4 upgrade and rollback path.

`NOXNamespaceRegistry.sol` — standalone, non-upgradeable. Delegates eligibility
to `staking.namespaceEligibility(wallet, positionId)` which requires an active
Circuit-tier position with a validly bound Zero State Pass.

`NOXAccessRegistry.sol` — standalone, non-upgradeable. Bitmask-flag access
registry administered by the Safe.

`NOXTokenV2.sol` — prior token implementation. Kept in-repo for V2 → V2.1
upgrade tests.

### `contracts/nft/`

ZeroState Pass — verified-source NFT live at the address above. The source
is on Etherscan; not duplicated in this repo.

### `contracts/bridge/`

`NOXBridge.sol` — three-of-three validator multisig bridging NOX between
Ethereum and Cellframe Backbone. Burns happen on the source side, mints on
the destination side. Daily limits, fee in NOX, pause path, and explicit
status codes for stuck transactions.

`CellframeBridge.sol` and `ICellframeBridge.sol` describe the Cellframe-side
artifacts the validators expect. The Cellframe contract itself is not
Solidity; the file documents the wire format.

### `contracts/marketplace/`

The contract suite that publishes capsule apps for NØNOS OS, mints
app-bound bonding-curve tokens for them, gates access through entitlements,
and settles per-call receipts.

```
core/
  CapsuleRegistry.sol     publisher + capsule + release lifecycle
  AppTokenFactory.sol     deploys EIP-1167 AppBondingToken clones, bound to a release
  AppTokenFactoryV2.sol   factory v2 (allowlist + treasury config)
  AppBondingToken.sol     per-app bonding curve, NOX as reserve, graduation to DEX
  AppBondingTokenV2.sol   bonding token v2

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

Detailed reproduction steps are in [`docs/REPRODUCIBILITY.md`](docs/REPRODUCIBILITY.md).

```
forge install
forge build
forge test --offline
```

Fork tests need `ETH_RPC_URL` set:

```
export ETH_RPC_URL=https://...
forge test
```

Deploy scripts live in `script/`. Each one reads its config from environment
variables only; nothing is hardcoded. See the script files and
[`docs/DEPLOYMENTS.md`](docs/DEPLOYMENTS.md).

## Audit and review status

| Component | Status |
|---|---|
| NOX V2.1 token | **External audit in progress.** Source verified Exact-Match on Etherscan. Internal review and upgrade-safety verification complete. |
| NOX Staking V4 | Internal review complete; external audit pending. |
| NOXNamespaceRegistry, NOXAccessRegistry | Internal review complete; external audit pending. |
| Marketplace v2 base suite | Internal review complete; Slither in `docs/security/`. |
| FeeSwapRouter | Internal review complete; Slither in `docs/security/`. |
| Bridge | Operating without incident since deployment; same audit status. |

## Contact

eKisNonos · `ekisano@proton.me`

Repo: <https://github.com/NON-OS/NOX-SmartContract>

## License

MIT.

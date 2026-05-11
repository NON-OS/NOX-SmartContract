# Reproducibility

This repository pins everything an external reviewer needs to reproduce the
build, the unit suite, and the live-fork suite for `NOXTokenV2_1.sol`.

## Toolchain

| Tool | Version |
|---|---|
| Foundry | `forge ≥ 0.2.0`, tested with stable nightly as of 2026-05 |
| Solc | `0.8.24+commit.e11b9ed9` (pinned in `foundry.toml`) |
| OpenZeppelin Contracts | as specified in `lib/openzeppelin-contracts` |
| OpenZeppelin Contracts Upgradeable | as specified in `lib/openzeppelin-contracts-upgradeable` |

Install Foundry (any OS):

```
curl -L https://foundry.paradigm.xyz | bash
foundryup
```

## Clone and install dependencies

```
git clone https://github.com/NON-OS/NOX-SmartContract.git
cd NOX-SmartContract
forge install
```

`forge install` materialises the `lib/` submodules listed in `foundry.toml`.
No npm / yarn / pnpm is required to build or test the contracts.

## Foundry profiles

Defined in `foundry.toml`.

| Profile | Optimizer | viaIR | bytecode_hash | When to use |
|---|---|---|---|---|
| `upgrade` | `runs = 1` | false | `ipfs` | Local tests, upgrade-safety verification |
| `deploy` | `runs = 1` | `true` | `none` | Production implementation builds; this is the profile used for the live V2.1 implementation and the live V4 staking implementation |

Switch profile by setting `FOUNDRY_PROFILE`.

## Build

```
forge build
```

Or pin the deploy profile explicitly (matches what is verified on Etherscan):

```
FOUNDRY_PROFILE=deploy forge build
```

Expected: `Compiler run successful with warnings:` and no errors. The lint
warnings are stylistic and do not affect bytecode.

## Tests

### Offline (does not need an RPC)

```
forge test --offline
```

Expected aggregate when the `ETH_RPC_URL` environment variable is **not** set:
fork suites under `test/token/*.fork.t.sol` skip cleanly; everything else
passes.

### With a mainnet RPC (full suite including fork tests)

```
export ETH_RPC_URL=https://...
forge test
```

Token fork tests pin to live-state queries on the latest block. The staking V4
fork tests pin to a specific pre-upgrade block declared in the test file:

```
uint256 constant PRE_UPGRADE_BLOCK = 25070941;
```

This block is the last mainnet block before the V3→V4 staking upgrade ran, so
the test deploys a fresh `NOXStakingV4` implementation and replays the actual
historical upgrade against the live storage state.

### Token-only audit run

```
export ETH_RPC_URL=https://...
forge test --match-path 'test/token/NOXTokenV2_1*.t.sol' -vv
```

Expected:

| File | Tests | Result |
|---|---|---|
| `test/token/NOXTokenV2_1.t.sol` | 26 | all pass |
| `test/token/NOXTokenV2_1.upgrade.t.sol` | 1 | passes |
| `test/token/NOXTokenV2_1.fork.t.sol` | 9 | all pass with `ETH_RPC_URL` set; skip otherwise |

## Verifying the live V2.1 implementation matches the source

Etherscan-verified deploy used:

```
solc           v0.8.24+commit.e11b9ed9
optimizer      enabled, runs = 1
viaIR          true
evmVersion     paris
bytecodeHash   none
```

Re-deploy with `FOUNDRY_PROFILE=deploy` and the deployedBytecode of the local
artifact should match the on-chain implementation byte-for-byte (no metadata
trailer because `bytecodeHash = none`).

## What you should observe on chain

| Read | Address | Expected |
|---|---|---|
| `implementation()` (ERC-1967 slot read) | `0x0a26c80Be4E060e688d7C23aDdB92cBb5D2C9eCA` | `0xBf0415ebFC762B4166e198736a15Ff0B53744e43` |
| `version()` or `VERSION()` | NOX token proxy | `"2.1.0"` (string return), check token source |
| `paused()` | NOX token proxy | `false` |
| Safe holds `GOVERNOR_ROLE`, `UPGRADER_ROLE`, `EMERGENCY_ROLE`, `DEFAULT_ADMIN_ROLE` | NOX token proxy | all `true` |

## Reproducibility hash check

If you want to assert that the on-chain runtime matches your local build:

```
FOUNDRY_PROFILE=deploy forge inspect contracts/token/NOXTokenV2_1.sol:NOXTokenV2_1 deployedBytecode > /tmp/local.txt
cast code 0xBf0415ebFC762B4166e198736a15Ff0B53744e43 --rpc-url $ETH_RPC_URL > /tmp/onchain.txt
diff /tmp/local.txt /tmp/onchain.txt && echo "EXACT MATCH"
```

`bytecodeHash = none` removes the trailing IPFS metadata, so the byte
comparison is exact, not "similar match".

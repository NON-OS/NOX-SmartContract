# Testing

All tests run under Foundry. Two profiles are used:

| Profile | Optimizer | viaIR | bytecode_hash | Purpose |
| --- | --- | --- | --- | --- |
| `upgrade` | runs=1 | false | ipfs | Local testing of upgrade paths against existing storage |
| `deploy` | runs=1 | true | none | Production implementation deploys |

Set `ETH_RPC_URL` in `.env` to enable fork tests. Without it, fork suites skip cleanly.

## Suites

### Token — `contracts/token/NOXTokenV2_1.sol`

| File | Tests | Scope |
| --- | --- | --- |
| `test/token/NOXTokenV2_1.t.sol` | 26 | Auto-swap, reserve-quoted slippage, fee policy validation, LP pair safety, failed-ETH parking, governance role lock, deflation cap, unit-level mutators |
| `test/token/NOXTokenV2_1.upgrade.t.sol` | 1 | Storage-safe UUPS upgrade from V2 to V2.1 |
| `test/token/NOXTokenV2_1.fork.t.sol` | 9 | Post-migration invariants on live mainnet proxy: implementation address, vhost addresses, V2.1 state initialized, fees at 2.5%, recipients routed to Safe, pair protections active, role migration complete, no stuck ETH |

### Staking — `contracts/staking/NOXStakingV4.sol`

| File | Tests | Scope |
| --- | --- | --- |
| `test/staking/NOXStakingV4.t.sol` | 39 | Storage layout V3→V4 append-only, emergency-withdraw reserve cap, reinit replay protection, reward reserve cap on claims, compound semantics, lock-expiry unwind, partial claim, migration idempotency, NFT-count boost, lock boost, NONOS tier mapping, namespace eligibility, ZSP binding lifecycle, stake receipt + operator ID, kernel-separation sentinel |
| `test/staking/NOXStakingV4.fork.t.sol` | 4 | Live-fork replay pinned at `PRE_UPGRADE_BLOCK = 25_070_941`: V3 state preserved byte-for-byte across `upgradeToAndCall(reinitV4(500, 0))`, reinitV4 cannot replay, V3 rollback is safe, users can still unstake after upgrade |

### Registries

| File | Tests | Scope |
| --- | --- | --- |
| `test/registry/NOXNamespaceRegistry.t.sol` | 7 | Reserve, release, owner enforcement, eligibility delegation to staking, zero-name-hash guard, kernel-separation sentinel |
| `test/registry/NOXAccessRegistry.t.sol` | 7 | Bitmask flags, admin grant/revoke, role gating, invalid-flag rejection, multi-flag independence, kernel-separation sentinel |

### Marketplace and revenue (out of scope for this commit's audit but kept green)

| File | Tests |
| --- | --- |
| `test/marketplace/v2/*` | full marketplace V2 suite |
| `test/revenue/feeSwap/*` | FeeSwapRouter + mocks |

## Running

```
forge build
forge test
forge test --match-path 'test/token/*.t.sol'
ETH_RPC_URL=https://... forge test --match-path 'test/token/*.fork.t.sol'
```

## Live deployment state referenced by fork tests

| Contract | Address |
| --- | --- |
| Staking proxy | `0xa94d6009790Ba13597A1E1b7cF4e1531eA513613` |
| V4 implementation | `0x415790B1f0aecd18B24D53BEaa25597573375B63` |
| Live V3 implementation (rollback target) | `0xcD499Fa840F3475fdc8a9B150405b9811AE54410` |
| NOX token | `0x0a26c80Be4E060e688d7C23aDdB92cBb5D2C9eCA` |
| NOX V2.1 implementation | `0xBf0415ebFC762B4166e198736a15Ff0B53744e43` |
| Zero State Pass | `0x7b575DD8e8b111c52Ab1e872924d4Efd4DF403df` |
| Safe (governor / upgrader) | `0x3a52ea60F61036Afbbec25F46a64485Ac4477Ccc` |
| NOXNamespaceRegistry | `0xD554ae30A0D20CB988c40d6C3b3d907740B9FD5C` |
| NOXAccessRegistry | `0x31140F839E2BB03C903ca894A87DF40c7333d38b` |

## Aggregate result

| | Count |
| --- | --- |
| Token suites | 36 tests, 0 failures |
| Staking V4 suites | 43 tests, 0 failures |
| Registry suites | 14 tests, 0 failures |
| Other in-repo suites | 142 tests, 0 failures |
| **In-scope total** | **93 tests** |
| **Repo total** | **235 tests** |

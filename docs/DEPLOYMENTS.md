# Deployments

Every NOX contract live on Ethereum mainnet. Chain id `0x1`.

## Token + NFT + Staking + Registries

### Proxies (call these)

| Contract | Address | Etherscan |
|---|---|---|
| NOX token (ERC-20) | `0x0a26c80Be4E060e688d7C23aDdB92cBb5D2C9eCA` | [view](https://etherscan.io/token/0x0a26c80Be4E060e688d7C23aDdB92cBb5D2C9eCA) |
| NOX Staking | `0xa94d6009790Ba13597A1E1b7cF4e1531eA513613` | [view](https://etherscan.io/address/0xa94d6009790Ba13597A1E1b7cF4e1531eA513613) |
| NOXNamespaceRegistry | `0xD554ae30A0D20CB988c40d6C3b3d907740B9FD5C` | [view](https://etherscan.io/address/0xD554ae30A0D20CB988c40d6C3b3d907740B9FD5C) |
| NOXAccessRegistry | `0x31140F839E2BB03C903ca894A87DF40c7333d38b` | [view](https://etherscan.io/address/0x31140F839E2BB03C903ca894A87DF40c7333d38b) |
| ZeroState Pass NFT | `0x7b575DD8e8b111c52Ab1e872924d4Efd4DF403df` | [view](https://etherscan.io/address/0x7b575DD8e8b111c52Ab1e872924d4Efd4DF403df) |
| NOX Rewards (legacy) | `0xa76cd221a30a100213f51b315cacd69daeab72be` | [view](https://etherscan.io/address/0xa76cd221a30a100213f51b315cacd69daeab72be) |

### Implementations behind the proxies

| Proxy | Current implementation | Etherscan |
|---|---|---|
| NOX token | `0xBf0415ebFC762B4166e198736a15Ff0B53744e43` (V2.1) | [view](https://etherscan.io/address/0xBf0415ebFC762B4166e198736a15Ff0B53744e43) |
| NOX Staking | `0x415790B1f0aecd18B24D53BEaa25597573375B63` (V4) | [view](https://etherscan.io/address/0x415790B1f0aecd18B24D53BEaa25597573375B63) |
| NOX Staking (prior V3, rollback target) | `0xcD499Fa840F3475fdc8a9B150405b9811AE54410` | [view](https://etherscan.io/address/0xcD499Fa840F3475fdc8a9B150405b9811AE54410) |

### Governance

| Role | Address |
|---|---|
| Safe (3-of-5) — governor, admin, upgrader on NOX token + staking proxies | `0x3a52ea60F61036Afbbec25F46a64485Ac4477Ccc` |
| Safe singleton | `0x41675c099f32341bf84bfc5382af534df5c7461a` (canonical Safe v1.4.1) |

The deployer EOA has been fully renounced from every privileged role on the
token and staking proxies.

### V4 staking upgrade transaction

| Field | Value |
|---|---|
| V4 implementation deploy tx | `0xe845463f3d5b4c516b93eeabdf7173182fd25512a3a6528d16b8a032dd54a649` |
| V4 implementation deploy block | `25,070,868` |
| Safe upgrade tx (`upgradeToAndCall(V4, reinitV4(500, 0))`) | `0x5ed9b880ef2a3246c39dfaff3342936006e4a17d19441c9c06c8fcbc3b625e52` |
| Safe upgrade block | `25,070,942` |
| Pre-upgrade block (used by fork tests) | `25,070,941` |
| NOXNamespaceRegistry deploy tx | `0x0b0ce44ab6b176423dca25599a718963c554a874bb608f9cfeb22790cd8b2ea7` |
| NOXNamespaceRegistry deploy block | `25,071,065` |
| NOXAccessRegistry deploy tx | `0xdefd3beac1d7516d02163425e741a60ceaa862dcd0e0671336b4ab086a902cc9` |
| NOXAccessRegistry deploy block | `25,071,067` |

## Bridge

| Contract | Address | Etherscan |
|---|---|---|
| NOX Bridge (proxy) | `0x70Fb00075879E7D9d87EA5536c6c374cc2d14435` | [view](https://etherscan.io/address/0x70Fb00075879E7D9d87EA5536c6c374cc2d14435) |
| Cellframe burn wallet | `Rj7J7MiX2bWy8sNyX1MFFTseBrFByqaSxHmLXZu8twkVxoWH1Urh8k88SNWBiiZoztfMbgHcfyzn2Jyc2zTHnF2RocZq6K841Y24yNEG` | (off-chain, Cellframe Backbone) |

## Marketplace base suite — deployed 5 May 2026, block 25,031,029

Compiler 0.8.24, optimizer 200 runs, evm version `paris`, no via-ir.

### Proxies (call these)

| Contract | Proxy | Etherscan |
|---|---|---|
| CapsuleRegistry | `0xcabb848fac25af95068d64eb5501e689c88172a3` | [view](https://etherscan.io/address/0xcabb848fac25af95068d64eb5501e689c88172a3) |
| AppTokenFactory | `0xa248f486fd838b315883026197cda96387f9e7dc` | [view](https://etherscan.io/address/0xa248f486fd838b315883026197cda96387f9e7dc) |
| FeeRouter | `0x0d0dd1d8d2940ed4c1cf05635722528def612559` | [view](https://etherscan.io/address/0x0d0dd1d8d2940ed4c1cf05635722528def612559) |
| EntitlementRegistry | `0xb821d04f1fd49851e3adc89505e10241f8a01a4c` | [view](https://etherscan.io/address/0xb821d04f1fd49851e3adc89505e10241f8a01a4c) |
| ReceiptSettlement | `0x1b522b9d62986f4ad0e7e881bad464b6e7e37317` | [view](https://etherscan.io/address/0x1b522b9d62986f4ad0e7e881bad464b6e7e37317) |

### Implementations (referenced by proxies; do not call directly)

| Contract | Implementation |
|---|---|
| CapsuleRegistry impl | `0xff1a9c2809e0a7b5f475cef30ca05046c0413854` |
| AppTokenFactory impl | `0xbc7cb8e181057b4a4cc7891348d89c7f94e1b6d3` |
| AppBondingToken impl | `0x06b6bb8f225e9c1c278f8a2b47fe768af9a7a4f8` |
| FeeRouter impl | `0x06278be437b84e2a653bdf1b7bf62ce2fd9c7377` |
| EntitlementRegistry impl | `0x1e5c8e755aa14901251469009510fd243b02e6c3` |
| ReceiptSettlement impl | `0xfbd3e9cb6582316bb7f72283298d97aac77626a4` |

`AppBondingToken` has no proxy. Each app's token is a fresh EIP-1167 minimal
proxy clone of the implementation, deployed by `AppTokenFactory.createAppToken`.

### Deploy transaction hashes

| Contract | Tx hash |
|---|---|
| CapsuleRegistry impl | `0xe74af1609a61e166bef01649ef9a2c84e42ee519e61ff0db61c840c9cdf6a00b` |
| CapsuleRegistry proxy | `0x1f4c6b18982e011e06cc1d6679a3e777fc2c4be4d1b952fdb44ac915ec227aa2` |
| FeeRouter impl | `0xeaaeb9c6e608f2bf7aa96a6beb45d57122610092578cb6677df7bee2dbc37cef` |
| FeeRouter proxy | `0x3ed2bff00b04b6d033f944a945b91bed874a7a8dec6111ed9dafb2e30f1877c7` |
| AppBondingToken impl | `0x57bc0ddadb47a5b6b657b3c0e3ca4a2ab488bb9fa5e47f6f63188657dec7a066` |
| AppTokenFactory impl | `0xfc2f38f230198df2039a208765f4d574d823b75d43ba033862449f443670197a` |
| AppTokenFactory proxy | `0x360dea3e1d58c4375c31c4a5cd1e7a34cdfb9b7b32f27385ba01345a5bb8f1d5` |
| EntitlementRegistry impl | `0x22ee6bb703c218c52ed7e8104b6bacd64ce0cfeccdbd3c0d0e8e8629c498c366` |
| EntitlementRegistry proxy | `0x6ea11190296ab583ed283a181b3b36d080feb5f2c3e4f5da3889483eb3314a05` |
| ReceiptSettlement impl | `0x283e87c5f49a79f523f04699b8403fe872f29b5a2249474fca876b2ba80f3eb4` |
| ReceiptSettlement proxy | `0xb1e600f15ccf60ce7f984fda37f6e377b5954e55381adb50028b6232c2d81a76` |

Total deploy gas: 0.0071 ETH at 0.47 gwei.

## FeeSwapRouter — deployed 6 May 2026

Atomic fee-on-input swap wrapper. Allowlisted swap targets only, leftover
refund invariant, fee-on-transfer-aware. UUPS proxy.

| Contract | Address | Etherscan |
|---|---|---|
| FeeSwapRouter (proxy) | `0x09d4fDb7176ef0E20Af558e650d2dcd8D1f73d62` | [view](https://etherscan.io/address/0x09d4fdb7176ef0e20af558e650d2dcd8d1f73d62) |
| FeeSwapRouter (impl) | `0x2E8f5eaE247435DDb513e408636A5fCF8Fd2699F` | [view](https://etherscan.io/address/0x2e8f5eae247435ddb513e408636a5fcf8fd2699f) |

Initial config:

| Setting | Value |
|---|---|
| `feeBps` | `10` (0.10%) |
| `MAX_FEE_BPS` | `100` (1.00% absolute cap) |
| `feeRecipient` | `0xa12eCf0CDfC9D53FFafbdef43696cE615E662B33` (B33, temporary; rotation to Safe pending) |
| All four roles (admin, config, pauser, upgrader) | B33 (temporary; rotation to Safe pending) |
| Approved target: Uniswap V2 router | `0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D` |
| AppTokenFactory wired | `0xa248f486fD838B315883026197cda96387f9E7Dc` (any clone it produces is auto-approved as a swap target) |
| Paused | false |

The dapp's `CONFIG.PROTOCOL_FEE_BPS` is currently set to `0`, so users are
not charged protocol fees yet. The fee will flip on after adapters route
through this router and an end-to-end fork dry-run lands. Until then the UI
shows "planned 0.10%, paused".

## Marketplace admin posture

Until `FinalizeMarketplace.s.sol` runs against Safe addresses, B33
(`0xa12eCf0CDfC9D53FFafbdef43696cE615E662B33`) holds every privileged role:

- `DEFAULT_ADMIN_ROLE` on every v2 contract
- `UPGRADER_ROLE` on every UUPS proxy
- `PAUSER_ROLE` on every contract that pauses
- `VALIDATOR_ROLE` on `CapsuleRegistry`
- `CONFIG_ROLE` on `FeeRouter`, `AppTokenFactory`, `EntitlementRegistry`, `ReceiptSettlement`
- `TREASURY_ROLE` on `FeeRouter`

After Finalize, B33 holds none of them. The Safe(s) configured in env at
finalize time take over.

## FeeRouter sinks (current)

| Sink | Address |
|---|---|
| `nftHoldersSink` | DAO_WALLET (single-sink-first) |
| `stakersSink` | DAO_WALLET |
| `treasurySink` | DAO_WALLET |

`launchFeeWei = 0`. Receipt settlement `epochDuration = 86400` (one day).

## App-token V2 upgrade — deployed 7 May 2026

In-place UUPS upgrade of the existing AppTokenFactory proxy at `0xa248f486fD838B315883026197cda96387f9E7Dc` to a V2 implementation that clones a new `AppBondingTokenV2` and exposes `createAppTokenV2(LaunchParamsV2)` behind a `LAUNCH_ENABLED` flag (default `false`). The V1 launch surface (`createAppToken(LaunchParams)`) is hard-disabled at the contract layer — calls now revert `LaunchDisabled()`.

| Contract | Address | Etherscan |
|---|---|---|
| AppBondingTokenV2 (impl) | `0x16caCbC81249c0A7d2d0271e77f0D05489AB35Dc` | [view](https://etherscan.io/address/0x16cacbc81249c0a7d2d0271e77f0d05489ab35dc) |
| AppTokenFactoryV2 (impl) | `0x58A167A94365B6294900A1e2A4229807DCbcdC09` | [view](https://etherscan.io/address/0x58a167a94365b6294900a1e2a4229807dcbcdc09) |
| AppTokenFactory (proxy, upgraded) | `0xa248f486fD838B315883026197cda96387f9E7Dc` | [view](https://etherscan.io/address/0xa248f486fd838b315883026197cda96387f9e7dc) |

Live config on the factory proxy after `initializeV2`:

| Setting | Value |
|---|---|
| `bondingTokenImplV2()` | `0x16caCbC81249c0A7d2d0271e77f0D05489AB35Dc` |
| `weth()` | `0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2` |
| `uniV2Factory()` | `0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f` |
| `uniV2Router()` | `0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D` |
| `lpBurnTo()` | `0x000000000000000000000000000000000000dEaD` |
| `launchEnabled()` | **`false`** (gate stays closed until final dry-run + Safe rotation) |

Source-verified on Etherscan: both impls (compiler 0.8.24, optimizer 200, evm `paris`).

V2 invariants on the bonding token (encoded in the contract):

- APP / ETH graduation pair only.
- LP burned to `0x000000000000000000000000000000000000dEaD`.
- 1% maximum graduation fee (`MAX_GRADUATION_FEE_BPS = 100`).
- `lpReserveCap` validated at init against the curve's terminal price; misconfigured launches revert at clone-init.
- Pair safety: refuses pre-existing pairs that have non-zero reserves OR non-zero `balanceOf(pair)` for either side (Uniswap V2 first-mint donation-attack guard).
- Post-`addLiquidityETH` exact-amount assertion + zero-stuck-tokens / zero-stuck-eth assertions.
- Bonding `buy`/`sell` revert post-graduation (CEI; `graduated` set before any external call).
- `GraduatedToUniswap(pair, lpBurnTo, ethToLp, tokensToLp, lpMinted, fee, terminalPriceWeiPerToken)` event published on every graduation.

# Deployments

Every NOX contract live on Ethereum mainnet. Chain id `0x1`.

## Token + NFT + Staking

| Contract | Address | Etherscan |
|---|---|---|
| NOX V2 (ERC-20) | `0x0a26c80Be4E060e688d7C23aDdB92cBb5D2C9eCA` | [view](https://etherscan.io/token/0x0a26c80Be4E060e688d7C23aDdB92cBb5D2C9eCA) |
| ZeroState Pass NFT | `0x7b575DD8e8b111c52Ab1e872924d4Efd4DF403df` | [view](https://etherscan.io/address/0x7b575DD8e8b111c52Ab1e872924d4Efd4DF403df) |
| NOX Staking V3 | `0xa94d6009790Ba13597A1E1b7cF4e1531eA513613` | [view](https://etherscan.io/address/0xa94d6009790Ba13597A1E1b7cF4e1531eA513613) |
| NOX Rewards | `0xa76cd221a30a100213f51b315cacd69daeab72be` | [view](https://etherscan.io/address/0xa76cd221a30a100213f51b315cacd69daeab72be) |

## Bridge

| Contract | Address | Etherscan |
|---|---|---|
| NOX Bridge (proxy) | `0x70Fb00075879E7D9d87EA5536c6c374cc2d14435` | [view](https://etherscan.io/address/0x70Fb00075879E7D9d87EA5536c6c374cc2d14435) |
| Cellframe burn wallet | `Rj7J7MiX2bWy8sNyX1MFFTseBrFByqaSxHmLXZu8twkVxoWH1Urh8k88SNWBiiZoztfMbgHcfyzn2Jyc2zTHnF2RocZq6K841Y24yNEG` | (off-chain, Cellframe Backbone) |

## Marketplace v2 — deployed 5 May 2026, block 25,031,029

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

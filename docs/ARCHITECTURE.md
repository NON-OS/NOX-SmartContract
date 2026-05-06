# Architecture

NOX is the asset of account for the NØNOS capsule marketplace and bridges
between Ethereum and Cellframe Backbone. The contract suite is split into
five concerns that talk to each other through small, fixed interfaces.

```
                            ┌──────────────────────┐
                            │      NOX (ERC-20)    │
                            └──────────┬───────────┘
                                       │
              ┌────────────────────────┼────────────────────────┐
              │                        │                        │
       ┌──────▼─────┐          ┌───────▼────────┐         ┌─────▼─────┐
       │   Bridge   │          │    Staking     │         │ Marketplace│
       │ (Cellframe │          │  + ZeroState   │         │   (v2)    │
       │   ↔ ETH)   │          │   Pass NFT     │         │           │
       └────────────┘          └────────────────┘         └─────┬─────┘
                                                                │
                       ┌────────────────────────────────────────┤
                       │                                        │
              ┌────────▼────────┐                     ┌─────────▼────────┐
              │ CapsuleRegistry │                     │  AppTokenFactory │
              │ publishers,     │                     │  EIP-1167 clones │
              │ releases,       │                     │  bound to a      │
              │ validation      │                     │  validated       │
              └────────┬────────┘                     │  release         │
                       │                              └─────────┬────────┘
                       │                                        │
              ┌────────▼─────────────────────────────────────────▼────────┐
              │                       FeeRouter                            │
              │  4-way revenue split (publisher / NFT / stakers / treasury)│
              │  per-source profile (trade / launch / unlock / receipt)    │
              └─────────┬─────────────────────────────────┬────────────────┘
                        │                                 │
              ┌─────────▼──────────┐         ┌────────────▼──────────────┐
              │ EntitlementRegistry │         │     ReceiptSettlement     │
              │ free / one-time /   │         │ batched EIP-712 receipts  │
              │ subscription / NFT  │         │ for pay-per-use access    │
              │ / token gates       │         │                            │
              └─────────────────────┘         └───────────────────────────┘

                        ┌────────────────────────────────────┐
                        │           FeeSwapRouter            │
                        │  atomic fee-on-input swap wrapper  │
                        │  allowlisted targets only          │
                        │  10 bps cap, leftover refund        │
                        └────────────────────────────────────┘
```

## Identity model

A capsule app has three identifiers, all stored on-chain in `CapsuleRegistry`.

`capsuleId` — a 32-byte value derived deterministically from the publisher
public key, the package hash, the app namespace, and the major version. Stays
constant across releases of the same app.

`releaseId` — incrementing per capsule. One row in `capsule_releases` per
release. Carries the `manifestHash`, `packageHash`, `packageUrl`, and the
publisher's signature over the canonicalised manifest.

`appToken` — optional. If a publisher chooses to launch an app-bound token,
`AppTokenFactory.createAppToken(capsuleId, releaseId, manifestHash, packageHash, ...)`
deploys a fresh `AppBondingToken` clone whose `getAppToken()` view permanently
links the token back to the release that birthed it.

## Trust path

A user installing a capsule on NØNOS OS verifies, in this order:

1. The marketplace index Ed25519 signature against the operator public key
   baked into the OS bootstrap trust list.
2. The release entry's `validation_status == validated` and the validator id
   matches the on-chain `VALIDATOR_ROLE` holder.
3. The publisher signature over the canonical manifest, against the
   publisher's on-chain public key in `CapsuleRegistry`.
4. The downloaded package's BLAKE3 hash matches `packageHash`.
5. The capsule's declared capability set is a subset of what the user has
   approved.
6. `EntitlementRegistry.hasEntitlement(capsuleId, userWallet)` returns true.

If any step fails, the install does not proceed. The marketplace publishes
the catalog; the OS is the final word on whether anything actually runs.

## Revenue model

Every NOX flow lands in `FeeRouter`. Each source identifier (`bytes32`) maps
to a `Profile` with four basis-point splits:

| Source profile | Publisher | NFT holders | Stakers | Treasury |
|---|---|---|---|---|
| trade | configurable | configurable | configurable | configurable |
| launch | 0 | configurable | configurable | configurable |
| unlock | configurable | configurable | configurable | configurable |
| receipt | configurable | configurable | configurable | configurable |

All profiles are role-controlled. Sums must equal 10000 bps. Rounding goes to
treasury. Default deployment routes everything to the DAO wallet as a single
sink, until the DAO votes to split.

## Upgradeability

CapsuleRegistry, AppTokenFactory, FeeRouter, EntitlementRegistry, and
ReceiptSettlement are UUPS proxies. Each has an `UPGRADER_ROLE` separated
from the admin. Upgrade requires the upgrade Safe's signature.

`AppBondingToken` is not upgradeable. Each clone is immutable from the
moment it is deployed. The factory implementation can be upgraded, but only
new clones get the new code.

`NOXBridge` is also a UUPS proxy. The bridge admin is currently B33, will
move to a Safe at the same time the marketplace contracts do.

`NOXToken` is not upgradeable. The token contract is fully immutable.

## Inputs and outputs across the system boundary

Three things enter the OS from this repo, and only three:

1. The signed marketplace index (binary, served at
   `/api/v1/marketplace/index`, signed by the operator key).
2. The result of `EntitlementRegistry.hasEntitlement(capsuleId, user)` queried
   on-chain.
3. The capsule package itself, downloaded from `packageUrl`, hash-checked.

Three things leave the OS toward this repo, and only three:

1. EIP-712 receipts signed by the user wallet, batched by the publisher's
   backend, settled in `ReceiptSettlement.batchSettle`.
2. Unlock transactions when the user buys access, calling
   `EntitlementRegistry.unlock(capsuleId)`.
3. Trades on `AppBondingToken` clones via the dapp.

The OS does not read marketplace policy, prices, or validator decisions
beyond the signed catalog. The marketplace does not read kernel internals.

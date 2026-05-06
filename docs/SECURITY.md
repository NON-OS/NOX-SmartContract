# Security review status

## Scope

The Solidity surface in this repo:

- `contracts/token/NOXToken.sol`
- `contracts/token/NOXStaking.sol`
- `contracts/bridge/NOXBridge.sol`
- `contracts/marketplace/core/CapsuleRegistry.sol`
- `contracts/marketplace/core/AppTokenFactory.sol`
- `contracts/marketplace/core/AppBondingToken.sol`
- `contracts/marketplace/libraries/BondingCurveLib.sol`
- `contracts/marketplace/revenue/FeeRouter.sol`
- `contracts/marketplace/revenue/FeeSwapRouter.sol`
- `contracts/marketplace/entitlement/EntitlementRegistry.sol`
- `contracts/marketplace/entitlement/ReceiptSettlement.sol`

## Current state

| Layer | Status |
|---|---|
| Internal review (B33) | done for every contract above |
| External audit | not started |
| Bug bounty | not open |
| Slither (FeeSwapRouter) | run, [findings documented](security/SLITHER_FeeSwapRouter.md), 0 critical |
| Foundry test suites | green (`forge test`) |
| Mainnet fork test (FeeSwapRouter) | passing on real Uniswap V2 router and real NOX |
| 1024-run fuzz (BondingCurveLib invariants) | green |

## Bridge

`NOXBridge` is live and processing real flows. It uses three-of-three
validator multisig on the Ethereum side. If any one validator key is
compromised no bridge from Cellframe can complete. If all three are
compromised an attacker can mint NOX on Ethereum without a Cellframe burn.
Validator key custody is documented in the operator runbook, not in this
repo.

## Marketplace

All five v2 contracts use OpenZeppelin upgradeable patterns: UUPS,
AccessControl, Pausable on sensitive surfaces, ReentrancyGuard where
external calls are involved.

Until `FinalizeMarketplace.s.sol` runs against a Safe, the deployer key
holds every privileged role. A compromise of that key can:

- pause any contract
- upgrade any UUPS proxy to arbitrary implementation
- redirect FeeRouter sinks
- mark releases validated
- rotate fee bps inside the cap

This is the explicit cost of shipping the contracts before the Safe is
configured. The post-Finalize state has the same multisig protections as
the bridge will once it migrates.

## FeeSwapRouter — pre-deploy

The `FeeSwapRouter` source in this repo is not yet deployed. Pre-deployment
gates that have closed:

- 41/41 forge tests green
- Mainnet fork tests green
- Slither: 11 findings, 0 critical, every one explained in
  [`security/SLITHER_FeeSwapRouter.md`](security/SLITHER_FeeSwapRouter.md)
- Allowlist for swap targets, factory-driven dynamic approvals
- `forceApprove(0) → forceApprove(net) → call → forceApprove(0)` allowance
  hygiene around every ERC-20 swap
- Leftover ETH and ERC-20 input refunded to payer; invariant-checked
- Fee taken on amount actually received after `transferFrom` so
  fee-on-transfer input tokens are handled correctly
- `MAX_FEE_BPS = 100` (1.00%) hard-coded
- Rescue path under config role only, with `nonReentrant`

Pre-deployment gates that remain open:

- Treasury Safe address not yet set
- Frontend dry-run on a fork against the deployed proxy

Deployment unlocks once the Safe address arrives. The plan is in
`script/DeployFeeSwapRouter.s.sol`.

## What an external auditor would look at first

The list, in rough priority order:

1. `AppBondingToken` graduation. The transition from bonding curve to a
   Uniswap-style pool is the highest-value surface. Math is in
   `BondingCurveLib`, fuzz-tested but not third-party-reviewed.
2. `CapsuleRegistry.validateRelease` / `rejectRelease` state transitions and
   role-gate access.
3. `ReceiptSettlement.batchSettle` — EIP-712 verification, replay protection
   (per-user, per-capsule nonce + expiry), gas-bounded loop.
4. `FeeRouter` profile bounds and rounding.
5. `EntitlementRegistry` mode transitions.
6. `FeeSwapRouter` arbitrary-call surface and the allowlist enforcement.

## Out of scope here

Frontend, backend (FastAPI), indexer, and the off-chain bridge validator
service are operational software, not consensus-critical. They are reviewed
continuously in normal operations, not as part of this contract review.

## How this page changes

When external audit starts, this page gets the auditor name, scope
statement, start date, and a link to the in-flight working drafts. When the
audit finishes, this page gets the report, the findings, and the fix
commits that resolved them.

# 0xNOX / NØNOS — Contract Reference and Internal Review

> **Status of this document.** Internal team reference produced by a code-read review. Not an external audit. No third-party security firm has audited any contract listed here. The Slither pass that informs the V2 sections is a tool-assisted review, not an audit. Treat the word "review" throughout this document as "internal team review", not "external audit".

This is the working reference for the critical public flows of the Solidity contracts in the `NOX-SmartContract` repository. It is not a marketing document. It is what an engineer or reviewer needs to know before they touch production: what each contract does, what it stores, who is allowed to call what, what invariants it claims to preserve, and where the rough edges are. The coverage is concentrated on the user-facing paths (token transfer/tax, staking position lifecycle, bridge directions, marketplace launch + graduation, fee routing, entitlement, settlement). Internal helpers and view methods are described where they affect security or composability, otherwise they are summarized rather than enumerated.

The system has three logical layers. The **token layer** is the NOX ERC-20 itself plus the staking vault that pays NOX-denominated rewards to lockers. The **bridge layer** moves NOX between Ethereum and Cellframe Backbone via a multi-validator quorum. The **marketplace layer** is the on-chain piece of the NØNOS capsule app store: a registry of publishers and signed releases, an entitlement system that gates per-app access, a pay-per-use settlement contract for off-chain receipts, an app-token launchpad with bonding-curve discovery, and a fee router that splits revenue between the publisher, NFT holders, stakers, and treasury.

Three guiding principles cut across the codebase:

1. **No surprise upgrades of users.** Every contract that grants admin keys also exposes an explicit `pause` and an explicit role hierarchy. Public-facing flows (purchase, bridge, swap, graduate) are reentrancy-guarded and pause-aware.
2. **Capsule binding is non-negotiable on the marketplace side.** App tokens cannot be created in isolation. They must be tied to a capsule whose release has been validated and published. The factory enforces this; the bonding token carries the binding in its `AppLink`.
3. **The OS does not parse marketplace policy.** The kernel consumes a signed marketplace index and verifies package identity, signatures, capabilities, and ABI. Pricing, ranking, gating, and revenue split all stay in userland and on-chain.

What follows is one section per contract. Live mainnet addresses are taken from `docs/DEPLOYMENTS.md` and represent the current state at the time of writing.

---

## Token layer

### `NONOS_NOX_MAINNET_V2`  ·  `NOXTokenV2.sol`

**Live:** `0x0a26c80Be4E060e688d7C23aDdB92cBb5D2C9eCA`

The NOX ERC-20. UUPS-upgradeable, OpenZeppelin upgradeable base (`ERC20Upgradeable`, `ERC20BurnableUpgradeable`, `ERC20PermitUpgradeable`, `ERC20VotesUpgradeable`, `ERC20PausableUpgradeable`, `AccessControlUpgradeable`). Total supply is hard-capped at `MAX_SUPPLY = 800,000,000 * 1e18`, minted once at `initialize` across nine specific recipient wallets (dev, staking vault, DAO, liquidity collector, CEX listings, contributors, NFTs, marketing, and the residual to a `mainReceiver`). There is no `mint` function. The supply curve is purely deflationary from this point onward, driven by transfer-time burns and by NOX sent into the `0xdead` burn sink.

**Tax model.** The token applies a per-transfer fee with separate basis-point rates for buys, sells, and arbitrary transfers. The fee bucket is split four ways — burn, liquidity, treasury, dev — and the per-bucket shares must sum to exactly `10000` bps. The hard caps are encoded as `MAX_FEE_BPS = 1000` (10%) per leg and `MAX_SUM_BPS = 2000` (20%) for fee-plus-deflation combined. Default configuration on mainnet is 2% buy, 2% sell, 0% transfer. The contract knows which counterparties are LP pairs because LP membership is registered explicitly via `setPair(address, bool)`. The fee logic refuses to evaluate `_isLpPair[from]` or `_isLpPair[to]` against an unregistered address, so until a Uniswap V2 pair is registered, every move outside the original allocation is treated as a generic transfer.

**Anti-MEV / anti-whale guards.** Three optional guards live in `_update`. The same-block guard rejects more than one tx from the same EOA in the same block. The transaction-size guard caps any single transfer at `maxTxBps` of supply. The wallet-size guard caps any wallet's post-transfer balance at `maxWalletBps`. A separate `sellCooldown` enforces a per-EOA minimum interval between sells. There is also an `emergencyStop` kill switch and a per-address `blacklisted` mapping. All of these are governance-tunable via `setGuards`, `setExemptions`, `setBlacklist`, `setEmergencyStop`. None of them are enabled by default in production; they are levers, not policies.

**Auto-swap of accumulated tax.** If `initializeV2(router, swapThreshold, slippageBps)` is called once with a Uniswap V2 router and a registered pair, the contract will swap accumulated tax tokens to ETH on every sell that crosses `autoSwapThreshold`, then split the resulting ETH between `liquidityCollector`, `treasury`, and `devWallet` according to the share configuration. The swap is guarded by `lockTheSwap` (an `_inSwap` flag) that prevents the Uniswap callback from re-entering the tax logic mid-sale. The `setAutoSwapConfig` setter caps `slippageBps` at 300.

**Roles.** Four roles are created at `initialize` and granted to the deployer: `DEFAULT_ADMIN_ROLE`, `GOVERNOR_ROLE`, `UPGRADER_ROLE`, `EMERGENCY_ROLE`. Every config setter is gated by `GOVERNOR_ROLE`. UUPS upgrades are gated by `UPGRADER_ROLE` with no timelock at the contract layer — Safe ownership is the operational hardening that keeps this honest in production.

**Things to know.** The `require` reverts use one-character reason strings (`"0"` through `"j"`) for code-size reasons; they are documented in the source comments and are not user-facing. The min-out parameter of the auto-swap call is set to `0` and the actual slippage protection is done by configuration, not by the swap itself. The split distribution uses raw `.call{value: x}("")` and ignores the returned bool — a misconfigured recipient will silently lose the leg.

---

### `NOXStakingV3`  ·  `NOXStakingV3.sol`

**Live:** `0xa94d6009790Ba13597A1E1b7cF4e1531eA513613`

Multi-position staking vault. UUPS-upgradeable. Users open up to `MAX_POSITIONS = 10` independent stake positions, each with an optional lock period (none, 30, 60, 90, 180, or 365 days). Each position earns NOX from a fixed two-year emission schedule: 28M NOX in year one, 12M NOX in year two, then zero. Boosts compound multiplicatively from two sources: ZeroState Pass NFT count (capped at five NFTs, scaling from 100% to 250%) and the lock period (100% to 250%). The contract autofills the migration of legacy V2 single-position users on first interaction.

**Storage.** The V2 storage block — single stakes, single locks, total weighted stake, accumulated rewards-per-share — is preserved at the original slots so the V3 implementation can be an in-place UUPS upgrade. V3-specific state (`userInfo`, `positions`, `earlyUnlockPenaltyBps`, `totalPenaltiesBurned`) is appended after, and a custom `_reentrancyStatus` field is reset by `initializeV3` to fix V2's idle reentrancy guard.

**External surface.** `stake(amount)` opens a flexible position. `stakeLocked(amount, lockPeriod)` opens a locked position with the appropriate boost. `extendLock(positionId, newLockPeriod)` lengthens a position's lock; the contract refuses to ever shorten one. `unstake(amount)` walks the user's positions and pulls from any that are unlocked. `unstakePosition(positionId)` exits one specific position. `earlyUnlock(positionId)` exits a still-locked position by paying a configurable penalty (capped at 5000 bps = 50%) which is sent to `0xdead` — irrecoverable burn, accounted in `totalPenaltiesBurned`. `claimRewards()` materialises pending rewards. `refreshBoost(user)` recomputes a user's weighted amount when their NFT balance changes (any caller may invoke).

**Reward accounting.** `accRewardPerShare` is a monotonic accumulator. `getEmissionRate()` returns 0 once `block.timestamp` exceeds `genesisTime + 2 * YEAR_DURATION`, which closes the schedule. The total weighted stake is updated atomically on every position event so the per-share accumulator stays consistent.

**Roles.** `DEFAULT_ADMIN_ROLE`, `ADMIN_ROLE`, `UPGRADER_ROLE` granted to admin at init. `ADMIN_ROLE` gates `initializeV3`, `setEarlyUnlockPenalty`, `setGenesisTime` (one-shot — once set, it cannot be changed), `pause`, `unpause`, `adminMigrate`, and `emergencyWithdraw`. `UPGRADER_ROLE` gates `_authorizeUpgrade`. Most user-facing functions are `nonReentrant whenNotPaused whenGenesisSet`.

**Caveats.** `initializeV3` is gated by `ADMIN_ROLE` rather than the `reinitializer` modifier, so admin can re-enter it to reset the penalty bps and the reentrancy guard. Position iteration loops walk `info.positionCount`, not `MAX_POSITIONS`, so inactive positions accumulate gas weight over time even after withdrawal. `_harvestPositionRewards` zeros `lockEndTime`/`lockPeriod` when a lock expires, which auto-converts the position to flexible — desirable in normal use, but worth knowing if you script over user positions.

---

## Bridge layer

### `NOXBridge`  ·  `NOXBridge.sol`

**Live:** `0x70Fb00075879E7D9d87EA5536c6c374cc2d14435`

The single-asset NOX bridge between Ethereum mainnet and Cellframe Backbone. UUPS-upgradeable. Holds NOX liquidity in-contract. Charges a fixed `BRIDGE_FEE_BPS = 25` (0.25%) on outbound (ETH→CF) transfers. Inbound (CF→ETH) transfers must accumulate at least `MIN_CONFIRMATIONS = 3` valid validator signatures before the contract pays out.

**Outbound flow.** `bridgeToCell(amount, cfRecipient)` accepts NOX from the caller via `safeTransferFrom`, deducts the fee (sent immediately to `feeCollector`), and credits the net amount to `liquidityPool`. A `BridgeTransaction` record is created, indexed by `txId = keccak256(msg.sender, cfRecipient, amount, block.timestamp, _txCount++)`, and a `BridgeToCell` event is emitted. The off-chain validator quorum picks this up, mirrors the burn on Cellframe, and one of them calls `confirmBridgeToCell(txId, cfTxHash)` once per validator. The third confirmation flips the record to `COMPLETED`.

**Inbound flow.** `bridgeFromCell(cfTxHash, cfSender, ethRecipient, amount, signatures[])` is the workhorse. The contract computes `txId = keccak256(cfTxHash, cfSender, ethRecipient, amount)`, recovers each provided signature against `keccak256("\x19Ethereum Signed Message:\n32" || txId)`, and counts only signatures from addresses that hold `VALIDATOR_ROLE` and have not already signed this `txId`. Once the count reaches threshold, the contract transfers `amount` of NOX to `ethRecipient` and emits `BridgeToEth`. If a previous call already marked this `txId` as completed, the call reverts `AlreadyCompleted` — this is the on-chain idempotency that protects against off-chain double-emit.

**Liquidity model.** Anyone can call `addLiquidity(amount)` to deposit NOX into the bridge. `removeLiquidity(amount)` is admin-only and explicitly reserves an amount equal to the sum of inbound transactions still in flight, so admin cannot accidentally drain user-owed funds. `getLiquidity()` returns the current contract NOX balance.

**Daily limit.** A rolling per-day limit is enforced on outbound flows via `_checkDailyLimit`, keyed by `block.timestamp / 1 days`. Default is 1,000,000 NOX/day; tunable by admin.

**Roles.** `ADMIN_ROLE`, `UPGRADER_ROLE`, `VALIDATOR_ROLE`, plus a declared-but-unused `RELAYER_ROLE`. All admin-class roles are granted to `_admin` at init. `addValidator` and `removeValidator` manage the validator set. Refund of failed transactions, fee-collector swaps, and pause/unpause are admin-only.

**Threat model.** Replay protection on outbound is achieved via the monotonic `_txCount` baked into the txId. Inbound replay is closed by the same-tx_id `AlreadyCompleted` guard plus the per-signer `validatorConfirmations[txId][signer]` map. The bridge will silently skip non-validator signatures rather than revert — this matches the goal of "tolerate noisy relayers" but does mean a buggy off-chain signer can be hard to debug from on-chain data alone.

**Known sharp edges.** `_recoverSigner` accepts any `s` value (no malleability normalization). `BRIDGE_FEE_BPS` is `constant` so changing the fee requires a contract upgrade. The `RELAYER_ROLE` is dead code today.

### `CellframeBridge`  ·  `CellframeBridge.sol`

A general-purpose ERC-20 ↔ Cellframe bridge that supports arbitrary registered token pairs, not just NOX. Same multi-sig quorum pattern as `NOXBridge`, default 3 signers. Charges 30 bps. Distinct enough from `NOXBridge` that the two are kept separate: the NOX bridge hardcodes the NOX token address and is optimised for NOX-only liquidity; this one is the generic vehicle.

**Outbound.** `initiateBridgeToCellframe(ethToken, cfToken, amount, cfRecipient)` requires `ethToken` to have been registered via `registerTokenPair(ethToken, cfToken)`. Pulls `amount` of `ethToken`, sends fee to `feeCollector`, records `bridgeAmount = amount - fee`. `requestId` derives from `_requestCount`, ensuring uniqueness across registered tokens.

**Inbound.** `completeBridgeFromCellframe(requestId, ethToken, recipient, amount, signatures)` checks for `VALIDATOR_ROLE` membership on each signer, refuses duplicate signers (`AlreadySigned`), and refuses non-validator signers (`InvalidSignature`) — note that this is stricter than `NOXBridge` which silently skips. Marks `request.completed = true` on success, then transfers tokens.

**Failure path.** `markRequestFailed(requestId, reason)` is callable by validators. For outbound requests that have not yet been completed on the CF side, it refunds the post-fee amount to the original sender. Single-validator gated, which is the trust escape hatch for unrecoverable CF-side failures.

**Caveats.** `emergencyWithdraw` is admin-broad: any token to any address. Useful for incident response, dangerous if admin keys are compromised — strong argument for moving admin to Safe before any meaningful TVL accumulates. Same `ecrecover` malleability note as `NOXBridge`.

### `ICellframeBridge`  ·  `ICellframeBridge.sol`

Interface for `CellframeBridge`. Defines the `BridgeRequest` struct and the events. No behaviour.

---

## Marketplace core

### `CapsuleRegistry`  ·  `CapsuleRegistry.sol`

**Live (proxy):** `0xcabb848fac25af95068d64eb5501e689c88172a3`

The on-chain canonical record of marketplace apps. UUPS-upgradeable. Tracks two entities: `App` (one per `capsuleId`, owned by a `publisher`) and `Release` (versioned artifact with `manifestHash`, `packageHash`, `capabilityHash`, plus URIs for the package and validator's report).

**Lifecycle.** A publisher calls `registerApp(capsuleId, publisherKeyHash, metadataURI)` to claim a `capsuleId` (one publisher per capsule, enforced by `AppExists`). They submit releases via `submitRelease(...)` — this just records the artifact hashes; the release starts in `Uploaded` state. A validator (anyone holding `VALIDATOR_ROLE`) calls `attachValidationResult(releaseId, passed, reportURI)` to flip the release to `Validated` or `Failed`. Once validated, the publisher calls `publishRelease(releaseId)` to make it the live release for that capsule. Publishing demotes the previous published release to `Superseded` and flips the app from `Draft` to `Listed` if this is its first publication.

**Why this matters.** The `AppTokenFactoryV2` will not let anyone create an app token unless the referenced `releaseId` exists, points at the same `capsuleId`, has status `Published`, and the caller is the registered `publisher`. The registry is the source of truth for that decision.

**Roles.** `DEFAULT_ADMIN_ROLE`, `UPGRADER_ROLE`, `PAUSER_ROLE`, `VALIDATOR_ROLE` granted to `admin` at init. Admin can revoke an app (terminal). Publisher or admin can revoke a release. Validator role attaches the validation result. Pauser pauses the contract (registration flows are `whenNotPaused`).

**Storage.** `_apps[capsuleId]`, `_releases[releaseId]`, plus index lists `_releaseIdsByCapsule[capsuleId]` and `_capsulesByPublisher[publisher]`. A `__gap[40]` reservation supports future fields.

**Caveats.** `initialize` reuses `AppMissing` as the "zero admin" revert reason, which reads strangely. `publishRelease` linearly scans the publisher's release list to find the previous published index — fine for normal volume, would need pagination if a single capsule produces hundreds of releases. The `publisherKeyHash` is opaque on-chain; cryptographic verification of the publisher's signing key is the off-chain validator's responsibility.

### `AppTokenFactory` (V1)  ·  `AppTokenFactory.sol`

**Live (proxy):** `0xa248f486fd838b315883026197cda96387f9e7dc`
**V1 implementation:** `0x06b6bb8f225e9c1c278f8a2b47fe768af9a7a4f8` (currently the active clone target — being replaced)

The V1 launchpad. UUPS-upgradeable. Each call to `createAppToken(LaunchParams)` deploys a new EIP-1167 minimal-proxy clone of `AppBondingToken`, initializes it with the publisher's `AppLink` (capsuleId, releaseId, manifestHash, packageHash, publisher), and records the per-publisher and per-capsule index. Validates that the capsule exists, that the caller is its publisher, that the release matches the capsule, and that the release is `Published` before allowing a launch.

V1 graduation is broken by design: the V1 `AppBondingToken` simply sets `graduated = true` and routes the entire ETH reserve to `FeeRouter` as a `GraduationFee`. There is no Uniswap pair created, no LP minted, and post-graduation `buy`/`sell` revert. Tokens minted under V1 effectively become un-tradeable once the bonding curve is exhausted.

> **PRODUCTION GATE — V1 LAUNCH PATH IS STILL LIVE ON CHAIN.** The factory proxy at `0xa248f486...` currently implements `AppTokenFactory` (V1) and exposes `createAppToken(LaunchParams)` to anyone willing to pay gas. Frontend gating (`CONFIG.GENERIC_LAUNCH_DISABLED = true`) hides the surface from our UI but does **not** stop a determined caller from invoking the function directly. As long as the factory has not been upgraded to `AppTokenFactoryV2` (or paused at the proxy level, or had `bondingTokenImpl` swapped to a revert-only contract, or had its admin moved to a Safe with a launch-block policy), a user could clone V1 and trap ETH. This is a real production risk, not a UI risk. It must be closed by the in-place UUPS upgrade described below — frontend gating alone is insufficient.

**This is why V2 exists.** V1 is preserved on-chain because zero clones have been launched against it (`platform/stats.total_tokens == 0`). The plan is to upgrade the factory in place to `AppTokenFactoryV2`, which retargets the clone to `AppBondingTokenV2`, hard-disables `createAppToken` (the V1 selector reverts `LaunchDisabled`), and replaces the public launch path with `createAppTokenV2` gated behind a `LAUNCH_ENABLED` flag that defaults false.

### `AppTokenFactoryV2`  ·  `AppTokenFactoryV2.sol`

**Status: Deployed, factory proxy upgraded, launch gate closed.** Implementation lives at [`0x58A167A94365B6294900A1e2A4229807DCbcdC09`](https://etherscan.io/address/0x58a167a94365b6294900a1e2a4229807dcbcdc09) (Etherscan source-verified). The live AppTokenFactory proxy at [`0xa248f486fD838B315883026197cda96387f9E7Dc`](https://etherscan.io/address/0xa248f486fd838b315883026197cda96387f9e7dc) was UUPS-upgraded to this implementation on 2026-05-07; `initializeV2(...)` was called in the same transaction. Verified live: `bondingTokenImplV2() == 0x16caCbC8…35Dc`, `weth() == 0xC02aaA39…56Cc2`, `uniV2Factory() == 0x5C69bEe7…aA6f`, `uniV2Router() == 0x7a250d56…488D`, `lpBurnTo() == 0x000…dEaD`, `launchEnabled() == false`. The V1 selector `createAppToken(LaunchParams)` on the live proxy now reverts `LaunchDisabled()` (selector `0x6cd08908`) — confirmed via direct `cast call` against mainnet.

**Storage layout.** V1's slots 0 through 9 (the `bondingTokenImpl`, `capsuleRegistry`, `feeRouter`, `launchFeeWei` scalars, the `_tokenForCapsule`, `_capsuleForToken`, `_info`, `_byPublisher`, `_allTokens` maps and array, plus the `__gap[40]` reservation) are preserved untouched. Six new V2 fields are appended afterwards: `bondingTokenImplV2`, `launchEnabled` (bool), and the four Uniswap-infra addresses `weth`, `uniV2Factory`, `uniV2Router`, `lpBurnTo`. A new `__gap_v2[34]` is reserved for further additions.

**Launch gate.** The V2 launch path is `createAppTokenV2(LaunchParamsV2)`. It refuses to do anything unless `launchEnabled` is `true`. By contract construction the flag defaults `false` and can only be flipped by `CONFIG_ROLE`. The legacy V1 path `createAppToken(LaunchParams)` is overridden to revert `LaunchDisabled` unconditionally — it is gone, not deprecated. Both behaviours are covered by tests.

**Validation order.** The launch path validates, in order: launch flag is true; V2 implementation pointer is set; Uniswap infra (WETH, factory, router, burn target) is set; `name` and `symbol` are non-empty; `graduationFeeBps` does not exceed `MAX_GRADUATION_FEE_BPS = 100`; the capsule exists in `CapsuleRegistry`; the caller is the capsule's registered publisher; the supplied `releaseId` belongs to that capsule and is in status `Published`; no token has already been launched for this capsule; the launch fee is satisfied. Only then does it clone the V2 implementation and initialize.

**Initialization is total.** The factory builds both the `AppLink` (capsule binding) and the `GraduationConfig` (graduation supply, LP reserve cap, trading fee bps, graduation fee bps, Uniswap infra, LP burn destination) and passes both into the clone's `initialize`. Per-clone variables are not configurable after init — there are no setters on the bonding token for any of them.

**Reinit.** A `reinitializer(2)` function `initializeV2(...)` exists for upgrading the live V1 proxy in place. It is gated by `CONFIG_ROLE` and refuses to run twice. It sets the V2 token impl pointer and the Uniswap infra; it deliberately does not flip `launchEnabled` true.

**Roles.** Same role layout as V1: `DEFAULT_ADMIN_ROLE`, `UPGRADER_ROLE`, `PAUSER_ROLE`, `CONFIG_ROLE`. `CONFIG_ROLE` is the gate for `setLaunchEnabled`, `setBondingTokenImplV2`, `setUniswapInfra`, plus the legacy V1 setters that still exist. `UPGRADER_ROLE` gates `_authorizeUpgrade`.

**Tests.** 18 tests prove every requirement individually — flag default, public-can't-launch-while-flag-false, V1 selector reverts, only publisher can launch, only validated published releases launch, one-token-per-capsule, factory init produces V2 with correct AppLink and GraduationConfig, infra-unset path reverts, V2-impl-unset reverts, name/symbol validation, fee-cap enforcement, pause behaviour, role-only setters, event emission. Plus three mainnet fork dry-runs that perform the full UUPS upgrade against the live proxy and execute end-to-end launch-buy-graduate.

### `AppBondingToken` (V1)  ·  `AppBondingToken.sol`

The deployed bonding-curve implementation that is V1's clone target. UUPS-style state, ERC20Upgradeable. Buys mint tokens at the cubic curve price (per `BondingCurveLib`); sells burn tokens and refund ETH from `_reserve` minus the trading fee. Once `totalSupply >= graduationSupply`, anyone can call `graduate()` — and that's where V1 falls over: the function pays the full reserve to `FeeRouter` as `GraduationFee`, sets `graduated = true`, and emits `Graduated`. No Uniswap pair exists; the post-graduation token is permanently illiquid.

This contract is left in source for completeness and to support storage-layout reasoning, but new launches must not target it.

### `AppBondingTokenV2`  ·  `AppBondingTokenV2.sol`

**Status: Deployed, source-verified, set as the live clone target.** Implementation lives at [`0x16caCbC81249c0A7d2d0271e77f0D05489AB35Dc`](https://etherscan.io/address/0x16cacbc81249c0a7d2d0271e77f0d05489ab35dc). Every clone produced by `AppTokenFactory.createAppTokenV2(...)` is an EIP-1167 minimal proxy that delegates to this implementation. Until `launchEnabled` is flipped true (currently false), no clones can be produced — but the path is wired end-to-end and verified by both unit tests and a full mainnet-fork dry-run that performs the upgrade against the live proxy and runs launch + buy + graduate to a real Uniswap V2 pair with LP burned at `0xdead`.

**Pre-graduation behaviour.** Identical to V1 from the user's perspective. `buy(minTokensOut)` accepts ETH, computes a cubic-curve quote via `BondingCurveLib.quoteBuy`, deducts the trading fee, mints tokens, and routes the fee to `FeeRouter` as `TradingFee`. `sell(tokensIn, minEthOut)` is the symmetric path. Both refuse to run if `graduated` is true, if the contract is paused, or if reentrancy is detected.

**Initialization.** The factory passes both an `AppLink` and a `GraduationConfig`. The token validates the config in `_validateInit`: every Uniswap address must be non-zero; `lpBurnTo` must be non-zero; `graduationSupply` must be non-zero; `tradingFeeBps` is bounded below the BPS denominator; `graduationFeeBps` is bounded by `MAX_GRADUATION_FEE_BPS = 100`. The most subtle check is the LP-reserve bound: the contract pre-computes the worst-case `tokensToLp` that graduation will need (assuming the curve is filled completely with no sells), and refuses to deploy if `lpReserveCap < maxNeeded`. In practice this means a publisher cannot configure a curve whose terminal price is incompatible with the LP allocation they declared.

**Graduation.** `graduate()` is `nonReentrant whenNotPaused`. It uses checks-effects-interactions: it sets `graduated = true` and zeros `_reserve` first, then takes the graduation fee and routes it through `FeeRouter` as `GraduationFee`, then computes the math-derived LP token amount as `reserveAfterFee * 1e18 / terminalPrice` (where `terminalPrice = priceAtSupply(graduationSupply)` — the curve price at the exact graduation supply), then calls `_ensureCleanPair()` to either create the Uniswap V2 pair or verify an existing pair is uncontaminated, mints exactly `tokensToLp` to itself, approves the V2 router for that exact amount, and calls `addLiquidityETH` with strict `amountTokenMin = tokensToLp`, `amountETHMin = reserveAfterFee`, `to = lpBurnTo` (which is `0xdead` in production), and `deadline = block.timestamp`. After the call, the contract asserts that the router consumed exactly the requested amounts (`LiquidityCreationFailed` otherwise), revokes the router approval, and verifies that no token or ETH residue remains in the contract (`PostGraduationStuckTokens` / `PostGraduationStuckEth`). Finally it emits `GraduatedToUniswap(pair, lpBurnTo, ethToLp, tokensToLp, lpMinted, fee, terminalPrice)` — every field a downstream verifier needs to prove the graduation was honest.

**Pair safety.** `_ensureCleanPair()` is the donation-attack guard. If `factory.getPair(this, weth)` returns the zero address, the contract creates the pair and emits `UniswapPairCreated`. If it returns a pre-existing pair, the contract reads the pair's reserves; if they are non-zero, it reverts `PairAlreadySeeded(reserve0, reserve1)`. Then — and this is the part that matters — it also checks `balanceOf(pair) == 0` for both this token and WETH. The Uniswap V2 first-mint formula uses `balanceOf(pair) - reserve` to compute the deposit, and an attacker who transfers tokens or WETH directly to the pair address before the mint can corrupt our LP and price. The dual-balance check refuses any pair where either side has been donated to. Two unit tests cover both donation vectors.

**Price continuity.** This is the entire reason for the math-derived LP amount. After `addLiquidityETH`, the V2 pair holds `reserveAfterFee` ETH and `tokensToLp` tokens. The Uniswap V2 spot price (in the same units used by `BondingCurveLib`) is `reserveAfterFee * 1e18 / tokensToLp`, which by construction equals `terminalPrice`. The first marginal trade after graduation prices the token at exactly the bonding curve's terminal price (modulo the V2 LP fee, which is bounded and known). There is no arbitrage gap on the first block. The fork test asserts `assertApproxEqAbs(spotPerToken, terminalPrice, 1)` — within one wei of rounding.

**Roles.** `DEFAULT_ADMIN_ROLE` and `PAUSER_ROLE` go to the publisher. `FACTORY_ROLE` goes to `msg.sender` (the factory). The publisher can pause and resume trading and declare an emergency. There is no admin upgrade path on the bonding token itself — clones are EIP-1167 minimal proxies pinned to the V2 implementation; upgrading would require the factory to retarget its `bondingTokenImplV2` for new clones.

**Tests.** 23 V2-side tests across two suites — 20 unit tests with mocked Uniswap (covering init validation, buy/sell, every graduation revert path, donation attack, idempotency, pause, fee accounting, price continuity) and 3 fork tests against real Uniswap V2 mainnet (full graduation cycle with real pair creation, real LP burn, real reserve verification).

**Slither.** One high-severity finding (`arbitrary-send-eth` on `addLiquidityETH`) is a documented false positive — `uniV2Router` is set once in `initialize` with no setter, so it is functionally immutable after init. The remaining mediums are math-precision warnings on `BondingCurveLib` (intentional cubic-curve precision) and three `unused-return` flags that are misclassifications. Full findings doc lives at `docs/security/SLITHER_AppBondingTokenV2_AppTokenFactoryV2.md`.

### `BondingCurveLib`  ·  `BondingCurveLib.sol`

The math kernel for the bonding-curve token. Pure library, no state, no external calls. Provides `reserveAtSupply(s)`, `priceAtSupply(s)`, `supplyAtReserve(r)`, `quoteBuy(currentSupply, graduationSupply, ethIn, feeBps)`, `quoteSell(currentSupply, tokenAmount, feeBps)`, and `graduationProgressBps(currentSupply, graduationSupply)`.

**Curve.** Cubic. With internal constants `CURVE_K = 1e10` and `SCALE = 1e16`, the relationships are:
- `reserve(s) = K * s³ / (3 * SCALE)` — total ETH paid in to mint up to supply `s` token-units (where one token-unit equals `1e18` raw)
- `price(s) = K * s² / SCALE` — marginal ETH price per token-unit at supply `s`, floored at `MIN_PRICE = 1e6` wei

Inverse `supplyAtReserve(r)` uses an integer cube root (`_icbrt`), bootstrapped by binary doubling and refined by a small fixed-point Newton loop. The implementation deliberately rounds down on the final step to avoid over-mint.

**Quotes.** `quoteBuy` deducts the fee from `ethIn` first, computes the new reserve, inverts to a new supply, caps at `graduationSupply`, and returns the supply delta as `tokensOut`. It refuses to mint less than one full token-unit (`AmountTooSmall`). `quoteSell` does the symmetric: compute the gross ETH out from the reserve delta, deduct the fee, return both pieces.

**Why this curve.** The cubic curve gives early-buyer convexity (price climbs slowly at the start, fast at the end) which is what app-token bonding curves want for fair early discovery. It is also exactly invertible enough to support both directions cheaply (no iteration in `reserveAtSupply` or `priceAtSupply`; one bounded loop in the inverse).

**Threat model.** Pure library, no roles. The math is the surface — `BondingCurveLib.t.sol` covers monotonicity, sell-never-exceeds-reserve, roundtrip-loses-proportional-to-fee, and zero-handling. Slither flags two `divide-before-multiply` instances inside the curve arithmetic; they are intentional and the precision loss is bounded to a few wei in the worst case.

---

## Marketplace revenue

### `FeeRouter`  ·  `FeeRouter.sol`

**Live (proxy):** `0x0d0dd1d8d2940ed4c1cf05635722528def612559`

Every revenue-bearing flow in the marketplace funnels through here. UUPS-upgradeable. Splits incoming ETH or ERC-20 four ways — publisher, NFT-holders sink, stakers sink, treasury sink — according to a `SplitProfile` configured per `RevenueSource`. Profiles must always sum to exactly `10000` bps; the contract refuses to set anything else.

**Sources.** The enum `RevenueSource` has seven members: `AppPurchase`, `Subscription`, `PayPerUse`, `TradingFee`, `GraduationFee`, `TokenLaunch`, `ValidationFee`. Each is independently configurable. Defaults at deploy bias publisher-heavy on the user-facing flows (App purchases give 70% to the publisher) and bias more toward stakers/treasury on protocol-side flows (TradingFee gives 5% to publisher, 40% to NFT holders, 35% to stakers, 20% to treasury).

**Routing.** `routeETH(source, capsuleId, publisher) payable` and `routeERC20(source, capsuleId, publisher, token, amount)` are both **permissionless** by design — the caller pays for the routing, so anyone can credit a capsule with revenue using their own funds. The contract pulls (for ERC-20) or accepts (for ETH), splits via integer math, and forwards each share via `_safeETH` (raw `call` reverting on failure) or `safeTransfer`. Bookkeeping increments `_capsuleRevenue[capsuleId][asset]` and `_publisherRevenue[publisher][asset]`.

**Why permissionless routing is safe.** The permissionless surface only credits accounting variables and forwards funds the caller actually supplied. There is no path where a third party can draw from contract balances or shift funds away from sinks. The risk is purely an analytics one: anyone can pollute the per-capsule cumulative number by routing arbitrary capsule IDs. Off-chain consumers should treat these maps as upper bounds on legitimate revenue, not as authoritative.

**Roles.** `DEFAULT_ADMIN_ROLE`, `UPGRADER_ROLE`, `PAUSER_ROLE`, `CONFIG_ROLE`, `TREASURY_ROLE`. `CONFIG_ROLE` configures profiles and sinks. `TREASURY_ROLE` holds the emergency-withdraw escape hatch (rarely needed since funds normally pass through, but `receive()` accepts arbitrary ETH that becomes admin-recoverable).

**Caveats.** A `ROUTER_CALLER` role is declared but never enforced — dead code. The `emergencyWithdraw*` paths are powerful and should move to Safe before any real flow runs through this contract.

### `FeeSwapRouter`  ·  `FeeSwapRouter.sol`

**Live (proxy):** `0x09d4fDb7176ef0E20Af558e650d2dcd8D1f73d62`

The protocol-fee dispatcher for swaps. Wraps an underlying swap (typically Uniswap V2) so that the protocol can charge a small fee on the input asset before forwarding the rest to the actual swap target. UUPS-upgradeable. Hard-capped at `MAX_FEE_BPS = 100` (1.00%).

**The single-popup model.** The user signs one transaction. `swap(SwapParams)` accepts: the input token (zero address means ETH), the input amount, the target swap contract, the calldata to invoke on it, the output token, the user's `minOut` for the output, the receiver, and a route ID for analytics. The contract validates that `target` is on the allowlist (`approvedTarget[target] == true`, or — if an `appTokenFactory` is wired — that `IAppTokenFactoryLite(factory).isAppToken(target)` returns true). It collects the fee, forwards the rest to the target with the user's calldata, measures the receiver's balance delta, and reverts `InsufficientOutput(received, minOut)` if slippage exceeds the user's bound.

**Fee-on-transfer awareness.** When the input is an ERC-20, the contract uses `balanceOf(this)` deltas before and after the `safeTransferFrom` call to compute the actual amount received, then takes the fee on `actual` — not on the nominal `amountIn`. This handles fee-on-transfer input tokens (including NOX itself) correctly without overcharging or stranding tokens.

**Allowance hygiene.** Every ERC-20 swap path calls `forceApprove(target, 0)` before and after the target call. There is never standing allowance held against a third party.

**Leftover refund.** If anything is left over — leftover ETH because the target didn't consume the full `value`, or leftover input tokens because the target took less than approved — the contract refunds it to `msg.sender`. The post-call self-balance assertion enforces this. This is what makes the fee-on-transfer math safe even when the target's behaviour is conservative.

**Live state.** On mainnet today: `feeBps = 10` (0.10%), `paused = false`, fee recipient is the B33 admin wallet (temporary, will rotate to Safe), the V2 Uniswap router is approved as a target, and the AppTokenFactory address is wired so future app-token swap targets auto-allowlist.

**Roles.** Three roles, deliberately separated at init: `CONFIG_ROLE` (fee parameters, target allowlist, factory wiring, rescue), `PAUSER_ROLE` (the `paused` flag — note: this is a custom bool, not OZ `PausableUpgradeable`), `UPGRADER_ROLE`.

**Threat model.** Fee cannot exceed 100 bps (enforced both in `initialize` and `setFeeBps`). Approved targets are an explicit allowlist or a factory-attested check; arbitrary calldata into arbitrary contracts is impossible. Output is measured at the receiver address, so a malicious target that returns success without delivering tokens still trips `InsufficientOutput`. `nonReentrant` on `swap`. `paused` for kill-switch.

### `FeeSwapErrors` & `FeeSwapEvents`

Tiny abstract contracts inherited by `FeeSwapRouter`. They factor out the custom error definitions and event signatures so the router's source stays focused on logic. Errors include `FeeExceedsCap`, `ZeroFeeRecipient`, `ZeroAddress`, `ZeroAmount`, `PausedError`, `TargetNotApproved(address)`, `NotPayable`, `InsufficientOutput(uint256, uint256)`, `SwapFailed(bytes)`. Events include `ProtocolFeeCollected(asset, payer, recipient, amount)` (the on-chain proof a user can verify), `SwapExecuted(routeId, payer, receiver, inputAsset, outputAsset, amountIn, amountInAfterFee, amountOut)`, `LeftoverRefunded(asset, to, amount)`, plus the configuration events.

---

## Marketplace entitlement

### `EntitlementRegistry`  ·  `EntitlementRegistry.sol`

**Live (proxy):** `0xb821d04f1fd49851e3adc89505e10241f8a01a4c`

Per-capsule access policy. UUPS-upgradeable. Each capsule has at most one `AccessConfig`, set by the publisher (or admin), describing how users obtain entitlements for that capsule.

**Modes.** Nine of them. `Free` lets anyone in. `OneTimeNOX` charges a fixed NOX price for a permanent entitlement. `Subscription` charges a fixed NOX price for a time-bounded entitlement that re-stacks on re-purchase. `Trial` grants a one-time time-bounded entitlement per user, no payment. `TokenHolder` and `NFTGated` defer the check to a balance lookup against an external contract. `PublisherGrant` is a manual entry by the publisher. `Revoked` is the terminal blocked state. `Unconfigured` is the default.

**Purchase.** `purchase(capsuleId)` is the paid path. It pulls `priceNoxWei` of NOX via `safeTransferFrom`, then calls `feeRouter.routeERC20(...)` with the appropriate `RevenueSource` (either `AppPurchase` or `Subscription`). Subscription expiry stacks on top of any existing expiry — re-purchasing before the current term ends extends from the existing expiry, not from now.

**Trials.** `claimTrial(capsuleId)` is one-shot per user per capsule and rejects subsequent attempts with `AlreadyClaimed`.

**Gating modes.** `hasEntitlement(capsuleId, user)` is the read-side check. It returns true if the configured mode is `Free`, OR the user satisfies a `TokenHolder` / `NFTGated` balance condition, OR the user has a non-revoked entitlement record with either no expiry or an expiry in the future. The `revoked` flag is checked first; admin or publisher can revoke any user's entitlement and the read side honours it immediately.

**Roles.** Standard four (admin, upgrader, pauser, config) plus the `onlyPublisherOrAdmin(capsuleId)` modifier that gates configuration, grants, and revocations against the live publisher record in `CapsuleRegistry`.

**Caveats.** `AppTokenFactory` is stored in the contract but never called — reserved for future per-app-token gating. `grantEntitlement` overwrites any prior entitlement for the user, including a paid subscription with remaining time, which is a footgun for publishers.

### `ReceiptSettlement`  ·  `ReceiptSettlement.sol`

**Live (proxy):** `0x1b522b9d62986f4ad0e7e881bad464b6e7e37317`

Off-chain "pay-per-use" receipts settled on-chain in batches. UUPS-upgradeable. Each receipt is an EIP-712 typed message signed by the user authorising a publisher to charge them `amountNox` for one unit of usage of a capsule. A relayer or anyone collects a batch and submits them via `batchSettle`, which iterates and pulls NOX from each user, routing through `FeeRouter` as `PayPerUse`.

**Replay protection.** Each receipt's hash is recorded in `_used` once successfully settled. The hash is the EIP-712 struct hash, so any change to any field (including `nonce`) produces a new hash. A receipt can only settle once.

**Validity window.** A receipt's `epoch` field must equal `currentEpoch` or `currentEpoch - 1` (one-epoch grace). On top of that, an optional `expiry` timestamp can be set — if non-zero and in the past, the receipt is rejected. Epoch zero is fixed at deploy time and not changeable; epoch duration is `CONFIG_ROLE`-tunable, but operators must coordinate epoch rollovers carefully because changing duration retroactively shifts epoch numbering.

**Soft failures.** `_settleOne` does not revert on individual bad receipts. It returns `(success, hash)` and emits `ReceiptRejected(hash, capsuleId, reason)` for any of: replay, zero-amount, expired, wrong-epoch, wrong-signer (the recovered signer doesn't match the receipt's `user` field), or wrong-publisher (the receipt's `publisher` field doesn't match `capsuleRegistry.publisherOf(capsuleId)`). The batch as a whole only reverts if it is empty (`EmptyBatch`).

**Settlement.** On success: mark `_used[h] = true`, pull NOX from the user via `safeTransferFrom`, `forceApprove` the FeeRouter for the exact amount, call `feeRouter.routeERC20(PayPerUse, capsuleId, publisher, noxToken, amount)`. Because `_settleOne` runs inside a single transaction (the batch's external call wrapper) and `safeTransferFrom` reverts on failure, the `_used` flag and the route are atomic — a failed transfer means the receipt remains reusable.

**Threat model.** The signer-must-equal-user check uses OZ's `ECDSA.recover` which rejects malleable `s` and zero-address recoveries. The publisher-binding check prevents redirected settlement. The replay set + epoch window + explicit expiry compose to a tight validity envelope. Roles are standard.

---

## Interfaces

The `contracts/marketplace/interfaces/` directory holds the type-safe surface for every concrete contract above, plus a couple of import-only interfaces. The interfaces are deliberately small and mirror the ABI consumers depend on. None of them carry behaviour — they exist so external integrations and other in-repo contracts compile against a stable surface even when implementations evolve.

The notable ones, beyond direct mirrors of the contracts already documented:

- **`IUniswapV2.sol`** — `IUniswapV2Factory`, `IUniswapV2Pair`, `IUniswapV2Router02` minimal slices. Used by `AppBondingTokenV2` and the V2 fork tests.
- **`IZeroStateRewardPool.sol`** — interface stub for a future ZeroState NFT reward pool (the destination of `nftHoldersSink` in `FeeRouter`). Implementation is not in this repo yet.
- **`IFeeSwapRouter.sol`** — public type definitions (the `SwapParams` struct, the `IAppTokenFactoryLite.isAppToken` check) used by both the router and external callers.

The bridge layer also has a tiny `contracts/bridge/interfaces/` with locally-shadowed `IERC20` and `IERC721` to avoid dragging the OpenZeppelin path into the bridge build.

---

## Cross-cutting concerns

### Admin posture today

Every live deployment currently controlled by B33 — that is, the NOX token, the bridge, and every marketplace proxy listed in `docs/DEPLOYMENTS.md` — grants every privileged role to a single EOA, the B33 wallet at `0xa12eCf0CDfC9D53FFafbdef43696cE615E662B33`. That wallet holds `DEFAULT_ADMIN_ROLE`, `UPGRADER_ROLE`, `PAUSER_ROLE`, `CONFIG_ROLE`, `VALIDATOR_ROLE`, `TREASURY_ROLE` across the marketplace, the bridge, and the token. It is also the validator-side sender for the bridge and the protocol-fee recipient on `FeeSwapRouter`. This is documented in `docs/security/SECURITY.md` and in `docs/DEPLOYMENTS.md`. It is the explicit, disclosed cost of shipping the contracts before the Safe is configured.

App-token clones produced by the factory are a separate role universe: each clone grants `DEFAULT_ADMIN_ROLE` and `PAUSER_ROLE` to the publisher of that capsule, and `FACTORY_ROLE` to the factory itself. B33 has no role on individual app-token clones unless the publisher of that capsule happens to be B33.

`script/FinalizeMarketplace.s.sol` exists and is the one-shot rotation: it grants every role to a Safe address per role family (admin, config, pauser, upgrader, treasury) and then revokes B33 from each. After Finalize runs against a real Safe address, B33 holds none of them.

### Upgradability posture

Every contract that holds state across releases is UUPS-upgradeable, with `UPGRADER_ROLE` gating `_authorizeUpgrade`. There is no on-chain timelock at the contract layer — the operational hardening is to put the upgrader role on a Safe with a multisig threshold and an off-chain timelock (Defender, Gnosis Zodiac, etc). Storage layouts use `__gap` reservations consistent with the OpenZeppelin upgrade pattern. The factory V2 explicitly preserves V1's slots and appends new state after the gap; the bonding token V2 is greenfield (the V1 implementation is not being upgraded — the factory is being retargeted to a fresh V2 implementation).

The only contract that uses EIP-1167 minimal proxies (and therefore is not UUPS-upgradeable per-instance) is `AppBondingToken{V1,V2}`. Each app token is a fresh clone of whatever implementation the factory currently points at; once cloned, that clone's behaviour is fixed for life. This is intentional — app tokens should be predictable assets, not upgradable surfaces.

### Reentrancy

Every public/external state-changing function on the bonding token, factory, fee router, fee swap router, entitlement registry, and receipt settlement carries `nonReentrant`. The bridge contracts use a custom `_reentrancyStatus` ladder. The auto-swap path in the NOX token uses an `_inSwap` lock to break the Uniswap callback recursion loop. The graduation path in `AppBondingTokenV2` uses checks-effects-interactions at the function level (the `graduated` flag is set before any external call) on top of `nonReentrant`.

### Reading the deployment posture

`docs/DEPLOYMENTS.md` is the canonical reference for every live mainnet address, including the deploy-time tx hashes. `docs/security/review.md` is the per-finding rationale for the Slither runs we have completed. `docs/security/SLITHER_AppBondingTokenV2_AppTokenFactoryV2.md` is the V2-specific findings doc with action status per item.

### What this repo does not yet contain

The OS-side `capsule_market` userland program for NØNOS is not part of this repository; it lives in the kernel/runtime tree. Its production-readiness gate is described in `docs/CONTRACT_REFERENCE.md` neighbours and not gated by anything here. The signed marketplace index served at `/api/v1/marketplace/index` is likewise a backend concern, not a Solidity one — but the OS's verification of that signature against a pinned operator key is what closes the loop between this on-chain layer and the runtime.

The review treats every gate the user has stated as binding: V1 graduation must not be accessible publicly, the V2 path must be the only launch path with `LAUNCH_ENABLED=false` until fork dry-run is green and Safe rotation is complete or explicitly disclosed, and no contract claims more than the test-and-deploy state actually proves. Status reports in this document use the labels Live / Code-complete / Admin-gated / Queued in line with the production readiness spec.

### Production-ready posture (binding)

The marketplace is **not** production-ready as a whole until **all** of the following are true:

- `AppBondingTokenV2` and `AppTokenFactoryV2` are deployed to mainnet and source-verified on Etherscan.
- The factory proxy at `0xa248f486...` has been UUPS-upgraded to `AppTokenFactoryV2` via `initializeV2(...)`, with `bondingTokenImplV2`, `weth`, `uniV2Factory`, `uniV2Router`, `lpBurnTo` set to canonical mainnet addresses.
- `launchEnabled` on the upgraded factory is verified `false` immediately after the upgrade transaction.
- The frontend reads `launchEnabled()` and `isGraduated(token)` from chain (not from a backend or config flag) before exposing any launch or post-graduation trade UI.
- A final fork dry-run against the deployed addresses (not impl-only addresses) reproduces full launch + buy + graduate + LP burn at `0xdead`.
- Admin/upgrader/config roles on every contract listed above have moved to a Safe (or, if any role is intentionally retained on B33 for an explicit operational reason, that retention is disclosed in this document with a date).
- Public copy is reviewed and matches chain truth — no "audited", no "fully production ready", no "app launch live" until the previous bullets are green.
- Only after every gate above is green does anyone call `setLaunchEnabled(true)` on the factory, and that call requires explicit human sign-off.

Until that whole chain closes, public-facing copy must say: bridge live, swap live for wired routes only, marketplace contracts deployed/source-verified, capsule marketplace in preparation, app-token launch not live.

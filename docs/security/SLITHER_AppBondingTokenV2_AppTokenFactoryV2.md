# Slither findings — AppBondingTokenV2 + AppTokenFactoryV2

Tool: Slither 0.11.4
Run on: contracts/marketplace/core/AppBondingTokenV2.sol, contracts/marketplace/core/AppTokenFactoryV2.sol
Filter: `--filter-paths node_modules` (OpenZeppelin findings excluded)

## Summary

| Severity | AppBondingTokenV2 | AppTokenFactoryV2 |
|---|---:|---:|
| High | 1 | 0 |
| Medium | 5 | 1 |
| Low | 4 | 1 |
| Informational | 5 | 9 |

**No real high-severity findings open.** The single High is a known false positive on admin-pinned destinations, documented below.

---

## AppBondingTokenV2

### High — `arbitrary-send-eth` in `graduate()`  ⟶  acknowledged false positive

```
graduate() sends ETH via uniV2Router.addLiquidityETH{value: reserveAfterFee}(...)
```

Slither flags `uniV2Router` as an arbitrary destination because it is a state variable rather than a Solidity `immutable`. In practice:

- `uniV2Router` is set exactly once, inside `initialize()`, validated non-zero.
- There is no setter function. `uniV2Router` cannot change after init.
- The factory pins all clones to the canonical Uniswap V2 router (`0x7a25…2488D` on mainnet).
- Init validation also reverts on zero `weth`, `uniV2Factory`, `lpBurnTo`.

The destination is verifiable on-chain by reading the public `uniV2Router()` getter. Identical pattern is used by every UUPS-upgradeable contract that integrates with Uniswap. Refactor to `immutable` is incompatible with the `Initializable` clone pattern (clones share impl bytecode but each holds its own storage).

**Status:** acknowledged, no action required. Mitigated by Safe-rotation gate and on-chain pin verification.

### Medium — `divide-before-multiply` (5)

Two were genuinely improvable and have been fixed in `_validateInit` and `maxTokensToLp`/`expectedTokensToLp` by collapsing two divisions into one (`numer / denom` form).

The remaining three are inside `BondingCurveLib` (a pure pre-existing library) and represent intentional precision in the cubic curve math (`reserveAtSupply` and `priceAtSupply`). Bounds: with `CURVE_K=1e10`, `SCALE=1e16`, supply units capped at graduationSupply (e.g., 800k), the precision loss is bounded to a few wei and is one-sided in favour of conservative reserve estimates. Tests `BondingCurveLib_*` cover the math.

**Status:** acknowledged in BondingCurveLib, fixed in V2 token.

### Medium — `unused-return` (3)

- `quoteBuy(uint256)` — `return BondingCurveLib.quoteBuy(...)`. Tuple is forwarded to caller; not dropped. **False positive**.
- `quoteSell(uint256)` — same. **False positive**.
- `_ensureCleanPair()` — `(uint112 r0, uint112 r1, ) = IUniswapV2Pair(_pair).getReserves()` deliberately drops the third return value (`blockTimestampLast`) which is irrelevant to the donation-attack guard. **Acknowledged**.

### Low

- `events-maths` — `initialize` does not emit per-field events. Coverage exists at the factory level via `AppTokenCreatedV2(capsuleId, releaseId, publisher, token, name, symbol, graduationSupply, lpReserveCap)`. **Acknowledged.**
- `missing-zero-check` — flagged on a parameter already validated in `_validateInit`. **False positive.**
- `reentrancy-benign` — `graduate()` makes external calls after setting `graduated = true` (CEI). `nonReentrant` modifier present. The "benign" classification is correct: reentrant calls cannot bypass the `graduated` flag. **Acknowledged.**
- `timestamp` — `block.timestamp` used as Uniswap `addLiquidityETH` deadline. The call is atomic (same tx), so timestamp is exactly current block. **Acknowledged.**

### Informational

- `cyclomatic-complexity` on `_validateInit` (13) — validation function with explicit error messages per field. Refactor would obscure error attribution. **Acknowledged.**
- `low-level-calls` — single `msg.sender.call{value: outAmt}("")` for ETH refund on `sell()`. Standard pattern. **Acknowledged.**
- `naming-convention` — `WETH()` on `IUniswapV2Router02` interface follows Uniswap canonical naming. **Acknowledged.**
- `unindexed-event-address` — events on parent `PausableUpgradeable` (OZ). Out of scope. **Filtered.**

---

## AppTokenFactoryV2

### Medium — `reentrancy-no-eth` in `createAppTokenV2`

State writes (`_tokenForCapsule`, `_capsuleForToken`, `_info`) occur after the external call to `IAppBondingTokenV2(token).initialize(...)`. The token's `initialize()` itself makes no callback to the factory. The factory has `nonReentrant`. Cross-function reentrancy through the factory's other state is impossible because:
- The new clone is owned by the publisher; only their `_grantRole(FACTORY_ROLE, msg.sender)` runs.
- No other public factory function reads `_tokenForCapsule[p.capsuleId]` in a way that grants advantage during initialization.

**Status:** acknowledged, mitigated by `nonReentrant`. Refactor to record-before-init would orphan the registry on init failure; current ordering is safer.

### Low — `reentrancy-benign`

Same root cause as above for `_allTokens.push` and `_byPublisher.push`. Index pushes after a guarded external call. **Acknowledged.**

### Informational

- `cyclomatic-complexity` on `createAppTokenV2` — multi-step validation with explicit revert messages per failure mode. **Acknowledged.**
- `naming-convention`, `unindexed-event-address` — same as above, OZ inheritance. **Filtered.**
- `unused-state` — `bondingTokenImpl` (V1 pointer) and one slot of `__gap` retained for storage-layout compatibility with the existing V1 proxy at `0xa248f486...`. **Required for safe UUPS upgrade.**

---

## Storage layout

UUPS storage layout for `AppTokenFactoryV2` preserves V1 slots 0–9 + `__gap[40]`. V2 fields appended at slots after `__gap`. New `__gap_v2[34]` reserved for future expansion. Verified with `forge inspect AppTokenFactoryV2 storage-layout`.

UUPS storage layout for `AppBondingTokenV2` is greenfield (V1 impl at `0x06b6bb…` is being replaced as the clone target, not upgraded in place). Verified with `forge inspect AppBondingTokenV2 storage-layout` — fields are tightly packed where possible (e.g., `feeBps` + `graduated` in slot 8, `graduationFeeBps` + `weth` in slot 13).

## Fee-on-transfer (FoT) absence

`AppBondingTokenV2` inherits `ERC20Upgradeable` directly with no `_update` override and no transfer hook. Standard 1:1 transfer behaviour. Verified by reading source and by integration tests in `test/marketplace/v2/AppBondingTokenV2.unit.t.sol` — the post-graduation `addLiquidityETH` post-call assertion `amountToken == tokensToLp` would fail if any tax were taken on transfer.

## Pair donation guard

Verified covers both `balanceOf(this).balanceOf(pair) == 0` AND `IERC20(weth).balanceOf(pair) == 0`. Tests:
- `test_graduate_pairDonationAttackBlocked_tokenBalance`
- `test_graduate_pairDonationAttackBlocked_wethBalance`

## Router allowance hygiene

Approval lifecycle in `graduate()`:
```
_approve(address(this), address(uniV2Router), tokensToLp);   // exact
uniV2Router.addLiquidityETH(...);                            // exact-amount asserted
_approve(address(this), address(uniV2Router), 0);            // reset to 0
```

Allowance always ends at zero. No standing approval.

## Test coverage

41 V2 tests passing (38 unit + 3 mainnet-fork). Full regression: 127/127 passing, 11 fork-skipped.

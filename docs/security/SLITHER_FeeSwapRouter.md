# FeeSwapRouter · Slither Findings

Run: `slither contracts/v2/revenue/FeeSwapRouter.sol --solc-remaps "@openzeppelin/=node_modules/@openzeppelin/" --filter-paths "node_modules|test|deprecated"`

| # | Detector | Location | Verdict | Reason |
|---|---|---|---|---|
| 1 | arbitrary-send-eth | `_takeFeeNative` → `feeRecipient.call{value}` | accepted | `feeRecipient` is set by `CONFIG_ROLE` only; never user-supplied. Reverts on call fail. |
| 2 | arbitrary-send-eth | `rescueETH` → `to.call{value}` | accepted | Function is `onlyRole(CONFIG_ROLE) nonReentrant`. Caller is the Safe; `to` is whatever the Safe signs. |
| 3 | arbitrary-send-eth | `_doSwap` → `target.call{value}` | accepted | `target` must pass `isApprovedTarget()` allowlist before reaching this line; cannot be arbitrary. |
| 4 | arbitrary-send-eth | `_doSwap` → `msg.sender.call{value}` (leftover refund) | accepted | Recipient is `msg.sender` — the original payer. Refunds their own ETH. |
| 5 | missing-zero-check | `setAppTokenFactory(address)` | accepted | `address(0)` is a valid input — it disables the dynamic factory lookup so only the manual `approvedTarget` map is consulted. Documented behaviour. |
| 6 | reentrancy-events | `rescueETH` (event after external call) | mitigated | Event reordered before the call. Function also has `nonReentrant`. |
| 7 | reentrancy-events | `rescueERC20` (event after external call) | mitigated | Event reordered before the call. Function also has `nonReentrant`. |
| 8 | low-level-calls | `rescueETH` | accepted | `.call{value}` is the canonical safe pattern for native ETH transfer (handles non-contract recipients without forcing 2300 gas). |
| 9 | low-level-calls | `_takeFeeNative` | accepted | Same. |
| 10 | low-level-calls | `_doSwap` (target call + refund) | accepted | The `target.call(p.data)` is the entire purpose of this contract — wrap arbitrary swap calldata atomically with fee deduction. The arbitrary-call surface is gated by `isApprovedTarget()`. |
| 11 | naming-convention | `IFeeSwapRouter.MAX_FEE_BPS()` | accepted | Constant getter; SCREAMING_SNAKE_CASE matches the implementation constant it exposes. Slither's mixedCase rule does not apply to public constants. |
| 12 | unindexed-event-address | `ERC1967Utils.AdminChanged` | upstream | OpenZeppelin event, out of scope. |

## Defense-in-depth applied

- `nonReentrant` added to `rescueETH` and `rescueERC20` (originally only on `swap`).
- All `emit` statements moved before external calls in rescue path (checks-effects-interactions).
- `feeRecipient` cannot be `address(0)`: enforced at `initialize` and `setFeeRecipient`.
- `feeBps` capped at `MAX_FEE_BPS = 100` (1%); enforced at `initialize` and `setFeeBps`.
- `target` must be in `approvedTarget` map OR pass `IAppTokenFactory.isAppToken()` lookup; the factory call is itself wrapped in try/catch with a code-length precheck so a non-contract factory address cannot revert the swap path.

## Items deliberately not ruled "high severity" by us

The arbitrary-send-eth findings would be critical in a contract where the destination is set by an unknown caller. Here, every destination is one of:

1. The protocol's own `feeRecipient` (Safe-rotated, never user-supplied).
2. A target router that has been explicitly allowlisted by the Safe or that the AppTokenFactory recognises as a valid AppBondingToken clone.
3. The original `msg.sender` receiving back unspent input.

This is the core trust contract of the design and is documented in `FeeSwapRouter.sol` itself.

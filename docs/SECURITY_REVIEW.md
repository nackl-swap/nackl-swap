# Security Review — Phase 1 contracts (self-review)

Reviewer: Claude (assistant). Date: 2026-09-29. Scope: `contracts/AtomicSwap.sol`, `contracts/SwapFactory.sol`
as of Phase 1 run 4 (34/34 on Shellnet). **This is not an independent audit.** An external review is
still required before mainnet.

Method: line-by-line read against invariants I1–I6 and the Acki Nacki behaviours found on Shellnet
(action-phase failures abort without bounce; failed constructors leave code installed; flag-16 SHELL is
listed in `msg.currencies` but converted to gas; getters cannot use DApp-context instructions).

## Findings

| # | Severity | Finding | Status |
|---|---|---|---|
| F1 | Medium | **Gas griefing via create/reclaim churn.** Each lot receives `LOT_GAS` (0.3 vmshell) that is never recovered, since lots never close. A maker with 1,000 NACKL can loop create→reclaim, costing the protocol ≈ 0.3 SHELL per cycle for only their wallet's message fees. 120 SHELL of credit ≈ 400 cycles. | Fixed: `close()` — verified run 5 (≈ 91% of lot gas returned) |
| F2 | Medium | **Factory can strand a maker's coins when low on gas.** Deploying a lot needs `LOT_GAS`. If the factory's native balance is short, the deploy fails in the action phase, which aborts without a bounce, leaving the maker's coins in the factory. | Fixed: pre-accept gas check (not triggered in tests) |
| F3 | Low–Med | **Unexpected currencies are stranded.** Currencies attached beyond the expected one (to `createLot`, `take`, `reclaim`, `claim`) stay in the contract permanently, and in the factory they are not in `_held`, so they are unrecoverable and can weaken the arrival check. | Fixed: exact-currency checks — verified run 5 (T9, T10) |
| F4 | Low | **Expired lots depend on the maker.** Only the maker can release an open lot's coins, even after the deadline. A lost or inattentive maker leaves the lot open indefinitely. | Fixed: permissionless `reclaim()` after deadline, paying the recorded maker — verified run 5 (T7b) |
| F5 | Info | Want-currency donated to an open lot (non-bounceable transfer) can satisfy the arrival check for a flag-16 payer, whose converted gas then stays in the lot. No one loses funds. | Accepted |
| F6 | Info | When DappConfig credit is exhausted, `mintshellq` silently does nothing. `take()` then refuses safely (coins bounce) once lot gas < `PAYOUT_GAS`; reclaim/claim carry no coins so cannot strand. Needs monitoring. | Ops |
| F7 | Info | A self-destructing lot must not be destroyed while a payout could still bounce back (a bounce to a deleted account is lost). | Designed into `close()` delay |

## Phase 2a additions (2026-09-30): pay-to-take and no-wallet keepers

| # | Severity | Finding | Status |
|---|---|---|---|
| F8 | High | **Refused non-bounceable messages strand coins** (spike 6 C8). Any failing `require` on a non-bounceable call carrying coins (to a lot or `createLot`) left them in the contract, outside every ledger. Plain wallet transfers may well be non-bounceable. | Fixed: `_refused()` reads the bounce bit; non-bounceable + coins → accept and refund only coins that arrived and belong to no one else (give side of an open lot, `_owedTotal`, factory `_held` are excluded). Tests P3, P5, P6, P8, P9 |
| F9 | Medium | **Non-bounceable flag-16 SHELL is unrecoverable** (spike 6 C10): converted to gas on arrival, and native value does not cross DApps. No contract can return it. | Accepted (limit of the chain). The lot stays intact (P7). The web app must tell users to send SHELL as SHELL, and the mainnet probe must learn what the wallet app sends |
| F10 | Medium | **Owed payouts could loop.** With permissionless `release()`, a wallet that always rejects would bounce each attempt back, letting anyone drain lot gas. | Fixed: owed payouts and refunds are sent `bounce: false`; a refusing wallet keeps them in its own account (P11). They can never return and be booked twice |
| F11 | Low | Keeper functions (reclaim after deadline, `close`, `release`) accept unsigned external messages. Failing ones are refused before `tvm.accept()`, so they cost nothing; successful ones are one-shot (state checks) and protected by the default `time`-header replay check. | By design |
| F13 | High | **Factory ledger inflated by flag-16 SHELL (found by the web-app demo, 2026-09-30).** `receive()` added the *listed* `msg.currencies` to `_held`, but flag-16 SHELL is listed and converted to gas (spike 6 C4). `_held[SHELL]` then exceeded the real balance, and every SHELL-giving `createLot` failed with 106 NOT_ARRIVED (coins bounced; nothing lost). **Anyone could block all SHELL-for-NACKL lots with one 1-SHELL flag-16 transfer.** | Fixed: `receive()` counts only what arrived (`min(listed, balance − _held)`); `getHeld()` added. Test P13 + final ledger == balance check |
| F12 | Low | `release(owner)` picks the owner's DApp id from recorded roles (maker, taker, else treasury's). For pay-to-take takers the recorded DApp is ours; delivery relies on routing by account id (T8, spike 6 C6). | Accepted; covered by P1, P11 |

## Fix design

- **`close()`** (AtomicSwap, permissionless): requires state ≠ OPEN, `block.timestamp ≥ settledAt + closeDelay`,
  and zero give/want balance (so nothing is owed: owed coins are held by the lot). Sends all remaining
  balance to the factory with flag 128 + 32 (carry all, destroy). `closeDelay` is set per factory at
  deploy (minimum 60 s; tests use 60 s, production should use ≥ 600 s). Bounces arrive within seconds.
- **Factory gas check**: `createLot` requires `address(this).balance ≥ LOT_GAS + DEPLOY_MARGIN` before
  `tvm.accept()`, so a short factory refuses (bounce) instead of stranding.
- **Exact currencies**: `take` accepts only the want currency; `createLot` only the give currency;
  `reclaim`, `claim`, `close` accept none. All checked before `tvm.accept()`.
- **Permissionless reclaim after deadline**: `reclaim()` allowed if caller is the maker, or the deadline
  has passed. Payout always to the recorded maker.

## Not changed (deliberate)

- Lots have no admin and no upgrade path (I6).
- Factory owner powers remain limited to spending `_held` (funding/fees) via `sendTransaction`.
- A cancel/listing fee is not added now; `close()` removes most of F1's cost. Revisit if churn appears.

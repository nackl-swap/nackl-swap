# Phase 1 Results — AtomicSwap (FIXED)

## Run 1 — 2026-09-29 — 7 passed, 23 failed (test harness bug, contracts not exercised)

Log: `out/phase1.log` (overwritten by later runs).
Factory `e4f3eade…0b8e`; maker wallet `4da880cc…e9d5`; taker wallet `849b5a54…5713`.

**Root cause:** `SwapFactory.getInfo()` called `gosh.getavailablebalance()` and `address(this).dapp_id`.
Local `tvm-cli run` has no DApp context, so the getter failed with
`exit code -36 (DApp ID is not set)`. The script read an empty lot count, derived an all-zero lot
address, and every take/reclaim/read went to a non-existent account (all bounced back).

What actually happened on chain:
- `createLot` worked 7 times: the maker's 8,000 NACKL sits in 7 open, untouched lots under the old
  factory (recoverable by the maker with `reclaim`). Test funds only.
- Every take bounced from the empty address, so the taker kept all 1,000 SHELL. The PASSes on
  "SHELL returned" were coincidences of that bounce.
- **T8 is valid:** a transfer with the **wrong** `dest_dapp_id` (the factory's) still reached the
  taker's existing wallet (+1 NACKL), same as the correct id. Existing accounts are reached by
  account id; the DApp id matters for accounts that do not exist yet.

Fixes:
- `SwapFactory` records `_dapp = address(this).dapp_id` in its constructor (on-chain, where it works);
  getters return stored values. No getter uses DApp-context `gosh.*` instructions. Credit is read from
  the DappConfig's `getDetails`.
- `run_phase1.sh` stops if the lot count is not a number, the lot id is all zeros, or a new lot is not
  live on chain.

Lessons:
- **Getters must not use DApp-context instructions** (`gosh.getavailablebalance`, `address(this).dapp_id`):
  they work on-chain but fail in local `tvm-cli run` with exit -36.
- A test harness must validate every derived address before using it.

## Run 2 — 2026-09-29 — stopped at setup (factory constructor), root-caused

Factory `3ed5d026…3eaa` (now bricked, test funds only).
```
deploy factory      → exit_code 35   (VM error 35 = "DApp ID is not set")
sendTransaction     → exit_code 76   ("public function was called before constructor")
getInfo             → exit_code 76
```

Cause: the run-1 fix read `address(this).dapp_id` in the constructor. During the **external deploy**
of a self-rooted contract the DApp id is not yet set, so the constructor failed.

**Acki Nacki behaviour discovered:** a failed constructor does NOT roll back the deploy. The code is
installed, the account is active (`acc_type 1`), and every public call fails with exit 76 because the
constructor never completed.

Consequences:
- **A lot's constructor must be impossible to fail.** Otherwise the maker's coins end up inside an
  installed-but-uninitialised contract whose every function reverts. SwapFactory validates every
  condition the AtomicSwap constructor checks before deploying (comment added to AtomicSwap).
- "Active" does not mean "deployed correctly". The test script now treats a contract as ready only
  when a getter answers, and re-sends the deploy (which runs the constructor) if not.

Fix: self-rooted factory uses `_dapp = address(this).value` (its DApp id equals its account id).
TestWallet `myDapp()` likewise. This changes the TestWallet code, so run 3 uses new wallet addresses.

## Run 3 — 2026-09-29 — 30 passed, 0 failed … but one real bug found in the final summary

Factory `9bec561b…3208`; maker `c9ad1eb7…e379`; taker `0f031a9d…cd4a`.

All 30 checks passed: exact settlement and fee split (T1), underpay refused at zero lot gas cost
and overpay change returned (T2), double take fills once (T3), reclaim rules (T4), bounced payout
booked and claimed (T6), deadline enforced (T7), routing by account id (T8), NACKL conserved.

**Bug (not covered by any check):** `all lots hold: shell 50000000000`. In T5 the taker's wallet sent
50 SHELL with flag 16 and lost it; it stayed in lot 4 (`…::8e9c53b6…`), breaking I4.

The aborted transaction (`366da914…`), read via GraphQL:
```
compute: exit_code 0, success true          ← take() ran to the end
credit:  50008071000                         ← the 50 SHELL was credited as NATIVE gas (flag 16)
action:  success false, no_funds true, result_code 38 ("not enough extra currencies"), msgs_created 0
bounce:  null                                ← no bounce
```
1. Flag-16 SHELL was converted to gas on arrival, but `msg.currencies[2]` still reported 50 SHELL.
2. `take()` trusted `msg.currencies`, passed, and tried to pay out SHELL the lot did not hold.
3. The action phase failed; the transaction aborted; state and payouts rolled back.
4. **On Acki Nacki an action-phase failure aborts WITHOUT bouncing.** The coins were stranded.

**Rule:** every failure must happen in the compute phase (a `require`, which bounces), never in the
action phase. Before accepting, check that coins actually **arrived** (contract balance, not just
`msg.currencies`) and that there is enough gas to send the payouts.

Fixes:
- `AtomicSwap.take()`: `require(address(this).currencies[want] >= paid)` and
  `require(address(this).balance >= PAYOUT_GAS)` before `tvm.accept()`.
- `SwapFactory`: tracks ECC it owns (`_held`: pre-deploy funding counted in the constructor, receipts
  via `receive()`); `createLot` requires `balance ≥ _held + give` (same flag-16 hole existed for
  SHELL makers); owner `sendTransaction` can spend only `_held`, never makers' coins.
- Tests: T5 now checks no SHELL stranded and the taker's value returned; the run ends by checking
  that no NACKL and no SHELL remain in any lot. 34 checks.

## Run 4 — 2026-09-29 — 34 passed, 0 failed ✅ PHASE 1 (FIXED) VERIFIED

Factory `5f19b165…eb3f`; maker `c9ad1eb7…e379`; taker `0f031a9d…cd4a`; 7 lots.

```
all lots hold: nackl 0  shell 0
NACKL maker+taker+lots: 20200000000000 -> 20200000000000
SHELL maker+taker+factory: 1957500000000 -> 1957500000000   (exact, including fees and change)
factory fees: 10 -> 12.5 SHELL (1 + 0.5 + 0.5 + 0.5)
```

- Every invariant exercised on-chain: I1 born funded (T1), I2 fee/payout split exact (T1, T2b),
  I3 single fill (T3), I4 nothing stranded (T5, end checks), I5 reclaim open lots incl. after
  deadline (T4, T7), I6 no admin on lots (by construction).
- Rejected takes cost the lot 0 gas (T2a): spam cannot drain our credit through lots.
- **T5 flag-16 SHELL now refused in the compute phase and returned AS SHELL** (taker SHELL delta 0,
  fee 0.009 vmshell). The flag-16 conversion only sticks if the transaction succeeds; a compute-phase
  refusal bounces and undoes it. Users who send with the wrong flag lose only a tiny fee.
- Factory `_held` works: pre-deploy funding counted in the constructor, config created from it,
  fees tracked via `receive()`.

## Run 5 — 2026-09-29 — 46 passed, 0 failed ✅ PHASE 1b (hardening) VERIFIED

Factory `8677e80d…39fc` (closeDelay 60 s); maker `c9ad1eb7…e379`; taker `0f031a9d…cd4a`; 9 lots, all closed.

Review fixes (docs/SECURITY_REVIEW.md) confirmed on-chain:
- **F1 `close()`**: refused on an open lot (T11a) and right after settlement (T11b); deleted the lot after
  the 60 s delay (T11c). Gas returned to the factory: **274,372,000** for one lot (≈ 91% of LOT_GAS);
  **2,056,963,000** for 8 lots (≈ 0.257 each). Churn now costs ≈ 0.03–0.05 per cycle, not 0.3.
- **F3 exact currencies**: take with extra NACKL refused, both currencies returned (T9); createLot with
  extra SHELL refused, no lot created, both returned (T10).
- **F4 permissionless reclaim after deadline**: a stranger reclaimed; coins went to the maker (T7b).
- F2 (factory gas pre-check) not triggered: factory stayed funded.

Conservation: NACKL 30300000000000 → 30300000000000; SHELL (maker+taker+factory) 2955000000000 → 2955000000000.
All lots empty at the end; all deleted by `close()`.

## Run 6 — Phase 2a suite, first full run (2026-09-30): 69 passed, 12 failed — test-harness fault

Factory `88fdb338…` (it already had 14 lots from an earlier, stopped Phase 2a run).

**Cause:** the maker TestWallet was left `rejecting = true` by the earlier run (P11 turns it on and
off; that run stopped in between, around 08:08 UTC). Maker wallet history on Shellnet shows compute
exit 300 (TestWallet's `require(!rejecting, 300)`) on every incoming message from 10:06:40, including the
giver's funding. So every payout to the maker bounced and was booked in the lot as owed. That is
correct contract behaviour, and it is why those lots could not close (`close` → 211 NOT_EMPTY).

All 12 failures are this one cause: maker payouts (T1, T2b, T4b, T7b, P1, P10b), closes blocked by owed
coins (T11c, T11d, P12), and the lot totals (6,000 NACKL + 346.5 SHELL owed to the maker).

**Passed, including every new Phase 2a behaviour:** pay-to-take bounceable and non-bounceable with change
(P1, P2); non-bounceable refunds of underpay, payment to a filled lot, wrong currency (exactly 1 NACKL
back, lot's 1000 intact), `take()` call and `createLot` (P3, P5, P6, P8, P9); flag-16 leaves lot intact (P7);
external reclaim refused before the deadline (exit 204) and working after (P10); bounced payout booked,
close refused while owed, external `release()` delivered 4.95 SHELL into a still-rejecting wallet, second
release refused (exit 205) (P11). NACKL conserved exactly.

**Fixes:** both suites now reset and verify `rejecting = false` on maker and taker at startup.
`recover_lots.sh` returns owed coins with unsigned external `release()` / `reclaim()` / `close()` only.

### Recovery (2026-09-30 10:49–10:55 UTC): `recover_lots.sh`, no wallet, no keys

17 live lots on factory `88fdb338…` (from run 6 and the earlier stopped run) held 9,000 NACKL + 346.5 SHELL.
Using only unsigned external messages: 15 × `release(maker)`, 2 × `reclaim()` (expired open lots),
then 17 × `close()`, all exit 0. Result: 0 lots live, 0 coins in lots, maker +9,000 NACKL, +346.5 SHELL.
First real-world use of the keeper design: coins stuck behind a refusing wallet recovered by anyone,
delivered only to their recorded owner.

## Run 7 — Phase 2a suite (2026-09-30 11:09–11:54 UTC): **81 / 81 PASS**

Factory `88fdb338…`. (A first attempt at 11:11 stopped at the new wallet-reset guard: it compared
Python's `False` with `false`. Guard fixed to normalise case; no lots had been created.)

- Phase 1 regression T1–T11: all pass on the Phase 2a contracts.
- Phase 2a P1–P12: all pass: pay-to-take (bounceable, non-bounceable with change), non-bounceable refunds
  (underpay, filled lot, wrong currency, `take()` call, factory `createLot`), flag-16 lot intact, external
  reclaim/release/close with no wallet, release into a rejecting wallet.
- Conservation: NACKL exact; no NACKL or SHELL left in any lot. SHELL total -5.0 exactly = P7's
  deliberate non-bounceable flag-16 transfer (converted to gas, unrecoverable: review F9).
- Gas: closing one lot returns 0.272 vmshell to the factory; 8 lots 2.03.

### Web-app demo (2026-09-30 ~12:10 UTC): `demo_lots.sh` found bug F13

The page showed the 3 asks and the pay-to-take fills correctly (lots `5f15d716…`, `3baf9b1e…` FILLED by the test
taker through `receive()`, `takerDapp` = our DApp as designed). The 4th demo lot (100 SHELL for 25,000 NACKL)
never appeared: the factory refused it with **exit 106 NOT_ARRIVED** and bounced the SHELL (nothing lost).
Cause: `receive()` counted flag-16 SHELL from each run's giver funding into `_held`, so `_held[SHELL]` exceeded
the real balance. Fixed (review F13); suite gains P13 and a final "ledger == balance" check. Factory
`88fdb338…` keeps the inflated ledger; the next suite run deploys a fixed factory at a new address.

## Run 8 — Phase 2a suite with F13 fix + P13 (2026-09-30, ended 13:15 UTC): 88 passed, 1 failed (test arithmetic)

New factory `4b836d38…` (fixed `receive()`, `getHeld()`).
- **P13 all pass:** a flag-16 donation no longer inflates the ledger (ledger == real SHELL before and after);
  a SHELL-giving lot is created (the case F13 blocked); NACKL pay-to-take fills it: taker +100 SHELL, maker +24,750 NACKL.
- Final ledger check passes: factory `_held` SHELL 13.55 == real balance.
- **The one FAIL was the test, not the contracts:** "NACKL conserved across maker + taker + lots" was short by exactly
  250 NACKL = P13's 1% fee, paid in NACKL to the factory (the first NACKL fee in any suite). The check never counted
  the treasury. Verified on chain: factory holds 250 NACKL and `getHeld().nackl` = 250. Start 96,016 NACKL = end
  95,766 (maker+taker+lots) + 250 (factory). Check corrected to include the factory; a NACKL ledger == balance check added.
  On this run's data all 89 checks pass.

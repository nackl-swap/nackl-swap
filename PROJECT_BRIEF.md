# NACKL-Swap — Project Brief

> Read this first in any new session. It is the single source of truth for what we are
> building, why, what is decided, and what is next.

## What

A non-custodial, peer-to-peer swap for Acki Nacki native currencies, starting with
**NACKL ↔ SHELL** (and NACKL ↔ USDC if SHELL turns out to convert on arrival).

## Why

- Getting SHELL took the founder days (gosh.ai, stuck transfers). Holders have NACKL and
  need SHELL for DEX.DO. Community feedback on the idea was positive.
- Market #GO (market.gozone.space) proves demand for NACKL trading (daily volume), but it
  is custodial: one hot wallet held ~908k NACKL of user deposits. We remove that risk.
- Same-chain swaps can settle atomically, so no operator ever holds user funds.

## What makes it outstanding

1. **Provably safe**: invariants first, no admin key, no upgrades, funds can only go to
   maker, taker, or a capped fee.
2. **Effortless**: one tap, no token approvals (ECC rides with the message), sponsored gas,
   lots are born funded.
3. **Alive**: Drop lots (price falls live each second), gasless haggling via signed quotes,
   private lots via taker-bound quotes.

## Decisions made

| Decision | Choice | Why |
|---|---|---|
| Escrow model | One `AtomicSwap` contract per lot | Isolated accounting; bugs can't spread; balance checks are exact |
| Order book | Read from chain: factory `LotCreated` events + lot balances via public GraphQL (no backend, no DB) | Shellnet GraphQL allows browser CORS; nothing to host or trust (Phase 2b) |
| Wallet flow | Takers: plain transfer to the lot (pay-to-take). Makers: `createLot` payload from any wallet that can attach coins + payload | The AN Wallet cannot call contracts (bee SDK = connect only; `docs/WALLET_INTEGRATION.md`) |
| Upgradeability | None on `AtomicSwap`; version via new factory | Trust comes from immutability |
| First pairs | NACKL↔SHELL, NACKL↔USDC | SHELL↔USDC is pointless (protocol fixed 100:1 via `accumulator`) |
| Network for dev | Shellnet first, mainnet later with caps | Contract bugs are permanent |

## Current phase

**Phase 0: spikes on Shellnet.** Spikes 1–4 CLOSED. Every design assumption verified on Shellnet. Spike 5 (checkSign) deferred to Phase 3.
**Phase 1 COMPLETE — `AtomicSwap` FIXED mode verified on Shellnet: 34/34, nothing lost or stranded.**
**Phase 1b: hardening from self-review** (`docs/SECURITY_REVIEW.md`, F1–F4): `close()` returns lot gas,
factory gas pre-check, exact-currency checks, permissionless reclaim after deadline. **46/46 on Shellnet (run 5).**
**Phase 2 — web app. Finding: the AN Wallet cannot call contracts (bee SDK = connect/identity only), only plain transfers.**
Decision: "pay-to-take" lots + keeper functions by external message (`docs/WALLET_INTEGRATION.md`).
Spike 6 CLOSED (bounce bit readable; refused non-bounceable strands coins; flag-16 SHELL converts unless bounced).
**Phase 2a COMPLETE — 81/81 on Shellnet (run 7)**: pay-to-take `receive()`, `_refused()` refunds, `release()`,
external keepers (review F8–F12). Suite `tests/run_phase2a.sh`; `tests/recover_lots.sh`. Phase 1b sources in `archive/`.
**Phase 2b — web app `web/` (working locally):** live order book from chain, pay-to-take dialog (exact amount, address, QR,
hides payment details unless the lot is open), maker payload builder (byte-identical to `tvm-cli body`, `web/test_boc.mjs`),
my lots + cancel payload. Demo data: `tests/demo_lots.sh`. Keeper clean-up by script (`tests/recover_lots.sh`); in-browser
external messages deferred (needs Acki Nacki's message-submission format).
**Found by the demo: F13** (factory ledger inflated by flag-16 SHELL blocked SHELL-giving lots). Fixed + P13 added.
**Run 8:** F13 fix verified (P13 all pass; 89/89 with the corrected NACKL-conservation check). Web app now on factory `4b836d38…`.
UI redesigned for everyday users (Buy · Sell · List, bottom sheets). Outreach drafts: `docs/MESSAGES_2026-09-30.md`. Name: NACKL-Swap for now (candidates: LobSwap, Marble Swap).
Mainnet still requires an independent audit. `contracts/AtomicSwap.sol` + `contracts/SwapFactory.sol`
compile (sold 0.81, `--tvm-version gosh`). Test suite: `tests/run_phase1.sh` (46 on-chain checks). Results: `tests/RESULTS.md` (runs 1–5).
See `spikes/README.md` and `spikes/RESULTS.md`.

Toolchain: working (WSL Ubuntu, sold 0.81.0, tvm-cli 3.0.6, Shellnet). See `tools/SETUP.md`.

## Chain facts (verified from dexdo production contracts)

- Currency IDs: **NACKL = 1**, **SHELL = 2**, **USDC = 3**. Decimals 9 / 9 / 6.
- Send currency: `mapping(uint32 => varuint32) ecc; ecc[2] = varuint32(x);` then
  `dest.transfer({value: 0.1 vmshell, bounce: false, flag: 1, currencies: ecc});`
- Read holdings: `uint128(address(this).currencies[id])` (contract balance, not message).
- Deploy child: `new C{stateInit: si, value: 1 vmshell, flag: 1, bounce: false, currencies: ecc}(...)`.
- Handlers: `receive() external {}` and `onBounce(TvmSlice body) external {}`.
- Time: `block.timestamp`. Hashing: `tvm.hash(abi.encode(...))`.
- **Verified (spike 3):** `gosh.mintshellq(x)` is a no-op until our DApp has a DappConfig. The DApp
  root creates it by sending DappRoot (`0000…::9999…`) `deployNewConfigCustom` with ≥ 100 SHELL, all
  of which becomes credit; anyone can top it up. Then `mintshellq(x)` credits x vmshell after the tx.
  Note `0000…::9999…` is the DappRoot system contract, never a test address.
- **Verified (spike 4):** ECC attached to `new Child{…, currencies}` is present at construction (born
  funded). Children join the factory's DApp (native value arrives intact). Children mint from the
  factory DApp's DappConfig in later calls after `tvm.accept()`, **never in the constructor**.
  Gas strategy: factory gives initial gas via `value`; lots top up with accept + mintshellq.
- `msg.currencies[id]` works in this dialect (DappRoot uses it): read exactly what a message carried.
- **Addressing (verified by compiler):** `dest_dapp_id` works on `transfer`/calls; a contract can read only
  `address(this).dapp_id`, never the sender's. So users pass their DApp id (`makerDapp`, `takerDapp`);
  a wrong id bounces the payout back into `_owed`, collected with `claim(dapp)`.
- Also available: `gosh.getavailablebalance()` (read credit), `gosh.mintshell` (non-quiet),
  `gosh.cnvrtshellq` (contract converts its own SHELL to gas), ZK: `gosh.vergrth16`, `gosh.zkhalo2verify`.
- **Getters must not use DApp-context instructions** (`gosh.getavailablebalance`, `address(this).dapp_id`):
  they fail in local `tvm-cli run` with exit -36. Record the DApp id in the constructor instead.
- **Flag-16 conversion only sticks if the transaction succeeds** (run 4): a compute-phase refusal
  bounces the SHELL back as SHELL.
- **Action-phase failures abort WITHOUT a bounce** (Phase 1 run 3): incoming coins are stranded. Every
  failure must be a compute-phase `require` (which bounces). Check coins actually arrived via the
  contract balance, not only `msg.currencies` (flag-16 SHELL is listed but converted to gas), and check
  gas for payouts, before `tvm.accept()`.
- **A failed constructor leaves the code installed** (active, uninitialised; every call exit 76). Lot
  constructors must be infallible (factory pre-validates). `address(this).dapp_id` is unavailable during
  an external deploy (VM error 35); a self-rooted contract's DApp id is `address(this).value`.
- **Routing (Phase 1 T8):** a transfer with a wrong `dest_dapp_id` still reached an existing wallet.
  Existing accounts are reached by account id; the DApp id matters for not-yet-existing accounts.
- The assistant can compile-check via `wsl.exe -d Ubuntu` (compile only; never keys or transactions).
- Economics: raise minimum lot to ~1,000 NACKL (or flat fee) so fees cover sponsored gas.
- Cross-DApp messages arrive with native value zeroed; the receiver pays its own execution.
- **Verified on Shellnet (spike 1):** SHELL sent with **flag 1 stays SHELL**; with **flag 16 it
  converts 1:1 to native vmshell**; NACKL arrives as NACKL; native `value` is zeroed across DApps.
  All SHELL payouts use flag 1. Fund a fresh contract's gas with flag-16 SHELL.
- Measured: deploy of a small contract 0.0136 vmshell; handling an incoming transfer 0.001 vmshell.
- **Verified (spike 2):** a bounced message returns its ECC in full, from a reverting contract and
  from a non-existent account. Only delivery to a wrong-but-existing address loses funds silently,
  so payouts go only to contract-recorded addresses. Send+bounce round trip ≈ 0.0067 vmshell.
- Compile with `sold --tvm-version gosh` (enables `gosh.*` instructions such as `mintshellq`).
- tvm-cli 3.0.6: always `genaddr --save` (ABI 2.4); `account/run/call` need `<dapp>::<account>`;
  on `DUPLICATE_MESSAGE`, retry with `--retries 1` and verify on chain.

## Key links

- Contract plan: `docs/CONTRACT_PLAN.md`
- Toolchain: `tools/SETUP.md`
- Reference contracts: github.com/gosh-sh/dexdo-cli/tree/main/contracts
- Docs: docs.ackinacki.com, dev.ackinacki.com

## Ground rules

- Throwaway **Shellnet** keys only for development. Never mainnet keys in this repo.
- The assistant writes code and reads output; the founder holds keys and runs deploys.
- Honest numbers: record spike results in `spikes/RESULTS.md` with the exact command output.

# NACKL-Swap

**Non-custodial, peer-to-peer swaps for Acki Nacki native currencies**, starting with NACKL ↔ SHELL
(and NACKL ↔ USDC).

Every offer ("lot") is its own immutable smart contract, born holding the seller's coins. A buyer pays the
lot directly and the lot pays back **in the same transaction**. There is no operator wallet, no deposit, no
admin key and no upgrade path. Coins can only ever go to the seller, the buyer, or a fee capped at 1%.

> **Status:** Shellnet (test network). 89/89 on-chain checks pass with exact coin conservation.
> **Not yet independently audited.** Mainnet comes after an audit. See [SECURITY.md](SECURITY.md).

## How it works

| | |
|---|---|
| **Factory** (`contracts/SwapFactory.sol`) | DApp root. Validates an offer and deploys a lot carrying the seller's coins plus gas, in one transaction. Owns the DApp's sponsored-gas credit (DappConfig). |
| **Lot** (`contracts/AtomicSwap.sol`) | One per offer. `take()`, or a plain transfer of the asked currency ("pay-to-take"), fills it atomically. Wrong, late or short payments are refunded. |
| **Keepers** | Returning expired lots, closing finished ones and pushing bounced payouts work by **unsigned external message**: no wallet needed, and coins still go only to their recorded owners. |
| **Web app** (`web/`) | Static files, no backend. Reads `LotCreated` events and lot balances straight from the public GraphQL, decodes them in the browser (`web/boc.js`), and guides pay-to-take. |

Why pay-to-take: the Acki Nacki Wallet can't call arbitrary contracts, but every wallet can make a
plain transfer. See [`docs/WALLET_INTEGRATION.md`](docs/WALLET_INTEGRATION.md).

## Repository map

```
contracts/      SwapFactory.sol, AtomicSwap.sol (TVM Solidity, sold 0.81, --tvm-version gosh)
tests/          run_phase2a.sh (full on-chain suite), RESULTS.md (every run), recover_lots.sh, demo_lots.sh, TestWallet.sol
spikes/         Phase 0 experiments that verified each chain behaviour we rely on (RESULTS.md)
web/            the app: index.html, app.js, boc.js, config.js, test_boc.mjs
docs/           CONTRACT_PLAN.md, SECURITY_REVIEW.md, WALLET_INTEGRATION.md
archive/        earlier verified versions of the contracts and the suite
tools/          SETUP.md (toolchain), hooks/pre-commit (secret guard)
```

## Chain behaviours we rely on (measured on Shellnet)

- An action-phase failure aborts **without a bounce**, so every failure must happen in the compute phase.
- A failed constructor leaves the code installed, so lot constructors must be infallible (the factory validates first).
- Flag-16 SHELL is listed in `msg.currencies` but credited as gas, so "coins arrived" is checked against the real balance.
- A refused non-bounceable message keeps its coins, so lots read the bounce bit and refund explicitly.
- Existing accounts are reached by account id whatever `dest_dapp_id` says.

Details and evidence: [`spikes/RESULTS.md`](spikes/RESULTS.md), [`tests/RESULTS.md`](tests/RESULTS.md).

## Running

Toolchain (WSL/Linux): `sold` 0.81 (gosh) and `tvm-cli` 3.0.6.an. See [`tools/SETUP.md`](tools/SETUP.md).

```bash
cd tests && bash run_phase2a.sh            # full suite on Shellnet (~25 min); creates its own test keys
node web/test_boc.mjs                      # web decoder/encoder tests
python -m http.server 8765 --directory web # then open http://localhost:8765
```

Test keys are generated locally on first run and are **Shellnet-only**. Never use them, or put a mainnet
key, in this folder. Contributors: `bash tools/install-hooks.sh` installs the secret-scanning pre-commit hook.

# Wallet Integration — what a web app can and cannot do (researched 2026-09-29)

## The constraint

Official Bee Engine SDK docs (dev.ackinacki.com/bee-engine/bee-engine-sdk-integration-documentation):

> "Acki Nacki Wallet is not intended for calling arbitrary methods of user contracts, because it
> operates under the system DAPP ID."

The web `bee_sdk` (Rust→WASM; same one Market #GO serves as `bee_sdk.js` + `bee_sdk.wasm`) exposes:
- `BeeConnect.create_shared_key_session`, `wait_wallet_hello` — connect / identify a wallet
- `request_sign_challenge`, `wait_challenge_response` — prove wallet ownership
- `request_set_mining_keys`, … — Bee Engine mining
- **No** "send these coins to this contract with this call" request. **No** agent onboarding.

Market #GO uses only connect (`new BeeConnect`, `create_shared_key_session`, `wait_wallet_hello`). Users
make **plain transfers** to deposit addresses from the Acki Nacki Wallet app, and a backend watches.
**That is why Market #GO is custodial.**

## What does support contract calls

The canonical Hot/Vault multisig (`UpdateCustodianMultisigWallet_v2`, compiled 0.81.0):
```
sendTransaction(dest, value, cc map(uint32,varuint32), bounce, flags, payload cell, dapp_id)
submitTransaction(...same...)   confirmTransaction(transactionId)
```
Coins + ABI payload + destination DApp. Any holder of a Hot custodian key can call our contracts fully
(this is how dexdo works: `wallet onboard ackinacki-wallet` creates a Vault/Hot "agent" pair via a QR
bee session with `intent=agent_onboard`, and the CLI holds the Hot key).

## Paths for our platform

| Action | Plain transfer from AN Wallet app (works today) | Agent Hot key (dexdo-style) | External message (no wallet) |
|---|---|---|---|
| **Take a lot** | ✅ if the lot treats an incoming want-currency transfer as a take (`receive()`) | ✅ | — |
| **Create a lot** | ⚠ needs terms; possible via "deposit to a pre-computed lot address, then deploy" | ✅ | — |
| **Reclaim after deadline / close / pay out owed** | — | ✅ | ✅ if made permissionless (payout still only to recorded owners) |
| **Maker cancels before deadline** | ⚠ needs maker authorisation | ✅ | — |

Notes:
- External inbound messages need no wallet; a web page or keeper can send them. If a function checks
  everything before `tvm.accept()`, a failing external message costs us nothing (not even included).
- Payouts to users' existing wallets are delivered by account id even with a guessed DApp id
  (Phase 1 T8), so a lot can pay `msg.sender` without being told the sender's DApp.
- Unknown: whether the AN Wallet app's plain transfers are bounceable. A `receive()`-based take must
  refund explicitly rather than rely on bounces.
- Open question for GOSH: will the web bee SDK support agent onboarding (`intent=agent_onboard`) or
  dApp transaction requests?
- The SDK's `Wallet` class (`send_tokens_direct`, `sell_shells`, …) is a full wallet that signs with
  keys held in the page. A dApp must never ask users for their seed, so we don't use it.

## Decision (2026-09-30): "pay-to-take" + keeper functions (Phase 2a)

1. **Take by plain transfer.** Sending exactly the want currency to an open lot fills it and pays the
   give currency to `msg.sender` (routed by account id, T8). This works from the Acki Nacki Wallet app
   today, and stays non-custodial: the coins go straight to the lot, never to us.
   - Bounceable transfer that fails a check → `require` (a compute-phase refusal bounces coins back as-is).
   - Non-bounceable transfer that fails a check → accept, then refund what actually arrived explicitly
     (a refusal would strand the coins). The lot must never refund coins it holds for others
     (the give side, or `_owed`), so it needs an `_owedTotal` per currency.
   - This needs the lot to read the bounce flag from `msg.data`, which is spike 6.
2. **Keeper functions by external message** (no wallet needed; the web app or anyone can send them):
   reclaim after the deadline, `close()`, and `release(owner)` for bounced payouts. All checks run
   before `tvm.accept()`, so a failing call costs nothing. Payouts only ever go to recorded owners.
   `release` is rate-limited per lot, so a wallet that keeps rejecting can't drain our gas.
3. **Makers (v1):** `createLot` from any wallet that can attach currencies and a payload (agent
   Hot/Vault multisig, as dexdo does, or CLI). The web app builds the exact call. Makers on the wallet
   app alone need either GOSH SDK support or signed-terms deposits (Phase 3, spike 5 `checkSign`).
4. **Mainnet probe (user-run, later):** send 1 NACKL from the real AN Wallet app to a probe, to learn
   which flag and bounce setting the app uses and what dest DApp id it sets.

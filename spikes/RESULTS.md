# Spike Results

Paste exact command output under each spike. A result without output is a guess.

| Spike | Question | Status | Answer |
|---|---|---|---|
| 1 | SHELL arrives as SHELL across a DApp boundary? | **CLOSED** | **flag 1 → SHELL stays SHELL; flag 16 → native 1:1; NACKL arrives as NACKL. Native `value` zeroed cross-DApp. Receive costs 0.001 vmshell.** |
| 2 | Bounce returns ECC? | **CLOSED** | **Yes, in full, both from a reverting contract and from a non-existent account.** Attached native also returns. Send+bounce ≈ 0.0067 vmshell. |
| 3 | `gosh.mintshellq` works in our DApp? Gas per call? | **CLOSED** | **No-op without a DappConfig. After creating one (120 SHELL credit), `mintshellq(10 vmshell)` credited +10 vmshell; credit fell ~10 SHELL.** Signed call ≈ 0.003 vmshell. |
| 4 | Child born funded, and joins factory's DApp? Can lots mint gas? | **CLOSED** | **Born funded ✅. In factory's DApp ✅. Minting from the factory's DappConfig works in later calls with `tvm.accept()` ✅ (+3 vmshell); never in the constructor ❌.** |
| 5 | `tvm.checkSign` verifies quote signatures? | not run | |

## Toolchain

- `sold` gosh 0.81.0 (linux x86_64, WSL Ubuntu) — compiled `01_ShellProbe.sol` first try, ABI 2.4
- `tvm-cli` 3.0.6.an (linux-musl amd64), configured for `shellnet.ackinacki.org`
- Output files are named after the source file: `01_ShellProbe.tvc`, `01_ShellProbe.abi.json`

## Spike 1

Probe address (self-rooted, undeployed):
`4b251fb8ddb2a2941d64eea2c8d713b719251b99ec9fdbe0cfa95ae10f116480::4b251fb8ddb2a2941d64eea2c8d713b719251b99ec9fdbe0cfa95ae10f116480`

### Test 1 — 2026-09-27 — giver → undeployed probe, flag 1, value 1 vmshell + 5 SHELL

```
sendCurrencyWithFlag '{"dest":"0:4b25…6480","value":1000000000,"ecc":{"2":5000000000},"flag":1}'
→ exit_code 0, aborted false, tx 8adb97212e01d77fb6e0f27e9372777e4da779fbf47a885601b32a67f4695cbf
```

Account read via Shellnet GraphQL `blockchain { account(account_id, dapp_id) }`:

```
dapp_id=4b25…6480 : {"acc_type":0,"balance":"0","balance_other":[{"currency":2.0,"value":"5000000000"}]}
dapp_id=0000…0000 : {"info":null}
```

Findings:
- **SHELL (ECC[2]) sent with flag 1 arrives as SHELL** across a DApp boundary. NACKL↔SHELL is viable.
- **Native value (1 vmshell) was zeroed** crossing DApps, as documented.
- Funds land in the destination's own DApp (self-rooted = account id), where the deploy will be.
- Consequence: a fresh cross-DApp account has **no gas to deploy itself**. Hypothesis: flag 16
  converts ECC[2] to native (per dexdo manual-onboarding docs). Test 2 checks this.

### Test 2 — 2026-09-27 — giver → undeployed probe, flag 16, value 1 vmshell + 3 SHELL

```
sendCurrencyWithFlag '{"dest":"0:4b25…6480","value":1000000000,"ecc":{"2":3000000000},"flag":16}'
→ exit_code 0, aborted false, tx 86cd0629c88821b10db5226055357e94f5b836455b48edb740102db80b236c99
```

```
dapp_id=4b25…6480 : {"acc_type":0,"balance":"3000000000","balance_other":[{"currency":2.0,"value":"5000000000"}]}
```

Findings:
- **Flag 16 converts ECC[2] SHELL into native vmshell, 1:1, on arrival.** Native 0 → 3e9; SHELL unchanged at 5e9.
- The 1 vmshell `value` was zeroed again. Flag-16 SHELL is the way to fuel a fresh cross-DApp account.

Design consequences:
- **All SHELL payouts must use flag 1.** Flag 16 would deliver gas, not SHELL.
- A taker's wallet sending SHELL with flag 16 delivers gas to the lot. `take()` must detect "no SHELL
  arrived" and refund the native value instead of filling.
- One message has one flag, so a user cannot attach trade SHELL (flag 1) and gas SHELL (flag 16)
  together. Sponsored gas (spike 3) is essential for one-tap UX.
- Addresses: `tvm-cli account/run/call` require `<dapp>::<account>`; JSON `address` params still take `0:<HEX>`.

### Deploy attempt 1 — 2026-09-27 — failed, root-caused

```
deploy → code 621 COMPUTE_SKIPPED "The account doesn't have a state"
account_id: 731847b96473f91213c4c00202b2beb15f4ba974f01fd980538a983363752a20   (not 4b25…!)
```

Cause (tvm-sdk v3.0.6.an source): `Contract::data_map_supported()` is `abi_version < 2.4`. Our ABI is
2.4, so `deploy` addresses the contract as `hash(tvc)` without inserting the pubkey, while `genaddr`
inserts it. Fix: `genaddr … --save` bakes the key into the `.tvc`. Nothing lost: funds wait at 4b25….

Design note: lot addresses must be derived from the exact stateInit (code + static vars + pubkey)
the factory deploys; off-chain precomputation must replicate it byte-for-byte.

### Deploy attempts 2–3 — 2026-09-27 — succeeded

- Attempt 2 (after `--save`): targeted the right account but returned `DUPLICATE_MESSAGE` via producer
  `shellnet-2`; chain showed nothing changed (acc_type 0, last_paid unchanged). tvm-cli's own retry was
  flagged; the first send had been dropped. WSL clock checked: fine.
- Attempt 3 with `tvm-cli config --retries 1`: **deployed**, producer `shellnet-4`,
  tx `0f9122e9f9712b659789ae1f8f159f7ae7a9047a558114a0b62e8e8542990e3c`.

```
after deploy: {"acc_type":1,"balance":"2986352000","balance_other":[{"currency":2.0,"value":"5000000000"}]}
```

- **Deploy cost: 0.013648 vmshell** (≈ 0.014 SHELL via flag-16 conversion). Per-lot contracts are cheap.
- Operational: `DUPLICATE_MESSAGE` can mask a dropped first send; retry with `--retries 1` to see the
  real result, and always confirm on chain.

### Test 3 — 2026-09-27 — in-contract, deployed probe, three giver sends (value 1 vmshell each)

| Receipt | Send | tx | dShell | dNackl | dNative (as logged) |
|---|---|---|---|---|---|
| 0 | 2 SHELL, flag 1 | fbcd2b1c… | **+2000000000** | 0 | +999000000 ⚠ |
| 1 | 2 SHELL, flag 16 | 1e4a05b9… | **0** | 0 | **+1999000000** |
| 2 | 2 NACKL, flag 1 | 98383f48… | 0 | **+2000000000** | −1000000 |

Final `getSnapshot`: native 4983352000, shell 7000000000, nackl 2000000000, count 3.

Account-level cross-check: native after deploy 2986352000 → after sends 4983352000 = **+1997000000**
= flag-16 conversion (2000000000) − 3 × 1000000 fees. So the 1 vmshell `value` was **zeroed on all
three sends**, and receipt 0's +0.999 is a probe artifact: the constructor's `address(this).balance`
baseline read exactly 1.000 vmshell below the real post-deploy balance.

Conclusions (spike 1 CLOSED):
- SHELL flag 1 → arrives as SHELL (in a live contract). NACKL flag 1 → arrives as NACKL.
- SHELL flag 16 → converts to native vmshell 1:1.
- Native `value` is always zeroed across DApps.
- Processing a plain incoming transfer (`receive()` with a small handler) costs **0.001 vmshell**.
- Don't baseline native balance inside the constructor; ECC balances are unaffected.
- **NACKL↔SHELL is viable. Build it.**

Useful query (GraphQL reads need both ids; the deprecated `accounts` API is disabled):
`{ blockchain { account(account_id:"<HEX>", dapp_id:"<DAPP>") { info { acc_type balance(format:DEC) balance_other { currency value(format:DEC) } } } } }`

## Spike 2

### Run 1 — 2026-09-27 — `run_spike2.sh` (log: `out/spike2.log`)

Rejector `1c6e309f…6433::…` and BounceProbe `f5340db5…2585::…`, both deployed first attempt.
Pre-deploy funding again confirmed: flag-16 SHELL → native (1e9), flag-1 SHELL stays SHELL (3e9).

**Test A — bounce off Rejector (reverts in `receive`)**, tx `7615ab7f…`:
```
shellBeforeSend 3000000000 | shellAfterBounce 3000000000 | bounces 1 | getShell 3000000000
Rejector after: SHELL 0
```
- **The full 1 SHELL came back on bounce.** `onBounce` fired.
- Native: probe spent only ~0.020 vmshell over deploy + send + bounce, versus 0.1 vmshell attached,
  so the attached native value also came back with the bounce.

**Test B — send to "never-deployed" `0:9999…9999`**, tx `c0fa3fa4…`: **INVALID TEST.**
```
bounces still 1 | getShell 2000000000 (1 SHELL gone)
0:9999…9999 : {"acc_type":1,"balance":"109535998000000","balance_other":[{"currency":2,"value":"1000000000"},{"currency":3,"value":"1"}]}
```
- That "obviously unused" address is a live account (~109,536 vmshell). It accepted the SHELL; no bounce.
- Lesson: a payment to a wrong-but-existing address is **silently lost**. Swap payouts must only go to
  addresses the contract captured itself (maker at deploy, taker = `msg.sender`), never to parameters.
- Re-run with a random, verified-empty address: `run_spike2b.sh`.

### Run 2 — 2026-09-27 — `run_spike2b.sh` (log: `out/spike2b.log`) — test B re-run

Random address `0:e7a57b76…d24c`, verified empty on chain first (`info: null`). tx `fb6664fb…`.
```
before: getShell 2000000000 | bounces 1 | native 875269000
after:  shellBeforeSend 2000000000 | shellAfterBounce 2000000000 | bounces 2 | getShell 2000000000 | native 868583000
empty address after: info null (nothing created)
```
- **SHELL sent with bounce=true to a non-existent account comes back in full.**
- Attached 0.1 vmshell also returned; the round trip cost 0.006686 vmshell in fees.

Spike 2 conclusions (CLOSED):
- Bounces return ECC in full, from a reverting contract **and** from a non-existent account.
- The only silent-loss case is a successful delivery to a wrong-but-existing address.
- Design: send payouts with `bounce: true` to contract-recorded addresses only; keep `_claimable`
  for bounced payouts; keep explicit refunds as defence in depth.

## Spike 3

### Run — 2026-09-27 — `run_spike3.sh` (log: `out/spike3.log`)

Sponsor `1072d2da…a24e::1072d2da…a24e` (self-rooted = its own DApp root). Compiled with
`sold --tvm-version gosh` (required for `gosh.mintshellq`; see failed logs for the two fixes:
`varuint16` for `transfer` value, and the `--tvm-version gosh` flag).

| Phase | Action | Native before → after | Delta |
|---|---|---|---|
| 1 | `tryMint` (no DappConfig) | 1988385000 → 1985387000 | **−2998000** (fee only; nothing minted) |
| 2 | `sendTransaction` → DappRoot `deployNewConfigCustom`, cc 120 SHELL | 1985387000 → 1970340000 | Sponsor SHELL 150e9 → 30e9 |
| 3 | `tryMint` (with credit) | 1970340000 → 11967342000 | **+9997002000** (10 vmshell minted − fee) |

DappConfig `1072d2da…::7618442500312d204ea5cd76829748399a23c439c0f6b8775cca44df863fd806`
(lives in our DApp; did not exist before phase 2):
```
after create: available_balance 120000000000, is_unlimit false (account native 14.999 vmshell)
after mint:   available_balance 110000005614   (dropped 9999994386 ≈ 10 SHELL)
```

Conclusions (spike 3 CLOSED):
- `gosh.mintshellq` is a silent no-op until the DApp has a DappConfig.
- The DApp root creates it by sending DappRoot `deployNewConfigCustom` with ≥ 100 SHELL; all of it
  becomes credit (SHELL burned 1:1). Anyone can top up by sending SHELL to the config.
- With credit, `mintshellq(x)` credits x vmshell to the caller after the transaction; credit falls by
  ≈ x. (Unexplained: credit fell 5,614 nano less than 10 SHELL. Negligible.)
- **Sponsored, gasless UX is feasible.** Credit exhaustion costs only operator credit, never user funds.
- Measured costs so far (vmshell): deploy small contract 0.0136; signed call 0.003; receive 0.001;
  send+bounce 0.0067. A full swap is estimated ≈ 0.03 SHELL (≈ $0.0003); measure in Phase 1.
- Economics: 1% of the 10-NACKL protocol minimum (~$0.00013) is below sponsored gas. Use a higher
  minimum lot (~1,000 NACKL) or a small flat fee.

## Spike 4

### Run 1 — 2026-09-27 — `run_spike4.sh` (log: `out/spike4.log`)

Factory `de3601bb…9178::de3601bb…9178` (compiled `--tvm-version gosh`; `abi.encodeStateInit` works).
DappConfig `de3601bb…::1736322bb01dbe840319155fd7325dbe7423ac84df5bd44cf443cabda5adc179`, 120 SHELL credit.
`deployChild(5 SHELL, 5 NACKL)` → child `de3601bb…::2d7ac3868b45497c5465c4545dbe5f38b98483f224edeac182cf620a6c5477eb`.

```
child account: acc_type 1, native 999000000, NACKL 5000000000, SHELL 5000000000
child record:  shellAtBirth 5000000000 | nacklAtBirth 5000000000 | nativeAtBirth 1000000000
credit:        120000000000 → 120000014556 (rose 14,556 nano; no mint drawn)
```

Findings:
- **Born funded ✅** — ECC attached to `new Child{…, currencies: ecc}` arrives before the constructor runs.
- **Child is in the factory's DApp ✅** — the 1 vmshell `value` arrived intact; cross-DApp it would be zeroed.
  (The GraphQL `dapp_id` argument is not a membership test: it returned the child for either id.)
- **`gosh.mintshellq` in the constructor did not mint ❌** — native stayed 0.999, credit did not fall.
  Called during the deploy transaction and without `tvm.accept()`. Spike 4b tests minting in a later
  internal call with `tvm.accept()`, which is the pattern `take()` needs.
- Credit again rose by a tiny amount (+14,556 nano here, +5,614 relative in spike 3). Cause unknown.

### Run 2 — 2026-09-27 — `run_spike4b.sh` (log: `out/spike4b.log`)

Factory `1a6b9e3b…f0f1`, DappConfig `…::6f72ec0b142f59d876c324a25cdffd0c53a5b41b74c6604d7d03bea48616e7d6`,
child 0 `1a6b9e3b…::9dff1b4a679f65cda8e333b47fa44e9723b1bb34ce81b138678b5000f4326fe4`.

```
after construction: child native 999000000; credit 120000014608   (constructor mint of 2 did NOT land)
poke (tx 78b328b4…): child native 999000000 → 4098000000 (+3099000000)
                     nativeAtLastPoke 1099000000 (0.999 + 0.1 poke value), pokes 1
                     credit 120000014608 → 117000029392 (−2999984784 ≈ 3 SHELL)
```

Arithmetic: 0.999 + 0.1 (poke value, same DApp, intact) + 3.0 minted − 0.001 fee = 4.098 ✅.

Conclusions (spike 4 CLOSED):
- **Children mint from the factory DApp's DappConfig** in later internal calls, after `tvm.accept()`.
- **Constructor-time `mintshellq` never lands** (not deferred either).
- Native value sent within our DApp arrives intact (0.1 vmshell poke value; 1 vmshell at birth).
- Gas strategy for AtomicSwap: factory funds initial gas via `value` at deploy; lots top up with
  `tvm.accept(); gosh.mintshellq(x)` in later calls; never mint in the constructor.
- Credit bookkeeping: tiny unexplained credits again (+14,608 at child deploy; draw 15,216 nano < 3 SHELL).

Open question for Phase 1 (drain protection): can a lot run its validation **before** `tvm.accept()`
when the incoming message is cross-DApp with zeroed value? All probes so far accepted first.

## Spike 5

## Spike 6: plain transfers into a contract (2026-09-30), CLOSED

Probe `fc4426a5…`, sender = taker TestWallet `0f031a9d…` (its own DApp). `run_spike6.sh`, log `out/spike6.log`.

| Case | Sent | Probe saw / got | Sender |
|---|---|---|---|
| C1 | bounce=true, flag 1, 1 NACKL | head `01101000` (bounce bit 1), +1 NACKL | -1 NACKL |
| C2 | bounce=false, flag 1, 1 NACKL | head `01001000` (bounce bit 0), +1 NACKL | -1 NACKL |
| C3 | bounce=false, flag 1, 1 SHELL | +1 SHELL as SHELL | -1 SHELL |
| C4 | bounce=false, flag 16, 1 SHELL | **listed** 1 SHELL, but holdShell unchanged; native +0.999 | -1 SHELL |
| C5 | bounce=true, flag 16, 1 SHELL | same as C4 (accepted, so converted) | -1 SHELL |
| C6 | wrong dest_dapp_id (sender's own) | arrived, +1 NACKL | -1 NACKL |
| C7 | refused, bounce=true, flag 1, NACKL | nothing | NACKL back |
| C8 | refused, **bounce=false**, flag 1, NACKL | **+1 NACKL stranded** | -1 NACKL |
| C9 | refused, bounce=true, flag 16, SHELL | nothing | SHELL back **as SHELL** |
| C10 | refused, **bounce=false**, flag 16, SHELL | **native +0.999 stranded** | -1 SHELL |

Conclusions:
- The bounce flag is readable: bit 5 of the first byte of `msg.data` (standard `int_msg_info` layout).
- A refused non-bounceable transfer keeps its coins at the receiver. Contracts must accept and refund
  explicitly, never simply refuse, a non-bounceable message that carries coins.
- Flag-16 SHELL becomes gas on arrival unless the message bounces. Non-bounceable flag-16 SHELL cannot
  be returned as SHELL.
- Existing contracts are reached by account id whatever dest_dapp_id says.
- A plain transfer costs the sender ~0.0156 vmshell; a refusal-bounce ~0.0086.

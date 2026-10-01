# Phase 0 — Spikes

Five throwaway contracts. Each answers one question that could change the design.
**Uncompiled drafts:** the first `sold` run will likely surface TVM-dialect fixes
(`abi.encodeStateInit`, the `checkSign` overload, `transfer` flag types). Paste compiler
errors back and they get fixed.

Record every result, with the exact command output, in `RESULTS.md`.

## Common setup (inside Ubuntu)

```
cd <repo>/spikes
G=0000000000000000000000000000000000000000000000000000000000000000::1111111111111111111111111111111111111111111111111111111111111111
GABI=~/tools/GiverV3.abi.json
KEYS=../spike.keys.json
```

Per contract: **compile → get address → fund → deploy → act → read.**

> **Always compile with `--tvm-version gosh`.** It enables Acki Nacki instructions such as
> `gosh.mintshellq`; without it `sold` rejects them. This is the flag Acki Nacki's own
> `contracts/Makefile.inc` uses: `sold --tvm-version gosh --base-path .. <file>.sol -o .`


```
sold --tvm-version gosh 01_ShellProbe.sol                 # → 01_ShellProbe.tvc + 01_ShellProbe.abi.json
tvm-cli genaddr --abi 01_ShellProbe.abi.json --setkey $KEYS --save 01_ShellProbe.tvc
```

**Always pass `--save` to `genaddr`.** `sold` 0.81 emits ABI 2.4, and for ABI ≥ 2.4 tvm-cli's
`deploy` computes the address as the hash of the `.tvc` *as-is* (no key inserted), while `genaddr`
inserts the key when calculating. Without `--save` the two disagree, funds go to the genaddr address,
and deploy targets another (empty) one — and the contract would have no pubkey. `--save` writes the
key into the `.tvc` so both agree.

`genaddr` prints a raw address `0:<HEX>`. A self-rooted contract's canonical address is
`<HEX>::<HEX>` (its DApp id is its own account id).

> **Address forms:** `tvm-cli` commands (`account`, `run`, `call`) take only the canonical
> `<dapp_id>::<account_id>` form. Inside JSON parameters sent to a contract (like the giver's
> `dest`), the ABI `address` type still uses `0:<HEX>`. Both are verified on Shellnet.


Fund it from the giver (amounts are raw units: 1 vmshell = 1e9, 1 SHELL = 1e9, 1 NACKL = 1e9):

```
tvm-cli -j callx --abi $GABI --addr $G -m sendCurrencyWithFlag \
  '{"dest":"0:<HEX>","value":1000000000,"ecc":{"2":5000000000},"flag":1}'
tvm-cli -j account <HEX>::<HEX>
```

Deploy:

```
tvm-cli -j deploy --abi 01_ShellProbe.abi.json --sign $KEYS 01_ShellProbe.tvc '{}'
```

Do **not** pass `--dst-dapp-id` to `deploy`: in tvm-cli 3.0.6 it exists only on `send`/`sendfile`,
and `deploy` accepts hyphen-values, so it swallows the flag as the TVC name. An external deploy
creates a self-rooted DApp (id = account id), which is where giver funds land.

Fund the address **with flag 16 SHELL first** (e.g. `"ecc":{"2":3000000000},"flag":16`): native
`value` is zeroed crossing DApps, and flag-16 SHELL converts 1:1 into the gas the deploy needs.

Read (free, off-chain) and call (on-chain, signed):

```
tvm-cli -j run  <HEX>::<HEX> getSnapshot '{}' --abi 01_ShellProbe.abi.json
tvm-cli -j call <HEX>::<HEX> <method> '<json>' --abi <X>.abi.json --sign $KEYS
```

---

## Spike 1 — Does SHELL arrive as SHELL? (`01_ShellProbe.sol`)  ⚠ decides the pair

The dexdo source says ECC[2] "converts to native on arrival" across a DApp boundary. Yet
your dexdo withdrawal and the gosh.ai sub-account both received SHELL as SHELL.

1. Compile, `genaddr`.
2. **Before deploying**, giver → `0:<HEX>` with flag 1: `value` 1 vmshell, `ecc {"2": 5 SHELL}`.
   Run `tvm-cli -j account <HEX>::<HEX>`: does it hold ECC 2 = 5 SHELL, or ~6 vmshell and no ECC?
3. Deploy.
4. Giver → probe, flag 1, `ecc {"2": 5 SHELL}` → `getSnapshot` + `receiptsLog`.
5. Same with **flag 16**.
6. Control: `ecc {"1": 5 NACKL}` with flag 1.

| Result | Decision |
|---|---|
| `dShell ≈ +5e9` with flag 1 | SHELL pairs are fine. Build NACKL↔SHELL. |
| `dShell = 0`, native jumps | SHELL converts. Build **NACKL↔USDC first**; investigate how dexdo's withdraw delivers SHELL intact. |
| Flag 1 keeps SHELL, flag 16 converts | Payouts must always use flag 1; document it. |

## Spike 2 — Does a bounce return ECC? (`02_BounceProbe.sol`, `02_Rejector.sol`)

1. Deploy `Rejector` and `BounceProbe`. Fund `BounceProbe` with SHELL (or NACKL if spike 1 says SHELL converts).
2. `call sendBouncing '{"dest":"0:<REJECTOR>","shellAmount":1000000000,"flag":1}'`
3. Read `shellBeforeSend`, `shellAfterBounce`, `bounces`.
4. Repeat with `dest` = an address you generated but never deployed.

| Result | Decision |
|---|---|
| `shellAfterBounce ≈ shellBeforeSend` | Bounces return ECC; still refund explicitly (defence in depth). |
| Lower by the amount | ECC is lost on bounce. Explicit refunds are **mandatory**; never send with a risk of bouncing. |

## Spike 3 — Does sponsored gas work? (`03_Sponsor.sol`)

1. Deploy `Sponsor`, fund ~2 vmshell.
2. `call tryMint '{}'` twice; read `nativeBefore`, `nativeAfter`, `getNative`.

Expected: **no effect** (a self-rooted DApp has no configuration). Then **3b**: work out how a
DApp gets a configuration with SHELL credit (dev.ackinacki.com "Dapp ID Full Guide"), set it
up, and re-run. Also record the gas each call burns — that sets the minimum fee.

## Spike 4 — Born funded? (`04_Factory.sol`, `04_Child.sol`)

1. Compile both. Extract Child's code cell: `tvm-cli decode stateinit --tvc Child.tvc` (check `--help`).
2. Deploy `Factory` with `'{"childCode":"<base64 code>"}'`; fund it with 10 SHELL + 10 NACKL.
3. `call deployChild '{"shellAmount":5000000000,"nacklAmount":5000000000}'`
4. `run childAccountId '{"nonce":0}'` → read the child's `shellAtBirth`, `nacklAtBirth`.
5. Check the child's canonical address is `<FACTORY_HEX>::<child hash>` (it joined our DApp).

| Result | Decision |
|---|---|
| Child holds both currencies at birth | I1 (born funded) is implementable as designed. |
| Child holds nothing | Fund after deploy; lots stay "pending" until the watcher sees funds. |

## Spike 5 — Signature check (`05_SigCheck.sol`)  low risk

1. Deploy. `run quoteHash` with sample values → a hash.
2. Sign the hash off-chain with an ed25519 key (small script, added when we get here).
3. `run verify` with the hash, signature halves and pubkey → expect `true`; flip one bit → `false`.

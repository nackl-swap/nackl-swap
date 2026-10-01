#!/usr/bin/env bash
# Recover coins held in test lots, WITHOUT any wallet or key: only unsigned external messages
# (the Phase 2a keeper functions). For every lot the factory ever created:
#   release(maker) / release(taker) / release(treasury) if coins are owed,
#   reclaim() if the lot is still open past its deadline, then close() once settled.
# Addresses come from the last Phase 2a log. Run from WSL (~4 minutes):
#   cd <repo>/tests && bash recover_lots.sh
# Log: tests/out/recover.log
set -u
cd "$(dirname "$0")"
LOG=out/recover.log
: > "$LOG"
exec > >(tee -a "$LOG") 2>&1

SWAP_ABI=../contracts/AtomicSwap.abi.json
FACT_ABI=../contracts/SwapFactory.abi.json
GQL=https://shellnet.ackinacki.org/graphql
SRC=out/phase2a.log

say() { echo; echo "=== $(date -u +%H:%M:%S) $* ==="; }
die() { echo "STOPPING: $*"; exit 1; }
hex_of() { grep -m1 "^$1 " "$SRC" | awk '{print $2}' | cut -d: -f1; }

MHEX=$(hex_of maker); THEX=$(hex_of taker); FHEX=$(hex_of factory)
for h in "$MHEX" "$THEX" "$FHEX"; do [[ "$h" =~ ^[0-9a-f]{64}$ ]] || die "could not read addresses from $SRC"; done
FA="$FHEX::$FHEX"

acct() {
  curl -s -X POST "$GQL" -H 'Content-Type: application/json' \
    -d "{\"query\":\"{ blockchain { account(account_id:\\\"$1\\\", dapp_id:\\\"$2\\\") { info { acc_type balance(format:DEC) balance_other { currency value(format:DEC) } } } } }\"}"
}
bal() {
  acct "$1" "$2" | python3 -c 'import json,sys
i=(json.load(sys.stdin).get("data") or {}).get("blockchain",{}).get("account",{}).get("info")
if not i: print("0 0 0"); sys.exit()
o={int(float(x["currency"])):int(x["value"]) for x in i.get("balance_other") or []}
print(int(i["balance"]), o.get(1,0), o.get(2,0))'
}
active() { acct "$1" "$FHEX" | grep -c '"acc_type":1'; }
ext() { tvm-cli -j call "$FHEX::$1" "$2" "$3" --abi "$SWAP_ABI" 2>&1 | grep -E '"(exit_code|aborted)"' | tr -d '\n '; echo; }
field() { tvm-cli -j run "$FHEX::$1" "$2" "$3" --abi "$SWAP_ABI" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('$4','?'))"; }
owed_any() {  # lot owner -> 1 if anything owed
  tvm-cli -j run "$FHEX::$1" getOwed "{\"owner\":\"0:$2\"}" --abi "$SWAP_ABI" | python3 -c 'import json,sys
d=json.load(sys.stdin); print(1 if int(d.get("give",0))>0 or int(d.get("want",0))>0 else 0)'
}
totals() {
  local k=0 s=0
  for L in "${LOTS[@]}"; do read _ a b <<< "$(bal "$L" "$FHEX")"; k=$((k+a)); s=$((s+b)); done
  echo "lots hold: nackl $k  shell $s"
}

N=$(tvm-cli -j run "$FA" getInfo '{}' --abi "$FACT_ABI" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("lots",""))')
[[ "$N" =~ ^[0-9]+$ ]] || die "factory getInfo failed"
say "factory $FA has created $N lots"
LOTS=()
for ((i=0; i<N; i++)); do
  L=$(tvm-cli -j run "$FA" lotAccountId "{\"nonce\":\"$i\"}" --abi "$FACT_ABI" | python3 -c 'import json,sys
v=json.load(sys.stdin).get("value0",""); v=v[2:] if v.startswith("0x") else v; print(v.lower().rjust(64,"0"))')
  [ "$(active "$L")" = 1 ] && LOTS+=("$L")
done
echo "live lots: ${#LOTS[@]}"
[ "${#LOTS[@]}" -gt 0 ] || { echo "nothing to recover"; exit 0; }
read M0N M0K M0S <<< "$(bal "$MHEX" "$MHEX")"
read T0N T0K T0S <<< "$(bal "$THEX" "$THEX")"
totals

say "release owed coins and reclaim expired open lots"
NOW=$(date +%s)
for L in "${LOTS[@]}"; do
  ST=$(field "$L" getStatus '{}' state)
  echo "lot $L state=$ST"
  for O in "$MHEX" "$THEX" "$FHEX"; do
    if [ "$(owed_any "$L" "$O")" = 1 ]; then printf '  release %s… ' "${O:0:8}"; ext "$L" release "{\"owner\":\"0:$O\"}"; fi
  done
  if [ "$ST" = 0 ]; then
    DL=$(field "$L" getTimes '{}' deadline)
    if [ "$NOW" -ge "$DL" ]; then printf '  reclaim (expired) '; ext "$L" reclaim '{}';
    else echo "  still open until $(date -u -d "@$DL" +%H:%M) UTC: left alone"; fi
  fi
done
sleep 30
totals

say "close settled lots (waiting out the 60 s close delay)"
sleep 65
for L in "${LOTS[@]}"; do
  [ "$(active "$L")" = 1 ] || continue
  [ "$(field "$L" getStatus '{}' state)" = 0 ] && continue
  printf '  close %s… ' "${L:0:8}"; ext "$L" close '{}'
done
sleep 30

say "result"
LEFT=0; for L in "${LOTS[@]}"; do LEFT=$(( LEFT + $(active "$L") )); done
echo "lots still live: $LEFT (open lots before their deadline are expected to stay)"
totals
read M1N M1K M1S <<< "$(bal "$MHEX" "$MHEX")"
read T1N T1K T1S <<< "$(bal "$THEX" "$THEX")"
echo "maker recovered: nackl $(( M1K - M0K ))  shell $(( M1S - M0S ))"
echo "taker recovered: nackl $(( T1K - T0K ))  shell $(( T1S - T0S ))"

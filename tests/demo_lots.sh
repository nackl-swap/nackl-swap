#!/usr/bin/env bash
# Demo data for the web app (Shellnet only, test wallets from the Phase 2a suite).
#   bash demo_lots.sh          create 3 asks (sell NACKL for SHELL) + 1 bid (buy NACKL with SHELL), 6-day expiry
#   bash demo_lots.sh take     taker pays the cheapest open ask with a PLAIN transfer (pay-to-take)
# Run from WSL:  cd <repo>/tests && bash demo_lots.sh
set -u
cd "$(dirname "$0")"
MKEYS=../maker.keys.json
TKEYS=../taker.keys.json
FACT_ABI=../contracts/SwapFactory.abi.json
SWAP_ABI=../contracts/AtomicSwap.abi.json
WAL_ABI=TestWallet.abi.json
GQL=https://shellnet.ackinacki.org/graphql
EMPTY_CELL=te6ccgEBAQEAAgAAAA==
N=1000000000
SRC=out/phase2a.log

die() { echo "STOPPING: $*"; exit 1; }
hex_of() { grep -m1 "^$1 " "$SRC" | awk '{print $2}' | cut -d: -f1; }
MHEX=$(hex_of maker); THEX=$(hex_of taker); FHEX=$(hex_of factory)
for h in "$MHEX" "$THEX" "$FHEX"; do [[ "$h" =~ ^[0-9a-f]{64}$ ]] || die "could not read addresses from $SRC"; done
FA="$FHEX::$FHEX"

body() { tvm-cli body "$1" "$2" --abi "$3" | grep -oE 'te6[A-Za-z0-9+/=]+' | head -1; }
send() {  # keys walletHex destHex bounce eccJson payload
  tvm-cli -j call "$2::$2" sendTx \
    "{\"dest\":\"0:$3\",\"destDapp\":\"0x$FHEX\",\"value\":\"10000000\",\"bounce\":$4,\"cc\":$5,\"flags\":1,\"payload\":\"$6\"}" \
    --abi "$WAL_ABI" --sign "$1" | grep -E '"(exit_code|aborted|message)"' | tr -d '\n '; echo
}
lot() {  # giveId giveUnits wantId wantNano
  local dl=$(( $(date +%s) + 6 * 86400 ))
  local p; p=$(body createLot "{\"giveId\":$1,\"wantId\":$3,\"wantAmount\":\"$4\",\"deadline\":\"$dl\",\"makerDapp\":\"0x$MHEX\"}" "$FACT_ABI")
  printf '  lot: give %s of #%s for %s of #%s  ' "$2" "$1" "$4" "$3"
  send "$MKEYS" "$MHEX" "$FHEX" true "{\"$1\":\"$(( $2 * N ))\"}" "$p"
  sleep 12
}

if [ "${1:-}" = "take" ]; then
  # cheapest open ask: scan the newest lots via the factory's lotAccountId + balances
  COUNT=$(tvm-cli -j run "$FA" getInfo '{}' --abi "$FACT_ABI" | python3 -c 'import json,sys; print(json.load(sys.stdin)["lots"])')
  BEST=""; BESTP=""
  for ((i=COUNT-1; i>=0 && i>=COUNT-12; i--)); do
    L=$(tvm-cli -j run "$FA" lotAccountId "{\"nonce\":\"$i\"}" --abi "$FACT_ABI" | python3 -c 'import json,sys
v=json.load(sys.stdin)["value0"]; v=v[2:] if v.startswith("0x") else v; print(v.lower().rjust(64,"0"))')
    T=$(tvm-cli -j run "$FHEX::$L" getTerms '{}' --abi "$SWAP_ABI" 2>/dev/null | tr -d '\n ')
    S=$(tvm-cli -j run "$FHEX::$L" getStatus '{}' --abi "$SWAP_ABI" 2>/dev/null | python3 -c 'import json,sys
try: print(json.load(sys.stdin)["state"])
except Exception: print("x")')
    [ "$S" = 0 ] || continue
    read G W WA <<< "$(echo "$T" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["giveId"], d["wantId"], d["wantAmount"])')"
    [ "$G" = 1 ] && [ "$W" = 2 ] || continue
    if [ -z "$BESTP" ] || [ "$WA" -lt "$BESTP" ]; then BEST=$L; BESTP=$WA; fi
  done
  [ -n "$BEST" ] || die "no open NACKL-for-SHELL lot found; run: bash demo_lots.sh"
  echo "paying lot $BEST with $BESTP nano-SHELL (plain transfer, like the Acki Nacki Wallet app)"
  send "$TKEYS" "$THEX" "$BEST" true "{\"2\":\"$BESTP\"}" "$EMPTY_CELL"
  echo "watch the web app: the lot leaves the order book within a few seconds"
  exit 0
fi

echo "creating demo lots on factory $FA"
lot 1 1000 2 $(( 5 * N ))           # 1,000 NACKL for 5 SHELL   (0.005)
lot 1 2500 2 $(( 14 * N ))          # 2,500 NACKL for 14 SHELL  (0.0056)
lot 1 5000 2 $(( 30 * N ))          # 5,000 NACKL for 30 SHELL  (0.006)
lot 2 100 1 $(( 25000 * N ))        # 100 SHELL for 25,000 NACKL (0.004)
echo "done - reload the web app"

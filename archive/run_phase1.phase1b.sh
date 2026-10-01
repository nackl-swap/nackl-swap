#!/usr/bin/env bash
# Phase 1: AtomicSwap (FIXED price) end-to-end on Shellnet.
# Maker and taker are TestWallets in their own DApps, like real users. Every invariant is exercised
# as a real transaction and checked automatically (PASS / FAIL).
#
# Run from WSL (takes ~10 minutes, unattended):
#   cd <repo>/tests && bash run_phase1.sh
# Log: tests/out/phase1.log
set -u
cd "$(dirname "$0")"
mkdir -p out build
LOG=out/phase1.log
: > "$LOG"
exec > >(tee -a "$LOG") 2>&1

OWNER=../spike.keys.json
MKEYS=../maker.keys.json
TKEYS=../taker.keys.json
G=0000000000000000000000000000000000000000000000000000000000000000::1111111111111111111111111111111111111111111111111111111111111111
GABI=~/tools/GiverV3.abi.json
DAPPROOT=0000000000000000000000000000000000000000000000000000000000000000::9999999999999999999999999999999999999999999999999999999999999999
DAPPROOT_HEX=9999999999999999999999999999999999999999999999999999999999999999
ZERO_HEX=0000000000000000000000000000000000000000000000000000000000000000
ROOT_ABI=~/tools/DappRoot.abi.json
CFG_ABI=~/tools/DappConfig.abi.json
SWAP_ABI=../contracts/AtomicSwap.abi.json
FACT_ABI=../contracts/SwapFactory.abi.json
WAL_ABI=TestWallet.abi.json
GQL=https://shellnet.ackinacki.org/graphql
EMPTY_CELL=te6ccgEBAQEAAgAAAA==
N=1000000000                      # 1 unit of NACKL / SHELL / vmshell (9 decimals)
PASS=0; FAIL=0

say()      { echo; echo "=== $(date -u +%H:%M:%S) $* ==="; }
die()      { echo "STOPPING: $*"; exit 1; }
is_hex64() { [[ "$1" =~ ^[0-9a-f]{64}$ ]]; }
check() {  # name expected actual
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); echo "  PASS  $1  ($3)";
  else FAIL=$((FAIL+1)); echo "  FAIL  $1  expected=$2 actual=$3"; fi
}

# ---- chain reads ----
acct() {   # hex dapp -> JSON
  curl -s -X POST "$GQL" -H 'Content-Type: application/json' \
    -d "{\"query\":\"{ blockchain { account(account_id:\\\"$1\\\", dapp_id:\\\"$2\\\") { info { acc_type balance(format:DEC) balance_other { currency value(format:DEC) } } } } }\"}"
}
bal() {    # hex dapp -> "native nackl shell"
  acct "$1" "$2" | python3 -c 'import json,sys
i=(json.load(sys.stdin).get("data") or {}).get("blockchain",{}).get("account",{}).get("info")
if not i: print("0 0 0"); sys.exit()
o={int(float(x["currency"])):int(x["value"]) for x in i.get("balance_other") or []}
print(int(i["balance"]), o.get(1,0), o.get(2,0))'
}
nackl() { bal "$1" "$2" | cut -d' ' -f2; }
shell() { bal "$1" "$2" | cut -d' ' -f3; }
native() { bal "$1" "$2" | cut -d' ' -f1; }
active() { acct "$1" "$2" | grep -c '"acc_type":1'; }

lot_state() {  # lot hex -> state number
  tvm-cli -j run "$FHEX::$1" getStatus '{}' --abi "$SWAP_ABI" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("state","?"))'
}
lot_status() { tvm-cli -j run "$FHEX::$1" getStatus '{}' --abi "$SWAP_ABI" | tr -d '\n ' ; echo; }
lot_owed_give() {  # lot hex, owner raw -> owed give amount
  tvm-cli -j run "$FHEX::$1" getOwed "{\"owner\":\"$2\"}" --abi "$SWAP_ABI" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("give","?"))'
}

# ---- writes ----
give() {   # raw dest, ecc json, flag
  tvm-cli -j callx --abi "$GABI" --addr "$G" -m sendCurrencyWithFlag \
    "{\"dest\":\"$1\",\"value\":1000000000,\"ecc\":$2,\"flag\":$3}" | grep -E '"(exit_code|aborted)"' | tr -d '\n '; echo
}
body() {   # fn json abi -> base64 body
  tvm-cli body "$1" "$2" --abi "$3" | grep -oE 'te6[A-Za-z0-9+/=]+' | head -1
}
wsend() {  # keys walletHex destHex destDappHex eccJson flag payload
  tvm-cli -j call "$2::$2" sendTx \
    "{\"dest\":\"0:$3\",\"destDapp\":\"0x$4\",\"value\":\"10000000\",\"bounce\":true,\"cc\":$5,\"flags\":$6,\"payload\":\"$7\"}" \
    --abi "$WAL_ABI" --sign "$1" | grep -E '"(exit_code|aborted|message)"' | tr -d '\n '; echo
}
deploy_until_ready() {  # abi tvc keys params hex getter
  # An account can be active with its constructor never completed (Acki Nacki keeps the code even when
  # the constructor fails). Ready = a getter answers without error. Re-sending the deploy runs the
  # constructor on an active-but-uninitialised account.
  for try in 1 2 3; do
    tvm-cli -j run "$5::$5" "$6" '{}' --abi "$1" 2>&1 | grep -q '"Error"' || { echo "  ready: $2"; return 0; }
    echo "  deploy $2, attempt $try"
    tvm-cli -j deploy --abi "$1" --sign "$3" "$2" "$4" | grep -E '"(exit_code|message)"' | tr -d '\n '; echo
    sleep 10
  done
  tvm-cli -j run "$5::$5" "$6" '{}' --abi "$1" 2>&1 | grep -q '"Error"' && die "$2 not ready after 3 attempts"
  echo "  ready: $2"
}
genaddr_save() { # abi tvc keys -> hex
  tvm-cli -j genaddr --abi "$1" --setkey "$3" --save "$2" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("raw_address","")[2:])'
}

new_lot() {  # giveNackl wantShell deadlineSecs -> sets LOT (hex)
  local before; before=$(tvm-cli -j run "$FA" getInfo '{}' --abi "$FACT_ABI" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("lots",""))')
  [[ "$before" =~ ^[0-9]+$ ]] || die "factory getInfo did not return a lot count"
  local dl=$(( $(date +%s) + $3 ))
  local p; p=$(body createLot "{\"giveId\":1,\"wantId\":2,\"wantAmount\":\"$(( $2 * N ))\",\"deadline\":\"$dl\",\"makerDapp\":\"0x$MHEX\"}" "$FACT_ABI")
  wsend "$MKEYS" "$MHEX" "$FHEX" "$FHEX" "{\"1\":\"$(( $1 * N ))\"}" 1 "$p"
  sleep 20
  LOT=$(tvm-cli -j run "$FA" lotAccountId "{\"nonce\":\"$before\"}" --abi "$FACT_ABI" | python3 -c 'import json,sys
v=json.load(sys.stdin).get("value0","")
v=v[2:] if v.startswith("0x") else v
print(v.lower().rjust(64,"0"))')
  is_hex64 "$LOT" && [ "$LOT" != "$ZERO_HEX" ] || die "no valid lot id for nonce $before"
  for w in 1 2 3; do [ "$(active "$LOT" "$FHEX")" = 1 ] && break; sleep 8; done
  [ "$(active "$LOT" "$FHEX")" = 1 ] || die "lot #$before is not live on chain"
  echo "  lot #$before: $FHEX::$LOT  (give $1 NACKL, want $2 SHELL, deadline +$3s)"
}
take() {     # lotHex shellAmount flag
  local p; p=$(body take "{\"takerDapp\":\"0x$THEX\"}" "$SWAP_ABI")
  wsend "$TKEYS" "$THEX" "$1" "$FHEX" "{\"2\":\"$(( $2 * N ))\"}" "$3" "$p"
}
reclaim_as() { # keys walletHex lotHex
  local p; p=$(body reclaim '{}' "$SWAP_ABI")
  wsend "$1" "$2" "$3" "$FHEX" '{}' 1 "$p"
}

# =====================================================================
say "compile"
( cd ../contracts && rm -f AtomicSwap.tvc SwapFactory.tvc \
  && sold --tvm-version gosh AtomicSwap.sol && sold --tvm-version gosh SwapFactory.sol ) || die "contract compile failed"
rm -f TestWallet.tvc; sold --tvm-version gosh TestWallet.sol || die "wallet compile failed"
LOT_CODE=$(tvm-cli -j decode stateinit --tvc ../contracts/AtomicSwap.tvc | python3 -c 'import json,sys; print(json.load(sys.stdin).get("code",""))')
[ -n "$LOT_CODE" ] || die "no lot code"

say "test keys (Shellnet only)"
[ -f "$MKEYS" ] || tvm-cli genphrase --dump "$MKEYS" >/dev/null
[ -f "$TKEYS" ] || tvm-cli genphrase --dump "$TKEYS" >/dev/null
cp TestWallet.tvc build/maker.tvc; cp TestWallet.tvc build/taker.tvc
cp ../contracts/SwapFactory.tvc build/factory.tvc
MHEX=$(genaddr_save "$WAL_ABI" build/maker.tvc "$MKEYS");   is_hex64 "$MHEX" || die "maker addr"
THEX=$(genaddr_save "$WAL_ABI" build/taker.tvc "$TKEYS");   is_hex64 "$THEX" || die "taker addr"
FHEX=$(genaddr_save "$FACT_ABI" build/factory.tvc "$OWNER"); is_hex64 "$FHEX" || die "factory addr"
FA="$FHEX::$FHEX"
echo "maker   $MHEX::$MHEX"; echo "taker   $THEX::$THEX"; echo "factory $FA"

say "fund from the giver"
give "0:$MHEX" '{"2":"3000000000"}' 16
give "0:$MHEX" "{\"1\":\"$(( 10100 * N ))\"}" 1
give "0:$THEX" '{"2":"3000000000"}' 16
give "0:$THEX" "{\"2\":\"$(( 1000 * N ))\"}" 1
give "0:$FHEX" '{"2":"5000000000"}' 16
give "0:$FHEX" "{\"2\":\"$(( 130 * N ))\"}" 1
sleep 20

say "deploy wallets and factory"
deploy_until_ready "$WAL_ABI" build/maker.tvc "$MKEYS" '{}' "$MHEX" rejecting
deploy_until_ready "$WAL_ABI" build/taker.tvc "$TKEYS" '{}' "$THEX" rejecting
deploy_until_ready "$FACT_ABI" build/factory.tvc "$OWNER" "{\"lotCode\":\"$LOT_CODE\",\"feeBps\":\"100\",\"closeDelay\":\"60\"}" "$FHEX" getInfo

say "create the factory's DappConfig (120 SHELL credit)"
P=$(tvm-cli body deployNewConfigCustom '{"authorityAddress":null}' --abi "$ROOT_ABI" | grep -oE 'te6[A-Za-z0-9+/=]+' | head -1)
tvm-cli -j call "$FA" sendTransaction \
  "{\"dest\":\"0:$DAPPROOT_HEX\",\"destDapp\":\"0x$ZERO_HEX\",\"value\":\"10000000\",\"bounce\":false,\"cc\":{\"2\":\"$(( 120 * N ))\"},\"flags\":1,\"payload\":\"$P\"}" \
  --abi "$FACT_ABI" --sign "$OWNER" | grep -E '"(exit_code|aborted|message)"' | tr -d '\n '; echo
sleep 20
CFG=$(tvm-cli -j run "$DAPPROOT" getConfigAddr "{\"dapp_id\":\"0x$FHEX\"}" --abi "$ROOT_ABI" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("config","")[2:])')
is_hex64 "$CFG" || die "no DappConfig address"
tvm-cli -j run "$FHEX::$CFG" getDetails '{}' --abi "$CFG_ABI" | tr -d '\n '; echo
INFO=$(tvm-cli -j run "$FA" getInfo '{}' --abi "$FACT_ABI" | tr -d '\n ')
echo "$INFO"; echo "$INFO" | grep -q '"lots"' || die "factory getInfo failed"

read M0N M0K M0S <<< "$(bal "$MHEX" "$MHEX")"
read T0N T0K T0S <<< "$(bal "$THEX" "$THEX")"
read F0N F0K F0S <<< "$(bal "$FHEX" "$FHEX")"
echo "start: maker nackl=$M0K shell=$M0S | taker nackl=$T0K shell=$T0S | factory shell=$F0S"

# =====================================================================
say "T1 happy path: lot 2000 NACKL for 100 SHELL; taker pays exactly 100"
new_lot 2000 100 3600; L0=$LOT
check "T1 lot born funded (holds 2000 NACKL)" "$(( 2000 * N ))" "$(nackl "$L0" "$FHEX")"
MS=$(shell "$MHEX" "$MHEX"); TK=$(nackl "$THEX" "$THEX"); FS=$(shell "$FHEX" "$FHEX")
take "$L0" 100 1; sleep 25
check "T1 lot state FILLED" 1 "$(lot_state "$L0")"
check "T1 maker got 99 SHELL (100 - 1% fee)" "$(( 99 * N ))" "$(( $(shell "$MHEX" "$MHEX") - MS ))"
check "T1 taker got 2000 NACKL" "$(( 2000 * N ))" "$(( $(nackl "$THEX" "$THEX") - TK ))"
check "T1 treasury got 1 SHELL fee" "$(( 1 * N ))" "$(( $(shell "$FHEX" "$FHEX") - FS ))"
check "T1 lot holds nothing" 0 "$(nackl "$L0" "$FHEX")"

say "T2 underpay (rejected before gas) then overpay (fill + change): lot 1000 NACKL for 50 SHELL"
new_lot 1000 50 3600; L1=$LOT
TS=$(shell "$THEX" "$THEX"); LN=$(native "$L1" "$FHEX")
take "$L1" 40 1; sleep 25
check "T2a underpaid lot still OPEN" 0 "$(lot_state "$L1")"
check "T2a taker's 40 SHELL came back" "$TS" "$(shell "$THEX" "$THEX")"
LD=$(( $(native "$L1" "$FHEX") - LN )); LDA=${LD#-}
echo "  info: lot native delta on rejected take: $LD (a real execution costs ~3000000)"
check "T2a rejection cost the lot < 0.001 vmshell (drain test)" yes "$([ "$LDA" -lt 1000000 ] && echo yes || echo no)"
MS=$(shell "$MHEX" "$MHEX"); TS=$(shell "$THEX" "$THEX"); TK=$(nackl "$THEX" "$THEX")
take "$L1" 60 1; sleep 25
check "T2b overpaid lot FILLED" 1 "$(lot_state "$L1")"
check "T2b taker net -50 SHELL (10 change returned)" "-$(( 50 * N ))" "$(( $(shell "$THEX" "$THEX") - TS ))"
check "T2b taker got 1000 NACKL" "$(( 1000 * N ))" "$(( $(nackl "$THEX" "$THEX") - TK ))"
check "T2b maker got 49.5 SHELL" "$(( 495 * N / 10 ))" "$(( $(shell "$MHEX" "$MHEX") - MS ))"

say "T3 double take: two takes back to back on one lot (1000 NACKL for 50 SHELL)"
new_lot 1000 50 3600; L2=$LOT
TS=$(shell "$THEX" "$THEX")
take "$L2" 50 1; take "$L2" 50 1; sleep 30
check "T3 lot FILLED once" 1 "$(lot_state "$L2")"
check "T3 taker charged once (-50 SHELL)" "-$(( 50 * N ))" "$(( $(shell "$THEX" "$THEX") - TS ))"

say "T4 reclaim rules: stranger cannot reclaim; maker can; late take is refused"
new_lot 1000 50 3600; L3=$LOT
reclaim_as "$TKEYS" "$THEX" "$L3"; sleep 20
check "T4a taker's reclaim refused, lot OPEN" 0 "$(lot_state "$L3")"
MK=$(nackl "$MHEX" "$MHEX")
reclaim_as "$MKEYS" "$MHEX" "$L3"; sleep 25
check "T4b maker reclaim -> RECLAIMED" 2 "$(lot_state "$L3")"
check "T4b maker got 1000 NACKL back" "$(( 1000 * N ))" "$(( $(nackl "$MHEX" "$MHEX") - MK ))"
TS=$(shell "$THEX" "$THEX")
take "$L3" 50 1; sleep 25
check "T4c take after reclaim refused, SHELL returned" "$TS" "$(shell "$THEX" "$THEX")"

say "T5 taker's wallet sends SHELL with flag 16 (arrives as gas, not SHELL)"
new_lot 1000 50 3600; L4=$LOT
read TN TK TS <<< "$(bal "$THEX" "$THEX")"
take "$L4" 50 16; sleep 25
check "T5 lot still OPEN (flag-16 SHELL is not payment)" 0 "$(lot_state "$L4")"
read TN2 TK2 TS2 <<< "$(bal "$THEX" "$THEX")"
echo "  info: taker SHELL delta $(( TS2 - TS )), native delta $(( TN2 - TN ))"
check "T5 no SHELL stranded in the lot (I4)" 0 "$(shell "$L4" "$FHEX")"
VAL=$(( (TS2 - TS) + (TN2 - TN) )); VALA=${VAL#-}
check "T5 taker value returned (SHELL + gas within 0.1)" yes "$([ "$VALA" -lt 100000000 ] && echo yes || echo no)"
reclaim_as "$MKEYS" "$MHEX" "$L4"; sleep 20

say "T6 bounced payout -> owed -> claim"
new_lot 1000 50 3600; L5=$LOT
tvm-cli -j call "$THEX::$THEX" setRejecting '{"value":true}' --abi "$WAL_ABI" --sign "$TKEYS" | grep -E '"exit_code"' | tr -d '\n '; echo
sleep 10
TK=$(nackl "$THEX" "$THEX")
take "$L5" 50 1; sleep 30
check "T6a lot FILLED" 1 "$(lot_state "$L5")"
check "T6a taker did not receive (rejecting)" "$TK" "$(nackl "$THEX" "$THEX")"
check "T6a lot owes taker 1000 NACKL" "$(( 1000 * N ))" "$(lot_owed_give "$L5" "0:$THEX")"
tvm-cli -j call "$THEX::$THEX" setRejecting '{"value":false}' --abi "$WAL_ABI" --sign "$TKEYS" | grep -E '"exit_code"' | tr -d '\n '; echo
sleep 10
P=$(body claim "{\"myDapp\":\"0x$THEX\"}" "$SWAP_ABI")
wsend "$TKEYS" "$THEX" "$L5" "$FHEX" '{}' 1 "$P"; sleep 25
check "T6b taker claimed 1000 NACKL" "$(( 1000 * N ))" "$(( $(nackl "$THEX" "$THEX") - TK ))"
check "T6b nothing owed any more" 0 "$(lot_owed_give "$L5" "0:$THEX")"

say "T7 deadline: lot with 90 s deadline; take after expiry refused; maker reclaims"
new_lot 1000 50 90; L6=$LOT
echo "  waiting for the deadline..."; sleep 100
TS=$(shell "$THEX" "$THEX")
take "$L6" 50 1; sleep 25
check "T7a expired lot still OPEN" 0 "$(lot_state "$L6")"
check "T7a taker's SHELL returned" "$TS" "$(shell "$THEX" "$THEX")"
MK=$(nackl "$MHEX" "$MHEX")
reclaim_as "$TKEYS" "$THEX" "$L6"; sleep 25
check "T7b stranger may reclaim after deadline -> RECLAIMED" 2 "$(lot_state "$L6")"
check "T7b ...and the coins went to the MAKER" "$(( 1000 * N ))" "$(( $(nackl "$MHEX" "$MHEX") - MK ))"

say "T8 routing: does a wrong dest_dapp_id still reach an existing wallet?"
TK=$(nackl "$THEX" "$THEX")
wsend "$MKEYS" "$MHEX" "$THEX" "$THEX" "{\"1\":\"$N\"}" 1 "$EMPTY_CELL"; sleep 20
check "T8a correct dapp id: taker +1 NACKL" "$N" "$(( $(nackl "$THEX" "$THEX") - TK ))"
TK=$(nackl "$THEX" "$THEX")
wsend "$MKEYS" "$MHEX" "$THEX" "$FHEX" "{\"1\":\"$N\"}" 1 "$EMPTY_CELL"; sleep 20
echo "  info: wrong dapp id (factory's): taker NACKL delta $(( $(nackl "$THEX" "$THEX") - TK )) (1e9 = routed by account id; 0 = not delivered)"

# =====================================================================

say "T9 take carrying an unexpected extra currency is refused (F3)"
new_lot 1000 50 3600; L7=$LOT
read TN TK TS <<< "$(bal "$THEX" "$THEX")"
P=$(body take "{\"takerDapp\":\"0x$THEX\"}" "$SWAP_ABI")
wsend "$TKEYS" "$THEX" "$L7" "$FHEX" "{\"2\":\"$(( 50 * N ))\",\"1\":\"$N\"}" 1 "$P"; sleep 25
read TN2 TK2 TS2 <<< "$(bal "$THEX" "$THEX")"
check "T9 lot still OPEN" 0 "$(lot_state "$L7")"
check "T9 taker's SHELL returned" "$TS" "$TS2"
check "T9 taker's extra NACKL returned" "$TK" "$TK2"
check "T9 nothing stranded in the lot's want side" 0 "$(shell "$L7" "$FHEX")"
reclaim_as "$MKEYS" "$MHEX" "$L7"; sleep 20

say "T10 createLot carrying an unexpected extra currency is refused (F3)"
BEFORE=$(tvm-cli -j run "$FA" getInfo '{}' --abi "$FACT_ABI" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("lots",""))')
read MN MK MS <<< "$(bal "$MHEX" "$MHEX")"
DL=$(( $(date +%s) + 3600 ))
P=$(body createLot "{\"giveId\":1,\"wantId\":2,\"wantAmount\":\"$(( 50 * N ))\",\"deadline\":\"$DL\",\"makerDapp\":\"0x$MHEX\"}" "$FACT_ABI")
wsend "$MKEYS" "$MHEX" "$FHEX" "$FHEX" "{\"1\":\"$(( 1000 * N ))\",\"2\":\"$N\"}" 1 "$P"; sleep 25
read MN2 MK2 MS2 <<< "$(bal "$MHEX" "$MHEX")"
AFTER=$(tvm-cli -j run "$FA" getInfo '{}' --abi "$FACT_ABI" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("lots",""))')
check "T10 no lot created" "$BEFORE" "$AFTER"
check "T10 maker's NACKL returned" "$MK" "$MK2"
check "T10 maker's extra SHELL returned" "$MS" "$MS2"

say "T11 close(): refused while open or too early; deletes a settled lot after the delay (F1)"
new_lot 1000 50 3600; L8=$LOT
P=$(body close '{}' "$SWAP_ABI")
wsend "$TKEYS" "$THEX" "$L8" "$FHEX" '{}' 1 "$P"; sleep 20
check "T11a close on an OPEN lot refused" 1 "$(active "$L8" "$FHEX")"
reclaim_as "$MKEYS" "$MHEX" "$L8"; sleep 20
wsend "$TKEYS" "$THEX" "$L8" "$FHEX" '{}' 1 "$P"; sleep 20
check "T11b close right after settlement refused (delay)" 1 "$(active "$L8" "$FHEX")"
echo "  waiting out the 60 s close delay..."; sleep 65
FN=$(native "$FHEX" "$FHEX")
wsend "$TKEYS" "$THEX" "$L8" "$FHEX" '{}' 1 "$P"; sleep 25
check "T11c settled lot deleted after the delay" 0 "$(active "$L8" "$FHEX")"
echo "  info: factory native change from closing one lot: $(( $(native "$FHEX" "$FHEX") - FN )) (lot gas returned)"

say "T11d close every other settled lot (gas recovery)"
FN=$(native "$FHEX" "$FHEX")
for L in $L0 $L1 $L2 $L3 $L4 $L5 $L6 $L7; do wsend "$TKEYS" "$THEX" "$L" "$FHEX" '{}' 1 "$P"; done
sleep 30
OPENLEFT=0; for L in $L0 $L1 $L2 $L3 $L4 $L5 $L6 $L7; do OPENLEFT=$(( OPENLEFT + $(active "$L" "$FHEX") )); done
check "T11d all settled lots deleted" 0 "$OPENLEFT"
echo "  info: factory native change from closing 8 lots: $(( $(native "$FHEX" "$FHEX") - FN ))"

say "final balances and conservation"
read M1N M1K M1S <<< "$(bal "$MHEX" "$MHEX")"
read T1N T1K T1S <<< "$(bal "$THEX" "$THEX")"
read F1N F1K F1S <<< "$(bal "$FHEX" "$FHEX")"
echo "maker   nackl $M0K -> $M1K   shell $M0S -> $M1S"
echo "taker   nackl $T0K -> $T1K   shell $T0S -> $T1S"
echo "factory shell $F0S -> $F1S"
LOTS_K=0; LOTS_S=0
for L in $L0 $L1 $L2 $L3 $L4 $L5 $L6 $L7 $L8; do read _ k s <<< "$(bal "$L" "$FHEX")"; LOTS_K=$((LOTS_K+k)); LOTS_S=$((LOTS_S+s)); done
echo "all lots hold: nackl $LOTS_K  shell $LOTS_S"
check "NACKL conserved across maker + taker + lots" "$(( M0K + T0K ))" "$(( M1K + T1K + LOTS_K ))"
check "no NACKL left in any lot (all settled)" 0 "$LOTS_K"
check "no SHELL left in any lot (I4)" 0 "$LOTS_S"
echo "  info: SHELL total maker+taker+factory $(( M0S + T0S + F0S )) -> $(( M1S + T1S + F1S ))"
tvm-cli -j run "$FA" getInfo '{}' --abi "$FACT_ABI" | tr -d '\n '; echo

say "RESULT: $PASS passed, $FAIL failed — log: tests/$LOG"

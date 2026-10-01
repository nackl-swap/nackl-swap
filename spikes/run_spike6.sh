#!/usr/bin/env bash
# Spike 6: plain transfers (what the Acki Nacki Wallet app can do) into a contract.
#   a) can the contract read the bounce flag?  b) flag 1 vs flag 16 SHELL
#   c) does a refused NON-bounceable transfer strand coins?  d) wrong dest_dapp_id to an existing contract
# Sender = the Phase 1 taker TestWallet (its own DApp, like a real user). Shellnet only, test keys only.
# Run from WSL (~6 minutes):
#   cd <repo>/spikes && bash run_spike6.sh
# Log: spikes/out/spike6.log
set -u
cd "$(dirname "$0")"
mkdir -p out
LOG=out/spike6.log
: > "$LOG"
exec > >(tee -a "$LOG") 2>&1

OWNER=../spike.keys.json
TKEYS=../taker.keys.json
G=0000000000000000000000000000000000000000000000000000000000000000::1111111111111111111111111111111111111111111111111111111111111111
GABI=~/tools/GiverV3.abi.json
PABI=06_TransferProbe.abi.json
WAL_ABI=../tests/TestWallet.abi.json
GQL=https://shellnet.ackinacki.org/graphql
EMPTY_CELL=te6ccgEBAQEAAgAAAA==
N=1000000000

say() { echo; echo "=== $(date -u +%H:%M:%S) $* ==="; }
die() { echo "STOPPING: $*"; exit 1; }

acct() {
  curl -s -X POST "$GQL" -H 'Content-Type: application/json' \
    -d "{\"query\":\"{ blockchain { account(account_id:\\\"$1\\\", dapp_id:\\\"$2\\\") { info { acc_type balance(format:DEC) balance_other { currency value(format:DEC) } } } } }\"}"
}
bal() {  # hex dapp -> "native nackl shell"
  acct "$1" "$2" | python3 -c 'import json,sys
i=(json.load(sys.stdin).get("data") or {}).get("blockchain",{}).get("account",{}).get("info")
if not i: print("0 0 0"); sys.exit()
o={int(float(x["currency"])):int(x["value"]) for x in i.get("balance_other") or []}
print(int(i["balance"]), o.get(1,0), o.get(2,0))'
}
give() {  # raw dest, ecc json, flag
  tvm-cli -j callx --abi "$GABI" --addr "$G" -m sendCurrencyWithFlag \
    "{\"dest\":\"$1\",\"value\":1000000000,\"ecc\":$2,\"flag\":$3}" | grep -E '"(exit_code|aborted)"' | tr -d '\n '; echo
}
genaddr_save() {  # abi tvc keys -> hex
  tvm-cli -j genaddr --abi "$1" --setkey "$3" --save "$2" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("raw_address","")[2:])'
}
tsend() {  # destDappHex bounce eccJson flag  (plain transfer, empty body, from the taker wallet)
  tvm-cli -j call "$THEX::$THEX" sendTx \
    "{\"dest\":\"0:$PHEX\",\"destDapp\":\"0x$1\",\"value\":\"10000000\",\"bounce\":$2,\"cc\":$3,\"flags\":$4,\"payload\":\"$EMPTY_CELL\"}" \
    --abi "$WAL_ABI" --sign "$TKEYS" | grep -E '"(exit_code|aborted|message)"' | tr -d '\n '; echo
}
count() { tvm-cli -j run "$PA" count '{}' --abi "$PABI" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("count","?"))'; }
seen() { tvm-cli -j run "$PA" getSeen "{\"i\":$1}" --abi "$PABI" | python3 -c 'import json,sys
d=json.load(sys.stdin); h=int(d["head"])
print("head=%s bits=%s bounce=%s listedN=%s listedS=%s holdN=%s holdS=%s native=%s" % (h, format(h,"08b"), d["bounce"], d["listedNackl"], d["listedShell"], d["holdNackl"], d["holdShell"], d["native"]))'; }

# case NAME destDapp bounce ecc flag : sends, then prints balance deltas for probe and taker
case_() {
  say "$1"
  read PN0 PK0 PS0 <<< "$(bal "$PHEX" "$PHEX")"
  read TN0 TK0 TS0 <<< "$(bal "$THEX" "$THEX")"
  local c0; c0=$(count)
  tsend "$2" "$3" "$4" "$5"; sleep 25
  read PN1 PK1 PS1 <<< "$(bal "$PHEX" "$PHEX")"
  read TN1 TK1 TS1 <<< "$(bal "$THEX" "$THEX")"
  local c1; c1=$(count)
  echo "  probe  d_native=$(( PN1 - PN0 )) d_nackl=$(( PK1 - PK0 )) d_shell=$(( PS1 - PS0 ))   receive() ran: $(( c1 - c0 ))"
  echo "  taker  d_native=$(( TN1 - TN0 )) d_nackl=$(( TK1 - TK0 )) d_shell=$(( TS1 - TS0 ))"
  if [ "$c1" != "$c0" ]; then echo "  seen[$c0]: $(seen "$c0")"; fi
}

say "compile"
rm -f 06_TransferProbe.tvc && sold --tvm-version gosh 06_TransferProbe.sol || die "probe compile failed"
( cd ../tests && rm -f TestWallet.tvc && sold --tvm-version gosh TestWallet.sol ) || die "wallet compile failed"
cp ../tests/TestWallet.tvc out/taker6.tvc

PHEX=$(genaddr_save "$PABI" 06_TransferProbe.tvc "$OWNER"); [[ "$PHEX" =~ ^[0-9a-f]{64}$ ]] || die "probe addr"
THEX=$(genaddr_save "$WAL_ABI" out/taker6.tvc "$TKEYS");    [[ "$THEX" =~ ^[0-9a-f]{64}$ ]] || die "taker addr"
PA="$PHEX::$PHEX"
echo "probe $PA"; echo "taker $THEX::$THEX"

say "fund"
give "0:$PHEX" '{"2":"3000000000"}' 16
give "0:$THEX" '{"2":"3000000000"}' 16
give "0:$THEX" "{\"1\":\"$(( 20 * N ))\"}" 1
give "0:$THEX" "{\"2\":\"$(( 20 * N ))\"}" 1
sleep 20

say "deploy probe"
for try in 1 2 3; do
  tvm-cli -j run "$PA" count '{}' --abi "$PABI" 2>&1 | grep -q '"Error"' || break
  echo "  deploy attempt $try"
  tvm-cli -j deploy --abi "$PABI" --sign "$OWNER" 06_TransferProbe.tvc '{}' | grep -E '"(exit_code|message)"' | tr -d '\n '; echo
  sleep 10
done
[ "$(count)" = "0" ] || echo "  note: probe count is $(count) (re-run on an existing probe)"
tvm-cli -j run "$THEX::$THEX" rejecting '{}' --abi "$WAL_ABI" | tr -d '\n '; echo

say "probe ACCEPTING"
case_ "C1 bounce=true  flag1  1 NACKL"  "$PHEX" true  "{\"1\":\"$N\"}" 1
case_ "C2 bounce=false flag1  1 NACKL"  "$PHEX" false "{\"1\":\"$N\"}" 1
case_ "C3 bounce=false flag1  1 SHELL"  "$PHEX" false "{\"2\":\"$N\"}" 1
case_ "C4 bounce=false flag16 1 SHELL"  "$PHEX" false "{\"2\":\"$N\"}" 16
case_ "C5 bounce=true  flag16 1 SHELL"  "$PHEX" true  "{\"2\":\"$N\"}" 16
case_ "C6 WRONG dest dapp (taker's own), bounce=false flag1 1 NACKL" "$THEX" false "{\"1\":\"$N\"}" 1

say "probe REFUSING"
tvm-cli -j call "$PA" setRefusing '{"value":true}' --abi "$PABI" --sign "$OWNER" | grep -E '"(exit_code|message)"' | tr -d '\n '; echo
sleep 15
tvm-cli -j run "$PA" refusing '{}' --abi "$PABI" | tr -d '\n '; echo
case_ "C7 refused, bounce=true  flag1  1 NACKL" "$PHEX" true  "{\"1\":\"$N\"}" 1
case_ "C8 refused, bounce=false flag1  1 NACKL" "$PHEX" false "{\"1\":\"$N\"}" 1
case_ "C9 refused, bounce=true  flag16 1 SHELL" "$PHEX" true  "{\"2\":\"$N\"}" 16
case_ "C10 refused, bounce=false flag16 1 SHELL" "$PHEX" false "{\"2\":\"$N\"}" 16

say "done - log in spikes/out/spike6.log"

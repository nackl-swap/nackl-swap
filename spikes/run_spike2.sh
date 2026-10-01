#!/usr/bin/env bash
# Spike 2: when a message carrying SHELL bounces, does the SHELL come back?
# Run from WSL:
#   cd <repo>/spikes && bash run_spike2.sh
# Everything is also written to out/spike2.log (the assistant reads it directly).
set -u
cd "$(dirname "$0")"
mkdir -p out
LOG=out/spike2.log
exec > >(tee -a "$LOG") 2>&1

KEYS=../spike.keys.json
G=0000000000000000000000000000000000000000000000000000000000000000::1111111111111111111111111111111111111111111111111111111111111111
GABI=~/tools/GiverV3.abi.json
EMPTY=0:9999999999999999999999999999999999999999999999999999999999999999
GQL=https://shellnet.ackinacki.org/graphql

say()   { echo; echo "=== $(date -u +%H:%M:%S) $* ==="; }
canon() { local h=${1#0:}; echo "$h::$h"; }

addr_of() {  # $1 = contract basename -> prints raw 0:HEX (and bakes the key into the .tvc)
  tvm-cli -j genaddr --abi "$1.abi.json" --setkey "$KEYS" --save "$1.tvc" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["raw_address"])'
}

give() {     # $1 = raw dest, $2 = ecc json, $3 = flag
  tvm-cli -j callx --abi "$GABI" --addr "$G" -m sendCurrencyWithFlag \
    "{\"dest\":\"$1\",\"value\":1000000000,\"ecc\":$2,\"flag\":$3}" \
    | grep -E '"(exit_code|aborted|tx_hash|message)"'
}

state() {    # $1 = raw address -> account JSON from Shellnet
  local h=${1#0:}
  curl -s -X POST "$GQL" -H 'Content-Type: application/json' \
    -d "{\"query\":\"{ blockchain { account(account_id:\\\"$h\\\", dapp_id:\\\"$h\\\") { info { acc_type balance(format:DEC) balance_other { currency value(format:DEC) } } } } }\"}"
  echo
}

is_active() {
  state "$1" | python3 -c 'import json,sys
d=json.load(sys.stdin); i=d["data"]["blockchain"]["account"]["info"]
print(1 if i and i.get("acc_type")==1 else 0)'
}

deploy_until_active() {  # $1 = basename, $2 = raw address
  for try in 1 2 3; do
    [ "$(is_active "$2")" = 1 ] && break
    echo "deploy $1, attempt $try"
    tvm-cli -j deploy --abi "$1.abi.json" --sign "$KEYS" "$1.tvc" '{}' \
      | grep -E '"(exit_code|deployed_at|code|message)"'
    sleep 8
  done
  echo "$1 active: $(is_active "$2")"
}

read_probe() {  # $1 = canonical probe address
  for g in shellBeforeSend shellAfterBounce nativeAfterBounce bounces getShell; do
    printf '%s: ' "$g"
    tvm-cli -j run "$1" "$g" '{}' --abi 02_BounceProbe.abi.json | tr -d '\n '
    echo
  done
}

say "compile"
sold 02_Rejector.sol
sold 02_BounceProbe.sol

say "addresses (genaddr --save)"
R=$(addr_of 02_Rejector)
B=$(addr_of 02_BounceProbe)
BA=$(canon "$B")
echo "Rejector:    $R"
echo "BounceProbe: $B"

say "fund: gas via flag-16 SHELL, plus 3 SHELL (flag 1) for the probe to send"
give "$R" '{"2":1000000000}' 16
give "$B" '{"2":1000000000}' 16
give "$B" '{"2":3000000000}' 1
sleep 15
echo "Rejector state:";    state "$R"
echo "BounceProbe state:"; state "$B"

say "deploy"
deploy_until_active 02_Rejector "$R"
deploy_until_active 02_BounceProbe "$B"

say "test A: send 1 SHELL (bounce=true) to the Rejector, which reverts"
tvm-cli -j call "$BA" sendBouncing "{\"dest\":\"$R\",\"shellAmount\":1000000000,\"flag\":1}" \
  --abi 02_BounceProbe.abi.json --sign "$KEYS" | grep -E '"(exit_code|aborted|tx_hash|message)"'
sleep 20
read_probe "$BA"
echo "BounceProbe state:"; state "$B"
echo "Rejector state:";    state "$R"

say "test B: send 1 SHELL (bounce=true) to a never-deployed address"
tvm-cli -j call "$BA" sendBouncing "{\"dest\":\"$EMPTY\",\"shellAmount\":1000000000,\"flag\":1}" \
  --abi 02_BounceProbe.abi.json --sign "$KEYS" | grep -E '"(exit_code|aborted|tx_hash|message)"'
sleep 20
read_probe "$BA"
echo "BounceProbe state:"; state "$B"
echo "Empty address state:"; state "$EMPTY"

say "done — log: spikes/$LOG"

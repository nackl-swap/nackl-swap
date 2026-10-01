#!/usr/bin/env bash
# Spike 4b: as spike 4, plus: can a child mint gas from our DappConfig in a LATER call (poke)?
# Run from WSL:
#   cd <repo>/spikes && bash run_spike4b.sh
# Log: out/spike4b.log
set -u
cd "$(dirname "$0")"
mkdir -p out
LOG=out/spike4b.log
exec > >(tee -a "$LOG") 2>&1

KEYS=../spike.keys.json
G=0000000000000000000000000000000000000000000000000000000000000000::1111111111111111111111111111111111111111111111111111111111111111
GABI=~/tools/GiverV3.abi.json
DAPPROOT=0000000000000000000000000000000000000000000000000000000000000000::9999999999999999999999999999999999999999999999999999999999999999
DAPPROOT_RAW=0:9999999999999999999999999999999999999999999999999999999999999999
ROOT_ABI=~/tools/DappRoot.abi.json
CFG_ABI=~/tools/DappConfig.abi.json
GQL=https://shellnet.ackinacki.org/graphql

say()      { echo; echo "=== $(date -u +%H:%M:%S) $* ==="; }
die()      { echo "STOPPING: $*"; exit 1; }
is_hex64() { [[ "$1" =~ ^[0-9a-f]{64}$ ]]; }

acct() {   # $1 = account hex, $2 = dapp hex
  curl -s -X POST "$GQL" -H 'Content-Type: application/json' \
    -d "{\"query\":\"{ blockchain { account(account_id:\\\"$1\\\", dapp_id:\\\"$2\\\") { info { acc_type balance(format:DEC) balance_other { currency value(format:DEC) } } } } }\"}"
  echo
}

native_of() {  # $1 = account hex, $2 = dapp hex -> native balance (nano) or 0
  acct "$1" "$2" | python3 -c 'import json,sys
i=json.load(sys.stdin)["data"]["blockchain"]["account"]["info"]
print(int(i["balance"]) if i else 0)'
}

give() {   # $1 = raw dest, $2 = ecc json, $3 = flag
  tvm-cli -j callx --abi "$GABI" --addr "$G" -m sendCurrencyWithFlag \
    "{\"dest\":\"$1\",\"value\":1000000000,\"ecc\":$2,\"flag\":$3}" \
    | grep -E '"(exit_code|aborted|tx_hash|message)"'
}

say "compile (--tvm-version gosh)"
rm -f 04_Child.tvc 04_Child.abi.json 04_Factory.tvc 04_Factory.abi.json
sold --tvm-version gosh 04_Child.sol   || die "Child compile failed"
sold --tvm-version gosh 04_Factory.sol || die "Factory compile failed"
[ -s 04_Child.tvc ] && [ -s 04_Factory.tvc ] || die "missing .tvc output"

say "child code cell"
CHILD_CODE=$(tvm-cli -j decode stateinit --tvc 04_Child.tvc \
               | python3 -c 'import json,sys; print(json.load(sys.stdin).get("code",""))')
[ -n "$CHILD_CODE" ] || die "could not extract child code"
echo "child code: ${#CHILD_CODE} base64 chars"

say "factory address (genaddr --save)"
F=$(tvm-cli -j genaddr --abi 04_Factory.abi.json --setkey "$KEYS" --save 04_Factory.tvc \
      | python3 -c 'import json,sys; print(json.load(sys.stdin).get("raw_address",""))')
FHEX=${F#0:}
is_hex64 "$FHEX" || die "genaddr did not return an address"
FA="$FHEX::$FHEX"
echo "Factory: $FA"

say "fund factory: 3 SHELL as gas (flag 16); 130 SHELL + 10 NACKL (flag 1)"
give "$F" '{"2":3000000000}' 16
give "$F" '{"1":10000000000,"2":130000000000}' 1
sleep 15
acct "$FHEX" "$FHEX"

say "deploy factory"
for try in 1 2 3; do
  [ "$(acct "$FHEX" "$FHEX" | grep -c '"acc_type":1')" = 1 ] && break
  echo "attempt $try"
  tvm-cli -j deploy --abi 04_Factory.abi.json --sign "$KEYS" 04_Factory.tvc "{\"childCode\":\"$CHILD_CODE\"}" \
    | grep -E '"(exit_code|deployed_at|code|message)"'
  sleep 8
done
acct "$FHEX" "$FHEX" | grep -q '"acc_type":1' || die "factory not deployed"

say "create the factory DApp's DappConfig (120 SHELL credit)"
CFG_RAW=$(tvm-cli -j run "$DAPPROOT" getConfigAddr "{\"dapp_id\":\"0x$FHEX\"}" --abi "$ROOT_ABI" \
            | python3 -c 'import json,sys; print(json.load(sys.stdin).get("config",""))')
CFGHEX=${CFG_RAW#0:}
is_hex64 "$CFGHEX" || die "getConfigAddr did not return an address"
CFG="$FHEX::$CFGHEX"
echo "DappConfig: $CFG"
PAYLOAD=$(tvm-cli body deployNewConfigCustom '{"authorityAddress":null}' --abi "$ROOT_ABI" \
            | grep -oE 'te6[A-Za-z0-9+/=]+' | head -1)
tvm-cli -j call "$FA" sendTransaction \
  "{\"dest\":\"$DAPPROOT_RAW\",\"value\":10000000,\"bounce\":false,\"cc\":{\"2\":120000000000},\"flags\":1,\"payload\":\"$PAYLOAD\"}" \
  --abi 04_Factory.abi.json --sign "$KEYS" | grep -E '"(exit_code|aborted|tx_hash|message)"'
sleep 20
tvm-cli -j run "$CFG" getDetails '{}' --abi "$CFG_ABI"

say "deploy child 0 carrying 5 SHELL + 5 NACKL (factory sends 1 vmshell; child mints 2 vmshell)"
tvm-cli -j call "$FA" deployChild '{"shellAmount":5000000000,"nacklAmount":5000000000}' \
  --abi 04_Factory.abi.json --sign "$KEYS" | grep -E '"(exit_code|aborted|tx_hash|message)"'
sleep 20

say "locate child 0"
CID=$(tvm-cli -j run "$FA" childAccountId '{"nonce":0}' --abi 04_Factory.abi.json \
        | python3 -c 'import json,sys
d=json.load(sys.stdin); v=d.get("value0") or ""
v=v[2:] if v.startswith("0x") else v
print(v.lower().rjust(64,"0") if v else "")')
is_hex64 "$CID" || die "childAccountId did not return an id"
CA="$FHEX::$CID"
echo "Child canonical address: $CA"
echo "Child account:"; acct "$CID" "$FHEX"

say "child's own record of birth"
for g in shellAtBirth nacklAtBirth nativeAtBirth; do
  printf '%s: ' "$g"
  tvm-cli -j run "$CA" "$g" '{}' --abi 04_Child.abi.json | tr -d '\n '
  echo
done

say "after construction (constructor mint of 2 vmshell expected NOT to land)"
tvm-cli -j run "$CFG" getDetails '{}' --abi "$CFG_ABI"
C0=$(native_of "$CID" "$FHEX"); echo "child native: $C0"

say "POKE: factory asks child to accept + mint 3 vmshell"
tvm-cli -j call "$FA" pokeChild '{"nonce":0}' --abi 04_Factory.abi.json --sign "$KEYS" | grep -E '"(exit_code|aborted|tx_hash|message)"'
sleep 20
C1=$(native_of "$CID" "$FHEX"); echo "child native: $C1   delta: $((C1 - C0))"
for g in pokes nativeAtLastPoke; do
  printf '%s: ' "$g"
  tvm-cli -j run "$CA" "$g" '{}' --abi 04_Child.abi.json | tr -d '\n '
  echo
done
tvm-cli -j run "$CFG" getDetails '{}' --abi "$CFG_ABI"
echo "Factory after:"; acct "$FHEX" "$FHEX"

say "done — log: spikes/$LOG"

#!/usr/bin/env bash
# Spike 3: sponsored gas. Does gosh.mintshellq work in our DApp, what does it take, what does it cost?
#   Phase 1: tryMint with NO DappConfig        -> expect no new gas
#   Phase 2: create our DappConfig via DappRoot (Sponsor sends deployNewConfigCustom + 120 SHELL)
#   Phase 3: tryMint again                     -> expect ~10 vmshell of new gas, credit down by 10
# Run from WSL:
#   cd <repo>/spikes && bash run_spike3.sh
# Log: out/spike3.log
set -u
cd "$(dirname "$0")"
mkdir -p out
LOG=out/spike3.log
exec > >(tee -a "$LOG") 2>&1

KEYS=../spike.keys.json
G=0000000000000000000000000000000000000000000000000000000000000000::1111111111111111111111111111111111111111111111111111111111111111
GABI=~/tools/GiverV3.abi.json
DAPPROOT=0000000000000000000000000000000000000000000000000000000000000000::9999999999999999999999999999999999999999999999999999999999999999
DAPPROOT_RAW=0:9999999999999999999999999999999999999999999999999999999999999999
ROOT_ABI=~/tools/DappRoot.abi.json
CFG_ABI=~/tools/DappConfig.abi.json
GQL=https://shellnet.ackinacki.org/graphql

say()   { echo; echo "=== $(date -u +%H:%M:%S) $* ==="; }

acct() {    # $1 = account hex, $2 = dapp hex -> account JSON
  curl -s -X POST "$GQL" -H 'Content-Type: application/json' \
    -d "{\"query\":\"{ blockchain { account(account_id:\\\"$1\\\", dapp_id:\\\"$2\\\") { info { acc_type balance(format:DEC) balance_other { currency value(format:DEC) } } } } }\"}"
  echo
}

native_of() {  # $1 = account hex, $2 = dapp hex -> native balance (nano) or 0
  acct "$1" "$2" | python3 -c 'import json,sys
i=json.load(sys.stdin)["data"]["blockchain"]["account"]["info"]
print(int(i["balance"]) if i else 0)'
}

give() {       # $1 = raw dest, $2 = ecc json, $3 = flag
  tvm-cli -j callx --abi "$GABI" --addr "$G" -m sendCurrencyWithFlag \
    "{\"dest\":\"$1\",\"value\":1000000000,\"ecc\":$2,\"flag\":$3}" \
    | grep -E '"(exit_code|aborted|tx_hash|message)"'
}

say "system ABIs"
[ -s "$ROOT_ABI" ] || curl -fsSL -o "$ROOT_ABI" https://raw.githubusercontent.com/ackinacki/ackinacki/main/contracts/0.79.3_compiled/dappconfig/DappRoot.abi.json
[ -s "$CFG_ABI" ]  || curl -fsSL -o "$CFG_ABI"  https://raw.githubusercontent.com/ackinacki/ackinacki/main/contracts/0.79.3_compiled/dappconfig/DappConfig.abi.json
ls -la "$ROOT_ABI" "$CFG_ABI"

die() { echo "STOPPING: $*"; exit 1; }
is_hex64() { [[ "$1" =~ ^[0-9a-f]{64}$ ]]; }

say "compile + address"
rm -f 03_Sponsor.tvc 03_Sponsor.abi.json
sold --tvm-version gosh 03_Sponsor.sol || die "compile failed"
[ -s 03_Sponsor.tvc ] || die "no 03_Sponsor.tvc produced"
S=$(tvm-cli -j genaddr --abi 03_Sponsor.abi.json --setkey "$KEYS" --save 03_Sponsor.tvc \
      | python3 -c 'import json,sys; print(json.load(sys.stdin).get("raw_address",""))')
SHEX=${S#0:}
is_hex64 "$SHEX" || die "genaddr did not return an address"
SA="$SHEX::$SHEX"
echo "Sponsor: $SA"

say "fund: 2 SHELL as gas (flag 16) + 150 SHELL (flag 1) to seed the credit"
give "$S" '{"2":2000000000}' 16
give "$S" '{"2":150000000000}' 1
sleep 15
acct "$SHEX" "$SHEX"

say "deploy"
for try in 1 2 3; do
  [ "$(acct "$SHEX" "$SHEX" | grep -c '"acc_type":1')" = 1 ] && break
  echo "attempt $try"
  tvm-cli -j deploy --abi 03_Sponsor.abi.json --sign "$KEYS" 03_Sponsor.tvc '{}' \
    | grep -E '"(exit_code|deployed_at|code|message)"'
  sleep 8
done
acct "$SHEX" "$SHEX"

say "PHASE 1: tryMint with no DappConfig"
N0=$(native_of "$SHEX" "$SHEX"); echo "native before: $N0"
tvm-cli -j call "$SA" tryMint '{}' --abi 03_Sponsor.abi.json --sign "$KEYS" \
  | grep -E '"(exit_code|aborted|tx_hash|message)"'
sleep 15
N1=$(native_of "$SHEX" "$SHEX"); echo "native after:  $N1   delta: $((N1 - N0))"

say "PHASE 2: create our DappConfig"
CFG_RAW=$(tvm-cli -j run "$DAPPROOT" getConfigAddr "{\"dapp_id\":\"0x$SHEX\"}" --abi "$ROOT_ABI" \
            | python3 -c 'import json,sys; print(json.load(sys.stdin).get("config",""))')
CFGHEX=${CFG_RAW#0:}
is_hex64 "$CFGHEX" || die "getConfigAddr did not return an address"
CFG="$SHEX::$CFGHEX"
echo "DappConfig address: $CFG"
echo "before:"; acct "$CFGHEX" "$SHEX"
PAYLOAD=$(tvm-cli body deployNewConfigCustom '{"authorityAddress":null}' --abi "$ROOT_ABI" \
            | grep -oE 'te6[A-Za-z0-9+/=]+' | head -1)
echo "payload: $PAYLOAD"
tvm-cli -j call "$SA" sendTransaction \
  "{\"dest\":\"$DAPPROOT_RAW\",\"value\":10000000,\"bounce\":false,\"cc\":{\"2\":120000000000},\"flags\":1,\"payload\":\"$PAYLOAD\"}" \
  --abi 03_Sponsor.abi.json --sign "$KEYS" | grep -E '"(exit_code|aborted|tx_hash|message)"'
sleep 20
echo "config after:"; acct "$CFGHEX" "$SHEX"
tvm-cli -j run "$CFG" getDetails '{}' --abi "$CFG_ABI"
echo "sponsor after:"; acct "$SHEX" "$SHEX"

say "PHASE 3: tryMint with credit"
N2=$(native_of "$SHEX" "$SHEX"); echo "native before: $N2"
tvm-cli -j call "$SA" tryMint '{}' --abi 03_Sponsor.abi.json --sign "$KEYS" \
  | grep -E '"(exit_code|aborted|tx_hash|message)"'
sleep 20
N3=$(native_of "$SHEX" "$SHEX"); echo "native after:  $N3   delta: $((N3 - N2))"
tvm-cli -j run "$CFG" getDetails '{}' --abi "$CFG_ABI"
tvm-cli -j run "$SA" calls '{}' --abi 03_Sponsor.abi.json | tr -d '\n '; echo

say "done — log: spikes/$LOG"

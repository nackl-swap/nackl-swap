#!/usr/bin/env bash
# Spike 2, test B (re-run): does SHELL come back when sent (bounce=true) to an address with NO account?
# Reuses the BounceProbe already deployed by run_spike2.sh. Uses a random address and verifies it is
# empty on chain before sending. Log: out/spike2b.log
#   cd <repo>/spikes && bash run_spike2b.sh
set -u
cd "$(dirname "$0")"
mkdir -p out
LOG=out/spike2b.log
exec > >(tee -a "$LOG") 2>&1

KEYS=../spike.keys.json
GQL=https://shellnet.ackinacki.org/graphql
B=0:f5340db52c71e9ee7b10f076824d6a827df19bff9a9d1f05d8bdf601dd312585
BA=f5340db52c71e9ee7b10f076824d6a827df19bff9a9d1f05d8bdf601dd312585::f5340db52c71e9ee7b10f076824d6a827df19bff9a9d1f05d8bdf601dd312585

say() { echo; echo "=== $(date -u +%H:%M:%S) $* ==="; }

state() {  # $1 = raw address -> account JSON (dapp id = account id)
  local h=${1#0:}
  curl -s -X POST "$GQL" -H 'Content-Type: application/json' \
    -d "{\"query\":\"{ blockchain { account(account_id:\\\"$h\\\", dapp_id:\\\"$h\\\") { info { acc_type balance(format:DEC) balance_other { currency value(format:DEC) } } } } }\"}"
  echo
}

read_probe() {
  for g in shellBeforeSend shellAfterBounce nativeAfterBounce bounces getShell; do
    printf '%s: ' "$g"
    tvm-cli -j run "$BA" "$g" '{}' --abi 02_BounceProbe.abi.json | tr -d '\n '
    echo
  done
}

say "pick a random address and prove it has no account"
for try in 1 2 3 4 5; do
  EMPTY=0:$(python3 -c 'import secrets; print(secrets.token_hex(32))')
  S=$(state "$EMPTY")
  echo "$EMPTY -> $S"
  echo "$S" | grep -q '"info":null' && break
done
echo "$S" | grep -q '"info":null' || { echo "Could not find an empty address; stopping."; exit 1; }

say "probe before"
read_probe
state "$B"

say "test B: send 1 SHELL (bounce=true) to the empty address"
tvm-cli -j call "$BA" sendBouncing "{\"dest\":\"$EMPTY\",\"shellAmount\":1000000000,\"flag\":1}" \
  --abi 02_BounceProbe.abi.json --sign "$KEYS" | grep -E '"(exit_code|aborted|tx_hash|message)"'
sleep 20

say "probe after"
read_probe
state "$B"
echo "Empty address after:"; state "$EMPTY"

say "done — log: spikes/$LOG"

#!/usr/bin/env bash
# Live user-flow suite against the Sepolia deployment (deployments/11155111.json).
# Actors (HD wallets from .env):
#   MNEMONIC  — deployer / curator / issuer / oracle keeper
#   MNEMONIC1 — LP (vault deposit + async exit)
#   MNEMONIC2 — trader (instant exits, Market-pool buy)
#   MNEMONIC3 — patient holder (queue redemption, operator auto-claim)
#   MNEMONIC4 — pro maker (own-wallet Aqua strategies)
set -euo pipefail
cd "$(dirname "$0")/.."
source .env

RPC="${RPC_URL:-https://ethereum-sepolia-rpc.publicnode.com}"

DEPLOYER=$(cast wallet address --mnemonic "$MNEMONIC")
LP=$(cast wallet address --mnemonic "$MNEMONIC1")
TRADER=$(cast wallet address --mnemonic "$MNEMONIC2")
PATIENT=$(cast wallet address --mnemonic "$MNEMONIC3")
MAKER=$(cast wallet address --mnemonic "$MNEMONIC4")
export DEPLOYER_ADDR=$DEPLOYER
export PATIENT_ADDR=$PATIENT

echo "deployer: $DEPLOYER"
echo "lp:       $LP"
echo "trader:   $TRADER"
echo "patient:  $PATIENT"
echo "maker:    $MAKER"

step() { # <label> <mnemonic> <sender> <sig>
  echo
  echo "==== $1 [$3] ===="
  # retry once after a pause: public RPCs are load-balanced and a lagging replica can
  # simulate against pre-previous-step state
  local out
  for attempt in 1 2; do
    out=$(forge script script/SepoliaFlows.s.sol --rpc-url "$RPC" \
      --mnemonics "$2" --sender "$3" --sig "$4" --broadcast 2>&1) || true
    echo "$out" | sed -n '/== Logs ==/,/^$/p; /Error/,$p'
    if echo "$out" | grep -q "Error"; then
      [ "$attempt" = 2 ] && { echo "step failed after retry"; exit 1; }
      echo "-- retrying in 15s (possible RPC state lag)"
      sleep 15
    else
      break
    fi
  done
}

step "1a drip: LP"      "$MNEMONIC1" "$LP"      "drip()"
step "1b drip: trader"  "$MNEMONIC2" "$TRADER"  "drip()"
step "1c drip: patient" "$MNEMONIC3" "$PATIENT" "drip()"
step "1d drip: maker"   "$MNEMONIC4" "$MAKER"   "drip()"

step "2 LP deposits into tier vaults"          "$MNEMONIC1" "$LP"       "lpDeposit()"
step "3 curator ships Express+Patient pools"   "$MNEMONIC"  "$DEPLOYER" "curatorPools()"
step "4 pro maker ships Market pool + bid"     "$MNEMONIC4" "$MAKER"    "proMakerShip()"
step "5 trader: instant exits + buy"           "$MNEMONIC2" "$TRADER"   "traderSwaps()"
step "6 patient holder queues 500 CRED"        "$MNEMONIC3" "$PATIENT"  "patientRequest()"
step "7 curator recycles inventory + submits"  "$MNEMONIC"  "$DEPLOYER" "curatorRecycleSubmit()"

echo
echo "==== waiting out issuer windows (60s tbill / 90s credit) ===="
sleep 100

step "8 issuer settles both epochs at NAV"     "$MNEMONIC"  "$DEPLOYER" "issuerSettle()"
step "9 operator auto-claim + vault harvest"   "$MNEMONIC"  "$DEPLOYER" "operatorClaims()"
step "10 LP requests async exit"               "$MNEMONIC1" "$LP"       "lpExitRequest()"
step "11 curator fulfills LP epoch"            "$MNEMONIC"  "$DEPLOYER" "curatorFulfill()"
step "12 LP claims USDC"                       "$MNEMONIC1" "$LP"       "lpClaim()"

echo
echo "==== all flows complete ===="

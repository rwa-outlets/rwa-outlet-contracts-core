#!/usr/bin/env bash
# Indexer-data generator: repeatable market rounds against the Sepolia deployment.
# Each round emits: NavUpdated x2, Trade/Swapped bursts (both directions), Deposit from
# two extra LPs, RedeemRequest from two controllers + vault recycles, Submitted/Settled,
# operator Withdraw + self-claim Withdraw, FeesClaimed, PoolDocked/PoolCreated (rebalance),
# and ComplianceNFT mint/revoke churn.
#
# Usage: ROUNDS=3 ./script/run-sepolia-scenarios.sh
# Assumes run-sepolia-flows.sh ran once (pools exist, operators/approvals set).
set -euo pipefail
cd "$(dirname "$0")/.."
source .env

RPC="${RPC_URL:-https://ethereum-sepolia-rpc.publicnode.com}"
ROUNDS="${ROUNDS:-3}"

DEPLOYER=$(cast wallet address --mnemonic "$MNEMONIC")
TRADER=$(cast wallet address --mnemonic "$MNEMONIC2")
PATIENT=$(cast wallet address --mnemonic "$MNEMONIC3")
MAKER=$(cast wallet address --mnemonic "$MNEMONIC4")
export DEPLOYER_ADDR=$DEPLOYER
export PATIENT_ADDR=$PATIENT

step() { # <label> <mnemonic> <sender> <sig>
  echo
  echo "==== $1 [$3] ===="
  local out
  for attempt in 1 2; do
    out=$(forge script script/SepoliaScenarios.s.sol --rpc-url "$RPC" \
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

for round in $(seq 1 "$ROUNDS"); do
  echo
  echo "######## round $round / $ROUNDS ########"
  step "nav keeper tick"           "$MNEMONIC"  "$DEPLOYER" "navDrift()"
  step "trader burst + deposit"    "$MNEMONIC2" "$TRADER"   "traderBurst()"
  step "maker LP deposit"          "$MNEMONIC4" "$MAKER"    "makerDeposit()"
  step "patient queues 20 CRED"    "$MNEMONIC3" "$PATIENT"  "patientQueue()"
  step "trader queues 30 TBILL"    "$MNEMONIC2" "$TRADER"   "traderQueue()"
  step "curator recycle + submit"  "$MNEMONIC"  "$DEPLOYER" "curatorSubmit()"
  echo "==== waiting out issuer windows ===="
  sleep 100
  step "issuer settle + claims"    "$MNEMONIC"  "$DEPLOYER" "settleOps()"
  step "trader self-claim"         "$MNEMONIC2" "$TRADER"   "traderClaim()"
  step "curator rebalances express" "$MNEMONIC" "$DEPLOYER" "rebalanceExpress()"
  step "kyc churn"                 "$MNEMONIC"  "$DEPLOYER" "kycChurn()"
done

echo
echo "==== $ROUNDS scenario rounds complete ===="

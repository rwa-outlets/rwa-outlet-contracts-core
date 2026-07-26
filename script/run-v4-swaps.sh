#!/usr/bin/env bash
# First gated swaps through the two Uniswap v4 RWA/USDC pools (deployments/11155111.v4.json):
# sell + buy on each pool so the RWAGateHook records its first ObservationRecorded events —
# the TWAP history behind the OutletRouter guard and the subgraph's secondary-market series.
# The v4 lane was seeded by SetupV4Pool.s.sol; this script only trades against it.
#
# Actor: MNEMONIC (deployer, .env) — holds the ComplianceNFT (hook compliance gate) and the
# demo token balances minted by Deploy.s.sol / SetupV4Pool.s.sol.
#
# Overrides: RPC_URL, SELL_RWA (18d base units), BUY_USDC (6d base units),
#            EXTRA_CAST_ARGS (e.g. "--unlocked --from 0x..." for anvil fork dry runs).
set -euo pipefail
cd "$(dirname "$0")/.."
# .env optional when EXTRA_CAST_ARGS provides the signer (fork dry runs)
[ -f .env ] && source .env

RPC="${RPC_URL:-https://ethereum-sepolia-rpc.publicnode.com}"
SELL_RWA="${SELL_RWA:-500000000000000000000}" # 500 RWA
BUY_USDC="${BUY_USDC:-500000000}"             # 500 USDC

json() { python3 -c "import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])" "$1" "$2"; }

VENUE=$(json deployments/11155111.v4.json V4Venue)
HOOK=$(json deployments/11155111.json RWAGateHook)
USDC=$(json deployments/11155111.json TestUSDC)
TBILL=$(json deployments/11155111.json rwaTBILL)
CREDIT=$(json deployments/11155111.json rwaCREDIT)
POOL_TBILL=$(json deployments/11155111.v4.json PoolId_rwaTBILL)
POOL_CREDIT=$(json deployments/11155111.v4.json PoolId_rwaCREDIT)

if [ -n "${EXTRA_CAST_ARGS:-}" ]; then
  # shellcheck disable=SC2206
  SIGN=(${EXTRA_CAST_ARGS})
  USER_ADDR=$(python3 -c "import sys; print(sys.argv[sys.argv.index('--from')+1])" "${SIGN[@]}")
else
  SIGN=(--mnemonic "$MNEMONIC")
  USER_ADDR=$(cast wallet address --mnemonic "$MNEMONIC")
fi
echo "swapping as: $USER_ADDR   venue: $VENUE"

send() { cast send "$@" --rpc-url "$RPC" "${SIGN[@]}" >/dev/null; }

echo "== approvals (venue pulls tokenIn from caller)"
send "$TBILL" "approve(address,uint256)" "$VENUE" "$(cast max-uint)"
send "$CREDIT" "approve(address,uint256)" "$VENUE" "$(cast max-uint)"
send "$USDC" "approve(address,uint256)" "$VENUE" "$(cast max-uint)"

swap() { # <label> <asset> <assetForUsdc> <amountIn>
  echo "== $1"
  send "$VENUE" "swapExactIn(address,bool,uint256,uint256,address,address)" \
    "$2" "$3" "$4" 0 "$USER_ADDR" "$USER_ADDR"
}

swap "rwaTBILL  sell (RWA -> USDC)" "$TBILL" true "$SELL_RWA"
swap "rwaTBILL  buy  (USDC -> RWA)" "$TBILL" false "$BUY_USDC"
swap "rwaCREDIT sell (RWA -> USDC)" "$CREDIT" true "$SELL_RWA"
swap "rwaCREDIT buy  (USDC -> RWA)" "$CREDIT" false "$BUY_USDC"

echo "== hook state"
for pool in "tbill:$POOL_TBILL" "credit:$POOL_CREDIT"; do
  id="${pool#*:}"
  name="${pool%%:*}"
  count=$(cast call "$HOOK" "observationCount(bytes32)(uint256)" "$id" --rpc-url "$RPC")
  rate=$(cast call "$HOOK" "lastRate(bytes32)(uint256)" "$id" --rpc-url "$RPC")
  echo "$name: observations=$count lastRate=$rate (USDC-per-RWA, 1e18)"
done
echo "TWAP guard becomes enforceable once the oldest observation is >= 900s old."

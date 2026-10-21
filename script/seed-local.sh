#!/usr/bin/env bash
# SupaDex official local seed — LOCAL ANVIL (chain 31337) ONLY.
# Usage:
#   script/seed-local.sh all                 # deploy + seed 5 pools + mock feeds + timelock-wire LVR oracle
#   script/seed-local.sh state <STATE> [N]   # fresh | stale [age] | invalid | reverting | deviate [bps]
#                                            # seq-down | seq-up | seq-recent [secs]
# Env: RPC_URL (default http://127.0.0.1:8545), FOUNDRY_PROFILE (default: repo default, via-IR).
# Keys are anvil's PUBLIC deterministic dev keys; the script refuses any chain other than 31337.
set -euo pipefail
cd "$(dirname "$0")/.."
RPC="${RPC_URL:-http://127.0.0.1:8545}"
OUT="deployments/local-seed.json"
cid="$(cast chain-id --rpc-url "$RPC")"
if [ "$cid" != "31337" ]; then echo "refusing: chain id $cid is not local anvil 31337" >&2; exit 1; fi

K0=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
A=(0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 0x70997970C51812dc3A010C7d01b50e0d17dc79C8
   0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC 0x90F79bf6EB2c4f870365E785982E1f101E93b906
   0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65 0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc
   0x976EA74026E726554dB657fA54763abd0C3a0aa9 0x14dC79964da2C08b23698B3D3cc7Ca32193d9955
   0x23618e81E3f5cdF7f54C3d65f7FBc0aBf5B21E8f 0xa0Ee7A142d267C1f36714E4a8F75612F20a79720)

addr() { # contract name from the deploy broadcast (last CREATE of that name)
  jq -r --arg n "$1" '[.transactions[] | select(.transactionType=="CREATE" and .contractName==$n) | .contractAddress] | last' \
    broadcast/DeploySupaDex.s.sol/31337/run-latest.json
}

case "${1:-all}" in
  all)
    PRIVATE_KEY=$K0 DEPLOY_ENV=local EXPECTED_CHAIN_ID=31337 TIMELOCK_DELAY=3600 \
    GOVERNANCE=${A[1]} PROPOSER=${A[2]} EXECUTOR=${A[3]} CANCELLER=${A[4]} GUARDIAN=${A[5]} \
    OPERATOR=${A[6]} DAO=${A[7]} STAKING=${A[8]} INSURANCE=${A[9]} \
      forge script script/DeploySupaDex.s.sol --rpc-url "$RPC" --broadcast --slow -q
    POOL_MANAGER=$(addr SupaPoolManager) POSITION_MANAGER=$(addr SupaPositionManager) \
    LVR_PLUGIN=$(addr LVRShieldPlugin) ANTIJIT_PLUGIN=$(addr AntiJITVestingPlugin) TIMELOCK=$(addr SupaTimelock) \
    SEED_PHASE=seed forge script script/SeedLocal.s.sol --rpc-url "$RPC" --broadcast --slow -q
    delay=$(cast call "$(addr SupaTimelock)" "minDelay()(uint256)" --rpc-url "$RPC")
    cast rpc evm_increaseTime $((delay + 1)) --rpc-url "$RPC" >/dev/null
    cast rpc evm_mine --rpc-url "$RPC" >/dev/null
    SEED_PHASE=execute forge script script/SeedLocal.s.sol --rpc-url "$RPC" --broadcast --slow -q
    SEED_PHASE=state FEED_STATE=fresh forge script script/SeedLocal.s.sol --rpc-url "$RPC" --broadcast --slow -q
    echo "Seed written to $OUT (core addresses: broadcast/DeploySupaDex.s.sol/31337/run-latest.json)"
    ;;
  state)
    SEED_PHASE=state FEED_STATE="${2:?state}" FEED_PARAM="${3:-0}" \
      forge script script/SeedLocal.s.sol --rpc-url "$RPC" --broadcast -q
    ;;
  *) echo "usage: $0 all | state <STATE> [N]" >&2; exit 2;;
esac

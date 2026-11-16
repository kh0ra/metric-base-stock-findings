#!/usr/bin/env bash
# Read-only verification of the Nov-2026 Metric/Base stock-pool findings.
# Usage: RPC=https://base-rpc.publicnode.com ./scripts/verify.sh
set -euo pipefail

RPC="${RPC:-https://base-rpc.publicnode.com}"
EO=0xE844701934D9C6085B292e428F41b911cC0b3872        # CompressedOracleV1
PYTH=0x30a88bf894D1b806125a23ebf23D715496fD7102      # PythOracle
MO_BAD=0x448d67117763b8ed3aa2af2b864faee83e88efb5   # not whitelisted
MO_OK=0x6c38232B0597ef335bCdC86029cDc9e23A17F166    # whitelisted control
KEY=0x8dfdc825dd0453e7c80b1c1d32ae910e35d6efe9000000000000000000000001
FID=0x8dfdc825dd0453e7c80b1c1d32ae910e35d6efe9000000000000000021050100

echo "== [F1] frozen slot-1 feed word + age =="
WORD=$(cast storage "$EO" "$KEY" --rpc-url "$RPC")
echo "word: $WORD"
python3 - "$WORD" <<'PY'
import sys, time
v = int(sys.argv[1], 16)
ts_ms = (v >> 8) & ((1 << 56) - 1)
age = time.time() - ts_ms / 1000
print(f"timestampMs={ts_ms}  age={age/86400:.2f} days")
print("decoded getOracleData:" )
PY
cast call "$EO" 'getOracleData(bytes32)' "$FID" --rpc-url "$RPC"

echo; echo "== [F1] adapter + pool revert (feed age > maxTimeDelta()==10s) =="
cast call 0x820706835E050f05f004AC9B783827835BC0d13e 'maxTimeDelta()(uint256)' --rpc-url "$RPC"
cast call 0x820706835E050f05f004AC9B783827835BC0d13e 'getQuote()(uint128,uint128,uint128)' --rpc-url "$RPC" || true
cast call 0x821251dac85F3de79bfbb2fF38A096e9F3B2c285 'getSellAndBuyPrices()(uint128,uint128)' --rpc-url "$RPC" || true

echo; echo "== [F3] integrator whitelist missing (false) vs control (true) =="
cast call "$PYTH" 'isIntegrator(address)(bool)' "$MO_BAD" --rpc-url "$RPC"
cast call "$PYTH" 'isIntegrator(address)(bool)' "$MO_OK" --rpc-url "$RPC"

echo; echo "== [F3] one affected pool reverts NotWhitelisted via the MO =="
cast call 0x769f2F7E6fb21Fc7403627b699024a828a298bB2 'getQuote()(uint128,uint128,uint128)' --rpc-url "$RPC" || true

echo; echo "== [F2] push-pipeline liveness (compressed + pyth lanes) =="
B=$(cast block-number --rpc-url "$RPC")
T0=0x29e088dffd7bf6815d088137a59f364d6747163baa7ff4bc47f316a1ad1b9586
echo -n "FeedUpdated events in last 6000 blocks: "
cast logs --address "$EO" --from-block $((B-6000)) --to-block "$B" "$T0" --rpc-url "$RPC" 2>/dev/null | grep -c blockNumber || true
cast call "$PYTH" 'price(bytes32,address)(uint256,uint256,uint16,uint256)' \
  0x0000000000000000000000000000000000000000000000000000000000000c77 \
  0x0000000000000000000000000000000000000000 --from 0x0000000000000000000000000000000000000000 --rpc-url "$RPC" || true

echo; echo "== [F4] funded pool133 paused at the gate =="
cast call 0x0049bce28d8f04d51365CFaFE2c87B1aD46873a0 'isTradingPaused(address)(bool)' \
  0x749f424a5A14aaD0d51CBb38Eba57f690d71BA19 --rpc-url "$RPC"

echo; echo "== done. For scripted PoCs: forge test --match-contract ForkBaseStockFrozen -vv =="

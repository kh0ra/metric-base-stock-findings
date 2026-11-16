# Metric × Base — tokenized-stock pool findings (Nov 2026)

Reproducible findings for **Metric** (Base mainnet): every Base tokenized-stock pool was unbuyable at snapshot — via four independently verified mechanisms. Contains the two Immunefi-ready reports, a live-outage ops note, and a fork PoC suite that **passes**.

> **Snapshot:** 2026-11-16 ~14:45Z · Base block ≈58,249,5xx
> All facts below were verified on-chain (reads, `callTracer` traces, storage slots) and with passing fork tests against live state. Push pipelines are timing-sensitive — re-run the checks if the state has moved.

## Findings (summary)

| # | Finding | Severity view | Proof |
|---|---------|---------------|-------|
| **F1** | **Stock feed frozen 52.06 days.** Compressed-oracle feed `creator=0x8dfdc825….efe9, slot=1` (AAPLc/METAc/GOOGLc/NVDAc) `timestampMs` untouched since **2026-09-25T13:18:38.966Z**. Consuming adapters enforce `maxTimeDelta()==10s` ⇒ every quote reverts `FeedStalled`. Pools **idx 23–30** bricked. | **High** (freezing, 100% swap failure, no on-chain recovery) | `test/ForkBaseStockFrozen.t.sol::test_slot1_ts_frozen_since_sept25_blocks_stock_pool` — patching **only** the feed ts restores quoting ($336 AAPLc) |
| **F2** | **Live venue-wide outage.** Compressed pusher last accepted push **14:11:17Z** (block 58,239,550), Pyth stock relayer last relay **13:45:15Z**; 0 `FeedUpdated` since. With 5–10 s staleness windows, **100/134 reachable pools** revert instantly. | Ops note | log scans + storage ts |
| **F3** | **MultiplierOracle `0x448d6711…` missing from `PythOracle` integrator whitelist** ⇒ `NotWhitelisted(0x448d6711…)` on every read of **29 pools** (idx 48–59, 61–62, 66–80). Dead since deploy. **One-tx fix:** `PythOracle.addIntegrator(0x448d6711…)` (ADMIN_ROLE on the admin Safe, verified). | **High/Medium** (freezing, trivial fix) | callTraces + `isIntegrator()` + raw repro commands |
| **F4** | **Funded stock pools seeded and left paused.** Pools idx 133–139 hold real inventory (pool 133: 89.07 AAPLc + 9,578 USDC), `isTradingPaused==true` on gate `0x0049bce2…` (flag = bit 224 of `poolConfig[pool]`, slot `keccak(pool,3)`). Fork test shows the pipeline is otherwise complete. | Ops note (context) | `test/ForkBaseStockFrozen.t.sol::test_funded_pool133_…` (PASS after 3 surgical patches) |

Reports: [`reports/01-frozen-stock-feed.md`](reports/01-frozen-stock-feed.md) · [`reports/02-missing-integrator-whitelist.md`](reports/02-missing-integrator-whitelist.md) · [`reports/combined-findings.md`](reports/combined-findings.md) · [`reports/venue-outage-ops-note-2026-11-16.md`](reports/venue-outage-ops-note-2026-11-16.md)

## Run the PoC suite

```bash
forge test --match-contract ForkBaseStockFrozen -vv
```

Expected:

```
[PASS] test_funded_pool133_revives_when_pyth_feed_ts_refreshed()
[PASS] test_slot1_ts_frozen_since_sept25_blocks_stock_pool()
Suite result: ok. 2 passed; 0 failed
```

Notes:
- The tests fork Base via `https://base-rpc.publicnode.com` (`vm.createSelectFork`), read live state, and revive the broken paths with surgical `vm.store` patches — no mainnet txs.
- The B20 token is EOF bytecode (`0xEF…`); the tests `vm.etch` a tiny mock exposing the exact config getters the issuer registry reads (values mirror the live token), so they also run on forge EVM versions without EOF support.

## Quick live verification (read-only)

```bash
RPC=https://base-rpc.publicnode.com

# F1 — frozen feed + bricked pools
cast storage 0xE844701934D9C6085B292e428F41b911cC0b3872 \
  0x8dfdc825dd0453e7c80b1c1d32ae910e35d6efe9000000000000000000000001 --rpc-url $RPC
cast call 0x820706835E050f05f004AC9B783827835BC0d13e 'getQuote()(uint128,uint128,uint128)' --rpc-url $RPC
cast call 0x821251dac85F3de79bfbb2fF38A096e9F3B2c285 'getSellAndBuyPrices()(uint128,uint128)' --rpc-url $RPC

# F3 — missing whitelist (false vs true control)
cast call 0x30a88bf894D1b806125a23ebf23D715496fD7102 'isIntegrator(address)(bool)' \
  0x448d67117763b8ed3aa2af2b864faee83e88efb5 --rpc-url $RPC   # false
cast call 0x30a88bf894D1b806125a23ebf23D715496fD7102 'isIntegrator(address)(bool)' \
  0x6c38232B0597ef335bCdC86029cDc9e23A17F166 --rpc-url $RPC   # true
```

Or run [`scripts/verify.sh`](scripts/verify.sh) for the full checklist.

## Repo layout

```
reports/   submission-ready write-ups (English, Immunefi format) + unified technical doc
test/      ForkBaseStockFrozen.t.sol — 2 passing fork PoCs
scripts/   verify.sh — read-only reproduction of every claim
```

## Key addresses

| Object | Address |
|---|---|
| CompressedOracleV1 | `0xE844701934D9C6085B292e428F41b911cC0b3872` |
| PythOracle | `0x30a88bf894D1b806125a23ebf23D715496fD7102` |
| Frozen feed (F1) | `0x8dfdc825dd0453e7c80b1c1d32ae910e35d6efe9000000000000000021050100` |
| Unwhitelisted MultiplierOracle (F3) | `0x448d67117763b8ed3aa2af2b864faee83e88efb5` |
| Trading gate (F4) | `0x0049bce28d8f04d51365CFaFE2c87B1aD46873a0` |
| Pool factory | `0x2a53833cc95548cf52c7b159110e22D3a9018f32` |
| Admin Safe (PythOracle ADMIN_ROLE) | `0xa082C768B1C40f5e980b75959D85cF245AFF0FAE` |

## Overlap notes

- F3 may overlap the `Known_issues` “Fix pending: Multiplier oracle/ScheduledMultiplier” item — hardened here with addresses, traces and repro.
- The OMM audit discussed `MAX_TIME_DELTA` on an Ethereum pool; F1 is the live, 52-day frozen Base feed + bricked pools.

## Disclaimer

Verified against live Base state at the snapshot above. All correctness claims are backed by either a passing fork test or raw, copy-pasteable read-only commands. No private keys touched, no mainnet transactions sent.

MIT (see `test/` headers; `lib/forge-std` keeps its own license).

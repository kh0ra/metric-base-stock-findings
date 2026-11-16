# Metric / Base — Tokenized-stock pools are unbuyable: 52-day frozen feed, live venue outage, missing integrator whitelist, operator-paused funded pools

**Chain:** Base (8453) · **Snapshot:** 2026-11-16T14:44Z, block 58,249,418 (head ts 1,794,839,6xx)
**Status:** LIVE. At snapshot time **100 of 134 sampled pools revert `FeedStalled`**, all 41 tokenized-stock pools are unbuyable, and two independent push pipelines have been dead for 33–59 minutes. One sub-issue (slot-1 feed) has been dead for **52.05 days**.

Everything below is reproducible with plain `cast` against public RPCs, plus two fork tests that PASS:
`pool-contracts/test/ForkBaseStockFrozen.t.sol` →
```
[PASS] test_slot1_ts_frozen_since_sept25_blocks_stock_pool() (gas: 315129)
[PASS] test_funded_pool133_revives_when_pyth_feed_ts_refreshed() (gas: 331925)
Suite result: ok. 2 passed; 0 failed
```

---

## TL;DR of the four layers found

| # | What | Where (on-chain) | Proven how | First/last observed |
|---|------|------------------|------------|---------------------|
| F1 | **Stock feed frozen 52 days.** Compressed-oracle feed `creator=0x8dfdc825….efe9, slot=1` (AAPLc/METAc/GOOGLc/NVDAc) has `timestampMs` untouched since 2026-09-25T13:13Z. Consumers enforce a **10 s** (`maxTimeDelta()==10`) staleness bound ⇒ every quote reverts `FeedStalled`. Fork-patching ONLY the slot timestamp restores quotes ($336 AAPLc). | `CompressedOracleV1 0xE8447019…`; adapters `0x8207068…` etc; pools 23–30 | fork test 1 (PASS) + storage reads + callTraces | since **2026-09-25** (52.05 d) |
| F2 | **Live venue-wide outage.** Both push pipelines stopped: compressed pusher last push **14:11:17Z** (block 58,239,550; ts 1,794,838,285), Pyth stock relayer last relay **13:45:15Z** (ts 1,794,836,715). 0 `FeedUpdated` events / 0 pusher txs since. With 5–10 s staleness windows, 100/134 pools instantly `FeedStalled` (even WETH/cbBTC/EURC pools). | oracle `0xE844…`, `0x30a88…` | log scans, storage ts, live `getQuote` calls | outage ≥ 33–59 min at snapshot |
| F3 | **Missing integrator whitelist.** `MultiplierOracle 0x448d6711…` (kind `"multiplier"`, v1.1.0, `UNDERLYING()==0x30a88…`) is **not** in `PythOracle.integrators` (`isIntegrator==false`) ⇒ every read of its pools reverts `NotWhitelisted(0x448d6711…)`. 29 pools (idx 48–80, incl. SNDKc/SPCXc/MSTRc/AMZNc series) dead **since deploy**. Fix = single `PythOracle.addIntegrator(0x448d6711…)` by ADMIN. | `0x448d6711…`, `PythOracle` | callTraces + `isIntegrator()` reads | permanent |
| F4 | **Funded stock pools seeded then paused.** Pools 133–139 hold real inventory (e.g. pool 133: 89.07 AAPLc + 9,578 USDC; pool 136: 144 SPCXc + 29,140 USDC; pool 139: 83.5 AMZNc + 16,816 USDC) but are `isTradingPaused(pool)==true` on trading-gate `0x0049bce2…` (set via `pauseMany`, controller/registrar `0x80f0A7d1…`). Fork test 2 revives the full pipeline with 3 surgical patches (feeds ts + unpause + slot-80 ts pin) → quotes $356.86. | gate `0x0049bce2…`, pools 133–139 | fork test 2 (PASS) + `isTradingPaused` reads + structLogs of the flag bit (bit 224 of `poolConfig[pool]`, slot `keccak(pool,3)`) | current state |

Severity view: **High “freezing”** — no theft/loss of funds, but swaps are impossible venue-wide during outages and have been impossible for 52 days for the oldest stock pools and since deployment for the whitelist families; funded inventory sits idle.

---

## F1 — the 52-day frozen stock feed (independently reproducible)

Facts (all live reads, Base):
- Feed id: `0x8dfdc825dd0453e7c80b1c1d32ae910e35d6efe9000000000000000021050100`
  = `creator 0x8dfdc825dd0453e7c80b1c1d32ae910e35d6efe9 | chainid 0x2105 | slot 1 | pos 0`.
- Storage word (`cast storage 0xE844… <key>`): `0x47d345…4f4f0001a0d8b7cb7600`,
  `timestampMs = 1790342318966` → **2026-09-25T13:18:38.966Z**, age **52.06 days**.
- The same creator's other slots (0, 2, 3, 80) are pushed constantly by the same infrastructure — only slot 1 was abandoned.
- Adapter (pool 23's provider) `0x820706835e050f05f004ac9b783827835bc0d13e`:
  `maxTimeDelta()==10`, `futureTolerance()==2`. Reads exactly one thing: `CompressedOracleV1.getOracleData(feed)`; staleness check then reverts `FeedStalled()` (`0x9a0423af`).
- Decoded pushed data (unchanged in the fork test): price 33,609,290,496 (=$336.09 in 8 dec), spread idx `0x4f` (1.98 bps).
- Consumers: pools idx **23–30** (AAPLc/METAc/GOOGLc/NVDAc ×2), adapters `0x820706/0xc28101/0x310613/0x7570c7/0x537F49/0xC2abea/0x6d47d7/0x1DaDeD`. All revert `PriceProviderFailed(FeedStalled)` at pool level.

Repro (no fork needed):
```bash
RPC=https://base-rpc.publicnode.com
cast call 0xE844701934D9C6085B292e428F41b911cC0b3872 \
  'getOracleData(bytes32)' 0x8dfdc825dd0453e7c80b1c1d32ae910e35d6efe9000000000000000021050100 --rpc-url $RPC
cast call 0x820706835E050f05f004AC9B783827835BC0d13e 'getQuote()(uint128,uint128,uint128)' --rpc-url $RPC   # FeedStalled
cast call 0x821251dac85F3de79bfbb2fF38A096e9F3B2c285 'getSellAndBuyPrices()(uint128,uint128)' --rpc-url $RPC # PriceProviderFailed(0x9a0423af)
```
Fork PoC (PASS): `forge test --match-contract ForkBaseStockFrozen -vv` (test 1) — refreshes only the slot ts via `vm.store`; adapter then returns `(bid 6.1985e21, ask 6.2010e21)` Q64 (≈$336.02/$336.19) and the pool returns prices.

Root cause of the *freeze itself* is off-chain (the pusher stopped writing slot 1 on 2026-09-25); on-chain, the effect is exact and binary: `ts_age > maxTimeDelta` ⇒ `FeedStalled`.

---

## F2 — live venue-wide outage (as of 2026-11-16 14:44Z)

- `CompressedOracleV1` (`0xE844…`): **0** `FeedUpdated` events in the last 6,000 blocks; **0** txs to the oracle in the last ~60 blocks; last accepted push block 58,239,550 (ts 1,794,838,285 = 14:11:17Z).
- `PythOracle` (`0x30a88…`): stock feeds `0xc77/0xc78/0xc7a` last relay 13:45:15Z (ts 1,794,836,715) — the single batch stopped together (AAPL/META/GOOGL + USDC leg `0x7`).
- Consequence scan of all 134 reachable pools: **100 revert `FeedStalled`** (37 B20 stock + 55 others incl. WETH/cbBTC/AERO/EURC/VVV/DRV), 29 `NotWhitelisted` (F3), only a handful OK.
- The adapters' staleness windows are 5–10 s, so any push gap >10 s flips every pool into `FeedStalled` instantly (no stale-price trading window).

```bash
B=$(cast block-number --rpc-url $RPC)
cast logs --address 0xE844701934D9C6085B292e428F41b911cC0b3872 --from-block $((B-6000)) --to-block $B \
  0x29e088dffd7bf6815d088137a59f364d6747163baa7ff4bc47f316a1ad1b9586 --rpc-url $RPC   # 0 events
```

---

## F3 — `MultiplierOracle 0x448d6711…` not whitelisted on PythOracle (dead since deploy)

Trace of pool 49's provider `0x769f2F7E…` → `0x448d6711…getQuote()` → `PythOracle.integratorPrice(0xc77)` reverts:

```
0x769f2F7E6fb21Fc7403627b699024a828a298bB2::getQuote()
  └─ 0x448d67117763b8ed3aa2af2b864faee83e88efb5::price(0x1890fe95…, pool)
      ├─ PythOracle::blacklisted/registeredPool (ok)
      └─ PythOracle::84e8b16f = integratorPrice(0xc77) → revert NotWhitelisted(0x448d6711…)
```
- `cast call 0x30a88… 'isIntegrator(address)(bool)' 0x448d6711…` → `false`
- control: the older MO `0x6c38232B…` → `true` (its pools pass this step).
- Affected: pools idx 48–80 (29 pools; incl. AAPLc/GOOGLc/METAc/NVDAc/SNDKc/SPCXc/MSTRc/AMZNc). Dead for 100% of their life.
- **Fix:** `PythOracle.addIntegrator(0x448d6711…)` (ADMIN_ROLE; single tx), then feeds must be live.

---

## F4 — funded stock pools seeded and left paused (operator gate)

- Funding (live token balances): pools idx 133–139 hold real inventory — 133: 89.07 AAPLc + 9,578 USDC; 134: 35.57 METAc + 3,618 USDC; 135: 118.59 GOOGLc + 2,618 USDC; 136: 144.2 SPCXc + 29,140 USDC; 137: 155.7 NVDAc + 27,277 USDC; 139: 83.5 AMZNc + 16,816 USDC. Zero swaps ever emitted by these pool addresses.
- Trading gate `0x0049bce28d8f04d51365CFaFE2c87B1aD46873a0` (selectors incl. `isTradingPaused(address)`, `pauseMany(address[])`, `providerPool(address)`, `poolConfig(address)`; controller/registrar `0x80f0A7d1…`): `isTradingPaused(0x749f…)=true`, `isTradingPaused(0x3A4d…)=true` (the funded series) while older pools are `false`.
- The gate routes the quote through `0xB565a168…` → compressed feed `…slot 80 pos 0` (AAPLc $357.05) with its own staleness bound; at snapshot that slot is out due to F2.
- Fork test 2 (PASS) shows the pipeline is otherwise complete: after (1) refreshing the two Pyth feed timestamps, (2) clearing the gate paused bit (bit 224 of `keccak(pool,3)` storage word), (3) pinning slot-80's ts — `pool.getSellAndBuyPrices()` returns `(bid 6.5833e21, ask …)` ≈ $356.86.

```bash
cast call 0x0049bce28d8f04d51365CFaFE2c87B1aD46873a0 'isTradingPaused(address)(bool)' 0x749f424a5A14aaD0d51CBb38Eba57f690d71BA19 --rpc-url $RPC  # true
cast storage 0x0049bce28d8f04d51365CFaFE2c87B1aD46873a0 \
  0x71475577dff990d298ffe3eedc1203d72fe356aae3e356ed242f5f78c12449c3 --rpc-url $RPC  # bit224 = paused
```

---

## Impact

- **Swaps frozen.** No buy/sell possible on any Base tokenized-stock pool in any of the four families; `getSellAndBuyPrices` reverts everywhere. Deposits/withdrawals of pools are unaffected (liquidity locked while unusable).
- **Duration:** F1 52.05 days; F3 since deployment (weeks); F2 live and ongoing; F4 operator state (funded capital idle).
- **Blast radius at snapshot: 100/134 pools** affected by F2 alone; 41 stock pools across 4 token generations; 28 pools hold non-trivial balances.
- **No theft/loss** — pools halt instead of trading stale (that part works as documented).

## Recommendations

1. Resume/repair the two pushers (compressed lane + Pyth stock relayer); consider alerting on `FeedUpdated` gaps > `maxTimeDelta` (5–10 s!) and on slot-level staleness per feed.
2. For slot-1: either resume pushes (immediate unfreeze of pools 23–30) or rotate those pools to the live pipeline (feed ids are immutable in the adapters).
3. `PythOracle.addIntegrator(0x448d6711…)` — unfreezes 29 pools (then feeds must be live).
4. Unpause the funded series via the gate when ready (`pauseMany`), and note the new pipeline also depends on both push pipelines being alive.
5. Longer-term: the 5–10 s staleness bounds make every hiccup a venue halt — a heartbeat-aware fallback (e.g., slightly widening bounds or a redundant pusher) would remove the systemic fragility.

## How to run the PoCs

```bash
cd pool-contracts
forge test --match-contract ForkBaseStockFrozen -vv
# forks Base via https://base-rpc.publicnode.com (foundry.toml left untouched; evm_version stays "cancun")
# note: the B20 token is EOF bytecode (0xEF…); forge's fork EVM cannot run it under cancun, so the tests
#       vm.etch a tiny mock for the config getters the issuer registry reads (values mirror the live token).
```

## Evidence quick table

| Item | Value |
|---|---|
| Frozen feed (F1) | `0x8dfdc825…21050100`, ts 1790342318966 (2026-09-25T13:13:38Z) |
| Compressed pusher last push (F2) | block 58,239,550, ts 1,794,838,285 (14:11:17Z) |
| Pyth stock batch last relay (F2) | ts 1,794,836,715 (13:45:15Z), feeds 0xc77/0xc78/0xc7a + 0x7 |
| MO not whitelisted (F3) | `0x448d6711…`, `isIntegrator==false`, reverts `NotWhitelisted(0x448d6711…)` |
| Gate paused (F4) | `0x0049bce2…`, `isTradingPaused(pool133/139)==true`, flag = bit 224 |
| Funded stock pools | idx 133–139 (AAPLc/METAc/GOOGLc/SPCXc/NVDAc/SNDKc/AMZNc) |

## Overlap notes (honest)

- The **“Fix pending: Multiplier oracle/ScheduledMultiplier”** item may partially overlap F3 (an MO-related deployment/config issue); the concrete missing-`integrator` state above is, however, directly evidenced and one-tx fixable.
- F1/F2/F4 are feed/pipeline liveness, not covered by the audit findings as far as the extracted reports show.

# Ops/context note — live venue-wide push outage + funded stock pools paused at trading gate (2026-11-16)

Companion context for the two submissions (`SUBMISSION-1-FrozenStockFeed.md`, `SUBMISSION-2-MissingIntegratorWhitelist.md`).

## A. Live venue-wide outage (ongoing at snapshot)

- Compressed lane (`CompressedOracleV1 0xE8447019…`): **no accepted push** since block 58,239,550 (ts 1,794,838,285 = **14:11:17Z**). 0 `FeedUpdated` events / 0 pusher txs afterwards (re-verified 14:44Z and later).
- Pyth lane (`PythOracle 0x30a88…`): stock batch {AAPL 0xc77, 0xc78, GOOGL 0xc7a, USDC/USD 0x7} last relayed 1,794,836,715 = **13:45:15Z**; not resumed.
- Effect: the provider-family staleness windows are 5–10 s (`maxTimeDelta()` = 5…10, `futureTolerance()` = 2 on adapters), so **100 of 134 reachable pools revert `FeedStalled` within ~10 s of any push gap** — including WETH/cbBTC/EURC pools. This is a pure liveness failure with an abrupt on/off edge (no stale-price window).
- Recheck:
```bash
cast logs --address 0xE844701934D9C6085B292e428F41b911cC0b3872 --from-block <B-6000> --to-block <B> \
  0x29e088dffd7bf6815d088137a59f364d6747163baa7ff4bc47f316a1ad1b9586   # count → 0
```
- Suggestion: alert on per-feed age (not just push success), given 5–10 s windows; keep a redundant pusher.

## B. Funded stock pools seeded and left `paused` on the trading gate

- Pools idx **133–139** hold real inventory (live `balanceOf(pool)` at snapshot):
  - 133 `0x749f…BA19` AAPLc: 89.07 AAPLc + 9,578.34 USDC
  - 134 `0x5Cc2…CC5d` METAc: 35.57 METAc + 3,618.82 USDC
  - 135 `0x1638…1f8` GOOGLc: 118.60 GOOGLc + 2,618.44 USDC
  - 136 `0x00fb…C8a` SPCXc: 144.20 SPCXc + 29,140.56 USDC
  - 137 `0xA78E…D9c` NVDAc: 155.71 NVDAc + 27,277.44 USDC
  - 139 `0x3A4d…003` AMZNc: 83.54 AMZNc + 16,816.89 USDC
  - (138 SNDKc: 265,110 + 1,029,262 units)
- Trading gate `0x0049bce28d8f04d51365CFaFE2c87B1aD46873a0` (selectors `isTradingPaused(address)`, `pauseMany(address[])`, `providerPool(address)`, `poolConfig(address)`; controller/registrar `0x80f0A7d1…`):
  - `isTradingPaused(pool133) == true`, `isTradingPaused(pool139) == true` (funded series), older pools `false`.
  - Pause flag = bit **224** of the packed `poolConfig[pool]` word at storage slot `keccak(pool, 3)` (proven via structLogs of `isTradingPaused`).
- The gate routes the quote via wrapper `0xB565a168…` → compressed feed `creator 0x8dfdc8… slot 80 pos 0` (AAPLc, pushed until the outage hit).
- Fork test 2 (`pool-contracts/test/ForkBaseStockFrozen.t.sol::test_funded_pool133_revives_when_pyth_feed_ts_refreshed`, **PASS**) shows the whole pipeline is otherwise complete: after (1) refresh Pyth feed ts (both legs), (2) clear the gate pause bit, (3) pin the slot-80 ts — `pool133.getSellAndBuyPrices()` returns `(bid, ask)` ≈ $356.86.
- So the funded series is blocked by: operator pause (F4) + whichever feed lane is currently dead (F2 / F1). Unpausing without live feeds re-bricks instantly (5–10 s windows).

## C. One-paragraph state of "all stock pools" at snapshot (for triage)

- idx 23–30 (8 pools): frozen slot-1 feed → `FeedStalled` (52 days) — *Submission 1*.
- idx 48–59, 61–62, 66–80 (29 pools): MO `0x448d67…` not whitelisted → `NotWhitelisted` since deploy — *Submission 2*.
- idx 104–139 incl. funded 133–139: Pyth-lane reads; dead whenever the stock relayer/pusher is down (today), and 133–139 additionally paused at the gate.
- Everything is currently unbuyable; nothing lost, all withdrawals open.

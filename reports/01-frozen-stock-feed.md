# [Metric / Base] Tokenized-stock pools are permanently unbuyable — stock feed timestamp frozen since 2026-09-25 (`FeedStalled`)

**Program:** Metric (Immunefi) · **Chain:** Base (8453)
**In-scope components:** `pool-contracts` (MetricOmmPool + deployed factory), `oracle-contracts` (CompressedOracleV1 read path), provider adapters (OMM/PriceProvider family)
**Severity:** High — *Freezing* (100% of swaps revert; pool quoting bricked for 52+ days; no on-chain recovery path)
**Snapshot:** 2026-11-16 ~14:45Z, block ≈58,249,5xx

---

## Summary

Eight deployed stock pools (idx **23–30**, AAPLc/METAc/GOOGLc/NVDAc ×2 each) are **hard-bricked**: every quote reverts `PriceProviderFailed(FeedStalled)`. Their provider adapters read one single compressed-oracle feed — `creator=0x8dfdc825dd0453e7c80b1c1d32ae910e35d6efe9, slot=1` — whose `timestampMs` **has not advanced since 2026-09-25T13:18:38Z (52.06 days)**. The adapters enforce `maxTimeDelta() == 10` seconds; since the feed is only ever *re-pushed* off-chain, and slot 1 was simply abandoned (all other slots of the same creator are pushed continuously), every read fails the staleness gate.

Proven by a passing fork test: patching **only the feed's timestamp** (pushed price bytes untouched) instantly restores correct quoting (bid/ask ≈ $336.02/$336.19 for AAPLc) and `pool.getSellAndBuyPrices()` succeeds.

## Root cause (on-chain mechanics, all verified)

1. Feed id = `0x8dfdc825dd0453e7c80b1c1d32ae910e35d6efe9` `| 0x2105 (chainid) | slot 0x01 | pos 0x00..03` — 4 positions = AAPLc/METAc/GOOGLc/NVDAc.
2. `cast storage 0xE844701934D9C6085B292e428F41b911cC0b3872 0x8dfdc825dd0453e7c80b1c1d32ae910e35d6efe9000000000000000000000001` → `0x47d345134f4f547c83e74f4f47fe893d4f4f4540ccd74f4f0001a0d8b7cb7600`
   - `timestampMs = 1790342318966` (2026-09-25T13:18:38.966Z), unchanged for 52+ days.
   - `price = 33,609,290,496` (=$336.09), spread idx `0x4f` (1.98 bps) — data itself fine.
3. Adapter of pool 23 `0x820706835E050f05f004AC9B783827835BC0d13e`: `maxTimeDelta() == 10`, `futureTolerance() == 2`; trace shows it reads exactly `CompressedOracleV1.getOracleData(feed)` and then reverts `FeedStalled()` (`0x9a0423af`) when `now - tsMs/1000 > 10`.
4. Same creator's slots 0/2/3/80 are pushed every few seconds; **slot 1 was abandoned** on 2026-09-25 (no `FeedUpdated` for these feed ids in an 8M-block scan).
5. Adapter `feedId` is immutable ⇒ the pools cannot be pointed at another feed in-place; nothing on-chain refreshes a compressed slot (writes come from pushers only), so the pools stay bricked until someone re-pushes.

## Impact

- 100% of swaps on pools idx 23–30 revert; `getSellAndBuyPrices()` reverts; no stale-price trading (halting, not mispricing).
- Duration: **52.06 days** at snapshot (and counting).
- Affected pool addresses (all feed `creator 0x8dfdc8…, slot 1, pos 0..3`):

| idx | pool | token | adapter | feedId (pos) |
|---|---|---|---|---|
| 23 | 0x821251dac85F3de79bfbb2fF38A096e9F3B2c285 | AAPLc | 0x820706835E050f05f004AC9B783827835BC0d13e | …21050100 |
| 24 | 0x4b2Ae56F61664A44c98cFcf8652ae5Cf8Ca1D8D8 | METAc | 0xc28101D70C6C60a83bfDd4D7F42DEA23a1AD8E5A | …21050101 |
| 25 | 0xa7d522022416a8d395240BE388417A300E227c54 | GOOGLc | 0x310613A73df81fDFeEDeD5eC1975a6Fb890a2308 | …21050102 |
| 26 | 0xecAb479Dd3158050d3eE86d6B18DcfA9e11b9D2D | NVDAc | 0x7570c73dc9dCf9CCB73FC86db95fE9CCE8788cdc | …21050103 |
| 27 | 0x9867E17b9DdEaDacb8F3482ba5DAB386b40e4fEb | AAPLc | 0x537F496612988C2b80b78CB102b4A29a9793Ff65 | …21050100 |
| 28 | 0xCA5929Dd66CE22a73c635faf69162bD778aeC22E | METAc | 0xC2abead32b47fF0365FFA7beB39917cf12592c5E | …21050101 |
| 29 | 0xac1c65DD4B64ACD337948C6A3325C8AEE7BaCdD3 | GOOGLc | 0x6d47d791b2Ba01F295B7ce4Bc6a564815F63dF30 | …21050102 |
| 30 | 0xCA69c5A01fE47e7eff18114451a57D624583cD83 | NVDAc | 0x1DaDeD726d6bd31C04a92de09ECe9f878Fccdf4C | …21050103 |

(Factory: `0x2a53833cc95548cf52c7b159110e22D3a9018f32`; `idxToPool` returns the above.)

## PoC (runs on a Base fork, no mainnet interaction)

Test: `pool-contracts/test/ForkBaseStockFrozen.t.sol`
```
forge test --match-contract ForkBaseStockFrozen -vv
[PASS] test_slot1_ts_frozen_since_sept25_blocks_stock_pool() (gas: 315129)
```
Core of the test:
```solidity
vm.createSelectFork("https://base-rpc.publicnode.com");
bytes32 key = 0x8dfdc8…efe9 << 96 | 1;
bytes32 word = vm.load(COMPRESSED_ORACLE, key);
uint256 tsNowMs = block.timestamp * 1000;
vm.store(COMPRESSED_ORACLE, key, bytes32((uint256(word) & ~(X56 << 8)) | (tsNowMs << 8)));
// -> adapters quote again, pool.getSellAndBuyPrices() returns (bid, ask) ~ $336.02 / $336.19
```
Raw one-liners (live, no fork):
```bash
RPC=https://base-rpc.publicnode.com
cast call 0x820706835E050f05f004AC9B783827835BC0d13e 'getQuote()(uint128,uint128,uint128)' --rpc-url $RPC
# → execution reverted: FeedStalled
cast call 0x821251dac85F3de79bfbb2fF38A096e9F3B2c285 'getSellAndBuyPrices()(uint128,uint128)' --rpc-url $RPC
# → execution reverted: PriceProviderFailed(0x9a0423af)
cast call 0xE844701934D9C6085B292e428F41b911cC0b3872 'getOracleData(bytes32)' \
  0x8dfdc825dd0453e7c80b1c1d32ae910e35d6efe9000000000000000021050100 --rpc-url $RPC
# → (price 3.3609e10, spread 198, spread1 198, timestampMs 1790342318966)
```

## Recommended fix

1. **Immediate:** resume pushing the slot-1 word (same layout: prices/ts/spread — ts in ms, monotonic, ≤ now+drift). Quotes resume within one push; nothing else needed.
2. If slot 1 is intentionally retired: deploy new adapters bound to a live feed and rotate pool providers (adapter `feedId` is immutable), or recreate the pools.
3. Longer term: monitor per-feed age vs consumer `maxTimeDelta` (10 s here) and alert on any `FeedUpdated` gap.

## Honest overlap notes

- The OMM audit discussed `MAX_TIME_DELTA` for the Ethereum WETH/USDC pool (recommendation: raise it), so the *mechanism* is partly known; the **live, 52-day frozen slot-1 feed and the resulting bricked Base pools** are the new, verified state.
- `Known_issues` "Fix pending" list does not cover this feed/pusher state as far as the extracted reports show.

## Evidence appendix

- Frozen storage word: `0x47d345134f4f547c83e74f4f47fe893d4f4f4540ccd74f4f0001a0d8b7cb7600` (slot key above).
- No `FeedUpdated` for feed ids `…21050100..03` in an 8,000,000-block scan (topic0 `0x29e088dffd7bf6815d088137a59f364d6747163baa7ff4bc47f316a1ad1b9586`).
- Creator's slot 0/2/3/80 timestamps within seconds of head at snapshot (pushes alive) — slot 1 the only frozen slot of the namespace.

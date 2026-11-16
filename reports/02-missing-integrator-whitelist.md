# [Metric / Base] 29 tokenized-stock pools permanently revert `NotWhitelisted` — MultiplierOracle missing from PythOracle integrator whitelist

**Program:** Metric (Immunefi) · **Chain:** Base (8453)
**In-scope components:** `oracle-contracts` (PythOracle / OracleBase integrator whitelist), deployed `MultiplierOracle 0x448d6711…`, `pool-contracts` (affected pools)
**Severity:** High — *Freezing* (29 pools bricked since deployment; trivial one-transaction fix)
**Snapshot:** 2026-11-16 ~14:50Z

---

## Summary

`MultiplierOracle 0x448d67117763b8ed3aa2af2b864faee83e88efb5` (`kind()=="multiplier"`, `version()=="1.1.0"`, `UNDERLYING()==0x30a88bf894D1b806125a23ebf23D715496fD7102`) is **not** present in the PythOracle integrator whitelist. Every quote of the 29 pools whose providers route through it therefore reverts:

```
PythOracle.integratorPrice(feed) → require(integrators.contains(msg.sender)) → NotWhitelisted(0x448d6711…)
```
(`NotWhitelisted(address)` selector `0xdf17e316`; `cast call PythOracle 'isIntegrator(address)(bool)' 0x448d67… → false`, while the older MO `0x6c38232B…` → `true`.)

The pools were deployed and funded but have **never been able to quote**; no feed/timing luck helps.

## Root cause

- `OracleBase.integratorPrice()` (oracle-contracts/contracts/oracles/providers/OracleBase.sol):
  `function integratorPrice(bytes32 feedId) … { require(integrators.contains(msg.sender), NotWhitelisted(msg.sender)); … }`
- `MultiplierOracle.price()` reads its underlying exclusively via `UNDERLYING.integratorPrice(feed)`; its `ADMIN`-curated allow-lists and feeds are fine — only the PythOracle-side whitelist entry is missing.
- Call traces (Base, live) show the identical failure for all sampled pools (48, 49, 50, 56, 62, 70, 78):
```
provider.getQuote()
 └─ 0x448d6711…getQuote()/price(...)                    (MultiplierOracle)
    └─ PythOracle.integratorPrice(<feed>)   ← msg.sender == 0x448d6711…
       └─ revert NotWhitelisted(0x448d6711…)
```

## Affected pools (29; all revert `FeedStalled` at pool level via `PriceProviderFailed`)

idx:pool:token (factory `0x2a53833cc95548cf52c7b159110e22D3a9018f32`, `idxToPool`)

```
48 0x8896396ce86CC404FC9cc585DFa423111326ea3b GOOGLc
49 0x831741Bf86E9921a5a6aDB0746e0742dE5DE1afF AAPLc
50 0x7bDC1c8475744824d539D4EEe4F80c5E749fB6c9 METAc
51 0xf9c5E4E5999D1f3827bbC965220b48D1dCBb6Ef5 NVDAc
52 0xe79dC529eDe20d450512c546Edf68648aFfFe8B9 GOOGLc
53 0x4307c68f271B8Eb6D9108D846aF3DEf435ceD489 AAPLc
54 0x26c1fAF4F0d4d3380a6Ab752dB9588285258d2A7 METAc
55 0x0e9ad4c174923Fa9361F025F6eb931168c45188f NVDAc
56 0xAc4B70D1a2bFd504f1c4980F387f9c9d9650C0B1 SNDKc
57 0xc464C6E17CC6ca2ED6477f83B328f804aeBBb89D SPCXc
58 0x33B553c40623f56E39c7Ec052A41Df1e98FBb153 MSTRc
59 0xf7feAF0338cE51c645eEb557Ce965BC48e266A01 AMZNc
61 0x04043cFA214f051CE01a044EdeF4a25E8da0f7d8 NVDAc
62 0x19077d6c41496A2c78E8C87707e6373e113eC89A AAPLc
66 0xE661B604A7aFf1f43DB42A5823ba6A7A29f2cD18 GOOGLc
67 0xde91623eb5FF8716Db1bE5172fF24C4f9d8271b8 METAc
68 0x60f28916086Ae9e9FB108a94819EC5887BC4886C SNDKc
69 0x9907A76217E87e94f9003D949656c8F1a93fc977 SPCXc
70 0x2C25df5117E7F2eAF87171521b705707689Be70e MSTRc
71 0x310E57882c4C289fA7c1CF4b59Fa4B40f6Aef5Af AMZNc
72 0x53e0e482d5204e417b809b13616e4eC96f3019E7 NVDAc
73 0xc8550a8D3b3E57f842f05Eb8918c3469a85F9aB0 NVDAc
74 0xEe6CC731EA6176c5EDf866df1427b2DAaeD4F233 AAPLc
75 0xd4C2aac818c0168C94B433C38757D9f301016413 GOOGLc
76 0x8D51A18b70e464d104cE52C45841529686b451f9 METAc
77 0xB9Fbcf44B7213094508abdeB2ea53d734B85083c SNDKc
78 0x82a97C7f09feF1EF086BD21CDDC99F2C95a2A34f SPCXc
79 0xA79709411A00695a45BC2EbbBD6fb5C187B28A76 MSTRc
80 0xAC061d7A4Db6Bb15cD172B3FDF0f381614c18153 AMZNc
```

## Reproduction (live, no fork)

```bash
RPC=https://base-rpc.publicnode.com
# 1) direct proof of the missing whitelist entry
cast call 0x30a88bf894D1b806125a23ebf23D715496fD7102 'isIntegrator(address)(bool)' \
  0x448d67117763b8ed3aa2af2b864faee83e88efb5 --rpc-url $RPC      # false
cast call 0x30a88bf894D1b806125a23ebf23D715496fD7102 'isIntegrator(address)(bool)' \
  0x6c38232B0597ef335bCdC86029cDc9e23A17F166 --rpc-url $RPC      # true  (control)

# 2) any affected pool reverts NotWhitelisted through the MO
cast call 0x769f2F7E6fb21Fc7403627b699024a828a298bB2 'getQuote()(uint128,uint128,uint128)' --rpc-url $RPC
# → execution reverted: NotWhitelisted(0x448d6711…)  [pool 49's provider]

# 3) pool-level effect
cast call 0x831741Bf86E9921a5a6aDB0746e0742dE5DE1afF 'getSellAndBuyPrices()(uint128,uint128)' --rpc-url $RPC
# → PriceProviderFailed(0x9a0423af)  (FeedStalled wrapped)
```

Raw call-trace (callTracer) excerpt for provider `0x769f2F7E…` (pool 49):
```
-> 0x769f2F7E6fb21Fc7403627b699024a828a298bB2::0x171755b1 (getQuote)   err FeedStalled
   -> 0x448d67117763b8ed3aa2af2b864faee83e88efb5::0xe3079c1b (price)    err NotWhitelisted(0x448d6711…)
      -> 0x30a88bf894D1b806125a23ebf23D715496fD7102::0x84e8b16f (integratorPrice) err NotWhitelisted(0x448d6711…)
```

## Recommended fix

Single transaction on PythOracle by its admin (verified `hasRole(ADMIN_ROLE, 0xa082C768B1C40f5e980b75959D85cF245AFF0FAE) == true`):

```solidity
PythOracle(0x30a88bf894D1b806125a23ebf23D715496fD7102).addIntegrator(0x448d67117763b8ed3aa2af2b864faee83e88efb5);
```
(OracleBase: `function addIntegrator(address) external onlyRole(ADMIN_ROLE)`, emits `IntegratorUpdated`.)

After the fix, the only remaining prerequisite is live feeds (see the companion note about the current push-pipeline state).

## Overlap notes (honest)

- The `Known_issues` "Fix pending" list contains a "Multiplier oracle/ScheduledMultiplier" item without details; if that item is exactly this missing whitelist, this submission hardens it with addresses, traces and severity. Every other check across the MO pipeline (allow-listed adapter `0x1D4995C8…`, feeds, `priceGuard`) is configured correctly — the sole defect is the PythOracle whitelist row.
- Not exploitable for theft; purely *freezing* of quoting/swaps for 29 pools.

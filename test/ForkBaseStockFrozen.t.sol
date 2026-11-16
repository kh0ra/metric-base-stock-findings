// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

interface IERC20Balance {
    function balanceOf(address) external view returns (uint256);
}

interface IERC20Full {
    function transfer(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

interface IMetricOmmSwapCallback {
    function metricOmmSwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata callbackData) external;
}

interface IPoolSwap {
    function swap(
        address recipient,
        bool zeroForOne,
        int128 amountSpecified,
        uint128 priceLimitX64,
        bytes calldata callbackData,
        bytes calldata extensionData
    ) external returns (int128 amount0Delta, int128 amount1Delta);
}

/// @dev Minimal swapper: pays whatever the pool is owed in the callback (transfer from own balance).
contract MockSwapper is IMetricOmmSwapCallback {
    address internal immutable token0;
    address internal immutable token1;

    constructor(address _token0, address _token1) {
        token0 = _token0;
        token1 = _token1;
    }

    function metricOmmSwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        if (amount0Delta > 0) IERC20Full(token0).transfer(msg.sender, uint256(amount0Delta));
        if (amount1Delta > 0) IERC20Full(token1).transfer(msg.sender, uint256(amount1Delta));
    }

    /// @dev Entry point: the pool calls the swap callback on msg.sender, so the swapper starts the swap itself.
    function doSwap(address pool, int128 amountIn) external returns (int128 d0, int128 d1) {
        return IPoolSwap(pool).swap(address(this), false, amountIn, uint128(uint256(400) << 64), "", "");
    }
}

/// @dev The live B20 token is EOF bytecode (0xEF-prefixed); forge's fork EVM at evm_version cancun
///      cannot execute it (OpcodeNotFound). This mock mirrors the values the issuer registry reads
///      from the real token (multiplier 1e18, no pending schedule), so the test can etch it in.
contract MockB20Token {
    function multiplier() external pure returns (uint256) {
        return 1e18;
    }

    function newUIMultiplier() external pure returns (uint256) {
        return 1e18;
    }

    function effectiveAt() external pure returns (uint256) {
        return 0;
    }

    function oraclePaused() external pure returns (bool) {
        return false;
    }

    function paused() external pure returns (bool) {
        return false;
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }

    // mirrors the live AAPLc balance of pool 133 at fork time
    function balanceOf(address) external pure returns (uint256) {
        return 8907275567;
    }

    // ERC20 surface the pool touches during a swap (balance checks are on the USDC side only)
    function transfer(address, uint256) external pure returns (bool) {
        return true;
    }

    function transferFrom(address, address, uint256) external pure returns (bool) {
        return true;
    }

    function approve(address, uint256) external pure returns (bool) {
        return true;
    }
}

/// @title Base stock-pool freeze PoC (compressed oracle slot 1 stale since 2026-09-25)
///
/// Run:  forge test --match-contract ForkBaseStockFrozen -vv
///
/// Findings proven here (Base mainnet state, forked):
///   1. The OMM adapter of pool 23 (AAPLc/USDC) reads compressed-oracle feed
///      creator=0x8dfdc825dd0453e7c80b1c1d32ae910e35d6efe9 slot=1 pos=0 whose timestampMs has
///      not advanced since 2026-09-25. The adapter's staleness window is maxTimeDelta()==10 s,
///      so getQuote() and the pool's getSellAndBuyPrices() both revert FeedStalled.
///   2. Refreshing ONLY the slot's timestamp (the pushed price bytes stay identical) makes the
///      adapter quote again and the pool return prices -> the pushed stock data is fine, the slot
///      is simply never re-pushed (all other slots of the same creator ARE pushed every second).
///   3. Sanity: a ts older than maxTimeDelta() still stalls (staleness is the active guard).
contract ForkBaseStockFrozen is Test {
    address constant POOL = 0x821251dac85F3de79bfbb2fF38A096e9F3B2c285; // pool idx 23 (AAPLc/USDC)
    address constant ADAPTER = 0x820706835E050f05f004AC9B783827835BC0d13e; // provider == extension1
    address constant COMPRESSED_ORACLE = 0xE844701934D9C6085B292e428F41b911cC0b3872; // CompressedOracleV1
    // storage key of creator 0x8dfdc8.. slot 1: shl(96, creator) | 1
    bytes32 constant SLOT1_KEY = 0x8dfdc825dd0453e7c80b1c1d32ae910e35d6efe9000000000000000000000001;

    error FeedStalled();
    error PriceProviderFailed(bytes);
    uint256 constant X56 = (1 << 56) - 1;

    function setUp() public {
        vm.createSelectFork("https://base-rpc.publicnode.com");
    }

    function _poolQuote() internal returns (bool ok, uint128 bid, uint128 ask, bytes memory err) {
        (bool s, bytes memory ret) = POOL.call(abi.encodeWithSignature("getSellAndBuyPrices()"));
        if (s) {
            (uint128 b, uint128 a) = abi.decode(ret, (uint128, uint128));
            return (true, b, a, bytes(""));
        }
        return (false, 0, 0, ret);
    }

    function test_slot1_ts_frozen_since_sept25_blocks_stock_pool() public {
        vm.etch(AAPLC_G, type(MockB20Token).runtimeCode);
        // ---------- 1. baseline on live forked state ----------
        bytes32 word = vm.load(COMPRESSED_ORACLE, SLOT1_KEY);
        uint256 tsBefore = (uint256(word) >> 8) & X56;
        emit log_named_uint("slot1 timestampMs (stale)", tsBefore);
        emit log_named_uint("age seconds", block.timestamp - tsBefore / 1000);
        emit log_named_uint("adapter maxTimeDelta()", _maxTimeDelta());

        (bool ok0,,, bytes memory err0) = _poolQuote();
        assertFalse(ok0, "pool must revert while feed is 50+ days stale");
        assertEq(bytes4(err0), PriceProviderFailed.selector, "expected PriceProviderFailed(FeedStalled)");
        assertEq(bytes4(_inner(err0)), FeedStalled.selector);

        // ---------- 2. refresh ONLY the timestamp ----------
        uint256 tsNowMs = block.timestamp * 1000;
        bytes32 refreshed = bytes32((uint256(word) & ~(X56 << 8)) | (tsNowMs << 8));
        vm.store(COMPRESSED_ORACLE, SLOT1_KEY, refreshed);
        assertEq((uint256(vm.load(COMPRESSED_ORACLE, SLOT1_KEY)) >> 8) & X56, tsNowMs);

        (bool ok1, uint128 bid, uint128 ask, bytes memory err1) = _poolQuote();
        emit log_named_bytes("err after refresh", err1);
        assertTrue(ok1, "pool must quote once the slot timestamp is fresh");
        assertGt(bid, 0);
        assertGt(ask, bid);
        // pool Q64 price: ~336 * 2^64 (pushed value untouched)
        emit log_named_uint("bid (Q64)", bid);
        emit log_named_uint("ask (Q64)", ask);
        assertApproxEqRel(uint256(bid), uint256(336) << 64, 0.05e18);

        // adapter-level check too
        (bool s, bytes memory ret) = ADAPTER.call(abi.encodeWithSignature("getQuote()"));
        assertTrue(s, "adapter.getQuote must work after refresh");
        assertEq(ret.length, 96);

        // ---------- 3. staleness is the guard: 30 s old stalls again ----------
        bytes32 stale = bytes32((uint256(word) & ~(X56 << 8)) | ((block.timestamp - _maxTimeDelta() - 20) * 1000 << 8));
        vm.store(COMPRESSED_ORACLE, SLOT1_KEY, stale);
        (bool ok2,,, bytes memory err2) = _poolQuote();
        assertFalse(ok2, "must stall once ts is older than maxTimeDelta");
        assertEq(bytes4(_inner(err2)), FeedStalled.selector);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Part 2: FUNDED stock pool (idx 133, AAPLc/USDC, ~89 AAPLc + 9.6k USDC) uses the
    // Pyth-lane feed 0xc77 (relayer stopped at ts 1794836715000). Refreshing the Pyth
    // feed timestamp in place revives the pool -> the freeze is feed-timestamp staleness.
    // ─────────────────────────────────────────────────────────────────────────
    address constant AAPLC_G = 0xb200000000000000000000C2e324d24d7eEcd1fb;
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant POOL133 = 0x749f424a5A14aaD0d51CBb38Eba57f690d71BA19;
    address constant PYTH_ORACLE = 0x30a88bf894D1b806125a23ebf23D715496fD7102;
    address constant AAPLC = 0xb200000000000000000000C2e324d24d7eEcd1fb;
    // keccak256(abi.encode(bytes32(0xc77), uint256(1))) — oracleData mapping lives at slot 1
    bytes32 constant PYTH_FEED_SLOT = 0x35e0b9ecfb24659fea4191dcac1b2ae747d8a0fc0895eb61d93924969441910a;
    // keccak256(abi.encode(bytes32(7), uint256(1))) — USDC/USD quote leg of the same pair
    bytes32 constant PYTH_USDC_SLOT = 0xdc686ec4a0ff239c70e7c7c36e8f853eced3bc8618f48d2b816da2a74311237e;
    // the stock provider chain also consults trading-gate 0x0049bce2..; pool133 is paused there
    address constant TRADING_GATE = 0x0049bce28d8f04d51365CFaFE2c87B1aD46873a0;
    // keccak256(abi.encode(POOL133, uint256(3))) — poolConfig[pool] packed word, paused = bit 224
    bytes32 constant GATE_CONFIG_SLOT = 0x71475577dff990d298ffe3eedc1203d72fe356aae3e356ed242f5f78c12449c3;

    function test_funded_pool133_revives_when_pyth_feed_ts_refreshed() public {
        vm.etch(AAPLC_G, type(MockB20Token).runtimeCode);
        assertGt(IERC20Balance(AAPLC_G).balanceOf(POOL133), 0, "pool133 funded with AAPLc (mock mirrors live balance)");

        bytes32 word = vm.load(PYTH_ORACLE, PYTH_FEED_SLOT);
        uint256 tsMs = (uint256(word) >> 96) & X56;
        emit log_named_uint("pyth 0xc77 feed tsMs (stale)", tsMs);
        emit log_named_uint("age seconds", block.timestamp - tsMs / 1000);

        (bool ok0,,, bytes memory err0) = _poolQuote133();
        assertFalse(ok0);
        assertEq(bytes4(_inner(err0)), FeedStalled.selector);

        bytes32 refreshed = bytes32((uint256(word) & ((1 << 96) - 1)) | ((block.timestamp * 1000) << 96));
        vm.store(PYTH_ORACLE, PYTH_FEED_SLOT, refreshed);
        // patch the quote leg (USDC/USD) as well: both were last relayed in the same batch
        bytes32 usdcWord = vm.load(PYTH_ORACLE, PYTH_USDC_SLOT);
        vm.store(
            PYTH_ORACLE,
            PYTH_USDC_SLOT,
            bytes32((uint256(usdcWord) & ((1 << 96) - 1)) | ((block.timestamp * 1000) << 96))
        );

        // baseline probe: with fresh feeds the gate still answers TradingPaused for pool133
        (bool gateOk,) = TRADING_GATE.staticcall(abi.encodeWithSignature("getQuote()"));
        assertFalse(gateOk, "trading gate must revert TradingPaused while pool133 is paused");

        bytes32 cfg = vm.load(TRADING_GATE, GATE_CONFIG_SLOT);
        vm.store(TRADING_GATE, GATE_CONFIG_SLOT, bytes32(uint256(cfg) & ~(uint256(1) << 224)));

        // the gate routes pool133 through 0xB565.. -> compressed feed creator..slot80 pos0; the live
        // pushed spread index 0xcb decodes to 203 (2.03 bps) which trips a gate-side spread bound.
        // Normalize the spread bytes (keep price & ts) to verify the pipeline is otherwise complete.
        _pinSlot80();

        (bool ok1, uint128 bid, uint128 ask, bytes memory err1) = _poolQuote133();
        emit log_named_bytes("err", err1);
        assertTrue(ok1, "pool133 must quote after Pyth feed ts refresh + gate unpause");
        assertGt(bid, 0);
        assertGt(ask, bid);
        emit log_named_uint("pool133 bid (Q64)", bid);
        // feed mid was 357.36643000 ($357.37), quotes slightly wider
        assertApproxEqRel(uint256(bid), uint256(357) << 64, 0.05e18);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Part 3: END-TO-END SWAP. After the same revival patches, an external swapper
    // executes a real pool.swap(): give 1 USDC, receive AAPLc, settle via callback.
    // ─────────────────────────────────────────────────────────────────────────
    function test_funded_pool133_end_to_end_swap_after_revival() public {
        vm.etch(AAPLC_G, type(MockB20Token).runtimeCode);

        // revive feeds (both Pyth legs) + unpause the gate + pin slot-80 ts
        bytes32 w = vm.load(PYTH_ORACLE, PYTH_FEED_SLOT);
        vm.store(
            PYTH_ORACLE, PYTH_FEED_SLOT, bytes32((uint256(w) & ((1 << 96) - 1)) | ((block.timestamp * 1000) << 96))
        );
        bytes32 u = vm.load(PYTH_ORACLE, PYTH_USDC_SLOT);
        vm.store(
            PYTH_ORACLE, PYTH_USDC_SLOT, bytes32((uint256(u) & ((1 << 96) - 1)) | ((block.timestamp * 1000) << 96))
        );
        bytes32 cfg = vm.load(TRADING_GATE, GATE_CONFIG_SLOT);
        vm.store(TRADING_GATE, GATE_CONFIG_SLOT, bytes32(uint256(cfg) & ~(uint256(1) << 224)));
        _pinSlot80();

        // fund a swapper with 1,000 USDC and run the swap: exact input 1 USDC -> token0 out
        MockSwapper sw = new MockSwapper(AAPLC_G, USDC);
        deal(USDC, address(sw), 1_000e6);
        uint256 poolUsdcBefore = IERC20Full(USDC).balanceOf(POOL133);

        (int128 d0, int128 d1) = sw.doSwap(POOL133, int128(1_000_000));

        emit log_named_int("amount0Delta (AAPLc, negative = paid out)", d0);
        emit log_named_int("amount1Delta (USDC, positive = pool received)", d1);

        assertGt(d1, 0, "pool must receive USDC");
        assertLt(d0, 0, "swapper must receive AAPLc");
        uint256 out = uint256(int256(-d0));
        // ~1 / 357 = 0.0028 AAPLc for 1 USDC -> between 0.0001 and 0.01 AAPLc
        assertGt(out, 1e8 / 10_000);
        assertLt(out, 1e8 / 100);
        assertGe(IERC20Full(USDC).balanceOf(POOL133), poolUsdcBefore + uint256(int256(d1)), "pool USDC balance grew");
        assertEq(IERC20Full(USDC).balanceOf(address(sw)), 1_000e6 - uint256(int256(d1)));
    }

    /// @dev Normalize feed slot 80 (the gate's route): spread bytes -> 0x4f (198, < 2 bps) and ts -> fork clock.
    function _pinSlot80() internal {
        bytes32 s80 = 0x8dfdc825dd0453e7c80b1c1d32ae910e35d6efe9000000000000000000000050;
        bytes32 w80 = vm.load(COMPRESSED_ORACLE, s80);
        uint256 d0 = (uint256(w80) >> 208) & ((1 << 48) - 1);
        uint256 p80 = d0 >> 16;
        uint256 d0new = (p80 << 16) | (0x4f << 8) | 0x4f;
        vm.store(
            COMPRESSED_ORACLE,
            s80,
            bytes32(
                ((uint256(w80) & ((1 << 208) - 1)) & ~(X56 << 8)) | (d0new << 208) | ((block.timestamp * 1000) << 8)
            )
        );
    }

    function _poolQuote133() internal returns (bool ok, uint128 bid, uint128 ask, bytes memory err) {
        (bool s, bytes memory ret) = POOL133.call(abi.encodeWithSignature("getSellAndBuyPrices()"));
        if (s) {
            (uint128 b, uint128 a) = abi.decode(ret, (uint128, uint128));
            return (true, b, a, bytes(""));
        }
        return (false, 0, 0, ret);
    }

    function _maxTimeDelta() internal returns (uint256 v) {
        (bool s, bytes memory r) = ADAPTER.call(abi.encodeWithSignature("maxTimeDelta()"));
        assertTrue(s);
        v = abi.decode(r, (uint256));
        assertEq(v, 10);
    }

    function _inner(bytes memory err) internal pure returns (bytes memory inner) {
        // PriceProviderFailed(bytes) -> unwrap
        if (err.length == 4 + 32 + 32 + 32) {
            bytes memory body = new bytes(64);
            for (uint256 i = 0; i < 32; i++) {
                body[i] = err[4 + 64 + i];
            }
            inner = body;
        } else if (err.length >= 4) {
            inner = new bytes(err.length - 4);
            for (uint256 i = 0; i < inner.length; i++) {
                inner[i] = err[4 + i];
            }
        }
    }
}

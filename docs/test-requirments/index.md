# HyperZig — Test Requirements

**Scope**: Full test coverage specification for the `api/`, `node/`,
`oracle_fetcher/`, and `shared/` layers.

**Organisation**: Tests are grouped into four tiers.

```
T1  Unit           Pure function / single module, no IPC, no network, no disk.
T2  Integration    Two or more modules wired together; may use real IPC / disk.
T3  System         Full process(es) running against each other end-to-end.
T4  Performance    Throughput, latency, and resource-usage assertions.
```

Each test entry lists:
- **ID** — unique reference used in CI tagging and issue tracking
- **Tier** — T1 / T2 / T3 / T4
- **Module(s)** — source files under test
- **What is verified** — behaviour, not implementation

---

## Table of Contents

1. [Shared Layer](#1-shared-layer)
2. [API Layer](#2-api-layer)
3. [Oracle Fetcher](#3-oracle-fetcher)
4. [Node — Matching Engine](#4-node--matching-engine)
5. [Node — Clearinghouse](#5-node--clearinghouse)
6. [Node — Consensus](#6-node--consensus)
7. [Node — P2P Network](#7-node--p2p-network)
8. [Node — Store](#8-node--store)
9. [Node — Mempool](#9-node--mempool)
10. [Node — IPC Server](#10-node--ipc-server)
11. [Integration — API ↔ Node](#11-integration--api--node)
12. [Integration — Multi-Node Cluster](#12-integration--multi-node-cluster)
13. [System — End-to-End Trading Scenarios](#13-system--end-to-end-trading-scenarios)
14. [Performance](#14-performance)
15. [Fuzz and Property-Based](#15-fuzz-and-property-based)
16. [Chaos and Fault Injection](#16-chaos-and-fault-injection)
17. [Test Infrastructure Requirements](#17-test-infrastructure-requirements)

---

## 1. Shared Layer

### 1.1 Fixed-Point Arithmetic (`shared/fixed_point.zig`)

| ID | Tier | What is verified |
|----|------|-----------------|
| SH-001 | T1 | `priceFromFloat(50000.0)` round-trips back to `50000.0` via `priceToFloat` |
| SH-002 | T1 | `mulPriceQty` uses u128 intermediate; result does not overflow for max plausible price × quantity |
| SH-003 | T1 | `mulPriceQty(MAX_PRICE, MAX_QTY)` does not panic (overflow check) |
| SH-004 | T1 | Multiplication result is correctly scaled: `1 BTC × 50000 USDC = 50000 USDC` |
| SH-005 | T1 | Converting a negative float to Price returns error, not wrapping integer |
| SH-006 | T1 | `priceFromFloat` and `quantityFromFloat` round to nearest, not truncate |

### 1.2 Cryptography (`shared/crypto.zig`)

| ID | Tier | What is verified |
|----|------|-----------------|
| SH-010 | T1 | `keccak256` matches known test vectors (Ethereum test suite vectors) |
| SH-011 | T1 | `ecrecover` returns the correct address for a known (msg, sig) pair |
| SH-012 | T1 | `ecrecover` returns error for an invalid signature (s out of range) |
| SH-013 | T1 | `ecrecover` returns error for a malleated signature (flipped v) |
| SH-014 | T1 | `eip712Hash` matches the Ethereum `eth_signTypedData_v4` reference output |
| SH-015 | T1 | `blsVerifyAggregate` returns true for a valid aggregate over a known validator set |
| SH-016 | T1 | `blsVerifyAggregate` returns false if one signer is replaced with a non-member |
| SH-017 | T1 | BLS aggregate of n = 1 validator equals a regular single-sig verification |

### 1.3 Protocol Serialisation (`shared/protocol.zig`)

| ID | Tier | What is verified |
|----|------|-----------------|
| SH-020 | T1 | Every `NodeEvent` variant serialises and deserialises with zero data loss |
| SH-021 | T1 | Frame length field matches actual payload byte count |
| SH-022 | T1 | Deserialising a truncated frame returns `error.FrameIncomplete`, not a crash |
| SH-023 | T1 | Deserialising an unknown `msg_type` byte returns `error.UnknownMessageType` |
| SH-024 | T1 | `PlaceOrderRequest` round-trip preserves decimal price strings exactly |
| SH-025 | T1 | `msg_id = 0` is reserved for push events; deserialiser rejects it in request position |

---

## 2. API Layer

### 2.1 Auth Middleware (`api/auth.zig`)

| ID | Tier | What is verified |
|----|------|-----------------|
| AU-001 | T1 | Valid EIP-712 signature over a `PlaceOrder` action returns the correct signer address |
| AU-002 | T1 | Signature where `v` is not 27 or 28 returns `error.SignatureInvalid` |
| AU-003 | T1 | Signature with wrong `chain_id` in domain separator returns `error.SignatureInvalid` |
| AU-004 | T1 | Signature over a different payload returns `error.SignatureInvalid` |
| AU-005 | T1 | Nonce within ±5 s of `now_ms` is accepted |
| AU-006 | T1 | Nonce older than 5 s returns `error.NonceTooOld` |
| AU-007 | T1 | Nonce more than 5 s in the future returns `error.NonceTooNew` |
| AU-008 | T1 | Replaying the same nonce within the window returns `error.NonceReused` |
| AU-009 | T1 | After the window expires, the old nonce slot is recycled and no longer blocks |
| AU-010 | T1 | Token bucket starts full; first N requests succeed; request N+1 returns `error.RateLimitExceeded` |
| AU-011 | T1 | Bucket refills at the correct rate over time |
| AU-012 | T1 | Per-IP and per-Address limits are tracked independently |
| AU-013 | T1 | API wallet address resolves to its owner when owner's action is checked |
| AU-014 | T1 | Unknown address (not a registered API wallet) resolves to itself |
| AU-015 | T2 | Under 10,000 concurrent requests, rate limiter maintains correct counts without data races |

### 2.2 REST Server (`api/rest.zig`)

| ID | Tier | What is verified |
|----|------|-----------------|
| RE-001 | T2 | `POST /exchange` with valid order JSON and signature returns HTTP 200 and `order_id` |
| RE-002 | T2 | `POST /exchange` with invalid JSON returns HTTP 400 |
| RE-003 | T2 | `POST /exchange` with invalid signature returns HTTP 401 |
| RE-004 | T2 | `POST /exchange` with stale nonce returns HTTP 401 |
| RE-005 | T2 | `POST /exchange` with rate-limit exceeded returns HTTP 429 with `Retry-After` header |
| RE-006 | T2 | `POST /info` with `type: "l2Book"` is served from `StateCache`; gateway call count is zero |
| RE-007 | T2 | `POST /info` with unknown `type` returns HTTP 400 |
| RE-008 | T2 | `POST /info` with missing required field returns HTTP 400 with field name in error body |
| RE-009 | T2 | Concurrent 1,000 `POST /info` requests all succeed without response corruption |
| RE-010 | T2 | Node timeout propagates as HTTP 503 to the client |
| RE-011 | T2 | `POST /exchange batchOrders` with 10 orders returns 10 per-order statuses |
| RE-012 | T2 | Request body exceeding `max_body_bytes` returns HTTP 413 |
| RE-013 | T2 | Arena allocator is freed after each request; heap usage does not grow over 10,000 sequential requests |
| RE-014 | T2 | `cancelByCloid` correctly maps cloid to order_id before forwarding to gateway |

### 2.3 WebSocket Server (`api/websocket.zig`)

| ID | Tier | What is verified |
|----|------|-----------------|
| WS-001 | T2 | Client subscribes to `l2Book`; receives a full snapshot immediately on subscribe |
| WS-002 | T2 | `l2Book` subsequent updates carry a `seq` number that is strictly monotonically increasing |
| WS-003 | T2 | Client subscribes to `orderUpdates` without auth header; receives `error` channel message |
| WS-004 | T2 | Client subscribes to `orderUpdates` with valid auth; receives only own user's events |
| WS-005 | T2 | Two clients subscribed to the same topic both receive the same event payload |
| WS-006 | T2 | Client subscribes to the same topic twice; receives events only once (dedup) |
| WS-007 | T2 | After `unsubscribe`, client no longer receives events for that topic |
| WS-008 | T2 | Server responds to `ping` with `pong` within 100 ms |
| WS-009 | T2 | Slow client: send buffer fills; oldest messages are dropped; fast client is unaffected |
| WS-010 | T2 | Slow client exceeding the overflow threshold is disconnected gracefully |
| WS-011 | T2 | `action` message over WebSocket follows the same auth path as REST `/exchange` |
| WS-012 | T2 | 10,000 simultaneous connections; each receives distinct per-user events without cross-contamination |
| WS-013 | T2 | Client reconnects after disconnect; re-subscribes; receives fresh snapshot |
| WS-014 | T2 | Server sends `allMids` update at most once per price-change event (no duplicate fan-out) |

### 2.4 Gateway (`api/gateway.zig`)

| ID | Tier | What is verified |
|----|------|-----------------|
| GW-001 | T2 | `sendAction` receives correct `ActionAck` from mock node |
| GW-002 | T2 | `sendAction` times out after `timeout_ms` and returns `error.NodeTimeout` |
| GW-003 | T2 | Two simultaneous `sendAction` calls with different `msg_id`s are matched correctly |
| GW-004 | T2 | `query` returns immediately (no consensus round-trip) from mock node state |
| GW-005 | T2 | Push event from node calls the registered `EventCallback` |
| GW-006 | T2 | When IPC connection drops, `sendAction` returns `error.NodeUnavailable` |
| GW-007 | T2 | Reconnect happens within 6 s (max backoff); subsequent `sendAction` succeeds |
| GW-008 | T2 | Multiple reconnect attempts follow exponential backoff: 100 ms, 500 ms, 1 s, 2 s, 5 s |
| GW-009 | T2 | Pending requests that were in-flight when connection dropped are all resolved with `error.NodeUnavailable` |
| GW-010 | T2 | Frame with `msg_id = 0` is routed to event callback, not to a pending request waiter |

### 2.5 State Cache (`api/state_cache.zig`)

| ID | Tier | What is verified |
|----|------|-----------------|
| SC-001 | T2 | Cache is populated on first node connection via initial snapshot |
| SC-002 | T2 | `l2Book` diff update with `seq = N+1` is applied; `seq = N+3` is ignored (gap detected) |
| SC-003 | T2 | Gap detection triggers a re-snapshot request to the node |
| SC-004 | T2 | `userState` query returns current positions after a fill event is applied |
| SC-005 | T2 | Concurrent read during write update does not produce torn reads |

---

## 3. Oracle Fetcher

### 3.1 Price Sources

| ID | Tier | What is verified |
|----|------|-----------------|
| OF-001 | T1 | Binance `bookTicker` response parses correctly; mid = (bid + ask) / 2 |
| OF-002 | T1 | OKX response with `code != "0"` returns null |
| OF-003 | T1 | Bybit per-symbol responses are all collected before emitting a `RawPriceSet` |
| OF-004 | T1 | Any source: HTTP 5xx response increments `fetch_err_total`, returns null |
| OF-005 | T1 | Any source: malformed JSON returns null without panic |
| OF-006 | T1 | Any source: response with timestamp older than `max_age_ms` drops that price |
| OF-007 | T1 | Symbol not in the configured asset map is silently ignored |
| OF-008 | T2 | All three sources fetched concurrently via `io_uring`; total wall time < single-source RTT × 1.5 |

### 3.2 Aggregator

| ID | Tier | What is verified |
|----|------|-----------------|
| OF-010 | T1 | Three sources with prices 49900, 50000, 50100 → median = 50000 |
| OF-011 | T1 | One stale source excluded; median computed from remaining two |
| OF-012 | T1 | Fewer than `min_sources` respond → `skip(too_few_sources)` |
| OF-013 | T1 | No sources respond → `skip(all_assets_stale)` |
| OF-014 | T1 | Weighted median: source with weight 2 counted twice |
| OF-015 | T1 | Price deviation > `max_deviation_pct` from last submission: asset flagged, still included |
| OF-016 | T1 | Asset absent from all source responses is excluded from result; not set to zero |
| OF-017 | T1 | `reset()` clears accumulated state; second `finalize()` reflects only new ingestions |

### 3.3 Submitter

| ID | Tier | What is verified |
|----|------|-----------------|
| OF-020 | T1 | Submitted action recovers to agent address via `ecrecover` |
| OF-021 | T1 | Nonce equals `unix_ms` at time of submission |
| OF-022 | T1 | Successive submissions have strictly increasing nonces |
| OF-023 | T1 | IPC unavailable: prices buffered; only the most recent set is kept |
| OF-024 | T1 | On reconnect, `flushPending` sends the most recent buffered set and clears the buffer |
| OF-025 | T1 | Older buffered set discarded when a newer set arrives while IPC is down |
| OF-026 | T2 | End-to-end: price fetched → aggregated → signed → received by mock node as valid `OracleSubmission` |

---

## 4. Node — Matching Engine

### 4.1 Order Book Invariants

| ID | Tier | What is verified |
|----|------|-----------------|
| ME-001 | T1 | After every operation, best bid < best ask (no crossed book) |
| ME-002 | T1 | After inserting N orders at distinct prices, `getL2Snapshot(depth=N)` returns all N levels |
| ME-003 | T1 | `OrderMap` O(1) lookup: `getById` returns correct order after 100,000 inserts |
| ME-004 | T1 | `cloid_map` lookup returns the correct `order_id` |
| ME-005 | T1 | Cancelling a non-existent order returns `error.OrderNotFound` |
| ME-006 | T1 | After a full fill, the order is removed from the book and from `OrderMap` |

### 4.2 Matching Logic

| ID | Tier | What is verified |
|----|------|-----------------|
| ME-010 | T1 | Limit buy at price ≥ best ask → crosses and produces a Fill |
| ME-011 | T1 | Limit buy at price < best ask → rests in book, no Fill |
| ME-012 | T1 | Price priority: higher bid fills before lower bid at same time |
| ME-013 | T1 | Time priority: earlier order at same price fills first |
| ME-014 | T1 | Partial fill: maker remaining size decremented; taker continues to next level |
| ME-015 | T1 | Full fill: both maker and taker removed from book |
| ME-016 | T1 | Market order fills all available liquidity up to its size |
| ME-017 | T1 | Market order with insufficient liquidity fills what is available; remainder is dropped |
| ME-018 | T1 | IOC: filled portion is returned; unfilled portion is cancelled immediately |
| ME-019 | T1 | FOK: full size available → fills completely; otherwise → no fill, no resting order |
| ME-020 | T1 | Post-only (ALO): would cross spread → `error.WouldTakeNotPost`; no fill |
| ME-021 | T1 | Post-only: would rest → enters book as maker |
| ME-022 | T1 | Self-trade prevention: taker order from same address as best maker → skips that level |
| ME-023 | T1 | Stop-market trigger: order stored; no fill until `checkTriggers` called with price crossing trigger_px |
| ME-024 | T1 | Stop-limit trigger fires: creates a limit order at the specified limit price |
| ME-025 | T1 | TP/SL pair: TP fires when price rises above tp_px; SL fires when price falls below sl_px |
| ME-026 | T1 | After TP fires, corresponding SL is automatically cancelled |
| ME-027 | T1 | Multiple overlapping triggers at the same price level all fire in placement order |
| ME-028 | T2 | 1,000,000 random valid orders processed; book remains consistent (no crossed book, no phantom orders) |

### 4.3 Risk Pre-Check (Matching ↔ Clearinghouse Hook)

| ID | Tier | What is verified |
|----|------|-----------------|
| ME-030 | T2 | Order that would breach initial margin is rejected before entering the book |
| ME-031 | T2 | Cross order uses aggregate equity across all cross positions |
| ME-032 | T2 | Isolated order only checks `isolated_margin` for that instrument |

---

## 5. Node — Clearinghouse

### 5.1 Account and Sub-Account

| ID | Tier | What is verified |
|----|------|-----------------|
| CH-001 | T1 | `deriveSubAccountAddress(master, index)` is deterministic and unique per index |
| CH-002 | T1 | `deriveSubAccountAddress` for two different masters produces different addresses |
| CH-003 | T1 | `openSubAccount` creates sub-account with empty collateral and no positions |
| CH-004 | T1 | `openSubAccount` with duplicate index returns `error.AlreadyExists` |
| CH-005 | T1 | `openSubAccount` with `index >= MAX_SUB_ACCOUNTS` returns `error.IndexOutOfRange` |
| CH-006 | T1 | `closeSubAccount` with collateral present returns `error.SubAccountNotEmpty` |
| CH-007 | T1 | `closeSubAccount` with open positions returns `error.SubAccountNotEmpty` |
| CH-008 | T1 | `closeSubAccount` on empty sub-account succeeds; `sub_index` map entry removed |
| CH-009 | T1 | `resolveSubAccount(master_addr)` returns sub-account 0 |
| CH-010 | T1 | `resolveSubAccount(sub_addr)` returns the correct sub-account |
| CH-011 | T1 | `resolveSubAccount(unknown_addr)` returns null |
| CH-012 | T2 | Liquidation of sub-account 0 leaves sub-account 1 collateral unchanged |
| CH-013 | T2 | Margin check for sub-account 0 does not see positions from sub-account 1 |

### 5.2 Account Mode

| ID | Tier | What is verified |
|----|------|-----------------|
| CH-020 | T1 | Standard mode: spot USDC balance is invisible to perp margin calculation |
| CH-021 | T1 | Unified mode: spot USDC balance fully collateralises all USDC-quoted perp positions |
| CH-022 | T1 | Unified mode: USDH balance only collateralises USDH-quoted perps |
| CH-023 | T1 | Standard mode: perps on DEX A and DEX B have independent collateral pools |
| CH-024 | T1 | Setting mode to `dex_abstraction` returns `error.ModeDeprecated` |
| CH-025 | T1 | Setting mode to `portfolio_margin` below volume threshold returns `error.InsufficientVolume` |
| CH-026 | T1 | Builder-code address attempts mode change away from Standard returns `error.BuilderCodeRequiresStandard` |
| CH-027 | T1 | Mode change takes effect at next block; in-flight orders are not cancelled |
| CH-028 | T1 | `unified` mode: 50,001st action in a day returns `error.DailyActionLimitExceeded` |
| CH-029 | T1 | `standard` mode: no daily action limit enforced |
| CH-030 | T1 | Daily action counter resets at midnight UTC |

### 5.3 Collateral

| ID | Tier | What is verified |
|----|------|-----------------|
| CH-040 | T1 | `effectiveTotal` for USDC-only pool equals raw USDC balance |
| CH-041 | T1 | `effectiveTotal` for 1 BTC at price 50,000 USDC with 10% haircut equals 45,000 USDC |
| CH-042 | T1 | Mixed pool: USDC + BTC + ETH effective total equals sum of each asset's haircut-adjusted value |
| CH-043 | T1 | BTC price drops 40%: effective total drops by 36% (40% × 0.9) |
| CH-044 | T1 | Depositing HYPE beyond `max_pct` returns `error.MaxConcentrationExceeded` |
| CH-045 | T1 | Depositing ineligible asset returns `error.AssetNotEligible` |
| CH-046 | T1 | `debitEffective`: USDC consumed first before any other asset |
| CH-047 | T1 | `debitEffective`: when USDC exhausted, spills to lowest-haircut asset |
| CH-048 | T1 | `debitEffective` for amount > total effective collateral returns `error.InsufficientCollateral` |
| CH-049 | T1 | `debitEffective` is atomic: on error, pool state is unchanged |
| CH-050 | T1 | `withdraw` with amount > raw balance returns `error.InsufficientBalance` |

### 5.4 Spot Clearing

| ID | Tier | What is verified |
|----|------|-----------------|
| CH-060 | T1 | Buy fill: taker receives base; taker pays quote + taker_fee |
| CH-061 | T1 | Buy fill: maker loses base; maker receives quote − maker_fee |
| CH-062 | T1 | Sell fill: mirror of buy fill |
| CH-063 | T1 | Net fees collected are credited to fee pool |
| CH-064 | T1 | Taker balance insufficient for quote + fee returns `error.InsufficientBalance` |
| CH-065 | T1 | Maker base balance insufficient returns `error.InsufficientBalance` |
| CH-066 | T1 | Settlement is atomic: on error, both taker and maker balances are unchanged |

### 5.5 Perp Clearing

| ID | Tier | What is verified |
|----|------|-----------------|
| CH-070 | T1 | Opening a new long position creates position with correct entry price |
| CH-071 | T1 | Adding to an existing long: entry price is VWAP of old and new |
| CH-072 | T1 | Partial close (opposite fill < position size): PnL for closed portion is realised and credited |
| CH-073 | T1 | Full close: position removed; full realised PnL credited; fee debited |
| CH-074 | T1 | Flip (opposite fill > position size): old position closed; new position opened at fill price |
| CH-075 | T1 | Before settling a fill, outstanding funding is settled for both taker and maker |
| CH-076 | T1 | Funding rate positive (mark > index): longs pay, shorts receive |
| CH-077 | T1 | Funding rate negative (mark < index): shorts pay, longs receive |
| CH-078 | T1 | Funding clamped at ±0.05% |
| CH-079 | T1 | Funding index on position updated after settlement; no double-charge on next settle |
| CH-080 | T1 | Position opened mid-period pays prorated funding only from open time |

### 5.6 Options Clearing

| ID | Tier | What is verified |
|----|------|-----------------|
| CH-090 | T1 | Buying a call: taker.balance decreases by premium + fee; long position created |
| CH-091 | T1 | Selling a call: maker.balance increases by premium − fee; short position created |
| CH-092 | T1 | Call expires ITM: long receives intrinsic = (settlement_px − strike) × size |
| CH-093 | T1 | Call expires OTM: no payout; position removed; no balance change |
| CH-094 | T1 | Put expires ITM: long receives intrinsic = (strike − settlement_px) × size |
| CH-095 | T1 | Short position pays the intrinsic value the long receives |
| CH-096 | T1 | Settlement is atomic: on error, all positions and balances are unchanged |
| CH-097 | T1 | Greeks after `refreshGreeks`: call delta ∈ [0, 1]; put delta ∈ [−1, 0]; gamma ≥ 0 |
| CH-098 | T1 | Deep ITM call: delta → 1; deep OTM call: delta → 0 |
| CH-099 | T1 | `isExpired(now_ms)` returns true iff `now_ms >= spec.expiry_ms` |

### 5.7 Margining

| ID | Tier | What is verified |
|----|------|-----------------|
| CH-110 | T1 | `initialMargin(1 BTC, 100,000 USDC, 10)` = 10,000 USDC |
| CH-111 | T1 | `maintenanceMarginRate(max_lev=50)` = 0.01 (1%) |
| CH-112 | T1 | `maintenanceMarginRate(max_lev=20)` = 0.025 (2.5%) |
| CH-113 | T1 | Cross margin: unrealised PnL immediately included in `total_equity` |
| CH-114 | T1 | Cross margin: negative unrealised PnL reduces `total_equity` below balance |
| CH-115 | T1 | Cross liquidation trigger: `account_value < mm_rate × total_notional` |
| CH-116 | T1 | Isolated liquidation: only `isolated_margin + upnl` vs `mm_rate × notional`; cross positions unaffected |
| CH-117 | T1 | `isolated_only` position: `canRemoveMargin()` returns false |
| CH-118 | T1 | Leverage increase on existing position: no new initial margin check; position remains open |
| CH-119 | T1 | `transferMarginRequired` = max(sum of im_required, 0.1 × total_notional) |
| CH-120 | T1 | Withdrawal leaving equity < `transferMarginRequired` returns `error.TransferWouldBreachMarginFloor` |
| CH-121 | T1 | `checkInitialMargin` rejects order that would push available balance negative |
| CH-122 | T2 | After BTC haircut collateral crashes 40%, `compute()` correctly classifies account as `.liquidatable` |
| CH-123 | T2 | Long spot BTC + short BTC perp (unified mode): margin lower than either alone |

### 5.8 Portfolio Margin

| ID | Tier | What is verified |
|----|------|-----------------|
| CH-130 | T1 | `borrowOraclePrice` returns median of three inputs |
| CH-131 | T1 | `borrowOraclePrice` with two sources agreeing and one outlier returns the median |
| CH-132 | T1 | `maxBorrow(1 BTC, USDC, ltv=0.85)` at BTC price 100k = 85,000 USDC |
| CH-133 | T1 | `stablecoinBorrowRate(utilization=0.5)` = 0.05 APY |
| CH-134 | T1 | `stablecoinBorrowRate(utilization=0.9)` = 0.525 APY |
| CH-135 | T1 | `accruedInterest` for 1 hour at 5% APY on 100,000 USDC is positive and < 10 USDC |
| CH-136 | T1 | `portfolioMaintenanceRequirement` always ≥ 20 USDC (min_borrow_offset) |
| CH-137 | T1 | Carry trade (spot BTC long + BTC perp short): `portfolioMarginRatio < 0.5` |
| CH-138 | T1 | Heavily leveraged perp with near-worthless HYPE collateral: `portfolioMarginRatio > 0.95` |
| CH-139 | T1 | `portfolioMarginRatio > 0.95` → health = `.liquidatable` |
| CH-140 | T1 | `portfolioMarginRatio > 0.90` → health = `.warning` |
| CH-141 | T1 | Global USDC supply cap exceeded: `computePortfolio` falls back to `computeUnified` |
| CH-142 | T1 | `liquidation_threshold(HYPE, ltv=0.5)` = 0.75 |
| CH-143 | T2 | Interest is indexed at each hourly boundary; total interest over 24 hours matches continuous formula within 0.01% |

### 5.9 Liquidation Engine

| ID | Tier | What is verified |
|----|------|-----------------|
| CH-150 | T1 | `scanCandidates` is pure: calling it twice on the same state returns identical results |
| CH-151 | T1 | Account at exact maintenance margin boundary is classified `.warning`, not `.liquidatable` |
| CH-152 | T1 | Account just below maintenance margin is in candidates list |
| CH-153 | T1 | Liquidation surplus (account over-collateralised): surplus credited to insurance fund |
| CH-154 | T1 | Liquidation deficit covered by insurance fund: fund decremented, no ADL |
| CH-155 | T1 | Liquidation deficit exceeds insurance fund: ADL triggered for exact shortfall |
| CH-156 | T1 | After liquidation, account has zero positions and zero collateral |
| CH-157 | T1 | ADL rank: higher (pnl_ratio × leverage) ranked before lower |
| CH-158 | T1 | ADL reduces highest-rank account first; lower-rank account untouched if shortfall covered |
| CH-159 | T1 | ADL across multiple accounts: accounts reduced in rank order until shortfall = 0 |
| CH-160 | T2 | Portfolio mode liquidation: sub-accounts treated independently; sibling not affected |
| CH-161 | T2 | Options ITM position liquidated at intrinsic value; perp liquidated at mark price |

### 5.10 Transfer Engine

| ID | Tier | What is verified |
|----|------|-----------------|
| CH-170 | T1 | Intra-master transfer moves correct amount from source to destination |
| CH-171 | T1 | Intra-master transfer of non-USDC asset (BTC) succeeds |
| CH-172 | T1 | Transfer to non-existent sub-account returns `error.SubAccountNotFound` |
| CH-173 | T1 | Transfer from source with insufficient raw balance returns `error.InsufficientBalance` |
| CH-174 | T1 | Transfer that would breach maintenance margin is rejected; source balance unchanged (atomic rollback) |
| CH-175 | T1 | Transfer of zero amount returns `error.ZeroAmount` |
| CH-176 | T1 | Transfer from index to itself returns `error.SameAccount` |
| CH-177 | T1 | Deposit credits the specified sub-account index |
| CH-178 | T1 | Deposit to non-existent sub-account returns `error.SubAccountNotFound` |
| CH-179 | T1 | Withdrawal rejected if it would breach transfer margin floor |
| CH-180 | T2 | Deposit via bridge proof that has already been consumed returns `error.DuplicateDeposit` |

---

## 6. Node — Consensus

### 6.1 HotStuff State Machine

| ID | Tier | What is verified |
|----|------|-----------------|
| CS-001 | T2 | 4 validators (f=1): block committed in 3 phases (Prepare → Pre-commit → Commit) |
| CS-002 | T2 | All 4 nodes commit the same block hash at height 1 |
| CS-003 | T2 | Committed block hash at height N is identical across all honest nodes |
| CS-004 | T2 | Receiving a `DECIDE` message with valid QC advances height |
| CS-005 | T2 | `locked_qc` is updated on PRE_COMMIT; prevents voting for conflicting block in same height |
| CS-006 | T2 | `high_qc` is updated on each new QC; used in next PREPARE message |

### 6.2 Pacemaker and Leader Rotation

| ID | Tier | What is verified |
|----|------|-----------------|
| CS-010 | T2 | Leader for round r = validators[r % count] |
| CS-011 | T2 | When leader is partitioned, timeout fires within `round_timeout_ms × 1.5` |
| CS-012 | T2 | After timeout, remaining 3/4 nodes elect a new leader and commit a block |
| CS-013 | T2 | Leader recovery after partition: re-joins and participates in future rounds |
| CS-014 | T2 | Consecutive leader timeouts: each new round increments the round counter |

### 6.3 Safety and Liveness

| ID | Tier | What is verified |
|----|------|-----------------|
| CS-020 | T2 | **Safety**: no two honest nodes ever commit different blocks at the same height (100 blocks) |
| CS-021 | T2 | **Liveness**: 4-node cluster commits 100 blocks within 60 s under normal conditions |
| CS-022 | T2 | Byzantine validator sending conflicting PREPARE votes: honest nodes still commit |
| CS-023 | T2 | Byzantine validator sending votes with invalid BLS signatures: votes are discarded |
| CS-024 | T2 | Network partition heals: lagging node catches up by syncing missing blocks |
| CS-025 | T3 | 7-node cluster (f=2): simultaneous isolation of 2 nodes → remaining 5 continue to commit |
| CS-026 | T3 | All nodes restart simultaneously: cluster recovers from WAL and resumes within 10 s |

### 6.4 Block Content

| ID | Tier | What is verified |
|----|------|-----------------|
| CS-030 | T1 | `txs_hash` in block header matches Merkle root of block's transactions |
| CS-031 | T1 | `state_root` in block header matches SMT root after applying all transactions |
| CS-032 | T2 | Empty block (no transactions): state root equals previous block's state root |
| CS-033 | T2 | Block containing oracle action: oracle prices updated before user transactions |

---

## 7. Node — P2P Network

| ID | Tier | What is verified |
|----|------|-----------------|
| P2P-001 | T2 | Transaction gossiped by one node reaches all 10 nodes within 1 s |
| P2P-002 | T2 | Duplicate message: node only processes it once (seen_cache dedup) |
| P2P-003 | T2 | Message with TTL=0 is not forwarded |
| P2P-004 | T2 | Node joining a running network: discovers peers, syncs blocks, reaches current height |
| P2P-005 | T2 | `syncBlocks(from=0, to=100)`: all 100 blocks received in correct order |
| P2P-006 | T2 | `syncBlocks` with a gap (block 50 missing): error returned; partial sync not committed |
| P2P-007 | T2 | Directed consensus message `sendTo(peer)` not forwarded to other peers |
| P2P-008 | T3 | 10-node network under 10,000 tx/s gossip load: all nodes see all tx within 2 s |
| P2P-009 | T3 | Node with slow outbound bandwidth does not block gossip propagation to others |

---

## 8. Node — Store

| ID | Tier | What is verified |
|----|------|-----------------|
| ST-001 | T1 | `commitBlock` then `getBlock(height)` returns the same block |
| ST-002 | T1 | `getBlock` for non-existent height returns null |
| ST-003 | T1 | State root changes after committing a block with transactions |
| ST-004 | T1 | State root unchanged after committing an empty block |
| ST-005 | T1 | Merkle proof for a known account key verifies correctly against latest state root |
| ST-006 | T1 | Merkle proof for a non-existent key has correct non-membership form |
| ST-007 | T2 | Node restart: `latestHeight()` and `latestStateRoot()` match last committed block |
| ST-008 | T2 | Node restart after crash mid-write (WAL partially written): state is the last fully committed block |
| ST-009 | T2 | `getFills(user, since)` returns only fills for that user after the given timestamp |
| ST-010 | T2 | Concurrent reads during a commit do not observe torn state |
| ST-011 | T4 | Writing 1,000,000 blocks: disk usage grows linearly; no unexpected spikes |

---

## 9. Node — Mempool

| ID | Tier | What is verified |
|----|------|-----------------|
| MP-001 | T1 | `add` then `peek(1)` returns the same transaction |
| MP-002 | T1 | `peek(N)` returns transactions in FIFO order |
| MP-003 | T1 | Duplicate `(address, nonce)` returns `error.DuplicateTx` |
| MP-004 | T1 | `add` when `size == max_size` returns `error.MempoolFull` |
| MP-005 | T1 | `removeConfirmed` reduces size by exactly the number of confirmed tx |
| MP-006 | T1 | `peek` does not remove transactions; size unchanged after peek |
| MP-007 | T2 | 10,000 concurrent adds: all succeed (no data race); final size = 10,000 |
| MP-008 | T2 | Proposer calls `peek(max_block_txs)`; after `removeConfirmed`, those tx not re-proposed |

---

## 10. Node — IPC Server

| ID | Tier | What is verified |
|----|------|-----------------|
| IPC-001 | T2 | `action_req` is added to Mempool; after block commit, `action_ack` returned to API client |
| IPC-002 | T2 | `query_req` for `userState` returns immediately without waiting for consensus |
| IPC-003 | T2 | Fill event after match is pushed to all connected API clients |
| IPC-004 | T2 | Two simultaneous API clients receive independent event streams |
| IPC-005 | T2 | API client disconnect is detected; resources freed; no further pushes attempted |
| IPC-006 | T2 | `action_req` with malformed frame returns `error_resp`, does not crash node |
| IPC-007 | T2 | 100 concurrent API connections sending actions: all acks received correctly matched by msg_id |

---

## 11. Integration — API ↔ Node

| ID | Tier | What is verified |
|----|------|-----------------|
| IN-001 | T3 | Place order via REST; order appears in `GET /info openOrders` |
| IN-002 | T3 | Place matching buy and sell; fill event arrives on both users' WS connections |
| IN-003 | T3 | Cancel order via REST; order no longer in `openOrders`; WS sends `orderUpdate` with status `cancelled` |
| IN-004 | T3 | Cancel by cloid; same result as cancel by order_id |
| IN-005 | T3 | WebSocket `l2Book` subscription receives live updates as orders are placed and filled |
| IN-006 | T3 | REST place order while node is restarting: API returns 503; after node reconnects, order succeeds |
| IN-007 | T3 | `userState` query returns up-to-date balance after a fill that changes PnL |
| IN-008 | T3 | Funding settlement event propagates to all subscribed WS clients within 100 ms of block commit |
| IN-009 | T3 | Deposit action via REST credited to correct sub-account; balance visible in `userState` |
| IN-010 | T3 | Withdrawal rejected if margin floor breached; REST returns 400 with reason |
| IN-011 | T3 | Oracle submission from fetcher process changes mark price visible via `/info allMids` |

---

## 12. Integration — Multi-Node Cluster

| ID | Tier | What is verified |
|----|------|-----------------|
| MN-001 | T3 | 4-node cluster: place order on node A; order book on node B reflects it within 2 blocks |
| MN-002 | T3 | Fill occurring on leader node: all nodes reflect the same post-fill account state |
| MN-003 | T3 | API server connected to sentry node: trades placed via API still reach the validator |
| MN-004 | T3 | Leader change mid-trading: no fills are lost or duplicated around the rotation |
| MN-005 | T3 | State roots identical across all nodes after 1,000 committed blocks |
| MN-006 | T3 | New node joins and syncs 1,000 blocks: final state root matches existing nodes |

---

## 13. System — End-to-End Trading Scenarios

These tests exercise complete user journeys through the full stack.

| ID | Tier | Scenario |
|----|------|----------|
| E2E-001 | T3 | **Spot round-trip**: deposit USDC → buy BTC spot → sell BTC spot → withdraw USDC. Final balance = initial − fees (within 0.01% tolerance). |
| E2E-002 | T3 | **Perp long, take profit**: open BTC perp long at 50,000 → price rises to 55,000 → TP order fires → position closed → realised PnL ≈ 5,000 × size − fees. |
| E2E-003 | T3 | **Perp long, stop loss**: open BTC perp long at 50,000 → price falls to 48,000 → SL order fires → position closed → realised PnL ≈ −2,000 × size − fees. |
| E2E-004 | T3 | **Liquidation flow**: open heavily leveraged long → price moves against position → margin drops below maintenance → liquidation executed → account balance = 0; no position remains. |
| E2E-005 | T3 | **Funding settlement**: hold perp long for 3 simulated funding intervals → funding debited three times → cumulative amount matches rate × notional × 3. |
| E2E-006 | T3 | **Carry trade (portfolio margin)**: spot BTC long + perp BTC short → price moves ±20% → portfolio stays solvent throughout; combined PnL ≈ 0 (hedge). |
| E2E-007 | T3 | **Multi-asset collateral**: deposit BTC as collateral → open perp position → BTC price drops 15% → position still open (haircut covers); BTC price drops 50% → margin breached → liquidation. |
| E2E-008 | T3 | **Sub-account isolation**: sub-account 0 is liquidated; sub-account 1 with independent collateral is unaffected. |
| E2E-009 | T3 | **Intra-master transfer**: move 10,000 USDC from sub 0 to sub 1 → sub 0 margin check passes → sub 1 can open new position immediately. |
| E2E-010 | T3 | **Options expiry ITM**: buy call, hold to expiry, ITM at expiry → intrinsic value credited → position removed. |
| E2E-011 | T3 | **Options expiry OTM**: buy call, hold to expiry, OTM → no payout → position removed, premium cost is sunk. |
| E2E-012 | T3 | **Market maker scenario**: bot places 100 resting limit orders on both sides → taker fills against them → maker rebates credited → bot P&L = rebates − spread cost. |
| E2E-013 | T3 | **Oracle price manipulation resistance**: single validator submits outlier price 10× the median → aggregated price remains within 2% of true median → no false liquidation. |
| E2E-014 | T3 | **Account mode transition Standard→Unified**: switch mode → previous isolated perp positions remain open → new position uses combined spot collateral. |
| E2E-015 | T3 | **ADL scenario**: insurance fund exhausted → deeply profitable opposing account is partially reduced → losing account fully closed → state is consistent. |

---

## 14. Performance

All performance tests run on a single machine matching the reference hardware
spec (48-core, 256 GB RAM, NVMe SSD). Results must be reproducible within 10%.

### 14.1 Matching Engine

| ID | Metric | Target | Measurement method |
|----|--------|--------|--------------------|
| PF-001 | Orders/sec (in-memory, no disk) | ≥ 200,000 | `zig build bench-matching` |
| PF-002 | Single-order latency P50 | < 1 µs | Histogram over 1M orders |
| PF-003 | Single-order latency P99 | < 10 µs | Histogram over 1M orders |
| PF-004 | Single-order latency P99.9 | < 50 µs | Histogram over 1M orders |
| PF-005 | Memory per 1M resting orders | < 500 MB | `valgrind massif` |
| PF-006 | Book remains below 1 ms P99 under 50,000 concurrent resting orders per side | < 1 ms | Benchmark with pre-loaded book |

### 14.2 Clearinghouse

| ID | Metric | Target | Measurement method |
|----|--------|--------|--------------------|
| PF-010 | Fill settlement throughput (perp, cross margin) | ≥ 100,000 fills/sec | Batch fill benchmark |
| PF-011 | `MarginEngine.compute` for 100 open positions | < 50 µs | Micro-benchmark |
| PF-012 | `portfolioMarginRatio` for 50 positions + 10 borrows | < 200 µs | Micro-benchmark |
| PF-013 | `scanCandidates` over 100,000 accounts | < 200 ms | Benchmark with populated state |

### 14.3 Consensus

| ID | Metric | Target | Measurement method |
|----|--------|--------|--------------------|
| PF-020 | Block time (4-node cluster, LAN) | < 500 ms P50 | 100-block run |
| PF-021 | Block time P99 | < 1,000 ms | 1,000-block run |
| PF-022 | BLS aggregate signature verification (100 validators) | < 5 ms | Micro-benchmark |
| PF-023 | Block with 10,000 transactions: execution time | < 100 ms | Benchmark |

### 14.4 API Layer

| ID | Metric | Target | Measurement method |
|----|--------|--------|--------------------|
| PF-030 | REST `/info` throughput (cache hit) | ≥ 50,000 req/s | `wrk` with 16 threads |
| PF-031 | REST `/info` P99 latency (cache hit) | < 5 ms | `wrk` histogram |
| PF-032 | WebSocket fan-out to 10,000 subscribers | < 1 ms after event receipt | Instrumented benchmark |
| PF-033 | REST `/exchange` P99 latency (incl. node round-trip) | < 50 ms | End-to-end benchmark |
| PF-034 | Memory: 100,000 WS connections with no subscriptions | < 2 GB | Process RSS measurement |

### 14.5 Oracle Fetcher

| ID | Metric | Target | Measurement method |
|----|--------|--------|--------------------|
| PF-040 | Full fetch cycle (3 sources concurrently) | < 300 ms P99 | Timed fetch loop |
| PF-041 | Aggregation of 50 assets from 3 sources | < 1 ms | Micro-benchmark |

### 14.6 Store

| ID | Metric | Target | Measurement method |
|----|--------|--------|--------------------|
| PF-050 | Block commit (10,000 tx, WAL + SMT update) | < 50 ms | Write benchmark |
| PF-051 | SMT proof generation | < 1 ms | Micro-benchmark |
| PF-052 | Historical fill query for 1,000 fills (indexed) | < 10 ms | Query benchmark |

---

## 15. Fuzz and Property-Based

These tests generate random valid and invalid inputs and assert invariants
rather than specific expected values. Run for at least 30 minutes in CI.

| ID | Target | Invariant |
|----|--------|-----------|
| FZ-001 | `matching::placeOrder` | After every operation: best_bid < best_ask; sum of all resting order sizes equals book total |
| FZ-002 | `matching::placeOrder` | Every fill has taker_qty + remaining_taker = original_taker_qty |
| FZ-003 | `clearinghouse::processFills` | Sum of all account equities is conserved (zero-sum: fees to fee pool) |
| FZ-004 | `clearinghouse::processFills` | No account balance goes below zero after settlement |
| FZ-005 | `margin::compute` | `available_balance = total_equity − initial_margin_used` always holds |
| FZ-006 | `margin::compute` | `health == .liquidatable` iff `margin_ratio < maintenance_rate` |
| FZ-007 | `collateral::debitEffective` | After any successful debit, `effectiveTotal` decreases by exactly `amount` |
| FZ-008 | `consensus` (simnet) | Two honest nodes never commit conflicting blocks at the same height (1,000 rounds) |
| FZ-009 | `eip712::verify` | `ecrecover(hash(action), sign(action, key)) == addressOf(key)` for all valid keys |
| FZ-010 | `protocol::frame` | Any byte sequence deserialises to `error` or a valid message; never panics |
| FZ-011 | `mempool::add` + `removeConfirmed` | Size never exceeds `max_size`; size never goes negative |
| FZ-012 | `store::commitBlock` | After commit + restart, `getBlock(h)` returns the exact same bytes |
| FZ-013 | `fixed_point::mulPriceQty` | Commutative within precision; never wraps when inputs are in valid range |
| FZ-014 | `auth::verifyAction` | Any modified-byte in signature returns `error.SignatureInvalid`; no false positives |
| FZ-015 | `portfolioMarginRatio` | Ratio is always ≥ 0; never NaN or infinity for any valid account state |

---

## 16. Chaos and Fault Injection

These tests inject failures at the infrastructure level to verify correctness
under adverse conditions.

| ID | Tier | Fault injected | Expected behaviour |
|----|------|---------------|--------------------|
| CH-F001 | T3 | Kill leader node mid-round | New leader elected within 3 × `round_timeout_ms`; no blocks lost |
| CH-F002 | T3 | Kill 1 of 4 nodes, keep it down for 10 blocks | Remaining 3 nodes continue; revived node syncs and rejoins |
| CH-F003 | T3 | Network partition: 2 nodes each side | Neither partition commits (lack of 2f+1); both halves resume on merge |
| CH-F004 | T3 | Inject random 100ms latency spikes between all nodes | All blocks eventually committed; no safety violation |
| CH-F005 | T3 | API process crash and restart | Gateway reconnects; in-flight REST requests return 503; new requests succeed after reconnect |
| CH-F006 | T3 | Oracle fetcher stopped for 3 funding intervals | Mark price goes stale; no new liquidations based on stale price (price age check) |
| CH-F007 | T3 | Kill node during block execution (after match, before store commit) | On restart, state is the last fully committed block; unfinalised block re-proposed |
| CH-F008 | T3 | Disk full during WAL write | Error surfaced to consensus; block not committed; disk-full alert triggered |
| CH-F009 | T3 | Byzantine node sends PREPARE for a different block than the honest leader | Honest nodes do not vote; timeout fires; round advances |
| CH-F010 | T3 | IPC socket file deleted while API and Node are connected | Gateway detects disconnect; reconnects to new socket path from config |
| CH-F011 | T3 | Memory pressure (90% heap used) | Node degrades gracefully; does not OOM-kill; resumes after GC equivalent (Arena cleanup) |
| CH-F012 | T3 | Clock skew of 6 s between API and Node | Nonce check correctly rejects actions with nonce outside the ±5 s window |

---

## 17. Test Infrastructure Requirements

### 17.1 Test Utilities Required

```zig
// src/testing/
├── mock_node.zig         // MockNode: IPC server stub for API tests
├── mock_gateway.zig      // MockGateway: captures outbound frames for node tests
├── mock_oracle.zig       // Controllable price source for deterministic scenarios
├── mock_http.zig         // Stub HTTP responses for oracle fetcher source tests
├── cluster.zig           // TestCluster: N in-process nodes connected by virtual network
├── net_sim.zig           // NetworkSimulator: latency injection, partition, packet loss
├── state_builder.zig     // Builder-pattern helpers for constructing GlobalState fixtures
├── assert_ext.zig        // Custom assertions: expectApproxPrice, expectHealthy, etc.
└── harness.zig           // Common test lifecycle (init, tick, deinit, snapshot)
```

### 17.2 Test Cluster Design

`TestCluster` runs N nodes in-process, connected by a `NetworkSimulator`
rather than real TCP. This allows:
- Deterministic message ordering in unit-style tests
- Fault injection without OS-level tooling
- Sub-millisecond test execution for consensus safety tests

```zig
pub const TestCluster = struct {
    pub fn init(n: u8, alloc: std.mem.Allocator) !TestCluster
    pub fn runUntilHeight(self: *TestCluster, height: u64, timeout_ms: u64) !void
    pub fn partitionNode(self: *TestCluster, index: u8) void
    pub fn healPartition(self: *TestCluster, index: u8) void
    pub fn makeEquivocating(self: *TestCluster, index: u8) void
    pub fn injectLatency(self: *TestCluster, from: u8, to: u8, latency_ms: u64) void
    pub fn stateRootAt(self: *TestCluster, node: u8, height: u64) [32]u8
    pub fn allStateRootsEqual(self: *TestCluster, height: u64) bool
};
```

### 17.3 Determinism Requirements

All T1 and T2 tests must be:
- **Deterministic**: same seed → same result
- **Isolated**: no shared global state between tests
- **Hermetic**: no real network, no real disk (use `std.testing.tmpDir`)
- **Fast**: T1 < 10 ms each; T2 < 500 ms each

T3 and T4 tests may use real disk and real network, but must be labelled
`slow` in the build system and excluded from the default `zig build test` target.

### 17.4 CI Configuration

```
# Fast gate (every PR):
zig build test                    # T1 + T2 only, < 2 min

# Full gate (merge to main):
zig build test-all                # T1 + T2 + T3, < 20 min
zig build bench                   # T4, results compared to baseline
zig build fuzz -- --time=30m      # FZ-001 through FZ-015

# Nightly:
zig build chaos                   # CH-F001 through CH-F012, requires cluster setup
zig build fuzz -- --time=8h       # Extended fuzz run
```

### 17.5 Coverage Targets

| Layer | Line coverage target | Branch coverage target |
|-------|---------------------|------------------------|
| `shared/` | 100% | 100% |
| `api/` | 90% | 85% |
| `node/clearinghouse/` | 95% | 90% |
| `node/consensus/` | 90% | 85% |
| `node/matching/` | 95% | 90% |
| `oracle_fetcher/` | 90% | 85% |

Coverage is measured with `zig build test --coverage` and enforced in CI.
Any PR that reduces coverage below these targets must include a justification.

### 17.6 Test Data and Fixtures

- **Canonical key pairs**: three fixed secp256k1 key pairs checked into
  `src/testing/fixtures/keys.zig` for use in auth tests. Never used with real funds.
- **Known EIP-712 vectors**: test vectors derived from `eth_signTypedData_v4`
  reference implementation stored in `src/testing/fixtures/eip712_vectors.zig`.
- **BLS vectors**: test vectors from the IETF BLS spec stored in
  `src/testing/fixtures/bls_vectors.zig`.
- **Market snapshots**: a small but realistic order book and account state
  snapshot in `src/testing/fixtures/market_snapshot.zig`, used for performance
  baseline and integration test setup.
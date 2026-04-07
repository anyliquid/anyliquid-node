# Clearinghouse — Complete Design Reference

**Directory:** `src/node/clearinghouse/`  
**Depends on:** `matching`, `oracle`, `shared/types`, `shared/crypto`

---

## 1. Overview

The Clearinghouse is the **single authority** over all account state, position
state, and collateral in the system. Every fill produced by the Matching Engine
flows through it before any account is mutated. Nothing else writes to
`GlobalState.accounts`.

It unifies three concerns that would otherwise be scattered:

- **Settlement** — how a fill becomes a position or a cash change (spot / perp / options)
- **Margin** — what collateral is required, computed per account mode and position type
- **Liquidation** — when and how an account is resolved, including insurance fund and ADL

```
                     Matching Engine
                           │ []Fill (instrument-agnostic)
                           ▼
          ┌────────────────────────────────────┐
          │            Clearinghouse           │
          │                                    │
          │  InstrumentRouter                  │
          │    ├─ SpotClearingUnit             │
          │    ├─ PerpClearingUnit             │
          │    └─ OptionsClearingUnit          │
          │              │                     │
          │         MarginEngine               │
          │    (dispatches by AccountMode)     │
          │    ├─ computeStandard()            │
          │    ├─ computeUnified()             │
          │    └─ computePortfolio()           │
          │              │                     │
          │       LiquidationEngine            │
          │    ├─ scanCandidates()             │
          │    ├─ execute()                    │
          │    └─ adl()                        │
          │              │                     │
          │       TransferEngine               │
          │    ├─ executeIntraMaster()         │
          │    ├─ executeDeposit()             │
          │    └─ executeWithdrawal()          │
          └──────────────┬─────────────────────┘
                         │ writes
              GlobalState.masters (AccountState)
```

---

## 2. File Structure

```
src/node/clearinghouse/
├── mod.zig            # Clearinghouse: public interface, block orchestration
├── account.zig        # MasterAccount, SubAccount, address derivation
├── account_mode.zig   # AccountMode enum, mode-change action, daily limits
├── collateral.zig     # CollateralRegistry, CollateralPool
├── router.zig         # InstrumentRouter: dispatches fills by instrument kind
├── spot.zig           # SpotClearingUnit
├── perp.zig           # PerpClearingUnit, funding index
├── options.zig        # OptionsClearingUnit, Greeks, expiry settlement
├── margin.zig         # MarginEngine: cross / isolated / portfolio dispatch
├── portfolio.zig      # Portfolio margin ratio, LTV, borrow interest
├── liquidation.zig    # LiquidationEngine, ADL ranking, insurance fund
├── transfer.zig       # TransferEngine: intra-master, deposit, withdrawal
└── types.zig          # All clearinghouse-internal types
```

---

## 3. Block Execution Order

Every committed block is processed in this **exact** sequence. All nodes must
execute in the same order to produce the same state root.

```
1. Collateral price refresh   (oracle prices → effective collateral recalc)
2. Oracle action settlement   (if block contains OracleSubmission)
3. Interest indexing          (portfolio margin: hourly borrow interest)
4. Funding settlement         (perp: if block crosses hourly boundary)
5. Options expiry settlement  (if any options expire within block window)
6. Fill settlement            (all fills from matching, in block order)
7. Intra-master transfers     (SubAccountTransfer actions)
8. Post-fill margin scan      (identify newly liquidatable sub-accounts)
9. Liquidation execution      (sub-accounts queued from previous block)
```

Liquidations identified in step 8 are **not** executed in the same block.
They are enqueued as system transactions for the next block proposer. This
keeps block execution fully deterministic regardless of discovery order.

---

## 4. Top-Level Interface

```zig
pub const Clearinghouse = struct {
    allocator:   std.mem.Allocator,
    router:      InstrumentRouter,
    margin:      MarginEngine,
    liquidation: LiquidationEngine,
    transfer:    TransferEngine,
    oracle:      *Oracle,

    pub fn init(cfg: ClearinghouseConfig, oracle: *Oracle, alloc: std.mem.Allocator) !Clearinghouse
    pub fn deinit(self: *Clearinghouse) void

    /// Step 6: settle all fills from a committed block.
    pub fn processFills(
        self:   *Clearinghouse,
        fills:  []const Fill,
        state:  *GlobalState,
        now_ms: i64,
    ) ![]ClearinghouseEvent

    /// Steps 3–5: periodic settlements (interest, funding, expiry).
    pub fn settlePeriodicPayments(
        self:   *Clearinghouse,
        state:  *GlobalState,
        now_ms: i64,
    ) ![]ClearinghouseEvent

    /// Step 8: scan all sub-accounts, return liquidation candidates.
    pub fn scanLiquidationCandidates(
        self:  *Clearinghouse,
        state: *const GlobalState,
    ) []LiquidationCandidate

    /// Step 9: execute a single queued liquidation.
    pub fn liquidate(
        self:      *Clearinghouse,
        candidate: LiquidationCandidate,
        state:     *GlobalState,
    ) !LiquidationResult

    /// Step 7: execute a collateral transfer action.
    pub fn processTransfer(
        self:   *Clearinghouse,
        action: TransferAction,
        state:  *GlobalState,
    ) !TransferEvent
};
```

---

## 5. Account Model

### 5.1 MasterAccount and SubAccount

A `MasterAccount` owns up to 20 `SubAccount`s. Each sub-account is
**fully isolated**: separate collateral pool, separate positions, separate
margin state. Liquidation never propagates across sub-account boundaries.

```zig
pub const MAX_SUB_ACCOUNTS: u8 = 20;

pub const MasterAccount = struct {
    address:      Address,
    sub_accounts: [MAX_SUB_ACCOUNTS]?SubAccount,
    mode_config:  AccountModeConfig,
    permissions:  MasterPermissions,
    daily_actions: DailyActionCounter,

    pub fn openSubAccount(self: *MasterAccount, index: u8, label: ?[32]u8) !void
    pub fn closeSubAccount(self: *MasterAccount, index: u8) !void
    // error.SubAccountNotEmpty  if positions or collateral remain

    pub fn subAccountByIndex(self: *MasterAccount, index: u8) ?*SubAccount
    pub fn subAccountByAddr(self: *MasterAccount, addr: Address) ?*SubAccount
    pub fn subAccountCount(self: *MasterAccount) u8
};

pub const SubAccount = struct {
    index:       u8,
    address:     Address,          // derived: keccak256(master ++ index)[12..]
    master:      Address,
    label:       ?[32]u8,
    collateral:  CollateralPool,
    positions:   std.AutoHashMap(InstrumentId, Position),
    margin:      MarginSummary,    // cached, recomputed on every price update
    borrows:     std.AutoHashMap(AssetId, BorrowPosition), // portfolio mode only
    created_at:  i64,

    pub fn hasOpenPositions(self: *const SubAccount) bool
    pub fn hasCollateral(self: *const SubAccount) bool
    pub fn isEmpty(self: *const SubAccount) bool
    pub fn unrealizedPnl(self: *const SubAccount, state: *const GlobalState) i64
};

pub const MasterPermissions = struct {
    global_agents: []Address,   // can trade on any sub-account of this master
};

pub const DailyActionCounter = struct {
    count:       u64,
    reset_at_ms: i64,   // next midnight UTC

    pub fn check(self: *DailyActionCounter, limit: ?u64, now_ms: i64) !void
    // error.DailyActionLimitExceeded
};
```

### 5.2 Address Derivation

Sub-account addresses are **deterministic** — the same master + index always
produces the same address, with no on-chain state needed to look them up.

```zig
/// keccak256(master_address ++ [index_byte]) → take last 20 bytes
pub fn deriveSubAccountAddress(master: Address, index: u8) Address {
    var buf: [21]u8 = undefined;
    @memcpy(buf[0..20], &master);
    buf[20] = index;
    const hash = keccak256(&buf);
    var addr: Address = undefined;
    @memcpy(&addr, hash[12..32]);
    return addr;
}
```

Index 0 is the master's primary trading account (created on first deposit,
cannot be closed while the master account exists).

### 5.3 GlobalState Account Lookup

`GlobalState` maintains two maps to make both master→sub and addr→sub
lookups O(1):

```zig
pub const GlobalState = struct {
    masters:   std.AutoHashMap(Address, MasterAccount),
    sub_index: std.AutoHashMap(Address, SubAccountRef), // sub addr → (master, index)
    // ...
};

pub const SubAccountRef = struct { master: Address, index: u8 };

/// Resolve any address — master or sub — to the active SubAccount.
/// Master address → sub-account 0.
pub fn resolveSubAccount(state: *GlobalState, addr: Address) ?*SubAccount {
    if (state.sub_index.get(addr)) |ref| {
        return state.masters.getPtr(ref.master).?.subAccountByIndex(ref.index);
    }
    if (state.masters.getPtr(addr)) |m| return m.subAccountByIndex(0);
    return null;
}
```

---

## 6. Account Mode

The account mode determines **how spot and perp balances interact as
collateral**. It is set per master account and applies to all its sub-accounts.

```zig
pub const AccountMode = enum(u8) {
    standard         = 0,  // fully separated spot/perp; no daily limit; required for builder codes
    unified          = 1,  // unified per quote asset; 50k actions/day
    portfolio_margin = 2,  // single portfolio across all eligible assets; 50k actions/day
    dex_abstraction  = 3,  // deprecated; read-only

    pub fn dailyActionLimit(self: AccountMode) ?u64 {
        return switch (self) {
            .standard => null,
            else      => 50_000,
        };
    }
};

pub const AccountModeConfig = struct {
    mode:       AccountMode,
    changed_at: i64,
};
```

### Mode Behaviour

| Mode | Spot/Perp collateral | Cross scope | Constraints |
|------|---------------------|-------------|-------------|
| **Standard** | Fully separated; each DEX has its own perp wallet | Per DEX | Must be in Standard to receive builder fees |
| **Unified** | Unified per quote asset (USDC pool covers all USDC-quoted perps + spot) | Per quote asset across all DEXes | 50k actions/day |
| **Portfolio** | Single portfolio: USDC, USDH, BTC, HYPE spot + all perps | Global | >$5M volume required; 50k actions/day; caps apply |
| **DEX Abstraction** | Deprecated | — | Cannot be newly set |

### SetAccountMode Action

```zig
pub const SetAccountModeAction = struct {
    type: []const u8,  // "setAccountMode"
    mode: AccountMode,
};
```

Rejected if:
- `mode == .dex_abstraction` (deprecated)
- `mode == .portfolio_margin` and master weighted volume < $5M
- Account has an active builder code and `mode != .standard`

Mode change takes effect at the next block boundary. In-flight orders are not
cancelled, but margin is re-evaluated under the new mode at next price update.

---

## 7. Collateral

### 7.1 CollateralRegistry

A governance-controlled registry of assets eligible as margin collateral.
Each asset carries a haircut rate (the discount applied to its market value
when computing effective collateral) and a concentration cap.

```zig
pub const CollateralRegistry = struct {
    entries: []CollateralEntry,

    pub fn isEligible(self: *CollateralRegistry, asset_id: AssetId) bool
    pub fn haircutRate(self: *CollateralRegistry, asset_id: AssetId) f64
    pub fn effectiveValue(
        self:     *CollateralRegistry,
        asset_id: AssetId,
        amount:   Quantity,
        oracle:   *const Oracle,
    ) Quantity   // USDC after haircut: oracle_price × amount × (1 − haircut)
};

pub const CollateralEntry = struct {
    asset_id:    AssetId,
    symbol:      []const u8,
    haircut_pct: f64,   // 0.0 = no discount (USDC), 0.30 = 30% haircut
    max_pct:     f64,   // max fraction of total collateral this asset may comprise
    enabled:     bool,
};
```

**Default registry:**

| Asset | Haircut | Max % | Rationale |
|-------|---------|-------|-----------|
| USDC | 0% | 100% | Settlement currency; 1:1 |
| BTC | 10% | 50% | Most liquid non-stable |
| ETH | 15% | 40% | |
| SOL | 25% | 30% | Higher volatility |
| HYPE | 30% | 20% | Native token |

Haircut ≈ expected price drop during the liquidation window. A 10% haircut on
BTC means the fund remains solvent even if BTC drops 10% before the seized BTC
can be sold.

### 7.2 CollateralPool

Per-sub-account store of raw asset balances with derived effective values.

```zig
pub const CollateralPool = struct {
    allocator: std.mem.Allocator,
    assets:    std.AutoHashMap(AssetId, Quantity),

    pub fn init(alloc: std.mem.Allocator) CollateralPool
    pub fn deinit(self: *CollateralPool) void

    pub fn deposit(self: *CollateralPool, asset_id: AssetId, amount: Quantity,
                   registry: *CollateralRegistry) !void
    // error.AssetNotEligible
    // error.MaxConcentrationExceeded

    pub fn withdraw(self: *CollateralPool, asset_id: AssetId, amount: Quantity) !void
    // error.InsufficientBalance

    /// Total effective collateral in USDC (all assets discounted by haircut).
    pub fn effectiveTotal(self: *CollateralPool,
                          registry: *CollateralRegistry,
                          oracle:   *const Oracle) Quantity

    pub fn rawBalance(self: *CollateralPool, asset_id: AssetId) Quantity

    /// Debit USDC-equivalent from the pool.
    /// Consumes assets in haircut-ascending order: USDC first, highest-haircut last.
    pub fn debitEffective(self: *CollateralPool, amount: Quantity,
                          registry: *CollateralRegistry,
                          oracle:   *const Oracle) !void
    // error.InsufficientCollateral

    pub fn credit(self: *CollateralPool, asset_id: AssetId, amount: Quantity) void
    pub fn snapshot(self: *CollateralPool, alloc: std.mem.Allocator) ![]AssetBalance
};

pub const AssetBalance = struct {
    asset_id:       AssetId,
    raw_amount:     Quantity,
    effective_usdc: Quantity,   // after haircut
};
```

**Debit order policy** — when fees or losses must be taken, consume assets
in this order (most stable first, to minimise effective-collateral loss):

```
1. USDC      (haircut 0% — cheapest to lose)
2. ETH       (haircut 15%)
3. BTC       (haircut 10%)   ← sorted by haircut ascending, not this literal order
4. SOL       (haircut 25%)
5. HYPE      (haircut 30%)   ← most expensive to lose
```

---

## 8. Instruments and Positions

### 8.1 Instrument Model

```zig
pub const Instrument = struct {
    id:          InstrumentId,
    kind:        InstrumentKind,
    base:        []const u8,
    quote:       []const u8,
    status:      InstrumentStatus,  // active / delisted / settlement_only
};

pub const InstrumentKind = union(enum) {
    spot: void,
    perp: PerpSpec,
    option: OptionSpec,
};

pub const PerpSpec = struct {
    tick_size:        Price,
    lot_size:         Quantity,
    max_leverage:     u8,
    funding_interval: u64,    // ms; default 3_600_000
    mark_method:      MarkMethod,
    isolated_only:    bool,   // if true, margin cannot be removed manually
};

pub const OptionSpec = struct {
    expiry_ms:    i64,
    strike:       Price,
    option_type:  OptionType,    // call / put
    settlement:   SettlementType, // cash / physical
    tick_size:    Price,
    lot_size:     Quantity,
};
```

### 8.2 Unified Position Model

All instrument types share one `Position` struct. Unused fields are zero-valued.

```zig
pub const Position = struct {
    instrument_id:   InstrumentId,
    kind:            InstrumentKind,
    user:            Address,

    // Universal
    size:            Quantity,       // always positive
    side:            Side,           // .long / .short  (spot: always .long)
    entry_price:     Price,
    realized_pnl:    i64,            // signed USDC
    leverage:        u8,             // 1–max_leverage; set at open

    // Per-position margin
    margin_mode:     PositionMarginMode,
    isolated_margin: Quantity,       // non-zero in isolated / isolated_only mode

    // Perp-specific
    funding_index:   i64,            // last settled cumulative funding index

    // Options-specific (cached Greeks, refreshed on each price update)
    delta: f64,
    gamma: f64,
    vega:  f64,
    theta: f64,

    pub fn notional(self: Position, mark_px: Price) Quantity
    pub fn unrealizedPnl(self: Position, mark_px: Price) i64
    pub fn isExpired(self: Position, now_ms: i64) bool
    pub fn canRemoveMargin(self: Position) bool
    // false for isolated_only instruments
};

pub const Side = enum { long, short,
    pub fn opposite(self: Side) Side { return if (self == .long) .short else .long; }
};
```

---

## 9. Clearing Units

### 9.1 SpotClearingUnit

Spot fills settle immediately: base and quote assets swap atomically.
No position record is created for fully settled spot fills.

```zig
pub const SpotClearingUnit = struct {
    pub fn settle(self: *SpotClearingUnit, fill: Fill, state: *GlobalState) !FillSettledEvent
    pub fn calcFee(fill: Fill, cfg: FeeConfig) SpotFee
};
```

**Settlement logic:**

```
taker buys:
  taker.collateral.debit(USDC, quote_amount + taker_fee)
  taker.spot_balance[base] += fill.size
  maker.spot_balance[base] -= fill.size
  maker.collateral.credit(USDC, quote_amount - maker_fee)

taker sells: mirror of above
fee_pool += net_fees_collected
```

### 9.2 PerpClearingUnit

Perp fills net into positions. Before applying any fill, outstanding funding
is settled for both taker and maker.

```zig
pub const PerpClearingUnit = struct {
    funding_index: std.AutoHashMap(InstrumentId, FundingIndex),

    pub fn settle(self: *PerpClearingUnit, fill: Fill, state: *GlobalState) !FillSettledEvent
    pub fn settleFunding(self: *PerpClearingUnit, instrument_id: InstrumentId,
                         state: *GlobalState, now_ms: i64) !FundingSettledEvent
    pub fn calcFundingRate(self: *PerpClearingUnit, instrument_id: InstrumentId,
                           state: *GlobalState) FundingRate
};

pub const FundingIndex = struct {
    cumulative: i64,    // signed; quote per unit base
    last_rate:  i64,
    updated_at: i64,
};
```

**Position netting rules:**

| Incoming fill vs existing | Result |
|---------------------------|--------|
| Same direction | Size increases; entry price = VWAP |
| Opposite, fill < existing | Partial close; realize PnL for closed portion |
| Opposite, fill == existing | Full close; realize PnL; position removed |
| Opposite, fill > existing | Flip: close existing, open new in opposite direction |

**Funding settlement:**

```
rate   = clamp(mark_premium + interest_rate_basis, −0.05%, +0.05%)
  where mark_premium = (mark_price − index_price) / index_price

cumulative_index += rate

per open position:
  delta   = cumulative_index − position.funding_index
  payment = notional × delta
  long  pays when rate > 0; short receives
  short pays when rate < 0; long  receives
  position.funding_index = cumulative_index
```

### 9.3 OptionsClearingUnit

Options fills create long (buyer) or short (seller/writer) positions. Greeks
are cached on the position and refreshed on every oracle price update.
Expiry settlement uses Black-Scholes intrinsic value at the settlement price.

```zig
pub const OptionsClearingUnit = struct {
    pub fn settle(self: *OptionsClearingUnit, fill: Fill, state: *GlobalState) !FillSettledEvent
    pub fn refreshGreeks(self: *OptionsClearingUnit, state: *GlobalState) void
    pub fn settleExpired(self: *OptionsClearingUnit, state: *GlobalState,
                         now_ms: i64) ![]OptionExpiredEvent
};
```

**Expiry payout:**

```
intrinsic =
  call: max(0, settlement_price − strike)
  put:  max(0, strike − settlement_price)

payout = intrinsic × size
  long  receives payout
  short pays     payout
```

**Cached Greeks** (Black-Scholes, refreshed on each oracle price update):

```zig
pub fn calcGreeks(spot: f64, strike: f64, r: f64, sigma: f64, t: f64,
                  kind: OptionType) Greeks {
    const d1 = (log(spot/strike) + (r + 0.5*sigma*sigma)*t) / (sigma*sqrt(t));
    const d2 = d1 - sigma*sqrt(t);
    return switch (kind) {
        .call => .{ .delta = N(d1), .gamma = n(d1)/(spot*sigma*sqrt(t)),
                    .vega  = spot*n(d1)*sqrt(t),
                    .theta = -(spot*n(d1)*sigma)/(2*sqrt(t)) - r*strike*exp(-r*t)*N(d2) },
        .put  => .{ .delta = N(d1)-1, .gamma = n(d1)/(spot*sigma*sqrt(t)),
                    .vega  = spot*n(d1)*sqrt(t),
                    .theta = -(spot*n(d1)*sigma)/(2*sqrt(t)) + r*strike*exp(-r*t)*(1-N(d2)) },
    };
}
```

---

## 10. Margining

### 10.1 Position Margin Mode

```zig
pub const PositionMarginMode = enum {
    cross,         // default; shares collateral pool with all other cross positions
    isolated,      // ring-fenced collateral; can add/remove margin manually
    isolated_only, // same as isolated; margin CANNOT be removed manually
                   // set by the exchange for high-risk assets
};
```

| Mode | Collateral scope | Liquidation scope | Add/remove margin |
|------|-----------------|-------------------|-------------------|
| Cross | All cross positions share one pool | Account-wide | Not removable individually |
| Isolated | Only this position's `isolated_margin` | This position only | Yes |
| Isolated-only | Same as isolated | This position only | No (remove only on close) |

### 10.2 Initial Margin

```
initial_margin = position_size × mark_price / leverage
```

`leverage` is an integer in `[1, max_leverage]`. Leverage can be **increased**
on an existing position without closing it. It is only checked at open time;
the user is responsible for monitoring after that.

For **cross** positions, initial margin is locked from the collateral pool and
cannot be withdrawn while the position is open. Unrealized PnL from any cross
position automatically expands `available_for_new_positions`.

For **isolated** positions, unrealized PnL applies as additional margin for
that same position only — it is not transferable to other positions.

```zig
pub fn initialMargin(size: Quantity, mark_px: Price, leverage: u8) Quantity {
    return mulPriceQty(size, mark_px) / leverage;
}
```

### 10.3 Maintenance Margin

```
maintenance_margin_rate = 1 / (max_leverage × 2)
```

Example: asset with `max_leverage = 50` → MM rate = 1% of notional.

**Cross liquidation trigger:**
```
account_value < maintenance_margin_rate × total_open_notional

where:
  account_value    = collateral.effectiveTotal() + sum(unrealizedPnl, all cross positions)
  total_open_notional = sum(size × mark_price, all cross positions)
```

**Isolated liquidation trigger** (only this position's inputs):
```
isolated_margin + unrealized_pnl < maintenance_margin_rate × notional
```

```zig
pub fn maintenanceMarginRate(max_leverage: u8) f64 {
    return 1.0 / (@as(f64, @floatFromInt(max_leverage)) * 2.0);
}

pub fn maintenanceMarginRequired(positions: []const Position,
                                 state: *const GlobalState) Quantity {
    var total: u128 = 0;
    for (positions) |pos| {
        const mark_px  = state.markPrice(pos.instrument_id);
        const notional = mulPriceQty(pos.size, mark_px);
        const rate     = maintenanceMarginRate(
            state.instruments[pos.instrument_id].kind.perp.max_leverage);
        total += @intFromFloat(@as(f64, @floatFromInt(notional)) * rate);
    }
    return @intCast(total);
}
```

### 10.4 Transfer Margin Requirement

Any action that removes collateral (withdrawal, transfer to spot, isolated
margin reduction) must leave:

```
remaining_equity ≥ transfer_margin_required

transfer_margin_required = max(
    initial_margin_required,          // sum(notional / leverage) for all open positions
    0.1 × total_open_notional         // 10% floor of total position value
)
```

This prevents draining collateral via unrealized PnL when positions are in
profit.

```zig
pub fn transferMarginRequired(account: *const SubAccount,
                               state: *const GlobalState) Quantity {
    var total_notional: u128 = 0;
    var total_im:       u128 = 0;
    for (account.positions.values()) |pos| {
        const mark_px  = state.markPrice(pos.instrument_id);
        const notional = mulPriceQty(pos.size, mark_px);
        total_notional += notional;
        total_im       += initialMargin(pos.size, mark_px, pos.leverage);
    }
    return @intCast(@max(total_im, total_notional / 10));
}
```

### 10.5 MarginEngine Interface

```zig
pub const MarginEngine = struct {
    cfg: MarginConfig,

    pub fn init(cfg: MarginConfig) MarginEngine

    /// Full margin summary; dispatches by account mode.
    pub fn compute(self: *MarginEngine, account: *const SubAccount,
                   state: *const GlobalState) MarginSummary

    /// Pre-trade: would opening this order breach initial margin?
    pub fn checkInitialMargin(self: *MarginEngine, account: *const SubAccount,
                               order: Order, state: *const GlobalState) !void
    // error.InsufficientMargin

    /// Pre-transfer: would removing `amount` breach the transfer margin floor?
    pub fn checkTransferMargin(self: *MarginEngine, account: *const SubAccount,
                                amount: Quantity, state: *const GlobalState) !void
    // error.TransferWouldBreachMarginFloor

    pub fn computeStandard(self: *MarginEngine, account: *const SubAccount,
                            state: *const GlobalState) MarginSummary
    pub fn computeUnified(self: *MarginEngine, account: *const SubAccount,
                           state: *const GlobalState) MarginSummary
    pub fn computePortfolio(self: *MarginEngine, account: *const SubAccount,
                             state: *const GlobalState) MarginSummary
};

pub const MarginSummary = struct {
    mode:                 AccountMode,
    total_equity:         i64,       // effective_collateral + unrealized_pnl (signed)
    initial_margin_used:  Quantity,
    maintenance_margin:   Quantity,
    available_balance:    Quantity,  // equity − im_used; can be zero-floored for display
    transfer_margin_req:  Quantity,  // max(im_req, 10% notional)
    margin_ratio:         f64,       // equity / maintenance_margin  (portfolio: ratio formula)
    health:               AccountHealth,
    collateral_breakdown: []AssetBalance,
};

pub const AccountHealth = enum {
    healthy,      // equity ≥ initial_margin
    warning,      // maintenance_margin ≤ equity < initial_margin; no new positions
    liquidatable, // equity < maintenance_margin  (or portfolio_ratio > 0.95)
};
```

**Mode dispatch:**

```zig
pub fn compute(self: *MarginEngine, account: *const SubAccount,
               state: *const GlobalState) MarginSummary {
    return switch (account.master(state).mode_config.mode) {
        .standard        => self.computeStandard(account, state),
        .unified         => self.computeUnified(account, state),
        .portfolio_margin => self.computePortfolio(account, state),
        .dex_abstraction  => self.computeUnified(account, state), // treated as unified
    };
}
```

---

## 11. Portfolio Margin

Portfolio margin is a superset of cross margin. All eligible spot balances and
all cross perp positions are margined together as a single portfolio. Spot
positions offset perp PnL; a spot long + perp short on the same asset requires
far less margin than either alone.

**Eligible assets (pre-alpha):** USDC, USDH, BTC, HYPE.

### 11.1 LTV and Auto-Borrow

When an order would exceed available balance, the system automatically borrows
against eligible collateral:

```
max_auto_borrow(collateral_asset, borrow_asset)
  = collateral_balance × borrow_oracle_price(collateral_asset) × LTV(collateral_asset)
```

**LTV table (pre-alpha):**

| Asset | LTV |
|-------|-----|
| USDC | 1.00 |
| USDH | 1.00 |
| BTC | 0.85 |
| HYPE | 0.50 |

**Borrow oracle price** — three-way median for manipulation resistance:

```zig
pub fn borrowOraclePrice(token: AssetId, state: *const GlobalState) Price {
    const spot_usdc    = state.oracle.spotPrice(token);
    const usdt_usdc    = 1.0 / @as(f64, @floatFromInt(state.oracle.spotPrice(USDC_ID)));
    const perp_mark    = @intFromFloat(@as(f64, @floatFromInt(
                             state.oracle.perpMarkPrice(token))) * usdt_usdc);
    const perp_oracle  = @intFromFloat(@as(f64, @floatFromInt(
                             state.oracle.perpOraclePrice(token))) * usdt_usdc);
    return median3(spot_usdc, perp_mark, perp_oracle);
}
```

### 11.2 Supply / Borrow Caps (Pre-Alpha)

| Asset | Global supply | Global borrow | User supply | User borrow |
|-------|--------------|---------------|-------------|-------------|
| USDC | 500M | 100M | 5M | 1M |
| USDH | 500M | 100M | 5M | 1M |
| HYPE | 1M HYPE | — | 50k HYPE | — |
| BTC | 400 BTC | — | 20 BTC | — |

When global caps are hit, portfolio margin falls back to unified mode silently.

### 11.3 Borrow Interest Rate

```
stablecoin_borrow_rate_apy = 0.05 + 4.75 × max(0, utilization − 0.8)

where utilization = total_borrowed_value / total_supplied_value
```

Interest is compounded continuously, indexed hourly (aligned to funding
interval). Protocol retains 10% of interest; 90% distributed to suppliers.

```zig
pub fn stablecoinBorrowRate(utilization: f64) f64 {
    return 0.05 + 4.75 * @max(0.0, utilization - 0.8);
}

pub fn accruedInterest(principal: Quantity, rate_apy: f64, dt_seconds: f64) Quantity {
    const r = @log(1.0 + rate_apy);
    return @intFromFloat(
        @as(f64, @floatFromInt(principal)) * (@exp(r * dt_seconds / SECONDS_PER_YEAR) - 1.0)
    );
}
```

### 11.4 Portfolio Margin Ratio (Liquidation Trigger)

Account becomes liquidatable when `portfolio_margin_ratio > 0.95`.

```
portfolio_margin_ratio =
    max_{borrowable_token} (
        portfolio_maintenance_requirement(token)
        ─────────────────────────────────────────
        portfolio_liquidation_value(token)
    )

portfolio_maintenance_requirement(token) =
    20 USDC                                          ← min_borrow_offset
    + sum_{dex} cross_maintenance_margin(dex)
    + borrowed_amount(token) × borrow_oracle_price(token)

portfolio_liquidation_value(token) =
    portfolio_balance(token)
    + min(borrow_cap(token),
          min(portfolio_balance(token), supply_cap(token))
          × borrow_oracle_price(token)
          × liquidation_threshold(token))

liquidation_threshold(token) = 0.5 + 0.5 × LTV(token)

portfolio_balance(token) =
    spot_balance(token) + perp_unrealized_pnl_in_token − borrowed(token)
```

```zig
pub fn portfolioMarginRatio(account: *const SubAccount,
                             state: *const GlobalState) f64 {
    var max_ratio: f64 = 0.0;
    for (BORROWABLE_ASSETS) |token| {
        const pmr = portfolioMaintenanceRequirement(account, token, state);
        const plv = portfolioLiquidationValue(account, token, state);
        if (plv > 0) {
            max_ratio = @max(max_ratio,
                @as(f64, @floatFromInt(pmr)) / @as(f64, @floatFromInt(plv)));
        }
    }
    return max_ratio;
}
```

### 11.5 Portfolio MarginEngine Path

```zig
pub fn computePortfolio(self: *MarginEngine, account: *const SubAccount,
                         state: *const GlobalState) MarginSummary {
    // Fall back to unified if caps exceeded
    if (!portfolioCapsAvailable(account, state)) {
        return self.computeUnified(account, state);
    }
    const ratio  = portfolioMarginRatio(account, state);
    const health = classifyPortfolioHealth(ratio);
    return MarginSummary{
        .mode         = .portfolio_margin,
        .margin_ratio = ratio,
        .health       = health,
        // ... other fields computed from portfolio_balance / requirement
    };
}

fn classifyPortfolioHealth(ratio: f64) AccountHealth {
    if (ratio > 0.95) return .liquidatable;
    if (ratio > 0.90) return .warning;
    return .healthy;
}
```

---

## 12. Liquidation Engine

### 12.1 Scan

```zig
pub const LiquidationEngine = struct {
    insurance_fund: Quantity,   // USDC; absorbs liquidation losses
    margin:         *MarginEngine,
    cfg:            LiquidationConfig,

    pub fn scanCandidates(self: *LiquidationEngine,
                           state: *const GlobalState) []LiquidationCandidate

    pub fn execute(self: *LiquidationEngine, candidate: LiquidationCandidate,
                   ch: *Clearinghouse, state: *GlobalState) !LiquidationResult

    pub fn adl(self: *LiquidationEngine, instrument_id: InstrumentId, side: Side,
               shortfall: Quantity, ch: *Clearinghouse, state: *GlobalState) !AdlResult
};

pub const LiquidationCandidate = struct {
    user:         Address,       // sub-account address
    margin_ratio: f64,
    deficit:      Quantity,      // how far below maintenance
    snapshot:     []Position,    // position snapshot at scan time
};
```

`scanCandidates` is **pure read** — it never mutates state. Mutation happens
only in `execute`, called from step 9 of the next block.

### 12.2 Execute

Liquidation order (per instrument type):

| Type | Liquidation price |
|------|------------------|
| Perp | Mark price (deterministic) |
| Options | Intrinsic value at mark price |
| Spot margin | Oracle price |

```
1. Close all positions at liquidation price (synthetic fills, not via order book)
2. Compute net PnL across all closed positions
   net_pnl = sum(position_pnl) − liquidation_fee

3. Apply to insurance fund:
   if net_pnl ≥ 0:
     insurance_fund += net_pnl   (surplus from over-collateralized liq)
     account.collateral = 0
   else:
     shortfall = −net_pnl
     if insurance_fund ≥ shortfall:
       insurance_fund -= shortfall
     else:
       remaining = shortfall − insurance_fund
       insurance_fund = 0
       adl(instrument, opposing_side, remaining)
```

Portfolio margin liquidation: spot borrows or perp positions may be liquidated
first depending on oracle price update order — liquidation sequence is **not**
deterministic across instrument types within portfolio mode.

### 12.3 ADL Ranking

When the insurance fund is exhausted, the most profitable opposing position
is reduced first.

```zig
pub fn adlRank(pos: *const Position, mark_px: Price) f64 {
    const upnl     = @as(f64, @floatFromInt(pos.unrealizedPnl(mark_px)));
    const notional = @as(f64, @floatFromInt(mulPriceQty(mark_px, pos.size)));
    const margin   = @as(f64, @floatFromInt(pos.isolated_margin));
    if (notional == 0 or margin == 0) return 0;
    return (upnl / notional) * (notional / margin);  // pnl_ratio × leverage
}
```

Accounts are sorted by `adlRank` descending. The highest-rank account is
reduced first, then the next, until the shortfall is covered.

---

## 13. Transfer Engine

All collateral movements — intra-master, deposit, withdrawal — run through
`TransferEngine`. Every transfer re-validates the source sub-account's margin
after the hypothetical deduction before committing.

```zig
pub const TransferEngine = struct {
    margin: *MarginEngine,

    pub fn executeIntraMaster(
        self: *TransferEngine, action: IntraMasterTransferAction,
        master: *MasterAccount, oracle: *const Oracle, state: *GlobalState,
    ) !TransferEvent
    // Atomic: withdraw from src → check margin → credit to dst
    // Rolls back on error.WouldBreachMaintenanceMargin

    pub fn executeDeposit(
        self: *TransferEngine, action: DepositAction,
        master: *MasterAccount, state: *GlobalState,
    ) !TransferEvent
    // Credits target sub-account after bridge proof verification

    pub fn executeWithdrawal(
        self: *TransferEngine, action: WithdrawalAction,
        master: *MasterAccount, oracle: *const Oracle, state: *GlobalState,
    ) !TransferEvent
    // Checks transfer_margin_required before deducting
};
```

### Actions

```zig
pub const IntraMasterTransferAction = struct {
    type:       []const u8,  // "subAccountTransfer"
    from_index: u8,
    to_index:   u8,
    asset_id:   AssetId,
    amount:     Quantity,
};

pub const DepositAction = struct {
    type:       []const u8,  // "deposit"
    to_index:   u8,          // 0 = primary sub-account
    asset_id:   AssetId,
    amount:     Quantity,
    l1_tx_hash: [32]u8,
};

pub const WithdrawalAction = struct {
    type:        []const u8,  // "withdraw"
    from_index:  u8,
    asset_id:    AssetId,
    amount:      Quantity,
    destination: Address,
};
```

---

## 14. Events

```zig
pub const ClearinghouseEvent = union(enum) {
    fill_settled:        FillSettledEvent,
    funding_settled:     FundingSettledEvent,
    interest_indexed:    InterestIndexedEvent,    // portfolio mode
    option_expired:      OptionExpiredEvent,
    liquidated:          LiquidationEvent,
    adl_executed:        AdlEvent,
    margin_warning:      MarginWarningEvent,
    transfer_completed:  TransferEvent,
    mode_changed:        AccountModeChangedEvent,
    sub_account_opened:  SubAccountOpenedEvent,
    sub_account_closed:  SubAccountClosedEvent,
};
```

---

## 15. Test Harness

### Account and Sub-Account

```zig
test "deriveSubAccountAddress - deterministic and unique" {
    const a0 = deriveSubAccountAddress(master_a, 0);
    const a1 = deriveSubAccountAddress(master_a, 1);
    try std.testing.expect(!std.mem.eql(u8, &a0, &a1));
    try std.testing.expectEqual(a0, deriveSubAccountAddress(master_a, 0));
}

test "openSubAccount - creates isolated empty state" {
    var master = MasterAccount.init(master_addr);
    const sub = try master.openSubAccount(1, null);
    try std.testing.expect(sub.isEmpty());
    try std.testing.expectEqual(deriveSubAccountAddress(master_addr, 1), sub.address);
}

test "closeSubAccount - fails if collateral present" {
    var master = MasterAccount.init(master_addr);
    const sub = try master.openSubAccount(2, null);
    try sub.collateral.deposit(USDC_ID, 1_000 * USDC, &registry);
    try std.testing.expectError(error.SubAccountNotEmpty, master.closeSubAccount(2));
}

test "liquidation isolation - sub 0 liq does not touch sub 1" {
    var state = testState(.{
        .sub0 = .{ .collateral = 100 * USDC,    .position = big_underwater_btc_long },
        .sub1 = .{ .collateral = 10_000 * USDC },
    });
    _ = try engine.execute(candidates[0], &ch, &state);
    const sub1_bal = resolveSubAccount(&state, derive(master, 1)).?.collateral.effectiveTotal(&reg, &oracle);
    try std.testing.expectEqual(10_000 * USDC, sub1_bal);
}
```

### Account Mode

```zig
test "standard mode - spot balance not visible to perp margin" {
    var sub = testSub(.{ .mode = .standard, .spot_usdc = 100_000 * USDC });
    const s = MarginEngine.init(cfg).computeStandard(&sub, &state);
    try std.testing.expectEqual(0, s.total_equity);
}

test "unified mode - spot USDC collateralizes perp positions" {
    var sub = testSub(.{ .mode = .unified, .spot_usdc = 100_000 * USDC,
                         .perp = btcLong(1, 10) });
    const s = MarginEngine.init(cfg).computeUnified(&sub, &state);
    try std.testing.expectEqual(.healthy, s.health);
}

test "set mode to dex_abstraction - rejected" {
    try std.testing.expectError(error.ModeDeprecated,
        state.setAccountMode(master_addr, .dex_abstraction));
}

test "set mode to portfolio_margin below volume threshold - rejected" {
    try std.testing.expectError(error.InsufficientVolume,
        state.setAccountMode(low_volume_addr, .portfolio_margin));
}

test "daily action limit exceeded - rejected" {
    var master = testMaster(.{ .mode = .unified });
    master.daily_actions.count = 50_000;
    try std.testing.expectError(error.DailyActionLimitExceeded,
        master.daily_actions.check(.unified.dailyActionLimit(), now_ms));
}
```

### Collateral

```zig
test "effectiveTotal - USDC at 1:1" {
    var pool = CollateralPool.init(alloc);
    try pool.deposit(USDC_ID, 10_000 * USDC, &registry);
    try std.testing.expectEqual(10_000 * USDC, pool.effectiveTotal(&registry, &oracle));
}

test "effectiveTotal - BTC with 10% haircut" {
    var pool = CollateralPool.init(alloc);
    try pool.deposit(BTC_ID, 1 * BTC, &registry);
    oracle.setPrice(BTC_ID, 50_000 * USDC);
    try std.testing.expectEqual(45_000 * USDC, pool.effectiveTotal(&registry, &oracle));
}

test "deposit exceeds max concentration - rejected" {
    var pool = CollateralPool.init(alloc);
    try pool.deposit(USDC_ID, 1_000 * USDC, &registry);
    try std.testing.expectError(error.MaxConcentrationExceeded,
        pool.deposit(HYPE_ID, 1_000_000 * HYPE, &registry));
}

test "debitEffective - USDC consumed first" {
    var pool = CollateralPool.init(alloc);
    try pool.deposit(USDC_ID, 5_000 * USDC, &registry);
    try pool.deposit(BTC_ID,  1 * BTC,      &registry);
    try pool.debitEffective(3_000 * USDC, &registry, &oracle);
    try std.testing.expectEqual(2_000 * USDC, pool.rawBalance(USDC_ID));
    try std.testing.expectEqual(1 * BTC,       pool.rawBalance(BTC_ID));
}
```

### Clearing Units

```zig
test "spot buy fill - base to taker, quote to maker" {
    var state = testState(.{ .taker_usdc = 100_000, .maker_btc = 1 });
    _ = try SpotClearingUnit.init().settle(
        makeFill(.{ .taker_is_buy = true, .price = 50_000 * USDC, .size = 1 * BTC }),
        &state);
    try std.testing.expect(state.takerBtcBalance() == 1 * BTC);
    try std.testing.expect(state.makerUsdcBalance() > 49_000 * USDC);
}

test "perp long - open, increase VWAP, partial close, flip" {
    var unit = PerpClearingUnit.init(alloc);
    // open
    _ = try unit.settle(makeFill(.{ .taker_is_buy = true,  .price = 100_000, .size = 1 }), &state);
    // increase
    _ = try unit.settle(makeFill(.{ .taker_is_buy = true,  .price = 102_000, .size = 1 }), &state);
    const pos = state.takerPosition(BTC_PERP_ID);
    try std.testing.expectEqual(2, pos.size);
    try std.testing.expectEqual(101_000, pos.entry_price); // VWAP
    // partial close
    _ = try unit.settle(makeFill(.{ .taker_is_buy = false, .size = 1 }), &state);
    try std.testing.expectEqual(1, state.takerPosition(BTC_PERP_ID).size);
}

test "funding - longs pay when mark > index" {
    oracle.setMarkPrice(BTC_PERP_ID, 50_500 * USDC);
    oracle.setIndexPrice(BTC_PERP_ID, 50_000 * USDC);
    const event = try unit.settleFunding(BTC_PERP_ID, &state, now_ms);
    try std.testing.expect(event.rate.raw > 0);
    try std.testing.expect(state.longBalance() < initial_long_balance);
    try std.testing.expect(state.shortBalance() > initial_short_balance);
}

test "call expires ITM - long receives intrinsic value" {
    var state = testExpiredOption(.{ .kind = .call, .strike = 50_000,
                                     .settlement_px = 55_000, .long_size = 1 });
    const events = try OptionsClearingUnit.init(alloc).settleExpired(&state, expiry_ms + 1);
    try std.testing.expect(state.longBalance() > initial_balance); // +5000
}
```

### Margining

```zig
test "initial margin formula - notional / leverage" {
    try std.testing.expectEqual(10_000 * USDC, initialMargin(1 * BTC, 100_000 * USDC, 10));
}

test "maintenance margin rate - half of im rate at max leverage" {
    try std.testing.expectApproxEqAbs(0.01, maintenanceMarginRate(50), 1e-9);
}

test "cross - unrealized pnl immediately usable for new positions" {
    var sub = testSub(.{ .balance = 10_000 * USDC,
                         .position = btcLong(.{ .entry = 90_000, .mark = 100_000, .lev = 10 }) });
    const s = MarginEngine.init(cfg).computeUnified(&sub, &state);
    // equity = 10k + 10k upnl = 20k; im_used = 10k; available = 10k
    try std.testing.expectEqual(20_000 * USDC, @intCast(s.total_equity));
    try std.testing.expectEqual(10_000 * USDC, s.available_balance);
}

test "transfer margin req - max(im, 10% notional)" {
    // notional = 100k, im = 20k, 10% = 10k → req = 20k
    var sub = testSub(.{ .balance = 25_000 * USDC,
                         .position = btcLong(.{ .mark = 100_000, .lev = 5 }) });
    try std.testing.expectEqual(20_000 * USDC, transferMarginRequired(&sub, &state));
}

test "transfer exceeds floor - rejected" {
    var sub = testSub(.{ .balance = 25_000 * USDC,
                         .position = btcLong(.{ .mark = 100_000, .lev = 5 }) });
    // safely withdrawable = 25000 − 20000 = 5000; trying 10000
    try std.testing.expectError(error.TransferWouldBreachMarginFloor,
        MarginEngine.init(cfg).checkTransferMargin(&sub, 10_000 * USDC, &state));
}

test "isolated margin - isolated liq does not affect cross positions" {
    var sub = testSub(.{ .positions = .{
        .{ .id = BTC_PERP_ID, .mode = .cross,    .size = 1 * BTC },
        .{ .id = ETH_PERP_ID, .mode = .isolated, .isolated_margin = 200 * USDC,
           .size = 10 * ETH },
    }});
    oracle.setMarkPrice(ETH_PERP_ID, 1 * USDC); // ETH crashes, isolated breached
    const btc_health = MarginEngine.init(cfg).computeForPosition(&sub, BTC_PERP_ID, &state).health;
    try std.testing.expectEqual(.healthy, btc_health);
}
```

### Portfolio Margin

```zig
test "carry trade - spot BTC + short perp requires far less margin" {
    var sub = testPortfolioSub(.{ .spot_btc = 1 * BTC, .perp_short_btc = 1 * BTC,
                                   .mark = 100_000 * USDC });
    const pm   = MarginEngine.init(cfg).computePortfolio(&sub, &state);
    const cross = MarginEngine.init(cfg).computeUnified(&sub, &state);
    try std.testing.expect(pm.maintenance_margin < cross.maintenance_margin);
    try std.testing.expectEqual(.healthy, pm.health);
}

test "portfolio_margin_ratio > 0.95 → liquidatable" {
    var sub = testPortfolioSub(.{ .spot_hype = 100 * HYPE, .perp_long_btc_20x = 1 * BTC });
    oracle.setPrice(HYPE_ID, 1 * USDC); // HYPE crash
    oracle.setPrice(BTC_ID, 100_000 * USDC);
    try std.testing.expectEqual(.liquidatable,
        MarginEngine.init(cfg).computePortfolio(&sub, &state).health);
}

test "borrow rate kink - below 80% util at 5% APY" {
    try std.testing.expectApproxEqAbs(0.05, stablecoinBorrowRate(0.5), 1e-9);
}

test "borrow rate kink - 90% util → 52.5% APY" {
    try std.testing.expectApproxEqAbs(0.525, stablecoinBorrowRate(0.9), 1e-9);
}

test "cap exceeded - falls back to unified mode" {
    var state = testState(.{ .usdc_global_supply = 500_000_001 * USDC });
    var sub   = testPortfolioSub(.{ .spot_usdc = 10_000 * USDC });
    const s   = MarginEngine.init(cfg).computePortfolio(&sub, &state);
    try std.testing.expectEqual(.unified, s.mode);
}

test "min_borrow_offset 20 USDC always included in maintenance req" {
    var sub = testPortfolioSub(.{ .spot_usdc = 1_000_000 * USDC }); // no positions
    const pmr = portfolioMaintenanceRequirement(&sub, USDC_ID, &state);
    try std.testing.expect(pmr >= 20 * USDC);
}
```

### Liquidation

```zig
test "scan finds account below maintenance margin" {
    var state = testState(.{ .sub0 = .{ .balance = 100 * USDC,
                                        .position = bigUnderwaterLong } });
    const candidates = LiquidationEngine.init(cfg, &margin).scanCandidates(&state);
    try std.testing.expectEqual(1, candidates.len);
}

test "liquidation surplus - credited to insurance fund" {
    var engine = LiquidationEngine.init(cfg, &margin);
    engine.insurance_fund = 0;
    _ = try engine.execute(slightlyUnderwaterCandidate, &ch, &state);
    try std.testing.expect(engine.insurance_fund > 0);
}

test "liquidation deficit - covered by insurance fund" {
    var engine = LiquidationEngine.init(cfg, &margin);
    engine.insurance_fund = 10_000 * USDC;
    _ = try engine.execute(deeplyUnderwaterCandidate, &ch, &state);
    try std.testing.expect(!engine.adlTriggered);
    try std.testing.expect(engine.insurance_fund < 10_000 * USDC);
}

test "insurance fund exhausted - triggers ADL" {
    var engine = LiquidationEngine.init(cfg, &margin);
    engine.insurance_fund = 0;
    const result = try engine.execute(massiveUnderwaterCandidate, &ch, &state);
    try std.testing.expect(result.adl_triggered);
}

test "ADL ranking - higher profit × leverage reduced first" {
    // pos_a: upnl_ratio 0.5, leverage 10 → rank 5
    // pos_b: upnl_ratio 0.1, leverage 20 → rank 2
    try std.testing.expect(adlRank(&pos_a, mark) > adlRank(&pos_b, mark));
    _ = try engine.adl(BTC_PERP_ID, .long, shortfall, &ch, &state);
    try std.testing.expect(state.posSize(high_rank_addr, BTC_PERP_ID) < initial_high_size);
    try std.testing.expectEqual(initial_low_size, state.posSize(low_rank_addr, BTC_PERP_ID));
}
```

### Transfer

```zig
test "intra-master transfer - moves asset between sub-accounts" {
    var master = testMaster(.{ .sub0_usdc = 10_000, .sub1_usdc = 0 });
    _ = try TransferEngine.init(&margin).executeIntraMaster(
        .{ .from_index = 0, .to_index = 1, .asset_id = USDC_ID, .amount = 3_000 * USDC },
        &master, &oracle, &state);
    try std.testing.expectEqual(7_000 * USDC, master.sub_accounts[0].?.collateral.rawBalance(USDC_ID));
    try std.testing.expectEqual(3_000 * USDC, master.sub_accounts[1].?.collateral.rawBalance(USDC_ID));
}

test "intra-master transfer - rejected if would breach maintenance margin" {
    var master = testMaster(.{ .sub0 = .{ .usdc = 3_000, .position = requiresMM2900 } });
    try std.testing.expectError(error.WouldBreachMaintenanceMargin,
        TransferEngine.init(&margin).executeIntraMaster(
            .{ .from_index = 0, .to_index = 1, .asset_id = USDC_ID, .amount = 200 * USDC },
            &master, &oracle, &state));
    // atomic rollback: source balance unchanged
    try std.testing.expectEqual(3_000 * USDC, master.sub_accounts[0].?.collateral.rawBalance(USDC_ID));
}

test "withdrawal - rejected if would breach transfer margin floor" {
    var master = testMaster(.{ .sub0 = .{ .usdc = 3_000, .position = requiresTMR2900 } });
    try std.testing.expectError(error.TransferWouldBreachMarginFloor,
        TransferEngine.init(&margin).executeWithdrawal(
            .{ .from_index = 0, .asset_id = USDC_ID, .amount = 200 * USDC,
               .destination = l1_addr },
            &master, &oracle, &state));
}
```
const std = @import("std");
const shared = @import("../../shared/mod.zig");

pub const MAX_SUB_ACCOUNTS: u8 = 20;
pub const USDC: u128 = 1_000_000;
pub const BTC: u128 = 100_000_000;
pub const ETH: u128 = 1_000_000_000_000_000_000;
pub const HYPE: u128 = 1_000_000_000_000_000_000;
pub const SOL: u128 = 1_000_000_000;

pub const InstrumentId = u32;
pub const AssetId = u64;

pub const USDC_ID: AssetId = 1;
pub const BTC_ID: AssetId = 2;
pub const ETH_ID: AssetId = 3;
pub const SOL_ID: AssetId = 4;
pub const HYPE_ID: AssetId = 5;

pub const InstrumentKind = union(enum) {
    spot: void,
    perp: PerpSpec,
    option: OptionSpec,
};

pub const PerpSpec = struct {
    tick_size: shared.types.Price,
    lot_size: shared.types.Quantity,
    max_leverage: u8,
    funding_interval_ms: u64,
    mark_method: MarkMethod,
    isolated_only: bool,
};

pub const MarkMethod = enum {
    oracle,
    mid_price,
    last_price,
};

pub const OptionSpec = struct {
    expiry_ms: i64,
    strike: shared.types.Price,
    option_type: OptionType,
    settlement: SettlementType,
    tick_size: shared.types.Price,
    lot_size: shared.types.Quantity,
};

pub const OptionType = enum { call, put };
pub const SettlementType = enum { cash, physical };

pub const InstrumentStatus = enum { active, delisted, settlement_only };

pub const Instrument = struct {
    id: InstrumentId,
    kind: InstrumentKind,
    base: []const u8,
    quote: []const u8,
    status: InstrumentStatus,
};

pub const PositionMarginMode = enum {
    cross,
    isolated,
    isolated_only,
};

pub const Position = struct {
    instrument_id: InstrumentId,
    kind: InstrumentKind,
    user: shared.types.Address,
    size: shared.types.Quantity,
    side: shared.types.Side,
    entry_price: shared.types.Price,
    realized_pnl: shared.types.SignedAmount,
    leverage: u8,
    margin_mode: PositionMarginMode,
    isolated_margin: shared.types.Quantity,
    funding_index: i64,
    delta: f64,
    gamma: f64,
    vega: f64,
    theta: f64,

    pub fn notional(self: Position, mark_px: shared.types.Price) shared.types.Quantity {
        return shared.fixed_point.mulPriceQty(mark_px, self.size);
    }

    pub fn unrealizedPnl(self: Position, mark_px: shared.types.Price) shared.types.SignedAmount {
        if (self.size == 0) return 0;
        const diff: i256 = if (self.side == .long)
            @as(i256, @intCast(mark_px)) - @as(i256, @intCast(self.entry_price))
        else
            @as(i256, @intCast(self.entry_price)) - @as(i256, @intCast(mark_px));
        return @intCast(@divTrunc(diff * @as(i512, @intCast(self.size)), shared.types.PRICE_SCALE));
    }

    pub fn isExpired(self: Position, now_ms: i64) bool {
        return switch (self.kind) {
            .option => |spec| now_ms >= spec.expiry_ms,
            else => false,
        };
    }

    pub fn canRemoveMargin(self: Position) bool {
        return self.margin_mode != .isolated_only;
    }
};

pub const Side = enum { long, short };

pub const Fill = struct {
    instrument_id: InstrumentId,
    instrument_kind: InstrumentKind,
    taker: shared.types.Address,
    maker: shared.types.Address,
    taker_order_id: u64,
    maker_order_id: u64,
    price: shared.types.Price,
    size: shared.types.Quantity,
    taker_is_buy: bool,
    timestamp: i64,
};

pub const FundingIndex = struct {
    cumulative: i64,
    last_rate: i64,
    updated_at: i64,
};

pub const FundingRate = struct {
    rate: f64,
    mark_premium: f64,
    interest_basis: f64,
};

pub const Greeks = struct {
    delta: f64,
    gamma: f64,
    vega: f64,
    theta: f64,
};

pub const BorrowPosition = struct {
    asset_id: AssetId,
    amount: shared.types.Quantity,
    cumulative_interest: shared.types.Quantity,
    opened_at: i64,
};

pub const MarginSummary = struct {
    mode: AccountMode,
    total_equity: shared.types.SignedAmount,
    initial_margin_used: shared.types.Quantity,
    maintenance_margin: shared.types.Quantity,
    available_balance: shared.types.Quantity,
    transfer_margin_req: shared.types.Quantity,
    margin_ratio: f64,
    health: AccountHealth,
    collateral_breakdown: []AssetBalance,
};

pub const AccountHealth = enum {
    healthy,
    warning,
    liquidatable,
};

pub const AssetBalance = struct {
    asset_id: AssetId,
    raw_amount: shared.types.Quantity,
    effective_usdc: shared.types.Quantity,
};

pub const CollateralEntry = struct {
    asset_id: AssetId,
    symbol: []const u8,
    haircut_pct: f64,
    max_pct: f64,
    enabled: bool,
};

pub const CollateralRegistry = []const CollateralEntry;

pub const LiquidationCandidate = struct {
    user: shared.types.Address,
    margin_ratio: f64,
    deficit: shared.types.Quantity,
    snapshot: []Position,
};

pub const LiquidationResult = struct {
    insurance_fund_delta: shared.types.SignedAmount,
    adl_triggered: bool,
    adl_shortfall: shared.types.Quantity,
};

pub const AdlResult = struct {
    reduced_accounts: usize,
    total_reduced: shared.types.Quantity,
    remaining_shortfall: shared.types.Quantity,
};

pub const TransferEvent = struct {
    from_addr: shared.types.Address,
    to_addr: shared.types.Address,
    asset_id: AssetId,
    amount: shared.types.Quantity,
    timestamp: i64,
};

pub const FillSettledEvent = struct {
    fill: Fill,
    taker_fee: shared.types.Quantity,
    maker_fee: shared.types.Quantity,
};

pub const FundingSettledEvent = struct {
    instrument_id: InstrumentId,
    rate: f64,
    cumulative_index: i64,
    timestamp: i64,
};

pub const InterestIndexedEvent = struct {
    instrument_id: InstrumentId,
    total_interest: shared.types.Quantity,
    timestamp: i64,
};

pub const OptionExpiredEvent = struct {
    instrument_id: InstrumentId,
    intrinsic_value: shared.types.Price,
    payout: shared.types.Quantity,
    timestamp: i64,
};

pub const LiquidationEvent = struct {
    user: shared.types.Address,
    instrument_id: InstrumentId,
    size: shared.types.Quantity,
    side: shared.types.Side,
    mark_px: shared.types.Price,
    pnl: shared.types.SignedAmount,
    insurance_fund_delta: shared.types.SignedAmount,
};

pub const AdlEvent = struct {
    instrument_id: InstrumentId,
    side: shared.types.Side,
    reduced_accounts: usize,
    total_reduced: shared.types.Quantity,
};

pub const MarginWarningEvent = struct {
    user: shared.types.Address,
    margin_ratio: f64,
    health: AccountHealth,
};

pub const AccountModeChangedEvent = struct {
    master: shared.types.Address,
    old_mode: AccountMode,
    new_mode: AccountMode,
    timestamp: i64,
};

pub const SubAccountOpenedEvent = struct {
    master: shared.types.Address,
    sub_index: u8,
    address: shared.types.Address,
};

pub const SubAccountClosedEvent = struct {
    master: shared.types.Address,
    sub_index: u8,
};

pub const ClearinghouseEvent = union(enum) {
    fill_settled: FillSettledEvent,
    funding_settled: FundingSettledEvent,
    interest_indexed: InterestIndexedEvent,
    option_expired: OptionExpiredEvent,
    liquidated: LiquidationEvent,
    adl_executed: AdlEvent,
    margin_warning: MarginWarningEvent,
    transfer_completed: TransferEvent,
    mode_changed: AccountModeChangedEvent,
    sub_account_opened: SubAccountOpenedEvent,
    sub_account_closed: SubAccountClosedEvent,
};

pub const AccountMode = enum(u8) {
    standard = 0,
    unified = 1,
    portfolio_margin = 2,
    dex_abstraction = 3,

    pub fn dailyActionLimit(self: AccountMode) ?u64 {
        return switch (self) {
            .standard => null,
            else => 50_000,
        };
    }
};

pub const AccountModeConfig = struct {
    mode: AccountMode,
    changed_at: i64,
};

pub const MasterPermissions = struct {
    global_agents: []shared.types.Address,
};

pub const DailyActionCounter = struct {
    count: u64,
    reset_at_ms: i64,

    pub fn check(self: *DailyActionCounter, limit: ?u64, now_ms: i64) !void {
        if (now_ms >= self.reset_at_ms) {
            self.count = 0;
            self.reset_at_ms = nextMidnightUtc(now_ms);
        }
        if (limit) |l| {
            if (self.count >= l) return error.DailyActionLimitExceeded;
        }
        self.count += 1;
    }
};

pub const SubAccountRef = struct {
    master: shared.types.Address,
    index: u8,
};

pub const FeeConfig = struct {
    taker_fee_bps: u32 = 10,
    maker_fee_bps: u32 = 2,
};

pub const ClearinghouseConfig = struct {
    max_sub_accounts: u8 = MAX_SUB_ACCOUNTS,
    fee_config: FeeConfig = .{},
    collateral_registry: []const CollateralEntry = &defaultCollateralRegistry,
};

pub const MarginConfig = struct {
    default_max_leverage: u8 = 50,
};

pub const LiquidationConfig = struct {
    liquidation_fee_bps: u32 = 50,
    adl_max_accounts: usize = 100,
};

pub const BORROWABLE_ASSETS = [_]AssetId{ USDC_ID, BTC_ID, HYPE_ID };
pub const SECONDS_PER_YEAR: f64 = 31_536_000.0;

pub const defaultCollateralRegistry = [_]CollateralEntry{
    .{ .asset_id = USDC_ID, .symbol = "USDC", .haircut_pct = 0.0, .max_pct = 1.0, .enabled = true },
    .{ .asset_id = BTC_ID, .symbol = "BTC", .haircut_pct = 0.10, .max_pct = 0.50, .enabled = true },
    .{ .asset_id = ETH_ID, .symbol = "ETH", .haircut_pct = 0.15, .max_pct = 0.40, .enabled = true },
    .{ .asset_id = SOL_ID, .symbol = "SOL", .haircut_pct = 0.25, .max_pct = 0.30, .enabled = true },
    .{ .asset_id = HYPE_ID, .symbol = "HYPE", .haircut_pct = 0.30, .max_pct = 0.20, .enabled = true },
};

fn nextMidnightUtc(now_ms: i64) i64 {
    const ms_per_day: i64 = 86_400_000;
    const day_start = @divTrunc(now_ms, ms_per_day) * ms_per_day;
    return day_start + ms_per_day;
}

pub fn deriveSubAccountAddress(master: shared.types.Address, index: u8) shared.types.Address {
    var buf: [21]u8 = undefined;
    @memcpy(buf[0..20], &master);
    buf[20] = index;
    const hash = shared.crypto.keccak256(&buf);
    var addr: shared.types.Address = undefined;
    @memcpy(&addr, hash[12..32]);
    return addr;
}

pub fn initialMargin(size: shared.types.Quantity, mark_px: shared.types.Price, leverage: u8) shared.types.Quantity {
    return shared.fixed_point.mulPriceQty(mark_px, size) / @as(shared.types.Quantity, @intCast(leverage));
}

pub fn maintenanceMarginRate(max_leverage: u8) f64 {
    return 1.0 / (@as(f64, @floatFromInt(max_leverage)) * 2.0);
}

pub fn stablecoinBorrowRate(utilization: f64) f64 {
    return 0.05 + 4.75 * @max(0.0, utilization - 0.8);
}

pub fn accruedInterest(principal: shared.types.Quantity, rate_apy: f64, dt_seconds: f64) shared.types.Quantity {
    const r = @log(1.0 + rate_apy);
    return @intFromFloat(
        @as(f64, @floatFromInt(principal)) * (@exp(r * dt_seconds / SECONDS_PER_YEAR) - 1.0),
    );
}

pub fn adlRank(pos: *const Position, mark_px: shared.types.Price) f64 {
    const upnl = @as(f64, @floatFromInt(pos.unrealizedPnl(mark_px)));
    const notional = @as(f64, @floatFromInt(shared.fixed_point.mulPriceQty(mark_px, pos.size)));
    const margin = @as(f64, @floatFromInt(pos.isolated_margin));
    if (notional == 0 or margin == 0) return 0;
    return (upnl / notional) * (notional / margin);
}

pub fn classifyPortfolioHealth(ratio: f64) AccountHealth {
    if (ratio > 0.95) return .liquidatable;
    if (ratio > 0.90) return .warning;
    return .healthy;
}

pub fn calcGreeks(spot: f64, strike: f64, r: f64, sigma: f64, t: f64, kind: OptionType) Greeks {
    const d1 = (@log(spot / strike) + (r + 0.5 * sigma * sigma) * t) / (sigma * @sqrt(t));
    const d2 = d1 - sigma * @sqrt(t);
    const n_d1 = std.math.exp(-0.5 * d1 * d1) / @sqrt(2.0 * std.math.pi);
    return switch (kind) {
        .call => .{
            .delta = normalCdf(d1),
            .gamma = n_d1 / (spot * sigma * @sqrt(t)),
            .vega = spot * n_d1 * @sqrt(t),
            .theta = -(spot * n_d1 * sigma) / (2 * @sqrt(t)) - r * strike * @exp(-r * t) * normalCdf(d2),
        },
        .put => .{
            .delta = normalCdf(d1) - 1.0,
            .gamma = n_d1 / (spot * sigma * @sqrt(t)),
            .vega = spot * n_d1 * @sqrt(t),
            .theta = -(spot * n_d1 * sigma) / (2 * @sqrt(t)) + r * strike * @exp(-r * t) * (1.0 - normalCdf(d2)),
        },
    };
}

fn normalCdf(x: f64) f64 {
    return 0.5 * (1.0 + std.math.erf(x / @sqrt(2.0)));
}

test "deriveSubAccountAddress - deterministic and unique" {
    const master_a = [_]u8{0xAA} ** 20;
    const a0 = deriveSubAccountAddress(master_a, 0);
    const a1 = deriveSubAccountAddress(master_a, 1);
    try std.testing.expect(!std.mem.eql(u8, &a0, &a1));
    try std.testing.expect(std.mem.eql(u8, &a0, &deriveSubAccountAddress(master_a, 0)));
}

test "initial margin formula - notional / leverage" {
    try std.testing.expectEqual(@as(shared.types.Quantity, 10_000), initialMargin(1, 100_000, 10));
}

test "maintenance margin rate - half of im rate at max leverage" {
    try std.testing.expectApproxEqAbs(0.01, maintenanceMarginRate(50), 1e-9);
}

test "borrow rate kink - below 80% util at 5% APY" {
    try std.testing.expectApproxEqAbs(0.05, stablecoinBorrowRate(0.5), 1e-9);
}

test "borrow rate kink - 90% util -> 52.5% APY" {
    try std.testing.expectApproxEqAbs(0.525, stablecoinBorrowRate(0.9), 1e-9);
}

test "ADL ranking - higher profit x leverage reduced first" {
    const pos_a = Position{
        .instrument_id = 1,
        .kind = .{ .perp = .{
            .tick_size = 1,
            .lot_size = 1,
            .max_leverage = 50,
            .funding_interval_ms = 3_600_000,
            .mark_method = .oracle,
            .isolated_only = false,
        } },
        .user = [_]u8{1} ** 20,
        .size = 1,
        .side = .long,
        .entry_price = 50_000,
        .realized_pnl = 0,
        .leverage = 10,
        .margin_mode = .isolated,
        .isolated_margin = 1000,
        .funding_index = 0,
        .delta = 0,
        .gamma = 0,
        .vega = 0,
        .theta = 0,
    };
    const pos_b = Position{
        .instrument_id = 1,
        .kind = .{ .perp = .{
            .tick_size = 1,
            .lot_size = 1,
            .max_leverage = 50,
            .funding_interval_ms = 3_600_000,
            .mark_method = .oracle,
            .isolated_only = false,
        } },
        .user = [_]u8{2} ** 20,
        .size = 1,
        .side = .long,
        .entry_price = 90_000,
        .realized_pnl = 0,
        .leverage = 20,
        .margin_mode = .isolated,
        .isolated_margin = 5000,
        .funding_index = 0,
        .delta = 0,
        .gamma = 0,
        .vega = 0,
        .theta = 0,
    };
    const mark: shared.types.Price = 100_000;
    try std.testing.expect(adlRank(&pos_a, mark) > adlRank(&pos_b, mark));
}

test "classifyPortfolioHealth" {
    try std.testing.expectEqual(AccountHealth.healthy, classifyPortfolioHealth(0.80));
    try std.testing.expectEqual(AccountHealth.warning, classifyPortfolioHealth(0.92));
    try std.testing.expectEqual(AccountHealth.liquidatable, classifyPortfolioHealth(0.96));
}

test "Position unrealizedPnl for long" {
    const pos = Position{
        .instrument_id = 1,
        .kind = .{ .perp = .{
            .tick_size = 1,
            .lot_size = 1,
            .max_leverage = 50,
            .funding_interval_ms = 3_600_000,
            .mark_method = .oracle,
            .isolated_only = false,
        } },
        .user = [_]u8{1} ** 20,
        .size = 1,
        .side = .long,
        .entry_price = 50_000,
        .realized_pnl = 0,
        .leverage = 10,
        .margin_mode = .isolated,
        .isolated_margin = 1000,
        .funding_index = 0,
        .delta = 0,
        .gamma = 0,
        .vega = 0,
        .theta = 0,
    };
    try std.testing.expect(pos.unrealizedPnl(60_000) > 0);
    try std.testing.expect(pos.unrealizedPnl(40_000) < 0);
}

test "Position notional" {
    const pos = Position{
        .instrument_id = 1,
        .kind = .{ .perp = .{
            .tick_size = 1,
            .lot_size = 1,
            .max_leverage = 50,
            .funding_interval_ms = 3_600_000,
            .mark_method = .oracle,
            .isolated_only = false,
        } },
        .user = [_]u8{1} ** 20,
        .size = 1,
        .side = .long,
        .entry_price = 50_000,
        .realized_pnl = 0,
        .leverage = 10,
        .margin_mode = .isolated,
        .isolated_margin = 1000,
        .funding_index = 0,
        .delta = 0,
        .gamma = 0,
        .vega = 0,
        .theta = 0,
    };
    try std.testing.expectEqual(@as(shared.types.Quantity, 100_000), pos.notional(100_000));
}

test "Position canRemoveMargin" {
    const pos_cross = Position{
        .instrument_id = 1,
        .kind = .{ .perp = .{
            .tick_size = 1,
            .lot_size = 1,
            .max_leverage = 50,
            .funding_interval_ms = 3_600_000,
            .mark_method = .oracle,
            .isolated_only = false,
        } },
        .user = [_]u8{1} ** 20,
        .size = 1,
        .side = .long,
        .entry_price = 50_000,
        .realized_pnl = 0,
        .leverage = 10,
        .margin_mode = .cross,
        .isolated_margin = 0,
        .funding_index = 0,
        .delta = 0,
        .gamma = 0,
        .vega = 0,
        .theta = 0,
    };
    const pos_isolated_only = Position{
        .instrument_id = 1,
        .kind = .{ .perp = .{
            .tick_size = 1,
            .lot_size = 1,
            .max_leverage = 50,
            .funding_interval_ms = 3_600_000,
            .mark_method = .oracle,
            .isolated_only = true,
        } },
        .user = [_]u8{1} ** 20,
        .size = 1,
        .side = .long,
        .entry_price = 50_000,
        .realized_pnl = 0,
        .leverage = 10,
        .margin_mode = .isolated_only,
        .isolated_margin = 1000,
        .funding_index = 0,
        .delta = 0,
        .gamma = 0,
        .vega = 0,
        .theta = 0,
    };
    try std.testing.expect(pos_cross.canRemoveMargin());
    try std.testing.expect(!pos_isolated_only.canRemoveMargin());
}

test "AccountMode dailyActionLimit" {
    try std.testing.expectEqual(@as(?u64, null), AccountMode.standard.dailyActionLimit());
    try std.testing.expectEqual(@as(?u64, 50_000), AccountMode.unified.dailyActionLimit());
    try std.testing.expectEqual(@as(?u64, 50_000), AccountMode.portfolio_margin.dailyActionLimit());
}

test "DailyActionCounter increments and resets" {
    var counter = DailyActionCounter{ .count = 0, .reset_at_ms = 1_700_000_000_000 + 86_400_000 };
    try counter.check(null, 1_700_000_000_000);
    try std.testing.expectEqual(@as(u64, 1), counter.count);
    try counter.check(50_000, 1_700_000_000_000 + 1);
    try std.testing.expectEqual(@as(u64, 2), counter.count);
}

test "DailyActionCounter rejects when limit exceeded" {
    var counter = DailyActionCounter{ .count = 50_000, .reset_at_ms = 1_700_000_000_000 + 86_400_000 };
    try std.testing.expectError(
        error.DailyActionLimitExceeded,
        counter.check(50_000, 1_700_000_000_000),
    );
}

test "nextMidnightUtc computes correctly" {
    const midnight = nextMidnightUtc(1_700_000_000_000);
    try std.testing.expect(midnight > 1_700_000_000_000);
    try std.testing.expect(@rem(midnight, 86_400_000) == 0);
}

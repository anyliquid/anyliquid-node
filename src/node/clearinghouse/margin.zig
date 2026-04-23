const std = @import("std");
const shared = @import("../../shared/mod.zig");
const types = @import("types.zig");
const account = @import("account.zig");
const portfolio_mod = @import("portfolio.zig");

pub const MarginEngine = struct {
    cfg: types.MarginConfig,

    pub fn init(cfg: types.MarginConfig) MarginEngine {
        return .{ .cfg = cfg };
    }

    pub fn compute(self: *const MarginEngine, sub: *const account.SubAccount, state: *const GlobalState) types.MarginSummary {
        return switch (sub.master_mode) {
            .standard => self.computeStandard(sub, state),
            .unified => self.computeUnified(sub, state),
            .portfolio_margin => self.computePortfolio(sub, state),
            .dex_abstraction => self.computeUnified(sub, state),
        };
    }

    pub fn computeStandard(self: *const MarginEngine, sub: *const account.SubAccount, state: *const GlobalState) types.MarginSummary {
        var total_im: shared.types.Quantity = 0;
        var total_mm: shared.types.Quantity = 0;
        var total_notional: shared.types.Quantity = 0;

        var it = sub.positions.iterator();
        while (it.next()) |entry| {
            const pos = entry.value_ptr;
            if (state.markPrice(pos.instrument_id)) |mark_px| {
                const notional = pos.notional(mark_px);
                total_notional += notional;
                total_im += types.initialMargin(pos.size, mark_px, pos.leverage);
                total_mm += maintenanceMarginForPosition(pos, mark_px, self.cfg.default_max_leverage);
            }
        }

        const collateral_registry = types.defaultCollateralRegistry; // TODO: Get from config/state
        const equity: shared.types.SignedAmount = @as(shared.types.SignedAmount, @intCast(sub.collateral.effectiveTotal(&collateral_registry)));
        const available = if (equity > @as(shared.types.SignedAmount, @intCast(total_im)))
            @as(shared.types.Quantity, @intCast(equity - @as(shared.types.SignedAmount, @intCast(total_im))))
        else
            0;

        return .{
            .mode = .standard,
            .total_equity = equity,
            .initial_margin_used = total_im,
            .maintenance_margin = total_mm,
            .available_balance = available,
            .transfer_margin_req = transferMarginRequired(sub, state),
            .margin_ratio = if (total_mm > 0) @as(f64, @floatFromInt(equity)) / @as(f64, @floatFromInt(total_mm)) else 0,
            .health = classifyHealth(equity, total_im, total_mm),
            .collateral_breakdown = buildCollateralBreakdown(sub, &collateral_registry),
        };
    }

    pub fn computeUnified(self: *const MarginEngine, sub: *const account.SubAccount, state: *const GlobalState) types.MarginSummary {
        var total_im: shared.types.Quantity = 0;
        var total_mm: shared.types.Quantity = 0;
        var total_upnl: shared.types.SignedAmount = 0;
        var total_notional: shared.types.Quantity = 0;

        var it = sub.positions.iterator();
        while (it.next()) |entry| {
            const pos = entry.value_ptr;
            if (state.markPrice(pos.instrument_id)) |mark_px| {
                const notional = pos.notional(mark_px);
                total_notional += notional;
                total_im += types.initialMargin(pos.size, mark_px, pos.leverage);
                total_mm += maintenanceMarginForPosition(pos, mark_px, self.cfg.default_max_leverage);
                total_upnl += pos.unrealizedPnl(mark_px);
            }
        }

        const collateral_registry = types.defaultCollateralRegistry; // TODO: Get from config/state
        const collateral = sub.collateral.effectiveTotal(&collateral_registry);
        const equity: shared.types.SignedAmount = @as(shared.types.SignedAmount, @intCast(collateral)) + total_upnl;
        const available = if (equity > @as(shared.types.SignedAmount, @intCast(total_im)))
            @as(shared.types.Quantity, @intCast(equity - @as(shared.types.SignedAmount, @intCast(total_im))))
        else
            0;

        return .{
            .mode = .unified,
            .total_equity = equity,
            .initial_margin_used = total_im,
            .maintenance_margin = total_mm,
            .available_balance = available,
            .transfer_margin_req = transferMarginRequired(sub, state),
            .margin_ratio = if (total_mm > 0) @as(f64, @floatFromInt(equity)) / @as(f64, @floatFromInt(total_mm)) else 0,
            .health = classifyHealth(equity, total_im, total_mm),
            .collateral_breakdown = buildCollateralBreakdown(sub, &collateral_registry),
        };
    }

    pub fn computePortfolio(self: *const MarginEngine, sub: *const account.SubAccount, state: *const GlobalState) types.MarginSummary {
        // Fall back to unified if caps exceeded
        if (!portfolio_mod.PortfolioMargin.portfolioCapsAvailable(sub, 500_000_000 * types.USDC, 100_000_000 * types.USDC)) {
            return self.computeUnified(sub, state);
        }

        const ratio = portfolio_mod.PortfolioMargin.portfolioMarginRatio(sub, state);

        const health = types.classifyPortfolioHealth(ratio);

        var total_im: shared.types.Quantity = 0;
        var total_mm: shared.types.Quantity = 0;
        var total_upnl: shared.types.SignedAmount = 0;
        var total_notional: shared.types.Quantity = 0;

        var it = sub.positions.iterator();
        while (it.next()) |entry| {
            const pos = entry.value_ptr;
            if (state.markPrice(pos.instrument_id)) |mark_px| {
                const notional = pos.notional(mark_px);
                total_notional += notional;
                total_im += types.initialMargin(pos.size, mark_px, pos.leverage);
                total_mm += maintenanceMarginForPosition(pos, mark_px, self.cfg.default_max_leverage);
                total_upnl += pos.unrealizedPnl(mark_px);
            }
        }

        const collateral_registry = types.defaultCollateralRegistry; // TODO: Get from config/state
        const collateral = sub.collateral.effectiveTotal(&collateral_registry);
        const equity: shared.types.SignedAmount = @as(shared.types.SignedAmount, @intCast(collateral)) + total_upnl;
        const available = if (equity > @as(shared.types.SignedAmount, @intCast(total_im)))
            @as(shared.types.Quantity, @intCast(equity - @as(shared.types.SignedAmount, @intCast(total_im))))
        else
            0;

        return .{
            .mode = .portfolio_margin,
            .total_equity = equity,
            .initial_margin_used = total_im,
            .maintenance_margin = total_mm,
            .available_balance = available,
            .transfer_margin_req = transferMarginRequired(sub, state),
            .margin_ratio = ratio,
            .health = health,
            .collateral_breakdown = buildCollateralBreakdown(sub, &collateral_registry),
        };
    }

    pub fn checkInitialMargin(self: *const MarginEngine, sub: *const account.SubAccount, order: shared.types.Order, state: *const GlobalState) !void {
        const summary = self.compute(sub, state);
        const instrument_id = try orderInstrumentId(order);
        const max_leverage = state.instrumentMaxLeverage(instrument_id, self.cfg.default_max_leverage);
        try validateRequestedLeverage(order.leverage, max_leverage);

        const mark_px = state.referencePriceForTrade(instrument_id) orelse if (order.price > 0)
            order.price
        else
            return error.MarkPriceUnavailable;

        const current_pos = sub.positions.get(instrument_id);
        const current_im = if (current_pos) |pos|
            types.initialMargin(pos.size, mark_px, pos.leverage)
        else
            0;
        const projected_im = projectedInitialMargin(order, current_pos, mark_px);

        if (projected_im <= current_im) return;
        if (summary.available_balance < (projected_im - current_im)) {
            return error.InsufficientMargin;
        }
    }

    pub fn checkTransferMargin(
        self: *const MarginEngine,
        sub: *const account.SubAccount,
        asset_id: types.AssetId,
        amount: shared.types.Quantity,
        state: *const GlobalState,
    ) !void {
        _ = self;
        if (amount == 0) return;

        const collateral_registry = types.defaultCollateralRegistry;
        const current_effective = sub.collateral.effectiveTotal(&collateral_registry);
        const remaining_effective = current_effective - @min(current_effective, effectiveCollateralValue(asset_id, amount, &collateral_registry));
        const required = transferMarginRequired(sub, state);

        if (remaining_effective < required) {
            return error.TransferWouldBreachMarginFloor;
        }
    }
};

pub const GlobalState = struct {
    markPriceFn: *const fn (types.InstrumentId) ?shared.types.Price,
    markPriceMetaFn: ?*const fn (types.InstrumentId) ?MarkPriceView = null,
    indexPriceFn: ?*const fn (types.InstrumentId) ?shared.types.Price = null,
    assetOraclePriceFn: ?*const fn (types.AssetId) ?shared.types.Price = null,
    instrumentMaxLeverageFn: ?*const fn (types.InstrumentId) ?u8 = null,
    now_ms: i64 = 0,
    max_mark_price_age_ms: i64 = 15_000,
    max_trade_price_deviation_bps: u32 = 500,
    funding_interest_bps: u32 = 1,
    funding_rate_cap_bps: u32 = 5,
    default_funding_interval_ms: u64 = 3_600_000,

    pub fn markPrice(self: *const GlobalState, instrument_id: types.InstrumentId) ?shared.types.Price {
        if (self.markPriceMetaFn) |resolver| {
            if (resolver(instrument_id)) |view| return view.price;
        }
        return self.markPriceFn(instrument_id);
    }

    pub fn markPriceView(self: *const GlobalState, instrument_id: types.InstrumentId) ?MarkPriceView {
        if (self.markPriceMetaFn) |resolver| {
            return resolver(instrument_id);
        }
        if (self.markPriceFn(instrument_id)) |price| {
            return .{
                .price = price,
                .updated_at_ms = self.now_ms,
            };
        }
        return null;
    }

    pub fn freshMarkPrice(self: *const GlobalState, instrument_id: types.InstrumentId) ?shared.types.Price {
        const view = self.markPriceView(instrument_id) orelse return null;
        if (self.now_ms - view.updated_at_ms > self.max_mark_price_age_ms) return null;
        return view.price;
    }

    pub fn indexPrice(self: *const GlobalState, instrument_id: types.InstrumentId) ?shared.types.Price {
        if (self.indexPriceFn) |resolver| {
            if (resolver(instrument_id)) |price| return price;
        }
        return self.freshMarkPrice(instrument_id) orelse self.markPrice(instrument_id);
    }

    pub fn assetOraclePrice(self: *const GlobalState, asset_id: types.AssetId) ?shared.types.Price {
        if (self.assetOraclePriceFn) |resolver| {
            if (resolver(asset_id)) |price| return price;
        }

        const instrument_id = std.math.cast(types.InstrumentId, asset_id) orelse return null;
        return self.indexPrice(instrument_id);
    }

    pub fn referencePriceForTrade(self: *const GlobalState, instrument_id: types.InstrumentId) ?shared.types.Price {
        return self.freshMarkPrice(instrument_id) orelse self.indexPrice(instrument_id);
    }

    pub fn isWithinTradeBand(self: *const GlobalState, reference_price: shared.types.Price, trade_price: shared.types.Price) bool {
        if (reference_price == 0) return true;
        const lower_delta: shared.types.Price = @as(shared.types.Price, @intCast((@as(u512, reference_price) * self.max_trade_price_deviation_bps) / 10_000));
        const upper = reference_price + lower_delta;
        const lower = if (reference_price > lower_delta) reference_price - lower_delta else 0;
        return trade_price >= lower and trade_price <= upper;
    }

    pub fn instrumentMaxLeverage(self: *const GlobalState, instrument_id: types.InstrumentId, fallback: u8) u8 {
        if (self.instrumentMaxLeverageFn) |resolver| {
            if (resolver(instrument_id)) |max_leverage| return max_leverage;
        }
        return fallback;
    }

    pub fn fundingInterestRate(self: *const GlobalState) f64 {
        return @as(f64, @floatFromInt(self.funding_interest_bps)) / 10_000.0;
    }

    pub fn fundingRateCap(self: *const GlobalState) f64 {
        return @as(f64, @floatFromInt(self.funding_rate_cap_bps)) / 10_000.0;
    }
};

pub const MarkPriceView = struct {
    price: shared.types.Price,
    updated_at_ms: i64,
};

fn transferMarginRequired(sub: *const account.SubAccount, state: *const GlobalState) shared.types.Quantity {
    var total_notional: shared.types.Quantity = 0;
    var total_im: shared.types.Quantity = 0;

    var it = sub.positions.iterator();
    while (it.next()) |entry| {
        const pos = entry.value_ptr;
        if (state.markPrice(pos.instrument_id)) |mark_px| {
            const notional = pos.notional(mark_px);
            total_notional += notional;
            total_im += types.initialMargin(pos.size, mark_px, pos.leverage);
        }
    }

    return @max(total_im, total_notional / 10);
}

fn buildCollateralBreakdown(sub: *const account.SubAccount, registry: types.CollateralRegistry) types.CollateralBreakdown {
    var breakdown = types.CollateralBreakdown.init();

    for (registry) |entry| {
        const raw_amount = sub.collateral.rawBalance(entry.asset_id);
        if (raw_amount == 0) continue;

        breakdown.append(.{
            .asset_id = entry.asset_id,
            .raw_amount = raw_amount,
            .effective_usdc = effectiveCollateralValue(entry.asset_id, raw_amount, registry),
        }) catch unreachable;
    }

    return breakdown;
}

fn effectiveCollateralValue(asset_id: types.AssetId, amount: shared.types.Quantity, registry: types.CollateralRegistry) shared.types.Quantity {
    for (registry) |entry| {
        if (entry.asset_id == asset_id) {
            return @intFromFloat(@as(f64, @floatFromInt(amount)) * (1.0 - entry.haircut_pct));
        }
    }
    return 0;
}

fn orderInstrumentId(order: shared.types.Order) !types.InstrumentId {
    return std.math.cast(types.InstrumentId, order.asset_id) orelse error.InvalidInstrumentId;
}

fn validateRequestedLeverage(leverage: u8, max_leverage: u8) !void {
    if (leverage == 0 or leverage > max_leverage) return error.InvalidLeverage;
}

fn maintenanceMarginForPosition(pos: *const types.Position, mark_px: shared.types.Price, fallback_max_leverage: u8) shared.types.Quantity {
    const notional = pos.notional(mark_px);
    const mm_rate = types.maintenanceMarginRate(types.instrumentMaxLeverage(pos.kind, fallback_max_leverage));
    return @intFromFloat(@as(f64, @floatFromInt(notional)) * mm_rate);
}

fn projectedInitialMargin(order: shared.types.Order, current_pos: ?types.Position, mark_px: shared.types.Price) shared.types.Quantity {
    const order_side: shared.types.Side = if (order.is_buy) .long else .short;

    if (current_pos) |pos| {
        if (pos.side == order_side) {
            return types.initialMargin(pos.size + order.size, mark_px, order.leverage);
        }
        if (order.size < pos.size) {
            return types.initialMargin(pos.size - order.size, mark_px, pos.leverage);
        }
        if (order.size == pos.size) {
            return 0;
        }
        return types.initialMargin(order.size - pos.size, mark_px, order.leverage);
    }

    return types.initialMargin(order.size, mark_px, order.leverage);
}

fn classifyHealth(equity: shared.types.SignedAmount, im: shared.types.Quantity, mm: shared.types.Quantity) types.AccountHealth {
    if (equity < @as(shared.types.SignedAmount, @intCast(mm))) return .liquidatable;
    if (equity < @as(shared.types.SignedAmount, @intCast(im))) return .warning;
    return .healthy;
}

const test_btc_mark = shared.fixed_point.priceFromWhole(100_000 * types.USDC);

fn testBtcMark(_: types.InstrumentId) ?shared.types.Price {
    return test_btc_mark;
}

test "initial margin formula - notional / leverage" {
    try std.testing.expectEqual(10_000 * types.USDC, types.initialMargin(1, test_btc_mark, 10));
}

test "maintenance margin rate - half of im rate at max leverage" {
    try std.testing.expectApproxEqAbs(0.01, types.maintenanceMarginRate(50), 1e-9);
}

test "cross - unrealized pnl immediately usable for new positions" {
    const alloc = std.testing.allocator;
    const master_addr = [_]u8{0xAA} ** 20;
    var master = account.MasterAccount.init(alloc, master_addr, 0);
    defer master.deinit();

    const sub = try master.openSubAccount(0, null, 0);
    try sub.collateral.deposit(types.USDC_ID, 10_000 * types.USDC, &types.defaultCollateralRegistry);

    const state = GlobalState{
        .markPriceFn = struct {
            fn mark(_: types.InstrumentId) ?shared.types.Price {
                return test_btc_mark;
            }
        }.mark,
    };

    var engine = MarginEngine.init(.{});
    const summary = engine.computeUnified(sub, &state);
    try std.testing.expect(summary.total_equity > 0);
    try std.testing.expectEqual(types.AccountHealth.healthy, summary.health);
    try std.testing.expectEqual(@as(usize, 1), summary.collateral_breakdown.slice().len);
    try std.testing.expectEqual(types.USDC_ID, summary.collateral_breakdown.slice()[0].asset_id);
    try std.testing.expectEqual(10_000 * types.USDC, summary.collateral_breakdown.slice()[0].effective_usdc);
}

test "transfer margin req - max(im, 10% notional)" {
    const alloc = std.testing.allocator;
    const master_addr = [_]u8{0xAA} ** 20;
    var master = account.MasterAccount.init(alloc, master_addr, 0);
    defer master.deinit();

    const sub = try master.openSubAccount(0, null, 0);
    try sub.collateral.deposit(types.USDC_ID, 25_000 * types.USDC, &types.defaultCollateralRegistry);

    try sub.positions.put(1, .{
        .instrument_id = 1,
        .kind = .{ .perp = .{
            .tick_size = 1,
            .lot_size = 1,
            .max_leverage = 50,
            .funding_interval_ms = 3_600_000,
            .mark_method = .oracle,
            .isolated_only = false,
        } },
        .user = sub.address,
        .size = 1,
        .side = .long,
        .entry_price = test_btc_mark,
        .realized_pnl = 0,
        .leverage = 5,
        .margin_mode = .cross,
        .isolated_margin = 0,
        .funding_index = 0,
        .delta = 0,
        .gamma = 0,
        .vega = 0,
        .theta = 0,
    });

    const state = GlobalState{
        .markPriceFn = testBtcMark,
    };

    const engine = MarginEngine.init(.{});
    const req = transferMarginRequired(sub, &state);
    _ = engine;
    try std.testing.expectEqual(20_000 * types.USDC, req);
}

test "check initial margin uses requested leverage" {
    const alloc = std.testing.allocator;
    const master_addr = [_]u8{0xAA} ** 20;
    var master = account.MasterAccount.init(alloc, master_addr, 0);
    defer master.deinit();

    const sub = try master.openSubAccount(0, null, 0);
    try sub.collateral.deposit(types.USDC_ID, 6_000 * types.USDC, &types.defaultCollateralRegistry);

    const state = GlobalState{
        .markPriceFn = testBtcMark,
    };

    const engine = MarginEngine.init(.{});
    try engine.checkInitialMargin(sub, .{
        .id = 1,
        .user = sub.address,
        .asset_id = 1,
        .is_buy = true,
        .price = test_btc_mark,
        .size = 1,
        .leverage = 20,
        .order_type = .{ .limit = .gtc },
        .cloid = null,
        .nonce = 1,
    }, &state);

    try std.testing.expectError(error.InsufficientMargin, engine.checkInitialMargin(sub, .{
        .id = 2,
        .user = sub.address,
        .asset_id = 1,
        .is_buy = true,
        .price = test_btc_mark,
        .size = 1,
        .leverage = 5,
        .order_type = .{ .limit = .gtc },
        .cloid = null,
        .nonce = 2,
    }, &state));
}

test "check initial margin rejects leverage above instrument max" {
    const alloc = std.testing.allocator;
    const master_addr = [_]u8{0xAA} ** 20;
    var master = account.MasterAccount.init(alloc, master_addr, 0);
    defer master.deinit();

    const sub = try master.openSubAccount(0, null, 0);
    try sub.collateral.deposit(types.USDC_ID, 100_000 * types.USDC, &types.defaultCollateralRegistry);

    const state = GlobalState{
        .markPriceFn = testBtcMark,
        .instrumentMaxLeverageFn = struct {
            fn maxLeverage(_: types.InstrumentId) ?u8 {
                return 25;
            }
        }.maxLeverage,
    };

    const engine = MarginEngine.init(.{});
    try std.testing.expectError(error.InvalidLeverage, engine.checkInitialMargin(sub, .{
        .id = 1,
        .user = sub.address,
        .asset_id = 1,
        .is_buy = true,
        .price = test_btc_mark,
        .size = 1,
        .leverage = 26,
        .order_type = .{ .limit = .gtc },
        .cloid = null,
        .nonce = 1,
    }, &state));
}

test "maintenance margin uses instrument max leverage" {
    const alloc = std.testing.allocator;
    const master_addr = [_]u8{0xAA} ** 20;
    var master = account.MasterAccount.init(alloc, master_addr, 0);
    defer master.deinit();

    const sub = try master.openSubAccount(0, null, 0);
    try sub.collateral.deposit(types.USDC_ID, 20_000 * types.USDC, &types.defaultCollateralRegistry);
    try sub.positions.put(1, .{
        .instrument_id = 1,
        .kind = .{ .perp = .{
            .tick_size = 1,
            .lot_size = 1,
            .max_leverage = 10,
            .funding_interval_ms = 3_600_000,
            .mark_method = .oracle,
            .isolated_only = false,
        } },
        .user = sub.address,
        .size = 1,
        .side = .long,
        .entry_price = test_btc_mark,
        .realized_pnl = 0,
        .leverage = 10,
        .margin_mode = .cross,
        .isolated_margin = 0,
        .funding_index = 0,
        .delta = 0,
        .gamma = 0,
        .vega = 0,
        .theta = 0,
    });

    const state = GlobalState{
        .markPriceFn = testBtcMark,
    };

    const engine = MarginEngine.init(.{});
    const summary = engine.computeUnified(sub, &state);
    try std.testing.expectEqual(5_000 * types.USDC, summary.maintenance_margin);
}

test "transfer exceeds floor - rejected" {
    const alloc = std.testing.allocator;
    const master_addr = [_]u8{0xAA} ** 20;
    var master = account.MasterAccount.init(alloc, master_addr, 0);
    defer master.deinit();

    const sub = try master.openSubAccount(0, null, 0);
    try sub.collateral.deposit(types.USDC_ID, 25_000 * types.USDC, &types.defaultCollateralRegistry);

    try sub.positions.put(1, .{
        .instrument_id = 1,
        .kind = .{ .perp = .{
            .tick_size = 1,
            .lot_size = 1,
            .max_leverage = 50,
            .funding_interval_ms = 3_600_000,
            .mark_method = .oracle,
            .isolated_only = false,
        } },
        .user = sub.address,
        .size = 1,
        .side = .long,
        .entry_price = test_btc_mark,
        .realized_pnl = 0,
        .leverage = 5,
        .margin_mode = .cross,
        .isolated_margin = 0,
        .funding_index = 0,
        .delta = 0,
        .gamma = 0,
        .vega = 0,
        .theta = 0,
    });

    const state = GlobalState{
        .markPriceFn = testBtcMark,
    };

    var engine = MarginEngine.init(.{});
    try std.testing.expectError(
        error.TransferWouldBreachMarginFloor,
        engine.checkTransferMargin(sub, types.USDC_ID, 10_000 * types.USDC, &state),
    );
}

test "portfolio margin ratio changes with oracle price" {
    const alloc = std.testing.allocator;
    const master_addr = [_]u8{0xAA} ** 20;
    var master = account.MasterAccount.init(alloc, master_addr, 0);
    defer master.deinit();

    const sub = try master.openSubAccount(0, null, 0);
    sub.master_mode = .portfolio_margin;
    try sub.collateral.deposit(types.USDC_ID, 1_000_000 * types.USDC, &types.defaultCollateralRegistry);

    const low_oracle_state = GlobalState{
        .markPriceFn = struct {
            fn mark(_: types.InstrumentId) ?shared.types.Price {
                return null;
            }
        }.mark,
        .assetOraclePriceFn = struct {
            fn oracle(asset_id: types.AssetId) ?shared.types.Price {
                return switch (asset_id) {
                    types.USDC_ID => 1,
                    else => null,
                };
            }
        }.oracle,
    };

    const high_oracle_state = GlobalState{
        .markPriceFn = low_oracle_state.markPriceFn,
        .assetOraclePriceFn = struct {
            fn oracle(asset_id: types.AssetId) ?shared.types.Price {
                return switch (asset_id) {
                    types.USDC_ID => 100_000,
                    else => null,
                };
            }
        }.oracle,
    };

    var engine = MarginEngine.init(.{});
    const low_ratio = engine.computePortfolio(sub, &low_oracle_state).margin_ratio;
    const high_ratio = engine.computePortfolio(sub, &high_oracle_state).margin_ratio;

    try std.testing.expect(low_ratio > 0);
    try std.testing.expect(low_ratio > high_ratio);
}

test "all margin modes expose collateral breakdown" {
    const alloc = std.testing.allocator;
    const master_addr = [_]u8{0xAB} ** 20;
    var master = account.MasterAccount.init(alloc, master_addr, 0);
    defer master.deinit();

    const sub = try master.openSubAccount(0, null, 0);
    try sub.collateral.deposit(types.USDC_ID, 1_000 * types.USDC, &types.defaultCollateralRegistry);
    try sub.collateral.deposit(types.BTC_ID, 1 * types.BTC, &types.defaultCollateralRegistry);

    const state = GlobalState{
        .markPriceFn = struct {
            fn mark(_: types.InstrumentId) ?shared.types.Price {
                return null;
            }
        }.mark,
        .assetOraclePriceFn = struct {
            fn oracle(asset_id: types.AssetId) ?shared.types.Price {
                return switch (asset_id) {
                    types.USDC_ID => 1,
                    types.BTC_ID => 50_000,
                    else => null,
                };
            }
        }.oracle,
    };

    var engine = MarginEngine.init(.{});

    const standard = engine.computeStandard(sub, &state);
    try std.testing.expectEqual(@as(usize, 2), standard.collateral_breakdown.slice().len);
    try std.testing.expectEqual(types.USDC_ID, standard.collateral_breakdown.slice()[0].asset_id);
    try std.testing.expectEqual(types.BTC_ID, standard.collateral_breakdown.slice()[1].asset_id);

    const unified = engine.computeUnified(sub, &state);
    try std.testing.expectEqual(@as(usize, 2), unified.collateral_breakdown.slice().len);
    try std.testing.expectEqual(90000000, unified.collateral_breakdown.slice()[1].effective_usdc);

    sub.master_mode = .portfolio_margin;
    const portfolio = engine.computePortfolio(sub, &state);
    try std.testing.expectEqual(@as(usize, 2), portfolio.collateral_breakdown.slice().len);
    try std.testing.expectEqual(types.BTC_ID, portfolio.collateral_breakdown.slice()[1].asset_id);
}

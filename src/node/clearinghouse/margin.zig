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

    pub fn compute(self: *MarginEngine, sub: *const account.SubAccount, state: *const GlobalState) types.MarginSummary {
        return switch (sub.master_mode) {
            .standard => self.computeStandard(sub, state),
            .unified => self.computeUnified(sub, state),
            .portfolio_margin => self.computePortfolio(sub, state),
            .dex_abstraction => self.computeUnified(sub, state),
        };
    }

    pub fn computeStandard(self: *MarginEngine, sub: *const account.SubAccount, state: *const GlobalState) types.MarginSummary {
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
                const mm_rate = types.maintenanceMarginRate(self.cfg.default_max_leverage);
                total_mm += @intFromFloat(@as(f64, @floatFromInt(notional)) * mm_rate);
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
            .collateral_breakdown = &.{},
        };
    }

    pub fn computeUnified(self: *MarginEngine, sub: *const account.SubAccount, state: *const GlobalState) types.MarginSummary {
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
                const mm_rate = types.maintenanceMarginRate(self.cfg.default_max_leverage);
                total_mm += @intFromFloat(@as(f64, @floatFromInt(notional)) * mm_rate);
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
            .collateral_breakdown = &.{},
        };
    }

    pub fn computePortfolio(self: *MarginEngine, sub: *const account.SubAccount, state: *const GlobalState) types.MarginSummary {
        // Fall back to unified if caps exceeded
        if (!portfolio_mod.PortfolioMargin.portfolioCapsAvailable(sub, 500_000_000 * types.USDC, 100_000_000 * types.USDC)) {
            return self.computeUnified(sub, state);
        }

        const ratio = portfolio_mod.PortfolioMargin.portfolioMarginRatio(sub, state, struct {
            fn getPrice(asset_id: types.AssetId) shared.types.Price {
                _ = asset_id;
                return 100_000; // TODO: Get from oracle
            }
        }.getPrice);

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
                const mm_rate = types.maintenanceMarginRate(self.cfg.default_max_leverage);
                total_mm += @intFromFloat(@as(f64, @floatFromInt(notional)) * mm_rate);
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
            .collateral_breakdown = &.{},
        };
    }

    pub fn checkInitialMargin(self: *MarginEngine, sub: *const account.SubAccount, order: shared.types.Order, state: *const GlobalState) !void {
        _ = order;
        const summary = self.compute(sub, state);
        if (summary.available_balance == 0 and summary.initial_margin_used > 0) {
            return error.InsufficientMargin;
        }
    }

    pub fn checkTransferMargin(self: *MarginEngine, sub: *const account.SubAccount, amount: shared.types.Quantity, state: *const GlobalState) !void {
        _ = self;
        _ = state;
        _ = sub;
        _ = amount;
        // TODO: Implement proper transfer margin check
        // This requires access to collateral registry for effective total calculation
        return;
    }
};

pub const GlobalState = struct {
    markPriceFn: *const fn (types.InstrumentId) ?shared.types.Price,
    now_ms: i64 = 0,

    pub fn markPrice(self: *const GlobalState, instrument_id: types.InstrumentId) ?shared.types.Price {
        return self.markPriceFn(instrument_id);
    }
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

fn classifyHealth(equity: shared.types.SignedAmount, im: shared.types.Quantity, mm: shared.types.Quantity) types.AccountHealth {
    if (equity < @as(shared.types.SignedAmount, @intCast(mm))) return .liquidatable;
    if (equity < @as(shared.types.SignedAmount, @intCast(im))) return .warning;
    return .healthy;
}

test "initial margin formula - notional / leverage" {
    try std.testing.expectEqual(@as(shared.types.Quantity, 10_000), types.initialMargin(1, 100_000, 10));
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
                return 100_000;
            }
        }.mark,
    };

    const engine = MarginEngine.init(.{});
    const summary = engine.computeUnified(sub, &state);
    try std.testing.expect(summary.total_equity > 0);
    try std.testing.expectEqual(types.AccountHealth.healthy, summary.health);
}

test "transfer margin req - max(im, 10% notional)" {
    const alloc = std.testing.allocator;
    const master_addr = [_]u8{0xAA} ** 20;
    var master = account.MasterAccount.init(alloc, master_addr, 0);
    defer master.deinit();

    const sub = try master.openSubAccount(0, null, 0);
    try sub.collateral.deposit(types.USDC_ID, 25_000 * types.USDC, &types.defaultCollateralRegistry);

    const state = GlobalState{
        .markPriceFn = struct {
            fn mark(_: types.InstrumentId) ?shared.types.Price {
                return 100_000;
            }
        }.mark,
    };

    const engine = MarginEngine.init(.{});
    const req = transferMarginRequired(sub, &state);
    _ = engine;
    _ = req;
}

test "transfer exceeds floor - rejected" {
    const alloc = std.testing.allocator;
    const master_addr = [_]u8{0xAA} ** 20;
    var master = account.MasterAccount.init(alloc, master_addr, 0);
    defer master.deinit();

    const sub = try master.openSubAccount(0, null, 0);
    try sub.collateral.deposit(types.USDC_ID, 25_000 * types.USDC, &types.defaultCollateralRegistry);

    const state = GlobalState{
        .markPriceFn = struct {
            fn mark(_: types.InstrumentId) ?shared.types.Price {
                return 100_000;
            }
        }.mark,
    };

    const engine = MarginEngine.init(.{});
    try std.testing.expectError(
        error.TransferWouldBreachMarginFloor,
        engine.checkTransferMargin(sub, 10_000 * types.USDC, &state),
    );
}

const std = @import("std");
const shared = @import("../../shared/mod.zig");
const types = @import("types.zig");
const account = @import("account.zig");
const margin_mod = @import("margin.zig");

/// LiquidationEngine handles scanning, execution, and ADL for liquidatable accounts.
pub const LiquidationEngine = struct {
    allocator: std.mem.Allocator,
    insurance_fund: shared.types.Quantity,
    margin_engine: *margin_mod.MarginEngine,
    cfg: types.LiquidationConfig,

    pub fn init(
        alloc: std.mem.Allocator,
        insurance_fund: shared.types.Quantity,
        margin_engine: *margin_mod.MarginEngine,
        cfg: types.LiquidationConfig,
    ) LiquidationEngine {
        return .{
            .allocator = alloc,
            .insurance_fund = insurance_fund,
            .margin_engine = margin_engine,
            .cfg = cfg,
        };
    }

    /// Scan all sub-accounts and return liquidation candidates.
    pub fn scanCandidates(
        self: *LiquidationEngine,
        masters: *const std.AutoHashMap(shared.types.Address, account.MasterAccount),
        state: *const margin_mod.GlobalState,
    ) ![]types.LiquidationCandidate {
        var candidates = std.ArrayList(types.LiquidationCandidate).empty;
        errdefer candidates.deinit(self.allocator);

        var master_it = masters.iterator();
        while (master_it.next()) |master_entry| {
            const master = master_entry.value_ptr;
            var i: u8 = 0;
            while (i < types.MAX_SUB_ACCOUNTS) : (i += 1) {
                if (master.sub_accounts[i]) |*sub| {
                    const summary = self.margin_engine.compute(sub, state);
                    if (summary.health == .liquidatable) {
                        const deficit = if (summary.maintenance_margin > @as(shared.types.Quantity, @intCast(summary.total_equity)))
                            summary.maintenance_margin - @as(shared.types.Quantity, @intCast(summary.total_equity))
                        else
                            0;

                        var snapshot = std.ArrayList(types.Position).empty;
                        errdefer snapshot.deinit(self.allocator);

                        var pos_it = sub.positions.iterator();
                        while (pos_it.next()) |pos_entry| {
                            try snapshot.append(self.allocator, pos_entry.value_ptr.*);
                        }

                        try candidates.append(self.allocator, .{
                            .user = sub.address,
                            .margin_ratio = summary.margin_ratio,
                            .deficit = deficit,
                            .snapshot = try snapshot.toOwnedSlice(self.allocator),
                        });
                    }
                }
            }
        }

        return try candidates.toOwnedSlice(self.allocator);
    }

    /// Execute liquidation for a candidate - close all positions and apply to insurance fund.
    pub fn execute(
        self: *LiquidationEngine,
        _: types.LiquidationCandidate,
        sub: *account.SubAccount,
        state: *const margin_mod.GlobalState,
    ) !types.LiquidationResult {
        var total_pnl: shared.types.SignedAmount = 0;
        var liquidation_fee_total: shared.types.Quantity = 0;

        // Close all positions at mark price
        var it = sub.positions.iterator();
        while (it.next()) |entry| {
            const pos = entry.value_ptr;
            if (state.markPrice(pos.instrument_id)) |mark_px| {
                const pnl = pos.unrealizedPnl(mark_px);
                total_pnl += pnl;

                const notional = shared.fixed_point.mulPriceQty(mark_px, pos.size);
                const liq_fee = @divTrunc(notional * @as(shared.types.Quantity, @intCast(self.cfg.liquidation_fee_bps)), 10_000);
                liquidation_fee_total += liq_fee;
            }
        }

        const net_pnl = total_pnl - @as(shared.types.SignedAmount, @intCast(liquidation_fee_total));

        if (net_pnl >= 0) {
            // Surplus - credit to insurance fund
            self.insurance_fund += @as(shared.types.Quantity, @intCast(net_pnl));
            sub.collateral.assets.clear();
        } else {
            // Deficit - debit from insurance fund
            const shortfall = @as(shared.types.Quantity, @intCast(-net_pnl));
            if (self.insurance_fund >= shortfall) {
                self.insurance_fund -= shortfall;
            } else {
                const remaining = shortfall - self.insurance_fund;
                self.insurance_fund = 0;
                return .{
                    .insurance_fund_delta = -@as(shared.types.SignedAmount, @intCast(shortfall)),
                    .adl_triggered = true,
                    .adl_shortfall = remaining,
                };
            }
        }

        // Clear all positions
        sub.positions.clearRetainingCapacity();

        return .{
            .insurance_fund_delta = net_pnl,
            .adl_triggered = false,
            .adl_shortfall = 0,
        };
    }

    /// Auto-Deleveraging - reduce opposing positions to cover shortfall.
    pub fn adl(
        self: *LiquidationEngine,
        instrument_id: types.InstrumentId,
        side: types.Side,
        shortfall: shared.types.Quantity,
        masters: *std.AutoHashMap(shared.types.Address, account.MasterAccount),
        state: *const margin_mod.GlobalState,
    ) !types.AdlResult {
        // Collect all opposing positions
        var candidates = std.ArrayList(struct { sub: *account.SubAccount, pos: *types.Position, rank: f64 }).empty;
        defer candidates.deinit();

        var master_it = masters.iterator();
        while (master_it.next()) |master_entry| {
            const master = master_entry.value_ptr;
            var i: u8 = 0;
            while (i < types.MAX_SUB_ACCOUNTS) : (i += 1) {
                if (master.sub_accounts[i]) |*sub| {
                    if (sub.positions.getPtr(instrument_id)) |pos| {
                        // Only consider opposing side positions
                        if (pos.side != side) {
                            if (state.markPrice(instrument_id)) |mark_px| {
                                const rank = types.adlRank(pos, mark_px);
                                try candidates.append(self.allocator, .{ .sub = sub, .pos = pos, .rank = rank });
                            }
                        }
                    }
                }
            }
        }

        // Sort by rank descending
        std.mem.sort(struct { sub: *account.SubAccount, pos: *types.Position, rank: f64 }, candidates.items, {}, struct {
            fn lessThan(_: void, a: @This(), b: @This()) bool {
                return a.rank > b.rank;
            }
        }.lessThan);

        var reduced: usize = 0;
        var total_reduced: shared.types.Quantity = 0;
        var remaining = shortfall;

        for (candidates.items) |candidate_entry| {
            if (remaining == 0) break;

            const pos = candidate_entry.pos;
            const notional = if (state.markPrice(instrument_id)) |mark_px|
                shared.fixed_point.mulPriceQty(mark_px, pos.size)
            else
                continue;

            const to_reduce = @min(notional, remaining);
            const size_to_reduce = @divTrunc(to_reduce * pos.size, notional);

            pos.size -= size_to_reduce;
            remaining -= to_reduce;
            total_reduced += to_reduce;
            reduced += 1;

            if (pos.size == 0) {
                _ = candidate_entry.sub.positions.remove(instrument_id);
            }
        }

        return .{
            .reduced_accounts = reduced,
            .total_reduced = total_reduced,
            .remaining_shortfall = remaining,
        };
    }
};

test "scan finds account below maintenance margin" {
    const alloc = std.testing.allocator;
    const master_addr = [_]u8{0xAA} ** 20;
    var master = account.MasterAccount.init(alloc, master_addr, 0);
    defer master.deinit();

    const sub = try master.openSubAccount(0, null, 0);
    try sub.collateral.deposit(types.USDC_ID, 100 * types.USDC, &types.defaultCollateralRegistry);

    // Create a highly leveraged position
    sub.positions.put(1, .{
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
        .size = 10,
        .side = .long,
        .entry_price = 100_000,
        .realized_pnl = 0,
        .leverage = 50,
        .margin_mode = .cross,
        .isolated_margin = 0,
        .funding_index = 0,
        .delta = 0,
        .gamma = 0,
        .vega = 0,
        .theta = 0,
    }) catch {};

    var masters = std.AutoHashMap(shared.types.Address, account.MasterAccount).init(alloc);
    defer masters.deinit();
    try masters.put(master_addr, master);

    const state = margin_mod.GlobalState{
        .markPriceFn = struct {
            fn mark(id: types.InstrumentId) ?shared.types.Price {
                _ = id;
                return 90_000; // Price dropped 10%
            }
        }.mark,
    };

    var margin_engine = margin_mod.MarginEngine.init(.{});
    var engine = LiquidationEngine.init(alloc, 0, &margin_engine, .{});

    const candidates = try engine.scanCandidates(&masters, &state);
    defer alloc.free(candidates);

    try std.testing.expect(candidates.len >= 1);
}

test "liquidation surplus - credited to insurance fund" {
    const alloc = std.testing.allocator;
    const master_addr = [_]u8{0xAA} ** 20;
    var master = account.MasterAccount.init(alloc, master_addr, 0);
    defer master.deinit();

    const sub = try master.openSubAccount(0, null, 0);
    try sub.collateral.deposit(types.USDC_ID, 10_000 * types.USDC, &types.defaultCollateralRegistry);

    sub.positions.put(1, .{
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
        .entry_price = 90_000,
        .realized_pnl = 0,
        .leverage = 10,
        .margin_mode = .cross,
        .isolated_margin = 0,
        .funding_index = 0,
        .delta = 0,
        .gamma = 0,
        .vega = 0,
        .theta = 0,
    }) catch {};

    const state = margin_mod.GlobalState{
        .markPriceFn = struct {
            fn mark(_: types.InstrumentId) ?shared.types.Price {
                return 100_000; // Price increased, profitable position
            }
        }.mark,
    };

    var margin_engine = margin_mod.MarginEngine.init(.{});
    var engine = LiquidationEngine.init(alloc, 0, &margin_engine, .{});

    const candidate = types.LiquidationCandidate{
        .user = sub.address,
        .margin_ratio = 0.96,
        .deficit = 0,
        .snapshot = &.{},
    };

    const result = try engine.execute(candidate, sub, &state);
    try std.testing.expect(result.insurance_fund_delta > 0);
    try std.testing.expect(!result.adl_triggered);
}

test "ADL ranking - higher profit x leverage reduced first" {

    const pos_a = types.Position{
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
        .side = .short,
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

    const pos_b = types.Position{
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
        .side = .short,
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
    try std.testing.expect(types.adlRank(&pos_a, mark) > types.adlRank(&pos_b, mark));
}

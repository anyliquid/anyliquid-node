const std = @import("std");
const shared = @import("../../shared/mod.zig");
const types = @import("types.zig");
const account = @import("account.zig");

/// OptionsClearingUnit handles options fill settlement, Greeks caching, and expiry settlement.
pub const OptionsClearingUnit = struct {
    allocator: std.mem.Allocator,
    fee_config: types.FeeConfig,

    pub fn init(alloc: std.mem.Allocator, cfg: types.FeeConfig) OptionsClearingUnit {
        return .{
            .allocator = alloc,
            .fee_config = cfg,
        };
    }

    pub fn deinit(self: *OptionsClearingUnit) void {
        _ = self;
        // Nothing to clean up currently
    }

    /// Settle an options fill - creates long/short positions.
    pub fn settle(
        self: *OptionsClearingUnit,
        fill: types.Fill,
        taker_sub: *account.SubAccount,
        maker_sub: *account.SubAccount,
    ) !types.FillSettledEvent {
        const quote_amount = shared.fixed_point.mulPriceQty(fill.price, fill.size);
        const taker_fee = spot_mod.calcFee(quote_amount, self.fee_config.taker_fee_bps);
        const maker_fee = spot_mod.calcFee(quote_amount, self.fee_config.maker_fee_bps);

        try self.applyOptionFill(fill, taker_sub, true, quote_amount, taker_fee);
        try self.applyOptionFill(fill, maker_sub, false, quote_amount, maker_fee);

        return .{
            .fill = fill,
            .taker_fee = taker_fee,
            .maker_fee = maker_fee,
        };
    }

    fn applyOptionFill(
        self: *OptionsClearingUnit,
        fill: types.Fill,
        sub: *account.SubAccount,
        is_taker: bool,
        quote_amount: shared.types.Quantity,
        fee: shared.types.Quantity,
    ) !void {
        _ = self;
        const user_addr = if (is_taker) fill.taker else fill.maker;
        const is_long = fill.taker_is_buy == is_taker;

        const gop = try sub.positions.getOrPut(fill.instrument_id);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{
                .instrument_id = fill.instrument_id,
                .kind = fill.instrument_kind,
                .user = user_addr,
                .size = fill.size,
                .side = if (is_long) .long else .short,
                .entry_price = fill.price,
                .realized_pnl = 0,
                .leverage = 1,
                .margin_mode = .isolated,
                .isolated_margin = quote_amount + fee,
                .funding_index = 0,
                .delta = 0,
                .gamma = 0,
                .vega = 0,
                .theta = 0,
            };
        } else {
            var pos = gop.value_ptr;
            const incoming_side: shared.types.Side = if (fill.taker_is_buy == is_taker) .long else .short;

            if (pos.side == incoming_side) {
                // Increase position - VWAP entry price
                const total_size = pos.size + fill.size;
                const old_notional = shared.fixed_point.mulPriceQty(pos.entry_price, pos.size);
                const new_notional = shared.fixed_point.mulPriceQty(fill.price, fill.size);
                pos.entry_price = @divTrunc(old_notional + new_notional, total_size);
                pos.size = total_size;
                pos.isolated_margin += quote_amount + fee;
            } else {
                // Opposite side - close or flip
                if (fill.size < pos.size) {
                    // Partial close
                    const pnl = calcOptionPnl(pos, fill.size, fill.price);
                    pos.realized_pnl += pnl;
                    pos.size -= fill.size;
                    const margin_to_release = @divTrunc(pos.isolated_margin * fill.size, pos.size + fill.size);
                    pos.isolated_margin -= margin_to_release;
                } else if (fill.size == pos.size) {
                    // Full close
                    const pnl = calcOptionPnl(pos, fill.size, fill.price);
                    pos.realized_pnl += pnl;
                    pos.size = 0;
                    pos.isolated_margin = 0;
                } else {
                    // Flip: close existing, open new in opposite direction
                    const pnl = calcOptionPnl(pos, pos.size, fill.price);
                    pos.realized_pnl += pnl;
                    pos.size = fill.size - pos.size;
                    pos.side = incoming_side;
                    pos.entry_price = fill.price;
                    pos.isolated_margin = quote_amount + fee;
                }
            }
        }
    }

    /// Refresh Greeks for all option positions based on current oracle prices.
    pub fn refreshGreeks(
        self: *OptionsClearingUnit,
        state: *const GlobalState,
        sub: *account.SubAccount,
    ) void {
        _ = self;
        var it = sub.positions.iterator();
        while (it.next()) |entry| {
            const pos = entry.value_ptr;
            if (pos.kind != .option) continue;

            const spec = pos.kind.option;
            if (state.getOraclePrice(pos.instrument_id)) |spot_price| {
                const time_to_expiry = @max(0.0, @as(f64, @floatFromInt(spec.expiry_ms - state.now_ms)) / 1000.0);
                const greeks = types.calcGreeks(
                    @as(f64, @floatFromInt(spot_price)),
                    @as(f64, @floatFromInt(spec.strike)),
                    0.05, // risk-free rate
                    0.3,  // implied volatility (30%)
                    time_to_expiry / (365.0 * 24.0 * 3600.0), // convert to years
                    spec.option_type,
                );

                entry.value_ptr.delta = greeks.delta;
                entry.value_ptr.gamma = greeks.gamma;
                entry.value_ptr.vega = greeks.vega;
                entry.value_ptr.theta = greeks.theta;
            }
        }
    }

    /// Settle all expired options - computes intrinsic value and pays out.
    pub fn settleExpired(
        self: *OptionsClearingUnit,
        state: *const GlobalState,
        sub: *account.SubAccount,
        now_ms: i64,
    ) ![]types.OptionExpiredEvent {
        var events = std.ArrayList(types.OptionExpiredEvent).empty;
        errdefer events.deinit(self.allocator);

        var to_remove = std.ArrayList(types.InstrumentId).empty;
        defer to_remove.deinit(self.allocator);

        var it = sub.positions.iterator();
        while (it.next()) |entry| {
            const pos = entry.value_ptr;
            if (!pos.isExpired(now_ms)) continue;
            if (pos.kind != .option) continue;

            const spec = pos.kind.option;
            const settlement_price = state.getOraclePrice(pos.instrument_id) orelse continue;

            const intrinsic = switch (spec.option_type) {
                .call => if (settlement_price > spec.strike) settlement_price - spec.strike else 0,
                .put => if (spec.strike > settlement_price) spec.strike - settlement_price else 0,
            };

            const payout = shared.fixed_point.mulPriceQty(intrinsic, pos.size);

            if (pos.side == .long) {
                // Long receives payout
                sub.collateral.credit(types.USDC_ID, payout);
            } else {
                // Short pays payout
                try sub.collateral.withdraw(types.USDC_ID, payout);
            }

            try events.append(self.allocator, .{
                .instrument_id = pos.instrument_id,
                .intrinsic_value = intrinsic,
                .payout = payout,
                .timestamp = now_ms,
            });

            try to_remove.append(self.allocator, pos.instrument_id);
        }

        // Remove settled positions
        for (to_remove.items) |inst_id| {
            _ = sub.positions.remove(inst_id);
        }

        return try events.toOwnedSlice(self.allocator);
    }
};

const spot_mod = @import("spot.zig");

fn calcOptionPnl(pos: *const types.Position, close_size: shared.types.Quantity, close_price: shared.types.Price) shared.types.SignedAmount {
    const diff: i256 = if (pos.side == .long)
        @as(i256, @intCast(close_price)) - @as(i256, @intCast(pos.entry_price))
    else
        @as(i256, @intCast(pos.entry_price)) - @as(i256, @intCast(close_price));
    return @intCast(@divTrunc(diff * @as(i512, @intCast(close_size)), shared.types.PRICE_SCALE));
}

pub const GlobalState = struct {
    now_ms: i64,
    getOraclePriceFn: *const fn (types.InstrumentId) ?shared.types.Price,

    pub fn getOraclePrice(self: *const GlobalState, instrument_id: types.InstrumentId) ?shared.types.Price {
        return self.getOraclePriceFn(instrument_id);
    }
};

test "call expires ITM - long receives intrinsic value" {
    const alloc = std.testing.allocator;
    const master_addr = [_]u8{0xAA} ** 20;
    var master = account.MasterAccount.init(alloc, master_addr, 0);
    defer master.deinit();

    const sub = try master.openSubAccount(0, null, 0);
    try sub.collateral.deposit(types.USDC_ID, 100_000 * types.USDC, &types.defaultCollateralRegistry);

    // Create an expired ITM call position
    const expiry_ms: i64 = 1_700_000_000_000;
    try sub.positions.put(1, .{
        .instrument_id = 1,
        .kind = .{ .option = .{
            .expiry_ms = expiry_ms,
            .strike = 50_000,
            .option_type = .call,
            .settlement = .cash,
            .tick_size = 1,
            .lot_size = 1,
        } },
        .user = sub.address,
        .size = 1,
        .side = .long,
        .entry_price = 5_000,
        .realized_pnl = 0,
        .leverage = 1,
        .margin_mode = .isolated,
        .isolated_margin = 5_000,
        .funding_index = 0,
        .delta = 0,
        .gamma = 0,
        .vega = 0,
        .theta = 0,
    });

    const state = GlobalState{
        .now_ms = expiry_ms + 1_000,
        .getOraclePriceFn = struct {
            fn getPrice(_: types.InstrumentId) ?shared.types.Price {
                return 55_000; // settlement price > strike
            }
        }.getPrice,
    };

    var unit = OptionsClearingUnit.init(alloc, .{});
    const events = try unit.settleExpired(&state, sub, state.now_ms);
    defer alloc.free(events);

    try std.testing.expect(events.len == 1);
    try std.testing.expect(events[0].payout == 5_000); // (55000 - 50000) * 1
    try std.testing.expect(!sub.positions.contains(1));
}

test "put expires OTM - no payout" {
    const alloc = std.testing.allocator;
    const master_addr = [_]u8{0xAA} ** 20;
    var master = account.MasterAccount.init(alloc, master_addr, 0);
    defer master.deinit();

    const sub = try master.openSubAccount(0, null, 0);
    try sub.collateral.deposit(types.USDC_ID, 100_000 * types.USDC, &types.defaultCollateralRegistry);

    const expiry_ms: i64 = 1_700_000_000_000;
    try sub.positions.put(1, .{
        .instrument_id = 1,
        .kind = .{ .option = .{
            .expiry_ms = expiry_ms,
            .strike = 50_000,
            .option_type = .put,
            .settlement = .cash,
            .tick_size = 1,
            .lot_size = 1,
        } },
        .user = sub.address,
        .size = 1,
        .side = .long,
        .entry_price = 5_000,
        .realized_pnl = 0,
        .leverage = 1,
        .margin_mode = .isolated,
        .isolated_margin = 5_000,
        .funding_index = 0,
        .delta = 0,
        .gamma = 0,
        .vega = 0,
        .theta = 0,
    });

    const state = GlobalState{
        .now_ms = expiry_ms + 1_000,
        .getOraclePriceFn = struct {
            fn getPrice(_: types.InstrumentId) ?shared.types.Price {
                return 55_000; // settlement price > strike, put is OTM
            }
        }.getPrice,
    };

    var unit = OptionsClearingUnit.init(alloc, .{});
    const events = try unit.settleExpired(&state, sub, state.now_ms);
    defer alloc.free(events);

    try std.testing.expect(events.len == 1);
    try std.testing.expect(events[0].payout == 0);
}

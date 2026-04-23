const std = @import("std");
const shared = @import("../../shared/mod.zig");
const types = @import("types.zig");
const account = @import("account.zig");
const margin_mod = @import("margin.zig");

pub const PerpClearingUnit = struct {
    allocator: std.mem.Allocator,
    funding_index: std.AutoHashMap(types.InstrumentId, types.FundingIndex),

    pub fn init(alloc: std.mem.Allocator) PerpClearingUnit {
        return .{
            .allocator = alloc,
            .funding_index = std.AutoHashMap(types.InstrumentId, types.FundingIndex).init(alloc),
        };
    }

    pub fn deinit(self: *PerpClearingUnit) void {
        self.funding_index.deinit();
    }

    pub fn settle(self: *PerpClearingUnit, fill: types.Fill, taker_sub: *account.SubAccount, maker_sub: *account.SubAccount, state: *const margin_mod.GlobalState) !types.FillSettledEvent {
        try self.enforcePriceBand(fill.instrument_id, fill.price, state);
        try self.settleOutstandingFunding(fill.instrument_id, taker_sub, state);
        try self.settleOutstandingFunding(fill.instrument_id, maker_sub, state);
        try applyPerpFill(fill, taker_sub, true);
        try applyPerpFill(fill, maker_sub, false);
        self.syncPositionFundingIndex(fill.instrument_id, taker_sub);
        self.syncPositionFundingIndex(fill.instrument_id, maker_sub);

        return .{
            .fill = fill,
            .taker_fee = 0,
            .maker_fee = 0,
        };
    }

    pub fn settleFunding(self: *PerpClearingUnit, instrument_id: types.InstrumentId, state: *const margin_mod.GlobalState, now_ms: i64) !types.FundingSettledEvent {
        const rate = self.calcFundingRate(instrument_id, state);
        const scaled_rate = rateToFundingIndex(rate.rate);
        const gop = try self.funding_index.getOrPut(instrument_id);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{
                .cumulative = 0,
                .last_rate = 0,
                .updated_at = now_ms,
            };
        }

        gop.value_ptr.cumulative += scaled_rate;
        gop.value_ptr.last_rate = scaled_rate;
        gop.value_ptr.updated_at = now_ms;

        return .{
            .instrument_id = instrument_id,
            .rate = rate.rate,
            .cumulative_index = gop.value_ptr.cumulative,
            .timestamp = now_ms,
        };
    }

    pub fn calcFundingRate(self: *PerpClearingUnit, instrument_id: types.InstrumentId, state: *const margin_mod.GlobalState) types.FundingRate {
        _ = self;
        const index_px = state.indexPrice(instrument_id) orelse return .{ .rate = 0, .mark_premium = 0, .interest_basis = 0 };
        const mark_px = state.freshMarkPrice(instrument_id) orelse index_px;
        const index_f = priceToF64(index_px);
        if (index_f == 0) return .{ .rate = 0, .mark_premium = 0, .interest_basis = 0 };

        const mark_f = priceToF64(mark_px);
        const mark_premium = (mark_f - index_f) / index_f;
        const interest_basis = state.fundingInterestRate();
        const cap = state.fundingRateCap();

        return .{
            .rate = std.math.clamp(mark_premium + interest_basis, -cap, cap),
            .mark_premium = mark_premium,
            .interest_basis = interest_basis,
        };
    }

    fn enforcePriceBand(
        self: *PerpClearingUnit,
        instrument_id: types.InstrumentId,
        fill_price: shared.types.Price,
        state: *const margin_mod.GlobalState,
    ) !void {
        _ = self;
        const reference_price = state.referencePriceForTrade(instrument_id) orelse return;
        if (!state.isWithinTradeBand(reference_price, fill_price)) {
            return error.PriceBandExceeded;
        }
    }

    fn settleOutstandingFunding(
        self: *PerpClearingUnit,
        instrument_id: types.InstrumentId,
        sub: *account.SubAccount,
        state: *const margin_mod.GlobalState,
    ) !void {
        const pos = sub.positions.getPtr(instrument_id) orelse return;
        const current_index: types.FundingIndex = self.funding_index.get(instrument_id) orelse .{
            .cumulative = 0,
            .last_rate = 0,
            .updated_at = state.now_ms,
        };
        if (current_index.cumulative == pos.funding_index) return;

        const settlement_px = state.referencePriceForTrade(instrument_id) orelse state.markPrice(instrument_id) orelse pos.entry_price;
        const notional = pos.notional(settlement_px);
        const delta_index = current_index.cumulative - pos.funding_index;
        const payment_abs = fundingPayment(notional, delta_index);
        if (payment_abs > 0) {
            const pays = (delta_index > 0 and pos.side == .long) or (delta_index < 0 and pos.side == .short);
            if (pays) {
                try sub.collateral.debitEffective(payment_abs, &types.defaultCollateralRegistry);
            } else {
                sub.collateral.credit(types.USDC_ID, payment_abs);
            }
        }
        pos.funding_index = current_index.cumulative;
    }

    fn syncPositionFundingIndex(
        self: *PerpClearingUnit,
        instrument_id: types.InstrumentId,
        sub: *account.SubAccount,
    ) void {
        if (sub.positions.getPtr(instrument_id)) |pos| {
            const current_index: types.FundingIndex = self.funding_index.get(instrument_id) orelse .{
                .cumulative = 0,
                .last_rate = 0,
                .updated_at = 0,
            };
            pos.funding_index = current_index.cumulative;
        }
    }
};

fn applyPerpFill(fill: types.Fill, sub: *account.SubAccount, is_taker: bool) !void {
    const user_addr = if (is_taker) fill.taker else fill.maker;
    if (!std.mem.eql(u8, &sub.address, &user_addr)) return;

    const spec = switch (fill.instrument_kind) {
        .perp => |perp| perp,
        else => return error.InvalidInstrumentKind,
    };
    const requested_leverage = if (is_taker) fill.taker_leverage else fill.maker_leverage;
    try validateRequestedLeverage(requested_leverage, spec.max_leverage);

    const gop = try sub.positions.getOrPut(fill.instrument_id);
    if (!gop.found_existing) {
        gop.value_ptr.* = .{
            .instrument_id = fill.instrument_id,
            .kind = fill.instrument_kind,
            .user = user_addr,
            .size = fill.size,
            .side = if (fill.taker_is_buy == is_taker) .long else .short,
            .entry_price = fill.price,
            .realized_pnl = 0,
            .leverage = requested_leverage,
            .margin_mode = .cross,
            .isolated_margin = 0,
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
            const total_size = pos.size + fill.size;
            const old_weighted_price = @as(u512, @intCast(pos.entry_price)) * @as(u512, @intCast(pos.size));
            const new_weighted_price = @as(u512, @intCast(fill.price)) * @as(u512, @intCast(fill.size));
            pos.entry_price = @intCast((old_weighted_price + new_weighted_price) / @as(u512, @intCast(total_size)));
            pos.size = total_size;
            pos.leverage = requested_leverage;
        } else {
            if (fill.size < pos.size) {
                const pnl = calcPnl(pos, fill.size, fill.price);
                pos.realized_pnl += pnl;
                pos.size -= fill.size;
            } else if (fill.size == pos.size) {
                const pnl = calcPnl(pos, fill.size, fill.price);
                pos.realized_pnl += pnl;
                _ = sub.positions.remove(fill.instrument_id);
                return;
            } else {
                const pnl = calcPnl(pos, pos.size, fill.price);
                pos.realized_pnl += pnl;
                pos.size = fill.size - pos.size;
                pos.side = incoming_side;
                pos.entry_price = fill.price;
                pos.leverage = requested_leverage;
            }
        }
    }
}

fn validateRequestedLeverage(leverage: u8, max_leverage: u8) !void {
    if (leverage == 0 or leverage > max_leverage) return error.InvalidLeverage;
}

fn calcPnl(pos: *const types.Position, close_size: shared.types.Quantity, close_price: shared.types.Price) shared.types.SignedAmount {
    const diff: i256 = if (pos.side == .long)
        @as(i256, @intCast(close_price)) - @as(i256, @intCast(pos.entry_price))
    else
        @as(i256, @intCast(pos.entry_price)) - @as(i256, @intCast(close_price));
    return @intCast(@divTrunc(diff * @as(i512, @intCast(close_size)), shared.types.PRICE_SCALE));
}

const FUNDING_INDEX_SCALE: i64 = 1_000_000_000;

fn rateToFundingIndex(rate: f64) i64 {
    return @intFromFloat(rate * @as(f64, @floatFromInt(FUNDING_INDEX_SCALE)));
}

fn fundingPayment(notional: shared.types.Quantity, delta_index: i64) shared.types.Quantity {
    const abs_delta: u64 = @intCast(if (delta_index < 0) -delta_index else delta_index);
    return @intCast((@as(u512, notional) * abs_delta) / @as(u64, FUNDING_INDEX_SCALE));
}

fn priceToF64(price: shared.types.Price) f64 {
    return @as(f64, @floatFromInt(price)) / @as(f64, @floatFromInt(shared.types.PRICE_SCALE));
}

test "perp long - open, increase VWAP, partial close" {
    const alloc = std.testing.allocator;
    const master_addr = [_]u8{0xAA} ** 20;
    var master = account.MasterAccount.init(alloc, master_addr, 0);
    defer master.deinit();

    const sub = try master.openSubAccount(0, null, 0);

    const state = margin_mod.GlobalState{
        .markPriceFn = struct {
            fn mark(_: types.InstrumentId) ?shared.types.Price {
                return 100_000;
            }
        }.mark,
        .now_ms = 0,
    };

    var unit = PerpClearingUnit.init(alloc);
    defer unit.deinit();

    const fill1 = types.Fill{
        .instrument_id = 1,
        .instrument_kind = .{ .perp = .{
            .tick_size = 1,
            .lot_size = 1,
            .max_leverage = 50,
            .funding_interval_ms = 3_600_000,
            .mark_method = .oracle,
            .isolated_only = false,
        } },
        .taker = sub.address,
        .maker = [_]u8{0xBB} ** 20,
        .taker_order_id = 1,
        .maker_order_id = 2,
        .price = 100_000,
        .size = 1,
        .taker_leverage = 15,
        .taker_is_buy = true,
        .timestamp = 0,
    };
    _ = try unit.settle(fill1, sub, sub, &state);

    const fill2 = types.Fill{
        .instrument_id = 1,
        .instrument_kind = .{ .perp = .{
            .tick_size = 1,
            .lot_size = 1,
            .max_leverage = 50,
            .funding_interval_ms = 3_600_000,
            .mark_method = .oracle,
            .isolated_only = false,
        } },
        .taker = sub.address,
        .maker = [_]u8{0xBB} ** 20,
        .taker_order_id = 3,
        .maker_order_id = 4,
        .price = 102_000,
        .size = 1,
        .taker_leverage = 10,
        .taker_is_buy = true,
        .timestamp = 0,
    };
    _ = try unit.settle(fill2, sub, sub, &state);

    const pos = sub.positions.get(1).?;
    try std.testing.expectEqual(@as(shared.types.Quantity, 2), pos.size);
    try std.testing.expectEqual(@as(shared.types.Price, 101_000), pos.entry_price);
    try std.testing.expectEqual(@as(u8, 10), pos.leverage);

    const fill3 = types.Fill{
        .instrument_id = 1,
        .instrument_kind = .{ .perp = .{
            .tick_size = 1,
            .lot_size = 1,
            .max_leverage = 50,
            .funding_interval_ms = 3_600_000,
            .mark_method = .oracle,
            .isolated_only = false,
        } },
        .taker = sub.address,
        .maker = [_]u8{0xBB} ** 20,
        .taker_order_id = 5,
        .maker_order_id = 6,
        .price = 101_000,
        .size = 1,
        .taker_is_buy = false,
        .timestamp = 0,
    };
    _ = try unit.settle(fill3, sub, sub, &state);

    const pos2 = sub.positions.get(1).?;
    try std.testing.expectEqual(@as(shared.types.Quantity, 1), pos2.size);
}

test "funding rate uses mark premium and cumulative index" {
    const alloc = std.testing.allocator;
    var unit = PerpClearingUnit.init(alloc);
    defer unit.deinit();

    const state = margin_mod.GlobalState{
        .markPriceFn = struct {
            fn mark(_: types.InstrumentId) ?shared.types.Price {
                return 101_000;
            }
        }.mark,
        .indexPriceFn = struct {
            fn index(_: types.InstrumentId) ?shared.types.Price {
                return 100_000;
            }
        }.index,
        .now_ms = 1_700_000_000_000,
    };

    const rate = unit.calcFundingRate(1, &state);
    try std.testing.expect(rate.rate > 0);

    const event = try unit.settleFunding(1, &state, state.now_ms);
    try std.testing.expect(event.rate > 0);
    try std.testing.expect(event.cumulative_index > 0);
}

test "perp settlement rejects fills outside price band" {
    const alloc = std.testing.allocator;
    const master_addr = [_]u8{0xAA} ** 20;
    var master = account.MasterAccount.init(alloc, master_addr, 0);
    defer master.deinit();

    const taker = try master.openSubAccount(0, null, 0);
    const maker = try master.openSubAccount(1, null, 0);
    var unit = PerpClearingUnit.init(alloc);
    defer unit.deinit();

    const fill = types.Fill{
        .instrument_id = 1,
        .instrument_kind = .{ .perp = .{
            .tick_size = 1,
            .lot_size = 1,
            .max_leverage = 50,
            .funding_interval_ms = 3_600_000,
            .mark_method = .oracle,
            .isolated_only = false,
        } },
        .taker = taker.address,
        .maker = maker.address,
        .taker_order_id = 1,
        .maker_order_id = 2,
        .price = 120_000,
        .size = 1,
        .taker_is_buy = true,
        .timestamp = 0,
    };

    const state = margin_mod.GlobalState{
        .markPriceFn = struct {
            fn mark(_: types.InstrumentId) ?shared.types.Price {
                return 100_000;
            }
        }.mark,
        .indexPriceFn = struct {
            fn index(_: types.InstrumentId) ?shared.types.Price {
                return 100_000;
            }
        }.index,
        .max_trade_price_deviation_bps = 500,
    };

    try std.testing.expectError(error.PriceBandExceeded, unit.settle(fill, taker, maker, &state));
}

test "perp exact close removes position" {
    const alloc = std.testing.allocator;
    const master_addr = [_]u8{0xAA} ** 20;
    var master = account.MasterAccount.init(alloc, master_addr, 0);
    defer master.deinit();

    const sub = try master.openSubAccount(0, null, 0);

    const state = margin_mod.GlobalState{
        .markPriceFn = struct {
            fn mark(_: types.InstrumentId) ?shared.types.Price {
                return 100_000;
            }
        }.mark,
        .now_ms = 0,
    };

    var unit = PerpClearingUnit.init(alloc);
    defer unit.deinit();

    const open_fill = types.Fill{
        .instrument_id = 1,
        .instrument_kind = .{ .perp = .{
            .tick_size = 1,
            .lot_size = 1,
            .max_leverage = 50,
            .funding_interval_ms = 3_600_000,
            .mark_method = .oracle,
            .isolated_only = false,
        } },
        .taker = sub.address,
        .maker = [_]u8{0xBB} ** 20,
        .taker_order_id = 1,
        .maker_order_id = 2,
        .price = 100_000,
        .size = 1,
        .taker_leverage = 20,
        .taker_is_buy = true,
        .timestamp = 0,
    };
    _ = try unit.settle(open_fill, sub, sub, &state);

    const close_fill = types.Fill{
        .instrument_id = 1,
        .instrument_kind = open_fill.instrument_kind,
        .taker = sub.address,
        .maker = [_]u8{0xBB} ** 20,
        .taker_order_id = 3,
        .maker_order_id = 4,
        .price = 101_000,
        .size = 1,
        .taker_is_buy = false,
        .timestamp = 0,
    };
    _ = try unit.settle(close_fill, sub, sub, &state);

    try std.testing.expect(sub.positions.get(1) == null);
    try std.testing.expect(!sub.hasOpenPositions());
}

test "perp open validates requested leverage against instrument max" {
    const alloc = std.testing.allocator;
    const master_addr = [_]u8{0xAA} ** 20;
    var master = account.MasterAccount.init(alloc, master_addr, 0);
    defer master.deinit();

    const sub = try master.openSubAccount(0, null, 0);

    const state = margin_mod.GlobalState{
        .markPriceFn = struct {
            fn mark(_: types.InstrumentId) ?shared.types.Price {
                return 100_000;
            }
        }.mark,
        .now_ms = 0,
    };

    var unit = PerpClearingUnit.init(alloc);
    defer unit.deinit();

    try std.testing.expectError(error.InvalidLeverage, unit.settle(.{
        .instrument_id = 1,
        .instrument_kind = .{ .perp = .{
            .tick_size = 1,
            .lot_size = 1,
            .max_leverage = 25,
            .funding_interval_ms = 3_600_000,
            .mark_method = .oracle,
            .isolated_only = false,
        } },
        .taker = sub.address,
        .maker = [_]u8{0xBB} ** 20,
        .taker_order_id = 1,
        .maker_order_id = 2,
        .price = 100_000,
        .size = 1,
        .taker_leverage = 26,
        .taker_is_buy = true,
        .timestamp = 0,
    }, sub, sub, &state));
}

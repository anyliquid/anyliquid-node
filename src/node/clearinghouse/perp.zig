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
        _ = self;
        _ = state;
        applyPerpFill(fill, taker_sub, true) catch {};
        applyPerpFill(fill, maker_sub, false) catch {};

        return .{
            .fill = fill,
            .taker_fee = 0,
            .maker_fee = 0,
        };
    }

    pub fn settleFunding(self: *PerpClearingUnit, instrument_id: types.InstrumentId, state: *const margin_mod.GlobalState, now_ms: i64) !types.FundingSettledEvent {
        _ = self;
        _ = state;
        return .{
            .instrument_id = instrument_id,
            .rate = 0,
            .cumulative_index = 0,
            .timestamp = now_ms,
        };
    }

    pub fn calcFundingRate(self: *PerpClearingUnit, instrument_id: types.InstrumentId, state: *const margin_mod.GlobalState) types.FundingRate {
        _ = self;
        _ = instrument_id;
        _ = state;
        return .{ .rate = 0, .mark_premium = 0, .interest_basis = 0 };
    }
};

fn applyPerpFill(fill: types.Fill, sub: *account.SubAccount, is_taker: bool) !void {
    const user_addr = if (is_taker) fill.taker else fill.maker;
    const gop = try sub.positions.getOrPut(fill.instrument_id);
    if (!gop.found_existing) {
        gop.value_ptr.* = .{
            .instrument_id = fill.instrument_id,
            .kind = .{ .perp = .{
                .tick_size = 1,
                .lot_size = 1,
                .max_leverage = 50,
                .funding_interval_ms = 3_600_000,
                .mark_method = .oracle,
                .isolated_only = false,
            } },
            .user = user_addr,
            .size = fill.size,
            .side = if (fill.taker_is_buy == is_taker) .long else .short,
            .entry_price = fill.price,
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
    } else {
        var pos = gop.value_ptr;
        const incoming_side: shared.types.Side = if (fill.taker_is_buy == is_taker) .long else .short;
        if (pos.side == incoming_side) {
            const total_size = pos.size + fill.size;
            const old_notional = shared.fixed_point.mulPriceQty(pos.entry_price, pos.size);
            const new_notional = shared.fixed_point.mulPriceQty(fill.price, fill.size);
            pos.entry_price = @divTrunc(old_notional + new_notional, total_size);
            pos.size = total_size;
        } else {
            if (fill.size < pos.size) {
                const pnl = calcPnl(pos, fill.size, fill.price);
                pos.realized_pnl += pnl;
                pos.size -= fill.size;
            } else if (fill.size == pos.size) {
                const pnl = calcPnl(pos, fill.size, fill.price);
                pos.realized_pnl += pnl;
                pos.size = 0;
            } else {
                const pnl = calcPnl(pos, pos.size, fill.price);
                pos.realized_pnl += pnl;
                pos.size = fill.size - pos.size;
                pos.side = incoming_side;
                pos.entry_price = fill.price;
            }
        }
    }
}

fn calcPnl(pos: *const types.Position, close_size: shared.types.Quantity, close_price: shared.types.Price) shared.types.SignedAmount {
    const diff: i256 = if (pos.side == .long)
        @as(i256, @intCast(close_price)) - @as(i256, @intCast(pos.entry_price))
    else
        @as(i256, @intCast(pos.entry_price)) - @as(i256, @intCast(close_price));
    return @intCast(@divTrunc(diff * @as(i512, @intCast(close_size)), shared.types.PRICE_SCALE));
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
        .taker = sub.address,
        .maker = [_]u8{0xBB} ** 20,
        .taker_order_id = 1,
        .maker_order_id = 2,
        .price = 100_000,
        .size = 1,
        .taker_is_buy = true,
        .timestamp = 0,
    };
    _ = try unit.settle(fill1, sub, sub, &state);

    const fill2 = types.Fill{
        .instrument_id = 1,
        .taker = sub.address,
        .maker = [_]u8{0xBB} ** 20,
        .taker_order_id = 3,
        .maker_order_id = 4,
        .price = 102_000,
        .size = 1,
        .taker_is_buy = true,
        .timestamp = 0,
    };
    _ = try unit.settle(fill2, sub, sub, &state);

    const pos = sub.positions.get(1).?;
    try std.testing.expectEqual(@as(shared.types.Quantity, 2), pos.size);
    try std.testing.expectEqual(@as(shared.types.Price, 101_000), pos.entry_price);

    const fill3 = types.Fill{
        .instrument_id = 1,
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

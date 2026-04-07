const std = @import("std");
const shared = @import("../../shared/mod.zig");
const types = @import("types.zig");
const account = @import("account.zig");
const margin_mod = @import("margin.zig");
const spot_mod = @import("spot.zig");
const perp_mod = @import("perp.zig");
const options_mod = @import("options.zig");

/// InstrumentRouter dispatches fills to the appropriate clearing unit based on instrument kind.
pub const InstrumentRouter = struct {
    allocator: std.mem.Allocator,
    spot_unit: spot_mod.SpotClearingUnit,
    perp_unit: perp_mod.PerpClearingUnit,
    options_unit: options_mod.OptionsClearingUnit,

    pub fn init(alloc: std.mem.Allocator, fee_config: types.FeeConfig) InstrumentRouter {
        return .{
            .allocator = alloc,
            .spot_unit = spot_mod.SpotClearingUnit.init(fee_config),
            .perp_unit = perp_mod.PerpClearingUnit.init(alloc),
            .options_unit = options_mod.OptionsClearingUnit.init(alloc, fee_config),
        };
    }

    pub fn deinit(self: *InstrumentRouter) void {
        self.perp_unit.deinit();
        self.options_unit.deinit(); // Note: OptionsClearingUnit doesn't have deinit yet
    }

    /// Route a fill to the appropriate clearing unit.
    pub fn route(
        self: *InstrumentRouter,
        fill: types.Fill,
        taker_sub: *account.SubAccount,
        maker_sub: *account.SubAccount,
        state: *const margin_mod.GlobalState,
    ) !types.FillSettledEvent {
        return switch (fill.instrument_kind) {
            .spot => self.spot_unit.settle(fill, taker_sub, maker_sub),
            .perp => self.perp_unit.settle(fill, taker_sub, maker_sub, state),
            .option => self.options_unit.settle(fill, taker_sub, maker_sub),
        };
    }

    /// Settle funding for a perp instrument.
    pub fn settleFunding(
        self: *InstrumentRouter,
        instrument_id: types.InstrumentId,
        state: *const margin_mod.GlobalState,
        now_ms: i64,
    ) !types.FundingSettledEvent {
        return self.perp_unit.settleFunding(instrument_id, state, now_ms);
    }

    /// Refresh Greeks for all option positions.
    pub fn refreshOptionGreeks(
        self: *InstrumentRouter,
        state: *const options_mod.GlobalState,
        sub: *account.SubAccount,
    ) void {
        self.options_unit.refreshGreeks(state, sub);
    }

    /// Settle expired options.
    pub fn settleExpiredOptions(
        self: *InstrumentRouter,
        state: *const options_mod.GlobalState,
        sub: *account.SubAccount,
        now_ms: i64,
    ) ![]types.OptionExpiredEvent {
        return self.options_unit.settleExpired(state, sub, now_ms);
    }
};

test "router dispatches spot fill" {
    const alloc = std.testing.allocator;
    const master_a = [_]u8{0xAA} ** 20;
    const master_b = [_]u8{0xBB} ** 20;

    var master_a_account = account.MasterAccount.init(alloc, master_a, 0);
    defer master_a_account.deinit();
    var master_b_account = account.MasterAccount.init(alloc, master_b, 0);
    defer master_b_account.deinit();

    const taker = try master_a_account.openSubAccount(0, null, 0);
    const maker = try master_b_account.openSubAccount(0, null, 0);

    try taker.collateral.deposit(types.USDC_ID, 100_000 * types.USDC, &types.defaultCollateralRegistry);
    try maker.collateral.deposit(types.BTC_ID, 1 * types.BTC, &types.defaultCollateralRegistry);

    const fill = types.Fill{
        .instrument_id = types.BTC_ID,
        .instrument_kind = .spot,
        .taker = taker.address,
        .maker = maker.address,
        .taker_order_id = 1,
        .maker_order_id = 2,
        .price = 50_000,
        .size = 1,
        .taker_is_buy = true,
        .timestamp = 0,
    };

    const state = margin_mod.GlobalState{
        .markPriceFn = struct {
            fn mark(_: types.InstrumentId) ?shared.types.Price {
                return null;
            }
        }.mark,
        .now_ms = 0,
    };

    var router = InstrumentRouter.init(alloc, .{});
    defer router.deinit();

    const event = try router.route(fill, taker, maker, &state);
    try std.testing.expect(event.fill.instrument_kind == .spot);
}

test "router dispatches perp fill" {
    const alloc = std.testing.allocator;
    const master_a = [_]u8{0xAA} ** 20;

    var master_a_account = account.MasterAccount.init(alloc, master_a, 0);
    defer master_a_account.deinit();

    const taker = try master_a_account.openSubAccount(0, null, 0);
    const maker = try master_a_account.openSubAccount(1, null, 0);

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
        .price = 100_000,
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
        .now_ms = 0,
    };

    var router = InstrumentRouter.init(alloc, .{});
    defer router.deinit();

    const event = try router.route(fill, taker, maker, &state);
    try std.testing.expect(event.fill.instrument_kind == .perp);
}

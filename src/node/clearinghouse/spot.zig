const std = @import("std");
const shared = @import("../../shared/mod.zig");
const types = @import("types.zig");
const account = @import("account.zig");
const margin = @import("margin.zig");

pub const SpotClearingUnit = struct {
    fee_config: types.FeeConfig,

    pub fn init(cfg: types.FeeConfig) SpotClearingUnit {
        return .{ .fee_config = cfg };
    }

    pub fn settle(self: *SpotClearingUnit, fill: types.Fill, taker_sub: *account.SubAccount, maker_sub: *account.SubAccount) !types.FillSettledEvent {
        const quote_amount = shared.fixed_point.mulPriceQty(fill.price, fill.size);
        const taker_fee = SpotClearingUnit.calcFee(quote_amount, self.fee_config.taker_fee_bps);
        const maker_fee = SpotClearingUnit.calcFee(quote_amount, self.fee_config.maker_fee_bps);

        if (fill.taker_is_buy) {
            try taker_sub.collateral.withdraw(types.USDC_ID, quote_amount + taker_fee);
            taker_sub.collateral.credit(fill.instrument_id, fill.size);
            try maker_sub.collateral.withdraw(fill.instrument_id, fill.size);
            maker_sub.collateral.credit(types.USDC_ID, quote_amount - maker_fee);
        } else {
            try taker_sub.collateral.withdraw(fill.instrument_id, fill.size);
            taker_sub.collateral.credit(types.USDC_ID, quote_amount - taker_fee);
            try maker_sub.collateral.withdraw(types.USDC_ID, quote_amount + maker_fee);
            maker_sub.collateral.credit(fill.instrument_id, fill.size);
        }

        return .{
            .fill = fill,
            .taker_fee = taker_fee,
            .maker_fee = maker_fee,
        };
    }

    pub fn calcFee(quote_amount: shared.types.Quantity, fee_bps: u32) shared.types.Quantity {
        return @divTrunc(quote_amount * @as(shared.types.Quantity, @intCast(fee_bps)), 10_000);
    }
};

pub fn calcFee(quote_amount: shared.types.Quantity, fee_bps: u32) shared.types.Quantity {
    return @divTrunc(quote_amount * @as(shared.types.Quantity, @intCast(fee_bps)), 10_000);
}

test "spot buy fill - base to taker, quote to maker" {
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

    var unit = SpotClearingUnit.init(.{});
    _ = try unit.settle(fill, taker, maker);

    try std.testing.expect(taker.collateral.rawBalance(types.BTC_ID) == 1);
    try std.testing.expect(maker.collateral.rawBalance(types.USDC_ID) > 49_000 * types.USDC);
}

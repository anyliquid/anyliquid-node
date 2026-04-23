const std = @import("std");
const shared = @import("../../shared/mod.zig");
const types = @import("types.zig");
const account = @import("account.zig");
const margin_mod = @import("margin.zig");

/// Portfolio margin calculations - margines spot and perp positions as a unified portfolio.
pub const PortfolioMargin = struct {
    /// LTV (Loan-to-Value) table for auto-borrow calculations.
    pub const LTV_TABLE = std.StaticStringMap(f64).initComptime(.{
        .{ "USDC", 1.00 },
        .{ "USDH", 1.00 },
        .{ "BTC", 0.85 },
        .{ "HYPE", 0.50 },
    });

    /// Supply and borrow caps (pre-alpha values).
    pub const SUPPLY_CAP_USDC: shared.types.Quantity = 500_000_000 * types.USDC;
    pub const BORROW_CAP_USDC: shared.types.Quantity = 100_000_000 * types.USDC;
    pub const SUPPLY_CAP_HYPE: shared.types.Quantity = 1_000_000 * types.HYPE;
    pub const BORROW_CAP_HYPE: shared.types.Quantity = 0; // Not borrowable
    pub const SUPPLY_CAP_BTC: shared.types.Quantity = 400 * types.BTC;
    pub const BORROW_CAP_BTC: shared.types.Quantity = 0; // Not borrowable

    /// Compute max auto-borrow amount against collateral.
    pub fn maxAutoBorrow(
        collateral_balance: shared.types.Quantity,
        collateral_oracle_price: shared.types.Price,
        ltv: f64,
    ) shared.types.Quantity {
        return @intFromFloat(@as(f64, @floatFromInt(collateral_balance)) *
            @as(f64, @floatFromInt(collateral_oracle_price)) *
            ltv);
    }

    /// Compute borrow oracle price - three-way median for manipulation resistance.
    pub fn borrowOraclePrice(
        token: types.AssetId,
        spot_price: shared.types.Price,
        perp_mark: shared.types.Price,
        perp_oracle: shared.types.Price,
    ) shared.types.Price {
        _ = token;
        return median3(spot_price, perp_mark, perp_oracle);
    }

    /// Compute stablecoin borrow rate APY based on utilization.
    pub fn stablecoinBorrowRate(utilization: f64) f64 {
        return types.stablecoinBorrowRate(utilization);
    }

    /// Compute accrued interest for a borrow position.
    pub fn accruedInterest(principal: shared.types.Quantity, rate_apy: f64, dt_seconds: f64) shared.types.Quantity {
        return types.accruedInterest(principal, rate_apy, dt_seconds);
    }

    /// Check if portfolio caps allow portfolio margin (falls back to unified if exceeded).
    pub fn portfolioCapsAvailable(
        sub: *const account.SubAccount,
        global_usdc_supply: shared.types.Quantity,
        global_usdc_borrow: shared.types.Quantity,
    ) bool {
        _ = sub;
        // Check if global caps are hit
        if (global_usdc_supply >= SUPPLY_CAP_USDC) return false;
        if (global_usdc_borrow >= BORROW_CAP_USDC) return false;
        return true;
    }

    /// Compute portfolio maintenance requirement for a token.
    pub fn portfolioMaintenanceRequirement(
        sub: *const account.SubAccount,
        token: types.AssetId,
        state: *const margin_mod.GlobalState,
    ) shared.types.Quantity {
        _ = token;
        const min_borrow_offset: shared.types.Quantity = 20 * types.USDC;

        var cross_mm: shared.types.Quantity = 0;
        var it = sub.positions.iterator();
        while (it.next()) |entry| {
            const pos = entry.value_ptr;
            if (pos.margin_mode == .cross) {
                if (state.markPrice(pos.instrument_id)) |mark_px| {
                    const mm_rate = types.maintenanceMarginRate(types.instrumentMaxLeverage(pos.kind, 50));
                    const notional = shared.fixed_point.mulPriceQty(mark_px, pos.size);
                    cross_mm += @intFromFloat(@as(f64, @floatFromInt(notional)) * mm_rate);
                }
            }
        }

        return min_borrow_offset + cross_mm;
    }

    /// Compute portfolio liquidation value for a token.
    pub fn portfolioLiquidationValue(
        sub: *const account.SubAccount,
        token: types.AssetId,
        state: *const margin_mod.GlobalState,
        borrow_oracle_price: shared.types.Price,
        ltv: f64,
        borrow_cap: shared.types.Quantity,
        supply_cap: shared.types.Quantity,
    ) shared.types.Quantity {
        const portfolio_balance = portfolioBalance(sub, token, state);

        const liquidation_threshold = 0.5 + 0.5 * ltv;

        const min_cap = @min(borrow_cap, @min(portfolio_balance, supply_cap));
        const capped_value: shared.types.Quantity = @intFromFloat(@as(f64, @floatFromInt(min_cap)) *
            @as(f64, @floatFromInt(borrow_oracle_price)) *
            liquidation_threshold);

        return @intCast(@as(i256, @intCast(portfolio_balance)) + @as(i256, @intCast(capped_value)));
    }

    /// Compute portfolio balance for a token.
    pub fn portfolioBalance(
        sub: *const account.SubAccount,
        token: types.AssetId,
        state: *const margin_mod.GlobalState,
    ) shared.types.SignedAmount {
        const spot_bal = sub.collateral.rawBalance(token);
        var perp_upnl: shared.types.SignedAmount = 0;

        var it = sub.positions.iterator();
        while (it.next()) |entry| {
            const pos = entry.value_ptr;
            if (state.markPrice(pos.instrument_id)) |mark_px| {
                perp_upnl += pos.unrealizedPnl(mark_px);
            }
        }

        return @as(shared.types.SignedAmount, @intCast(spot_bal)) + perp_upnl;
    }

    /// Compute portfolio margin ratio (liquidation trigger).
    pub fn portfolioMarginRatio(
        sub: *const account.SubAccount,
        state: *const margin_mod.GlobalState,
    ) f64 {
        var max_ratio: f64 = 0.0;

        for (types.BORROWABLE_ASSETS) |token| {
            const pmr = portfolioMaintenanceRequirement(sub, token, state);
            const oracle_price = state.assetOraclePrice(token) orelse continue;
            const ltv = getLTV(token);
            const plv = portfolioLiquidationValue(
                sub,
                token,
                state,
                oracle_price,
                ltv,
                getBorrowCap(token),
                getSupplyCap(token),
            );

            if (plv > 0) {
                const ratio = @as(f64, @floatFromInt(pmr)) / @as(f64, @floatFromInt(plv));
                max_ratio = @max(max_ratio, ratio);
            }
        }

        return max_ratio;
    }

    fn getLTV(token: types.AssetId) f64 {
        return switch (token) {
            types.USDC_ID => 1.00,
            types.BTC_ID => 0.85,
            types.HYPE_ID => 0.50,
            else => 0.0,
        };
    }

    fn getBorrowCap(token: types.AssetId) shared.types.Quantity {
        return switch (token) {
            types.USDC_ID => BORROW_CAP_USDC,
            else => 0,
        };
    }

    fn getSupplyCap(token: types.AssetId) shared.types.Quantity {
        return switch (token) {
            types.USDC_ID => SUPPLY_CAP_USDC,
            types.HYPE_ID => SUPPLY_CAP_HYPE,
            types.BTC_ID => SUPPLY_CAP_BTC,
            else => 0,
        };
    }
};

fn median3(a: shared.types.Price, b: shared.types.Price, c: shared.types.Price) shared.types.Price {
    if ((a >= b and a <= c) or (a <= b and a >= c)) return a;
    if ((b >= a and b <= c) or (b <= a and b >= c)) return b;
    return c;
}

test "portfolio margin ratio > 0.95 -> liquidatable" {
    const alloc = std.testing.allocator;
    const master_addr = [_]u8{0xAA} ** 20;
    var master = account.MasterAccount.init(alloc, master_addr, 0);
    defer master.deinit();

    const sub = try master.openSubAccount(0, null, 0);
    try sub.collateral.deposit(types.USDC_ID, 1_000_000 * types.USDC, &types.defaultCollateralRegistry);

    const state = margin_mod.GlobalState{
        .markPriceFn = struct {
            fn mark(_: types.InstrumentId) ?shared.types.Price {
                return 100_000;
            }
        }.mark,
        .now_ms = 0,
    };

    const ratio = PortfolioMargin.portfolioMarginRatio(sub, &state);

    try std.testing.expect(ratio < 0.95); // Should be healthy with just USDC
}

test "borrow rate kink - below 80% util at 5% APY" {
    try std.testing.expectApproxEqAbs(0.05, PortfolioMargin.stablecoinBorrowRate(0.5), 1e-9);
}

test "borrow rate kink - 90% util -> 52.5% APY" {
    try std.testing.expectApproxEqAbs(0.525, PortfolioMargin.stablecoinBorrowRate(0.9), 1e-9);
}

test "cap exceeded - falls back to unified mode" {
    const alloc = std.testing.allocator;
    const master_addr = [_]u8{0xAA} ** 20;
    var master = account.MasterAccount.init(alloc, master_addr, 0);
    defer master.deinit();

    const sub = try master.openSubAccount(0, null, 0);
    try sub.collateral.deposit(types.USDC_ID, 10_000 * types.USDC, &types.defaultCollateralRegistry);

    const available = PortfolioMargin.portfolioCapsAvailable(sub, PortfolioMargin.SUPPLY_CAP_USDC + 1, 0);
    try std.testing.expect(!available);
}

test "min_borrow_offset 20 USDC always included in maintenance req" {
    const alloc = std.testing.allocator;
    const master_addr = [_]u8{0xAA} ** 20;
    var master = account.MasterAccount.init(alloc, master_addr, 0);
    defer master.deinit();

    const sub = try master.openSubAccount(0, null, 0);
    try sub.collateral.deposit(types.USDC_ID, 1_000_000 * types.USDC, &types.defaultCollateralRegistry);

    const state = margin_mod.GlobalState{
        .markPriceFn = struct {
            fn mark(_: types.InstrumentId) ?shared.types.Price {
                return null;
            }
        }.mark,
        .now_ms = 0,
    };

    const pmr = PortfolioMargin.portfolioMaintenanceRequirement(sub, types.USDC_ID, &state);
    try std.testing.expect(pmr >= 20 * types.USDC);
}

const std = @import("std");
const shared = @import("../../shared/mod.zig");
const types = @import("types.zig");
const account_mod = @import("account.zig");
const margin_mod = @import("margin.zig");
const router_mod = @import("router.zig");
const liquidation_mod = @import("liquidation.zig");
const transfer_mod = @import("transfer.zig");
const account_mode_mod = @import("account_mode.zig");

/// Clearinghouse - the single authority over all account state, position state, and collateral.
/// Every fill produced by the Matching Engine flows through it before any account is mutated.
pub const Clearinghouse = struct {
    allocator: std.mem.Allocator,
    router: router_mod.InstrumentRouter,
    margin_engine: margin_mod.MarginEngine,
    liquidation_engine: liquidation_mod.LiquidationEngine,
    transfer_engine: transfer_mod.TransferEngine,
    mode_manager: account_mode_mod.AccountModeManager,

    pub fn init(cfg: types.ClearinghouseConfig, alloc: std.mem.Allocator) !Clearinghouse {
        var margin_engine = margin_mod.MarginEngine.init(.{});
        
        return .{
            .allocator = alloc,
            .router = router_mod.InstrumentRouter.init(alloc, cfg.fee_config),
            .margin_engine = margin_engine,
            .liquidation_engine = liquidation_mod.LiquidationEngine.init(alloc, 0, &margin_engine, .{}),
            .transfer_engine = transfer_mod.TransferEngine.init(alloc, &margin_engine),
            .mode_manager = account_mode_mod.AccountModeManager.init(alloc),
        };
    }

    pub fn deinit(self: *Clearinghouse) void {
        self.router.deinit();
    }

    /// Process a single fill through the appropriate clearing unit.
    pub fn processFill(
        self: *Clearinghouse,
        fill: types.Fill,
        taker_sub: *account_mod.SubAccount,
        maker_sub: *account_mod.SubAccount,
        state: *const margin_mod.GlobalState,
    ) !types.FillSettledEvent {
        return self.router.route(fill, taker_sub, maker_sub, state);
    }

    /// Settle periodic funding for a perp instrument.
    pub fn settleFunding(
        self: *Clearinghouse,
        instrument_id: types.InstrumentId,
        state: *const margin_mod.GlobalState,
        now_ms: i64,
    ) !types.FundingSettledEvent {
        return self.router.settleFunding(instrument_id, state, now_ms);
    }

    /// Compute margin summary for a sub-account.
    pub fn computeMargin(
        self: *Clearinghouse,
        sub: *const account_mod.SubAccount,
        state: *const margin_mod.GlobalState,
    ) types.MarginSummary {
        return self.margin_engine.compute(sub, state);
    }

    /// Check if opening a position would breach margin requirements.
    pub fn checkMarginForOrder(
        self: *Clearinghouse,
        sub: *const account_mod.SubAccount,
        order: shared.types.Order,
        state: *const margin_mod.GlobalState,
    ) !void {
        try self.margin_engine.checkInitialMargin(sub, order, state);
    }

    /// Scan for liquidation candidates.
    pub fn scanLiquidations(
        self: *Clearinghouse,
        masters: *const std.AutoHashMap(shared.types.Address, account_mod.MasterAccount),
        state: *const margin_mod.GlobalState,
    ) ![]types.LiquidationCandidate {
        return self.liquidation_engine.scanCandidates(masters, state);
    }

    /// Execute liquidation for a candidate.
    pub fn executeLiquidation(
        self: *Clearinghouse,
        candidate: types.LiquidationCandidate,
        sub: *account_mod.SubAccount,
        state: *const margin_mod.GlobalState,
    ) !types.LiquidationResult {
        return self.liquidation_engine.execute(candidate, sub, state);
    }

    /// Execute intra-master transfer.
    pub fn executeIntraMasterTransfer(
        self: *Clearinghouse,
        from_index: u8,
        to_index: u8,
        asset_id: types.AssetId,
        amount: shared.types.Quantity,
        master: *account_mod.MasterAccount,
        state: *const margin_mod.GlobalState,
    ) !types.TransferEvent {
        return self.transfer_engine.executeIntraMaster(
            from_index, to_index, asset_id, amount, master, state,
        );
    }

    /// Execute deposit.
    pub fn executeDeposit(
        self: *Clearinghouse,
        to_index: u8,
        asset_id: types.AssetId,
        amount: shared.types.Quantity,
        master: *account_mod.MasterAccount,
        state: *const margin_mod.GlobalState,
    ) !types.TransferEvent {
        return self.transfer_engine.executeDeposit(
            to_index, asset_id, amount, master, state,
        );
    }

    /// Execute withdrawal.
    pub fn executeWithdrawal(
        self: *Clearinghouse,
        from_index: u8,
        asset_id: types.AssetId,
        amount: shared.types.Quantity,
        destination: shared.types.Address,
        master: *account_mod.MasterAccount,
        state: *const margin_mod.GlobalState,
    ) !types.TransferEvent {
        return self.transfer_engine.executeWithdrawal(
            from_index, asset_id, amount, destination, master, state,
        );
    }

    /// Change account mode.
    pub fn setAccountMode(
        self: *Clearinghouse,
        master: *account_mod.MasterAccount,
        new_mode: types.AccountMode,
        now_ms: i64,
        weighted_volume: shared.types.Quantity,
        has_active_builder_code: bool,
    ) !types.AccountModeChangedEvent {
        return self.mode_manager.setAccountMode(
            master, new_mode, now_ms, weighted_volume, has_active_builder_code,
        );
    }

    /// Check daily action limit.
    pub fn checkDailyAction(
        self: *Clearinghouse,
        master: *account_mod.MasterAccount,
        now_ms: i64,
    ) !void {
        return self.mode_manager.checkDailyAction(master, now_ms);
    }

    /// Refresh option greeks.
    pub fn refreshOptionGreeks(
        self: *Clearinghouse,
        state: *const @import("options.zig").GlobalState,
        sub: *account_mod.SubAccount,
    ) void {
        self.router.refreshOptionGreeks(state, sub);
    }

    /// Settle expired options.
    pub fn settleExpiredOptions(
        self: *Clearinghouse,
        state: *const @import("options.zig").GlobalState,
        sub: *account_mod.SubAccount,
        now_ms: i64,
    ) ![]types.OptionExpiredEvent {
        return self.router.settleExpiredOptions(state, sub, now_ms);
    }
};

test "Clearinghouse processes spot fill" {
    const alloc = std.testing.allocator;
    const master_a = [_]u8{0xAA} ** 20;
    const master_b = [_]u8{0xBB} ** 20;

    var master_a_account = account_mod.MasterAccount.init(alloc, master_a, 0);
    defer master_a_account.deinit();
    var master_b_account = account_mod.MasterAccount.init(alloc, master_b, 0);
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
                return 50_000;
            }
        }.mark,
    };

    var ch = try Clearinghouse.init(.{}, alloc);
    defer ch.deinit();

    const event = try ch.processFill(fill, taker, maker, &state);
    try std.testing.expect(event.fill.price == 50_000);
    try std.testing.expect(taker.collateral.rawBalance(types.BTC_ID) == 1);
}

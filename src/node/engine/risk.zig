const std = @import("std");
const shared = @import("../../shared/mod.zig");
const perp_mod = @import("perp.zig");
const state_mod = @import("../state.zig");

pub const RiskError = error{
    InsufficientMargin,
    PositionNotFound,
};

const MAINTENANCE_BPS: i256 = 500;
const BPS_SCALE: i256 = 10_000;
const DEFAULT_BALANCE: shared.types.Amount = 1_000_000_000;

const AccountLedger = struct {
    balance: shared.types.Amount,
    positions: std.AutoHashMap(shared.types.AssetId, shared.types.Position),

    fn init(allocator: std.mem.Allocator, balance: shared.types.Amount) AccountLedger {
        return .{
            .balance = balance,
            .positions = std.AutoHashMap(shared.types.AssetId, shared.types.Position).init(allocator),
        };
    }

    fn deinit(self: *AccountLedger) void {
        self.positions.deinit();
    }
};

pub const RiskEngine = struct {
    allocator: std.mem.Allocator,
    perp: *perp_mod.PerpEngine,
    accounts: std.AutoHashMap(shared.types.Address, AccountLedger),

    pub fn init(perp: *perp_mod.PerpEngine, allocator: std.mem.Allocator) RiskEngine {
        return .{
            .allocator = allocator,
            .perp = perp,
            .accounts = std.AutoHashMap(shared.types.Address, AccountLedger).init(allocator),
        };
    }

    pub fn deinit(self: *RiskEngine) void {
        var it = self.accounts.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.accounts.deinit();
    }

    pub fn setBalance(self: *RiskEngine, addr: shared.types.Address, balance: shared.types.Amount) !void {
        const account = try self.ensureAccount(addr);
        account.balance = balance;
    }

    pub fn onFill(
        self: *RiskEngine,
        taker: *const shared.types.Order,
        maker: *const shared.types.Order,
        fill_size: shared.types.Quantity,
        fill_px: shared.types.Price,
        state: *state_mod.GlobalState,
    ) !void {
        _ = state;
        try self.checkMarginBeforeTrade(taker.user, taker.asset_id, taker.is_buy, fill_size, fill_px);
        try self.checkMarginBeforeTrade(maker.user, maker.asset_id, maker.is_buy, fill_size, fill_px);
        try self.applyTrade(taker.user, taker.asset_id, taker.is_buy, fill_size, fill_px);
        try self.applyTrade(maker.user, maker.asset_id, maker.is_buy, fill_size, fill_px);
        try self.refreshExposure(taker.asset_id);
    }

    pub fn checkLiquidations(
        self: *RiskEngine,
        state: *state_mod.GlobalState,
    ) ![]shared.types.LiquidationEvent {
        _ = state;
        var events = std.ArrayList(shared.types.LiquidationEvent).empty;
        defer events.deinit(self.allocator);

        var accounts_it = self.accounts.iterator();
        while (accounts_it.next()) |account_entry| {
            const account_addr = account_entry.key_ptr.*;
            var pos_it = account_entry.value_ptr.positions.iterator();
            while (pos_it.next()) |pos_entry| {
                const pos = pos_entry.value_ptr.*;
                const mark_px = self.perp.markPrice(pos.asset_id) orelse pos.entry_price;
                const maintenance = maintenanceMarginRequired(pos.size, mark_px);
                const equity = self.accountEquity(account_entry.value_ptr, pos.asset_id);
                if (equity < maintenance) {
                    const event = shared.types.LiquidationEvent{
                        .user = account_addr,
                        .asset_id = pos.asset_id,
                        .size = pos.size,
                        .side = pos.side,
                        .mark_px = mark_px,
                    };
                    try self.perp.liquidation_center.enqueue(event);
                    try events.append(self.allocator, event);
                }
            }
        }

        return events.toOwnedSlice(self.allocator);
    }

    pub fn liquidate(
        self: *RiskEngine,
        event: shared.types.LiquidationEvent,
        state: *state_mod.GlobalState,
    ) !void {
        _ = state;
        var account = self.accounts.getPtr(event.user) orelse return RiskError.PositionNotFound;
        const pos = account.positions.get(event.asset_id) orelse return RiskError.PositionNotFound;
        _ = self.perp.liquidation_center.execute(event, pos.entry_price);
        _ = account.positions.remove(event.asset_id);
        try self.refreshExposure(event.asset_id);
    }

    pub fn adl(
        self: *RiskEngine,
        asset_id: shared.types.AssetId,
        side: shared.types.Side,
        state: *state_mod.GlobalState,
    ) !void {
        _ = state;
        var candidates = std.ArrayList(struct { addr: shared.types.Address, rank: f64 }).init(self.allocator);
        defer candidates.deinit();

        var accounts_it = self.accounts.iterator();
        while (accounts_it.next()) |entry| {
            if (entry.value_ptr.positions.get(asset_id)) |pos| {
                if (pos.side != side) continue;
                const mark_px = self.perp.markPrice(pos.asset_id) orelse pos.entry_price;
                const rank = adlRank(&pos, mark_px);
                try candidates.append(.{ .addr = entry.key_ptr.*, .rank = rank });
            }
        }

        if (candidates.items.len == 0) return;

        std.sort.blocking(
            struct { addr: shared.types.Address, rank: f64 },
            candidates.items,
            {},
            struct {
                fn lessThan(_: void, a: @This(), b: @This()) bool {
                    return a.rank > b.rank;
                }
            }.lessThan,
        );

        const top = candidates.items[0];
        const account_ptr = self.accounts.getPtr(top.addr);
        if (account_ptr) |acc| {
            if (acc.positions.getPtr(asset_id)) |pos| {
                const mark_px = self.perp.markPrice(asset_id) orelse pos.entry_price;
                const close_size = @min(pos.size, pos.size / 2 + 1);
                const pnl = perp_mod.PerpEngine.unrealizedPnl(pos, mark_px);
                if (pnl < 0 and self.perp.liquidation_center.insurance_fund + pnl < 0) {
                    self.perp.liquidation_center.adl_invocations += 1;
                }
                pos.size -= close_size;
                if (pos.size == 0) {
                    _ = acc.positions.remove(asset_id);
                }
            }
        }
    }

    pub fn getAccountHealth(
        self: *RiskEngine,
        addr: shared.types.Address,
        state: *state_mod.GlobalState,
    ) shared.types.AccountHealth {
        _ = state;
        const account = self.accounts.get(addr) orelse return .{
            .equity = 0,
            .maintenance_margin = 0,
        };

        var maintenance: shared.types.SignedAmount = 0;
        var pos_it = account.positions.iterator();
        while (pos_it.next()) |entry| {
            const pos = entry.value_ptr.*;
            const mark_px = self.perp.markPrice(pos.asset_id) orelse pos.entry_price;
            maintenance += maintenanceMarginRequired(pos.size, mark_px);
        }

        return .{
            .equity = self.accountEquity(&account, null),
            .maintenance_margin = maintenance,
        };
    }

    pub fn position(
        self: *const RiskEngine,
        addr: shared.types.Address,
        asset_id: shared.types.AssetId,
    ) ?shared.types.Position {
        const account = self.accounts.get(addr) orelse return null;
        return account.positions.get(asset_id);
    }

    pub fn onBookUpdate(
        self: *RiskEngine,
        asset_id: shared.types.AssetId,
        best_bid: ?shared.types.Price,
        best_ask: ?shared.types.Price,
        state: *state_mod.GlobalState,
    ) void {
        self.perp.updateMarkPriceFromBook(asset_id, best_bid, best_ask, state);
    }

    fn ensureAccount(self: *RiskEngine, addr: shared.types.Address) !*AccountLedger {
        const gop = try self.accounts.getOrPut(addr);
        if (!gop.found_existing) {
            gop.value_ptr.* = AccountLedger.init(self.allocator, DEFAULT_BALANCE);
        }
        return gop.value_ptr;
    }

    fn checkMarginBeforeTrade(
        self: *RiskEngine,
        addr: shared.types.Address,
        asset_id: shared.types.AssetId,
        is_buy: bool,
        fill_size: shared.types.Quantity,
        fill_px: shared.types.Price,
    ) !void {
        const account = self.accounts.getPtr(addr) orelse return;
        const existing_pos = account.positions.get(asset_id);

        if (existing_pos) |pos| {
            if (pos.side == (if (is_buy) shared.types.Side.long else .short)) {
                return;
            }
        }

        const im_req = initialMarginRequired(fill_size, fill_px);
        const equity: shared.types.SignedAmount = @intCast(account.balance);
        if (equity < im_req) {
            return RiskError.InsufficientMargin;
        }
    }

    fn applyTrade(
        self: *RiskEngine,
        addr: shared.types.Address,
        asset_id: shared.types.AssetId,
        is_buy: bool,
        fill_size: shared.types.Quantity,
        fill_px: shared.types.Price,
    ) !void {
        const account = try self.ensureAccount(addr);
        const entry = try account.positions.getOrPut(asset_id);
        if (!entry.found_existing) {
            entry.value_ptr.* = .{
                .user = addr,
                .asset_id = asset_id,
                .side = if (is_buy) .long else .short,
                .size = fill_size,
                .entry_price = fill_px,
                .isolated_margin = 0,
                .leverage = 1,
            };
            return;
        }

        var pos = entry.value_ptr;
        if (pos.side == (if (is_buy) shared.types.Side.long else .short)) {
            const total_size = pos.size + fill_size;
            const weighted = (@as(u512, pos.entry_price) * @as(u512, pos.size)) +
                (@as(u512, fill_px) * @as(u512, fill_size));
            pos.entry_price = @intCast(weighted / @as(u512, total_size));
            pos.size = total_size;
            return;
        }

        if (fill_size < pos.size) {
            pos.size -= fill_size;
            pos.unrealized_pnl = perp_mod.PerpEngine.unrealizedPnl(pos, fill_px);
            return;
        }

        if (fill_size == pos.size) {
            _ = account.positions.remove(asset_id);
            return;
        }

        pos.side = if (is_buy) .long else .short;
        pos.size = fill_size - pos.size;
        pos.entry_price = fill_px;
        pos.unrealized_pnl = 0;
    }

    fn refreshExposure(self: *RiskEngine, asset_id: shared.types.AssetId) !void {
        var long_notional: shared.types.Price = 0;
        var short_notional: shared.types.Price = 0;

        var accounts_it = self.accounts.iterator();
        while (accounts_it.next()) |account_entry| {
            if (account_entry.value_ptr.positions.get(asset_id)) |pos| {
                const notional = positionNotional(pos.size, pos.entry_price);
                switch (pos.side) {
                    .long => long_notional += notional,
                    .short => short_notional += notional,
                }
            }
        }

        try self.perp.setOpenInterest(asset_id, long_notional, short_notional);
    }

    fn accountEquity(
        self: *RiskEngine,
        account: *const AccountLedger,
        only_asset: ?shared.types.AssetId,
    ) shared.types.SignedAmount {
        var equity: shared.types.SignedAmount = @intCast(account.balance);
        var pos_it = account.positions.iterator();
        while (pos_it.next()) |entry| {
            const pos = entry.value_ptr.*;
            if (only_asset) |asset_id| {
                if (asset_id != pos.asset_id) continue;
            }
            const mark_px = self.perp.markPrice(pos.asset_id) orelse pos.entry_price;
            equity += perp_mod.PerpEngine.unrealizedPnl(&pos, mark_px);
        }
        return equity;
    }
};

fn positionNotional(size: shared.types.Quantity, price: shared.types.Price) shared.types.Price {
    return @intCast((@as(u512, size) * @as(u512, price)) / @as(u512, shared.types.PRICE_SCALE));
}

fn maintenanceMarginRequired(size: shared.types.Quantity, price: shared.types.Price) shared.types.SignedAmount {
    const notional = positionNotional(size, price);
    return @intCast(@divTrunc((@as(i512, @intCast(notional)) * MAINTENANCE_BPS), BPS_SCALE));
}

fn initialMarginRequired(size: shared.types.Quantity, price: shared.types.Price) shared.types.SignedAmount {
    const notional = positionNotional(size, price);
    const im_bps: i256 = 1000;
    return @intCast(@divTrunc((@as(i512, @intCast(notional)) * im_bps), BPS_SCALE));
}

pub fn adlRank(pos: *const shared.types.Position, mark_px: shared.types.Price) f64 {
    const upnl_f: f64 = @floatFromInt(perp_mod.PerpEngine.unrealizedPnl(pos, mark_px));
    const size_f: f64 = @floatFromInt(pos.size);
    const mark_f: f64 = @floatFromInt(mark_px);
    const margin_f: f64 = @floatFromInt(pos.isolated_margin);
    if (margin_f == 0 or mark_f == 0 or size_f == 0) return 0;
    const notional = size_f * mark_f / @as(f64, @floatFromInt(shared.types.PRICE_SCALE));
    const pnl_ratio = upnl_f / notional;
    const leverage = notional / margin_f;
    return pnl_ratio * leverage;
}

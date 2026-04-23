const std = @import("std");
const shared = @import("../shared/mod.zig");
const perp_mod = @import("engine/perp.zig");
const risk_mod = @import("engine/risk.zig");

pub const GlobalState = struct {
    allocator: std.mem.Allocator,
    block_height: u64 = 0,
    state_root: [32]u8 = [_]u8{0} ** 32,
    timestamp: i64 = 0,
    accounts: std.AutoHashMap(shared.types.Address, AccountEntry),
    oracle_prices: std.AutoHashMap(shared.types.AssetId, shared.types.Price),
    funding_history: std.AutoHashMap(shared.types.AssetId, std.ArrayList(FundingRecord)),
    perp_engine: perp_mod.PerpEngine,
    risk_engine: risk_mod.RiskEngine,

    pub fn init(allocator: std.mem.Allocator) !GlobalState {
        var perp = perp_mod.PerpEngine.init(allocator);
        errdefer perp.deinit();

        var risk = risk_mod.RiskEngine.init(&perp, allocator);
        errdefer risk.deinit();

        return .{
            .allocator = allocator,
            .accounts = std.AutoHashMap(shared.types.Address, AccountEntry).init(allocator),
            .oracle_prices = std.AutoHashMap(shared.types.AssetId, shared.types.Price).init(allocator),
            .funding_history = std.AutoHashMap(shared.types.AssetId, std.ArrayList(FundingRecord)).init(allocator),
            .perp_engine = perp,
            .risk_engine = risk,
        };
    }

    pub fn deinit(self: *GlobalState) void {
        var it = self.funding_history.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.funding_history.deinit();
        self.oracle_prices.deinit();
        var accounts_it = self.accounts.iterator();
        while (accounts_it.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.accounts.deinit();
        self.risk_engine.deinit();
        self.perp_engine.deinit();
    }

    pub fn bumpBlock(self: *GlobalState) void {
        self.block_height += 1;
        self.timestamp += 1;
        self.state_root[0] +%= 1;
    }

    pub fn getAccount(self: *GlobalState, addr: shared.types.Address) ?*AccountEntry {
        return self.accounts.getPtr(addr);
    }

    pub fn getOrCreateAccount(self: *GlobalState, addr: shared.types.Address) !*AccountEntry {
        const gop = try self.accounts.getOrPut(addr);
        if (!gop.found_existing) {
            gop.value_ptr.* = AccountEntry.init(self.allocator, addr);
        }
        return gop.value_ptr;
    }

    pub fn setOraclePrice(self: *GlobalState, asset_id: shared.types.AssetId, price: shared.types.Price) !void {
        try self.oracle_prices.put(asset_id, price);
        try self.perp_engine.setIndexPrice(asset_id, price);
    }

    pub fn getOraclePrice(self: *GlobalState, asset_id: shared.types.AssetId) ?shared.types.Price {
        return self.oracle_prices.get(asset_id);
    }

    pub fn recordFunding(self: *GlobalState, asset_id: shared.types.AssetId, event: shared.types.FundingEvent) !void {
        const gop = try self.funding_history.getOrPut(asset_id);
        if (!gop.found_existing) {
            gop.value_ptr.* = std.ArrayList(FundingRecord).init(self.allocator);
        }
        try gop.value_ptr.append(FundingRecord{
            .rate_bps = event.rate_bps,
            .long_payment = event.long_payment,
            .short_payment = event.short_payment,
            .timestamp = self.timestamp,
        });
    }
};

pub const AccountEntry = struct {
    address: shared.types.Address,
    balance: shared.types.Amount,
    positions: std.AutoHashMap(shared.types.AssetId, shared.types.Position),
    open_orders: std.AutoHashMap(u64, shared.types.Order),
    api_wallet: ?shared.types.Address,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, addr: shared.types.Address) AccountEntry {
        return .{
            .address = addr,
            .balance = 0,
            .positions = std.AutoHashMap(shared.types.AssetId, shared.types.Position).init(allocator),
            .open_orders = std.AutoHashMap(u64, shared.types.Order).init(allocator),
            .api_wallet = null,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *AccountEntry) void {
        self.open_orders.deinit();
        self.positions.deinit();
    }
};

pub const FundingRecord = struct {
    rate_bps: i64,
    long_payment: shared.types.SignedAmount,
    short_payment: shared.types.SignedAmount,
    timestamp: i64,
};

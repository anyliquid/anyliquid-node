const std = @import("std");
const shared = @import("../../shared/mod.zig");
const types = @import("types.zig");

pub const SubAccount = struct {
    index: u8,
    address: shared.types.Address,
    master: shared.types.Address,
    master_mode: types.AccountMode,
    label: ?[32]u8,
    collateral: CollateralPool,
    positions: std.AutoHashMap(types.InstrumentId, types.Position),
    margin: types.MarginSummary,
    borrows: std.AutoHashMap(types.AssetId, types.BorrowPosition),
    created_at: i64,
    allocator: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator, index: u8, address: shared.types.Address, master: shared.types.Address, master_mode: types.AccountMode, label: ?[32]u8, now_ms: i64) SubAccount {
        return .{
            .index = index,
            .address = address,
            .master = master,
            .master_mode = master_mode,
            .label = label,
            .collateral = CollateralPool.init(alloc),
            .positions = std.AutoHashMap(types.InstrumentId, types.Position).init(alloc),
            .margin = .{
                .mode = .standard,
                .total_equity = 0,
                .initial_margin_used = 0,
                .maintenance_margin = 0,
                .available_balance = 0,
                .transfer_margin_req = 0,
                .margin_ratio = 0,
                .health = .healthy,
                .collateral_breakdown = &.{},
            },
            .borrows = std.AutoHashMap(types.AssetId, types.BorrowPosition).init(alloc),
            .created_at = now_ms,
            .allocator = alloc,
        };
    }

    pub fn deinit(self: *SubAccount) void {
        self.collateral.deinit();
        self.positions.deinit();
        self.borrows.deinit();
    }

    pub fn hasOpenPositions(self: *const SubAccount) bool {
        return self.positions.count() > 0;
    }

    pub fn hasCollateral(self: *const SubAccount) bool {
        const registry = types.defaultCollateralRegistry;
        return self.collateral.effectiveTotal(&registry) > 0;
    }

    pub fn isEmpty(self: *const SubAccount) bool {
        return !self.hasOpenPositions() and !self.hasCollateral();
    }

    pub fn unrealizedPnl(self: *const SubAccount, markPriceFn: *const fn (types.InstrumentId) ?shared.types.Price) shared.types.SignedAmount {
        var total: shared.types.SignedAmount = 0;
        var it = self.positions.iterator();
        while (it.next()) |entry| {
            const pos = entry.value_ptr;
            if (markPriceFn(pos.instrument_id)) |mark_px| {
                total += pos.unrealizedPnl(mark_px);
            }
        }
        return total;
    }
};

pub const MasterAccount = struct {
    address: shared.types.Address,
    sub_accounts: [types.MAX_SUB_ACCOUNTS]?SubAccount,
    mode_config: types.AccountModeConfig,
    permissions: types.MasterPermissions,
    daily_actions: types.DailyActionCounter,
    allocator: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator, address: shared.types.Address, now_ms: i64) MasterAccount {
        var sub_accounts: [types.MAX_SUB_ACCOUNTS]?SubAccount = undefined;
        var i: usize = 0;
        while (i < types.MAX_SUB_ACCOUNTS) : (i += 1) {
            sub_accounts[i] = null;
        }
        return .{
            .address = address,
            .sub_accounts = sub_accounts,
            .mode_config = .{ .mode = .standard, .changed_at = now_ms },
            .permissions = .{ .global_agents = &.{} },
            .daily_actions = .{ .count = 0, .reset_at_ms = nextMidnightUtc(now_ms) },
            .allocator = alloc,
        };
    }

    pub fn deinit(self: *MasterAccount) void {
        var i: usize = 0;
        while (i < types.MAX_SUB_ACCOUNTS) : (i += 1) {
            if (self.sub_accounts[i]) |*sub| {
                sub.deinit();
            }
        }
    }

    pub fn openSubAccount(self: *MasterAccount, index: u8, label: ?[32]u8, now_ms: i64) !*SubAccount {
        if (index >= types.MAX_SUB_ACCOUNTS) return error.InvalidSubAccountIndex;
        if (self.sub_accounts[index] != null) return error.SubAccountAlreadyExists;

        const addr = types.deriveSubAccountAddress(self.address, index);
        self.sub_accounts[index] = SubAccount.init(self.allocator, index, addr, self.address, self.mode_config.mode, label, now_ms);
        return &self.sub_accounts[index].?;
    }

    pub fn closeSubAccount(self: *MasterAccount, index: u8) !void {
        if (index >= types.MAX_SUB_ACCOUNTS) return error.InvalidSubAccountIndex;
        if (self.sub_accounts[index]) |*sub| {
            if (!sub.isEmpty()) return error.SubAccountNotEmpty;
            sub.deinit();
            self.sub_accounts[index] = null;
        } else {
            return error.SubAccountNotFound;
        }
    }

    pub fn subAccountByIndex(self: *MasterAccount, index: u8) ?*SubAccount {
        if (index >= types.MAX_SUB_ACCOUNTS) return null;
        if (self.sub_accounts[index]) |*sub| return sub;
        return null;
    }

    pub fn subAccountByAddr(self: *MasterAccount, addr: shared.types.Address) ?*SubAccount {
        var i: usize = 0;
        while (i < types.MAX_SUB_ACCOUNTS) : (i += 1) {
            if (self.sub_accounts[i]) |*sub| {
                if (std.mem.eql(u8, &sub.address, &addr)) return sub;
            }
        }
        return null;
    }

    pub fn subAccountCount(self: *const MasterAccount) u8 {
        var count: u8 = 0;
        var i: usize = 0;
        while (i < types.MAX_SUB_ACCOUNTS) : (i += 1) {
            if (self.sub_accounts[i] != null) count += 1;
        }
        return count;
    }
};

pub const CollateralPool = struct {
    allocator: std.mem.Allocator,
    assets: std.AutoHashMap(types.AssetId, shared.types.Quantity),

    pub fn init(alloc: std.mem.Allocator) CollateralPool {
        return .{
            .allocator = alloc,
            .assets = std.AutoHashMap(types.AssetId, shared.types.Quantity).init(alloc),
        };
    }

    pub fn deinit(self: *CollateralPool) void {
        self.assets.deinit();
    }

    pub fn deposit(self: *CollateralPool, asset_id: types.AssetId, amount: shared.types.Quantity, registry: types.CollateralRegistry) !void {
        const entry = findEntry(registry, asset_id) orelse return error.AssetNotEligible;
        if (!entry.enabled) return error.AssetNotEligible;

        const current = self.assets.get(asset_id) orelse 0;
        const new_balance = current + amount;

        const total_effective = self.effectiveTotal(registry);
        const new_effective = effectiveValue(registry, asset_id, new_balance);
        if (total_effective > 0 and new_effective > 0) {
            const concentration = @as(f64, @floatFromInt(new_effective)) / @as(f64, @floatFromInt(total_effective + new_effective));
            if (concentration > entry.max_pct) return error.MaxConcentrationExceeded;
        }

        try self.assets.put(asset_id, new_balance);
    }

    pub fn withdraw(self: *CollateralPool, asset_id: types.AssetId, amount: shared.types.Quantity) !void {
        const current = self.assets.get(asset_id) orelse return error.InsufficientBalance;
        if (current < amount) return error.InsufficientBalance;
        if (current == amount) {
            _ = self.assets.remove(asset_id);
        } else {
            try self.assets.put(asset_id, current - amount);
        }
    }

    pub fn effectiveTotal(self: *const CollateralPool, registry: types.CollateralRegistry) shared.types.Quantity {
        var total: shared.types.Quantity = 0;
        var it = self.assets.iterator();
        while (it.next()) |entry| {
            total += effectiveValue(registry, entry.key_ptr.*, entry.value_ptr.*);
        }
        return total;
    }

    pub fn rawBalance(self: *const CollateralPool, asset_id: types.AssetId) shared.types.Quantity {
        return self.assets.get(asset_id) orelse 0;
    }

    pub fn debitEffective(self: *CollateralPool, amount: shared.types.Quantity, registry: types.CollateralRegistry) !void {
        const total = self.effectiveTotal(registry);
        if (total < amount) return error.InsufficientCollateral;

        var sorted = std.ArrayList(struct { asset_id: types.AssetId, haircut: f64, balance: shared.types.Quantity }).init(self.allocator);
        defer sorted.deinit();

        var it = self.assets.iterator();
        while (it.next()) |entry| {
            if (findEntry(registry, entry.key_ptr.*)) |e| {
                try sorted.append(.{ .asset_id = entry.key_ptr.*, .haircut = e.haircut_pct, .balance = entry.value_ptr.* });
            }
        }

        std.mem.sort(struct { asset_id: types.AssetId, haircut: f64, balance: shared.types.Quantity }, sorted.items, {}, struct {
            fn lessThan(_: void, a: @This(), b: @This()) bool {
                return a.haircut < b.haircut;
            }
        }.lessThan);

        var remaining = amount;
        for (sorted.items) |item| {
            if (remaining == 0) break;
            const eff = effectiveValue(registry, item.asset_id, item.balance);
            const to_debit = @min(eff, remaining);
            const raw_to_debit = if (eff > 0) @divTrunc(to_debit * item.balance, eff) else 0;
            const current = self.assets.get(item.asset_id) orelse 0;
            if (raw_to_debit >= current) {
                _ = self.assets.remove(item.asset_id);
            } else {
                self.assets.put(item.asset_id, current - raw_to_debit) catch {};
            }
            remaining -= to_debit;
        }
    }

    pub fn credit(self: *CollateralPool, asset_id: types.AssetId, amount: shared.types.Quantity) void {
        const current = self.assets.get(asset_id) orelse 0;
        self.assets.put(asset_id, current + amount) catch {};
    }

    pub fn snapshot(self: *const CollateralPool, registry: types.CollateralRegistry, alloc: std.mem.Allocator) ![]types.AssetBalance {
        var result = std.ArrayList(types.AssetBalance).init(alloc);
        errdefer result.deinit();

        var it = self.assets.iterator();
        while (it.next()) |entry| {
            const eff = effectiveValue(registry, entry.key_ptr.*, entry.value_ptr.*);
            try result.append(.{
                .asset_id = entry.key_ptr.*,
                .raw_amount = entry.value_ptr.*,
                .effective_usdc = eff,
            });
        }

        return try result.toOwnedSlice();
    }
};

fn findEntry(registry: types.CollateralRegistry, asset_id: types.AssetId) ?*const types.CollateralEntry {
    for (registry) |*entry| {
        if (entry.asset_id == asset_id) return entry;
    }
    return null;
}

fn effectiveValue(registry: types.CollateralRegistry, asset_id: types.AssetId, amount: shared.types.Quantity) shared.types.Quantity {
    if (findEntry(registry, asset_id)) |entry| {
        const haircut_factor = 1.0 - entry.haircut_pct;
        return @intFromFloat(@as(f64, @floatFromInt(amount)) * haircut_factor);
    }
    return 0;
}

fn nextMidnightUtc(now_ms: i64) i64 {
    const ms_per_day: i64 = 86_400_000;
    const day_start = @divTrunc(now_ms, ms_per_day) * ms_per_day;
    return day_start + ms_per_day;
}

test "deriveSubAccountAddress - deterministic and unique" {
    const master_a = [_]u8{0xAA} ** 20;
    const a0 = types.deriveSubAccountAddress(master_a, 0);
    const a1 = types.deriveSubAccountAddress(master_a, 1);
    try std.testing.expect(!std.mem.eql(u8, &a0, &a1));
    try std.testing.expect(std.mem.eql(u8, &a0, &types.deriveSubAccountAddress(master_a, 0)));
}

test "openSubAccount - creates isolated empty state" {
    const alloc = std.testing.allocator;
    const master_addr = [_]u8{0xAA} ** 20;
    var master = MasterAccount.init(alloc, master_addr, 0);
    defer master.deinit();

    const sub = try master.openSubAccount(1, null, 0);
    try std.testing.expect(sub.isEmpty());
    try std.testing.expect(std.mem.eql(u8, &sub.address, &types.deriveSubAccountAddress(master_addr, 1)));
}

test "closeSubAccount - fails if collateral present" {
    const alloc = std.testing.allocator;
    const master_addr = [_]u8{0xAA} ** 20;
    var master = MasterAccount.init(alloc, master_addr, 0);
    defer master.deinit();

    _ = try master.openSubAccount(2, null, 0);
    const sub = master.subAccountByIndex(2).?;
    try sub.collateral.deposit(types.USDC_ID, 1_000 * types.USDC, &types.defaultCollateralRegistry);
    try std.testing.expectError(error.SubAccountNotEmpty, master.closeSubAccount(2));
}

test "effectiveTotal - USDC at 1:1" {
    const alloc = std.testing.allocator;
    var pool = CollateralPool.init(alloc);
    defer pool.deinit();

    try pool.deposit(types.USDC_ID, 10_000 * types.USDC, &types.defaultCollateralRegistry);
    try std.testing.expectEqual(10_000 * types.USDC, pool.effectiveTotal(&types.defaultCollateralRegistry));
}

test "effectiveTotal - BTC with 10% haircut" {
    const alloc = std.testing.allocator;
    var pool = CollateralPool.init(alloc);
    defer pool.deinit();

    try pool.deposit(types.BTC_ID, 1 * types.BTC, &types.defaultCollateralRegistry);
    const eff = pool.effectiveTotal(&types.defaultCollateralRegistry);
    try std.testing.expect(eff == 90_000_000);
}

test "deposit exceeds max concentration - rejected" {
    const alloc = std.testing.allocator;
    var pool = CollateralPool.init(alloc);
    defer pool.deinit();

    try pool.deposit(types.USDC_ID, 1_000 * types.USDC, &types.defaultCollateralRegistry);
    try std.testing.expectError(error.MaxConcentrationExceeded, pool.deposit(types.HYPE_ID, 1_000_000 * types.HYPE, &types.defaultCollateralRegistry));
}

test "debitEffective - USDC consumed first" {
    const alloc = std.testing.allocator;
    var pool = CollateralPool.init(alloc);
    defer pool.deinit();

    try pool.deposit(types.USDC_ID, 5_000 * types.USDC, &types.defaultCollateralRegistry);
    try pool.deposit(types.BTC_ID, 1 * types.BTC, &types.defaultCollateralRegistry);
    try pool.debitEffective(3_000 * types.USDC, &types.defaultCollateralRegistry);
    try std.testing.expectEqual(2_000 * types.USDC, pool.rawBalance(types.USDC_ID));
    try std.testing.expectEqual(1 * types.BTC, pool.rawBalance(types.BTC_ID));
}

test "withdraw insufficient balance - rejected" {
    const alloc = std.testing.allocator;
    var pool = CollateralPool.init(alloc);
    defer pool.deinit();

    try pool.deposit(types.USDC_ID, 1_000 * types.USDC, &types.defaultCollateralRegistry);
    try std.testing.expectError(error.InsufficientBalance, pool.withdraw(types.USDC_ID, 2_000 * types.USDC));
}

test "credit increases balance" {
    const alloc = std.testing.allocator;
    var pool = CollateralPool.init(alloc);
    defer pool.deinit();

    pool.credit(types.USDC_ID, 5_000 * types.USDC);
    try std.testing.expectEqual(5_000 * types.USDC, pool.rawBalance(types.USDC_ID));
}

test "liquidation isolation - sub 0 liq does not touch sub 1" {
    const alloc = std.testing.allocator;
    const master_addr = [_]u8{0xAA} ** 20;
    var master = MasterAccount.init(alloc, master_addr, 0);
    defer master.deinit();

    const sub0 = try master.openSubAccount(0, null, 0);
    try sub0.collateral.deposit(types.USDC_ID, 100 * types.USDC, &types.defaultCollateralRegistry);

    const sub1 = try master.openSubAccount(1, null, 0);
    try sub1.collateral.deposit(types.USDC_ID, 10_000 * types.USDC, &types.defaultCollateralRegistry);

    try std.testing.expectEqual(10_000 * types.USDC, sub1.collateral.rawBalance(types.USDC_ID));
}

const std = @import("std");
const shared = @import("../../shared/mod.zig");
const types = @import("types.zig");
const account = @import("account.zig");

/// AccountModeManager handles account mode changes and validation.
pub const AccountModeManager = struct {
    allocator: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) AccountModeManager {
        return .{
            .allocator = alloc,
        };
    }

    /// Set account mode - validates constraints before applying.
    pub fn setAccountMode(
        _: *AccountModeManager,
        master: *account.MasterAccount,
        new_mode: types.AccountMode,
        now_ms: i64,
        weighted_volume: shared.types.Quantity,
        has_active_builder_code: bool,
    ) !types.AccountModeChangedEvent {
        // Reject deprecated mode
        if (new_mode == .dex_abstraction) return error.ModeDeprecated;

        // Validate portfolio margin volume requirement
        if (new_mode == .portfolio_margin and weighted_volume < 5_000_000 * types.USDC) {
            return error.InsufficientVolume;
        }

        // Validate builder code constraint
        if (has_active_builder_code and new_mode != .standard) {
            return error.BuilderCodeRequiresStandard;
        }

        const old_mode = master.mode_config.mode;

        // Mode change takes effect at next block boundary
        master.mode_config = .{
            .mode = new_mode,
            .changed_at = now_ms,
        };

        // Reset daily action counter on mode change
        master.daily_actions.count = 0;
        master.daily_actions.reset_at_ms = nextMidnightUtc(now_ms);

        // Update all sub-accounts with new mode
        var i: u8 = 0;
        while (i < types.MAX_SUB_ACCOUNTS) : (i += 1) {
            if (master.sub_accounts[i]) |*sub| {
                sub.master_mode = new_mode;
            }
        }

        return .{
            .master = master.address,
            .old_mode = old_mode,
            .new_mode = new_mode,
            .timestamp = now_ms,
        };
    }

    /// Check daily action limit before executing an action.
    pub fn checkDailyAction(
        _: *AccountModeManager,
        master: *account.MasterAccount,
        now_ms: i64,
    ) !void {
        const limit = master.mode_config.mode.dailyActionLimit();
        try master.daily_actions.check(limit, now_ms);
    }
};

fn nextMidnightUtc(now_ms: i64) i64 {
    const ms_per_day: i64 = 86_400_000;
    const day_start = @divTrunc(now_ms, ms_per_day) * ms_per_day;
    return day_start + ms_per_day;
}

test "set mode to dex_abstraction - rejected" {
    const alloc = std.testing.allocator;
    const master_addr = [_]u8{0xAA} ** 20;
    var master = account.MasterAccount.init(alloc, master_addr, 0);
    defer master.deinit();

    var manager = AccountModeManager.init(alloc);

    try std.testing.expectError(
        error.ModeDeprecated,
        manager.setAccountMode(&master, .dex_abstraction, 0, 0, false),
    );
}

test "set mode to portfolio_margin below volume threshold - rejected" {
    const alloc = std.testing.allocator;
    const master_addr = [_]u8{0xAA} ** 20;
    var master = account.MasterAccount.init(alloc, master_addr, 0);
    defer master.deinit();

    var manager = AccountModeManager.init(alloc);

    try std.testing.expectError(
        error.InsufficientVolume,
        manager.setAccountMode(&master, .portfolio_margin, 0, 1_000_000 * types.USDC, false),
    );
}

test "set mode to standard with builder code - allowed" {
    const alloc = std.testing.allocator;
    const master_addr = [_]u8{0xAA} ** 20;
    var master = account.MasterAccount.init(alloc, master_addr, 0);
    defer master.deinit();

    var manager = AccountModeManager.init(alloc);

    const event = try manager.setAccountMode(&master, .standard, 0, 0, true);
    try std.testing.expect(event.new_mode == .standard);
}

test "set mode to unified with builder code - rejected" {
    const alloc = std.testing.allocator;
    const master_addr = [_]u8{0xAA} ** 20;
    var master = account.MasterAccount.init(alloc, master_addr, 0);
    defer master.deinit();

    var manager = AccountModeManager.init(alloc);

    try std.testing.expectError(
        error.BuilderCodeRequiresStandard,
        manager.setAccountMode(&master, .unified, 0, 10_000_000 * types.USDC, true),
    );
}

test "daily action limit exceeded - rejected" {
    const alloc = std.testing.allocator;
    const master_addr = [_]u8{0xAA} ** 20;
    var master = account.MasterAccount.init(alloc, master_addr, 0);
    defer master.deinit();

    // Set to unified mode with 50k daily limit
    var manager = AccountModeManager.init(alloc);
    _ = try manager.setAccountMode(&master, .unified, 0, 10_000_000 * types.USDC, false);

    // Simulate 50k actions
    master.daily_actions.count = 50_000;
    const now_ms: i64 = 1_700_000_000_000;

    try std.testing.expectError(
        error.DailyActionLimitExceeded,
        manager.checkDailyAction(&master, now_ms),
    );
}

test "mode change resets daily action counter" {
    const alloc = std.testing.allocator;
    const master_addr = [_]u8{0xAA} ** 20;
    var master = account.MasterAccount.init(alloc, master_addr, 0);
    defer master.deinit();

    // Set some daily actions
    master.daily_actions.count = 1000;

    var manager = AccountModeManager.init(alloc);
    const now_ms: i64 = 1_700_000_000_000;

    _ = try manager.setAccountMode(&master, .unified, now_ms, 10_000_000 * types.USDC, false);

    try std.testing.expect(master.daily_actions.count == 0);
    try std.testing.expect(master.daily_actions.reset_at_ms > now_ms);
}

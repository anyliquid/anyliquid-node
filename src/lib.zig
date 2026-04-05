const std = @import("std");

pub const shared = @import("shared/mod.zig");
pub const api = @import("api/mod.zig");
pub const node = @import("node/mod.zig");

pub const App = struct {
    allocator: std.mem.Allocator,
    auth: api.Auth,
    cache: api.StateCache,
    gateway: api.Gateway,
    mempool: node.Mempool,
    store: node.Store,
    state: node.GlobalState,
    gateway_harness: ?api.InMemoryNodeHarness = null,
    connected: bool = false,

    pub fn init(allocator: std.mem.Allocator) !App {
        var cache = try api.StateCache.init(.{}, allocator);
        errdefer cache.deinit();

        var auth = try api.Auth.init(.{}, allocator);
        errdefer auth.deinit();

        var gateway = try api.Gateway.init(.{ .start_connected = false }, api.Gateway.noopEventSink(), allocator);
        errdefer gateway.deinit();

        var mempool = node.Mempool.init(.{}, allocator);
        errdefer mempool.deinit();

        var store = try node.Store.init(.{}, allocator);
        errdefer store.deinit();

        return .{
            .allocator = allocator,
            .auth = auth,
            .cache = cache,
            .gateway = gateway,
            .mempool = mempool,
            .store = store,
            .state = try node.GlobalState.init(allocator),
        };
    }

    pub fn deinit(self: *App) void {
        if (self.gateway_harness) |*harness| {
            harness.deinit();
        }
        self.store.deinit();
        self.mempool.deinit();
        self.gateway.deinit();
        self.cache.deinit();
        self.auth.deinit();
    }

    pub fn connect(self: *App) !void {
        if (self.connected) return;

        self.gateway.on_event = .{
            .ctx = &self.cache,
            .callback = cacheNodeEvent,
        };

        for (self.store.pendingTransactions()) |tx| {
            try self.mempool.add(tx);
        }

        self.mempool.setPersistence(&self.store, persistPendingTransaction);
        self.mempool.setConfirmation(&self.store, confirmPendingTransactions);
        self.gateway_harness = api.InMemoryNodeHarness.init(&self.state, &self.mempool, &self.store, self.allocator);
        self.gateway.transport = self.gateway_harness.?.transport();
        self.gateway.setConnected(true);
        self.connected = true;
    }

    pub fn writeOverview(self: *App, writer: anytype) !void {
        _ = self;
        try writer.print(
            "AnyLiquid Node scaffold\nzig: {s}\nthroughput target: {s}\n",
            .{ "0.15.2", "1,000,000 TPS" },
        );
    }
};

fn persistPendingTransaction(ctx: ?*anyopaque, tx: shared.types.Transaction) anyerror!void {
    const store: *node.Store = @ptrCast(@alignCast(ctx.?));
    try store.appendPendingTransaction(tx);
}

fn confirmPendingTransactions(ctx: ?*anyopaque, txs: []const shared.types.Transaction) anyerror!void {
    const store: *node.Store = @ptrCast(@alignCast(ctx.?));
    try store.removePendingTransactions(txs);
}

fn cacheNodeEvent(ctx: ?*anyopaque, event: shared.protocol.NodeEvent) void {
    const cache: *api.StateCache = @ptrCast(@alignCast(ctx.?));
    cache.applyEvent(event) catch {};
}

test {
    _ = @import("shared/fixed_point.zig");
    _ = @import("api/auth.zig");
    _ = @import("node/mempool.zig");
}

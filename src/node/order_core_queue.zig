const std = @import("std");
const shared = @import("../shared/mod.zig");

const TxKey = struct {
    user: shared.types.Address,
    nonce: u64,
};

pub const OrderCoreQueueError = error{
    DuplicateTx,
    QueueFull,
    UnsupportedAction,
} || std.mem.Allocator.Error;

pub const OrderCoreQueueConfig = struct {
    max_size: usize = 4096,
};

pub const OrderCoreQueue = struct {
    allocator: std.mem.Allocator,
    cfg: OrderCoreQueueConfig,
    cancel_txs: std.ArrayList(shared.types.Transaction),
    order_txs: std.ArrayList(shared.types.Transaction),
    keys: std.AutoHashMap(TxKey, void),

    pub fn init(cfg: OrderCoreQueueConfig, allocator: std.mem.Allocator) OrderCoreQueue {
        return .{
            .allocator = allocator,
            .cfg = cfg,
            .cancel_txs = .empty,
            .order_txs = .empty,
            .keys = std.AutoHashMap(TxKey, void).init(allocator),
        };
    }

    pub fn deinit(self: *OrderCoreQueue) void {
        for (self.cancel_txs.items) |*tx| {
            shared.serialization.deinitTransaction(self.allocator, tx);
        }
        for (self.order_txs.items) |*tx| {
            shared.serialization.deinitTransaction(self.allocator, tx);
        }
        self.keys.deinit();
        self.order_txs.deinit(self.allocator);
        self.cancel_txs.deinit(self.allocator);
    }

    pub fn enqueue(self: *OrderCoreQueue, tx: shared.types.Transaction) OrderCoreQueueError!void {
        if (!isOrderCoreAction(tx.action)) return error.UnsupportedAction;
        if (self.size() >= self.cfg.max_size) return error.QueueFull;

        const key = TxKey{ .user = tx.user, .nonce = tx.nonce };
        if (self.keys.contains(key)) return error.DuplicateTx;

        const owned = try shared.serialization.cloneTransaction(self.allocator, tx);
        errdefer shared.serialization.deinitTransaction(self.allocator, @constCast(&owned));
        try self.keys.put(key, {});

        if (isCancelAction(tx.action)) {
            try self.cancel_txs.append(self.allocator, owned);
        } else {
            try self.order_txs.append(self.allocator, owned);
        }
    }

    pub fn drainOwned(self: *OrderCoreQueue, allocator: std.mem.Allocator) ![]shared.types.Transaction {
        const total = self.size();
        if (total == 0) return &.{};

        const out = try allocator.alloc(shared.types.Transaction, total);
        errdefer allocator.free(out);

        var idx: usize = 0;
        for (self.cancel_txs.items) |tx| {
            out[idx] = tx;
            idx += 1;
        }
        for (self.order_txs.items) |tx| {
            out[idx] = tx;
            idx += 1;
        }

        self.cancel_txs.clearRetainingCapacity();
        self.order_txs.clearRetainingCapacity();
        self.keys.clearRetainingCapacity();
        return out;
    }

    pub fn size(self: *const OrderCoreQueue) usize {
        return self.cancel_txs.items.len + self.order_txs.items.len;
    }
};

pub fn isOrderCoreAction(action: shared.types.ActionPayload) bool {
    return switch (action) {
        .order, .batch_orders, .cancel, .batch_cancel, .cancel_by_cloid, .cancel_all => true,
        else => false,
    };
}

pub fn isCancelAction(action: shared.types.ActionPayload) bool {
    return switch (action) {
        .cancel, .batch_cancel, .cancel_by_cloid, .cancel_all => true,
        else => false,
    };
}

test "order-core queue drains cancels before new orders" {
    var queue = OrderCoreQueue.init(.{}, std.testing.allocator);
    defer queue.deinit();

    const order_tx = shared.types.Transaction{
        .action = .{ .order = .{
            .type = "order",
            .orders = &.{},
            .grouping = .none,
        } },
        .nonce = 1,
        .signature = .{ .r = [_]u8{0} ** 32, .s = [_]u8{0} ** 32, .v = 27 },
        .user = [_]u8{1} ** 20,
    };
    const cancel_tx = shared.types.Transaction{
        .action = .{ .cancel = .{ .order_id = 42 } },
        .nonce = 2,
        .signature = .{ .r = [_]u8{0} ** 32, .s = [_]u8{0} ** 32, .v = 27 },
        .user = [_]u8{1} ** 20,
    };

    try queue.enqueue(order_tx);
    try queue.enqueue(cancel_tx);

    const drained = try queue.drainOwned(std.testing.allocator);
    defer {
        for (drained, 0..) |_, idx| {
            shared.serialization.deinitTransaction(std.testing.allocator, &drained[idx]);
        }
        if (drained.len > 0) std.testing.allocator.free(drained);
    }

    try std.testing.expect(drained[0].action == .cancel);
    try std.testing.expect(drained[1].action == .order);
}

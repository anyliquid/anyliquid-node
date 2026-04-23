const std = @import("std");
const shared = @import("../shared/mod.zig");
const mempool_mod = @import("../node/mempool.zig");
const order_core_queue_mod = @import("../node/order_core_queue.zig");
const state_mod = @import("../node/state.zig");
const store_mod = @import("../node/store/mod.zig");
const executor_mod = @import("../node/executor.zig");

pub const GatewayError = error{
    InvalidResponse,
    NodeUnavailable,
    NodeTimeout,
    QueryUnsupported,
    ConnectionFailed,
};

pub const EventSink = struct {
    ctx: ?*anyopaque = null,
    callback: *const fn (?*anyopaque, shared.protocol.NodeEvent) void,

    pub fn emit(self: EventSink, event: shared.protocol.NodeEvent) void {
        self.callback(self.ctx, event);
    }
};

pub const Transport = struct {
    ctx: ?*anyopaque = null,
    round_trip_fn: *const fn (?*anyopaque, []const u8, std.mem.Allocator) anyerror![]u8,
    pump_fn: ?*const fn (?*anyopaque, *Gateway, std.mem.Allocator) anyerror!void = null,
};

pub const GatewayConfig = struct {
    start_connected: bool = true,
    socket_path: ?[]const u8 = null,
    timeout_ms: i64 = 5000,
    mock_ack: ?shared.protocol.ActionAck = null,
    transport: ?Transport = null,
};

const PendingRequest = struct {
    msg_id: u32,
    ack: ?shared.protocol.ActionAck = null,
    deadline_ms: i64,
    completed: bool = false,
};

const reconnect_delays = [_]u64{ 100, 500, 1000, 2000, 5000 };

pub const Gateway = struct {
    allocator: std.mem.Allocator,
    connected: bool,
    on_event: EventSink,
    transport: ?Transport,
    mock_ack: ?shared.protocol.ActionAck,
    next_msg_id: u32 = 1,
    last_action: ?shared.protocol.ActionRequest = null,
    socket_path: ?[]const u8,
    socket: ?std.posix.socket_t = null,
    timeout_ms: i64,
    pending_requests: std.AutoHashMap(u32, PendingRequest),
    reconnect_index: usize = 0,
    last_reconnect_attempt: i64 = 0,

    pub fn init(cfg: GatewayConfig, on_event: EventSink, allocator: std.mem.Allocator) !Gateway {
        return .{
            .allocator = allocator,
            .connected = cfg.start_connected,
            .on_event = on_event,
            .transport = cfg.transport,
            .mock_ack = cfg.mock_ack,
            .socket_path = cfg.socket_path,
            .timeout_ms = cfg.timeout_ms,
            .pending_requests = std.AutoHashMap(u32, PendingRequest).init(allocator),
        };
    }

    pub fn deinit(self: *Gateway) void {
        self.disconnect();
        if (self.last_action) |*last_action| {
            shared.serialization.deinitActionRequest(self.allocator, last_action);
        }
        var it = self.pending_requests.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.ack) |*ack| {
                shared.serialization.deinitActionAck(self.allocator, ack);
            }
        }
        self.pending_requests.deinit();
    }

    pub fn sendAction(self: *Gateway, req: shared.protocol.ActionRequest) GatewayError!shared.protocol.ActionAck {
        if (!self.connected) {
            return GatewayError.NodeUnavailable;
        }

        if (self.last_action) |*last_action| {
            shared.serialization.deinitActionRequest(self.allocator, last_action);
        }
        self.last_action = shared.serialization.cloneActionRequest(self.allocator, req) catch return GatewayError.InvalidResponse;

        if (self.mock_ack) |ack| {
            return ack;
        }

        const transport = self.transport orelse {
            if (self.socket_path) |path| {
                return try self.sendActionViaSocket(req, path);
            }
            return GatewayError.NodeUnavailable;
        };

        const payload = shared.serialization.encodeActionRequest(self.allocator, req) catch return GatewayError.InvalidResponse;
        defer self.allocator.free(payload);
        const frame = shared.serialization.encodeFrame(
            self.allocator,
            self.nextMessageId(),
            .action_req,
            payload,
        ) catch return GatewayError.InvalidResponse;
        defer self.allocator.free(frame);

        const response = transport.round_trip_fn(transport.ctx, frame, self.allocator) catch return GatewayError.NodeUnavailable;
        defer self.allocator.free(response);

        const decoded = shared.serialization.decodeFrame(response) catch return GatewayError.InvalidResponse;
        if (decoded.header.msg_type != @intFromEnum(shared.protocol.MsgType.action_ack)) {
            return GatewayError.InvalidResponse;
        }

        var ack = shared.serialization.decodeActionAck(self.allocator, decoded.payload) catch return GatewayError.InvalidResponse;
        defer shared.serialization.deinitActionAck(self.allocator, &ack);

        self.pump() catch {};
        return .{
            .status = ack.status,
            .order_id = ack.order_id,
            .error_msg = if (ack.error_msg) |msg| self.allocator.dupe(u8, msg) catch null else null,
        };
    }

    fn sendActionViaSocket(self: *Gateway, req: shared.protocol.ActionRequest, socket_path: []const u8) GatewayError!shared.protocol.ActionAck {
        const sock = std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM | std.posix.SOCK.NONBLOCK, 0) catch return GatewayError.ConnectionFailed;
        defer std.posix.close(sock);

        var path_buf = [_]u8{0} ** 104;
        @memcpy(path_buf[0..@min(socket_path.len, 103)], socket_path);
        var addr = std.posix.sockaddr.un{ .family = std.posix.AF.UNIX, .path = path_buf };

        std.posix.connect(sock, @ptrCast(&addr), @intCast(@sizeOf(std.posix.sa_family_t) + socket_path.len)) catch |err| {
            if (err != error.WouldBlock and err != error.InProgress) return GatewayError.ConnectionFailed;
        };

        const payload = shared.serialization.encodeActionRequest(self.allocator, req) catch return GatewayError.InvalidResponse;
        defer self.allocator.free(payload);
        const msg_id = self.nextMessageId();
        const frame = shared.serialization.encodeFrame(self.allocator, msg_id, .action_req, payload) catch return GatewayError.InvalidResponse;
        defer self.allocator.free(frame);

        _ = std.posix.write(sock, frame) catch return GatewayError.NodeUnavailable;

        const ack = try self.readAckFromSocket(sock, msg_id);
        return ack;
    }

    fn readAckFromSocket(self: *Gateway, sock: std.posix.socket_t, msg_id: u32) GatewayError!shared.protocol.ActionAck {
        var header_buf: [12]u8 = undefined;
        const start = std.time.milliTimestamp();

        while (true) {
            if (std.time.milliTimestamp() - start > self.timeout_ms) {
                return GatewayError.NodeTimeout;
            }

            const n = std.posix.read(sock, &header_buf) catch |err| {
                if (err == error.WouldBlock) {
                    std.Thread.sleep(10 * std.time.ns_per_ms);
                    continue;
                }
                return GatewayError.NodeUnavailable;
            };

            if (n < 12) {
                std.Thread.sleep(10 * std.time.ns_per_ms);
                continue;
            }

            const frame = shared.serialization.decodeFrame(&header_buf) catch continue;
            if (frame.header.msg_id != msg_id) continue;
            if (frame.header.msg_type != @intFromEnum(shared.protocol.MsgType.action_ack)) continue;

            var ack = shared.serialization.decodeActionAck(self.allocator, frame.payload) catch continue;
            defer shared.serialization.deinitActionAck(self.allocator, &ack);

            return .{
                .status = ack.status,
                .order_id = ack.order_id,
                .error_msg = if (ack.error_msg) |msg| self.allocator.dupe(u8, msg) catch null else null,
            };
        }
    }

    pub fn query(self: *Gateway, req: shared.protocol.QueryRequest) GatewayError!shared.protocol.QueryResponse {
        if (!self.connected) {
            return GatewayError.NodeUnavailable;
        }

        const payload = shared.serialization.encodeQueryRequest(self.allocator, req) catch return GatewayError.InvalidResponse;
        defer self.allocator.free(payload);

        const msg_id = self.nextMessageId();
        const frame = shared.serialization.encodeFrame(self.allocator, msg_id, .query_req, payload) catch return GatewayError.InvalidResponse;
        defer self.allocator.free(frame);

        if (self.transport) |transport| {
            const response = transport.round_trip_fn(transport.ctx, frame, self.allocator) catch return GatewayError.NodeUnavailable;
            defer self.allocator.free(response);

            const decoded = shared.serialization.decodeFrame(response) catch return GatewayError.InvalidResponse;
            if (decoded.header.msg_type != @intFromEnum(shared.protocol.MsgType.query_resp)) {
                return GatewayError.InvalidResponse;
            }

            return shared.serialization.decodeQueryResponse(self.allocator, decoded.payload) catch GatewayError.InvalidResponse;
        }

        if (self.socket_path) |path| {
            return try self.queryViaSocket(req, path, msg_id);
        }

        return GatewayError.QueryUnsupported;
    }

    fn queryViaSocket(self: *Gateway, req: shared.protocol.QueryRequest, socket_path: []const u8, msg_id: u32) GatewayError!shared.protocol.QueryResponse {
        const sock = std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM | std.posix.SOCK.NONBLOCK, 0) catch return GatewayError.ConnectionFailed;
        defer std.posix.close(sock);

        var path_buf = [_]u8{0} ** 104;
        @memcpy(path_buf[0..@min(socket_path.len, 103)], socket_path);
        var addr = std.posix.sockaddr.un{ .family = std.posix.AF.UNIX, .path = path_buf };

        std.posix.connect(sock, @ptrCast(&addr), @intCast(@sizeOf(std.posix.sa_family_t) + socket_path.len)) catch |err| {
            if (err != error.WouldBlock and err != error.InProgress) return GatewayError.ConnectionFailed;
        };

        const payload = shared.serialization.encodeQueryRequest(self.allocator, req) catch return GatewayError.InvalidResponse;
        defer self.allocator.free(payload);
        const frame = shared.serialization.encodeFrame(self.allocator, msg_id, .query_req, payload) catch return GatewayError.InvalidResponse;
        defer self.allocator.free(frame);

        _ = std.posix.write(sock, frame) catch return GatewayError.NodeUnavailable;

        return try self.readQueryResponseFromSocket(sock, msg_id);
    }

    fn readQueryResponseFromSocket(self: *Gateway, sock: std.posix.socket_t, msg_id: u32) GatewayError!shared.protocol.QueryResponse {
        var header_buf: [12]u8 = undefined;
        const start = std.time.milliTimestamp();

        while (true) {
            if (std.time.milliTimestamp() - start > self.timeout_ms) {
                return GatewayError.NodeTimeout;
            }

            const n = std.posix.read(sock, &header_buf) catch |err| {
                if (err == error.WouldBlock) {
                    std.Thread.sleep(10 * std.time.ns_per_ms);
                    continue;
                }
                return GatewayError.NodeUnavailable;
            };

            if (n < 12) {
                std.Thread.sleep(10 * std.time.ns_per_ms);
                continue;
            }

            const frame = shared.serialization.decodeFrame(&header_buf) catch continue;
            if (frame.header.msg_id != msg_id) continue;
            if (frame.header.msg_type != @intFromEnum(shared.protocol.MsgType.query_resp)) continue;

            return shared.serialization.decodeQueryResponse(self.allocator, frame.payload) catch GatewayError.InvalidResponse;
        }
    }

    pub fn isConnected(self: *const Gateway) bool {
        return self.connected;
    }

    pub fn setConnected(self: *Gateway, connected: bool) void {
        self.connected = connected;
        if (connected) {
            self.reconnect_index = 0;
        }
    }

    pub fn pump(self: *Gateway) !void {
        if (self.transport) |transport| {
            if (transport.pump_fn) |pump_fn| {
                try pump_fn(transport.ctx, self, self.allocator);
            }
        }
    }

    pub fn acceptIncomingFrame(self: *Gateway, frame_bytes: []const u8) GatewayError!void {
        const frame = shared.serialization.decodeFrame(frame_bytes) catch return GatewayError.InvalidResponse;
        switch (@as(shared.protocol.MsgType, @enumFromInt(frame.header.msg_type))) {
            .event_l2_book, .event_trades, .event_all_mids, .event_order_upd, .event_user, .event_fill, .event_liquidation, .event_funding => {
                var event = shared.serialization.decodeNodeEvent(self.allocator, frame.payload) catch return GatewayError.InvalidResponse;
                defer shared.serialization.deinitNodeEvent(self.allocator, &event);
                self.on_event.emit(event);
            },
            .action_ack => {
                if (frame.header.msg_id != 0) {
                    if (self.pending_requests.getPtr(frame.header.msg_id)) |pending| {
                        const ack = shared.serialization.decodeActionAck(self.allocator, frame.payload) catch return GatewayError.InvalidResponse;
                        pending.ack = ack;
                        pending.completed = true;
                    }
                }
            },
            else => return GatewayError.InvalidResponse,
        }
    }

    pub fn injectNodeEvent(self: *Gateway, event: shared.protocol.NodeEvent) void {
        const frame_type = frameTypeForEvent(event);
        const payload = shared.serialization.encodeNodeEvent(self.allocator, event) catch return;
        defer self.allocator.free(payload);
        const frame = shared.serialization.encodeFrame(self.allocator, 0, frame_type, payload) catch return;
        defer self.allocator.free(frame);
        self.acceptIncomingFrame(frame) catch {};
    }

    pub fn noopEventCallback(ctx: ?*anyopaque, event: shared.protocol.NodeEvent) void {
        _ = ctx;
        _ = event;
    }

    pub fn noopEventSink() EventSink {
        return .{ .callback = noopEventCallback };
    }

    fn nextMessageId(self: *Gateway) u32 {
        const current = self.next_msg_id;
        self.next_msg_id +%= 1;
        return current;
    }

    fn disconnect(self: *Gateway) void {
        if (self.socket) |sock| {
            std.posix.close(sock);
            self.socket = null;
        }
        self.connected = false;
    }

    fn tryReconnect(self: *Gateway) bool {
        const now = std.time.milliTimestamp();
        if (self.reconnect_index >= reconnect_delays.len) return false;

        const delay = reconnect_delays[self.reconnect_index];
        if (now - self.last_reconnect_attempt < @as(i64, @intCast(delay))) return false;

        self.last_reconnect_attempt = now;
        self.reconnect_index += 1;

        if (self.socket_path) |path| {
            const sock = std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0) catch return false;

            var path_buf = [_]u8{0} ** 104;
            @memcpy(path_buf[0..@min(path.len, 107)], path);
            var addr = std.posix.sockaddr.un{ .family = std.posix.AF.UNIX, .path = path_buf };

            std.posix.connect(sock, &addr.any, @sizeOf(std.posix.sa_family_t) + path.len) catch {
                std.posix.close(sock);
                return false;
            };

            if (self.socket) |old| std.posix.close(old);
            self.socket = sock;
            self.connected = true;
            self.reconnect_index = 0;
            return true;
        }

        return false;
    }
};

pub const InMemoryNodeHarness = struct {
    allocator: std.mem.Allocator,
    state: *state_mod.GlobalState,
    mempool: *mempool_mod.Mempool,
    store: *store_mod.Store,
    order_core_queue: order_core_queue_mod.OrderCoreQueue,
    executor: executor_mod.BlockExecutor,
    queued_events: std.ArrayList(shared.protocol.NodeEvent),

    pub fn init(
        state: *state_mod.GlobalState,
        mempool: *mempool_mod.Mempool,
        store: *store_mod.Store,
        allocator: std.mem.Allocator,
    ) InMemoryNodeHarness {
        return .{
            .allocator = allocator,
            .state = state,
            .mempool = mempool,
            .store = store,
            .order_core_queue = order_core_queue_mod.OrderCoreQueue.init(.{}, allocator),
            .executor = executor_mod.BlockExecutor.init(state, allocator) catch @panic("failed to init BlockExecutor"),
            .queued_events = .empty,
        };
    }

    pub fn deinit(self: *InMemoryNodeHarness) void {
        for (self.queued_events.items) |*event| {
            shared.serialization.deinitNodeEvent(self.allocator, event);
        }
        self.queued_events.deinit(self.allocator);
        self.order_core_queue.deinit();
        self.executor.deinit();
    }

    pub fn transport(self: *InMemoryNodeHarness) Transport {
        return .{
            .ctx = self,
            .round_trip_fn = roundTrip,
            .pump_fn = pump,
        };
    }

    pub fn creditCollateral(
        self: *InMemoryNodeHarness,
        user: shared.types.Address,
        asset_id: u64,
        amount: shared.types.Quantity,
    ) !void {
        try self.executor.creditCollateral(user, asset_id, amount);
    }

    fn roundTrip(ctx: ?*anyopaque, frame_bytes: []const u8, allocator: std.mem.Allocator) anyerror![]u8 {
        const self: *InMemoryNodeHarness = @ptrCast(@alignCast(ctx.?));
        const frame = try shared.serialization.decodeFrame(frame_bytes);
        switch (@as(shared.protocol.MsgType, @enumFromInt(frame.header.msg_type))) {
            .action_req => {
                var req = try shared.serialization.decodeActionRequest(allocator, frame.payload);
                defer shared.serialization.deinitActionPayload(allocator, &req.action);

                const ack = try self.handleAction(req);
                defer if (ack.error_msg) |msg| allocator.free(msg);

                const payload = try shared.serialization.encodeActionAck(allocator, ack);
                defer allocator.free(payload);
                return try shared.serialization.encodeFrame(allocator, frame.header.msg_id, .action_ack, payload);
            },
            .query_req => {
                const query = try shared.serialization.decodeQueryRequest(allocator, frame.payload);
                var response = try self.handleQuery(query, allocator);
                defer deinitQueryResponseLocal(allocator, &response);
                const payload = try shared.serialization.encodeQueryResponse(allocator, response);
                defer allocator.free(payload);
                return try shared.serialization.encodeFrame(allocator, frame.header.msg_id, .query_resp, payload);
            },
            else => return error.UnsupportedMessageType,
        }
    }

    fn pump(ctx: ?*anyopaque, gateway: *Gateway, allocator: std.mem.Allocator) anyerror!void {
        _ = allocator;
        const self: *InMemoryNodeHarness = @ptrCast(@alignCast(ctx.?));
        while (self.queued_events.items.len > 0) {
            var event = self.queued_events.orderedRemove(0);
            defer shared.serialization.deinitNodeEvent(self.allocator, &event);

            const payload = try shared.serialization.encodeNodeEvent(self.allocator, event);
            defer self.allocator.free(payload);
            const frame = try shared.serialization.encodeFrame(self.allocator, 0, frameTypeForEvent(event), payload);
            defer self.allocator.free(frame);
            try gateway.acceptIncomingFrame(frame);
        }
    }

    fn handleAction(self: *InMemoryNodeHarness, req: shared.protocol.ActionRequest) !shared.protocol.ActionAck {
        const tx = shared.types.Transaction{
            .action = req.action,
            .nonce = req.nonce,
            .signature = req.signature,
            .user = req.user,
        };
        const receipts = if (order_core_queue_mod.isOrderCoreAction(tx.action)) blk: {
            try self.order_core_queue.enqueue(tx);
            break :blk try self.executor.executeOrderCoreBlock(&self.order_core_queue, self.store, &self.queued_events);
        } else blk: {
            try self.mempool.add(tx);
            break :blk try self.executor.executePendingBlock(self.mempool, self.store, &self.queued_events);
        };
        defer executor_mod.deinitExecutionReceipts(self.allocator, receipts);

        for (receipts) |receipt| {
            if (std.mem.eql(u8, receipt.user[0..], req.user[0..]) and receipt.nonce == req.nonce) {
                return .{
                    .status = receipt.ack.status,
                    .order_id = receipt.ack.order_id,
                    .error_msg = if (receipt.ack.error_msg) |msg| try self.allocator.dupe(u8, msg) else null,
                };
            }
        }

        return error.MissingExecutionReceipt;
    }

    fn handleQuery(self: *InMemoryNodeHarness, query: shared.protocol.QueryRequest, allocator: std.mem.Allocator) !shared.protocol.QueryResponse {
        return switch (query) {
            .user_state => |addr| .{ .user_state = self.executor.queryUserState(allocator, addr) catch .{
                .address = addr,
                .balance = 0,
                .positions = &.{},
                .open_orders = &.{},
                .api_wallet = null,
            } },
            .open_orders => |addr| .{ .open_orders = self.executor.queryOpenOrders(allocator, addr) catch &.{} },
            .l2_book => |params| .{ .l2_book = self.executor.queryL2Book(allocator, params.asset_id, params.depth) catch .{
                .asset_id = params.asset_id,
                .seq = 0,
                .bids = &.{},
                .asks = &.{},
                .is_snapshot = true,
            } },
            .all_mids => .{ .all_mids = try self.executor.queryAllMids(allocator) },
        };
    }
};

fn deinitQueryResponseLocal(allocator: std.mem.Allocator, response: *shared.protocol.QueryResponse) void {
    switch (response.*) {
        .user_state => |*account| shared.serialization.deinitAccountState(allocator, account),
        .open_orders => |orders| if (orders.len > 0) allocator.free(orders),
        .l2_book => |*snapshot| shared.serialization.deinitL2Snapshot(allocator, snapshot),
        .all_mids => |*all_mids| all_mids.deinit(allocator),
        else => {},
    }
    response.* = undefined;
}

fn frameTypeForEvent(event: shared.protocol.NodeEvent) shared.protocol.MsgType {
    return switch (event) {
        .l2_book_update => .event_l2_book,
        .trade => .event_trades,
        .all_mids => .event_all_mids,
        .order_update => .event_order_upd,
        .user_update => .event_user,
        .liquidation => .event_liquidation,
        .funding => .event_funding,
    };
}

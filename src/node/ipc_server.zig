const std = @import("std");
const shared = @import("../shared/mod.zig");
const state_mod = @import("state.zig");
const mempool_mod = @import("mempool.zig");
const order_core_queue_mod = @import("order_core_queue.zig");
const store_mod = @import("store/mod.zig");
const executor_mod = @import("executor.zig");

pub const IpcConfig = struct {
    socket_path: []const u8 = "/tmp/anyliquid-node.sock",
    max_connections: usize = 64,
    send_buf_size: usize = 65536,
};

const IpcClient = struct {
    stream: std.posix.socket_t,
    send_buf: std.ArrayList(u8),
    pending_requests: std.AutoHashMap(u32, PendingRequest),
    allocator: std.mem.Allocator,

    const PendingRequest = struct {
        msg_id: u32,
        response_buf: []u8,
    };
};

pub const IpcServer = struct {
    allocator: std.mem.Allocator,
    cfg: IpcConfig,
    state: *state_mod.GlobalState,
    mempool: *mempool_mod.Mempool,
    store: *store_mod.Store,
    order_core_queue: order_core_queue_mod.OrderCoreQueue,
    executor: executor_mod.BlockExecutor,
    server_socket: ?std.posix.socket_t = null,
    clients: std.ArrayList(IpcClient),
    event_buf: std.ArrayList(shared.protocol.NodeEvent),
    running: bool = false,

    pub fn init(
        cfg: IpcConfig,
        state: *state_mod.GlobalState,
        mempool: *mempool_mod.Mempool,
        store: *store_mod.Store,
        allocator: std.mem.Allocator,
    ) !IpcServer {
        return .{
            .allocator = allocator,
            .cfg = cfg,
            .state = state,
            .mempool = mempool,
            .store = store,
            .order_core_queue = order_core_queue_mod.OrderCoreQueue.init(.{}, allocator),
            .executor = try executor_mod.BlockExecutor.init(state, allocator),
            .clients = .empty,
            .event_buf = .empty,
        };
    }

    pub fn deinit(self: *IpcServer) void {
        self.stop();
        for (self.clients.items) |*client| {
            client.send_buf.deinit(self.allocator);
            client.pending_requests.deinit();
            if (client.stream != 0) {
                std.posix.close(client.stream);
            }
        }
        self.clients.deinit(self.allocator);
        for (self.event_buf.items) |*event| {
            shared.serialization.deinitNodeEvent(self.allocator, event);
        }
        self.event_buf.deinit(self.allocator);
        self.order_core_queue.deinit();
        self.executor.deinit();
        if (self.server_socket) |sock| {
            std.posix.close(sock);
        }
        std.posix.unlink(self.cfg.socket_path) catch {};
    }

    pub fn start(self: *IpcServer) !void {
        std.posix.unlink(self.cfg.socket_path) catch {};

        const sock = try std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0);
        errdefer std.posix.close(sock);

        _ = std.posix.sockaddr.un{
            .family = std.posix.AF.UNIX,
            .path = undefined,
        };
        var path_buf = [_]u8{0} ** 104;
        const socket_path = self.cfg.socket_path;
        @memcpy(path_buf[0..@min(socket_path.len, 103)], socket_path);

        var unix_addr = std.posix.sockaddr.un{
            .family = std.posix.AF.UNIX,
            .path = path_buf,
        };

        try std.posix.bind(sock, @ptrCast(&unix_addr), @intCast(@sizeOf(std.posix.sa_family_t) + socket_path.len));
        try std.posix.listen(sock, 128);

        _ = try std.posix.fcntl(sock, std.posix.F.SETFL, 4);

        self.server_socket = sock;
        self.running = true;
    }

    pub fn stop(self: *IpcServer) void {
        self.running = false;
        if (self.server_socket) |sock| {
            std.posix.close(sock);
            self.server_socket = null;
        }
    }

    pub fn tick(self: *IpcServer) void {
        if (!self.running) return;
        self.acceptNewClients() catch {};
        self.processClientMessages() catch {};
    }

    pub fn broadcastEvents(self: *IpcServer, events: []const shared.protocol.NodeEvent) void {
        for (events) |event| {
            const payload = shared.serialization.encodeNodeEvent(self.allocator, event) catch continue;
            defer self.allocator.free(payload);

            const frame = shared.serialization.encodeFrame(
                self.allocator,
                0,
                frameTypeForEvent(event),
                payload,
            ) catch continue;
            defer self.allocator.free(frame);

            var idx: usize = 0;
            while (idx < self.clients.items.len) {
                const client = &self.clients.items[idx];
                client.send_buf.appendSlice(self.allocator, frame) catch {
                    _ = self.clients.orderedRemove(idx);
                    continue;
                };
                self.flushClient(client) catch {
                    _ = self.clients.orderedRemove(idx);
                    continue;
                };
                idx += 1;
            }
        }
    }

    fn acceptNewClients(self: *IpcServer) !void {
        const server_sock = self.server_socket orelse return;

        while (self.clients.items.len < self.cfg.max_connections) {
            var client_addr: std.posix.sockaddr = undefined;
            var client_addr_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr);

            const client_sock = std.posix.accept(server_sock, &client_addr, &client_addr_len, std.posix.SOCK.NONBLOCK) catch |err| {
                if (err == error.WouldBlock) return;
                return err;
            };

            try self.clients.append(self.allocator, .{
                .stream = client_sock,
                .send_buf = .empty,
                .pending_requests = std.AutoHashMap(u32, IpcClient.PendingRequest).init(self.allocator),
                .allocator = self.allocator,
            });
        }
    }

    fn processClientMessages(self: *IpcServer) !void {
        var idx: usize = 0;
        while (idx < self.clients.items.len) {
            const client = &self.clients.items[idx];
            const result = self.readClientFrame(client) catch |err| {
                if (err == error.WouldBlock) {
                    idx += 1;
                    continue;
                }
                _ = self.clients.orderedRemove(idx);
                continue;
            };

            if (result) |frame| {
                try self.handleFrame(client, frame);
            } else {
                idx += 1;
            }
        }
    }

    fn readClientFrame(self: *IpcServer, client: *IpcClient) !?shared.serialization.Frame {
        var header_buf: [12]u8 = undefined;
        const n = std.posix.read(client.stream, &header_buf) catch |err| {
            if (err == error.WouldBlock) return null;
            return err;
        };

        if (n == 0) return error.ConnectionClosed;
        if (n < 12) return error.IncompleteHeader;

        const frame = try shared.serialization.decodeFrame(&header_buf);

        if (frame.payload.len > 0) {
            const payload_buf = try self.allocator.alloc(u8, frame.payload.len);
            const pn = std.posix.read(client.stream, payload_buf) catch |err| {
                self.allocator.free(payload_buf);
                return err;
            };
            if (pn < frame.payload.len) {
                self.allocator.free(payload_buf);
                return error.IncompletePayload;
            }
        }

        return frame;
    }

    fn handleFrame(self: *IpcServer, client: *IpcClient, frame: shared.serialization.Frame) !void {
        switch (@as(shared.protocol.MsgType, @enumFromInt(frame.header.msg_type))) {
            .action_req => {
                var req = try shared.serialization.decodeActionRequest(self.allocator, frame.payload);
                defer shared.serialization.deinitActionPayload(self.allocator, &req.action);

                const tx = shared.types.Transaction{
                    .action = req.action,
                    .nonce = req.nonce,
                    .signature = req.signature,
                    .user = req.user,
                };
                const receipts = if (order_core_queue_mod.isOrderCoreAction(tx.action)) blk: {
                    try self.order_core_queue.enqueue(tx);
                    break :blk try self.executor.executeOrderCoreBlock(&self.order_core_queue, self.store, &self.event_buf);
                } else blk: {
                    try self.mempool.add(tx);
                    break :blk try self.executor.executePendingBlock(self.mempool, self.store, &self.event_buf);
                };
                defer executor_mod.deinitExecutionReceipts(self.allocator, receipts);

                var ack = shared.protocol.ActionAck{
                    .status = .rejected,
                    .order_id = null,
                    .error_msg = try self.allocator.dupe(u8, "MissingExecutionReceipt"),
                };
                defer shared.serialization.deinitActionAck(self.allocator, &ack);
                for (receipts) |receipt| {
                    if (std.mem.eql(u8, receipt.user[0..], req.user[0..]) and receipt.nonce == req.nonce) {
                        ack = .{
                            .status = receipt.ack.status,
                            .order_id = receipt.ack.order_id,
                            .error_msg = if (receipt.ack.error_msg) |msg| try self.allocator.dupe(u8, msg) else null,
                        };
                        break;
                    }
                }
                try self.sendAck(client, frame.header.msg_id, ack);
                self.broadcastQueuedEvents();
            },
            .query_req => {
                const query = try shared.serialization.decodeQueryRequest(self.allocator, frame.payload);
                var response = try self.handleQuery(query);
                defer deinitQueryResponseLocal(self.allocator, &response);
                try self.sendQueryResponse(client, frame.header.msg_id, response);
            },
            else => return error.UnsupportedMessageType,
        }
    }

    fn handleQuery(self: *IpcServer, query: shared.protocol.QueryRequest) !shared.protocol.QueryResponse {
        return switch (query) {
            .user_state => |addr| {
                return .{ .user_state = self.executor.queryUserState(self.allocator, addr) catch .{
                    .address = addr,
                    .balance = 0,
                    .positions = &.{},
                    .open_orders = &.{},
                    .api_wallet = null,
                } };
            },
            .open_orders => |addr| {
                return .{ .open_orders = self.executor.queryOpenOrders(self.allocator, addr) catch &.{} };
            },
            .l2_book => |params| .{ .l2_book = self.executor.queryL2Book(self.allocator, params.asset_id, params.depth) catch .{
                .asset_id = params.asset_id,
                .seq = 0,
                .bids = &.{},
                .asks = &.{},
                .is_snapshot = true,
            } },
            .all_mids => .{ .all_mids = try self.executor.queryAllMids(self.allocator) },
        };
    }

    fn sendAck(self: *IpcServer, client: *IpcClient, msg_id: u32, ack: shared.protocol.ActionAck) !void {
        const payload = try shared.serialization.encodeActionAck(self.allocator, ack);
        defer self.allocator.free(payload);
        const frame = try shared.serialization.encodeFrame(self.allocator, msg_id, .action_ack, payload);
        defer self.allocator.free(frame);
        try client.send_buf.appendSlice(self.allocator, frame);
        try self.flushClient(client);
    }

    fn sendQueryResponse(self: *IpcServer, client: *IpcClient, msg_id: u32, response: shared.protocol.QueryResponse) !void {
        const payload = try shared.serialization.encodeQueryResponse(self.allocator, response);
        defer self.allocator.free(payload);
        const frame = try shared.serialization.encodeFrame(self.allocator, msg_id, .query_resp, payload);
        defer self.allocator.free(frame);
        try client.send_buf.appendSlice(self.allocator, frame);
        try self.flushClient(client);
    }

    fn flushClient(self: *IpcServer, client: *IpcClient) !void {
        if (client.send_buf.items.len == 0) return;
        const written = std.posix.write(client.stream, client.send_buf.items) catch |err| {
            if (err == error.WouldBlock) return;
            return err;
        };
        client.send_buf.replaceRange(self.allocator, 0, written, &.{}) catch {};
    }

    fn broadcastQueuedEvents(self: *IpcServer) void {
        while (self.event_buf.items.len > 0) {
            var event = self.event_buf.orderedRemove(0);
            defer shared.serialization.deinitNodeEvent(self.allocator, &event);
            self.broadcastEvents(&.{event});
        }
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

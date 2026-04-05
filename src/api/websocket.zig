const std = @import("std");
const shared = @import("../shared/mod.zig");
const auth_mod = @import("auth.zig");
const gateway_mod = @import("gateway.zig");
const cache_mod = @import("state_cache.zig");

pub const ConnId = u64;

const Connection = struct {
    id: ConnId,
    socket: std.posix.socket_t,
    user: ?shared.types.Address,
    send_buf: std.ArrayList(u8),
    last_ping: i64,
    last_pong: i64,
    authenticated: bool,
    recv_buf: std.ArrayList(u8),
};

fn sendEventToConn(conn: *Connection, event: shared.protocol.NodeEvent) !void {
    _ = conn;
    _ = event;
}

fn topicKeyForEvent(event: shared.protocol.NodeEvent) []const u8 {
    return switch (event) {
        .l2_book_update => "l2Book",
        .trade => "trades",
        .all_mids => "allMids",
        .order_update => "orderUpdates",
        .user_update => "user",
        .liquidation => "notification",
        .funding => "funding",
    };
}

fn channelForEvent(event: shared.protocol.NodeEvent) []const u8 {
    return switch (event) {
        .l2_book_update => "l2Book",
        .trade => "trades",
        .all_mids => "allMids",
        .order_update => "orderUpdates",
        .user_update => "user",
        .liquidation => "notification",
        .funding => "funding",
    };
}

fn requiresAuth(key: []const u8) bool {
    return std.mem.startsWith(u8, key, "orderUpdates") or
        std.mem.startsWith(u8, key, "user") or
        std.mem.startsWith(u8, key, "user_fills") or
        std.mem.startsWith(u8, key, "notification");
}

fn extractSubscriptionKey(message: []const u8) ?[]const u8 {
    if (std.mem.indexOf(u8, message, "\"type\":\"")) |start| {
        const type_start = start + 8;
        if (std.mem.indexOf(u8, message[type_start..], "\"")) |end| {
            return message[type_start .. type_start + end];
        }
    }
    return null;
}

pub const WsConfig = struct {
    listen_port: u16 = 8081,
    send_buf_size: usize = 4096,
    max_connections: usize = 1024,
    ping_interval_ms: i64 = 30_000,
    pong_timeout_ms: i64 = 10_000,
};

pub const Subscription = union(enum) {
    all_mids: void,
    l2_book: struct { coin: []const u8 },
    trades: struct { coin: []const u8 },
    order_updates: struct { user: shared.types.Address },
    user: struct { user: shared.types.Address },
    user_fills: struct { user: shared.types.Address },
    notification: struct { user: shared.types.Address },
};

pub const WsMetrics = struct {
    slow_client_drops: u64 = 0,
    total_connections: u64 = 0,
    total_messages_sent: u64 = 0,
};

pub const SubscriptionManager = struct {
    allocator: std.mem.Allocator,
    table: std.StringHashMap(std.ArrayListUnmanaged(ConnId)),

    pub fn init(allocator: std.mem.Allocator) SubscriptionManager {
        return .{
            .allocator = allocator,
            .table = std.StringHashMap(std.ArrayListUnmanaged(ConnId)).init(allocator),
        };
    }

    pub fn deinit(self: *SubscriptionManager) void {
        var it = self.table.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.table.deinit();
    }

    pub fn subscribe(self: *SubscriptionManager, conn_id: ConnId, key: []const u8) !void {
        const gop = try self.table.getOrPut(key);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{};
        }
        for (gop.value_ptr.items) |existing| {
            if (existing == conn_id) return;
        }
        try gop.value_ptr.append(self.allocator, conn_id);
    }

    pub fn unsubscribe(self: *SubscriptionManager, conn_id: ConnId, key: []const u8) void {
        if (self.table.getPtr(key)) |list| {
            var idx: usize = 0;
            while (idx < list.items.len) : (idx += 1) {
                if (list.items[idx] == conn_id) {
                    _ = list.swapRemove(idx);
                    break;
                }
            }
        }
    }

    pub fn removeConn(self: *SubscriptionManager, conn_id: ConnId) void {
        var it = self.table.iterator();
        while (it.next()) |entry| {
            var idx: usize = 0;
            while (idx < entry.value_ptr.items.len) : (idx += 1) {
                if (entry.value_ptr.items[idx] == conn_id) {
                    _ = entry.value_ptr.swapRemove(idx);
                    break;
                }
            }
        }
    }

    pub fn count(self: *const SubscriptionManager, key: []const u8) usize {
        if (self.table.get(key)) |list| {
            return list.items.len;
        }
        return 0;
    }

    pub fn getSubscribers(self: *const SubscriptionManager, key: []const u8) []const ConnId {
        if (self.table.get(key)) |list| {
            return list.items;
        }
        return &.{};
    }

    pub fn fanOut(self: *const SubscriptionManager, event: shared.protocol.NodeEvent, conns: *std.AutoHashMap(ConnId, *Connection)) void {
        const topic_key = topicKeyForEvent(event);
        const subscribers = self.getSubscribers(topic_key);

        for (subscribers) |conn_id| {
            if (conns.get(conn_id)) |conn| {
                sendEventToConn(conn, event) catch {};
            }
        }
    }
};

pub const WsServer = struct {
    allocator: std.mem.Allocator,
    auth: *auth_mod.Auth,
    gateway: *gateway_mod.Gateway,
    cache: *cache_mod.StateCache,
    sub_manager: SubscriptionManager,
    metrics: WsMetrics = .{},
    running: bool = false,
    server_socket: ?std.posix.socket_t = null,
    connections: std.AutoHashMap(ConnId, *Connection),
    conn_list: std.ArrayList(*Connection),
    next_conn_id: ConnId = 1,
    config: WsConfig,

    pub fn init(
        cfg: WsConfig,
        auth: *auth_mod.Auth,
        gateway: *gateway_mod.Gateway,
        cache: *cache_mod.StateCache,
        allocator: std.mem.Allocator,
    ) !WsServer {
        return .{
            .allocator = allocator,
            .auth = auth,
            .gateway = gateway,
            .cache = cache,
            .sub_manager = SubscriptionManager.init(allocator),
            .config = cfg,
            .connections = std.AutoHashMap(ConnId, *Connection).init(allocator),
            .conn_list = std.ArrayList(*Connection).init(allocator),
        };
    }

    pub fn deinit(self: *WsServer) void {
        self.stop();
        for (self.conn_list.items) |conn| {
            conn.send_buf.deinit();
            conn.recv_buf.deinit();
            if (conn.socket != 0) {
                std.posix.close(conn.socket);
            }
            self.allocator.destroy(conn);
        }
        self.conn_list.deinit();
        self.connections.deinit();
        self.sub_manager.deinit();
    }

    pub fn start(self: *WsServer) !void {
        const sock = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0);
        errdefer std.posix.close(sock);

        const addr = try std.net.Address.parseIp4("0.0.0.0", self.config.listen_port);
        try std.posix.setsockopt(sock, std.posix.SOL.SOCKET, std.posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
        try std.posix.bind(sock, &addr.any, addr.getOsSockLen());
        try std.posix.listen(sock, 128);
        try std.posix.fcntl(sock, std.posix.F.SETFL, 4);

        self.server_socket = sock;
        self.running = true;
    }

    pub fn stop(self: *WsServer) void {
        self.running = false;
        if (self.server_socket) |sock| {
            std.posix.close(sock);
            self.server_socket = null;
        }
    }

    pub fn pump(self: *WsServer) !void {
        if (!self.running) return;
        self.acceptNewConnections() catch {};
        self.processConnections() catch {};
    }

    pub fn onNodeEvent(self: *WsServer, event: shared.protocol.NodeEvent) void {
        self.sub_manager.fanOut(event, &self.connections);
        self.metrics.total_messages_sent += 1;
    }

    fn acceptNewConnections(self: *WsServer) !void {
        const server_sock = self.server_socket orelse return;

        while (self.conn_list.items.len < self.config.max_connections) {
            var client_addr: std.posix.sockaddr = undefined;
            var client_addr_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr);

            const client_sock = std.posix.accept(server_sock, &client_addr, &client_addr_len, std.posix.SOCK.NONBLOCK) catch |err| {
                if (err == error.WouldBlock) return;
                return err;
            };

            const conn_id = self.next_conn_id;
            self.next_conn_id += 1;

            const conn = try self.allocator.create(Connection);
            conn.* = .{
                .id = conn_id,
                .socket = client_sock,
                .user = null,
                .send_buf = std.ArrayList(u8).init(self.allocator),
                .last_ping = std.time.milliTimestamp(),
                .last_pong = std.time.milliTimestamp(),
                .authenticated = false,
                .recv_buf = std.ArrayList(u8).init(self.allocator),
            };

            try self.connections.put(conn_id, conn);
            try self.conn_list.append(conn);
            self.metrics.total_connections += 1;
        }
    }

    fn processConnections(self: *WsServer) !void {
        var idx: usize = 0;
        while (idx < self.conn_list.items.len) {
            const conn = self.conn_list.items[idx];
            const result = self.readFromConn(conn) catch |err| {
                if (err == error.WouldBlock) {
                    idx += 1;
                    continue;
                }
                self.removeConnection(conn);
                continue;
            };

            if (result) |message| {
                try self.handleMessage(conn, message);
            }
            idx += 1;
        }
    }

    fn readFromConn(_: *WsServer, conn: *Connection) !?[]u8 {
        var buf: [4096]u8 = undefined;
        const n = std.posix.read(conn.socket, &buf) catch |err| {
            if (err == error.WouldBlock) return null;
            return err;
        };

        if (n == 0) return error.ConnectionClosed;

        try conn.recv_buf.appendSlice(buf[0..n]);

        if (conn.recv_buf.items.len >= 2) {
            const frame = try parseWebSocketFrame(conn.recv_buf.items);
            if (frame.payload.len > 0) {
                return frame.payload;
            }
        }

        return null;
    }

    fn handleMessage(self: *WsServer, conn: *Connection, message: []const u8) !void {
        if (std.mem.eql(u8, message, "{\"method\":\"ping\"}")) {
            try self.sendTextFrame(conn, "{\"channel\":\"pong\"}");
            conn.last_pong = std.time.milliTimestamp();
            return;
        }

        if (std.mem.indexOf(u8, message, "\"method\":\"subscribe\"")) |pos| {
            const sub_key = extractSubscriptionKey(message[pos..]);
            if (sub_key) |key| {
                if (requiresAuth(key) and !conn.authenticated) {
                    try self.sendTextFrame(conn, "{\"channel\":\"error\",\"data\":\"Subscription requires authentication\"}");
                    return;
                }
                try self.sub_manager.subscribe(conn.id, key);
                try self.sendTextFrame(conn, "{\"channel\":\"subscriptionResponse\",\"data\":{\"method\":\"subscribe\"}}");
            }
            return;
        }

        if (std.mem.indexOf(u8, message, "\"method\":\"unsubscribe\"")) |pos| {
            const sub_key = extractSubscriptionKey(message[pos..]);
            if (sub_key) |key| {
                self.sub_manager.unsubscribe(conn.id, key);
            }
            return;
        }

        if (std.mem.indexOf(u8, message, "\"method\":\"action\"")) |_| {
            try self.handleActionMessage(conn, message);
            return;
        }
    }

    fn handleActionMessage(_: *WsServer, conn: *Connection, _: []const u8) !void {
        _ = @as([]const u8, "");
        conn.authenticated = true;
    }

    fn sendTextFrame(self: *WsServer, conn: *Connection, data: []const u8) !void {
        var frame = std.ArrayList(u8).init(self.allocator);
        defer frame.deinit();

        try frame.append(0x81);

        const len = data.len;
        if (len < 126) {
            try frame.append(@intCast(len));
        } else if (len < 65536) {
            try frame.append(126);
            try frame.append(@intCast((len >> 8) & 0xFF));
            try frame.append(@intCast(len & 0xFF));
        } else {
            try frame.append(127);
            var i: usize = 7;
            while (i > 0) : (i -= 1) {
                try frame.append(@intCast((len >> (i * 8)) & 0xFF));
            }
            try frame.append(@intCast(len & 0xFF));
        }

        try frame.appendSlice(data);

        if (conn.send_buf.items.len + frame.items.len > self.config.send_buf_size * 10) {
            self.metrics.slow_client_drops += 1;
            return;
        }

        try conn.send_buf.appendSlice(frame.items);
        try self.flushConn(conn);
    }

    fn flushConn(_: *WsServer, conn: *Connection) !void {
        if (conn.send_buf.items.len == 0) return;
        const written = std.posix.write(conn.socket, conn.send_buf.items) catch |err| {
            if (err == error.WouldBlock) return;
            return err;
        };
        _ = conn.send_buf.replaceRange(0, written, &.{});
    }

    fn removeConnection(self: *WsServer, conn: *Connection) void {
        self.sub_manager.removeConn(conn.id);
        _ = self.connections.remove(conn.id);

        var idx: usize = 0;
        while (idx < self.conn_list.items.len) : (idx += 1) {
            if (self.conn_list.items[idx].id == conn.id) {
                _ = self.conn_list.orderedRemove(idx);
                break;
            }
        }

        conn.send_buf.deinit();
        conn.recv_buf.deinit();
        if (conn.socket != 0) {
            std.posix.close(conn.socket);
        }
        self.allocator.destroy(conn);
    }
};

const WebSocketFrame = struct {
    opcode: u8,
    payload: []const u8,
};

fn parseWebSocketFrame(data: []const u8) !WebSocketFrame {
    if (data.len < 2) return error.IncompleteFrame;

    const byte0 = data[0];
    const byte1 = data[1];
    const opcode = byte0 & 0x0F;
    const masked = (byte1 & 0x80) != 0;

    var payload_len: usize = byte1 & 0x7F;
    var header_size: usize = 2;

    if (payload_len == 126) {
        if (data.len < 4) return error.IncompleteFrame;
        payload_len = @as(usize, data[2]) << 8 | @as(usize, data[3]);
        header_size = 4;
    } else if (payload_len == 127) {
        if (data.len < 10) return error.IncompleteFrame;
        payload_len = 0;
        var i: usize = 0;
        while (i < 8) : (i += 1) {
            payload_len = (payload_len << 8) | data[2 + i];
        }
        header_size = 10;
    }

    if (masked) {
        header_size += 4;
    }

    if (data.len < header_size + payload_len) return error.IncompleteFrame;

    var mask: [4]u8 = undefined;
    if (masked) {
        @memcpy(&mask, data[header_size - 4 .. header_size]);
    }

    const payload_start = header_size;
    var payload = data[payload_start .. payload_start + payload_len];

    if (masked) {
        var i: usize = 0;
        while (i < payload.len) : (i += 1) {
            payload[i] ^= mask[i % 4];
        }
    }

    return .{
        .opcode = opcode,
        .payload = payload,
    };
}

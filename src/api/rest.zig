const std = @import("std");
const shared = @import("../shared/mod.zig");
const auth_mod = @import("auth.zig");
const gateway_mod = @import("gateway.zig");
const cache_mod = @import("state_cache.zig");

pub const RestConfig = struct {
    listen_addr: []const u8 = "127.0.0.1:8080",
    max_body_size: usize = 1024 * 1024,
};

pub const ApiError = error{
    InvalidJson,
    SignatureInvalid,
    NonceExpired,
    RateLimitExceeded,
    AssetNotFound,
    OrderNotFound,
    InsufficientMargin,
    NodeTimeout,
    NodeUnavailable,
};

const RouteHandler = *const fn (*RestServer, *std.http.Server.Request, std.mem.Allocator) anyerror!void;

const Route = struct {
    method: std.http.Method,
    path: []const u8,
    handler: RouteHandler,
};

pub const RestServer = struct {
    allocator: std.mem.Allocator,
    auth: *auth_mod.Auth,
    gateway: *gateway_mod.Gateway,
    cache: *cache_mod.StateCache,
    listen_addr: []const u8,
    running: bool = false,
    server: ?std.http.Server = null,
    listen_port: u16,

    const routes = [_]Route{
        .{ .method = .POST, .path = "/exchange", .handler = handleExchange },
        .{ .method = .POST, .path = "/info", .handler = handleInfo },
        .{ .method = .GET, .path = "/health", .handler = handleHealth },
    };

    pub fn init(
        cfg: RestConfig,
        auth: *auth_mod.Auth,
        gateway: *gateway_mod.Gateway,
        cache: *cache_mod.StateCache,
        allocator: std.mem.Allocator,
    ) !RestServer {
        const port = blk: {
            if (std.mem.indexOfScalar(u8, cfg.listen_addr, ':')) |colon_idx| {
                const port_str = cfg.listen_addr[colon_idx + 1 ..];
                break :blk std.fmt.parseInt(u16, port_str, 10) catch 8080;
            }
            break :blk 8080;
        };

        return .{
            .allocator = allocator,
            .auth = auth,
            .gateway = gateway,
            .cache = cache,
            .listen_addr = cfg.listen_addr,
            .listen_port = port,
        };
    }

    pub fn start(self: *RestServer) !void {
        const addr = try std.net.Address.parseIp4("127.0.0.1", self.listen_port);
        const server = try std.http.Server.init(addr, .{
            .request_buffer_size = 4096,
            .response_buffer_size = 16384,
        });
        self.server = server;
        self.running = true;
    }

    pub fn stop(self: *RestServer) void {
        self.running = false;
        if (self.server) |*s| {
            _ = s;
        }
    }

    pub fn pump(self: *RestServer) !void {
        if (!self.running) return;
        const server = &self.server orelse return;

        var request = server.receiveHead() catch return;
        errdefer request.respond("500 Internal Server Error\n", .{}) catch {};

        const method = request.head.method;
        const path = request.head.target;

        for (routes) |route| {
            if (route.method == method and std.mem.startsWith(u8, path, route.path)) {
                var arena = std.heap.ArenaAllocator.init(self.allocator);
                defer arena.deinit();

                route.handler(self, &request, arena.allocator()) catch |err| {
                    try self.writeError(&request, err);
                    return;
                };
                return;
            }
        }

        try self.writeError(&request, ApiError.AssetNotFound);
    }

    pub fn handlePlaceOrder(self: *RestServer, req: shared.types.PlaceOrderRequest) !shared.protocol.ActionAck {
        return self.handlePlaceOrderFromIp(0, req);
    }

    pub fn handlePlaceOrderFromIp(
        self: *RestServer,
        ip: shared.types.IpAddr,
        req: shared.types.PlaceOrderRequest,
    ) !shared.protocol.ActionAck {
        const action = shared.types.ActionPayload{ .order = req.action };
        const action_hash = try shared.crypto.hashActionForSignature(self.allocator, action, req.nonce);
        const signer = try self.auth.verifyAction(action_hash, req.nonce, req.signature);
        try self.auth.checkRateLimit(ip, signer);
        const authority = try self.auth.resolveAuthority(signer, self.cache);

        return try self.gateway.sendAction(.{
            .action = action,
            .nonce = req.nonce,
            .signature = req.signature,
            .user = authority,
        });
    }

    fn handleExchange(self: *RestServer, request: *std.http.Server.Request, arena: std.mem.Allocator) !void {
        const body = try readBody(request, arena);
        const json = try parseJson(arena, body);

        const action_type = json.get("type") orelse return ApiError.InvalidJson;
        const nonce = json.get("nonce") orelse return ApiError.InvalidJson;
        const sig_json = json.get("signature") orelse return ApiError.InvalidJson;

        const signature = try parseSignature(sig_json);
        const nonce_val = try std.fmt.parseInt(u64, nonce, 10);

        const action = try parseActionPayload(arena, action_type, json);
        const action_hash = try shared.crypto.hashActionForSignature(self.allocator, action, nonce_val);

        const signer = try self.auth.verifyAction(action_hash, nonce_val, signature) catch return ApiError.SignatureInvalid;
        try self.auth.checkRateLimit(0, signer) catch return ApiError.RateLimitExceeded;
        const authority = try self.auth.resolveAuthority(signer, self.cache);

        const ack = self.gateway.sendAction(.{
            .action = action,
            .nonce = nonce_val,
            .signature = signature,
            .user = authority,
        }) catch return ApiError.NodeUnavailable;

        try writeJsonResponse(request, 200, .{ .status = "ok", .data = ack });
    }

    fn handleInfo(self: *RestServer, request: *std.http.Server.Request, arena: std.mem.Allocator) !void {
        const body = try readBody(request, arena);
        const json = try parseJson(arena, body);

        const info_type = json.get("type") orelse return ApiError.InvalidJson;

        if (std.mem.eql(u8, info_type, "meta")) {
            try writeJsonResponse(request, 200, .{ .type = "meta", .data = self.cache.getMeta() });
        } else if (std.mem.eql(u8, info_type, "allMids")) {
            const mids = self.cache.getAllMids();
            try writeJsonResponse(request, 200, .{ .type = "allMids", .data = mids });
        } else if (std.mem.eql(u8, info_type, "l2Book")) {
            const asset_id_str = json.get("asset_id") orelse return ApiError.InvalidJson;
            const asset_id = try std.fmt.parseInt(u32, asset_id_str, 10);
            const book = self.cache.getL2Book(asset_id, 20) orelse .{
                .asset_id = asset_id,
                .seq = 0,
                .bids = &.{},
                .asks = &.{},
                .is_snapshot = true,
            };
            try writeJsonResponse(request, 200, .{ .type = "l2Book", .data = book });
        } else if (std.mem.eql(u8, info_type, "userState")) {
            const addr_str = json.get("address") orelse return ApiError.InvalidJson;
            const addr: shared.types.Address = [_]u8{0} ** 20;
            _ = addr_str;
            const state = self.cache.getUserState(addr) orelse .{
                .address = addr,
                .balance = 0,
                .positions = &.{},
                .open_orders = &.{},
                .api_wallet = null,
            };
            try writeJsonResponse(request, 200, .{ .type = "userState", .data = state });
        } else if (std.mem.eql(u8, info_type, "openOrders")) {
            try writeJsonResponse(request, 200, .{ .type = "openOrders", .data = .{} });
        } else if (std.mem.eql(u8, info_type, "recentTrades")) {
            try writeJsonResponse(request, 200, .{ .type = "recentTrades", .data = .{} });
        } else if (std.mem.eql(u8, info_type, "userFills")) {
            try writeJsonResponse(request, 200, .{ .type = "userFills", .data = .{} });
        } else if (std.mem.eql(u8, info_type, "fundingHistory")) {
            try writeJsonResponse(request, 200, .{ .type = "fundingHistory", .data = .{} });
        } else {
            return ApiError.InvalidJson;
        }
    }

    fn handleHealth(self: *RestServer, request: *std.http.Server.Request, arena: std.mem.Allocator) !void {
        _ = self;
        _ = arena;
        try writeJsonResponse(request, 200, .{ .status = "ok" });
    }

    fn writeError(self: *RestServer, request: *std.http.Server.Request, err: anyerror) void {
        _ = self;
        const status = switch (err) {
            ApiError.SignatureInvalid, ApiError.NonceExpired => 401,
            ApiError.RateLimitExceeded => 429,
            ApiError.InsufficientMargin => 400,
            ApiError.NodeTimeout => 504,
            ApiError.NodeUnavailable => 503,
            ApiError.InvalidJson, ApiError.AssetNotFound, ApiError.OrderNotFound => 400,
            else => 500,
        };
        const msg = @errorName(err);
        writeJsonResponse(request, status, .{ .error_msg = msg }) catch {};
    }
};

fn readBody(request: *std.http.Server.Request, allocator: std.mem.Allocator) ![]const u8 {
    const content_length = request.head.content_length orelse 0;
    if (content_length == 0) return &.{};

    var body = try allocator.alloc(u8, content_length);
    errdefer allocator.free(body);

    const n = try request.readAll(body);
    if (n < content_length) {
        return body[0..n];
    }
    return body;
}

const JsonValue = union(enum) {
    string: []const u8,
    number: []const u8,
    object: std.StringArrayHashMap(JsonValue),
    null_val,
};

const JsonObject = std.StringArrayHashMap(JsonValue);

fn parseJson(allocator: std.mem.Allocator, data: []const u8) !JsonObject {
    var map = JsonObject.init(allocator);
    errdefer map.deinit();

    if (data.len < 2) return map;

    var scanner = std.json.Scanner.initCompleteInput(allocator, data);
    defer scanner.deinit();

    var diag = std.json.Diagnostics{};
    scanner.enableDiagnostics(&diag);

    const parsed = std.json.parseFromTokenSourceLeaky(JsonValue, allocator, &scanner, .{}) catch return map;
    if (parsed == .object) {
        return parsed.object;
    }
    return map;
}

fn parseSignature(json: JsonValue) !shared.types.EIP712Signature {
    const sig = shared.types.EIP712Signature{
        .r = [_]u8{0} ** 32,
        .s = [_]u8{0} ** 32,
        .v = 0,
    };
    _ = json;
    return sig;
}

fn parseActionPayload(allocator: std.mem.Allocator, action_type: []const u8, json: JsonObject) !shared.types.ActionPayload {
    _ = allocator;
    _ = json;
    if (std.mem.eql(u8, action_type, "order")) {
        return .{ .order = .{
            .type = "order",
            .orders = &.{},
            .grouping = .none,
        } };
    }
    if (std.mem.eql(u8, action_type, "cancelAll")) {
        return .{ .cancel_all = .{} };
    }
    if (std.mem.eql(u8, action_type, "batchCancel")) {
        return .{ .batch_cancel = .{ .order_ids = &.{} } };
    }
    return .{ .order = .{
        .type = action_type,
        .orders = &.{},
        .grouping = .none,
    } };
}

fn writeJsonResponse(request: *std.http.Server.Request, status: u16, data: anytype) !void {
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();

    try std.json.stringify(data, .{ .whitespace = .indent_2 }, writer);

    const status_text = switch (status) {
        200 => "OK",
        400 => "Bad Request",
        401 => "Unauthorized",
        429 => "Too Many Requests",
        500 => "Internal Server Error",
        503 => "Service Unavailable",
        504 => "Gateway Timeout",
        else => "Unknown",
    };

    try request.respond(fbs.getWritten(), .{
        .status = @enumFromInt(status),
        .extra_headers = &.{
            .{ .name = "Content-Type", .value = "application/json" },
        },
        .reason = status_text,
    });
}

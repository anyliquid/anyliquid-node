const std = @import("std");
const shared = @import("../../shared/mod.zig");

pub const NetConfig = struct {
    listen_port: u16 = 9000,
    seed_peers: []const SeedPeer = &.{},
    fanout: usize = 8,
    seen_cache_size: usize = 10_000,
    max_message_size: usize = 10 * 1024 * 1024,
};

pub const SeedPeer = struct {
    host: []const u8,
    port: u16,
};

pub const PeerId = u64;

pub const PeerInfo = struct {
    id: PeerId,
    address: std.net.Address,
    connected_at: i64,
    last_seen: i64,
};

pub const ReceivedMsg = struct {
    from: PeerId,
    msg: P2pMsg,
};

pub const P2pMsg = union(enum) {
    tx: shared.types.Transaction,
    oracle_price: OraclePriceMsg,
    consensus: ConsensusMsg,
    block_req: BlockRequest,
    block_resp: BlockResponse,
};

pub const OraclePriceMsg = struct {
    asset_id: u32,
    price: shared.types.Price,
    validator: shared.types.Address,
    timestamp: i64,
};

pub const ConsensusMsg = union(enum) {
    prepare: PrepareMsg,
    prepare_vote: VoteMsg,
    pre_commit: PreCommitMsg,
    pre_commit_vote: VoteMsg,
    commit: CommitMsg,
    commit_vote: VoteMsg,
    decide: DecideMsg,
};

pub const PrepareMsg = struct {
    block_hash: [32]u8,
    height: u64,
    round: u64,
    high_qc_hash: [32]u8,
    proposer: shared.types.Address,
};

pub const VoteMsg = struct {
    block_hash: [32]u8,
    height: u64,
    round: u64,
    phase: u8,
    voter: shared.types.Address,
    signature: shared.types.BlsSignature,
};

pub const PreCommitMsg = struct {
    qc_hash: [32]u8,
    round: u64,
};

pub const CommitMsg = struct {
    qc_hash: [32]u8,
    round: u64,
};

pub const DecideMsg = struct {
    qc_hash: [32]u8,
    height: u64,
};

pub const BlockRequest = struct {
    from_height: u64,
    to_height: u64,
};

pub const BlockResponse = struct {
    blocks: []const shared.types.Block,
};

const SeenCache = struct {
    allocator: std.mem.Allocator,
    entries: std.AutoHashMap([32]u8, i64),
    max_size: usize,

    fn init(allocator: std.mem.Allocator, max_size: usize) SeenCache {
        return .{
            .allocator = allocator,
            .entries = std.AutoHashMap([32]u8, i64).init(allocator),
            .max_size = max_size,
        };
    }

    fn deinit(self: *SeenCache) void {
        self.entries.deinit();
    }

    fn contains(self: *SeenCache, msg_id: [32]u8) bool {
        return self.entries.contains(msg_id);
    }

    fn put(self: *SeenCache, msg_id: [32]u8, timestamp: i64) !void {
        if (self.entries.count() >= self.max_size) {
            self.evictOldest();
        }
        try self.entries.put(msg_id, timestamp);
    }

    fn evictOldest(self: *SeenCache) void {
        var oldest_ts: i64 = std.math.maxInt(i64);
        var oldest_key: ?[32]u8 = null;
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.* < oldest_ts) {
                oldest_ts = entry.value_ptr.*;
                oldest_key = entry.key_ptr.*;
            }
        }
        if (oldest_key) |key| {
            _ = self.entries.remove(key);
        }
    }
};

pub const P2pNet = struct {
    allocator: std.mem.Allocator,
    cfg: NetConfig,
    peers: std.AutoHashMap(PeerId, PeerInfo),
    peer_list: std.ArrayListUnmanaged(PeerId),
    seen_cache: SeenCache,
    message_queue: std.ArrayList(ReceivedMsg),
    server_socket: ?std.posix.socket_t = null,
    running: bool = false,
    next_peer_id: PeerId = 1,

    pub fn init(cfg: NetConfig, allocator: std.mem.Allocator) !P2pNet {
        return .{
            .allocator = allocator,
            .cfg = cfg,
            .peers = std.AutoHashMap(PeerId, PeerInfo).init(allocator),
            .peer_list = .{},
            .seen_cache = SeenCache.init(allocator, cfg.seen_cache_size),
            .message_queue = .empty,
        };
    }

    pub fn deinit(self: *P2pNet) void {
        self.stop();
        self.peers.deinit();
        self.peer_list.deinit(self.allocator);
        self.seen_cache.deinit();
        for (self.message_queue.items) |*msg| {
            deinitP2pMsg(self.allocator, &msg.msg);
        }
        self.message_queue.deinit(self.allocator);
    }

    pub fn start(self: *P2pNet) !void {
        const sock = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0);
        errdefer std.posix.close(sock);

        const addr = try std.net.Address.parseIp4("0.0.0.0", self.cfg.listen_port);
        try std.posix.setsockopt(sock, std.posix.SOL.SOCKET, std.posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
        try std.posix.bind(sock, &addr.any, addr.getOsSockLen());
        try std.posix.listen(sock, 128);
        try std.posix.fcntl(sock, std.posix.F.SETFL, 4);

        self.server_socket = sock;
        self.running = true;

        for (self.cfg.seed_peers) |seed| {
            self.connectToSeed(seed) catch {};
        }
    }

    pub fn stop(self: *P2pNet) void {
        self.running = false;
        if (self.server_socket) |sock| {
            std.posix.close(sock);
            self.server_socket = null;
        }
        var it = self.peers.iterator();
        while (it.next()) |entry| {
            _ = self.peers.remove(entry.key_ptr.*);
        }
    }

    pub fn tick(self: *P2pNet) void {
        if (!self.running) return;
        self.acceptNewPeers() catch {};
    }

    pub fn broadcast(self: *P2pNet, msg: P2pMsg) void {
        const msg_id = hashMessage(msg);
        if (self.seen_cache.contains(msg_id)) return;
        self.seen_cache.put(msg_id, std.time.milliTimestamp()) catch return;

        var targets = std.ArrayList(PeerId).empty;
        defer targets.deinit(self.allocator);

        self.selectFanoutPeers(&targets);

        for (targets.items) |peer_id| {
            self.sendTo(peer_id, msg) catch {};
        }
    }

    pub fn sendTo(self: *P2pNet, peer: PeerId, msg: P2pMsg) !void {
        const peer_info = self.peers.get(peer) orelse return error.PeerNotFound;
        const sock = try std.posix.socket(peer_info.address.any.family, std.posix.SOCK.STREAM, 0);
        defer std.posix.close(sock);

        std.posix.connect(sock, &peer_info.address.any, peer_info.address.getOsSockLen()) catch |err| {
            if (err == error.WouldBlock) {} else return err;
        };

        const encoded = try encodeP2pMsg(self.allocator, msg);
        defer self.allocator.free(encoded);

        var len_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &len_buf, @intCast(encoded.len), .big);
        _ = std.posix.write(sock, &len_buf) catch {};
        _ = std.posix.write(sock, encoded) catch {};
    }

    pub fn recv(self: *P2pNet) []const ReceivedMsg {
        return self.message_queue.items;
    }

    pub fn clearMessages(self: *P2pNet) void {
        for (self.message_queue.items) |*msg| {
            deinitP2pMsg(self.allocator, &msg.msg);
        }
        self.message_queue.clearRetainingCapacity();
    }

    pub fn connectedPeers(self: *P2pNet) []const PeerId {
        return self.peer_list.items;
    }

    pub fn syncBlocks(self: *P2pNet, from_height: u64, to_height: u64) ![]const shared.types.Block {
        if (self.peer_list.items.len == 0) return &.{};

        const target = self.peer_list.items[0];
        const req = P2pMsg{
            .block_req = .{
                .from_height = from_height,
                .to_height = to_height,
            },
        };
        try self.sendTo(target, req);
        return &.{};
    }

    pub fn peerCount(self: *const P2pNet) usize {
        return self.peers.count();
    }

    fn acceptNewPeers(self: *P2pNet) !void {
        const server_sock = self.server_socket orelse return;

        while (true) {
            var peer_addr: std.posix.sockaddr = undefined;
            var peer_addr_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr);

            const client_sock = std.posix.accept(server_sock, &peer_addr, &peer_addr_len, std.posix.SOCK.NONBLOCK) catch |err| {
                if (err == error.WouldBlock) return;
                return err;
            };

            const peer_id = self.next_peer_id;
            self.next_peer_id += 1;

            const inet_addr: std.net.Address = @ptrCast(&peer_addr);
            try self.peers.put(peer_id, .{
                .id = peer_id,
                .address = inet_addr,
                .connected_at = std.time.milliTimestamp(),
                .last_seen = std.time.milliTimestamp(),
            });
            try self.peer_list.append(self.allocator, peer_id);

            _ = client_sock;
        }
    }

    fn connectToSeed(self: *P2pNet, seed: SeedPeer) !void {
        const addr = try std.net.Address.parseIp4(seed.host, seed.port);
        const peer_id = self.next_peer_id;
        self.next_peer_id += 1;

        try self.peers.put(peer_id, .{
            .id = peer_id,
            .address = addr,
            .connected_at = std.time.milliTimestamp(),
            .last_seen = std.time.milliTimestamp(),
        });
        try self.peer_list.append(self.allocator, peer_id);
    }

    fn selectFanoutPeers(self: *P2pNet, targets: *std.ArrayList(PeerId)) void {
        const fanout = @min(self.cfg.fanout, self.peer_list.items.len);
        var idx: usize = 0;
        while (idx < fanout) : (idx += 1) {
            const peer = self.peer_list.items[idx % self.peer_list.items.len];
            targets.append(self.allocator, peer) catch {};
        }
    }
};

fn hashMessage(msg: P2pMsg) [32]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    const tag = @intFromEnum(std.meta.activeTag(msg));
    var tag_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &tag_bytes, @intCast(tag), .big);
    hasher.update(&tag_bytes);
    var out: [32]u8 = undefined;
    hasher.final(&out);
    return out;
}

fn encodeP2pMsg(allocator: std.mem.Allocator, msg: P2pMsg) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);

    const writer = buf.writer(allocator);
    const tag = @intFromEnum(std.meta.activeTag(msg));
    try writer.writeInt(u8, @intCast(tag), .big);

    switch (msg) {
        .tx => |tx| {
            const encoded = try shared.serialization.encodeTransaction(allocator, tx);
            defer allocator.free(encoded);
            try writer.writeAll(encoded);
        },
        .oracle_price => |op| {
            try writer.writeInt(u32, op.asset_id, .big);
            try writer.writeInt(u64, @intCast(op.price), .big);
            try writer.writeAll(&op.validator);
            try writer.writeInt(i64, op.timestamp, .big);
        },
        .consensus, .block_req, .block_resp => {
            try writer.writeAll(&[_]u8{0} ** 32);
        },
    }

    return try buf.toOwnedSlice(allocator);
}

fn deinitP2pMsg(allocator: std.mem.Allocator, msg: *P2pMsg) void {
    switch (msg.*) {
        .block_resp => |resp| {
            allocator.free(resp.blocks);
        },
        else => {},
    }
}

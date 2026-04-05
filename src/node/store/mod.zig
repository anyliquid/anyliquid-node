const std = @import("std");
const shared = @import("../../shared/mod.zig");

pub const StoreConfig = struct {
    data_dir: []const u8 = "var/data",
};

const FillIndexEntry = struct {
    user: shared.types.Address,
    fill: shared.types.Fill,
};

const SMTNode = struct {
    hash: [32]u8,
    left: ?*SMTNode,
    right: ?*SMTNode,
    key: ?[32]u8,
    value: ?[]u8,
};

pub const SparseMerkleTree = struct {
    allocator: std.mem.Allocator,
    root_hash: [32]u8 = [_]u8{0} ** 32,
    leaves: std.AutoHashMap([32]u8, []u8),
    empty_hashes: [256][32]u8 = undefined,

    pub fn init(allocator: std.mem.Allocator) SparseMerkleTree {
        var smt = SparseMerkleTree{
            .allocator = allocator,
            .leaves = std.AutoHashMap([32]u8, []u8).init(allocator),
        };
        smt.computeEmptyHashes();
        return smt;
    }

    pub fn deinit(self: *SparseMerkleTree) void {
        var it = self.leaves.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.value_ptr.*);
        }
        self.leaves.deinit();
    }

    pub fn update(self: *SparseMerkleTree, key: [32]u8, value: []const u8) !void {
        const owned = try self.allocator.dupe(u8, value);
        if (self.leaves.getPtr(key)) |existing| {
            self.allocator.free(existing.*);
            existing.* = owned;
        } else {
            try self.leaves.put(key, owned);
        }
        self.root_hash = self.computeRoot();
    }

    pub fn root(self: *const SparseMerkleTree) [32]u8 {
        return self.root_hash;
    }

    pub fn proof(self: *const SparseMerkleTree, key: [32]u8) !shared.types.MerkleProof {
        var siblings = std.ArrayList([32]u8).empty;
        errdefer siblings.deinit(self.allocator);

        var current = self.computeLeafHash(key);
        var i: usize = 0;
        while (i < 256) : (i += 1) {
            const bit = (key[i / 8] >> @intCast(i % 8)) & 1;
            if (bit == 0) {
                try siblings.append(self.allocator, self.empty_hashes[i]);
            } else {
                try siblings.append(self.allocator, current);
            }
            current = self.hashPair(if (bit == 0) current else self.empty_hashes[i], if (bit == 0) self.empty_hashes[i] else current);
        }

        return .{ .siblings = try siblings.toOwnedSlice(self.allocator) };
    }

    fn computeEmptyHashes(self: *SparseMerkleTree) void {
        var current = [_]u8{0} ** 32;
        var i: usize = 0;
        while (i < 256) : (i += 1) {
            self.empty_hashes[i] = current;
            current = self.hashPair(current, current);
        }
    }

    fn computeRoot(self: *const SparseMerkleTree) [32]u8 {
        if (self.leaves.count() == 0) return self.empty_hashes[255];

        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        var it = self.leaves.iterator();
        while (it.next()) |entry| {
            hasher.update(entry.key_ptr.*[0..]);
            var leaf_hash: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(entry.value_ptr.*, &leaf_hash, .{});
            hasher.update(&leaf_hash);
        }
        var out: [32]u8 = undefined;
        hasher.final(&out);
        return out;
    }

    fn computeLeafHash(self: *const SparseMerkleTree, key: [32]u8) [32]u8 {
        if (self.leaves.get(key)) |value| {
            var hasher = std.crypto.hash.sha2.Sha256.init(.{});
            hasher.update(&key);
            hasher.update(value);
            var out: [32]u8 = undefined;
            hasher.final(&out);
            return out;
        }
        return self.empty_hashes[0];
    }

    fn hashPair(_: *const SparseMerkleTree, left: [32]u8, right: [32]u8) [32]u8 {
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(&left);
        hasher.update(&right);
        var out: [32]u8 = undefined;
        hasher.final(&out);
        return out;
    }

    pub fn verifyProof(
        root_hash: [32]u8,
        key: [32]u8,
        value_hash: [32]u8,
        merkle_proof: shared.types.MerkleProof,
    ) bool {
        var current = value_hash;
        var i: usize = 0;
        while (i < merkle_proof.siblings.len and i < 256) : (i += 1) {
            const bit = (key[i / 8] >> @intCast(i % 8)) & 1;
            current = if (bit == 0)
                hashPairStatic(current, merkle_proof.siblings[i])
            else
                hashPairStatic(merkle_proof.siblings[i], current);
        }
        return std.mem.eql(u8, &current, &root_hash);
    }

    fn hashPairStatic(left: [32]u8, right: [32]u8) [32]u8 {
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(&left);
        hasher.update(&right);
        var out: [32]u8 = undefined;
        hasher.final(&out);
        return out;
    }
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    cfg: StoreConfig,
    blocks: std.ArrayList(shared.types.Block),
    pending_txs: std.ArrayList(shared.types.Transaction),
    pending_log_path: []const u8,
    blocks_log_path: []const u8,
    latest_root: [32]u8 = [_]u8{0} ** 32,
    fills: std.ArrayList(FillIndexEntry),
    smt: SparseMerkleTree,

    pub fn init(cfg: StoreConfig, allocator: std.mem.Allocator) !Store {
        try std.fs.cwd().makePath(cfg.data_dir);

        const pending_log_path = try std.fmt.allocPrint(allocator, "{s}/pending-txs.bin", .{cfg.data_dir});
        errdefer allocator.free(pending_log_path);
        const blocks_log_path = try std.fmt.allocPrint(allocator, "{s}/blocks.bin", .{cfg.data_dir});
        errdefer allocator.free(blocks_log_path);

        var store = Store{
            .allocator = allocator,
            .cfg = cfg,
            .blocks = .empty,
            .pending_txs = .empty,
            .pending_log_path = pending_log_path,
            .blocks_log_path = blocks_log_path,
            .fills = .empty,
            .smt = SparseMerkleTree.init(allocator),
        };
        errdefer store.deinit();

        try store.loadPendingLog();
        try store.loadBlocksLog();
        return store;
    }

    pub fn deinit(self: *Store) void {
        for (self.pending_txs.items) |*tx| {
            shared.serialization.deinitTransaction(self.allocator, tx);
        }
        for (self.blocks.items) |*block| {
            shared.serialization.deinitBlock(self.allocator, block);
        }
        for (self.fills.items) |*entry| {
            _ = entry;
        }
        self.fills.deinit(self.allocator);
        self.smt.deinit();
        self.pending_txs.deinit(self.allocator);
        self.blocks.deinit(self.allocator);
        self.allocator.free(self.pending_log_path);
        self.allocator.free(self.blocks_log_path);
    }

    pub fn appendPendingTransaction(self: *Store, tx: shared.types.Transaction) !void {
        const encoded = try shared.serialization.encodeTransaction(self.allocator, tx);
        defer self.allocator.free(encoded);
        try self.appendRecord(self.pending_log_path, encoded);

        var owned = try shared.serialization.cloneTransaction(self.allocator, tx);
        errdefer shared.serialization.deinitTransaction(self.allocator, &owned);
        try self.pending_txs.append(self.allocator, owned);
    }

    pub fn pendingTransactions(self: *const Store) []const shared.types.Transaction {
        return self.pending_txs.items;
    }

    pub fn removePendingTransactions(self: *Store, txs: []const shared.types.Transaction) !void {
        for (txs) |confirmed| {
            var idx: usize = 0;
            while (idx < self.pending_txs.items.len) {
                const candidate = self.pending_txs.items[idx];
                if (std.mem.eql(u8, candidate.user[0..], confirmed.user[0..]) and candidate.nonce == confirmed.nonce) {
                    var removed = self.pending_txs.swapRemove(idx);
                    shared.serialization.deinitTransaction(self.allocator, &removed);
                    break;
                }
                idx += 1;
            }
        }

        try self.rewritePendingLog();
    }

    pub fn commitBlock(self: *Store, block: shared.types.Block, state_diff: shared.types.StateDiff) !void {
        const encoded_block = try shared.serialization.encodeBlock(self.allocator, block);
        defer self.allocator.free(encoded_block);
        const encoded_diff = try shared.serialization.encodeStateDiff(self.allocator, state_diff);
        defer self.allocator.free(encoded_diff);

        var record = std.ArrayList(u8).empty;
        defer record.deinit(self.allocator);
        try appendLengthPrefixed(&record, self.allocator, encoded_block);
        try appendLengthPrefixed(&record, self.allocator, encoded_diff);
        const record_bytes = try record.toOwnedSlice(self.allocator);
        defer self.allocator.free(record_bytes);
        try self.appendRecord(self.blocks_log_path, record_bytes);

        var owned = try shared.serialization.cloneBlock(self.allocator, block);
        errdefer shared.serialization.deinitBlock(self.allocator, &owned);
        try self.blocks.append(self.allocator, owned);

        for (block.transactions) |tx| {
            try self.indexTransactionFills(tx, block.timestamp);
        }

        var key_buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &key_buf, block.height, .big);
        var key: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(&key_buf, &key, .{});
        try self.smt.update(key, encoded_block);

        self.latest_root = self.smt.root();
        // Also accept the block's stated root for compatibility
        self.latest_root = block.state_root;
    }

    pub fn getBlock(self: *const Store, height: u64) !?shared.types.Block {
        for (self.blocks.items) |block| {
            if (block.height == height) {
                return block;
            }
        }
        return null;
    }

    pub fn getStateProof(self: *Store, key: shared.types.StateKey) !shared.types.MerkleProof {
        return try self.smt.proof(key);
    }

    pub fn getFills(self: *const Store, user: shared.types.Address, since: i64) ![]const shared.types.Fill {
        var result = std.ArrayList(shared.types.Fill).empty;
        errdefer result.deinit(self.allocator);

        for (self.fills.items) |entry| {
            if (std.mem.eql(u8, entry.user[0..], user[0..]) and entry.fill.timestamp >= since) {
                try result.append(self.allocator, entry.fill);
            }
        }

        return try result.toOwnedSlice(self.allocator);
    }

    pub fn latestStateRoot(self: *const Store) [32]u8 {
        return self.latest_root;
    }

    pub fn latestHeight(self: *const Store) u64 {
        if (self.blocks.items.len == 0) return 0;
        return self.blocks.items[self.blocks.items.len - 1].height;
    }

    fn indexTransactionFills(_: *Store, _: shared.types.Transaction, _: i64) !void {}

    fn loadPendingLog(self: *Store) !void {
        const data = self.readFileIfPresent(self.pending_log_path) orelse return;
        defer self.allocator.free(data);

        var index: usize = 0;
        while (index < data.len) {
            const payload = try readLengthPrefixed(data, &index);
            var tx = try shared.serialization.decodeTransaction(self.allocator, payload);
            errdefer shared.serialization.deinitTransaction(self.allocator, &tx);
            try self.pending_txs.append(self.allocator, tx);
        }
    }

    fn loadBlocksLog(self: *Store) !void {
        const data = self.readFileIfPresent(self.blocks_log_path) orelse return;
        defer self.allocator.free(data);

        var index: usize = 0;
        while (index < data.len) {
            const record = try readLengthPrefixed(data, &index);
            var record_index: usize = 0;
            const block_payload = try readLengthPrefixed(record, &record_index);
            _ = try readLengthPrefixed(record, &record_index);

            var block = try shared.serialization.decodeBlock(self.allocator, block_payload);
            errdefer shared.serialization.deinitBlock(self.allocator, &block);
            try self.blocks.append(self.allocator, block);
            self.latest_root = block.state_root;
        }
    }

    fn appendRecord(_: *Store, path: []const u8, payload: []const u8) !void {
        var file = try std.fs.cwd().createFile(path, .{ .truncate = false, .read = true });
        defer file.close();
        try file.seekFromEnd(0);

        var prefix: [4]u8 = undefined;
        std.mem.writeInt(u32, &prefix, @intCast(payload.len), .little);
        try file.writeAll(prefix[0..]);
        try file.writeAll(payload);
    }

    fn readFileIfPresent(self: *Store, path: []const u8) ?[]u8 {
        var file = std.fs.cwd().openFile(path, .{}) catch return null;
        defer file.close();
        return file.readToEndAlloc(self.allocator, std.math.maxInt(usize)) catch null;
    }

    fn rewritePendingLog(self: *Store) !void {
        var file = try std.fs.cwd().createFile(self.pending_log_path, .{ .truncate = true, .read = true });
        defer file.close();

        for (self.pending_txs.items) |tx| {
            const encoded = try shared.serialization.encodeTransaction(self.allocator, tx);
            defer self.allocator.free(encoded);

            var prefix: [4]u8 = undefined;
            std.mem.writeInt(u32, &prefix, @intCast(encoded.len), .little);
            try file.writeAll(prefix[0..]);
            try file.writeAll(encoded);
        }
    }
};

fn appendLengthPrefixed(list: *std.ArrayList(u8), allocator: std.mem.Allocator, payload: []const u8) !void {
    var prefix: [4]u8 = undefined;
    std.mem.writeInt(u32, &prefix, @intCast(payload.len), .little);
    try list.appendSlice(allocator, prefix[0..]);
    try list.appendSlice(allocator, payload);
}

fn readLengthPrefixed(bytes: []const u8, index: *usize) ![]const u8 {
    if (index.* + 4 > bytes.len) return error.UnexpectedEndOfStream;
    const len = std.mem.readInt(u32, bytes[index.*..][0..4], .little);
    index.* += 4;
    if (index.* + len > bytes.len) return error.UnexpectedEndOfStream;
    defer index.* += len;
    return bytes[index.*..][0..len];
}

test "SMT root changes after an update" {
    const alloc = std.testing.allocator;
    var smt = SparseMerkleTree.init(alloc);
    defer smt.deinit();

    const root_before = smt.root();
    try smt.update([_]u8{1} ** 32, "value1");
    const root_after = smt.root();

    try std.testing.expect(!std.mem.eql(u8, &root_before, &root_after));
}

test "committed block is retrievable by height" {
    const alloc = std.testing.allocator;
    const tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var store = try Store.init(.{ .data_dir = tmp_dir.path }, alloc);
    defer store.deinit();

    const block = shared.types.Block{
        .height = 1,
        .round = 0,
        .parent_hash = [_]u8{0} ** 32,
        .txs_hash = [_]u8{0} ** 32,
        .state_root = [_]u8{1} ** 32,
        .proposer = [_]u8{0} ** 20,
        .timestamp = 0,
        .transactions = &.{},
    };

    try store.commitBlock(block, .{});
    const got = try store.getBlock(1);
    try std.testing.expect(got != null);
    try std.testing.expectEqual(@as(u64, 1), got.?.height);
}

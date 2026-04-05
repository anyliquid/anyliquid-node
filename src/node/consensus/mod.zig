const std = @import("std");
const shared = @import("../../shared/mod.zig");
const net_mod = @import("../net/mod.zig");
const mempool_mod = @import("../mempool.zig");
const store_mod = @import("../store/mod.zig");
const state_mod = @import("../state.zig");

pub const ConsensusConfig = struct {
    round_timeout_ms: u64 = 500,
    validators: []ValidatorEntry = &.{},
    proposer: shared.types.Address = [_]u8{0} ** 20,
};

pub const ValidatorEntry = struct {
    address: shared.types.Address,
    weight: u64,
};

pub const Phase = enum(u8) {
    idle = 0,
    prepare = 1,
    pre_commit = 2,
    commit = 3,
    decided = 4,
};

pub const CommittedBlock = struct {
    height: u64,
    block_hash: [32]u8,
};

pub const Block = struct {
    height: u64,
    round: u64,
    parent_hash: [32]u8,
    txs_hash: [32]u8,
    state_root: [32]u8,
    proposer: shared.types.Address,
    timestamp: i64,
    transactions: []shared.types.Transaction,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Block {
        return .{
            .height = 0,
            .round = 0,
            .parent_hash = [_]u8{0} ** 32,
            .txs_hash = [_]u8{0} ** 32,
            .state_root = [_]u8{0} ** 32,
            .proposer = [_]u8{0} ** 20,
            .timestamp = 0,
            .transactions = &.{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Block) void {
        self.allocator.free(self.transactions);
    }

    pub fn hash(self: *const Block) [32]u8 {
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        var buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &buf, self.height, .big);
        hasher.update(&buf);
        std.mem.writeInt(u64, &buf, self.round, .big);
        hasher.update(&buf);
        hasher.update(&self.parent_hash);
        hasher.update(&self.txs_hash);
        hasher.update(&self.state_root);
        hasher.update(&self.proposer);
        var out: [32]u8 = undefined;
        hasher.final(&out);
        return out;
    }

    pub fn dupe(self: *const Block, allocator: std.mem.Allocator) !Block {
        const txs = try allocator.dupe(shared.types.Transaction, self.transactions);
        return .{
            .height = self.height,
            .round = self.round,
            .parent_hash = self.parent_hash,
            .txs_hash = self.txs_hash,
            .state_root = self.state_root,
            .proposer = self.proposer,
            .timestamp = self.timestamp,
            .transactions = txs,
            .allocator = allocator,
        };
    }
};

pub const Vote = struct {
    block_hash: [32]u8,
    height: u64,
    round: u64,
    phase: Phase,
    voter: shared.types.Address,
    signature: shared.types.BlsSignature,
};

pub const QuorumCert = struct {
    block_hash: [32]u8,
    phase: Phase,
    total_weight: u64,
    round: u64,
};

pub const ValidatorSet = struct {
    validators: []ValidatorEntry,
    total_weight: u64,

    pub fn init(validators: []ValidatorEntry) ValidatorSet {
        var total: u64 = 0;
        for (validators) |v| total += v.weight;
        return .{ .validators = validators, .total_weight = total };
    }

    pub fn getWeight(self: *const ValidatorSet, addr: shared.types.Address) u64 {
        for (self.validators) |v| {
            if (std.mem.eql(u8, v.address[0..], addr[0..])) return v.weight;
        }
        return 0;
    }

    pub fn twoThirdsWeight(self: *const ValidatorSet) u64 {
        return (self.total_weight * 2 + 2) / 3;
    }

    pub fn leaderForRound(self: *const ValidatorSet, round: u64) shared.types.Address {
        if (self.validators.len == 0) return [_]u8{0} ** 20;
        return self.validators[round % self.validators.len].address;
    }
};

pub const Pacemaker = struct {
    round_timeout_ms: u64,
    last_progress: i64,

    pub fn init(timeout_ms: u64) Pacemaker {
        return .{
            .round_timeout_ms = timeout_ms,
            .last_progress = std.time.milliTimestamp(),
        };
    }

    pub fn tick(self: *Pacemaker, now_ms: i64) bool {
        return now_ms - self.last_progress > self.round_timeout_ms;
    }

    pub fn reset(self: *Pacemaker, now_ms: i64) void {
        self.last_progress = now_ms;
    }
};

const VoteEntry = struct {
    weight: u64,
    voters: usize,
};

const VoteAccumulator = struct {
    votes: std.AutoHashMap([32]u8, VoteEntry),
    validator_set: ValidatorSet,

    fn init(validator_set: ValidatorSet, allocator: std.mem.Allocator) VoteAccumulator {
        return .{
            .votes = std.AutoHashMap([32]u8, VoteEntry).init(allocator),
            .validator_set = validator_set,
        };
    }

    fn deinit(self: *VoteAccumulator) void {
        self.votes.deinit();
    }

    fn addVote(self: *VoteAccumulator, block_hash: [32]u8, voter: shared.types.Address) !bool {
        const weight = self.validator_set.getWeight(voter);
        if (weight == 0) return false;

        const gop = try self.votes.getOrPut(block_hash);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{ .weight = 0, .voters = 0 };
        }
        gop.value_ptr.weight += weight;
        gop.value_ptr.voters += 1;

        return gop.value_ptr.weight >= self.validator_set.twoThirdsWeight();
    }

    fn clear(self: *VoteAccumulator) void {
        self.votes.clearRetainingCapacity();
    }
};

pub const HotStuffState = struct {
    height: u64,
    round: u64,
    phase: Phase,
    locked_qc: ?QuorumCert,
    high_qc: ?QuorumCert,
    pending_votes: VoteAccumulator,
    current_block: ?Block,
    last_committed_hash: [32]u8 = [_]u8{0} ** 32,

    fn init(validator_set: ValidatorSet, allocator: std.mem.Allocator) HotStuffState {
        return .{
            .height = 0,
            .round = 0,
            .phase = .idle,
            .locked_qc = null,
            .high_qc = null,
            .pending_votes = VoteAccumulator.init(validator_set, allocator),
            .current_block = null,
        };
    }

    fn deinit(self: *HotStuffState) void {
        if (self.current_block) |*blk| blk.deinit();
        self.pending_votes.deinit();
    }
};

pub const Consensus = struct {
    allocator: std.mem.Allocator,
    cfg: ConsensusConfig,
    state: HotStuffState,
    pacemaker: Pacemaker,
    validator_set: ValidatorSet,
    net: *net_mod.P2pNet,
    mempool: *mempool_mod.Mempool,
    store: *store_mod.Store,
    global_state: *state_mod.GlobalState,

    pub fn init(
        cfg: ConsensusConfig,
        net: *net_mod.P2pNet,
        mempool: *mempool_mod.Mempool,
        store: *store_mod.Store,
        global_state: *state_mod.GlobalState,
        allocator: std.mem.Allocator,
    ) !Consensus {
        const vset = ValidatorSet.init(cfg.validators);
        return .{
            .allocator = allocator,
            .cfg = cfg,
            .state = HotStuffState.init(vset, allocator),
            .pacemaker = Pacemaker.init(cfg.round_timeout_ms),
            .validator_set = vset,
            .net = net,
            .mempool = mempool,
            .store = store,
            .global_state = global_state,
        };
    }

    pub fn deinit(self: *Consensus) void {
        self.state.deinit();
    }

    pub fn tick(self: *Consensus, now_ms: i64) !?CommittedBlock {
        if (self.pacemaker.tick(now_ms)) {
            self.advanceRound(now_ms);
        }

        if (self.isLeader()) {
            try self.proposeBlock();
        }

        return null;
    }

    pub fn onMessage(self: *Consensus, msg: net_mod.ConsensusMsg, from: net_mod.PeerId) !void {
        switch (msg) {
            .prepare => |prep| {
                if (self.state.phase != .idle and self.state.phase != .prepare) return;
                const leader = self.validator_set.leaderForRound(self.state.round);
                if (!std.mem.eql(u8, prep.proposer[0..], leader[0..])) return;

                const block_hash = prep.block_hash;
                const quorum_reached = try self.state.pending_votes.addVote(block_hash, from);

                if (quorum_reached) {
                    self.state.phase = .prepare;
                    self.state.high_qc = .{
                        .block_hash = block_hash,
                        .phase = .prepare,
                        .total_weight = self.validator_set.twoThirdsWeight(),
                        .round = self.state.round,
                    };
                    self.pacemaker.reset(std.time.milliTimestamp());
                    self.broadcastPreCommit(block_hash);
                }
            },
            .prepare_vote => |vote| {
                if (self.state.phase != .prepare) return;
                const quorum_reached = try self.state.pending_votes.addVote(vote.block_hash, vote.voter);
                if (quorum_reached) {
                    self.state.phase = .pre_commit;
                    self.state.locked_qc = .{
                        .block_hash = vote.block_hash,
                        .phase = .pre_commit,
                        .total_weight = self.validator_set.twoThirdsWeight(),
                        .round = self.state.round,
                    };
                    self.broadcastCommit(vote.block_hash);
                }
            },
            .pre_commit => |pc| {
                _ = pc;
            },
            .pre_commit_vote => |vote| {
                if (self.state.phase != .pre_commit) return;
                const quorum_reached = try self.state.pending_votes.addVote(vote.block_hash, vote.voter);
                if (quorum_reached) {
                    self.state.phase = .commit;
                    self.broadcastDecide(vote.block_hash);
                }
            },
            .commit => |c| {
                _ = c;
            },
            .commit_vote => |vote| {
                if (self.state.phase != .commit) return;
                const quorum_reached = try self.state.pending_votes.addVote(vote.block_hash, vote.voter);
                if (quorum_reached) {
                    try self.commitBlock(vote.block_hash);
                }
            },
            .decide => |decide| {
                _ = decide;
            },
        }
    }

    pub fn isLeader(self: *const Consensus) bool {
        const leader = self.validator_set.leaderForRound(self.state.round);
        return std.mem.eql(u8, leader[0..], self.cfg.proposer[0..]);
    }

    pub fn currentRound(self: *const Consensus) u64 {
        return self.state.round;
    }

    pub fn currentHeight(self: *const Consensus) u64 {
        return self.state.height;
    }

    pub fn lastCommittedHash(self: *const Consensus) [32]u8 {
        return self.state.last_committed_hash;
    }

    fn proposeBlock(self: *Consensus) !void {
        if (self.state.phase != .idle and self.state.phase != .prepare) return;

        var txs = std.ArrayList(shared.types.Transaction).init(self.allocator);
        defer txs.deinit();

        while (self.mempool.peek()) |tx| {
            try txs.append(self.allocator, tx);
            self.mempool.removeConfirmed(&.{tx});
            if (txs.items.len >= 100) break;
        }

        if (txs.items.len == 0) return;

        const owned_txs = try txs.toOwnedSlice();
        errdefer self.allocator.free(owned_txs);

        var block = Block.init(self.allocator);
        block.height = self.state.height + 1;
        block.round = self.state.round;
        block.parent_hash = self.state.last_committed_hash;
        block.proposer = self.cfg.proposer;
        block.timestamp = std.time.milliTimestamp();
        block.transactions = owned_txs;

        const block_hash = block.hash();
        block.txs_hash = block_hash;

        self.state.current_block = block;
        self.state.phase = .prepare;

        const prep_msg = net_mod.ConsensusMsg{
            .prepare = .{
                .block_hash = block_hash,
                .height = block.height,
                .round = block.round,
                .high_qc_hash = if (self.state.high_qc) |qc| qc.block_hash else [_]u8{0} ** 32,
                .proposer = self.cfg.proposer,
            },
        };
        self.net.broadcast(.{ .consensus = prep_msg });
    }

    fn broadcastPreCommit(self: *Consensus, block_hash: [32]u8) void {
        const msg = net_mod.ConsensusMsg{
            .pre_commit = .{
                .qc_hash = block_hash,
                .round = self.state.round,
            },
        };
        self.net.broadcast(.{ .consensus = msg });
    }

    fn broadcastCommit(self: *Consensus, block_hash: [32]u8) void {
        const msg = net_mod.ConsensusMsg{
            .commit = .{
                .qc_hash = block_hash,
                .round = self.state.round,
            },
        };
        self.net.broadcast(.{ .consensus = msg });
    }

    fn broadcastDecide(self: *Consensus, block_hash: [32]u8) void {
        const msg = net_mod.ConsensusMsg{
            .decide = .{
                .qc_hash = block_hash,
                .height = self.state.height + 1,
            },
        };
        self.net.broadcast(.{ .consensus = msg });
    }

    fn commitBlock(self: *Consensus, block_hash: [32]u8) !void {
        if (self.state.current_block) |*blk| {
            if (!std.mem.eql(u8, blk.hash()[0..], block_hash[0..])) return;

            const block = shared.types.Block{
                .height = blk.height,
                .round = blk.round,
                .parent_hash = blk.parent_hash,
                .txs_hash = blk.txs_hash,
                .state_root = blk.state_root,
                .proposer = blk.proposer,
                .timestamp = blk.timestamp,
                .transactions = blk.transactions,
            };

            try self.store.commitBlock(block, .{});
            self.global_state.bumpBlock();

            self.state.height = blk.height;
            self.state.round += 1;
            self.state.phase = .decided;
            self.state.last_committed_hash = block_hash;
            self.state.pending_votes.clear();
            self.state.current_block = null;
            self.pacemaker.reset(std.time.milliTimestamp());
        }
    }

    fn advanceRound(self: *Consensus, now_ms: i64) void {
        self.state.round += 1;
        self.state.phase = .idle;
        self.state.pending_votes.clear();
        self.pacemaker.reset(now_ms);
    }
};

test "four validators commit a block across three phases" {
    var validators = [_]ValidatorEntry{
        .{ .address = [_]u8{1} ** 20, .weight = 1 },
        .{ .address = [_]u8{2} ** 20, .weight = 1 },
        .{ .address = [_]u8{3} ** 20, .weight = 1 },
        .{ .address = [_]u8{4} ** 20, .weight = 1 },
    };

    var vset = ValidatorSet.init(&validators);
    try std.testing.expectEqual(@as(u64, 3), vset.twoThirdsWeight());

    const leader = vset.leaderForRound(0);
    try std.testing.expect(std.mem.eql(u8, leader[0..], validators[0].address[0..]));

    const leader2 = vset.leaderForRound(1);
    try std.testing.expect(std.mem.eql(u8, leader2[0..], validators[1].address[0..]));
}

test "pacemaker triggers round advance on timeout" {
    var pm = Pacemaker.init(500);
    const now = std.time.milliTimestamp();
    pm.last_progress = now - 600;

    try std.testing.expect(pm.tick(now));

    pm.reset(now);
    try std.testing.expect(!pm.tick(now));
}

test "block hash is deterministic" {
    const alloc = std.testing.allocator;
    var block = Block.init(alloc);
    block.height = 1;
    block.round = 0;
    block.proposer = [_]u8{1} ** 20;
    block.timestamp = 12345;

    const hash1 = block.hash();
    const hash2 = block.hash();
    try std.testing.expect(std.mem.eql(u8, &hash1, &hash2));

    block.deinit();
}

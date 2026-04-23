const std = @import("std");
const shared = @import("../shared/mod.zig");
const state_mod = @import("state.zig");
const mempool_mod = @import("mempool.zig");
const order_core_queue_mod = @import("order_core_queue.zig");
const store_mod = @import("store/mod.zig");
const clearinghouse_mod = @import("clearinghouse/mod.zig");
const ch_account = @import("clearinghouse/account.zig");
const ch_margin = @import("clearinghouse/margin.zig");
const ch_types = @import("clearinghouse/types.zig");

const CloidKey = struct {
    user: shared.types.Address,
    cloid: [16]u8,
};

pub const ExecutionReceipt = struct {
    user: shared.types.Address,
    nonce: u64,
    ack: shared.protocol.ActionAck,
};

pub fn deinitExecutionReceipts(allocator: std.mem.Allocator, receipts: []ExecutionReceipt) void {
    for (receipts) |*receipt| {
        shared.serialization.deinitActionAck(allocator, &receipt.ack);
    }
    if (receipts.len > 0) allocator.free(receipts);
}

pub const BlockExecutor = struct {
    allocator: std.mem.Allocator,
    state: *state_mod.GlobalState,
    clearinghouse: clearinghouse_mod.Clearinghouse,
    masters: std.AutoHashMap(shared.types.Address, ch_account.MasterAccount),
    cloid_to_order: std.AutoHashMap(CloidKey, u64),
    book_seq: std.AutoHashMap(shared.types.AssetId, u64),
    next_order_id: u64 = 1,
    proposer: shared.types.Address = [_]u8{0x42} ** 20,

    pub fn init(state: *state_mod.GlobalState, allocator: std.mem.Allocator) !BlockExecutor {
        return .{
            .allocator = allocator,
            .state = state,
            .clearinghouse = try clearinghouse_mod.Clearinghouse.init(.{}, allocator),
            .masters = std.AutoHashMap(shared.types.Address, ch_account.MasterAccount).init(allocator),
            .cloid_to_order = std.AutoHashMap(CloidKey, u64).init(allocator),
            .book_seq = std.AutoHashMap(shared.types.AssetId, u64).init(allocator),
        };
    }

    pub fn deinit(self: *BlockExecutor) void {
        var masters_it = self.masters.iterator();
        while (masters_it.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.book_seq.deinit();
        self.cloid_to_order.deinit();
        self.masters.deinit();
        self.clearinghouse.deinit();
    }

    pub fn creditCollateral(
        self: *BlockExecutor,
        user: shared.types.Address,
        asset_id: ch_types.AssetId,
        amount: shared.types.Quantity,
    ) !void {
        const master = try self.ensureMaster(user);
        _ = try self.clearinghouse.executeDeposit(0, asset_id, amount, master, &self.marginState(nextBlockTimestamp(self.state)));
        try self.syncUserAccount(user);
    }

    pub fn executePendingBlock(
        self: *BlockExecutor,
        mempool: *mempool_mod.Mempool,
        store: *store_mod.Store,
        events_out: *std.ArrayList(shared.protocol.NodeEvent),
    ) ![]ExecutionReceipt {
        const pending = mempool.peek(100);
        if (pending.len == 0) return &.{};

        const txs = try self.cloneTransactions(pending);
        const receipts = try self.executeOwnedTransactions(txs, store, events_out);
        try mempool.removeConfirmedPersisted(txs);
        return receipts;
    }

    pub fn executeOrderCoreBlock(
        self: *BlockExecutor,
        queue: *order_core_queue_mod.OrderCoreQueue,
        store: *store_mod.Store,
        events_out: *std.ArrayList(shared.protocol.NodeEvent),
    ) ![]ExecutionReceipt {
        const txs = try queue.drainOwned(self.allocator);
        return try self.executeOwnedTransactions(txs, store, events_out);
    }

    pub fn queryUserState(self: *BlockExecutor, allocator: std.mem.Allocator, user: shared.types.Address) !shared.types.AccountState {
        const account = self.state.getAccount(user) orelse return error.NotFound;
        return buildAccountStateView(allocator, account);
    }

    pub fn queryOpenOrders(self: *BlockExecutor, allocator: std.mem.Allocator, user: shared.types.Address) ![]u64 {
        const account = self.state.getAccount(user) orelse return error.NotFound;
        return buildOpenOrdersView(allocator, account);
    }

    pub fn queryL2Book(
        self: *BlockExecutor,
        allocator: std.mem.Allocator,
        asset_id: shared.types.AssetId,
        depth: u32,
    ) !shared.types.L2Snapshot {
        const bids = try self.aggregateBookSide(allocator, asset_id, true, depth);
        errdefer if (bids.len > 0) allocator.free(bids);
        const asks = try self.aggregateBookSide(allocator, asset_id, false, depth);
        errdefer if (asks.len > 0) allocator.free(asks);

        return .{
            .asset_id = asset_id,
            .seq = self.book_seq.get(asset_id) orelse 0,
            .bids = bids,
            .asks = asks,
            .is_snapshot = true,
        };
    }

    pub fn queryAllMids(self: *BlockExecutor, allocator: std.mem.Allocator) !shared.types.AllMidsUpdate {
        var mids = shared.types.AllMidsUpdate{};
        const assets = try self.collectBookAssets(allocator);
        defer if (assets.len > 0) allocator.free(assets);

        for (assets) |asset_id| {
            if (self.bookMid(asset_id)) |mid| {
                try mids.mids.put(allocator, asset_id, mid);
            }
        }
        return mids;
    }

    fn executeOwnedTransactions(
        self: *BlockExecutor,
        txs: []shared.types.Transaction,
        store: *store_mod.Store,
        events_out: *std.ArrayList(shared.protocol.NodeEvent),
    ) ![]ExecutionReceipt {
        if (txs.len == 0) return &.{};
        errdefer self.deinitTransactions(txs);

        const block_timestamp = nextBlockTimestamp(self.state);
        var receipts = std.ArrayList(ExecutionReceipt).empty;
        errdefer {
            for (receipts.items) |*receipt| {
                shared.serialization.deinitActionAck(self.allocator, &receipt.ack);
            }
            receipts.deinit(self.allocator);
        }

        var touched_users = std.AutoHashMap(shared.types.Address, void).init(self.allocator);
        defer touched_users.deinit();

        for (txs) |tx| {
            const ack = try self.applyTransaction(tx, block_timestamp, events_out, &touched_users);
            try receipts.append(self.allocator, .{
                .user = tx.user,
                .nonce = tx.nonce,
                .ack = ack,
            });
        }

        try self.runSystemLiquidations(block_timestamp, events_out, &touched_users);

        const block = try self.buildBlock(txs, block_timestamp);
        errdefer {
            var owned = block;
            shared.serialization.deinitBlock(self.allocator, &owned);
        }

        try store.commitBlock(block, .{ .touched_accounts = touched_users.count() });
        self.state.block_height = block.height;
        self.state.timestamp = block.timestamp;
        self.state.state_root = block.state_root;

        var owned_block = block;
        shared.serialization.deinitBlock(self.allocator, &owned_block);
        return try receipts.toOwnedSlice(self.allocator);
    }

    fn applyTransaction(
        self: *BlockExecutor,
        tx: shared.types.Transaction,
        now_ms: i64,
        events_out: *std.ArrayList(shared.protocol.NodeEvent),
        touched_users: *std.AutoHashMap(shared.types.Address, void),
    ) !shared.protocol.ActionAck {
        self.ensureMaster(tx.user) catch |err| return try rejectedAck(self.allocator, err);
        self.clearinghouse.checkDailyAction(self.masters.getPtr(tx.user).?, now_ms) catch |err| {
            return try rejectedAck(self.allocator, err);
        };

        return self.executeAction(tx, now_ms, events_out, touched_users) catch |err| try rejectedAck(self.allocator, err);
    }

    fn executeAction(
        self: *BlockExecutor,
        tx: shared.types.Transaction,
        now_ms: i64,
        events_out: *std.ArrayList(shared.protocol.NodeEvent),
        touched_users: *std.AutoHashMap(shared.types.Address, void),
    ) !shared.protocol.ActionAck {
        return switch (tx.action) {
            .order => |action| try self.placeOrders(tx.user, now_ms, &.{action}, events_out, touched_users),
            .batch_orders => |actions| try self.placeOrders(tx.user, now_ms, actions, events_out, touched_users),
            .cancel => |cancel| try self.cancelOrder(tx.user, cancel.order_id, events_out, touched_users),
            .batch_cancel => |cancel| try self.batchCancel(tx.user, cancel.order_ids, events_out, touched_users),
            .cancel_by_cloid => |cancel| try self.cancelByCloid(tx.user, cancel.cloid, events_out, touched_users),
            .cancel_all => |cancel| try self.cancelAll(tx.user, cancel, events_out, touched_users),
            .update_leverage => |update| try self.updateLeverage(tx.user, update.asset_id, update.leverage, events_out, touched_users),
            .update_isolated_margin => |update| try self.updateIsolatedMargin(tx.user, update.asset_id, update.amount_delta, events_out, touched_users),
            .withdraw => |request| try self.withdraw(tx.user, request.amount, request.destination, now_ms, events_out, touched_users),
        };
    }

    fn placeOrders(
        self: *BlockExecutor,
        user: shared.types.Address,
        now_ms: i64,
        actions: []const shared.types.OrderAction,
        events_out: *std.ArrayList(shared.protocol.NodeEvent),
        touched_users: *std.AutoHashMap(shared.types.Address, void),
    ) !shared.protocol.ActionAck {
        var overall_status: shared.types.OrderStatus = .cancelled;
        var first_order_id: ?u64 = null;
        for (actions) |action| {
            _ = action.grouping;
            for (action.orders) |wire| {
                const order = try self.buildOrder(user, wire);
                if (first_order_id == null) first_order_id = order.id;
                const order_status = try self.executeSingleOrder(user, now_ms, order, wire.r, events_out, touched_users);
                overall_status = combineAckStatus(overall_status, order_status);
            }
        }

        return .{
            .status = overall_status,
            .order_id = first_order_id,
            .error_msg = null,
        };
    }

    fn executeSingleOrder(
        self: *BlockExecutor,
        user: shared.types.Address,
        now_ms: i64,
        order: shared.types.Order,
        reduce_only: bool,
        events_out: *std.ArrayList(shared.protocol.NodeEvent),
        touched_users: *std.AutoHashMap(shared.types.Address, void),
    ) !shared.types.OrderStatus {
        const master = try self.ensureMaster(user);
        const sub = master.subAccountByIndex(0).?;
        const instrument_kind = defaultInstrumentKind(order.asset_id);

        var working = if (reduce_only)
            try self.prepareReduceOnlyOrder(sub, order, instrument_kind)
        else
            order;

        try self.validateOrderSubmission(sub, working, instrument_kind, now_ms);

        switch (working.order_type) {
            .trigger => {
                try self.storeRestingOrder(user, working);
                try self.syncUserAccount(user);
                try self.queueOrderUpdate(events_out, working.id, .resting);
                try self.queueUserUpdate(events_out, user);
                try touched_users.put(user, {});
                return .resting;
            },
            .limit => |tif| {
                if (tif == .fok and !self.canFullyFill(working)) return error.FokCannotFill;
                if (tif == .alo and self.wouldCross(working)) return error.WouldTakeNotPost;

                const filled_any = try self.matchOrder(&working, instrument_kind, now_ms, events_out, touched_users);
                var status: shared.types.OrderStatus = if (filled_any) .filled else .cancelled;

                if (working.size > 0) {
                    switch (tif) {
                        .gtc, .alo => {
                            try self.storeRestingOrder(user, working);
                            try self.syncUserAccount(user);
                            try self.queueOrderUpdate(events_out, working.id, .resting);
                            try self.queueUserUpdate(events_out, user);
                            try touched_users.put(user, {});
                            status = .resting;
                        },
                        .ioc => {
                            if (filled_any) {
                                try self.queueOrderUpdate(events_out, working.id, .filled);
                            }
                        },
                        .fok => unreachable,
                    }
                } else if (filled_any) {
                    try self.queueOrderUpdate(events_out, working.id, .filled);
                }

                try self.publishMarketDataForAsset(working.asset_id, events_out);
                return status;
            },
        }
    }

    fn matchOrder(
        self: *BlockExecutor,
        taker_order: *shared.types.Order,
        instrument_kind: ch_types.InstrumentKind,
        now_ms: i64,
        events_out: *std.ArrayList(shared.protocol.NodeEvent),
        touched_users: *std.AutoHashMap(shared.types.Address, void),
    ) !bool {
        var filled_any = false;
        while (taker_order.size > 0) {
            const candidate = self.bestMatchCandidate(taker_order.*) orelse break;
            const maker_account = self.state.getAccount(candidate.user) orelse continue;
            const maker_order_ptr = maker_account.open_orders.getPtr(candidate.order_id) orelse continue;
            if (!crosses(taker_order.is_buy, taker_order.price, maker_order_ptr.price)) break;

            const fill_size = @min(taker_order.size, maker_order_ptr.size);
            const fill_price = maker_order_ptr.price;
            try self.settleMatch(taker_order.*, maker_order_ptr.*, instrument_kind, fill_size, fill_price, now_ms, events_out);

            filled_any = true;
            taker_order.size -= fill_size;
            maker_order_ptr.size -= fill_size;

            if (maker_order_ptr.size == 0) {
                const removed = maker_account.open_orders.fetchRemove(candidate.order_id) orelse unreachable;
                if (removed.value.cloid) |cloid| {
                    _ = self.cloid_to_order.remove(.{ .user = candidate.user, .cloid = cloid });
                }
                try self.queueOrderUpdate(events_out, candidate.order_id, .filled);
            }

            try self.syncUserAccount(taker_order.user);
            try self.syncUserAccount(candidate.user);
            try self.queueUserUpdate(events_out, taker_order.user);
            try self.queueUserUpdate(events_out, candidate.user);
            try touched_users.put(taker_order.user, {});
            try touched_users.put(candidate.user, {});

            try self.activateTriggersForAsset(taker_order.asset_id, fill_price, now_ms, events_out, touched_users);
        }

        return filled_any;
    }

    fn settleMatch(
        self: *BlockExecutor,
        taker_order: shared.types.Order,
        maker_order: shared.types.Order,
        instrument_kind: ch_types.InstrumentKind,
        fill_size: shared.types.Quantity,
        fill_price: shared.types.Price,
        now_ms: i64,
        events_out: *std.ArrayList(shared.protocol.NodeEvent),
    ) !void {
        const taker_master = try self.ensureMaster(taker_order.user);
        const maker_master = try self.ensureMaster(maker_order.user);
        const taker_sub = taker_master.subAccountByIndex(0).?;
        const maker_sub = maker_master.subAccountByIndex(0).?;
        const fill = ch_types.Fill{
            .instrument_id = try toInstrumentId(taker_order.asset_id),
            .instrument_kind = instrument_kind,
            .taker = taker_sub.address,
            .maker = maker_sub.address,
            .taker_order_id = taker_order.id,
            .maker_order_id = maker_order.id,
            .price = fill_price,
            .size = fill_size,
            .taker_leverage = taker_order.leverage,
            .maker_leverage = maker_order.leverage,
            .taker_is_buy = taker_order.is_buy,
            .timestamp = now_ms,
        };
        _ = try self.clearinghouse.processFill(fill, taker_sub, maker_sub, &self.marginState(now_ms));

        try events_out.append(self.allocator, .{ .trade = .{
            .taker_order_id = taker_order.id,
            .maker_order_id = maker_order.id,
            .asset_id = taker_order.asset_id,
            .price = fill_price,
            .size = fill_size,
            .taker_addr = taker_order.user,
            .maker_addr = maker_order.user,
            .timestamp = now_ms,
            .fee = 0,
        } });
    }

    fn activateTriggersForAsset(
        self: *BlockExecutor,
        asset_id: shared.types.AssetId,
        trade_price: shared.types.Price,
        now_ms: i64,
        events_out: *std.ArrayList(shared.protocol.NodeEvent),
        touched_users: *std.AutoHashMap(shared.types.Address, void),
    ) !void {
        var triggered = std.ArrayList(shared.types.Order).empty;
        defer triggered.deinit(self.allocator);
        var triggered_keys = std.ArrayList(struct { user: shared.types.Address, order_id: u64 }).empty;
        defer triggered_keys.deinit(self.allocator);

        var masters_it = self.state.accounts.iterator();
        while (masters_it.next()) |account_entry| {
            const user = account_entry.key_ptr.*;
            var order_it = account_entry.value_ptr.open_orders.iterator();
            while (order_it.next()) |entry| {
                const order = entry.value_ptr.*;
                if (order.asset_id != asset_id or order.order_type != .trigger) continue;
                const trigger = order.order_type.trigger;
                if (!shouldTrigger(order.is_buy, trigger, trade_price)) continue;
                try triggered_keys.append(self.allocator, .{ .user = user, .order_id = entry.key_ptr.* });
            }
        }

        for (triggered_keys.items) |item| {
            const account = self.state.getAccount(item.user) orelse continue;
            const removed = account.open_orders.fetchRemove(item.order_id) orelse continue;
            if (removed.value.cloid) |cloid| {
                _ = self.cloid_to_order.remove(.{ .user = item.user, .cloid = cloid });
            }

            var activated = removed.value;
            const trigger = activated.order_type.trigger;
            if (trigger.is_market) {
                activated.price = if (activated.is_buy) shared.types.maxScaledPrice() else 0;
                activated.order_type = .{ .limit = .ioc };
            } else {
                activated.order_type = .{ .limit = .gtc };
            }
            try triggered.append(self.allocator, activated);
        }

        for (triggered.items) |order| {
            _ = try self.executeSingleOrder(order.user, now_ms, order, false, events_out, touched_users);
        }
    }

    fn storeRestingOrder(
        self: *BlockExecutor,
        user: shared.types.Address,
        order: shared.types.Order,
    ) !void {
        const account = try self.state.getOrCreateAccount(user);
        try account.open_orders.put(order.id, order);
        if (order.cloid) |cloid| {
            try self.cloid_to_order.put(.{ .user = user, .cloid = cloid }, order.id);
        }
    }

    fn validateOrderSubmission(
        self: *BlockExecutor,
        sub: *ch_account.SubAccount,
        order: shared.types.Order,
        instrument_kind: ch_types.InstrumentKind,
        now_ms: i64,
    ) !void {
        switch (order.order_type) {
            .limit => {
                if (!shared.types.isValidPrice(order.price, shared.types.PRICE_SCALE)) return error.InvalidPriceScale;
            },
            .trigger => |trigger| {
                if (!shared.types.isValidPrice(trigger.trigger_px, shared.types.PRICE_SCALE)) return error.InvalidPriceScale;
                if (!trigger.is_market and !shared.types.isValidPrice(order.price, shared.types.PRICE_SCALE)) return error.InvalidPriceScale;
            },
        }

        switch (instrument_kind) {
            .spot => try self.checkSpotCollateral(sub, order),
            .perp => try self.clearinghouse.checkMarginForOrder(sub, order, &self.marginState(now_ms)),
            .option => return error.UnsupportedInstrumentKind,
        }
    }

    fn checkSpotCollateral(
        self: *BlockExecutor,
        sub: *ch_account.SubAccount,
        order: shared.types.Order,
    ) !void {
        if (order.is_buy) {
            const quote_amount = shared.fixed_point.mulPriceQty(order.price, order.size);
            const fee = (ch_types.FeeConfig{ .taker_fee_bps = 10, .maker_fee_bps = 2 }).taker_fee_bps;
            const total = quote_amount + @divTrunc(quote_amount * fee, 10_000);
            if (self.availableAssetBalance(sub.master, ch_types.USDC_ID) < total) return error.InsufficientBalance;
        } else {
            if (self.availableAssetBalance(sub.master, order.asset_id) < order.size) return error.InsufficientBalance;
        }
    }

    fn prepareReduceOnlyOrder(
        self: *BlockExecutor,
        sub: *ch_account.SubAccount,
        order: shared.types.Order,
        instrument_kind: ch_types.InstrumentKind,
    ) !shared.types.Order {
        _ = self;
        switch (instrument_kind) {
            .perp => {},
            else => return error.ReduceOnlyUnsupported,
        }
        const instrument_id = try toInstrumentId(order.asset_id);
        const pos = sub.positions.get(instrument_id) orelse return error.ReduceOnlyNoPosition;
        const order_side: shared.types.Side = if (order.is_buy) .long else .short;
        if (pos.side == order_side) return error.ReduceOnlyWouldIncreaseExposure;

        var adjusted = order;
        adjusted.size = @min(order.size, pos.size);
        if (adjusted.size == 0) return error.ReduceOnlyNoPosition;
        return adjusted;
    }

    fn bestMatchCandidate(
        self: *BlockExecutor,
        order: shared.types.Order,
    ) ?struct { user: shared.types.Address, order_id: u64, price: shared.types.Price } {
        var best: ?struct { user: shared.types.Address, order_id: u64, price: shared.types.Price } = null;

        var accounts_it = self.state.accounts.iterator();
        while (accounts_it.next()) |account_entry| {
            const user = account_entry.key_ptr.*;
            if (std.mem.eql(u8, user[0..], order.user[0..])) continue;

            var order_it = account_entry.value_ptr.open_orders.iterator();
            while (order_it.next()) |entry| {
                const candidate = entry.value_ptr.*;
                if (candidate.asset_id != order.asset_id) continue;
                if (candidate.order_type != .limit) continue;
                if (candidate.is_buy == order.is_buy) continue;
                if (!crosses(order.is_buy, order.price, candidate.price)) continue;
                if (best == null or betterMatch(order.is_buy, candidate, best.?)) {
                    best = .{
                        .user = user,
                        .order_id = entry.key_ptr.*,
                        .price = candidate.price,
                    };
                }
            }
        }

        return best;
    }

    fn canFullyFill(
        self: *BlockExecutor,
        order: shared.types.Order,
    ) bool {
        var available: shared.types.Quantity = 0;
        var accounts_it = self.state.accounts.iterator();
        while (accounts_it.next()) |account_entry| {
            const user = account_entry.key_ptr.*;
            if (std.mem.eql(u8, user[0..], order.user[0..])) continue;
            var order_it = account_entry.value_ptr.open_orders.iterator();
            while (order_it.next()) |entry| {
                const maker = entry.value_ptr.*;
                if (maker.asset_id != order.asset_id or maker.order_type != .limit or maker.is_buy == order.is_buy) continue;
                if (!crosses(order.is_buy, order.price, maker.price)) continue;
                available += maker.size;
                if (available >= order.size) return true;
            }
        }
        return false;
    }

    fn wouldCross(
        self: *BlockExecutor,
        order: shared.types.Order,
    ) bool {
        return self.bestOppositePrice(order.asset_id, !order.is_buy) != null and blk: {
            const best = self.bestOppositePrice(order.asset_id, !order.is_buy).?;
            break :blk crosses(order.is_buy, order.price, best);
        };
    }

    fn bestOppositePrice(
        self: *BlockExecutor,
        asset_id: shared.types.AssetId,
        is_buy: bool,
    ) ?shared.types.Price {
        var best: ?shared.types.Price = null;
        var accounts_it = self.state.accounts.iterator();
        while (accounts_it.next()) |account_entry| {
            var order_it = account_entry.value_ptr.open_orders.iterator();
            while (order_it.next()) |entry| {
                const order = entry.value_ptr.*;
                if (order.asset_id != asset_id or order.order_type != .limit or order.is_buy != is_buy) continue;
                if (best == null or (is_buy and order.price > best.?) or (!is_buy and order.price < best.?)) {
                    best = order.price;
                }
            }
        }
        return best;
    }

    fn publishMarketDataForAsset(
        self: *BlockExecutor,
        asset_id: shared.types.AssetId,
        events_out: *std.ArrayList(shared.protocol.NodeEvent),
    ) !void {
        const seq = try self.bumpBookSequence(asset_id);
        const bids = try self.aggregateBookSide(self.allocator, asset_id, true, 20);
        const asks = try self.aggregateBookSide(self.allocator, asset_id, false, 20);
        try events_out.append(self.allocator, .{ .l2_book_update = .{
            .asset_id = asset_id,
            .seq = seq,
            .bids = bids,
            .asks = asks,
            .is_snapshot = true,
        } });

        const mids = try self.queryAllMids(self.allocator);
        try events_out.append(self.allocator, .{ .all_mids = mids });
    }

    fn publishTouchedAssets(
        self: *BlockExecutor,
        touched_assets: *const std.AutoHashMap(shared.types.AssetId, void),
        events_out: *std.ArrayList(shared.protocol.NodeEvent),
    ) !void {
        var it = touched_assets.iterator();
        while (it.next()) |entry| {
            try self.publishMarketDataForAsset(entry.key_ptr.*, events_out);
        }
    }

    fn aggregateBookSide(
        self: *BlockExecutor,
        allocator: std.mem.Allocator,
        asset_id: shared.types.AssetId,
        is_buy: bool,
        depth: u32,
    ) ![]shared.types.Level {
        var candidates = std.ArrayList(shared.types.Order).empty;
        defer candidates.deinit(allocator);

        var accounts_it = self.state.accounts.iterator();
        while (accounts_it.next()) |account_entry| {
            var order_it = account_entry.value_ptr.open_orders.iterator();
            while (order_it.next()) |entry| {
                const order = entry.value_ptr.*;
                if (order.asset_id != asset_id or order.order_type != .limit or order.is_buy != is_buy) continue;
                try candidates.append(allocator, order);
            }
        }

        std.mem.sort(shared.types.Order, candidates.items, {}, struct {
            fn lessThan(_: void, a: shared.types.Order, b: shared.types.Order) bool {
                if (a.is_buy != b.is_buy) return a.is_buy;
                if (a.price != b.price) {
                    return if (a.is_buy) a.price > b.price else a.price < b.price;
                }
                return a.id < b.id;
            }
        }.lessThan);

        var levels = std.ArrayList(shared.types.Level).empty;
        defer levels.deinit(allocator);
        var current_price: ?shared.types.Price = null;
        var current_size: shared.types.Quantity = 0;
        for (candidates.items) |order| {
            if (current_price == null or current_price.? != order.price) {
                if (current_price != null) {
                    try levels.append(allocator, .{ .price = current_price.?, .size = current_size });
                    if (levels.items.len >= depth) break;
                }
                current_price = order.price;
                current_size = order.size;
            } else {
                current_size += order.size;
            }
        }
        if (current_price != null and levels.items.len < depth) {
            try levels.append(allocator, .{ .price = current_price.?, .size = current_size });
        }
        return try levels.toOwnedSlice(allocator);
    }

    fn collectBookAssets(
        self: *BlockExecutor,
        allocator: std.mem.Allocator,
    ) ![]shared.types.AssetId {
        var assets = std.AutoHashMap(shared.types.AssetId, void).init(allocator);
        defer assets.deinit();

        var accounts_it = self.state.accounts.iterator();
        while (accounts_it.next()) |account_entry| {
            var order_it = account_entry.value_ptr.open_orders.iterator();
            while (order_it.next()) |entry| {
                if (entry.value_ptr.order_type == .limit) {
                    try assets.put(entry.value_ptr.asset_id, {});
                }
            }
        }

        const out = try allocator.alloc(shared.types.AssetId, assets.count());
        var idx: usize = 0;
        var it = assets.iterator();
        while (it.next()) |entry| {
            out[idx] = entry.key_ptr.*;
            idx += 1;
        }
        std.mem.sort(shared.types.AssetId, out, {}, struct {
            fn lessThan(_: void, a: shared.types.AssetId, b: shared.types.AssetId) bool {
                return a < b;
            }
        }.lessThan);
        return out;
    }

    fn bookMid(self: *BlockExecutor, asset_id: shared.types.AssetId) ?shared.types.Price {
        const best_bid = self.bestOppositePrice(asset_id, true);
        const best_ask = self.bestOppositePrice(asset_id, false);
        if (best_bid != null and best_ask != null) {
            return @intCast((@as(u512, best_bid.?) + @as(u512, best_ask.?)) / 2);
        }
        return best_bid orelse best_ask;
    }

    fn bumpBookSequence(self: *BlockExecutor, asset_id: shared.types.AssetId) !u64 {
        const gop = try self.book_seq.getOrPut(asset_id);
        if (!gop.found_existing) {
            gop.value_ptr.* = 1;
            return 1;
        }
        gop.value_ptr.* += 1;
        return gop.value_ptr.*;
    }

    fn availableAssetBalance(
        self: *BlockExecutor,
        user: shared.types.Address,
        asset_id: shared.types.AssetId,
    ) shared.types.Quantity {
        const master = self.masters.get(user) orelse return 0;
        const sub = master.sub_accounts[0] orelse return 0;
        const raw = sub.collateral.rawBalance(asset_id);
        const reserved = self.reservedAssetAmount(user, asset_id);
        return raw - @min(raw, reserved);
    }

    fn reservedAssetAmount(
        self: *BlockExecutor,
        user: shared.types.Address,
        asset_id: shared.types.AssetId,
    ) shared.types.Quantity {
        const account = self.state.getAccount(user) orelse return 0;
        var reserved: shared.types.Quantity = 0;
        var order_it = account.open_orders.iterator();
        while (order_it.next()) |entry| {
            const order = entry.value_ptr.*;
            if (order.order_type != .limit) continue;
            switch (defaultInstrumentKind(order.asset_id)) {
                .spot => {},
                else => continue,
            }

            if (order.is_buy and asset_id == ch_types.USDC_ID) {
                reserved += shared.fixed_point.mulPriceQty(order.price, order.size);
            } else if (!order.is_buy and asset_id == order.asset_id) {
                reserved += order.size;
            }
        }
        return reserved;
    }

    fn cancelOrder(
        self: *BlockExecutor,
        user: shared.types.Address,
        order_id: u64,
        events_out: *std.ArrayList(shared.protocol.NodeEvent),
        touched_users: *std.AutoHashMap(shared.types.Address, void),
    ) !shared.protocol.ActionAck {
        const account = self.state.getAccount(user) orelse return error.OrderNotFound;
        const removed = account.open_orders.fetchRemove(order_id) orelse return error.OrderNotFound;
        if (removed.value.cloid) |cloid| {
            _ = self.cloid_to_order.remove(.{ .user = user, .cloid = cloid });
        }

        try self.syncUserAccount(user);
        try self.queueOrderUpdate(events_out, order_id, .cancelled);
        try self.queueUserUpdate(events_out, user);
        try self.publishMarketDataForAsset(removed.value.asset_id, events_out);
        try touched_users.put(user, {});

        return .{
            .status = .cancelled,
            .order_id = order_id,
            .error_msg = null,
        };
    }

    fn batchCancel(
        self: *BlockExecutor,
        user: shared.types.Address,
        order_ids: []const u64,
        events_out: *std.ArrayList(shared.protocol.NodeEvent),
        touched_users: *std.AutoHashMap(shared.types.Address, void),
    ) !shared.protocol.ActionAck {
        const account = self.state.getAccount(user) orelse return error.OrderNotFound;
        var cancelled: usize = 0;
        var last_order_id: ?u64 = null;
        var touched_assets = std.AutoHashMap(shared.types.AssetId, void).init(self.allocator);
        defer touched_assets.deinit();
        for (order_ids) |order_id| {
            const removed = account.open_orders.fetchRemove(order_id) orelse continue;
            if (removed.value.cloid) |cloid| {
                _ = self.cloid_to_order.remove(.{ .user = user, .cloid = cloid });
            }
            try self.queueOrderUpdate(events_out, order_id, .cancelled);
            try touched_assets.put(removed.value.asset_id, {});
            cancelled += 1;
            last_order_id = order_id;
        }
        if (cancelled == 0) return error.OrderNotFound;

        try self.syncUserAccount(user);
        try self.queueUserUpdate(events_out, user);
        try self.publishTouchedAssets(&touched_assets, events_out);
        try touched_users.put(user, {});

        return .{
            .status = .cancelled,
            .order_id = last_order_id,
            .error_msg = null,
        };
    }

    fn cancelByCloid(
        self: *BlockExecutor,
        user: shared.types.Address,
        cloid: [16]u8,
        events_out: *std.ArrayList(shared.protocol.NodeEvent),
        touched_users: *std.AutoHashMap(shared.types.Address, void),
    ) !shared.protocol.ActionAck {
        const order_id = self.cloid_to_order.get(.{ .user = user, .cloid = cloid }) orelse return error.OrderNotFound;
        return try self.cancelOrder(user, order_id, events_out, touched_users);
    }

    fn cancelAll(
        self: *BlockExecutor,
        user: shared.types.Address,
        req: shared.types.CancelAllRequest,
        events_out: *std.ArrayList(shared.protocol.NodeEvent),
        touched_users: *std.AutoHashMap(shared.types.Address, void),
    ) !shared.protocol.ActionAck {
        const account = self.state.getAccount(user) orelse return error.OrderNotFound;
        var to_remove = std.ArrayList(u64).empty;
        defer to_remove.deinit(self.allocator);
        var touched_assets = std.AutoHashMap(shared.types.AssetId, void).init(self.allocator);
        defer touched_assets.deinit();

        var open_orders_it = account.open_orders.iterator();
        while (open_orders_it.next()) |entry| {
            const order = entry.value_ptr.*;
            if (req.asset_id) |asset_id| {
                if (order.asset_id != asset_id) continue;
            }
            if (!req.include_triggers and order.order_type == .trigger) continue;
            try to_remove.append(self.allocator, entry.key_ptr.*);
        }
        if (to_remove.items.len == 0) return error.OrderNotFound;

        for (to_remove.items) |order_id| {
            const removed = account.open_orders.fetchRemove(order_id) orelse continue;
            if (removed.value.cloid) |cloid| {
                _ = self.cloid_to_order.remove(.{ .user = user, .cloid = cloid });
            }
            try self.queueOrderUpdate(events_out, order_id, .cancelled);
            try touched_assets.put(removed.value.asset_id, {});
        }

        try self.syncUserAccount(user);
        try self.queueUserUpdate(events_out, user);
        try self.publishTouchedAssets(&touched_assets, events_out);
        try touched_users.put(user, {});

        return .{
            .status = .cancelled,
            .order_id = if (to_remove.items.len > 0) to_remove.items[0] else null,
            .error_msg = null,
        };
    }

    fn updateLeverage(
        self: *BlockExecutor,
        user: shared.types.Address,
        asset_id: shared.types.AssetId,
        leverage: u8,
        events_out: *std.ArrayList(shared.protocol.NodeEvent),
        touched_users: *std.AutoHashMap(shared.types.Address, void),
    ) !shared.protocol.ActionAck {
        const master = self.masters.getPtr(user) orelse return error.SubAccountNotFound;
        const sub = master.subAccountByIndex(0).?;
        const instrument_id = try toInstrumentId(asset_id);
        const pos = sub.positions.getPtr(instrument_id) orelse return error.PositionNotFound;
        const max_leverage = self.marginState(nextBlockTimestamp(self.state)).instrumentMaxLeverage(instrument_id, 50);
        if (leverage == 0 or leverage > max_leverage) return error.InvalidLeverage;
        pos.leverage = leverage;

        try self.syncUserAccount(user);
        try self.queueUserUpdate(events_out, user);
        try touched_users.put(user, {});

        return .{
            .status = .filled,
            .order_id = null,
            .error_msg = null,
        };
    }

    fn updateIsolatedMargin(
        self: *BlockExecutor,
        user: shared.types.Address,
        asset_id: shared.types.AssetId,
        amount_delta: i128,
        events_out: *std.ArrayList(shared.protocol.NodeEvent),
        touched_users: *std.AutoHashMap(shared.types.Address, void),
    ) !shared.protocol.ActionAck {
        const master = self.masters.getPtr(user) orelse return error.SubAccountNotFound;
        const sub = master.subAccountByIndex(0).?;
        const pos = sub.positions.getPtr(try toInstrumentId(asset_id)) orelse return error.PositionNotFound;
        if (amount_delta == 0) return .{ .status = .filled, .order_id = null, .error_msg = null };

        if (amount_delta > 0) {
            const amount: shared.types.Quantity = @intCast(amount_delta);
            try sub.collateral.withdraw(ch_types.USDC_ID, amount);
            pos.isolated_margin += amount;
            pos.margin_mode = .isolated;
        } else {
            const amount: shared.types.Quantity = @intCast(-amount_delta);
            if (!pos.canRemoveMargin()) return error.MarginRemovalNotAllowed;
            if (pos.isolated_margin < amount) return error.InsufficientIsolatedMargin;
            pos.isolated_margin -= amount;
            sub.collateral.credit(ch_types.USDC_ID, amount);
        }

        try self.syncUserAccount(user);
        try self.queueUserUpdate(events_out, user);
        try touched_users.put(user, {});

        return .{
            .status = .filled,
            .order_id = null,
            .error_msg = null,
        };
    }

    fn withdraw(
        self: *BlockExecutor,
        user: shared.types.Address,
        amount: shared.types.Quantity,
        destination: shared.types.Address,
        now_ms: i64,
        events_out: *std.ArrayList(shared.protocol.NodeEvent),
        touched_users: *std.AutoHashMap(shared.types.Address, void),
    ) !shared.protocol.ActionAck {
        const master = self.masters.getPtr(user) orelse return error.SubAccountNotFound;
        _ = try self.clearinghouse.executeWithdrawal(0, ch_types.USDC_ID, amount, destination, master, &self.marginState(now_ms));

        try self.syncUserAccount(user);
        try self.queueUserUpdate(events_out, user);
        try touched_users.put(user, {});

        return .{
            .status = .filled,
            .order_id = null,
            .error_msg = null,
        };
    }

    fn runSystemLiquidations(
        self: *BlockExecutor,
        now_ms: i64,
        events_out: *std.ArrayList(shared.protocol.NodeEvent),
        touched_users: *std.AutoHashMap(shared.types.Address, void),
    ) !void {
        const margin_state = self.marginState(now_ms);
        const candidates = try self.clearinghouse.scanLiquidations(&self.masters, &margin_state);
        defer {
            for (candidates) |candidate| {
                if (candidate.snapshot.len > 0) self.allocator.free(candidate.snapshot);
            }
            if (candidates.len > 0) self.allocator.free(candidates);
        }

        for (candidates) |candidate| {
            const located = self.findSubAccountByAddress(candidate.user) orelse continue;
            const first_pos = if (candidate.snapshot.len > 0) candidate.snapshot[0] else null;
            const result = try self.clearinghouse.executeLiquidation(candidate, located.sub, &margin_state);
            if (first_pos) |pos| {
                const mark_px = margin_state.freshMarkPrice(pos.instrument_id) orelse pos.entry_price;
                try events_out.append(self.allocator, .{ .liquidation = .{
                    .user = located.master,
                    .asset_id = pos.instrument_id,
                    .size = pos.size,
                    .side = pos.side,
                    .mark_px = mark_px,
                    .pnl = result.insurance_fund_delta,
                    .insurance_fund_delta = result.insurance_fund_delta,
                } });
            }
            try self.syncUserAccount(located.master);
            try self.queueUserUpdate(events_out, located.master);
            try touched_users.put(located.master, {});
        }
    }

    fn ensureMaster(self: *BlockExecutor, user: shared.types.Address) !*ch_account.MasterAccount {
        const gop = try self.masters.getOrPut(user);
        if (!gop.found_existing) {
            gop.value_ptr.* = ch_account.MasterAccount.init(self.allocator, user, self.state.timestamp);
            _ = try gop.value_ptr.openSubAccount(0, null, self.state.timestamp);
        }
        return gop.value_ptr;
    }

    fn syncUserAccount(self: *BlockExecutor, user: shared.types.Address) !void {
        const master = self.masters.getPtr(user) orelse return;
        const sub = master.subAccountByIndex(0) orelse return;
        const account = try self.state.getOrCreateAccount(user);

        account.balance = sub.collateral.effectiveTotal(&ch_types.defaultCollateralRegistry);
        account.positions.clearRetainingCapacity();

        var pos_it = sub.positions.iterator();
        while (pos_it.next()) |entry| {
            const pos = entry.value_ptr.*;
            const mark_px = self.marginState(self.state.timestamp).markPrice(pos.instrument_id) orelse pos.entry_price;
            try account.positions.put(entry.key_ptr.*, .{
                .user = user,
                .asset_id = pos.instrument_id,
                .side = pos.side,
                .size = pos.size,
                .entry_price = pos.entry_price,
                .unrealized_pnl = pos.unrealizedPnl(mark_px),
                .isolated_margin = pos.isolated_margin,
                .leverage = pos.leverage,
            });
        }
    }

    fn queueUserUpdate(
        self: *BlockExecutor,
        events_out: *std.ArrayList(shared.protocol.NodeEvent),
        user: shared.types.Address,
    ) !void {
        const account = self.state.getAccount(user) orelse return;
        try events_out.append(self.allocator, .{ .user_update = try buildAccountStateView(self.allocator, account) });
    }

    fn queueOrderUpdate(
        self: *BlockExecutor,
        events_out: *std.ArrayList(shared.protocol.NodeEvent),
        order_id: u64,
        status: shared.types.OrderStatus,
    ) !void {
        try events_out.append(self.allocator, .{ .order_update = .{
            .order_id = order_id,
            .status = status,
        } });
    }

    fn buildOrder(self: *BlockExecutor, user: shared.types.Address, wire: shared.types.OrderWire) !shared.types.Order {
        const order_id = self.next_order_id;
        self.next_order_id += 1;
        return .{
            .id = order_id,
            .user = user,
            .asset_id = wire.a,
            .is_buy = wire.b,
            .price = try parsePrice(wire.p),
            .size = try parseQuantity(wire.s),
            .leverage = if (wire.leverage == 0) 1 else wire.leverage,
            .order_type = wire.t,
            .cloid = try parseCloid(wire.c),
            .nonce = order_id,
        };
    }

    fn buildBlock(self: *BlockExecutor, txs: []shared.types.Transaction, timestamp: i64) !shared.types.Block {
        return .{
            .height = self.state.block_height + 1,
            .round = self.state.block_height + 1,
            .parent_hash = self.state.state_root,
            .txs_hash = try hashTransactions(self.allocator, txs),
            .state_root = try computeStateRoot(self.allocator, self.state),
            .proposer = self.proposer,
            .timestamp = timestamp,
            .transactions = txs,
        };
    }

    fn marginState(self: *BlockExecutor, now_ms: i64) ch_margin.GlobalState {
        current_state = self.state;
        current_now_ms = now_ms;
        return .{
            .markPriceFn = markPriceBridge,
            .markPriceMetaFn = markPriceMetaBridge,
            .indexPriceFn = indexPriceBridge,
            .assetOraclePriceFn = assetOraclePriceBridge,
            .now_ms = now_ms,
        };
    }

    fn cloneTransactions(self: *BlockExecutor, txs: []const shared.types.Transaction) ![]shared.types.Transaction {
        const owned = try self.allocator.alloc(shared.types.Transaction, txs.len);
        errdefer self.allocator.free(owned);
        for (txs, 0..) |tx, idx| {
            owned[idx] = shared.serialization.cloneTransaction(self.allocator, tx) catch |err| {
                var rollback: usize = 0;
                while (rollback < idx) : (rollback += 1) {
                    shared.serialization.deinitTransaction(self.allocator, &owned[rollback]);
                }
                return err;
            };
        }
        return owned;
    }

    fn deinitTransactions(self: *BlockExecutor, txs: []shared.types.Transaction) void {
        for (txs, 0..) |_, idx| {
            shared.serialization.deinitTransaction(self.allocator, &txs[idx]);
        }
        if (txs.len > 0) self.allocator.free(txs);
    }

    fn findSubAccountByAddress(self: *BlockExecutor, sub_addr: shared.types.Address) ?struct { master: shared.types.Address, sub: *ch_account.SubAccount } {
        var masters_it = self.masters.iterator();
        while (masters_it.next()) |entry| {
            if (entry.value_ptr.subAccountByAddr(sub_addr)) |sub| {
                return .{ .master = entry.key_ptr.*, .sub = sub };
            }
        }
        return null;
    }
};

fn rejectedAck(allocator: std.mem.Allocator, err: anyerror) !shared.protocol.ActionAck {
    return .{
        .status = .rejected,
        .order_id = null,
        .error_msg = try allocator.dupe(u8, @errorName(err)),
    };
}

fn buildAccountStateView(
    allocator: std.mem.Allocator,
    account: *const state_mod.AccountEntry,
) !shared.types.AccountState {
    const positions = try allocator.alloc(shared.types.Position, account.positions.count());
    errdefer allocator.free(positions);
    var idx: usize = 0;
    var pos_it = account.positions.iterator();
    while (pos_it.next()) |entry| {
        positions[idx] = entry.value_ptr.*;
        idx += 1;
    }

    const open_orders = try buildOpenOrdersView(allocator, account);
    errdefer if (open_orders.len > 0) allocator.free(open_orders);

    return .{
        .address = account.address,
        .balance = account.balance,
        .positions = positions,
        .open_orders = open_orders,
        .api_wallet = account.api_wallet,
    };
}

fn buildOpenOrdersView(
    allocator: std.mem.Allocator,
    account: *const state_mod.AccountEntry,
) ![]u64 {
    const open_orders = try allocator.alloc(u64, account.open_orders.count());
    var idx: usize = 0;
    var it = account.open_orders.iterator();
    while (it.next()) |entry| {
        open_orders[idx] = entry.key_ptr.*;
        idx += 1;
    }
    std.mem.sort(u64, open_orders, {}, struct {
        fn lessThan(_: void, a: u64, b: u64) bool {
            return a < b;
        }
    }.lessThan);
    return open_orders;
}

fn parsePrice(value: []const u8) !shared.types.Price {
    return try parseScaledDecimal(shared.types.Price, value, 36, shared.types.PRICE_SCALE);
}

fn parseQuantity(value: []const u8) !shared.types.Quantity {
    return try parseScaledDecimal(shared.types.Quantity, value, 0, 1);
}

fn parseScaledDecimal(comptime T: type, value: []const u8, decimals: usize, scale: T) !T {
    const dot_index = std.mem.indexOfScalar(u8, value, '.');
    const whole_part = if (dot_index) |idx| value[0..idx] else value;
    const frac_part = if (dot_index) |idx| value[idx + 1 ..] else "";

    const whole = if (whole_part.len == 0) 0 else try std.fmt.parseInt(T, whole_part, 10);
    var result: T = whole * scale;

    if (frac_part.len == 0) return result;
    if (decimals == 0) {
        for (frac_part) |ch| {
            if (ch != '0') return error.InvalidQuantityScale;
        }
        return result;
    }

    var frac_value: T = 0;
    var used_digits: usize = 0;
    for (frac_part) |ch| {
        if (ch < '0' or ch > '9') return error.InvalidDecimal;
        if (used_digits < decimals) {
            frac_value = frac_value * 10 + @as(T, ch - '0');
            used_digits += 1;
        } else if (ch != '0') {
            return error.TooManyDecimals;
        }
    }

    var remaining = decimals - used_digits;
    while (remaining > 0) : (remaining -= 1) {
        frac_value *= 10;
    }

    result += frac_value;
    return result;
}

fn parseCloid(value: ?[]const u8) !?[16]u8 {
    if (value == null) return null;
    const raw = value.?;
    if (raw.len > 16) return error.CloidTooLong;
    var out = [_]u8{0} ** 16;
    @memcpy(out[0..raw.len], raw);
    return out;
}

fn toInstrumentId(asset_id: shared.types.AssetId) !ch_types.InstrumentId {
    return std.math.cast(ch_types.InstrumentId, asset_id) orelse error.InvalidInstrumentId;
}

fn nextBlockTimestamp(state: *const state_mod.GlobalState) i64 {
    return if (state.timestamp == 0) 1_700_000_000_000 else state.timestamp + 1_000;
}

fn hashTransactions(allocator: std.mem.Allocator, txs: []const shared.types.Transaction) ![32]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    for (txs) |tx| {
        const encoded = try shared.serialization.encodeTransaction(allocator, tx);
        defer allocator.free(encoded);
        hasher.update(encoded);
    }
    var out: [32]u8 = undefined;
    hasher.final(&out);
    return out;
}

fn computeStateRoot(allocator: std.mem.Allocator, state: *const state_mod.GlobalState) ![32]u8 {
    var account_keys = std.ArrayList(shared.types.Address).empty;
    defer account_keys.deinit(allocator);

    var accounts_it = state.accounts.iterator();
    while (accounts_it.next()) |entry| {
        try account_keys.append(allocator, entry.key_ptr.*);
    }
    std.mem.sort(shared.types.Address, account_keys.items, {}, struct {
        fn lessThan(_: void, a: shared.types.Address, b: shared.types.Address) bool {
            return std.mem.order(u8, a[0..], b[0..]) == .lt;
        }
    }.lessThan);

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    for (account_keys.items) |address| {
        const account = state.accounts.get(address).?;
        hasher.update(address[0..]);

        var balance_bytes: [16]u8 = undefined;
        std.mem.writeInt(u128, &balance_bytes, account.balance, .big);
        hasher.update(&balance_bytes);

        var position_keys = std.ArrayList(shared.types.AssetId).empty;
        defer position_keys.deinit(allocator);
        var pos_it = account.positions.iterator();
        while (pos_it.next()) |entry| {
            try position_keys.append(allocator, entry.key_ptr.*);
        }
        std.mem.sort(shared.types.AssetId, position_keys.items, {}, struct {
            fn lessThan(_: void, a: shared.types.AssetId, b: shared.types.AssetId) bool {
                return a < b;
            }
        }.lessThan);
        for (position_keys.items) |asset_id| {
            const pos = account.positions.get(asset_id).?;
            var asset_bytes: [8]u8 = undefined;
            std.mem.writeInt(u64, &asset_bytes, asset_id, .big);
            hasher.update(&asset_bytes);
            hasher.update(&[_]u8{@intFromEnum(pos.side)});
            var size_bytes: [16]u8 = undefined;
            std.mem.writeInt(u128, &size_bytes, pos.size, .big);
            hasher.update(&size_bytes);
        }

        const open_orders = try buildOpenOrdersView(allocator, &account);
        defer if (open_orders.len > 0) allocator.free(open_orders);
        for (open_orders) |order_id| {
            var order_bytes: [8]u8 = undefined;
            std.mem.writeInt(u64, &order_bytes, order_id, .big);
            hasher.update(&order_bytes);
        }
    }

    var out: [32]u8 = undefined;
    hasher.final(&out);
    return out;
}

fn defaultInstrumentKind(asset_id: shared.types.AssetId) ch_types.InstrumentKind {
    return switch (asset_id) {
        ch_types.BTC_ID, ch_types.ETH_ID, ch_types.SOL_ID, ch_types.HYPE_ID => .spot,
        else => .{ .perp = defaultPerpSpec() },
    };
}

fn defaultPerpSpec() ch_types.PerpSpec {
    return .{
        .tick_size = shared.types.PRICE_SCALE,
        .lot_size = 1,
        .max_leverage = 50,
        .funding_interval_ms = 3_600_000,
        .mark_method = .oracle,
        .isolated_only = false,
    };
}

fn shouldTrigger(is_buy: bool, trigger: shared.types.TriggerOrderType, price: shared.types.Price) bool {
    return if (is_buy) price >= trigger.trigger_px else price <= trigger.trigger_px;
}

fn crosses(is_buy: bool, taker_price: shared.types.Price, maker_price: shared.types.Price) bool {
    return if (is_buy) taker_price >= maker_price else taker_price <= maker_price;
}

fn betterMatch(
    taker_is_buy: bool,
    candidate: shared.types.Order,
    best: struct { user: shared.types.Address, order_id: u64, price: shared.types.Price },
) bool {
    if (candidate.price != best.price) {
        return if (taker_is_buy) candidate.price < best.price else candidate.price > best.price;
    }
    return candidate.id < best.order_id;
}

fn combineAckStatus(
    current: shared.types.OrderStatus,
    incoming: shared.types.OrderStatus,
) shared.types.OrderStatus {
    if (current == .resting or incoming == .resting) return .resting;
    if (current == .filled or incoming == .filled) return .filled;
    if (current == .cancelled or incoming == .cancelled) return .cancelled;
    return incoming;
}

fn markPriceBridge(instrument_id: ch_types.InstrumentId) ?shared.types.Price {
    return current_state.?.getOraclePrice(instrument_id);
}

fn indexPriceBridge(instrument_id: ch_types.InstrumentId) ?shared.types.Price {
    return current_state.?.getOraclePrice(instrument_id);
}

fn assetOraclePriceBridge(asset_id: ch_types.AssetId) ?shared.types.Price {
    return current_state.?.getOraclePrice(asset_id);
}

fn markPriceMetaBridge(instrument_id: ch_types.InstrumentId) ?ch_margin.MarkPriceView {
    const price = current_state.?.getOraclePrice(instrument_id) orelse return null;
    return .{
        .price = price,
        .updated_at_ms = current_now_ms,
    };
}

threadlocal var current_state: ?*state_mod.GlobalState = null;
threadlocal var current_now_ms: i64 = 0;

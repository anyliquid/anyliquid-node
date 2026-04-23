const std = @import("std");
const shared = @import("../../shared/mod.zig");
const risk_mod = @import("risk.zig");
const state_mod = @import("../state.zig");

pub const MatchingError = error{
    AssetNotFound,
    FokCannotFill,
    InvalidPriceScale,
    OrderNotFound,
    WouldTakeNotPost,
} || risk_mod.RiskError || std.mem.Allocator.Error;

const BookOrder = struct {
    order: shared.types.Order,
    remaining: shared.types.Quantity,
    placed_seq: u64,
    trigger: ?shared.types.TriggerOrderType = null,
};

const OrderBook = struct {
    asset_id: shared.types.AssetId,
    bids: std.ArrayList(u64),
    asks: std.ArrayList(u64),
    triggers: std.ArrayList(u64),
    orders: std.AutoHashMap(u64, BookOrder),
    cloid_map: std.AutoHashMap([16]u8, u64),
    seq: u64 = 0,

    fn init(asset_id: shared.types.AssetId, allocator: std.mem.Allocator) OrderBook {
        return .{
            .asset_id = asset_id,
            .bids = .empty,
            .asks = .empty,
            .triggers = .empty,
            .orders = std.AutoHashMap(u64, BookOrder).init(allocator),
            .cloid_map = std.AutoHashMap([16]u8, u64).init(allocator),
        };
    }

    fn deinit(self: *OrderBook, allocator: std.mem.Allocator) void {
        self.cloid_map.deinit();
        self.orders.deinit();
        self.triggers.deinit(allocator);
        self.asks.deinit(allocator);
        self.bids.deinit(allocator);
    }
};

pub const MatchingEngine = struct {
    allocator: std.mem.Allocator,
    risk: *risk_mod.RiskEngine,
    books: std.AutoHashMap(shared.types.AssetId, OrderBook),
    order_asset: std.AutoHashMap(u64, shared.types.AssetId),
    next_order_id: u64 = 1,
    next_seq: u64 = 1,

    pub fn init(risk: *risk_mod.RiskEngine, allocator: std.mem.Allocator) !MatchingEngine {
        return .{
            .allocator = allocator,
            .risk = risk,
            .books = std.AutoHashMap(shared.types.AssetId, OrderBook).init(allocator),
            .order_asset = std.AutoHashMap(u64, shared.types.AssetId).init(allocator),
        };
    }

    pub fn deinit(self: *MatchingEngine) void {
        var it = self.books.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.order_asset.deinit();
        self.books.deinit();
    }

    pub fn placeOrder(
        self: *MatchingEngine,
        order: shared.types.Order,
        state: *state_mod.GlobalState,
    ) MatchingError![]shared.types.Fill {
        var fills = std.ArrayList(shared.types.Fill).empty;
        defer fills.deinit(self.allocator);

        const book = try self.ensureBook(order.asset_id);
        var normalized = order;
        if (normalized.id == 0) {
            normalized.id = self.next_order_id;
            self.next_order_id += 1;
        }

        switch (normalized.order_type) {
            .limit => {
                if (!shared.types.isValidPrice(normalized.price, defaultTickSize())) {
                    return error.InvalidPriceScale;
                }
            },
            .trigger => |trigger| {
                if (!shared.types.isValidPrice(trigger.trigger_px, defaultTickSize())) {
                    return error.InvalidPriceScale;
                }
                if (!trigger.is_market and !shared.types.isValidPrice(normalized.price, defaultTickSize())) {
                    return error.InvalidPriceScale;
                }
            },
        }

        switch (normalized.order_type) {
            .trigger => {
                try self.insertTrigger(book, normalized);
                self.risk.onBookUpdate(order.asset_id, bestBid(book), bestAsk(book), state);
                return fills.toOwnedSlice(self.allocator);
            },
            .limit => {},
        }

        switch (normalized.order_type) {
            .limit => |tif| {
                if (tif == .fok and !self.canFullyFill(book, normalized)) {
                    return error.FokCannotFill;
                }
                if (tif == .alo and wouldCross(book, normalized)) {
                    return error.WouldTakeNotPost;
                }
            },
            .trigger => unreachable,
        }

        var taker = BookOrder{
            .order = normalized,
            .remaining = normalized.size,
            .placed_seq = self.nextSequence(book),
        };
        try self.matchAgainstBook(book, &taker, &fills, state);

        switch (normalized.order_type) {
            .limit => |tif| switch (tif) {
                .gtc, .alo => {
                    if (taker.remaining > 0) try self.insertResting(book, taker);
                },
                .ioc, .fok => {},
            },
            .trigger => unreachable,
        }

        self.risk.onBookUpdate(order.asset_id, bestBid(book), bestAsk(book), state);
        return fills.toOwnedSlice(self.allocator);
    }

    pub fn cancelOrder(
        self: *MatchingEngine,
        cancel: shared.types.CancelRequest,
        state: *state_mod.GlobalState,
    ) MatchingError!void {
        const asset_id = self.order_asset.get(cancel.order_id) orelse return error.OrderNotFound;
        const book = self.books.getPtr(asset_id) orelse return error.OrderNotFound;
        try self.removeOrder(book, cancel.order_id);
        self.risk.onBookUpdate(asset_id, bestBid(book), bestAsk(book), state);
    }

    pub fn cancelByCloid(
        self: *MatchingEngine,
        req: shared.types.CancelByCloidRequest,
        state: *state_mod.GlobalState,
    ) MatchingError!void {
        var it = self.books.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.cloid_map.get(req.cloid)) |order_id| {
                try self.removeOrder(entry.value_ptr, order_id);
                self.risk.onBookUpdate(entry.key_ptr.*, bestBid(entry.value_ptr), bestAsk(entry.value_ptr), state);
                return;
            }
        }
        return error.OrderNotFound;
    }

    pub fn batchCancel(
        self: *MatchingEngine,
        user: shared.types.Address,
        req: shared.types.BatchCancelRequest,
        state: *state_mod.GlobalState,
    ) MatchingError!usize {
        var touched_assets = std.AutoHashMap(shared.types.AssetId, void).init(self.allocator);
        defer touched_assets.deinit();

        var cancelled: usize = 0;
        for (req.order_ids) |order_id| {
            const asset_id = self.order_asset.get(order_id) orelse continue;
            const book = self.books.getPtr(asset_id) orelse continue;
            const record = book.orders.get(order_id) orelse continue;
            if (!std.mem.eql(u8, record.order.user[0..], user[0..])) continue;

            try self.removeOrder(book, order_id);
            cancelled += 1;
            try touched_assets.put(asset_id, {});
        }

        try self.publishTouchedBooks(&touched_assets, state);
        return cancelled;
    }

    pub fn cancelAll(
        self: *MatchingEngine,
        user: shared.types.Address,
        req: shared.types.CancelAllRequest,
        state: *state_mod.GlobalState,
    ) MatchingError!usize {
        var touched_assets = std.AutoHashMap(shared.types.AssetId, void).init(self.allocator);
        defer touched_assets.deinit();

        var cancelled: usize = 0;
        var books_it = self.books.iterator();
        while (books_it.next()) |entry| {
            const asset_id = entry.key_ptr.*;
            if (req.asset_id) |filter_asset_id| {
                if (filter_asset_id != asset_id) continue;
            }

            const book = entry.value_ptr;
            var to_remove = std.ArrayList(u64).empty;
            defer to_remove.deinit(self.allocator);

            for (book.bids.items) |order_id| {
                const record = book.orders.get(order_id) orelse continue;
                if (std.mem.eql(u8, record.order.user[0..], user[0..])) {
                    try to_remove.append(self.allocator, order_id);
                }
            }
            for (book.asks.items) |order_id| {
                const record = book.orders.get(order_id) orelse continue;
                if (std.mem.eql(u8, record.order.user[0..], user[0..])) {
                    try to_remove.append(self.allocator, order_id);
                }
            }
            if (req.include_triggers) {
                for (book.triggers.items) |order_id| {
                    const record = book.orders.get(order_id) orelse continue;
                    if (std.mem.eql(u8, record.order.user[0..], user[0..])) {
                        try to_remove.append(self.allocator, order_id);
                    }
                }
            }

            for (to_remove.items) |order_id| {
                try self.removeOrder(book, order_id);
                cancelled += 1;
            }
            if (to_remove.items.len > 0) {
                try touched_assets.put(asset_id, {});
            }
        }

        try self.publishTouchedBooks(&touched_assets, state);
        return cancelled;
    }

    pub fn checkTriggers(
        self: *MatchingEngine,
        asset_id: shared.types.AssetId,
        price: shared.types.Price,
        state: *state_mod.GlobalState,
    ) MatchingError![]shared.types.Fill {
        if (!shared.types.isValidPrice(price, defaultTickSize())) return error.InvalidPriceScale;

        var fills = std.ArrayList(shared.types.Fill).empty;
        defer fills.deinit(self.allocator);

        const book = self.books.getPtr(asset_id) orelse return fills.toOwnedSlice(self.allocator);
        var idx: usize = 0;
        while (idx < book.triggers.items.len) {
            const order_id = book.triggers.items[idx];
            const triggered = book.orders.get(order_id) orelse {
                _ = book.triggers.orderedRemove(idx);
                continue;
            };

            if (!shouldTrigger(triggered.order.is_buy, triggered.trigger.?, price)) {
                idx += 1;
                continue;
            }

            _ = book.triggers.orderedRemove(idx);
            var activated = triggered.order;
            const trigger = triggered.trigger.?;
            if (trigger.is_market) {
                activated.price = if (activated.is_buy) shared.types.maxScaledPrice() else 0;
                activated.order_type = .{ .limit = .ioc };
            } else {
                activated.order_type = .{ .limit = .gtc };
            }

            _ = book.orders.remove(order_id);
            _ = self.order_asset.remove(order_id);
            if (activated.cloid) |cloid| _ = book.cloid_map.remove(cloid);

            const trigger_fills = try self.placeOrder(activated, state);
            defer self.allocator.free(trigger_fills);
            try fills.appendSlice(self.allocator, trigger_fills);
        }

        self.risk.onBookUpdate(asset_id, bestBid(book), bestAsk(book), state);
        return fills.toOwnedSlice(self.allocator);
    }

    pub fn getL2Snapshot(
        self: *MatchingEngine,
        asset_id: shared.types.AssetId,
        depth: u32,
    ) !shared.types.L2Snapshot {
        const book = self.books.getPtr(asset_id) orelse return error.AssetNotFound;
        const bids = try aggregateSide(self.allocator, book, .bids, depth);
        errdefer self.allocator.free(bids);
        const asks = try aggregateSide(self.allocator, book, .asks, depth);
        errdefer self.allocator.free(asks);

        return .{
            .asset_id = asset_id,
            .seq = book.seq,
            .bids = bids,
            .asks = asks,
            .is_snapshot = true,
        };
    }

    fn ensureBook(self: *MatchingEngine, asset_id: shared.types.AssetId) !*OrderBook {
        const gop = try self.books.getOrPut(asset_id);
        if (!gop.found_existing) {
            gop.value_ptr.* = OrderBook.init(asset_id, self.allocator);
        }
        return gop.value_ptr;
    }

    fn insertTrigger(self: *MatchingEngine, book: *OrderBook, order: shared.types.Order) !void {
        const record = BookOrder{
            .order = order,
            .remaining = order.size,
            .placed_seq = self.nextSequence(book),
            .trigger = order.order_type.trigger,
        };
        try book.orders.put(order.id, record);
        try book.triggers.append(self.allocator, order.id);
        try self.order_asset.put(order.id, order.asset_id);
        if (order.cloid) |cloid| try book.cloid_map.put(cloid, order.id);
    }

    fn insertResting(self: *MatchingEngine, book: *OrderBook, record: BookOrder) !void {
        try book.orders.put(record.order.id, record);
        try self.order_asset.put(record.order.id, record.order.asset_id);
        if (record.order.cloid) |cloid| try book.cloid_map.put(cloid, record.order.id);

        const side = if (record.order.is_buy) &book.bids else &book.asks;
        const index = findInsertIndex(book, side.items, record.order.id, record);
        try side.insert(self.allocator, index, record.order.id);
    }

    fn matchAgainstBook(
        self: *MatchingEngine,
        book: *OrderBook,
        taker: *BookOrder,
        fills: *std.ArrayList(shared.types.Fill),
        state: *state_mod.GlobalState,
    ) MatchingError!void {
        const maker_side = if (taker.order.is_buy) &book.asks else &book.bids;

        while (taker.remaining > 0 and maker_side.items.len > 0) {
            const maker_id = maker_side.items[0];
            const maker = book.orders.getPtr(maker_id).?;
            if (!crosses(taker.order.is_buy, taker.order.price, maker.order.price)) break;

            const fill_size = @min(taker.remaining, maker.remaining);
            try self.risk.onFill(&taker.order, &maker.order, fill_size, maker.order.price, state);

            try fills.append(self.allocator, .{
                .taker_order_id = taker.order.id,
                .maker_order_id = maker.order.id,
                .asset_id = taker.order.asset_id,
                .price = maker.order.price,
                .size = fill_size,
                .taker_addr = taker.order.user,
                .maker_addr = maker.order.user,
                .timestamp = state.timestamp,
                .fee = 0,
            });

            taker.remaining -= fill_size;
            maker.remaining -= fill_size;
            state.timestamp += 1;

            if (maker.remaining == 0) {
                try self.removeOrder(book, maker_id);
            }
        }
    }

    fn removeOrder(self: *MatchingEngine, book: *OrderBook, order_id: u64) MatchingError!void {
        const record = book.orders.get(order_id) orelse return error.OrderNotFound;
        if (record.order.cloid) |cloid| _ = book.cloid_map.remove(cloid);
        _ = self.order_asset.remove(order_id);

        if (record.trigger != null) {
            removeFromIdList(&book.triggers, order_id);
        } else if (record.order.is_buy) {
            removeFromIdList(&book.bids, order_id);
        } else {
            removeFromIdList(&book.asks, order_id);
        }

        _ = book.orders.remove(order_id);
        book.seq += 1;
    }

    fn canFullyFill(self: *MatchingEngine, book: *OrderBook, order: shared.types.Order) bool {
        _ = self;
        const maker_side = if (order.is_buy) book.asks.items else book.bids.items;
        var remaining = order.size;
        for (maker_side) |maker_id| {
            const maker = book.orders.get(maker_id).?;
            if (!crosses(order.is_buy, order.price, maker.order.price)) break;
            if (maker.remaining >= remaining) return true;
            remaining -= maker.remaining;
        }
        return remaining == 0;
    }

    fn nextSequence(self: *MatchingEngine, book: *OrderBook) u64 {
        const seq = self.next_seq;
        self.next_seq += 1;
        book.seq += 1;
        return seq;
    }

    fn publishTouchedBooks(
        self: *MatchingEngine,
        touched_assets: *const std.AutoHashMap(shared.types.AssetId, void),
        state: *state_mod.GlobalState,
    ) MatchingError!void {
        var it = touched_assets.iterator();
        while (it.next()) |entry| {
            const book = self.books.getPtr(entry.key_ptr.*) orelse continue;
            self.risk.onBookUpdate(entry.key_ptr.*, bestBid(book), bestAsk(book), state);
        }
    }
};

fn aggregateSide(
    allocator: std.mem.Allocator,
    book: *const OrderBook,
    comptime side: enum { bids, asks },
    depth: u32,
) ![]shared.types.Level {
    var out = std.ArrayList(shared.types.Level).empty;
    defer out.deinit(allocator);

    const ids = switch (side) {
        .bids => book.bids.items,
        .asks => book.asks.items,
    };

    var current_price: ?shared.types.Price = null;
    var current_size: shared.types.Quantity = 0;
    for (ids) |order_id| {
        const order = book.orders.get(order_id).?;
        if (current_price == null or current_price.? != order.order.price) {
            if (current_price != null) {
                try out.append(allocator, .{ .price = current_price.?, .size = current_size });
                if (out.items.len >= depth) break;
            }
            current_price = order.order.price;
            current_size = order.remaining;
        } else {
            current_size += order.remaining;
        }
    }

    if (current_price != null and out.items.len < depth) {
        try out.append(allocator, .{ .price = current_price.?, .size = current_size });
    }

    return out.toOwnedSlice(allocator);
}

fn removeFromIdList(list: *std.ArrayList(u64), order_id: u64) void {
    var idx: usize = 0;
    while (idx < list.items.len) : (idx += 1) {
        if (list.items[idx] == order_id) {
            _ = list.orderedRemove(idx);
            return;
        }
    }
}

fn findInsertIndex(book: *const OrderBook, ids: []const u64, order_id: u64, record: BookOrder) usize {
    _ = order_id;
    var idx: usize = 0;
    while (idx < ids.len) : (idx += 1) {
        const candidate = book.orders.get(ids[idx]).?;
        if (better(record, candidate)) return idx;
    }
    return ids.len;
}

fn better(lhs: BookOrder, rhs: BookOrder) bool {
    if (lhs.order.is_buy != rhs.order.is_buy) return lhs.order.is_buy;
    if (lhs.order.price != rhs.order.price) {
        return if (lhs.order.is_buy) lhs.order.price > rhs.order.price else lhs.order.price < rhs.order.price;
    }
    return lhs.placed_seq < rhs.placed_seq;
}

fn crosses(is_buy: bool, taker_price: shared.types.Price, maker_price: shared.types.Price) bool {
    return if (is_buy) taker_price >= maker_price else taker_price <= maker_price;
}

fn wouldCross(book: *const OrderBook, order: shared.types.Order) bool {
    const best_ask = bestAsk(book);
    const best_bid = bestBid(book);
    return if (order.is_buy)
        best_ask != null and crosses(true, order.price, best_ask.?)
    else
        best_bid != null and crosses(false, order.price, best_bid.?);
}

fn bestBid(book: *const OrderBook) ?shared.types.Price {
    if (book.bids.items.len == 0) return null;
    return book.orders.get(book.bids.items[0]).?.order.price;
}

fn bestAsk(book: *const OrderBook) ?shared.types.Price {
    if (book.asks.items.len == 0) return null;
    return book.orders.get(book.asks.items[0]).?.order.price;
}

fn shouldTrigger(is_buy: bool, trigger: shared.types.TriggerOrderType, price: shared.types.Price) bool {
    _ = trigger.tpsl;
    return if (is_buy) price >= trigger.trigger_px else price <= trigger.trigger_px;
}

fn defaultTickSize() shared.types.Price {
    return shared.types.PRICE_SCALE;
}

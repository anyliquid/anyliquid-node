const std = @import("std");
const protocol = @import("protocol.zig");
const types = @import("types.zig");

pub const SerializationError = error{
    InvalidFormat,
    InvalidTag,
    TrailingBytes,
    UnexpectedFrameType,
    UnexpectedEndOfStream,
};

pub const Error = SerializationError || std.mem.Allocator.Error;

const Reader = struct {
    bytes: []const u8,
    index: usize = 0,

    fn readByte(self: *Reader) SerializationError!u8 {
        if (self.index >= self.bytes.len) return error.UnexpectedEndOfStream;
        const byte = self.bytes[self.index];
        self.index += 1;
        return byte;
    }

    fn readBool(self: *Reader) SerializationError!bool {
        return switch (try self.readByte()) {
            0 => false,
            1 => true,
            else => error.InvalidFormat,
        };
    }

    fn readInt(self: *Reader, comptime T: type) SerializationError!T {
        const len = @sizeOf(T);
        if (self.index + len > self.bytes.len) return error.UnexpectedEndOfStream;
        const value = std.mem.readInt(T, self.bytes[self.index..][0..len], .little);
        self.index += len;
        return value;
    }

    fn readFixed(self: *Reader, comptime N: usize) SerializationError![N]u8 {
        if (self.index + N > self.bytes.len) return error.UnexpectedEndOfStream;
        const out = self.bytes[self.index..][0..N].*;
        self.index += N;
        return out;
    }

    fn readOwnedSlice(self: *Reader, allocator: std.mem.Allocator) Error![]u8 {
        const len = try self.readInt(u32);
        if (self.index + len > self.bytes.len) return error.UnexpectedEndOfStream;
        defer self.index += len;
        return allocator.dupe(u8, self.bytes[self.index..][0..len]);
    }

    fn readOptionalOwnedSlice(self: *Reader, allocator: std.mem.Allocator) Error!?[]u8 {
        if (!try self.readBool()) return null;
        return try self.readOwnedSlice(allocator);
    }

    fn finish(self: *Reader) SerializationError!void {
        if (self.index != self.bytes.len) return error.TrailingBytes;
    }
};

fn writeInt(list: *std.ArrayList(u8), allocator: std.mem.Allocator, comptime T: type, value: T) Error!void {
    var buf: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &buf, value, .little);
    try list.appendSlice(allocator, buf[0..]);
}

fn writeBool(list: *std.ArrayList(u8), allocator: std.mem.Allocator, value: bool) Error!void {
    try list.append(allocator, if (value) 1 else 0);
}

fn writeBytes(list: *std.ArrayList(u8), allocator: std.mem.Allocator, bytes: []const u8) Error!void {
    try writeInt(list, allocator, u32, @intCast(bytes.len));
    try list.appendSlice(allocator, bytes);
}

fn writeOptionalBytes(list: *std.ArrayList(u8), allocator: std.mem.Allocator, bytes: ?[]const u8) Error!void {
    try writeBool(list, allocator, bytes != null);
    if (bytes) |present| {
        try writeBytes(list, allocator, present);
    }
}

fn writeAddress(list: *std.ArrayList(u8), allocator: std.mem.Allocator, address: types.Address) Error!void {
    try list.appendSlice(allocator, address[0..]);
}

fn writeSignature(list: *std.ArrayList(u8), allocator: std.mem.Allocator, sig: types.EIP712Signature) Error!void {
    try list.appendSlice(allocator, sig.r[0..]);
    try list.appendSlice(allocator, sig.s[0..]);
    try list.append(allocator, sig.v);
}

fn readSignature(reader: *Reader) SerializationError!types.EIP712Signature {
    return .{
        .r = try reader.readFixed(32),
        .s = try reader.readFixed(32),
        .v = try reader.readByte(),
    };
}

fn writeLevel(list: *std.ArrayList(u8), allocator: std.mem.Allocator, level: types.Level) Error!void {
    try writeInt(list, allocator, types.Price, level.price);
    try writeInt(list, allocator, types.Quantity, level.size);
}

fn readLevel(reader: *Reader) SerializationError!types.Level {
    return .{
        .price = try reader.readInt(types.Price),
        .size = try reader.readInt(types.Quantity),
    };
}

fn writeOrderType(list: *std.ArrayList(u8), allocator: std.mem.Allocator, order_type: types.OrderType) Error!void {
    switch (order_type) {
        .limit => |tif| {
            try list.append(allocator, 0);
            try list.append(allocator, @intFromEnum(tif));
        },
        .trigger => |trigger| {
            try list.append(allocator, 1);
            try writeInt(list, allocator, types.Price, trigger.trigger_px);
            try writeBool(list, allocator, trigger.is_market);
            try list.append(allocator, @intFromEnum(trigger.tpsl));
        },
    }
}

fn readOrderType(reader: *Reader) SerializationError!types.OrderType {
    return switch (try reader.readByte()) {
        0 => .{ .limit = @enumFromInt(try reader.readByte()) },
        1 => .{ .trigger = .{
            .trigger_px = try reader.readInt(types.Price),
            .is_market = try reader.readBool(),
            .tpsl = @enumFromInt(try reader.readByte()),
        } },
        else => error.InvalidTag,
    };
}

fn writeOrderWire(list: *std.ArrayList(u8), allocator: std.mem.Allocator, order: types.OrderWire) Error!void {
    try writeInt(list, allocator, types.AssetId, order.a);
    try writeBool(list, allocator, order.b);
    try writeBytes(list, allocator, order.p);
    try writeBytes(list, allocator, order.s);
    try list.append(allocator, order.leverage);
    try writeBool(list, allocator, order.r);
    try writeOrderType(list, allocator, order.t);
    try writeOptionalBytes(list, allocator, order.c);
}

fn decodeOrderWireInto(reader: *Reader, allocator: std.mem.Allocator, out: *types.OrderWire) Error!void {
    out.* = .{
        .a = try reader.readInt(types.AssetId),
        .b = try reader.readBool(),
        .p = try reader.readOwnedSlice(allocator),
        .s = undefined,
        .leverage = 1,
        .r = false,
        .t = undefined,
        .c = null,
    };
    errdefer allocator.free(out.p);

    out.s = try reader.readOwnedSlice(allocator);
    errdefer allocator.free(out.s);

    out.leverage = try reader.readByte();
    out.r = try reader.readBool();
    out.t = try readOrderType(reader);
    out.c = try reader.readOptionalOwnedSlice(allocator);
}

fn writeOrderAction(list: *std.ArrayList(u8), allocator: std.mem.Allocator, action: types.OrderAction) Error!void {
    try writeBytes(list, allocator, action.type);
    try writeInt(list, allocator, u32, @intCast(action.orders.len));
    for (action.orders) |order| {
        try writeOrderWire(list, allocator, order);
    }
    try list.append(allocator, @intFromEnum(action.grouping));
}

fn decodeOrderActionInto(reader: *Reader, allocator: std.mem.Allocator, out: *types.OrderAction) Error!void {
    out.* = .{
        .type = try reader.readOwnedSlice(allocator),
        .orders = &.{},
        .grouping = .none,
    };
    errdefer allocator.free(out.type);

    const len = try reader.readInt(u32);
    const orders = try allocator.alloc(types.OrderWire, len);
    errdefer allocator.free(orders);
    for (orders, 0..) |*order, idx| {
        decodeOrderWireInto(reader, allocator, order) catch |err| {
            var rollback: usize = 0;
            while (rollback < idx) : (rollback += 1) {
                deinitOrderWire(allocator, &orders[rollback]);
            }
            return err;
        };
    }
    out.orders = orders;
    out.grouping = @enumFromInt(try reader.readByte());
}

fn writeActionPayload(list: *std.ArrayList(u8), allocator: std.mem.Allocator, payload: types.ActionPayload) Error!void {
    switch (payload) {
        .order => |order| {
            try list.append(allocator, 0);
            try writeOrderAction(list, allocator, order);
        },
        .cancel => |cancel| {
            try list.append(allocator, 1);
            try writeInt(list, allocator, u64, cancel.order_id);
        },
        .batch_cancel => |cancel| {
            try list.append(allocator, 7);
            try writeInt(list, allocator, u32, @intCast(cancel.order_ids.len));
            for (cancel.order_ids) |order_id| {
                try writeInt(list, allocator, u64, order_id);
            }
        },
        .cancel_by_cloid => |cancel| {
            try list.append(allocator, 2);
            try list.appendSlice(allocator, cancel.cloid[0..]);
        },
        .cancel_all => |cancel| {
            try list.append(allocator, 8);
            try list.append(allocator, @intFromBool(cancel.asset_id != null));
            if (cancel.asset_id) |asset_id| {
                try writeInt(list, allocator, types.AssetId, asset_id);
            }
            try list.append(allocator, @intFromBool(cancel.include_triggers));
        },
        .batch_orders => |orders| {
            try list.append(allocator, 3);
            try writeInt(list, allocator, u32, @intCast(orders.len));
            for (orders) |order| {
                try writeOrderAction(list, allocator, order);
            }
        },
        .update_leverage => |update| {
            try list.append(allocator, 4);
            try writeInt(list, allocator, types.AssetId, update.asset_id);
            try list.append(allocator, update.leverage);
        },
        .update_isolated_margin => |update| {
            try list.append(allocator, 5);
            try writeInt(list, allocator, types.AssetId, update.asset_id);
            try writeInt(list, allocator, i128, update.amount_delta);
        },
        .withdraw => |withdraw| {
            try list.append(allocator, 6);
            try writeInt(list, allocator, types.Quantity, withdraw.amount);
            try writeAddress(list, allocator, withdraw.destination);
        },
    }
}

fn decodeActionPayloadInto(reader: *Reader, allocator: std.mem.Allocator, out: *types.ActionPayload) Error!void {
    switch (try reader.readByte()) {
        0 => {
            var order: types.OrderAction = undefined;
            try decodeOrderActionInto(reader, allocator, &order);
            out.* = .{ .order = order };
        },
        1 => out.* = .{ .cancel = .{ .order_id = try reader.readInt(u64) } },
        2 => out.* = .{ .cancel_by_cloid = .{ .cloid = try reader.readFixed(16) } },
        3 => {
            const len = try reader.readInt(u32);
            const orders = try allocator.alloc(types.OrderAction, len);
            errdefer allocator.free(orders);
            for (orders, 0..) |*order, idx| {
                decodeOrderActionInto(reader, allocator, order) catch |err| {
                    var rollback: usize = 0;
                    while (rollback < idx) : (rollback += 1) {
                        deinitOrderAction(allocator, &orders[rollback]);
                    }
                    return err;
                };
            }
            out.* = .{ .batch_orders = orders };
        },
        4 => out.* = .{ .update_leverage = .{
            .asset_id = try reader.readInt(types.AssetId),
            .leverage = try reader.readByte(),
        } },
        5 => out.* = .{ .update_isolated_margin = .{
            .asset_id = try reader.readInt(types.AssetId),
            .amount_delta = try reader.readInt(i128),
        } },
        6 => out.* = .{ .withdraw = .{
            .amount = try reader.readInt(types.Quantity),
            .destination = try reader.readFixed(20),
        } },
        7 => {
            const len = try reader.readInt(u32);
            const order_ids = try allocator.alloc(u64, len);
            errdefer allocator.free(order_ids);
            for (order_ids) |*order_id| {
                order_id.* = try reader.readInt(u64);
            }
            out.* = .{ .batch_cancel = .{ .order_ids = order_ids } };
        },
        8 => {
            const has_asset = try reader.readByte();
            out.* = .{ .cancel_all = .{
                .asset_id = if (has_asset == 1) try reader.readInt(types.AssetId) else null,
                .include_triggers = (try reader.readByte()) == 1,
            } };
        },
        else => return error.InvalidTag,
    }
}

fn writePosition(list: *std.ArrayList(u8), allocator: std.mem.Allocator, position: types.Position) Error!void {
    try writeAddress(list, allocator, position.user);
    try writeInt(list, allocator, types.AssetId, position.asset_id);
    try list.append(allocator, @intFromEnum(position.side));
    try writeInt(list, allocator, types.Quantity, position.size);
    try writeInt(list, allocator, types.Price, position.entry_price);
    try writeInt(list, allocator, types.SignedAmount, position.unrealized_pnl);
    try writeInt(list, allocator, types.Quantity, position.isolated_margin);
    try list.append(allocator, position.leverage);
}

fn readPosition(reader: *Reader) SerializationError!types.Position {
    return .{
        .user = try reader.readFixed(20),
        .asset_id = try reader.readInt(types.AssetId),
        .side = @enumFromInt(try reader.readByte()),
        .size = try reader.readInt(types.Quantity),
        .entry_price = try reader.readInt(types.Price),
        .unrealized_pnl = try reader.readInt(types.SignedAmount),
        .isolated_margin = try reader.readInt(types.Quantity),
        .leverage = try reader.readByte(),
    };
}

fn writeAccountState(list: *std.ArrayList(u8), allocator: std.mem.Allocator, account: types.AccountState) Error!void {
    try writeAddress(list, allocator, account.address);
    try writeInt(list, allocator, types.Quantity, account.balance);
    try writeInt(list, allocator, u32, @intCast(account.positions.len));
    for (account.positions) |position| {
        try writePosition(list, allocator, position);
    }
    try writeInt(list, allocator, u32, @intCast(account.open_orders.len));
    for (account.open_orders) |order_id| {
        try writeInt(list, allocator, u64, order_id);
    }
    try writeBool(list, allocator, account.api_wallet != null);
    if (account.api_wallet) |wallet| {
        try writeAddress(list, allocator, wallet);
    }
}

fn decodeAccountStateInto(reader: *Reader, allocator: std.mem.Allocator, out: *types.AccountState) Error!void {
    out.* = .{
        .address = try reader.readFixed(20),
        .balance = try reader.readInt(types.Quantity),
        .positions = &.{},
        .open_orders = &.{},
        .api_wallet = null,
    };

    const positions_len = try reader.readInt(u32);
    const positions = try allocator.alloc(types.Position, positions_len);
    errdefer allocator.free(positions);
    for (positions) |*position| {
        position.* = try readPosition(reader);
    }
    out.positions = positions;

    const orders_len = try reader.readInt(u32);
    const open_orders = try allocator.alloc(u64, orders_len);
    errdefer allocator.free(open_orders);
    for (open_orders) |*order_id| {
        order_id.* = try reader.readInt(u64);
    }
    out.open_orders = open_orders;

    if (try reader.readBool()) {
        out.api_wallet = try reader.readFixed(20);
    }
}

fn writeAllMids(list: *std.ArrayList(u8), allocator: std.mem.Allocator, all_mids: types.AllMidsUpdate) Error!void {
    try writeInt(list, allocator, u32, @intCast(all_mids.mids.count()));
    var it = all_mids.mids.iterator();
    while (it.next()) |entry| {
        try writeInt(list, allocator, types.AssetId, entry.key_ptr.*);
        try writeInt(list, allocator, types.Price, entry.value_ptr.*);
    }
}

fn decodeAllMidsInto(reader: *Reader, allocator: std.mem.Allocator, out: *types.AllMidsUpdate) Error!void {
    out.* = .{};
    const len = try reader.readInt(u32);
    var idx: u32 = 0;
    while (idx < len) : (idx += 1) {
        try out.mids.put(allocator, try reader.readInt(types.AssetId), try reader.readInt(types.Price));
    }
}

fn writeSnapshot(list: *std.ArrayList(u8), allocator: std.mem.Allocator, snapshot: types.L2Snapshot) Error!void {
    try writeInt(list, allocator, types.AssetId, snapshot.asset_id);
    try writeInt(list, allocator, u64, snapshot.seq);
    try writeInt(list, allocator, u32, @intCast(snapshot.bids.len));
    for (snapshot.bids) |bid| {
        try writeLevel(list, allocator, bid);
    }
    try writeInt(list, allocator, u32, @intCast(snapshot.asks.len));
    for (snapshot.asks) |ask| {
        try writeLevel(list, allocator, ask);
    }
    try writeBool(list, allocator, snapshot.is_snapshot);
}

fn decodeSnapshotInto(reader: *Reader, allocator: std.mem.Allocator, out: *types.L2Snapshot) Error!void {
    out.* = .{
        .asset_id = try reader.readInt(types.AssetId),
        .seq = try reader.readInt(u64),
        .bids = &.{},
        .asks = &.{},
        .is_snapshot = false,
    };

    const bids_len = try reader.readInt(u32);
    const bids = try allocator.alloc(types.Level, bids_len);
    errdefer allocator.free(bids);
    for (bids) |*bid| {
        bid.* = try readLevel(reader);
    }
    out.bids = bids;

    const asks_len = try reader.readInt(u32);
    const asks = try allocator.alloc(types.Level, asks_len);
    errdefer allocator.free(asks);
    for (asks) |*ask| {
        ask.* = try readLevel(reader);
    }
    out.asks = asks;

    out.is_snapshot = try reader.readBool();
}

fn writeFill(list: *std.ArrayList(u8), allocator: std.mem.Allocator, fill: types.Fill) Error!void {
    try writeInt(list, allocator, u64, fill.taker_order_id);
    try writeInt(list, allocator, u64, fill.maker_order_id);
    try writeInt(list, allocator, types.AssetId, fill.asset_id);
    try writeInt(list, allocator, types.Price, fill.price);
    try writeInt(list, allocator, types.Quantity, fill.size);
    try writeAddress(list, allocator, fill.taker_addr);
    try writeAddress(list, allocator, fill.maker_addr);
    try writeInt(list, allocator, i64, fill.timestamp);
    try writeInt(list, allocator, types.Quantity, fill.fee);
}

fn readFill(reader: *Reader) SerializationError!types.Fill {
    return .{
        .taker_order_id = try reader.readInt(u64),
        .maker_order_id = try reader.readInt(u64),
        .asset_id = try reader.readInt(types.AssetId),
        .price = try reader.readInt(types.Price),
        .size = try reader.readInt(types.Quantity),
        .taker_addr = try reader.readFixed(20),
        .maker_addr = try reader.readFixed(20),
        .timestamp = try reader.readInt(i64),
        .fee = try reader.readInt(types.Quantity),
    };
}

fn writeOrderUpdate(list: *std.ArrayList(u8), allocator: std.mem.Allocator, update: types.OrderUpdate) Error!void {
    try writeInt(list, allocator, u64, update.order_id);
    try list.append(allocator, @intFromEnum(update.status));
}

fn readOrderUpdate(reader: *Reader) SerializationError!types.OrderUpdate {
    return .{
        .order_id = try reader.readInt(u64),
        .status = @enumFromInt(try reader.readByte()),
    };
}

fn writeLiquidation(list: *std.ArrayList(u8), allocator: std.mem.Allocator, event: types.LiquidationEvent) Error!void {
    try writeAddress(list, allocator, event.user);
    try writeInt(list, allocator, types.AssetId, event.asset_id);
    try writeInt(list, allocator, types.Quantity, event.size);
    try list.append(allocator, @intFromEnum(event.side));
    try writeInt(list, allocator, types.Price, event.mark_px);
}

fn readLiquidation(reader: *Reader) SerializationError!types.LiquidationEvent {
    return .{
        .user = try reader.readFixed(20),
        .asset_id = try reader.readInt(types.AssetId),
        .size = try reader.readInt(types.Quantity),
        .side = @enumFromInt(try reader.readByte()),
        .mark_px = try reader.readInt(types.Price),
    };
}

fn writeFunding(list: *std.ArrayList(u8), allocator: std.mem.Allocator, event: types.FundingEvent) Error!void {
    try writeInt(list, allocator, types.AssetId, event.asset_id);
    try writeInt(list, allocator, i64, event.rate_bps);
    try writeInt(list, allocator, types.SignedAmount, event.long_payment);
    try writeInt(list, allocator, types.SignedAmount, event.short_payment);
}

fn readFunding(reader: *Reader) SerializationError!types.FundingEvent {
    return .{
        .asset_id = try reader.readInt(types.AssetId),
        .rate_bps = try reader.readInt(i64),
        .long_payment = try reader.readInt(types.SignedAmount),
        .short_payment = try reader.readInt(types.SignedAmount),
    };
}

fn writeAssetInfo(list: *std.ArrayList(u8), allocator: std.mem.Allocator, asset: types.AssetInfo) Error!void {
    try writeInt(list, allocator, u32, asset.id);
    try writeBytes(list, allocator, asset.name);
    try list.append(allocator, asset.sz_decimals);
    try list.append(allocator, asset.max_leverage);
    try writeInt(list, allocator, types.Price, asset.tick_size);
    try writeInt(list, allocator, types.Quantity, asset.lot_size);
}

fn decodeAssetInfoInto(reader: *Reader, allocator: std.mem.Allocator, out: *types.AssetInfo) Error!void {
    out.* = .{
        .id = try reader.readInt(types.AssetId),
        .name = try reader.readOwnedSlice(allocator),
        .sz_decimals = try reader.readByte(),
        .max_leverage = try reader.readByte(),
        .tick_size = try reader.readInt(types.Price),
        .lot_size = try reader.readInt(types.Quantity),
    };
}

pub fn cloneOrderWire(allocator: std.mem.Allocator, order: types.OrderWire) std.mem.Allocator.Error!types.OrderWire {
    return .{
        .a = order.a,
        .b = order.b,
        .p = try allocator.dupe(u8, order.p),
        .s = try allocator.dupe(u8, order.s),
        .leverage = order.leverage,
        .r = order.r,
        .t = order.t,
        .c = if (order.c) |cloid| try allocator.dupe(u8, cloid) else null,
    };
}

pub fn deinitOrderWire(allocator: std.mem.Allocator, order: *types.OrderWire) void {
    allocator.free(order.p);
    allocator.free(order.s);
    if (order.c) |cloid| allocator.free(cloid);
    order.* = undefined;
}

pub fn cloneOrderAction(allocator: std.mem.Allocator, action: types.OrderAction) std.mem.Allocator.Error!types.OrderAction {
    const type_bytes = try allocator.dupe(u8, action.type);
    errdefer allocator.free(type_bytes);

    var orders = try allocator.alloc(types.OrderWire, action.orders.len);
    errdefer allocator.free(orders);

    for (action.orders, 0..) |order, idx| {
        orders[idx] = cloneOrderWire(allocator, order) catch |err| {
            var rollback: usize = 0;
            while (rollback < idx) : (rollback += 1) {
                deinitOrderWire(allocator, &orders[rollback]);
            }
            return err;
        };
    }
    return .{
        .type = type_bytes,
        .orders = orders,
        .grouping = action.grouping,
    };
}

pub fn deinitOrderAction(allocator: std.mem.Allocator, action: *types.OrderAction) void {
    allocator.free(action.type);
    for (action.orders, 0..) |_, idx| {
        deinitOrderWire(allocator, @constCast(&action.orders[idx]));
    }
    allocator.free(action.orders);
    action.* = undefined;
}

pub fn cloneActionPayload(allocator: std.mem.Allocator, payload: types.ActionPayload) std.mem.Allocator.Error!types.ActionPayload {
    return switch (payload) {
        .order => |order| .{ .order = try cloneOrderAction(allocator, order) },
        .cancel => |cancel| .{ .cancel = cancel },
        .batch_cancel => |cancel| .{ .batch_cancel = .{
            .order_ids = try allocator.dupe(u64, cancel.order_ids),
        } },
        .cancel_by_cloid => |cancel| .{ .cancel_by_cloid = cancel },
        .cancel_all => |cancel| .{ .cancel_all = cancel },
        .batch_orders => |orders| blk: {
            var cloned = try allocator.alloc(types.OrderAction, orders.len);
            errdefer allocator.free(cloned);
            for (orders, 0..) |order, idx| {
                cloned[idx] = try cloneOrderAction(allocator, order);
            }
            break :blk .{ .batch_orders = cloned };
        },
        .update_leverage => |update| .{ .update_leverage = update },
        .update_isolated_margin => |update| .{ .update_isolated_margin = update },
        .withdraw => |withdraw| .{ .withdraw = withdraw },
    };
}

pub fn deinitActionPayload(allocator: std.mem.Allocator, payload: *types.ActionPayload) void {
    switch (payload.*) {
        .order => |*order| deinitOrderAction(allocator, order),
        .batch_cancel => |cancel| allocator.free(cancel.order_ids),
        .batch_orders => |orders| {
            for (orders, 0..) |_, idx| {
                deinitOrderAction(allocator, @constCast(&orders[idx]));
            }
            allocator.free(orders);
        },
        else => {},
    }
    payload.* = undefined;
}

pub fn cloneTransaction(allocator: std.mem.Allocator, tx: types.Transaction) std.mem.Allocator.Error!types.Transaction {
    return .{
        .action = try cloneActionPayload(allocator, tx.action),
        .nonce = tx.nonce,
        .signature = tx.signature,
        .user = tx.user,
    };
}

pub fn deinitTransaction(allocator: std.mem.Allocator, tx: *types.Transaction) void {
    deinitActionPayload(allocator, &tx.action);
    tx.* = undefined;
}

pub fn cloneActionRequest(allocator: std.mem.Allocator, req: protocol.ActionRequest) std.mem.Allocator.Error!protocol.ActionRequest {
    return .{
        .action = try cloneActionPayload(allocator, req.action),
        .nonce = req.nonce,
        .signature = req.signature,
        .user = req.user,
    };
}

pub fn deinitActionRequest(allocator: std.mem.Allocator, req: *protocol.ActionRequest) void {
    deinitActionPayload(allocator, &req.action);
    req.* = undefined;
}

pub fn cloneBlock(allocator: std.mem.Allocator, block: types.Block) std.mem.Allocator.Error!types.Block {
    const transactions = try allocator.alloc(types.Transaction, block.transactions.len);
    errdefer allocator.free(transactions);
    for (block.transactions, 0..) |tx, idx| {
        transactions[idx] = try cloneTransaction(allocator, tx);
    }
    return .{
        .height = block.height,
        .round = block.round,
        .parent_hash = block.parent_hash,
        .txs_hash = block.txs_hash,
        .state_root = block.state_root,
        .proposer = block.proposer,
        .timestamp = block.timestamp,
        .transactions = transactions,
    };
}

pub fn deinitBlock(allocator: std.mem.Allocator, block: *types.Block) void {
    for (block.transactions, 0..) |_, idx| {
        deinitTransaction(allocator, @constCast(&block.transactions[idx]));
    }
    if (block.transactions.len > 0) allocator.free(block.transactions);
    block.* = undefined;
}

pub fn cloneAccountState(allocator: std.mem.Allocator, account: types.AccountState) std.mem.Allocator.Error!types.AccountState {
    return .{
        .address = account.address,
        .balance = account.balance,
        .positions = try allocator.dupe(types.Position, account.positions),
        .open_orders = try allocator.dupe(u64, account.open_orders),
        .api_wallet = account.api_wallet,
    };
}

pub fn deinitAccountState(allocator: std.mem.Allocator, account: *types.AccountState) void {
    if (account.positions.len > 0) allocator.free(account.positions);
    if (account.open_orders.len > 0) allocator.free(account.open_orders);
    account.* = undefined;
}

pub fn cloneL2Snapshot(allocator: std.mem.Allocator, snapshot: types.L2Snapshot) std.mem.Allocator.Error!types.L2Snapshot {
    return .{
        .asset_id = snapshot.asset_id,
        .seq = snapshot.seq,
        .bids = try allocator.dupe(types.Level, snapshot.bids),
        .asks = try allocator.dupe(types.Level, snapshot.asks),
        .is_snapshot = snapshot.is_snapshot,
    };
}

pub fn deinitL2Snapshot(allocator: std.mem.Allocator, snapshot: *types.L2Snapshot) void {
    if (snapshot.bids.len > 0) allocator.free(snapshot.bids);
    if (snapshot.asks.len > 0) allocator.free(snapshot.asks);
    snapshot.* = undefined;
}

pub fn cloneAllMidsUpdate(allocator: std.mem.Allocator, src: types.AllMidsUpdate) std.mem.Allocator.Error!types.AllMidsUpdate {
    var out = types.AllMidsUpdate{};
    var it = src.mids.iterator();
    while (it.next()) |entry| {
        try out.mids.put(allocator, entry.key_ptr.*, entry.value_ptr.*);
    }
    return out;
}

pub fn cloneExchangeMeta(allocator: std.mem.Allocator, meta: types.ExchangeMeta) std.mem.Allocator.Error!types.ExchangeMeta {
    var assets = try allocator.alloc(types.AssetInfo, meta.assets.len);
    errdefer allocator.free(assets);
    for (meta.assets, 0..) |asset, idx| {
        assets[idx] = .{
            .id = asset.id,
            .name = try allocator.dupe(u8, asset.name),
            .sz_decimals = asset.sz_decimals,
            .max_leverage = asset.max_leverage,
            .tick_size = asset.tick_size,
            .lot_size = asset.lot_size,
        };
    }
    return .{ .assets = assets };
}

pub fn deinitExchangeMeta(allocator: std.mem.Allocator, meta: *types.ExchangeMeta) void {
    if (meta.assets.len == 0) {
        meta.* = undefined;
        return;
    }
    for (meta.assets) |asset| {
        allocator.free(asset.name);
    }
    allocator.free(meta.assets);
    meta.* = undefined;
}

pub fn encodeActionRequest(allocator: std.mem.Allocator, req: protocol.ActionRequest) Error![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    try writeActionPayload(&out, allocator, req.action);
    try writeInt(&out, allocator, u64, req.nonce);
    try writeSignature(&out, allocator, req.signature);
    try writeAddress(&out, allocator, req.user);

    return out.toOwnedSlice(allocator);
}

pub fn decodeActionRequest(allocator: std.mem.Allocator, bytes: []const u8) Error!protocol.ActionRequest {
    var reader = Reader{ .bytes = bytes };
    var req: protocol.ActionRequest = undefined;
    try decodeActionPayloadInto(&reader, allocator, &req.action);
    req.nonce = try reader.readInt(u64);
    req.signature = try readSignature(&reader);
    req.user = try reader.readFixed(20);
    try reader.finish();
    return req;
}

pub fn encodeActionAck(allocator: std.mem.Allocator, ack: protocol.ActionAck) Error![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    try out.append(allocator, @intFromEnum(ack.status));
    try writeBool(&out, allocator, ack.order_id != null);
    if (ack.order_id) |order_id| {
        try writeInt(&out, allocator, u64, order_id);
    }
    try writeOptionalBytes(&out, allocator, ack.error_msg);

    return out.toOwnedSlice(allocator);
}

pub fn decodeActionAck(allocator: std.mem.Allocator, bytes: []const u8) Error!protocol.ActionAck {
    var reader = Reader{ .bytes = bytes };
    var ack = protocol.ActionAck{
        .status = @enumFromInt(try reader.readByte()),
        .order_id = null,
        .error_msg = null,
    };
    if (try reader.readBool()) {
        ack.order_id = try reader.readInt(u64);
    }
    ack.error_msg = try reader.readOptionalOwnedSlice(allocator);
    try reader.finish();
    return ack;
}

pub fn deinitActionAck(allocator: std.mem.Allocator, ack: *protocol.ActionAck) void {
    if (ack.error_msg) |msg| allocator.free(msg);
    ack.* = undefined;
}

pub fn encodeNodeEvent(allocator: std.mem.Allocator, event: protocol.NodeEvent) Error![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    switch (event) {
        .l2_book_update => |snapshot| {
            try out.append(allocator, 0);
            try writeSnapshot(&out, allocator, snapshot);
        },
        .trade => |fill| {
            try out.append(allocator, 1);
            try writeFill(&out, allocator, fill);
        },
        .all_mids => |all_mids| {
            try out.append(allocator, 2);
            try writeAllMids(&out, allocator, all_mids);
        },
        .order_update => |update| {
            try out.append(allocator, 3);
            try writeOrderUpdate(&out, allocator, update);
        },
        .user_update => |account| {
            try out.append(allocator, 4);
            try writeAccountState(&out, allocator, account);
        },
        .liquidation => |liq| {
            try out.append(allocator, 5);
            try writeLiquidation(&out, allocator, liq);
        },
        .funding => |funding| {
            try out.append(allocator, 6);
            try writeFunding(&out, allocator, funding);
        },
    }

    return out.toOwnedSlice(allocator);
}

pub fn decodeNodeEvent(allocator: std.mem.Allocator, bytes: []const u8) Error!protocol.NodeEvent {
    var reader = Reader{ .bytes = bytes };
    const tag = try reader.readByte();
    const event = switch (tag) {
        0 => blk: {
            var snapshot: types.L2Snapshot = undefined;
            try decodeSnapshotInto(&reader, allocator, &snapshot);
            break :blk protocol.NodeEvent{ .l2_book_update = snapshot };
        },
        1 => protocol.NodeEvent{ .trade = try readFill(&reader) },
        2 => blk: {
            var all_mids: types.AllMidsUpdate = undefined;
            try decodeAllMidsInto(&reader, allocator, &all_mids);
            break :blk protocol.NodeEvent{ .all_mids = all_mids };
        },
        3 => protocol.NodeEvent{ .order_update = try readOrderUpdate(&reader) },
        4 => blk: {
            var account: types.AccountState = undefined;
            try decodeAccountStateInto(&reader, allocator, &account);
            break :blk protocol.NodeEvent{ .user_update = account };
        },
        5 => protocol.NodeEvent{ .liquidation = try readLiquidation(&reader) },
        6 => protocol.NodeEvent{ .funding = try readFunding(&reader) },
        else => return error.InvalidTag,
    };
    try reader.finish();
    return event;
}

pub fn deinitNodeEvent(allocator: std.mem.Allocator, event: *protocol.NodeEvent) void {
    switch (event.*) {
        .l2_book_update => |*snapshot| deinitL2Snapshot(allocator, snapshot),
        .all_mids => |*all_mids| all_mids.deinit(allocator),
        .user_update => |*account| deinitAccountState(allocator, account),
        else => {},
    }
    event.* = undefined;
}

pub fn encodeTransaction(allocator: std.mem.Allocator, tx: types.Transaction) Error![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try writeActionPayload(&out, allocator, tx.action);
    try writeInt(&out, allocator, u64, tx.nonce);
    try writeSignature(&out, allocator, tx.signature);
    try writeAddress(&out, allocator, tx.user);
    return out.toOwnedSlice(allocator);
}

pub fn decodeTransaction(allocator: std.mem.Allocator, bytes: []const u8) Error!types.Transaction {
    var reader = Reader{ .bytes = bytes };
    var tx: types.Transaction = undefined;
    try decodeActionPayloadInto(&reader, allocator, &tx.action);
    tx.nonce = try reader.readInt(u64);
    tx.signature = try readSignature(&reader);
    tx.user = try reader.readFixed(20);
    try reader.finish();
    return tx;
}

pub fn encodeBlock(allocator: std.mem.Allocator, block: types.Block) Error![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    try writeInt(&out, allocator, u64, block.height);
    try writeInt(&out, allocator, u64, block.round);
    try out.appendSlice(allocator, block.parent_hash[0..]);
    try out.appendSlice(allocator, block.txs_hash[0..]);
    try out.appendSlice(allocator, block.state_root[0..]);
    try writeAddress(&out, allocator, block.proposer);
    try writeInt(&out, allocator, i64, block.timestamp);
    try writeInt(&out, allocator, u32, @intCast(block.transactions.len));
    for (block.transactions) |tx| {
        const encoded = try encodeTransaction(allocator, tx);
        defer allocator.free(encoded);
        try writeBytes(&out, allocator, encoded);
    }

    return out.toOwnedSlice(allocator);
}

pub fn decodeBlock(allocator: std.mem.Allocator, bytes: []const u8) Error!types.Block {
    var reader = Reader{ .bytes = bytes };
    var block = types.Block{
        .height = try reader.readInt(u64),
        .round = try reader.readInt(u64),
        .parent_hash = try reader.readFixed(32),
        .txs_hash = try reader.readFixed(32),
        .state_root = try reader.readFixed(32),
        .proposer = try reader.readFixed(20),
        .timestamp = try reader.readInt(i64),
        .transactions = &.{},
    };

    const len = try reader.readInt(u32);
    const txs = try allocator.alloc(types.Transaction, len);
    errdefer allocator.free(txs);
    for (txs, 0..) |*tx, idx| {
        const encoded = try reader.readOwnedSlice(allocator);
        defer allocator.free(encoded);
        tx.* = decodeTransaction(allocator, encoded) catch |err| {
            var rollback: usize = 0;
            while (rollback < idx) : (rollback += 1) {
                deinitTransaction(allocator, &txs[rollback]);
            }
            return err;
        };
    }
    block.transactions = txs;
    try reader.finish();
    return block;
}

pub fn encodeStateDiff(allocator: std.mem.Allocator, diff: types.StateDiff) Error![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try writeInt(&out, allocator, u64, @intCast(diff.touched_accounts));
    return out.toOwnedSlice(allocator);
}

pub fn decodeStateDiff(bytes: []const u8) Error!types.StateDiff {
    var reader = Reader{ .bytes = bytes };
    const diff = types.StateDiff{
        .touched_accounts = @intCast(try reader.readInt(u64)),
    };
    try reader.finish();
    return diff;
}

pub fn encodeExchangeMeta(allocator: std.mem.Allocator, meta: types.ExchangeMeta) Error![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try writeInt(&out, allocator, u32, @intCast(meta.assets.len));
    for (meta.assets) |asset| {
        try writeAssetInfo(&out, allocator, asset);
    }
    return out.toOwnedSlice(allocator);
}

pub fn decodeExchangeMeta(allocator: std.mem.Allocator, bytes: []const u8) Error!types.ExchangeMeta {
    var reader = Reader{ .bytes = bytes };
    const len = try reader.readInt(u32);
    const assets = try allocator.alloc(types.AssetInfo, len);
    errdefer allocator.free(assets);
    for (assets, 0..) |*asset, idx| {
        decodeAssetInfoInto(&reader, allocator, asset) catch |err| {
            var rollback: usize = 0;
            while (rollback < idx) : (rollback += 1) {
                allocator.free(assets[rollback].name);
            }
            return err;
        };
    }
    try reader.finish();
    return .{ .assets = assets };
}

pub const Frame = struct {
    header: protocol.IpcFrameHeader,
    payload: []const u8,
};

pub fn encodeFrame(
    allocator: std.mem.Allocator,
    msg_id: u32,
    msg_type: protocol.MsgType,
    payload: []const u8,
) Error![]u8 {
    const total_len = @sizeOf(protocol.IpcFrameHeader) + payload.len;
    const out = try allocator.alloc(u8, total_len);
    std.mem.writeInt(u32, out[0..4], @intCast(payload.len), .big);
    std.mem.writeInt(u32, out[4..8], msg_id, .little);
    out[8] = @intFromEnum(msg_type);
    @memcpy(out[@sizeOf(protocol.IpcFrameHeader)..], payload);
    return out;
}

pub fn decodeFrame(bytes: []const u8) SerializationError!Frame {
    if (bytes.len < @sizeOf(protocol.IpcFrameHeader)) return error.UnexpectedEndOfStream;
    const payload_len = std.mem.readInt(u32, bytes[0..4], .big);
    if (bytes.len != @sizeOf(protocol.IpcFrameHeader) + payload_len) return error.InvalidFormat;
    return .{
        .header = .{
            .len = payload_len,
            .msg_id = std.mem.readInt(u32, bytes[4..8], .little),
            .msg_type = bytes[8],
        },
        .payload = bytes[@sizeOf(protocol.IpcFrameHeader)..],
    };
}

test "action request round-trips through shared serialization" {
    const allocator = std.testing.allocator;
    const req = protocol.ActionRequest{
        .action = .{ .order = .{
            .type = "order",
            .orders = &.{.{
                .a = 1,
                .b = true,
                .p = "100.25",
                .s = "0.5",
                .leverage = 20,
                .r = false,
                .t = .{ .limit = .gtc },
                .c = "cloid-1",
            }},
            .grouping = .none,
        } },
        .nonce = 42,
        .signature = .{
            .r = [_]u8{1} ** 32,
            .s = [_]u8{2} ** 32,
            .v = 27,
        },
        .user = [_]u8{9} ** 20,
    };

    const encoded = try encodeActionRequest(allocator, req);
    defer allocator.free(encoded);

    var decoded = try decodeActionRequest(allocator, encoded);
    defer deinitActionPayload(allocator, &decoded.action);

    try std.testing.expectEqual(req.nonce, decoded.nonce);
    try std.testing.expectEqual(req.user, decoded.user);
    try std.testing.expectEqualStrings("order", decoded.action.order.type);
    try std.testing.expectEqualStrings("100.25", decoded.action.order.orders[0].p);
    try std.testing.expectEqual(@as(u8, 20), decoded.action.order.orders[0].leverage);
}

pub fn encodeQueryRequest(allocator: std.mem.Allocator, req: protocol.QueryRequest) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);

    const tag: u8 = switch (req) {
        .user_state => 0x01,
        .open_orders => 0x02,
        .l2_book => 0x03,
        .all_mids => 0x04,
    };
    try buf.append(allocator, tag);

    switch (req) {
        .user_state => |addr| try buf.appendSlice(allocator, &addr),
        .open_orders => |addr| try buf.appendSlice(allocator, &addr),
        .l2_book => |params| {
            var asset_bytes: [8]u8 = undefined;
            std.mem.writeInt(u64, &asset_bytes, params.asset_id, .big);
            try buf.appendSlice(allocator, &asset_bytes);
            var depth_bytes: [4]u8 = undefined;
            std.mem.writeInt(u32, &depth_bytes, params.depth, .big);
            try buf.appendSlice(allocator, &depth_bytes);
        },
        .all_mids => {},
    }

    return try buf.toOwnedSlice(allocator);
}

pub fn decodeQueryRequest(allocator: std.mem.Allocator, data: []const u8) !protocol.QueryRequest {
    _ = allocator;
    if (data.len < 1) return error.UnexpectedEndOfStream;
    const tag = data[0];
    return switch (tag) {
        0x01 => .{ .user_state = data[1..21].* },
        0x02 => .{ .open_orders = data[1..21].* },
        0x03 => .{ .l2_book = .{
            .asset_id = std.mem.readInt(u64, data[1..9], .big),
            .depth = std.mem.readInt(u32, data[9..13], .big),
        } },
        0x04 => .{ .all_mids = {} },
        else => error.InvalidTag,
    };
}

pub fn encodeQueryResponse(allocator: std.mem.Allocator, resp: protocol.QueryResponse) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);

    const tag: u8 = switch (resp) {
        .user_state => 0x81,
        .open_orders => 0x82,
        .l2_book => 0x83,
        .all_mids => 0x84,
        .not_found => 0x8F,
    };
    try buf.append(allocator, tag);

    switch (resp) {
        .user_state => |state| {
            try buf.appendSlice(allocator, &state.address);
            var bal_bytes: [16]u8 = undefined;
            std.mem.writeInt(u128, &bal_bytes, state.balance, .big);
            try buf.appendSlice(allocator, &bal_bytes);
        },
        .open_orders => |orders| {
            var len_bytes: [4]u8 = undefined;
            std.mem.writeInt(u32, &len_bytes, @intCast(orders.len), .big);
            try buf.appendSlice(allocator, &len_bytes);
            for (orders) |oid| {
                var oid_bytes: [8]u8 = undefined;
                std.mem.writeInt(u64, &oid_bytes, oid, .big);
                try buf.appendSlice(allocator, &oid_bytes);
            }
        },
        .l2_book => |book| {
            var asset_bytes: [8]u8 = undefined;
            std.mem.writeInt(u64, &asset_bytes, book.asset_id, .big);
            try buf.appendSlice(allocator, &asset_bytes);
            var seq_bytes: [8]u8 = undefined;
            std.mem.writeInt(u64, &seq_bytes, book.seq, .big);
            try buf.appendSlice(allocator, &seq_bytes);
        },
        .all_mids => {},
        .not_found => {},
    }

    return try buf.toOwnedSlice(allocator);
}

pub fn decodeQueryResponse(allocator: std.mem.Allocator, data: []const u8) !protocol.QueryResponse {
    if (data.len < 1) return error.UnexpectedEndOfStream;
    const tag = data[0];
    return switch (tag) {
        0x81 => .{ .user_state = .{
            .address = data[1..21].*,
            .balance = std.mem.readInt(u128, data[21..37], .big),
            .positions = &.{},
            .open_orders = &.{},
            .api_wallet = null,
        } },
        0x82 => blk: {
            if (data.len < 5) return error.UnexpectedEndOfStream;
            const len = std.mem.readInt(u32, data[1..5], .big);
            const orders = try allocator.alloc(u64, len);
            errdefer allocator.free(orders);
            var idx: usize = 5;
            for (orders) |*order_id| {
                if (idx + 8 > data.len) return error.UnexpectedEndOfStream;
                order_id.* = std.mem.readInt(u64, data[idx .. idx + 8], .big);
                idx += 8;
            }
            break :blk .{ .open_orders = orders };
        },
        0x83 => .{ .l2_book = .{
            .asset_id = std.mem.readInt(u64, data[1..9], .big),
            .seq = std.mem.readInt(u64, data[9..17], .big),
            .bids = &.{},
            .asks = &.{},
            .is_snapshot = true,
        } },
        0x84 => .{ .all_mids = .{} },
        else => error.InvalidTag,
    };
}

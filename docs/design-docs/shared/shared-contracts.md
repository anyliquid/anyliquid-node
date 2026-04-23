# Shared Contracts

**Directory:** `src/shared/`

The shared layer contains no business ownership. It defines contracts, message formats, cryptographic helpers, and fixed-point utilities used by both the API and Node layers.

## File Map

```text
src/shared/
├── types.zig
├── protocol.zig
├── serialization.zig
├── crypto.zig
└── fixed_point.zig
```

## `types.zig`

```zig
pub const Address = [20]u8;

pub const Price = u64;    // raw / 1_000_000
pub const Quantity = u64; // raw / 100_000_000

pub const Side = enum { long, short };
pub fn Side.opposite(self: Side) Side {
    return if (self == .long) .short else .long;
}

pub const AssetInfo = struct {
    id:           u32,
    name:         []const u8,
    sz_decimals:  u8,
    max_leverage: u8,
    tick_size:    Price,
    lot_size:     Quantity,
};

pub const Order = struct {
    id:          u64,
    user:        Address,
    asset_id:    u32,
    is_buy:      bool,
    price:       Price,
    size:        Quantity,
    leverage:    u8,
    order_type:  OrderType,
    cloid:       ?[16]u8,
    nonce:       u64,
};

pub const ActionPayload = union(enum) {
    order:                  OrderAction,
    cancel:                 CancelRequest,
    batch_cancel:           BatchCancelRequest,
    cancel_by_cloid:        CancelByCloidRequest,
    cancel_all:             CancelAllRequest,
    batch_orders:           []OrderAction,
    update_leverage:        UpdateLeverageRequest,
    update_isolated_margin: UpdateMarginRequest,
    withdraw:               WithdrawRequest,
};

pub const BatchCancelRequest = struct {
    order_ids: []const u64,
};

pub const CancelAllRequest = struct {
    asset_id: ?u32,
    include_triggers: bool,
};

pub const Fill = struct {
    taker_order_id: u64,
    maker_order_id: u64,
    asset_id:       u32,
    price:          Price,
    size:           Quantity,
    taker_addr:     Address,
    maker_addr:     Address,
    timestamp:      i64,
    fee:            Quantity,
};

pub const OrderStatus = enum {
    resting,
    filled,
    cancelled,
    rejected,
};

pub const Position = struct {
    user:             Address,
    asset_id:         u32,
    side:             Side,
    size:             Quantity,
    entry_price:      Price,
    unrealized_pnl:   i64,
    isolated_margin:  Quantity,
    leverage:         u8,       // requested at open/increase time; persisted on the position
};

pub const AccountState = struct {
    address:        Address,
    balance:        Quantity,
    positions:      []Position,
    open_orders:    []u64,
    api_wallet:     ?Address,
};

pub const Transaction = struct {
    action:    ActionPayload,
    nonce:     u64,
    signature: EIP712Signature,
    user:      Address,
};

pub const EIP712Signature = struct {
    r: [32]u8,
    s: [32]u8,
    v: u8,
};
```

Only the shared types referenced across multiple modules are listed here. Module-local request and response shapes should remain in their owning module docs.

## `protocol.zig`

All IPC messages use MessagePack inside the following frame:

```text
[ u32 len ][ u32 msg_id ][ u8 type ][ msgpack payload ]
```

### API -> Node

```zig
pub const ActionRequest = struct {
    action:    ActionPayload,
    nonce:     u64,
    signature: EIP712Signature,
    user:      Address,
};

pub const QueryRequest = union(enum) {
    user_state:  Address,
    open_orders: Address,
    l2_book:     struct { asset_id: u32, depth: u32 },
    all_mids:    void,
};
```

### Node -> API

```zig
pub const ActionAck = struct {
    status:    OrderStatus,
    order_id:  ?u64,
    error_msg: ?[]const u8,
};

pub const NodeEvent = union(enum) {
    l2_book_update: L2BookUpdate,
    trade:          Fill,
    all_mids:       AllMidsUpdate,
    order_update:   OrderUpdate,
    user_update:    AccountState,
    liquidation:    LiquidationEvent,
    funding:        FundingEvent,
};

pub const L2BookUpdate = struct {
    asset_id:    u32,
    seq:         u64,
    bids:        []Level,
    asks:        []Level,
    is_snapshot: bool,
};
```

Current scaffold implementation note:

- `serialization.zig` provides a deterministic binary codec used by the harness and in-process IPC loop.
- The long-term production target remains a dedicated MessagePack adapter as described in [`../../references/dependencies.md`](../../references/dependencies.md).

## `serialization.zig`

```zig
pub fn encodeFrame(alloc: std.mem.Allocator, msg_id: u32, msg_type: MsgType, payload: []const u8) ![]u8
pub fn decodeFrame(bytes: []const u8) !Frame

pub fn encodeActionRequest(alloc: std.mem.Allocator, req: ActionRequest) ![]u8
pub fn decodeActionRequest(alloc: std.mem.Allocator, bytes: []const u8) !ActionRequest

pub fn encodeActionAck(alloc: std.mem.Allocator, ack: ActionAck) ![]u8
pub fn decodeActionAck(alloc: std.mem.Allocator, bytes: []const u8) !ActionAck
```

## `crypto.zig`

```zig
pub fn ecrecover(msg_hash: [32]u8, r: [32]u8, s: [32]u8, v: u8) !Address
pub fn keccak256(data: []const u8) [32]u8
pub fn eip712Hash(domain: EIP712Domain, struct_hash: [32]u8) [32]u8

pub fn blsVerifyAggregate(
    agg_sig: BlsAggregateSignature,
    pubkeys: []BlsPublicKey,
    msg:     [32]u8,
) bool
```

## `fixed_point.zig`

```zig
pub const PRICE_DECIMALS = 1_000_000;
pub const QUANTITY_DECIMALS = 100_000_000;

pub fn priceFromFloat(f: f64) Price {
    return @intFromFloat(f * PRICE_DECIMALS);
}

pub fn quantityFromFloat(f: f64) Quantity {
    return @intFromFloat(f * QUANTITY_DECIMALS);
}

pub fn mulPriceQty(p: Price, q: Quantity) Quantity {
    const result = @as(u128, p) * @as(u128, q);
    return @intCast(result / PRICE_DECIMALS);
}
```

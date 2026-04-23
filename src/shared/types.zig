const std = @import("std");

pub const Address = [20]u8;
pub const AssetId = u64;
pub const Price = u256;
pub const Amount = u128;
pub const Quantity = Amount;
pub const IpAddr = u128;
pub const SignedAmount = i256;
pub const PRICE_SCALE: Price = 1_000_000_000_000_000_000_000_000_000_000_000_000;

pub const Side = enum { long, short };

pub fn oppositeSide(side: Side) Side {
    return if (side == .long) .short else .long;
}

pub fn isValidPrice(price: Price, tick_size: Price) bool {
    return price > 0 and price % tick_size == 0;
}

pub fn maxScaledPrice() Price {
    return std.math.maxInt(Price) - (std.math.maxInt(Price) % PRICE_SCALE);
}

pub const TimeInForce = enum {
    gtc,
    ioc,
    fok,
    alo,
};

pub const TpslType = enum {
    none,
    tp,
    sl,
};

pub const TriggerOrderType = struct {
    trigger_px: Price,
    is_market: bool,
    tpsl: TpslType,
};

pub const OrderType = union(enum) {
    limit: TimeInForce,
    trigger: TriggerOrderType,
};

pub const Grouping = enum {
    none,
    normal_tpsl,
    position_tpsl,
};

pub const AssetInfo = struct {
    id: AssetId,
    name: []const u8,
    sz_decimals: u8,
    max_leverage: u8,
    tick_size: Price,
    lot_size: Quantity,
};

pub const OrderWire = struct {
    a: AssetId,
    b: bool,
    p: []const u8,
    s: []const u8,
    leverage: u8 = 1,
    r: bool,
    t: OrderType,
    c: ?[]const u8,
};

pub const OrderAction = struct {
    type: []const u8,
    orders: []const OrderWire,
    grouping: Grouping,
};

pub const CancelRequest = struct {
    order_id: u64,
};

pub const BatchCancelRequest = struct {
    order_ids: []const u64,
};

pub const CancelByCloidRequest = struct {
    cloid: [16]u8,
};

pub const CancelAllRequest = struct {
    asset_id: ?AssetId = null,
    include_triggers: bool = true,
};

pub const UpdateLeverageRequest = struct {
    asset_id: AssetId,
    leverage: u8,
};

pub const UpdateMarginRequest = struct {
    asset_id: AssetId,
    amount_delta: i128,
};

pub const WithdrawRequest = struct {
    amount: Quantity,
    destination: Address,
};

pub const EIP712Signature = struct {
    r: [32]u8,
    s: [32]u8,
    v: u8,
};

pub const BlsSignature = [96]u8;
pub const BlsAggregateSignature = [96]u8;
pub const BlsPublicKey = [48]u8;

pub const EIP712Domain = struct {
    name: []const u8,
    version: []const u8,
    chain_id: u64,
};

pub const Order = struct {
    id: u64,
    user: Address,
    asset_id: AssetId,
    is_buy: bool,
    price: Price,
    size: Quantity,
    leverage: u8 = 1,
    order_type: OrderType,
    cloid: ?[16]u8,
    nonce: u64,
};

pub const ActionPayload = union(enum) {
    order: OrderAction,
    cancel: CancelRequest,
    batch_cancel: BatchCancelRequest,
    cancel_by_cloid: CancelByCloidRequest,
    cancel_all: CancelAllRequest,
    batch_orders: []const OrderAction,
    update_leverage: UpdateLeverageRequest,
    update_isolated_margin: UpdateMarginRequest,
    withdraw: WithdrawRequest,
};

pub const OrderStatus = enum {
    resting,
    filled,
    cancelled,
    rejected,
};

pub const Fill = struct {
    taker_order_id: u64,
    maker_order_id: u64,
    asset_id: AssetId,
    price: Price,
    size: Quantity,
    taker_addr: Address,
    maker_addr: Address,
    timestamp: i64,
    fee: Quantity,
};

pub const Position = struct {
    user: Address = [_]u8{0} ** 20,
    asset_id: AssetId,
    side: Side,
    size: Quantity,
    entry_price: Price,
    unrealized_pnl: SignedAmount = 0,
    isolated_margin: Quantity = 0,
    leverage: u8 = 1,
};

pub const AccountState = struct {
    address: Address,
    balance: Quantity,
    positions: []const Position,
    open_orders: []const u64,
    api_wallet: ?Address,
};

pub const Transaction = struct {
    action: ActionPayload,
    nonce: u64,
    signature: EIP712Signature,
    user: Address,
};

pub const Level = struct {
    price: Price,
    size: Quantity,
};

pub const L2BookUpdate = struct {
    asset_id: AssetId,
    seq: u64,
    bids: []const Level,
    asks: []const Level,
    is_snapshot: bool,
};

pub const L2Snapshot = L2BookUpdate;

pub const AllMidsUpdate = struct {
    mids: std.AutoHashMapUnmanaged(AssetId, Price) = .{},

    pub fn deinit(self: *AllMidsUpdate, allocator: std.mem.Allocator) void {
        self.mids.deinit(allocator);
    }
};

pub const OrderUpdate = struct {
    order_id: u64,
    status: OrderStatus,
};

pub const LiquidationEvent = struct {
    user: Address,
    asset_id: AssetId,
    size: Quantity,
    side: Side,
    mark_px: Price,
};

pub const FundingEvent = struct {
    asset_id: AssetId,
    rate_bps: i64,
    long_payment: SignedAmount = 0,
    short_payment: SignedAmount = 0,
};

pub const FundingRate = struct {
    value: f64,
};

pub const ExchangeMeta = struct {
    assets: []const AssetInfo,
};

pub const UserStateView = AccountState;

pub const RestingOrderView = struct {
    order_id: u64,
    asset_id: AssetId,
    price: Price,
    remaining: Quantity,
};

pub const AccountHealth = struct {
    equity: SignedAmount,
    maintenance_margin: SignedAmount,
};

pub const MerkleProof = struct {
    siblings: []const [32]u8,
};

pub const StateDiff = struct {
    touched_accounts: usize = 0,
};

pub const Block = struct {
    height: u64,
    round: u64,
    parent_hash: [32]u8,
    txs_hash: [32]u8,
    state_root: [32]u8,
    proposer: Address,
    timestamp: i64,
    transactions: []const Transaction,
};

pub const StateKey = [32]u8;

pub const PlaceOrderRequest = struct {
    action: OrderAction,
    nonce: u64,
    signature: EIP712Signature,
};

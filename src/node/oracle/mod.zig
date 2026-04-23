const std = @import("std");
const shared = @import("../../shared/mod.zig");

pub const AssetPrice = struct {
    asset_id: u32,
    price: shared.types.Price,
};

pub const OracleSubmission = struct {
    validator: shared.types.Address,
    prices: []AssetPrice,
    timestamp: i64,
    signature: shared.types.BlsSignature,
};

pub const ValidatorInfo = struct {
    address: shared.types.Address,
    weight: u64,
};

const PriceEntry = struct {
    price: shared.types.Price,
    weight: u64,
};

pub const ValidatorSet = struct {
    validators: []const ValidatorInfo,
    total_weight: u64,

    pub fn init(validators: []const ValidatorInfo) ValidatorSet {
        var total: u64 = 0;
        for (validators) |v| {
            total += v.weight;
        }
        return .{
            .validators = validators,
            .total_weight = total,
        };
    }

    pub fn getWeight(self: *const ValidatorSet, addr: shared.types.Address) u64 {
        for (self.validators) |v| {
            if (std.mem.eql(u8, v.address[0..], addr[0..])) {
                return v.weight;
            }
        }
        return 0;
    }

    pub fn hasValidator(self: *const ValidatorSet, addr: shared.types.Address) bool {
        for (self.validators) |v| {
            if (std.mem.eql(u8, v.address[0..], addr[0..])) {
                return true;
            }
        }
        return false;
    }

    pub fn twoThirdsWeight(self: *const ValidatorSet) u64 {
        return (self.total_weight * 2 + 2) / 3;
    }
};

pub const OracleConfig = struct {
    max_deviation_bps: u16 = 200,
    min_participants: usize = 2,
    max_age_ms: i64 = 5_000,
    now_ms_fn: ?*const fn () i64 = null,
};

pub const Oracle = struct {
    allocator: std.mem.Allocator,
    submissions: std.AutoHashMap(shared.types.Address, OracleSubmission),
    validator_set: ValidatorSet,
    config: OracleConfig,
    aggregated_prices: std.AutoHashMap(u32, shared.types.Price),

    pub fn init(validator_set: ValidatorSet, config: OracleConfig, allocator: std.mem.Allocator) Oracle {
        return .{
            .allocator = allocator,
            .submissions = std.AutoHashMap(shared.types.Address, OracleSubmission).init(allocator),
            .validator_set = validator_set,
            .config = config,
            .aggregated_prices = std.AutoHashMap(u32, shared.types.Price).init(allocator),
        };
    }

    pub fn deinit(self: *Oracle) void {
        var it = self.submissions.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.value_ptr.prices);
        }
        self.submissions.deinit();
        self.aggregated_prices.deinit();
    }

    pub fn submitPrices(
        self: *Oracle,
        from: shared.types.Address,
        prices: []const AssetPrice,
        sig: shared.types.BlsSignature,
        timestamp: i64,
    ) !void {
        if (!self.validator_set.hasValidator(from)) {
            return error.InvalidValidator;
        }

        if (shared.crypto.blsVerifyAggregate(sig, &.{}, [_]u8{0} ** 32) == false) {
            return error.InvalidSignature;
        }

        const owned_prices = try self.allocator.dupe(AssetPrice, prices);
        errdefer self.allocator.free(owned_prices);

        if (self.submissions.getPtr(from)) |existing| {
            self.allocator.free(existing.prices);
            existing.prices = owned_prices;
            existing.timestamp = timestamp;
            existing.signature = sig;
        } else {
            try self.submissions.put(from, .{
                .validator = from,
                .prices = owned_prices,
                .timestamp = timestamp,
                .signature = sig,
            });
        }
    }

    pub fn aggregate(self: *Oracle) ![]AssetPrice {
        var asset_prices = std.AutoHashMap(u32, std.ArrayList(PriceEntry)).init(self.allocator);
        defer {
            var it = asset_prices.iterator();
            while (it.next()) |entry| {
                entry.value_ptr.deinit(self.allocator);
            }
            asset_prices.deinit();
        }

        var total_weight: u64 = 0;
        const now_ms = if (self.config.now_ms_fn) |clock| clock() else null;
        var sub_it = self.submissions.iterator();
        while (sub_it.next()) |entry| {
            if (now_ms) |now| {
                if (entry.value_ptr.timestamp < now - self.config.max_age_ms) continue;
            }
            const weight = self.validator_set.getWeight(entry.key_ptr.*);
            total_weight += weight;

            for (entry.value_ptr.prices) |ap| {
                const gop = try asset_prices.getOrPut(ap.asset_id);
                if (!gop.found_existing) {
                    gop.value_ptr.* = std.ArrayList(PriceEntry).empty;
                }
                try gop.value_ptr.append(self.allocator, PriceEntry{ .price = ap.price, .weight = weight });
            }
        }

        if (total_weight < self.validator_set.twoThirdsWeight()) {
            return error.InsufficientParticipation;
        }

        var result = std.ArrayList(AssetPrice).empty;
        errdefer result.deinit(self.allocator);

        var agg_it = asset_prices.iterator();
        while (agg_it.next()) |entry| {
            const asset_id = entry.key_ptr.*;
            const prices_list = entry.value_ptr;

            if (prices_list.items.len < self.config.min_participants) {
                continue;
            }

            const median = try computeWeightedMedian(self.allocator, prices_list.items, self.config.max_deviation_bps);
            try result.append(self.allocator, .{
                .asset_id = asset_id,
                .price = median,
            });
        }

        const owned = try result.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(owned);

        for (owned) |ap| {
            try self.aggregated_prices.put(ap.asset_id, ap.price);
        }

        return owned;
    }

    pub fn hasSubmitted(self: *const Oracle, validator: shared.types.Address) bool {
        return self.submissions.contains(validator);
    }

    pub fn getAggregatedPrice(self: *const Oracle, asset_id: u32) ?shared.types.Price {
        return self.aggregated_prices.get(asset_id);
    }

    pub fn clearSubmissions(self: *Oracle) void {
        var it = self.submissions.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.value_ptr.prices);
        }
        self.submissions.clearRetainingCapacity();
    }
};

fn computeWeightedMedian(
    allocator: std.mem.Allocator,
    entries: []const PriceEntry,
    max_deviation_bps: u16,
) !shared.types.Price {
    const sorted = try allocator.dupe(PriceEntry, entries);
    defer allocator.free(sorted);
    std.mem.sort(PriceEntry, sorted, {}, struct {
        fn lessThan(_: void, a: PriceEntry, b: PriceEntry) bool {
            return a.price < b.price;
        }
    }.lessThan);

    const initial_median = weightedMedianFromSorted(sorted);
    if (max_deviation_bps == 0 or sorted.len <= 2) return initial_median;

    var filtered = std.ArrayList(PriceEntry).empty;
    defer filtered.deinit(allocator);
    for (sorted) |entry| {
        if (isWithinDeviation(initial_median, entry.price, max_deviation_bps)) {
            try filtered.append(allocator, entry);
        }
    }
    if (filtered.items.len == 0 or filtered.items.len == sorted.len) {
        return initial_median;
    }

    std.mem.sort(PriceEntry, filtered.items, {}, struct {
        fn lessThan(_: void, a: PriceEntry, b: PriceEntry) bool {
            return a.price < b.price;
        }
    }.lessThan);

    return weightedMedianFromSorted(filtered.items);
}

fn weightedMedianFromSorted(sorted: []const PriceEntry) shared.types.Price {
    var total_weight: u64 = 0;
    for (sorted) |e| {
        total_weight += e.weight;
    }

    const half_weight = total_weight / 2;
    var cumulative: u64 = 0;
    for (sorted) |e| {
        cumulative += e.weight;
        if (cumulative >= half_weight) {
            return e.price;
        }
    }

    return 0;
}

fn isWithinDeviation(
    reference_price: shared.types.Price,
    candidate_price: shared.types.Price,
    max_deviation_bps: u16,
) bool {
    if (reference_price == 0) return true;
    const diff = if (candidate_price >= reference_price)
        candidate_price - reference_price
    else
        reference_price - candidate_price;
    const deviation_bps = (@as(u512, diff) * 10_000) / @as(u512, reference_price);
    return deviation_bps <= max_deviation_bps;
}

test "five validator submissions produce the median" {
    const alloc = std.testing.allocator;
    var validators = [_]ValidatorInfo{
        .{ .address = [_]u8{1} ** 20, .weight = 1 },
        .{ .address = [_]u8{2} ** 20, .weight = 1 },
        .{ .address = [_]u8{3} ** 20, .weight = 1 },
        .{ .address = [_]u8{4} ** 20, .weight = 1 },
        .{ .address = [_]u8{5} ** 20, .weight = 1 },
    };
    const vset = ValidatorSet.init(&validators);

    var oracle = Oracle.init(vset, .{}, alloc);
    defer oracle.deinit();

    const sig = [_]u8{0} ** 96;

    try oracle.submitPrices(validators[0].address, &.{.{ .asset_id = 0, .price = 50100 }}, sig, 0);
    try oracle.submitPrices(validators[1].address, &.{.{ .asset_id = 0, .price = 50000 }}, sig, 0);
    try oracle.submitPrices(validators[2].address, &.{.{ .asset_id = 0, .price = 49900 }}, sig, 0);
    try oracle.submitPrices(validators[3].address, &.{.{ .asset_id = 0, .price = 50050 }}, sig, 0);
    try oracle.submitPrices(validators[4].address, &.{.{ .asset_id = 0, .price = 50000 }}, sig, 0);

    const result = try oracle.aggregate();
    defer alloc.free(result);

    try std.testing.expectEqual(@as(shared.types.Price, 50000), result[0].price);
}

test "outlier submission is filtered before the median" {
    const alloc = std.testing.allocator;
    var validators = [_]ValidatorInfo{
        .{ .address = [_]u8{1} ** 20, .weight = 1 },
        .{ .address = [_]u8{2} ** 20, .weight = 1 },
        .{ .address = [_]u8{3} ** 20, .weight = 1 },
        .{ .address = [_]u8{4} ** 20, .weight = 1 },
        .{ .address = [_]u8{5} ** 20, .weight = 1 },
    };
    const vset = ValidatorSet.init(&validators);

    var oracle = Oracle.init(vset, .{}, alloc);
    defer oracle.deinit();

    const sig = [_]u8{0} ** 96;

    try oracle.submitPrices(validators[0].address, &.{.{ .asset_id = 0, .price = 50000 }}, sig, 0);
    try oracle.submitPrices(validators[1].address, &.{.{ .asset_id = 0, .price = 50000 }}, sig, 0);
    try oracle.submitPrices(validators[2].address, &.{.{ .asset_id = 0, .price = 50000 }}, sig, 0);
    try oracle.submitPrices(validators[3].address, &.{.{ .asset_id = 0, .price = 99999 }}, sig, 0);
    try oracle.submitPrices(validators[4].address, &.{.{ .asset_id = 0, .price = 50000 }}, sig, 0);

    const result = try oracle.aggregate();
    defer alloc.free(result);

    try std.testing.expect(result[0].price < 51000);
}

test "stale submissions are excluded from aggregation" {
    const alloc = std.testing.allocator;
    var validators = [_]ValidatorInfo{
        .{ .address = [_]u8{1} ** 20, .weight = 1 },
        .{ .address = [_]u8{2} ** 20, .weight = 1 },
        .{ .address = [_]u8{3} ** 20, .weight = 1 },
    };
    const vset = ValidatorSet.init(&validators);

    const now_ms: i64 = 1_700_000_000_000;
    var oracle = Oracle.init(vset, .{
        .max_age_ms = 5_000,
        .now_ms_fn = struct {
            fn now() i64 {
                return 1_700_000_000_000;
            }
        }.now,
    }, alloc);
    defer oracle.deinit();

    const sig = [_]u8{0} ** 96;
    try oracle.submitPrices(validators[0].address, &.{.{ .asset_id = 0, .price = 50000 }}, sig, now_ms - 10_000);
    try oracle.submitPrices(validators[1].address, &.{.{ .asset_id = 0, .price = 50100 }}, sig, now_ms);
    try oracle.submitPrices(validators[2].address, &.{.{ .asset_id = 0, .price = 50200 }}, sig, now_ms);

    const result = try oracle.aggregate();
    defer alloc.free(result);

    try std.testing.expect(result[0].price >= 50100);
}

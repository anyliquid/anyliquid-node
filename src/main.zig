const std = @import("std");
const anyliquid = @import("lib.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var app = try anyliquid.App.init(gpa.allocator());
    defer app.deinit();
    try app.connect();

    std.debug.print("AnyLiquid Node scaffold\nzig: {s}\nthroughput target: {s}\nexecution path: {s}\n", .{
        "0.15.2",
        "1,000,000 TPS",
        "clearinghouse-first",
    });
}

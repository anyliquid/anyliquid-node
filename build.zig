const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const lib_module = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "anyliquid-node",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the AnyLiquid node scaffold");
    run_step.dependOn(&run_cmd.step);

    // Unit tests - run all test blocks from lib.zig
    const unit_tests = b.addTest(.{ .root_module = lib_module });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    run_unit_tests.has_side_effects = true; // Prevents LLVM optimization bugs

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // Integration tests (T2/T3 tier)
    // Note: May encounter Zig 0.15.2 LLVM backend bugs with --listen=-
    // If tests fail with "LLVM ERROR: Unsupported library call operation",
    // try: zig build test --release=safe
    const integration_root = b.createModule(.{
        .root_source_file = b.path("tests/all.zig"),
        .target = target,
        .optimize = optimize,
    });
    integration_root.addImport("anyliquid", lib_module);

    const integration_tests = b.addTest(.{
        .root_module = integration_root,
    });

    const run_integration_tests = b.addRunArtifact(integration_tests);
    run_integration_tests.has_side_effects = true;

    const test_all_step = b.step("test-all", "Run unit and integration tests");
    test_all_step.dependOn(&run_unit_tests.step);
    test_all_step.dependOn(&run_integration_tests.step);

    // Aliases for CI configuration
    _ = b.step("bench", "Run performance benchmarks (placeholder)");
    _ = b.step("fuzz", "Run fuzz tests (placeholder)");
    _ = b.step("chaos", "Run chaos tests (placeholder)");
}

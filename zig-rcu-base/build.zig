const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ===== Library Module =====
    _ = b.addModule("rcu", .{
        .root_source_file = b.path("rcu.zig"),
    });

    // ===== Tests =====
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test_rcu.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_tests.step);

    // ===== Examples =====
    const examples = b.addExecutable(.{
        .name = "examples",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_examples = b.addRunArtifact(examples);
    const examples_step = b.step("run-examples", "Run example programs");
    examples_step.dependOn(&run_examples.step);

    // ===== Benchmarks =====
    const benchmark = b.addExecutable(.{
        .name = "benchmark",
        .root_module = b.createModule(.{
            .root_source_file = b.path("benchmark.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });

    const run_benchmark = b.addRunArtifact(benchmark);
    const benchmark_step = b.step("benchmark", "Run performance benchmarks");
    benchmark_step.dependOn(&run_benchmark.step);
}

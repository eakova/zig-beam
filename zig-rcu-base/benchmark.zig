const std = @import("std");
const Rcu = @import("rcu.zig").Rcu;
const Thread = std.Thread;
const Timer = std.time.Timer;

const Config = struct {
    value: u64,

    fn destroy(self: *Config, allocator: std.mem.Allocator) void {
        allocator.destroy(self);
    }
};

fn benchmark(
    comptime name: []const u8,
    num_readers: usize,
    num_writers: usize,
    duration_ms: u64,
) !void {
    std.debug.print("\n=== Benchmark: {} ===\n", .{name});
    std.debug.print("Readers: {}, Writers: {}, Duration: {}ms\n", 
        .{ num_readers, num_writers, duration_ms });

    const allocator = std.heap.page_allocator;

    const initial = try allocator.create(Config);
    initial.* = .{ .value = 0 };

    const RcuConfig = Rcu(Config);
    const rcu = try RcuConfig.init(allocator, initial, Config.destroy, .{
        .max_pending_mods = 8192,
        .reclaim_interval_ns = 5 * std.time.ns_per_ms,
    });
    defer rcu.deinit();

    var stop = std.atomic.Value(bool).init(false);
    var total_reads = std.atomic.Value(u64).init(0);
    var total_writes = std.atomic.Value(u64).init(0);

    // Reader thread
    const ReaderContext = struct {
        rcu: *const RcuConfig,
        stop: *std.atomic.Value(bool),
        reads: *std.atomic.Value(u64),

        fn run(self: *@This()) void {
            var local_reads: u64 = 0;
            while (!self.stop.load(.Acquire)) {
                const guard = self.rcu.read() catch break;
                defer guard.release();
                _ = guard.get().value;
                local_reads += 1;
            }
            _ = self.reads.fetchAdd(local_reads, .Monotonic);
        }
    };

    // Writer thread
    const WriterContext = struct {
        rcu: *RcuConfig,
        stop: *std.atomic.Value(bool),
        writes: *std.atomic.Value(u64),

        fn run(self: *@This()) void {
            const UpdateContext = struct {
                increment: u64,
                fn updateFn(ctx: *anyopaque, alloc: std.mem.Allocator, current: ?*const Config) !*Config {
                    const self_ctx: *@This() = @ptrCast(@alignCast(ctx));
                    const new_config = try alloc.create(Config);
                    new_config.* = current.?.*;
                    new_config.value += self_ctx.increment;
                    return new_config;
                }
            };

            var local_writes: u64 = 0;
            while (!self.stop.load(.Acquire)) {
                var ctx = UpdateContext{ .increment = 1 };
                self.rcu.update(&ctx, UpdateContext.updateFn) catch {
                    Thread.sleep(1 * std.time.ns_per_ms);
                    continue;
                };
                local_writes += 1;
            }
            _ = self.writes.fetchAdd(local_writes, .Monotonic);
        }
    };

    // Spawn threads
    var reader_threads = try allocator.alloc(Thread, num_readers);
    defer allocator.free(reader_threads);
    var reader_contexts = try allocator.alloc(ReaderContext, num_readers);
    defer allocator.free(reader_contexts);

    var writer_threads = try allocator.alloc(Thread, num_writers);
    defer allocator.free(writer_threads);
    var writer_contexts = try allocator.alloc(WriterContext, num_writers);
    defer allocator.free(writer_contexts);

    var timer = try Timer.start();

    for (reader_threads, reader_contexts) |*thread, *ctx| {
        ctx.* = .{ .rcu = rcu, .stop = &stop, .reads = &total_reads };
        thread.* = try Thread.spawn(.{}, ReaderContext.run, .{ctx});
    }

    for (writer_threads, writer_contexts) |*thread, *ctx| {
        ctx.* = .{ .rcu = rcu, .stop = &stop, .writes = &total_writes };
        thread.* = try Thread.spawn(.{}, WriterContext.run, .{ctx});
    }

    // Run for specified duration
    Thread.sleep(duration_ms * std.time.ns_per_ms);

    // Signal stop
    stop.store(true, .Release);

    // Wait for all threads
    for (reader_threads) |thread| thread.join();
    for (writer_threads) |thread| thread.join();

    const elapsed_ns = timer.read();
    const elapsed_s = @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, std.time.ns_per_s);

    const reads = total_reads.load(.Monotonic);
    const writes = total_writes.load(.Monotonic);

    const reads_per_sec = @as(f64, @floatFromInt(reads)) / elapsed_s;
    const writes_per_sec = @as(f64, @floatFromInt(writes)) / elapsed_s;

    std.debug.print("Results:\n", .{});
    std.debug.print("  Total reads:  {} ({d:.2} million/sec)\n", 
        .{ reads, reads_per_sec / 1_000_000.0 });
    std.debug.print("  Total writes: {} ({d:.2} thousand/sec)\n", 
        .{ writes, writes_per_sec / 1_000.0 });
    std.debug.print("  Read/Write ratio: {d:.1}:1\n", 
        .{ @as(f64, @floatFromInt(reads)) / @as(f64, @floatFromInt(writes)) });
    std.debug.print("  Elapsed: {d:.3}s\n", .{elapsed_s});

    if (@import("builtin").mode == .Debug) {
        const diag = rcu.getDiagnostics();
        std.debug.print("\nDiagnostics:\n", .{});
        std.debug.print("  Epoch advances: {}\n", .{diag.epoch_advances.load(.Monotonic)});
        std.debug.print("  Reclamations:   {}\n", .{diag.reclamations.load(.Monotonic)});
    }
}

pub fn main() !void {
    std.debug.print("\n╔════════════════════════════════════════╗\n", .{});
    std.debug.print("║  RCU Performance Benchmark Suite      ║\n", .{});
    std.debug.print("╚════════════════════════════════════════╝\n", .{});

    // Benchmark 1: Read-heavy (typical use case)
    try benchmark("Read-Heavy Workload", 16, 2, 2000);

    // Benchmark 2: Balanced
    try benchmark("Balanced Workload", 8, 4, 2000);

    // Benchmark 3: Many readers
    try benchmark("Many Readers", 32, 1, 2000);

    // Benchmark 4: Extreme read-heavy
    try benchmark("Extreme Read-Heavy", 64, 1, 2000);

    std.debug.print("\n╔════════════════════════════════════════╗\n", .{});
    std.debug.print("║  Benchmarks Complete                  ║\n", .{});
    std.debug.print("╚════════════════════════════════════════╝\n", .{});
}

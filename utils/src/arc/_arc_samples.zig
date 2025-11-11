//! ARC samples that double as executable documentation.

const std = @import("std");
const testing = std.testing;
const ArcModule = @import("arc_core");
const ArcPoolModule = @import("arc_pool");
const DetectorModule = @import("cycle-detector/arc_cycle_detector.zig");

const ArcU32 = ArcModule.Arc(u32);
const ArcString = ArcModule.Arc([]const u8);
const ArcBytes = ArcModule.Arc([4]u8);
const Pool = ArcPoolModule.ArcPool(Node);
const Detector = DetectorModule.ArcCycleDetector(Node);
const CounterPool = ArcPoolModule.ArcPool(struct { value: usize });

const Node = struct {
    label: u8,
    next: ?ArcModule.Arc(Node) = null,
};

// --------------------------------------------------------------------------
// SIMPLE SAMPLE
// --------------------------------------------------------------------------
/// Simple usage: create, clone, and observe shared state.
pub fn sampleSimpleClone(allocator: std.mem.Allocator) !u32 {
    var arc = try ArcU32.init(allocator, 10);
    defer arc.release();

    var clone = arc.clone();
    defer clone.release();

    return arc.get().* + clone.get().*; // 20
}

test "sample (simple): clone + observe" {
    try testing.expectEqual(@as(u32, 20), try sampleSimpleClone(testing.allocator));
}

// --------------------------------------------------------------------------
// MODERATE SAMPLE
// --------------------------------------------------------------------------
/// Moderate usage: keep weak references and detect evicted entries.
pub fn sampleModerateWeakCache(allocator: std.mem.Allocator) !bool {
    var hello = try ArcString.init(allocator, "hello");
    var bye = try ArcString.init(allocator, "bye");
    defer bye.release();

    const weak_hello = hello.downgrade() orelse return false;
    defer weak_hello.release();
    hello.release();

    const weak_bye = bye.downgrade() orelse return false;
    defer weak_bye.release();

    const hello_hit = weak_hello.upgrade();
    const bye_hit = weak_bye.upgrade();
    if (bye_hit) |arc| arc.release();

    return hello_hit == null and bye_hit != null;
}

test "sample (moderate): weak cache" {
    try testing.expect(try sampleModerateWeakCache(testing.allocator));
}

/// Moderate usage: demonstrate copy-on-write semantics via `makeMut`.
pub fn sampleModerateMakeMut(allocator: std.mem.Allocator) !bool {
    var arc = try ArcBytes.init(allocator, .{ 1, 2, 3, 4 });
    defer arc.release();
    var clone = arc.clone();
    defer clone.release();

    const ptr = try arc.makeMut();
    ptr.*[0] = 9;

    return clone.get().*[0] == 1 and arc.get().*[0] == 9;
}

test "sample (moderate): makeMut copy-on-write" {
    try testing.expect(try sampleModerateMakeMut(testing.allocator));
}

// --------------------------------------------------------------------------
// ADVANCED SAMPLE
// --------------------------------------------------------------------------
/// Advanced usage: combine `ArcPool` and the cycle detector to find leaks.
pub fn sampleAdvancedPoolAndDetector(allocator: std.mem.Allocator) !usize {
    var pool = Pool.init(allocator);
    defer pool.deinit();

    var detector = Detector.init(allocator, traceNode, null);
    defer detector.deinit();

    var node_a = try pool.create(.{ .label = 'A', .next = null });
    var node_b = try pool.create(.{ .label = 'B', .next = null });

    node_a.asPtr().data.next = node_b.clone();
    node_b.asPtr().data.next = node_a.clone();

    try detector.track(node_a.clone());
    try detector.track(node_b.clone());

    var weak_a = node_a.downgrade().?;
    var weak_b = node_b.downgrade().?;

    node_a.release();
    node_b.release();

    var leaks = try detector.detectCycles();
    defer leaks.deinit();

    for (leaks.list.items) |arc| {
        if (arc.asPtr().data.next) |child| child.release();
        arc.release();
    }
    pool.drainThreadCache();

    weak_a.release();
    weak_b.release();

    return leaks.list.items.len;
}

fn traceNode(_: ?*anyopaque, allocator: std.mem.Allocator, data: *const Node, children: *Detector.ChildList) void {
    if (data.next) |child| {
        if (!child.isInline()) {
            children.append(allocator, child.asPtr()) catch unreachable;
        }
    }
}

test "sample (advanced): pooled cycle detection" {
    try testing.expectEqual(@as(usize, 2), try sampleAdvancedPoolAndDetector(testing.allocator));
}

/// Advanced usage: run pooled work inside `withThreadCache` across threads.
pub fn sampleAdvancedPoolWithThreadCache(allocator: std.mem.Allocator) !usize {
    var pool = CounterPool.init(allocator);
    defer pool.deinit();

    var total = std.atomic.Value(usize).init(0);
    var contexts: [4]ThreadCacheCtx = undefined;
    var threads: [4]std.Thread = undefined;
    const base_iters: usize = 8;

    for (&contexts, 0..) |*ctx, idx| {
        ctx.* = .{
            .pool = &pool,
            .sum = &total,
            .iterations = base_iters + idx,
        };
        threads[idx] = try std.Thread.spawn(.{}, poolWorkerThread, .{ctx});
    }
    for (threads) |t| t.join();

    pool.drainThreadCache();
    return total.load(.seq_cst);
}

const ThreadCacheCtx = struct {
    pool: *CounterPool,
    sum: *std.atomic.Value(usize),
    iterations: usize,
};

fn poolWorkerThread(ctx: *ThreadCacheCtx) void {
    ctx.pool.withThreadCache(populateCounterPool, @ptrCast(ctx)) catch unreachable;
}

fn populateCounterPool(pool: *CounterPool, raw_ctx: *anyopaque) anyerror!void {
    const ctx: *ThreadCacheCtx = @ptrCast(@alignCast(raw_ctx));
    var i: usize = 0;
    while (i < ctx.iterations) : (i += 1) {
        const arc = try pool.create(.{ .value = i });
        _ = ctx.sum.fetchAdd(1, .seq_cst);
        pool.recycle(arc);
    }
}

test "sample (advanced): pool with thread cache" {
    const total = try sampleAdvancedPoolWithThreadCache(testing.allocator);
    try testing.expectEqual(@as(usize, 38), total);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const simple = try sampleSimpleClone(allocator);
    const weak_cache = try sampleModerateWeakCache(allocator);
    const cow = try sampleModerateMakeMut(allocator);
    const leak_count = try sampleAdvancedPoolAndDetector(allocator);
    const pool_sum = try sampleAdvancedPoolWithThreadCache(allocator);

    std.debug.print(
        "ARC samples -> simple_sum={}, weak_cache={}, cow={}, leaks={}, pool_sum={}\n",
        .{ simple, weak_cache, cow, leak_count, pool_sum },
    );
}

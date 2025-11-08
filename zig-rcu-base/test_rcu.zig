const std = @import("std");
const testing = std.testing;
const Thread = std.Thread;
const Rcu = @import("rcu.zig").Rcu;

//==============================================================================
// TEST DATA STRUCTURES
//==============================================================================

const Config = struct {
    port: u16,
    timeout_ms: u32,
    max_connections: u32,

    fn destroy(self: *Config, allocator: std.mem.Allocator) void {
        allocator.destroy(self);
    }

    fn clone(self: *const Config, allocator: std.mem.Allocator) !*Config {
        const new = try allocator.create(Config);
        new.* = self.*;
        return new;
    }
};

const Database = struct {
    name: []const u8,
    connections: std.ArrayList(Connection),

    const Connection = struct {
        id: u32,
        active: bool,
    };

    fn init(allocator: std.mem.Allocator, name: []const u8) !*Database {
        const db = try allocator.create(Database);
        db.* = .{
            .name = try allocator.dupe(u8, name),
            .connections = std.ArrayList(Connection).init(allocator),
        };
        return db;
    }

    fn destroy(self: *Database, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        self.connections.deinit();
        allocator.destroy(self);
    }

    fn addConnection(self: *const Database, allocator: std.mem.Allocator, id: u32) !*Database {
        const new_db = try allocator.create(Database);
        new_db.* = .{
            .name = try allocator.dupe(u8, self.name),
            .connections = try self.connections.clone(),
        };
        try new_db.connections.append(.{ .id = id, .active = true });
        return new_db;
    }
};

//==============================================================================
// BASIC TESTS
//==============================================================================

test "RCU: basic init and deinit" {
    const allocator = testing.allocator;

    const initial = try allocator.create(Config);
    initial.* = .{ .port = 8080, .timeout_ms = 5000, .max_connections = 100 };

    const RcuConfig = Rcu(Config);
    const rcu = try RcuConfig.init(allocator, initial, Config.destroy, .{});
    defer rcu.deinit();

    // Should be able to read
    const guard = try rcu.read();
    defer guard.release();

    const config = guard.get();
    try testing.expectEqual(@as(u16, 8080), config.port);
}

test "RCU: single reader" {
    const allocator = testing.allocator;

    const initial = try allocator.create(Config);
    initial.* = .{ .port = 3000, .timeout_ms = 1000, .max_connections = 50 };

    const RcuConfig = Rcu(Config);
    const rcu = try RcuConfig.init(allocator, initial, Config.destroy, .{});
    defer rcu.deinit();

    {
        const guard = try rcu.read();
        defer guard.release();
        try testing.expectEqual(@as(u16, 3000), guard.get().port);
    }

    {
        const guard = try rcu.read();
        defer guard.release();
        try testing.expectEqual(@as(u32, 1000), guard.get().timeout_ms);
    }
}

test "RCU: single update" {
    const allocator = testing.allocator;

    const initial = try allocator.create(Config);
    initial.* = .{ .port = 8080, .timeout_ms = 5000, .max_connections = 100 };

    const RcuConfig = Rcu(Config);
    const rcu = try RcuConfig.init(allocator, initial, Config.destroy, .{});
    defer rcu.deinit();

    // Read initial value
    {
        const guard = try rcu.read();
        defer guard.release();
        try testing.expectEqual(@as(u16, 8080), guard.get().port);
    }

    // Update
    const UpdateContext = struct {
        new_port: u16,
        fn updateFn(ctx: *anyopaque, alloc: std.mem.Allocator, current: ?*const Config) !*Config {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            const new_config = try alloc.create(Config);
            new_config.* = current.?.*;
            new_config.port = self.new_port;
            return new_config;
        }
    };
    var ctx = UpdateContext{ .new_port = 9090 };
    try rcu.update(&ctx, UpdateContext.updateFn);

    // Give reclaimer time to process
    Thread.sleep(100 * std.time.ns_per_ms);

    // Read updated value
    {
        const guard = try rcu.read();
        defer guard.release();
        try testing.expectEqual(@as(u16, 9090), guard.get().port);
    }
}

test "RCU: multiple updates" {
    const allocator = testing.allocator;

    const initial = try allocator.create(Config);
    initial.* = .{ .port = 8000, .timeout_ms = 1000, .max_connections = 10 };

    const RcuConfig = Rcu(Config);
    const rcu = try RcuConfig.init(allocator, initial, Config.destroy, .{});
    defer rcu.deinit();

    const UpdateContext = struct {
        increment: u16,
        fn updateFn(ctx: *anyopaque, alloc: std.mem.Allocator, current: ?*const Config) !*Config {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            const new_config = try alloc.create(Config);
            new_config.* = current.?.*;
            new_config.port += self.increment;
            return new_config;
        }
    };

    // Apply 10 updates
    for (0..10) |i| {
        var ctx = UpdateContext{ .increment = 1 };
        try rcu.update(&ctx, UpdateContext.updateFn);
        Thread.sleep(10 * std.time.ns_per_ms);
        _ = i;
    }

    Thread.sleep(200 * std.time.ns_per_ms);

    // Verify final value
    {
        const guard = try rcu.read();
        defer guard.release();
        try testing.expectEqual(@as(u16, 8010), guard.get().port);
    }
}

//==============================================================================
// CONCURRENCY TESTS
//==============================================================================

test "RCU: concurrent readers" {
    const allocator = testing.allocator;

    const initial = try allocator.create(Config);
    initial.* = .{ .port = 8080, .timeout_ms = 5000, .max_connections = 100 };

    const RcuConfig = Rcu(Config);
    const rcu = try RcuConfig.init(allocator, initial, Config.destroy, .{});
    defer rcu.deinit();

    const ReaderContext = struct {
        rcu: *const RcuConfig,
        reads: *std.atomic.Value(u64),
        
        fn readerTask(self: *@This()) void {
            for (0..1000) |_| {
                const guard = self.rcu.read() catch return;
                defer guard.release();
                const config = guard.get();
                _ = config.port; // Access the data
                _ = self.reads.fetchAdd(1, .Monotonic);
            }
        }
    };

    var reads = std.atomic.Value(u64).init(0);
    var threads: [4]Thread = undefined;
    var contexts: [4]ReaderContext = undefined;

    for (&threads, &contexts) |*thread, *ctx| {
        ctx.* = .{ .rcu = rcu, .reads = &reads };
        thread.* = try Thread.spawn(.{}, ReaderContext.readerTask, .{ctx});
    }

    for (threads) |thread| {
        thread.join();
    }

    try testing.expectEqual(@as(u64, 4000), reads.load(.Monotonic));
}

test "RCU: readers and writers concurrent" {
    const allocator = testing.allocator;

    const initial = try allocator.create(Config);
    initial.* = .{ .port = 8000, .timeout_ms = 1000, .max_connections = 10 };

    const RcuConfig = Rcu(Config);
    const rcu = try RcuConfig.init(allocator, initial, Config.destroy, .{});
    defer rcu.deinit();

    const ReaderContext = struct {
        rcu: *const RcuConfig,
        fn task(self: *@This()) void {
            for (0..500) |_| {
                const guard = self.rcu.read() catch return;
                defer guard.release();
                _ = guard.get().port;
                Thread.sleep(1 * std.time.ns_per_ms);
            }
        }
    };

    const WriterContext = struct {
        rcu: *RcuConfig,
        fn task(self: *@This()) void {
            const UpdateCtx = struct {
                increment: u16,
                fn updateFn(ctx: *anyopaque, alloc: std.mem.Allocator, current: ?*const Config) !*Config {
                    const update_ctx: *@This() = @ptrCast(@alignCast(ctx));
                    const new_config = try alloc.create(Config);
                    new_config.* = current.?.*;
                    new_config.port += update_ctx.increment;
                    return new_config;
                }
            };

            for (0..100) |_| {
                var update_ctx = UpdateCtx{ .increment = 1 };
                self.rcu.update(&update_ctx, UpdateCtx.updateFn) catch return;
                Thread.sleep(5 * std.time.ns_per_ms);
            }
        }
    };

    var reader_ctx = ReaderContext{ .rcu = rcu };
    var writer_ctx = WriterContext{ .rcu = rcu };

    const reader = try Thread.spawn(.{}, ReaderContext.task, .{&reader_ctx});
    const writer = try Thread.spawn(.{}, WriterContext.task, .{&writer_ctx});

    reader.join();
    writer.join();

    Thread.sleep(200 * std.time.ns_per_ms);

    // Verify final state
    {
        const guard = try rcu.read();
        defer guard.release();
        try testing.expectEqual(@as(u16, 8100), guard.get().port);
    }
}

test "RCU: complex data structure" {
    const allocator = testing.allocator;

    const initial = try Database.init(allocator, "primary");
    
    const RcuDatabase = Rcu(Database);
    const rcu = try RcuDatabase.init(allocator, initial, Database.destroy, .{});
    defer rcu.deinit();

    // Read initial
    {
        const guard = try rcu.read();
        defer guard.release();
        try testing.expectEqualStrings("primary", guard.get().name);
        try testing.expectEqual(@as(usize, 0), guard.get().connections.items.len);
    }

    // Add connections
    for (0..5) |i| {
        const AddContext = struct {
            conn_id: u32,
            fn updateFn(ctx: *anyopaque, alloc: std.mem.Allocator, current: ?*const Database) !*Database {
                const self: *@This() = @ptrCast(@alignCast(ctx));
                return current.?.addConnection(alloc, self.conn_id);
            }
        };
        var ctx = AddContext{ .conn_id = @intCast(i) };
        try rcu.update(&ctx, AddContext.updateFn);
        Thread.sleep(20 * std.time.ns_per_ms);
    }

    Thread.sleep(200 * std.time.ns_per_ms);

    // Verify
    {
        const guard = try rcu.read();
        defer guard.release();
        try testing.expectEqual(@as(usize, 5), guard.get().connections.items.len);
    }
}

//==============================================================================
// STRESS TESTS
//==============================================================================

test "RCU: stress test - many readers, many writers" {
    const allocator = testing.allocator;

    const initial = try allocator.create(Config);
    initial.* = .{ .port = 5000, .timeout_ms = 1000, .max_connections = 100 };

    const RcuConfig = Rcu(Config);
    const rcu = try RcuConfig.init(allocator, initial, Config.destroy, .{
        .max_pending_mods = 2048,
        .reclaim_interval_ns = 10 * std.time.ns_per_ms,
    });
    defer rcu.deinit();

    const num_readers = 8;
    const num_writers = 4;
    const reads_per_thread = 500;
    const writes_per_thread = 100;

    const ReaderContext = struct {
        rcu: *const RcuConfig,
        fn task(self: *@This()) void {
            for (0..reads_per_thread) |_| {
                const guard = self.rcu.read() catch return;
                defer guard.release();
                _ = guard.get();
            }
        }
    };

    const WriterContext = struct {
        rcu: *RcuConfig,
        fn task(self: *@This()) void {
            const UpdateCtx = struct {
                increment: u16,
                fn updateFn(ctx: *anyopaque, alloc: std.mem.Allocator, current: ?*const Config) !*Config {
                    const update_ctx: *@This() = @ptrCast(@alignCast(ctx));
                    const new_config = try alloc.create(Config);
                    new_config.* = current.?.*;
                    new_config.port += update_ctx.increment;
                    return new_config;
                }
            };

            for (0..writes_per_thread) |_| {
                var update_ctx = UpdateCtx{ .increment = 1 };
                self.rcu.update(&update_ctx, UpdateCtx.updateFn) catch return;
                Thread.sleep(2 * std.time.ns_per_ms);
            }
        }
    };

    var readers: [num_readers]Thread = undefined;
    var reader_contexts: [num_readers]ReaderContext = undefined;
    
    var writers: [num_writers]Thread = undefined;
    var writer_contexts: [num_writers]WriterContext = undefined;

    // Start all threads
    for (&readers, &reader_contexts) |*thread, *ctx| {
        ctx.* = .{ .rcu = rcu };
        thread.* = try Thread.spawn(.{}, ReaderContext.task, .{ctx});
    }

    for (&writers, &writer_contexts) |*thread, *ctx| {
        ctx.* = .{ .rcu = rcu };
        thread.* = try Thread.spawn(.{}, WriterContext.task, .{ctx});
    }

    // Wait for all
    for (readers) |thread| thread.join();
    for (writers) |thread| thread.join();

    Thread.sleep(500 * std.time.ns_per_ms);

    // Verify
    {
        const guard = try rcu.read();
        defer guard.release();
        const expected = 5000 + (num_writers * writes_per_thread);
        try testing.expectEqual(@as(u16, @intCast(expected)), guard.get().port);
    }
}

test "RCU: memory safety - no leaks" {
    const allocator = testing.allocator;

    const initial = try allocator.create(Config);
    initial.* = .{ .port = 8080, .timeout_ms = 5000, .max_connections = 100 };

    const RcuConfig = Rcu(Config);
    const rcu = try RcuConfig.init(allocator, initial, Config.destroy, .{});

    // Do some operations
    for (0..50) |_| {
        const UpdateContext = struct {
            increment: u16,
            fn updateFn(ctx: *anyopaque, alloc: std.mem.Allocator, current: ?*const Config) !*Config {
                const self: *@This() = @ptrCast(@alignCast(ctx));
                const new_config = try alloc.create(Config);
                new_config.* = current.?.*;
                new_config.port += self.increment;
                return new_config;
            }
        };
        var ctx = UpdateContext{ .increment = 1 };
        try rcu.update(&ctx, UpdateContext.updateFn);
        Thread.sleep(5 * std.time.ns_per_ms);
    }

    Thread.sleep(300 * std.time.ns_per_ms);
    rcu.deinit();

    // If we reach here without leaks, test passes
}

const std = @import("std");
const Rcu = @import("rcu.zig").Rcu;
const Thread = std.Thread;

//==============================================================================
// EXAMPLE 1: GLOBAL CONFIGURATION
//==============================================================================
// A common use case: application configuration that rarely changes
// but is frequently read by many threads.

pub fn example1_global_config() !void {
    std.debug.print("\n=== Example 1: Global Configuration ===\n", .{});
    
    const allocator = std.heap.page_allocator;

    const AppConfig = struct {
        server_url: []const u8,
        port: u16,
        timeout_ms: u32,
        debug_mode: bool,

        fn init(alloc: std.mem.Allocator, url: []const u8, port: u16) !*@This() {
            const config = try alloc.create(@This());
            config.* = .{
                .server_url = try alloc.dupe(u8, url),
                .port = port,
                .timeout_ms = 5000,
                .debug_mode = false,
            };
            return config;
        }

        fn destroy(self: *@This(), alloc: std.mem.Allocator) void {
            alloc.free(self.server_url);
            alloc.destroy(self);
        }
    };

    // Initialize RCU with default config
    const initial = try AppConfig.init(allocator, "https://api.example.com", 8080);
    const RcuConfig = Rcu(AppConfig);
    const config_rcu = try RcuConfig.init(allocator, initial, AppConfig.destroy, .{});
    defer config_rcu.deinit();

    // Simulate worker threads reading config
    const Worker = struct {
        rcu: *const RcuConfig,
        id: u32,

        fn run(self: *@This()) void {
            std.debug.print("Worker {} started\n", .{self.id});
            
            for (0..5) |i| {
                const guard = self.rcu.read() catch return;
                defer guard.release();
                
                const config = guard.get();
                std.debug.print("Worker {}: Connecting to {}:{} (iteration {})\n", 
                    .{ self.id, config.server_url, config.port, i });
                
                Thread.sleep(100 * std.time.ns_per_ms);
            }
        }
    };

    var workers: [3]Thread = undefined;
    var worker_contexts: [3]Worker = undefined;

    for (&workers, &worker_contexts, 0..) |*thread, *ctx, i| {
        ctx.* = .{ .rcu = config_rcu, .id = @intCast(i) };
        thread.* = try Thread.spawn(.{}, Worker.run, .{ctx});
    }

    // Hot-reload configuration after 200ms
    Thread.sleep(200 * std.time.ns_per_ms);
    
    std.debug.print("\n>>> Hot-reloading configuration...\n\n", .{});
    
    const UpdateContext = struct {
        new_port: u16,
        fn updateFn(ctx: *anyopaque, alloc: std.mem.Allocator, current: ?*const AppConfig) !*AppConfig {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            const new_config = try alloc.create(AppConfig);
            new_config.* = .{
                .server_url = try alloc.dupe(u8, current.?.server_url),
                .port = self.new_port,
                .timeout_ms = current.?.timeout_ms,
                .debug_mode = true, // Enable debug mode
            };
            return new_config;
        }
    };
    var update_ctx = UpdateContext{ .new_port = 9090 };
    try config_rcu.update(&update_ctx, UpdateContext.updateFn);

    for (workers) |thread| thread.join();
    
    std.debug.print("Example 1 complete!\n", .{});
}

//==============================================================================
// EXAMPLE 2: ROUTING TABLE
//==============================================================================
// Network routing table that needs fast lookups with rare updates

pub fn example2_routing_table() !void {
    std.debug.print("\n=== Example 2: Routing Table ===\n", .{});
    
    const allocator = std.heap.page_allocator;

    const Route = struct {
        destination: []const u8,
        gateway: []const u8,
        metric: u32,
    };

    const RoutingTable = struct {
        routes: std.ArrayList(Route),
        version: u32,

        fn init(alloc: std.mem.Allocator) !*@This() {
            const table = try alloc.create(@This());
            table.* = .{
                .routes = std.ArrayList(Route).init(alloc),
                .version = 1,
            };
            return table;
        }

        fn destroy(self: *@This(), alloc: std.mem.Allocator) void {
            for (self.routes.items) |route| {
                alloc.free(route.destination);
                alloc.free(route.gateway);
            }
            self.routes.deinit();
            alloc.destroy(self);
        }

        fn findRoute(self: *const @This(), dest: []const u8) ?Route {
            for (self.routes.items) |route| {
                if (std.mem.eql(u8, route.destination, dest)) {
                    return route;
                }
            }
            return null;
        }
    };

    const initial = try RoutingTable.init(allocator);
    const RcuTable = Rcu(RoutingTable);
    const table_rcu = try RcuTable.init(allocator, initial, RoutingTable.destroy, .{});
    defer table_rcu.deinit();

    // Add initial routes
    const AddRouteContext = struct {
        dest: []const u8,
        gateway: []const u8,
        metric: u32,

        fn updateFn(ctx: *anyopaque, alloc: std.mem.Allocator, current: ?*const RoutingTable) !*RoutingTable {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            const new_table = try alloc.create(RoutingTable);
            new_table.* = .{
                .routes = try current.?.routes.clone(),
                .version = current.?.version + 1,
            };
            try new_table.routes.append(.{
                .destination = try alloc.dupe(u8, self.dest),
                .gateway = try alloc.dupe(u8, self.gateway),
                .metric = self.metric,
            });
            return new_table;
        }
    };

    var ctx1 = AddRouteContext{ .dest = "192.168.1.0/24", .gateway = "10.0.0.1", .metric = 100 };
    try table_rcu.update(&ctx1, AddRouteContext.updateFn);
    Thread.sleep(50 * std.time.ns_per_ms);

    var ctx2 = AddRouteContext{ .dest = "192.168.2.0/24", .gateway = "10.0.0.2", .metric = 200 };
    try table_rcu.update(&ctx2, AddRouteContext.updateFn);
    Thread.sleep(50 * std.time.ns_per_ms);

    // Simulate packet forwarding (fast lookups)
    const Forwarder = struct {
        rcu: *const RcuTable,
        id: u32,

        fn run(self: *@This()) void {
            const destinations = [_][]const u8{ "192.168.1.0/24", "192.168.2.0/24", "192.168.3.0/24" };
            
            for (0..10) |i| {
                const guard = self.rcu.read() catch return;
                defer guard.release();
                
                const table = guard.get();
                const dest = destinations[i % destinations.len];
                
                if (table.findRoute(dest)) |route| {
                    std.debug.print("Forwarder {}: {} -> {} (metric: {})\n", 
                        .{ self.id, dest, route.gateway, route.metric });
                } else {
                    std.debug.print("Forwarder {}: No route to {}\n", .{ self.id, dest });
                }
                
                Thread.sleep(50 * std.time.ns_per_ms);
            }
        }
    };

    var forwarders: [2]Thread = undefined;
    var forwarder_contexts: [2]Forwarder = undefined;

    for (&forwarders, &forwarder_contexts, 0..) |*thread, *ctx, i| {
        ctx.* = .{ .rcu = table_rcu, .id = @intCast(i) };
        thread.* = try Thread.spawn(.{}, Forwarder.run, .{ctx});
    }

    for (forwarders) |thread| thread.join();
    
    std.debug.print("Example 2 complete!\n", .{});
}

//==============================================================================
// EXAMPLE 3: FEATURE FLAGS
//==============================================================================
// Feature flag system for A/B testing and gradual rollouts

pub fn example3_feature_flags() !void {
    std.debug.print("\n=== Example 3: Feature Flags ===\n", .{});
    
    const allocator = std.heap.page_allocator;

    const FeatureFlags = struct {
        flags: std.StringHashMap(bool),

        fn init(alloc: std.mem.Allocator) !*@This() {
            const ff = try alloc.create(@This());
            ff.* = .{
                .flags = std.StringHashMap(bool).init(alloc),
            };
            return ff;
        }

        fn destroy(self: *@This(), alloc: std.mem.Allocator) void {
            var it = self.flags.keyIterator();
            while (it.next()) |key| {
                alloc.free(key.*);
            }
            self.flags.deinit();
            alloc.destroy(self);
        }

        fn isEnabled(self: *const @This(), name: []const u8) bool {
            return self.flags.get(name) orelse false;
        }

        fn clone(self: *const @This(), alloc: std.mem.Allocator) !*@This() {
            const new = try @This().init(alloc);
            var it = self.flags.iterator();
            while (it.next()) |entry| {
                const key_copy = try alloc.dupe(u8, entry.key_ptr.*);
                try new.flags.put(key_copy, entry.value_ptr.*);
            }
            return new;
        }
    };

    const initial = try FeatureFlags.init(allocator);
    const RcuFlags = Rcu(FeatureFlags);
    const flags_rcu = try RcuFlags.init(allocator, initial, FeatureFlags.destroy, .{});
    defer flags_rcu.deinit();

    // Set initial flags
    const SetFlagContext = struct {
        name: []const u8,
        enabled: bool,

        fn updateFn(ctx: *anyopaque, alloc: std.mem.Allocator, current: ?*const FeatureFlags) !*FeatureFlags {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            const new_flags = try current.?.clone(alloc);
            const key = try alloc.dupe(u8, self.name);
            try new_flags.flags.put(key, self.enabled);
            return new_flags;
        }
    };

    var ctx1 = SetFlagContext{ .name = "new_ui", .enabled = false };
    try flags_rcu.update(&ctx1, SetFlagContext.updateFn);
    Thread.sleep(50 * std.time.ns_per_ms);

    // Simulate services checking flags
    const Service = struct {
        rcu: *const RcuFlags,
        name: []const u8,

        fn run(self: *@This()) void {
            for (0..5) |i| {
                const guard = self.rcu.read() catch return;
                defer guard.release();
                
                const flags = guard.get();
                const new_ui_enabled = flags.isEnabled("new_ui");
                const experimental_enabled = flags.isEnabled("experimental_api");
                
                std.debug.print("{} (iter {}): new_ui={}, experimental={}\n", 
                    .{ self.name, i, new_ui_enabled, experimental_enabled });
                
                Thread.sleep(100 * std.time.ns_per_ms);
            }
        }
    };

    var service1_ctx = Service{ .rcu = flags_rcu, .name = "WebServer" };
    var service2_ctx = Service{ .rcu = flags_rcu, .name = "APIServer" };

    const service1 = try Thread.spawn(.{}, Service.run, .{&service1_ctx});
    const service2 = try Thread.spawn(.{}, Service.run, .{&service2_ctx});

    // Enable new UI after 200ms (gradual rollout)
    Thread.sleep(200 * std.time.ns_per_ms);
    std.debug.print("\n>>> Enabling new_ui flag...\n\n", .{});
    
    var ctx2 = SetFlagContext{ .name = "new_ui", .enabled = true };
    try flags_rcu.update(&ctx2, SetFlagContext.updateFn);

    service1.join();
    service2.join();
    
    std.debug.print("Example 3 complete!\n", .{});
}

//==============================================================================
// EXAMPLE 4: CACHE STATISTICS
//==============================================================================
// Statistics that are frequently read but occasionally updated

pub fn example4_cache_stats() !void {
    std.debug.print("\n=== Example 4: Cache Statistics ===\n", .{});
    
    const allocator = std.heap.page_allocator;

    const CacheStats = struct {
        hits: u64,
        misses: u64,
        evictions: u64,
        size: usize,

        fn init(alloc: std.mem.Allocator) !*@This() {
            const stats = try alloc.create(@This());
            stats.* = .{ .hits = 0, .misses = 0, .evictions = 0, .size = 0 };
            return stats;
        }

        fn destroy(self: *@This(), alloc: std.mem.Allocator) void {
            alloc.destroy(self);
        }

        fn hitRate(self: *const @This()) f64 {
            const total = self.hits + self.misses;
            if (total == 0) return 0.0;
            return @as(f64, @floatFromInt(self.hits)) / @as(f64, @floatFromInt(total)) * 100.0;
        }
    };

    const initial = try CacheStats.init(allocator);
    const RcuStats = Rcu(CacheStats);
    const stats_rcu = try RcuStats.init(allocator, initial, CacheStats.destroy, .{});
    defer stats_rcu.deinit();

    // Simulate cache operations updating stats
    const CacheOp = struct {
        rcu: *RcuStats,

        fn run(self: *@This()) void {
            const UpdateContext = struct {
                hit: bool,
                fn updateFn(ctx: *anyopaque, alloc: std.mem.Allocator, current: ?*const CacheStats) !*CacheStats {
                    const update_ctx: *@This() = @ptrCast(@alignCast(ctx));
                    const new_stats = try alloc.create(CacheStats);
                    new_stats.* = current.?.*;
                    if (update_ctx.hit) {
                        new_stats.hits += 1;
                    } else {
                        new_stats.misses += 1;
                    }
                    return new_stats;
                }
            };

            var prng = std.rand.DefaultPrng.init(@intCast(std.time.timestamp()));
            const random = prng.random();

            for (0..20) |_| {
                const is_hit = random.boolean();
                var ctx = UpdateContext{ .hit = is_hit };
                self.rcu.update(&ctx, UpdateContext.updateFn) catch return;
                Thread.sleep(25 * std.time.ns_per_ms);
            }
        }
    };

    // Monitoring thread reading stats
    const Monitor = struct {
        rcu: *const RcuStats,

        fn run(self: *@This()) void {
            for (0..10) |i| {
                const guard = self.rcu.read() catch return;
                defer guard.release();
                
                const stats = guard.get();
                std.debug.print("Monitor ({}): Hits={}, Misses={}, Rate={d:.1}%\n",
                    .{ i, stats.hits, stats.misses, stats.hitRate() });
                
                Thread.sleep(100 * std.time.ns_per_ms);
            }
        }
    };

    var cache_ctx = CacheOp{ .rcu = stats_rcu };
    var monitor_ctx = Monitor{ .rcu = stats_rcu };

    const cache_thread = try Thread.spawn(.{}, CacheOp.run, .{&cache_ctx});
    const monitor_thread = try Thread.spawn(.{}, Monitor.run, .{&monitor_ctx});

    cache_thread.join();
    monitor_thread.join();

    std.debug.print("Example 4 complete!\n", .{});
}

//==============================================================================
// MAIN
//==============================================================================

pub fn main() !void {
    try example1_global_config();
    try example2_routing_table();
    try example3_feature_flags();
    try example4_cache_stats();
    
    std.debug.print("\n=== All examples completed successfully! ===\n", .{});
}

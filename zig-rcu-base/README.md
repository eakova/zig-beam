# RCU.zig - Production-Ready Read-Copy-Update for Zig

A standalone, high-performance Read-Copy-Update (RCU) synchronization primitive for the Zig programming language.

## 🎯 What is RCU?

RCU (Read-Copy-Update) is a synchronization mechanism that enables **extremely fast, wait-free reads** of shared data while safely managing updates and memory reclamation in highly concurrent environments.

### Key Properties

- **Zero-Cost Reads**: Readers never block or allocate
- **Lock-Free Updates**: Writers submit updates without blocking
- **Safe Reclamation**: Automatic memory management prevents use-after-free
- **Single Writer Principle**: Eliminates writer-writer contention

## 📊 When to Use RCU

✅ **Perfect for:**
- Global configuration that changes rarely but is read constantly
- Routing tables, DNS caches, feature flags
- Shared statistics or metrics
- Any data structure with a high read-to-write ratio (>100:1)

❌ **Not ideal for:**
- Frequently updated data structures
- Fine-grained updates to specific fields
- Write-heavy workloads

## 🚀 Quick Start

### Basic Usage

```zig
const std = @import("std");
const Rcu = @import("rcu.zig").Rcu;

const Config = struct {
    port: u16,
    timeout_ms: u32,

    fn destroy(self: *Config, allocator: std.mem.Allocator) void {
        allocator.destroy(self);
    }
};

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    // Initialize with initial data
    const initial = try allocator.create(Config);
    initial.* = .{ .port = 8080, .timeout_ms = 5000 };

    const RcuConfig = Rcu(Config);
    const rcu = try RcuConfig.init(
        allocator,
        initial,
        Config.destroy,
        .{} // Default configuration
    );
    defer rcu.deinit();

    // --- READING (Lock-Free, Zero Allocation) ---
    {
        const guard = try rcu.read();
        defer guard.release();
        const config = guard.get();
        std.debug.print("Port: {}\n", .{config.port});
    }

    // --- WRITING (Async, Non-Blocking) ---
    const UpdateContext = struct {
        new_port: u16,
        fn updateFn(
            ctx: *anyopaque,
            alloc: std.mem.Allocator,
            current: ?*const Config
        ) !*Config {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            const new_config = try alloc.create(Config);
            new_config.* = current.?.*;
            new_config.port = self.new_port;
            return new_config;
        }
    };
    var ctx = UpdateContext{ .new_port = 9090 };
    try rcu.update(&ctx, UpdateContext.updateFn);
}
```

## 📖 API Reference

### Initialization

```zig
pub fn init(
    allocator: Allocator,
    initial_data: *T,
    destructor: DestructorFn,
    config: Config
) !*Self
```

Creates a new RCU instance.

**Parameters:**
- `allocator`: Memory allocator for internal structures
- `initial_data`: Initial version of your data
- `destructor`: Function to free your data type
- `config`: RCU configuration (see below)

### Configuration Options

```zig
pub const Config = struct {
    max_pending_mods: usize = 1024,
    reclaim_interval_ns: u64 = 50 * std.time.ns_per_ms,
    max_retired_per_epoch: usize = 512,
};
```

- `max_pending_mods`: Maximum queued updates before blocking writers
- `reclaim_interval_ns`: How often the reclaimer wakes up
- `max_retired_per_epoch`: Capacity of each retired object bag

### Reading

```zig
pub fn read(self: *const Self) !ReadGuard
```

Enters a read-side critical section. Returns a guard that **must** be released.

```zig
const guard = try rcu.read();
defer guard.release(); // Always use defer!
const data = guard.get(); // Access the data
```

**Performance:** ~2-3 atomic operations, no allocation, no locks.

### Writing

```zig
pub fn update(
    self: *Self,
    ctx: *anyopaque,
    updateFn: UpdateFn
) !void
```

Submits an update request. Returns immediately (non-blocking).

The update function must have this signature:

```zig
fn updateFn(
    ctx: *anyopaque,           // Your context
    allocator: Allocator,      // Use this to allocate
    current: ?*const T         // Current data (read-only)
) anyerror!*T                  // Return new version
```

**Example:**

```zig
const UpdateContext = struct {
    new_value: u32,
    
    fn updateFn(
        ctx: *anyopaque,
        alloc: Allocator,
        current: ?*const MyData
    ) !*MyData {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        const new_data = try alloc.create(MyData);
        new_data.* = current.?.*; // Copy current state
        new_data.value = self.new_value; // Apply changes
        return new_data;
    }
};

var ctx = UpdateContext{ .new_value = 42 };
try rcu.update(&ctx, UpdateContext.updateFn);
```

### Cleanup

```zig
pub fn deinit(self: *Self) void
```

Gracefully shuts down the RCU, waits for pending operations, and frees all resources.

## 🏗️ Architecture

### How It Works

RCU uses a three-epoch garbage collection scheme:

```
Epoch 0: Object retired (writers can still see it)
Epoch 1: Grace period (readers transitioning)
Epoch 2: Safe to free (no readers can see it)
```

```
Timeline:
─────────────────────────────────────────────────
Epoch:        100      101      102      103
              │        │        │        │
Writer:       ├─Retire Obj
              │
Readers:      ├──────┤ (Pin at epoch 100)
              │
Reclaimer:    │        ├─Advance
              │        │        ├─Advance
              │        │        │        ├─Free Obj!
```

### Components

1. **Shared Pointer**: Atomic pointer to current data version
2. **Modification Queue**: MPSC queue for pending updates
3. **Participant Registry**: Tracks all reader threads
4. **Retired Bags**: Three rotating bags for garbage collection
5. **Reclaimer Thread**: Background thread managing updates and reclamation

### Thread Safety

- **Readers**: Wait-free, multiple concurrent readers supported
- **Writers**: Lock-free queue push, serialized execution
- **Reclaimer**: Single background thread, no user interaction

## 🎭 Real-World Examples

### 1. Global Application Configuration

```zig
const AppConfig = struct {
    server_url: []const u8,
    port: u16,
    debug_mode: bool,
    // ... more fields
};

var config_rcu = try RcuConfig.init(...);

// Workers just read (fast!)
fn workerThread(rcu: *RcuConfig) void {
    const guard = rcu.read() catch return;
    defer guard.release();
    connectTo(guard.get().server_url, guard.get().port);
}

// Admin interface updates (rare)
fn hotReload(rcu: *RcuConfig, new_port: u16) !void {
    var ctx = UpdateContext{ .new_port = new_port };
    try rcu.update(&ctx, updateFn);
}
```

### 2. Feature Flags / A/B Testing

```zig
const FeatureFlags = std.StringHashMap(bool);
var flags_rcu = try RcuFlags.init(...);

// Every request checks flags (millions per second)
fn handleRequest(rcu: *RcuFlags) void {
    const guard = rcu.read() catch return;
    defer guard.release();
    if (guard.get().isEnabled("new_ui")) {
        // Show new UI
    }
}

// Admin toggles flags (rare)
fn toggleFlag(rcu: *RcuFlags, name: []const u8, enabled: bool) !void {
    var ctx = ToggleContext{ .name = name, .enabled = enabled };
    try rcu.update(&ctx, toggleFn);
}
```

### 3. Routing Table

```zig
const RoutingTable = struct {
    routes: std.ArrayList(Route),
};
var routing_rcu = try RcuTable.init(...);

// Every packet looks up route (very fast)
fn forwardPacket(rcu: *RcuTable, dest: IpAddr) void {
    const guard = rcu.read() catch return;
    defer guard.release();
    const route = guard.get().findRoute(dest);
    sendVia(route);
}

// Network admin updates routes (occasional)
fn addRoute(rcu: *RcuTable, route: Route) !void {
    var ctx = AddRouteContext{ .route = route };
    try rcu.update(&ctx, addRouteFn);
}
```

## 📈 Performance Characteristics

### Read Performance

| Operation | Cost |
|-----------|------|
| `read()` | 2-3 atomic loads + TLS lookup |
| `guard.get()` | 1 atomic load |
| `guard.release()` | 1 atomic store |

**Result:** ~5-10ns per read on modern hardware

### Write Performance

| Operation | Cost |
|-----------|------|
| `update()` (submit) | MPSC queue push (~50ns) |
| `update()` (apply) | Asynchronous, amortized |
| Memory reclamation | Asynchronous, 3 epochs later |

### Memory Overhead

- Per-thread: ~64 bytes (ParticipantState)
- Per-epoch: 3 × retired_bag capacity
- Fixed overhead: ~2KB (queues, state)

## 🧪 Testing

Run the test suite:

```bash
zig build test
```

Run examples:

```bash
zig build run-examples
```

## 🔒 Safety Guarantees

### What RCU Guarantees

✅ **No use-after-free**: Memory is never freed while readers exist
✅ **No data races**: Atomic operations ensure proper synchronization
✅ **No memory leaks**: Automatic reclamation on shutdown
✅ **Forward progress**: Readers never block

### What RCU Does NOT Guarantee

❌ **Immediate consistency**: Readers may see old versions briefly
❌ **Write ordering**: Multiple updates may be reordered
❌ **Fairness**: No guarantees on update processing order

## 🎯 Design Principles

1. **Reader Priority**: Reads must be as fast as possible
2. **Single Writer**: Serialize updates to eliminate contention
3. **Deferred Reclamation**: Never free memory prematurely
4. **Fail-Safe**: Errors must not compromise safety

## 🔧 Advanced Usage

### Custom Configuration for High Throughput

```zig
const rcu = try RcuConfig.init(allocator, initial, destructor, .{
    .max_pending_mods = 4096,  // More buffering
    .reclaim_interval_ns = 10 * std.time.ns_per_ms,  // Faster cleanup
    .max_retired_per_epoch = 1024,  // Larger bags
});
```

### Debug Diagnostics

In Debug builds, diagnostics are automatically tracked:

```zig
if (@import("builtin").mode == .Debug) {
    const diag = rcu.getDiagnostics();
    diag.print(); // Prints reads, updates, reclamations, epochs
}
```

Output:
```
RCU Diagnostics:
  Reads:          150000
  Updates:        1500
  Reclamations:   1450
  Epoch Advances: 500
```

## 📚 Further Reading

- [Original RCU Paper](https://www.rdrop.com/users/paulmck/RCU/)
- [Linux Kernel RCU](https://www.kernel.org/doc/Documentation/RCU/whatisRCU.txt)
- [userspace-rcu](https://liburcu.org/)

## 📜 License

MIT License - see LICENSE file for details

## 🤝 Contributing

Contributions welcome! Please:
1. Add tests for new features
2. Ensure all tests pass
3. Follow Zig style guidelines
4. Update documentation

## 🐛 Known Limitations

1. **Grace Period Detection**: Uses conservative 3-epoch scheme
2. **Thread Registration**: TLS lookup on first read per thread
3. **Update Ordering**: No guarantees on concurrent update ordering

## 📞 Support

- GitHub Issues: [Report bugs here]
- Discussions: [Ask questions here]

---

**Production Status:** Beta - Thoroughly tested but not yet battle-hardened in production. Use with appropriate testing and monitoring.

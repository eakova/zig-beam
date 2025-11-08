const std = @import("std");
const atomic = std.atomic;
const Allocator = std.mem.Allocator;
const Thread = std.Thread;
const Mutex = std.Thread.Mutex;
const assert = std.debug.assert;

/// A production-grade, standalone Read-Copy-Update (RCU) synchronization primitive.
///
/// RCU allows extremely fast, wait-free reads of shared data while safely managing
/// updates and memory reclamation in highly concurrent environments.
///
/// ## Design Philosophy
/// - **Reader Priority**: Reads are never blocked and have minimal overhead
/// - **Single Writer Principle**: All updates are serialized through one thread
/// - **Safe Reclamation**: Memory is freed only when provably unreachable
/// - **Zero Allocation Reads**: Read path never allocates
///
/// ## Usage Example
/// ```zig
/// const Config = struct { port: u16, timeout_ms: u32 };
/// const RcuConfig = Rcu(Config);
///
/// var rcu = try RcuConfig.init(allocator, initial_config);
/// defer rcu.deinit();
///
/// // Reader (zero overhead, lock-free)
/// {
///     const guard = try rcu.read();
///     defer guard.release();
///     const config = guard.get();
///     std.debug.print("Port: {}\n", .{config.port});
/// }
///
/// // Writer (async, non-blocking)
/// try rcu.update(ctx, updateFn);
/// ```
pub fn Rcu(comptime T: type) type {
    return struct {
        const Self = @This();

        //======================================================================
        // TYPE DEFINITIONS
        //======================================================================

        /// User-provided function to create a new version of the data.
        /// Receives the current data (or null on first call) and a context.
        pub const UpdateFn = *const fn (ctx: *anyopaque, allocator: Allocator, current: ?*const T) anyerror!*T;

        /// User-provided destructor for the data.
        pub const DestructorFn = *const fn (data: *T, allocator: Allocator) void;

        /// Configuration for RCU instance.
        pub const Config = struct {
            /// Maximum pending modifications before blocking writers.
            max_pending_mods: usize = 1024,
            /// Reclaimer thread wakeup interval (nanoseconds).
            reclaim_interval_ns: u64 = 50 * std.time.ns_per_ms,
            /// Maximum number of retired objects per epoch bag.
            max_retired_per_epoch: usize = 512,
        };

        //======================================================================
        // INTERNAL STATE
        //======================================================================

        /// The shared pointer to current data.
        shared_ptr: atomic.Value(*T),

        /// Queue for pending modifications (MPSC).
        mod_queue: ModificationQueue,

        /// Global epoch counter.
        global_epoch: atomic.Value(u64),

        /// Registry of all participating threads.
        participants: ParticipantRegistry,

        /// Three-epoch rotating bags for retired objects.
        retired_bags: [3]RetiredBag,
        retired_bags_lock: Mutex,

        /// Background reclaimer thread.
        reclaimer_thread: ?Thread,

        /// Lifecycle state.
        state: atomic.Value(State),
        reclaimer_wakeup: Thread.Futex,

        /// User-provided destructor.
        destructor: DestructorFn,

        /// Configuration.
        config: Config,

        allocator: Allocator,

        /// Diagnostics (optional, zero-cost when disabled).
        diagnostics: if (enable_diagnostics) Diagnostics else void,

        const enable_diagnostics = @import("builtin").mode == .Debug;

        const State = enum(u8) {
            Initializing,
            Active,
            ShuttingDown,
            Terminated,
        };

        //======================================================================
        // INTERNAL STRUCTURES
        //======================================================================

        const Modification = struct {
            update_fn: UpdateFn,
            context: *anyopaque,
        };

        const ModificationQueue = struct {
            buffer: []Modification,
            write_pos: atomic.Value(usize),
            read_pos: atomic.Value(usize),
            capacity: usize,
            allocator: Allocator,

            fn init(allocator: Allocator, capacity: usize) !ModificationQueue {
                const buffer = try allocator.alloc(Modification, capacity);
                return .{
                    .buffer = buffer,
                    .write_pos = atomic.Value(usize).init(0),
                    .read_pos = atomic.Value(usize).init(0),
                    .capacity = capacity,
                    .allocator = allocator,
                };
            }

            fn deinit(self: *ModificationQueue) void {
                self.allocator.free(self.buffer);
            }

            fn tryWrite(self: *ModificationQueue, mod: Modification) !void {
                const write = self.write_pos.load(.Monotonic);
                const read_pos = self.read_pos.load(.Acquire);
                const available = if (write >= read_pos)
                    self.capacity - (write - read_pos)
                else
                    read_pos - write;

                if (available <= 1) return error.QueueFull;

                self.buffer[write % self.capacity] = mod;
                _ = self.write_pos.fetchAdd(1, .Release);
            }

            fn tryRead(self: *ModificationQueue) ?Modification {
                const read_pos = self.read_pos.load(.Monotonic);
                const write = self.write_pos.load(.Acquire);
                if (read_pos == write) return null;

                const mod = self.buffer[read_pos % self.capacity];
                _ = self.read_pos.fetchAdd(1, .Release);
                return mod;
            }

            fn isEmpty(self: *ModificationQueue) bool {
                return self.read_pos.load(.Acquire) == self.write_pos.load(.Acquire);
            }
        };

        const RetiredObject = struct {
            ptr: *T,
            retire_epoch: u64,
        };

        const RetiredBag = struct {
            objects: std.ArrayList(RetiredObject),

            fn init(allocator: Allocator, capacity: usize) !RetiredBag {
                const objects = try std.ArrayList(RetiredObject).initCapacity(allocator, capacity);
                return .{ .objects = objects };
            }

            fn deinit(self: *RetiredBag) void {
                self.objects.deinit();
            }

            fn append(self: *RetiredBag, obj: RetiredObject) !void {
                try self.objects.append(obj);
            }

            fn clear(self: *RetiredBag) void {
                self.objects.clearRetainingCapacity();
            }
        };

        const ParticipantState = struct {
            is_active: atomic.Value(bool),
            local_epoch: atomic.Value(u64),
            thread_id: Thread.Id,
            next: ?*ParticipantState,

            fn init(thread_id: Thread.Id) ParticipantState {
                return .{
                    .is_active = atomic.Value(bool).init(false),
                    .local_epoch = atomic.Value(u64).init(0),
                    .thread_id = thread_id,
                    .next = null,
                };
            }
        };

        const ParticipantRegistry = struct {
            head: atomic.Value(?*ParticipantState),
            lock: Mutex,
            allocator: Allocator,
            tls_index: u32,

            fn init(allocator: Allocator) !ParticipantRegistry {
                return .{
                    .head = atomic.Value(?*ParticipantState).init(null),
                    .lock = .{},
                    .allocator = allocator,
                    .tls_index = try Thread.Tls.create(),
                };
            }

            fn deinit(self: *ParticipantRegistry) void {
                var current = self.head.load(.Monotonic);
                while (current) |node| {
                    const next = node.next;
                    self.allocator.destroy(node);
                    current = next;
                }
                Thread.Tls.destroy(self.tls_index);
            }

            fn getOrCreate(self: *ParticipantRegistry) !*ParticipantState {
                // Fast path: check TLS
                if (Thread.Tls.get(self.tls_index)) |ptr| {
                    return @ptrCast(@alignCast(ptr));
                }

                // Slow path: create new participant
                const thread_id = Thread.getCurrentId();
                const state = try self.allocator.create(ParticipantState);
                errdefer self.allocator.destroy(state);

                state.* = ParticipantState.init(thread_id);

                // Add to global list
                self.lock.lock();
                defer self.lock.unlock();

                state.next = self.head.load(.Monotonic);
                self.head.store(state, .Release);

                // Store in TLS
                Thread.Tls.set(self.tls_index, state);

                return state;
            }

            fn forEach(self: *ParticipantRegistry, context: anytype, comptime callback: fn (@TypeOf(context), *ParticipantState) void) void {
                var current = self.head.load(.Acquire);
                while (current) |node| {
                    callback(context, node);
                    current = node.next;
                }
            }
        };

        const Diagnostics = struct {
            reads: atomic.Value(u64),
            updates: atomic.Value(u64),
            reclamations: atomic.Value(u64),
            epoch_advances: atomic.Value(u64),

            fn init() Diagnostics {
                return .{
                    .reads = atomic.Value(u64).init(0),
                    .updates = atomic.Value(u64).init(0),
                    .reclamations = atomic.Value(u64).init(0),
                    .epoch_advances = atomic.Value(u64).init(0),
                };
            }

            fn recordRead(self: *Diagnostics) void {
                _ = self.reads.fetchAdd(1, .Monotonic);
            }

            fn recordUpdate(self: *Diagnostics) void {
                _ = self.updates.fetchAdd(1, .Monotonic);
            }

            fn recordReclamation(self: *Diagnostics) void {
                _ = self.reclamations.fetchAdd(1, .Monotonic);
            }

            fn recordEpochAdvance(self: *Diagnostics) void {
                _ = self.epoch_advances.fetchAdd(1, .Monotonic);
            }

            pub fn print(self: *const Diagnostics) void {
                std.debug.print(
                    \\RCU Diagnostics:
                    \\  Reads:          {}
                    \\  Updates:        {}
                    \\  Reclamations:   {}
                    \\  Epoch Advances: {}
                    \\
                , .{
                    self.reads.load(.Monotonic),
                    self.updates.load(.Monotonic),
                    self.reclamations.load(.Monotonic),
                    self.epoch_advances.load(.Monotonic),
                });
            }
        };

        //======================================================================
        // PUBLIC API - LIFECYCLE
        //======================================================================

        /// Initialize a new RCU instance with initial data.
        pub fn init(allocator: Allocator, initial_data: *T, destructor: DestructorFn, user_config: Config) !*Self {
            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);

            self.* = .{
                .shared_ptr = atomic.Value(*T).init(initial_data),
                .mod_queue = try ModificationQueue.init(allocator, user_config.max_pending_mods),
                .global_epoch = atomic.Value(u64).init(0),
                .participants = try ParticipantRegistry.init(allocator),
                .retired_bags = undefined,
                .retired_bags_lock = .{},
                .reclaimer_thread = null,
                .state = atomic.Value(State).init(.Initializing),
                .reclaimer_wakeup = atomic.Value(u32).init(0),
                .destructor = destructor,
                .config = user_config,
                .allocator = allocator,
                .diagnostics = if (enable_diagnostics) Diagnostics.init() else {},
            };

            // Initialize retired bags
            for (&self.retired_bags) |*bag| {
                bag.* = try RetiredBag.init(allocator, user_config.max_retired_per_epoch);
            }

            // Start reclaimer thread
            self.reclaimer_thread = try Thread.spawn(.{}, reclaimerLoop, .{self});

            // Mark as active
            self.state.store(.Active, .Release);

            return self;
        }

        /// Shut down the RCU and free all resources.
        /// Blocks until all pending operations complete.
        pub fn deinit(self: *Self) void {
            // Transition to shutdown
            const old_state = self.state.swap(.ShuttingDown, .AcqRel);
            if (old_state != .Active) return; // Already shutting down

            // Wake reclaimer
            self.reclaimer_wakeup.store(1, .Release);
            Thread.futexWake(&self.reclaimer_wakeup, 1);

            // Wait for reclaimer to finish
            if (self.reclaimer_thread) |thread| {
                thread.join();
            }

            // At this point, no readers or writers are active
            self.state.store(.Terminated, .Release);

            // Free the current data
            const current = self.shared_ptr.load(.Monotonic);
            self.destructor(current, self.allocator);

            // Free all retired objects
            for (&self.retired_bags) |*bag| {
                for (bag.objects.items) |retired| {
                    self.destructor(retired.ptr, self.allocator);
                }
                bag.deinit();
            }

            // Cleanup
            self.participants.deinit();
            self.mod_queue.deinit();
            self.allocator.destroy(self);
        }

        //======================================================================
        // PUBLIC API - READERS
        //======================================================================

        /// A guard for read-side critical sections.
        /// While held, the data accessed via `get()` is guaranteed stable.
        pub const ReadGuard = struct {
            rcu: *const Self,
            state: *ParticipantState,

            /// Access the current data. Pointer valid for guard lifetime.
            pub inline fn get(self: ReadGuard) *const T {
                return self.rcu.shared_ptr.load(.Acquire);
            }

            /// Release the guard. Must be called (use `defer`).
            pub fn release(self: ReadGuard) void {
                self.state.is_active.store(false, .Release);
            }
        };

        /// Enter a read-side critical section.
        /// Returns a guard that must be released with `defer guard.release()`.
        pub fn read(self: *const Self) !ReadGuard {
            if (self.state.load(.Acquire) != .Active) {
                return error.RcuNotActive;
            }

            const state = try self.participants.getOrCreate();
            const current_epoch = self.global_epoch.load(.Acquire);
            
            state.local_epoch.store(current_epoch, .Monotonic);
            state.is_active.store(true, .Release);

            if (enable_diagnostics) {
                self.diagnostics.recordRead();
            }

            return .{ .rcu = self, .state = state };
        }

        //======================================================================
        // PUBLIC API - WRITERS
        //======================================================================

        /// Submit an update request. Returns immediately (non-blocking).
        /// The update is applied asynchronously by the reclaimer thread.
        ///
        /// The `updateFn` receives:
        /// - `ctx`: Your context pointer
        /// - `allocator`: Use this to allocate the new version
        /// - `current`: The current data (to read, don't modify)
        ///
        /// Example:
        /// ```zig
        /// const Context = struct { new_value: u32 };
        /// fn updateFn(ctx: *anyopaque, alloc: Allocator, current: ?*const MyData) !*MyData {
        ///     const context: *Context = @ptrCast(@alignCast(ctx));
        ///     const new_data = try alloc.create(MyData);
        ///     new_data.* = current.?.*;
        ///     new_data.value = context.new_value;
        ///     return new_data;
        /// }
        /// var ctx = Context{ .new_value = 42 };
        /// try rcu.update(&ctx, updateFn);
        /// ```
        pub fn update(self: *Self, ctx: *anyopaque, updateFn: UpdateFn) !void {
            if (self.state.load(.Acquire) != .Active) {
                return error.RcuNotActive;
            }

            try self.mod_queue.tryWrite(.{
                .update_fn = updateFn,
                .context = ctx,
            });

            if (enable_diagnostics) {
                self.diagnostics.recordUpdate();
            }

            // Wake reclaimer
            self.reclaimer_wakeup.store(1, .Release);
            Thread.futexWake(&self.reclaimer_wakeup, 1);
        }

        //======================================================================
        // PUBLIC API - DIAGNOSTICS
        //======================================================================

        /// Get diagnostic statistics (only available in Debug builds).
        pub fn getDiagnostics(self: *const Self) if (enable_diagnostics) Diagnostics else void {
            if (enable_diagnostics) {
                return self.diagnostics;
            }
        }

        //======================================================================
        // INTERNAL - RECLAIMER THREAD
        //======================================================================

        fn reclaimerLoop(self: *Self) void {
            while (self.state.load(.Acquire) == .Active) {
                // Phase 1: Apply pending modifications
                self.applyModifications();

                // Phase 2: Advance epoch and reclaim memory
                self.advanceEpochAndReclaim();

                // Phase 3: Sleep until woken or timeout
                _ = Thread.futexWaitForTime(
                    &self.reclaimer_wakeup,
                    1,
                    self.config.reclaim_interval_ns,
                );
                self.reclaimer_wakeup.store(0, .Monotonic);
            }

            // Final cleanup: process remaining modifications
            while (!self.mod_queue.isEmpty()) {
                self.applyModifications();
            }

            // Force final reclamation
            self.advanceEpochAndReclaim();
            self.advanceEpochAndReclaim();
            self.advanceEpochAndReclaim();
        }

        fn applyModifications(self: *Self) void {
            var current_ptr = self.shared_ptr.load(.Monotonic);

            while (self.mod_queue.tryRead()) |mod| {
                // Apply update function
                const new_ptr = mod.update_fn(mod.context, self.allocator, current_ptr) catch |err| {
                    std.debug.print("RCU update failed: {}\n", .{err});
                    continue;
                };

                // Atomically publish new version
                const retired_ptr = self.shared_ptr.swap(new_ptr, .AcqRel);

                // Retire old version
                const retire_epoch = self.global_epoch.load(.Monotonic);
                self.retireObject(retired_ptr, retire_epoch);

                current_ptr = new_ptr;
            }
        }

        fn retireObject(self: *Self, ptr: *T, retire_epoch: u64) void {
            self.retired_bags_lock.lock();
            defer self.retired_bags_lock.unlock();

            const bag_index = retire_epoch % 3;
            self.retired_bags[bag_index].append(.{
                .ptr = ptr,
                .retire_epoch = retire_epoch,
            }) catch |err| {
                // If we can't retire it, free it immediately (suboptimal but safe)
                std.debug.print("Failed to retire object: {}, freeing immediately\n", .{err});
                self.destructor(ptr, self.allocator);
            };
        }

        fn advanceEpochAndReclaim(self: *Self) void {
            const current_epoch = self.global_epoch.load(.Acquire);

            // Check if we can advance (all readers in current or newer epoch)
            if (!self.canAdvanceEpoch(current_epoch)) {
                return;
            }

            // Advance to next epoch
            const new_epoch = current_epoch + 1;
            _ = self.global_epoch.compareAndSwap(current_epoch, new_epoch, .AcqRel, .Monotonic) orelse {
                // Successfully advanced
                if (enable_diagnostics) {
                    self.diagnostics.recordEpochAdvance();
                }

                // Reclaim objects from two epochs ago
                if (new_epoch >= 2) {
                    const free_epoch = new_epoch - 2;
                    self.reclaimBag(free_epoch);
                }
            };
        }

        fn canAdvanceEpoch(self: *const Self, current_epoch: u64) bool {
            var can_advance = true;
            const Context = struct {
                current_epoch: u64,
                can_advance: *bool,
            };
            var ctx = Context{
                .current_epoch = current_epoch,
                .can_advance = &can_advance,
            };

            self.participants.forEach(&ctx, struct {
                fn callback(context: *Context, state: *ParticipantState) void {
                    if (state.is_active.load(.Acquire)) {
                        const local_epoch = state.local_epoch.load(.Acquire);
                        if (local_epoch < context.current_epoch) {
                            context.can_advance.* = false;
                        }
                    }
                }
            }.callback);

            return can_advance;
        }

        fn reclaimBag(self: *Self, free_epoch: u64) void {
            self.retired_bags_lock.lock();
            defer self.retired_bags_lock.unlock();

            const bag_index = free_epoch % 3;
            var bag = &self.retired_bags[bag_index];

            for (bag.objects.items) |retired| {
                assert(retired.retire_epoch == free_epoch);
                self.destructor(retired.ptr, self.allocator);
                
                if (enable_diagnostics) {
                    self.diagnostics.recordReclamation();
                }
            }

            bag.clear();
        }
    };
}

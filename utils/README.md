## Utils Library Overview

This directory hosts standalone Zig modules that can be consumed individually or
all at once via `src/root.zig`. Each submodule ships with its own targeted test
suites and (where relevant) micro-benchmarks. Run the commands below from
`utils/`.

## Tagged Pointer
Compact helper that stores a pointer and a 1-bit tag inside a single machine
word; used to power Small Value Optimization (SVO) in ARC.

```bash
zig test src/tagged-pointer/_tagged_pointer_unit_tests.zig
zig test src/tagged-pointer/_tagged_pointer_integration_tests.zig
zig test src/tagged-pointer/_tagged_pointer_samples.zig
zig build test-tagged
zig build samples-tagged
```

## Thread-Local Cache
Lock-free, per-thread cache layer that frontloads expensive pool operations and
keeps allocation churn off the global allocator.

```bash
zig test src/thread-local-cache/_thread_local_cache_unit_tests.zig
zig test src/thread-local-cache/_thread_local_cache_integration_test.zig
zig test src/thread-local-cache/_thread_local_cache_fuzz_tests.zig
zig test src/thread-local-cache/_thread_local_cache_samples.zig
zig build test-tlc
zig build samples-tlc
zig build bench-tlc   # runs _thread_local_cache_benchmarks.zig and updates docs
```

## ARC Core
Atomic reference-counted smart pointer (`Arc<T>`) plus optional weak handles and
SVO support for tiny POD values.

```bash
zig test src/arc/_arc_unit_tests.zig
zig test src/arc/_arc_integration_tests.zig
zig test src/arc/_arc_fuzz_tests.zig
zig test src/arc/_arc_samples.zig
zig build test-arc
zig build samples-arc
zig build bench-arc                  # single-threaded benchmarks + report
ARC_BENCH_RUN_MT=1 zig build bench-arc  # also enables multi-thread benchmark
```

## ARC Pool
Multi-layer allocator (TLS cache + Treiber stack + allocator fallback) that
recycles `Arc.Inner` blocks for heap-backed payloads.

```bash
zig test src/arc/arc-pool/_arc_pool_unit_tests.zig
zig test src/arc/arc-pool/_arc_pool_integration_tests.zig
zig build test-arc-pool
```

## ARC Cycle Detector
Debug-only tracing utility to surface reference cycles in complex Arc graphs.

```bash
zig test src/arc/cycle-detector/_arc_cycle_detector_unit_tests.zig
zig test src/arc/cycle-detector/_arc_cycle_detector_integration_tests.zig
zig build test-arc-cycle
```

## Full Suite
```bash
zig build test
```

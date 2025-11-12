# ThreadLocalCache Benchmark Results

## Legend
- iters/attempts/cycles: amount of work per measured run (scaled to target duration).
- repeats: number of measured runs; latency and throughput report median (IQR) across repeats.
- ns/op (or ns/item): latency per operation/item; lower is better.
- ops/s (or items/s): throughput; higher is better.
- Notes: very fast paths may report ~0ns due to timer granularity in ReleaseFast.

## Config
- repeats: 2
- target_ms (ST/MT): 100/150
- threads (MT): 4

## Machine
- OS: macos
- Arch: aarch64
- Zig: 0.15.2
- Build Mode: ReleaseFast
- Pointer Width: 64-bit
- Logical CPUs: 0

## push_pop_hits
- iters: 28,232,000
- repeats: 2
- ns/op median (IQR): 2 (2–2)
- pairs/s median: 442,761,403 (≈ 442 M/s)
- single-op ops/s median: 885,522,806 (≈ 885 M/s)

## pop_empty
- attempts: 50,000,000
- repeats: 2
- ns/attempt median (IQR): 0 (0–0)
- attempts/s median: 595,238,095,238,095 (≈ 595,238 M/s)

## push_overflow(full)
- attempts: 50,000,000
- repeats: 2
- ns/attempt median (IQR): 0 (0–0)
- attempts/s median: 0 (≈ 0 M/s)

## clear_no_callback
- cycles: 50,000,000 (items/cycle: 8)
- repeats: 2
- ns/item median (IQR): 0 (0–0)
- items/s median: 4,878,048,780,487,804 (≈ 4,878,048 M/s)

## clear_with_callback
- cycles: 50,000,000 (items/cycle: 8)
- repeats: 2
- ns/item median (IQR): 0 (0–0)
- items/s median: 4,761,904,761,904,761 (≈ 4,761,904 M/s)

## Callback Toggle (Single-Threaded)
| Variant | Items | ns/item (median) | items/s (median) |
| --- | --- | --- | --- |
| clear(no-callback) | 400,000,000 | <1 | 9,523,809,523,809,523 |
| clear(callback) | 400,000,000 | <1 | 7,287,687,334,704,671 |

## mt_push_pop_hits
- threads: 4
- iters/thread: 50,000,000
- repeats: 2
- ns/iter median (IQR): 0 (0–0)
- pairs/s median: 2,142,696,303 (≈ 2 M/s)
- per-thread pairs/s median: 535 M/s
- per-thread single-op ops/s median: 1 M/s

## mt_fill_and_clear(shared_cb)
- threads: 4
- cycles/thread: 336,090
- repeats: 2
- ns/item median (IQR): 14 (14–14)
- items/s median: 68,060,828 (≈ 68 M/s)
- per-thread items/s median: 17 M/s

### Callback Toggle (Multi-Threaded)
| Variant | Items | ns/item (median) | items/s (median) |
| --- | --- | --- | --- |
| clear(callback) | 10,754,880 | 13 | 71,290,884 |
| clear(no-callback) | 10,754,880 | <1 | 1,718,972,586 |


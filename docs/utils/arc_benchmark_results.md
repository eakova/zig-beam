# ARC Benchmark Results

## Legend
- Iterations: number of clone+release pairs per measured run.
- ns/op: latency per pair (lower is better).
- ops/s: pairs per second (higher is better).

## Config
- iterations: 50000000
- threads (MT): 4

## Machine
- OS: macos
- Arch: aarch64
- Zig: 0.15.2
- Build Mode: ReleaseFast
- Pointer Width: 64-bit
- Logical CPUs: 0

## Arc — Single-Threaded
- Iterations: 50,000,000
- Latency (ns/op) median (IQR): 0 (0–0)
- Throughput: 0 (≈ 0 /s)

## Arc — SVO vs Heap Clone Throughput
| Variant | Iterations | ns/op (median) | Throughput (ops/s) |
| --- | --- | --- | --- |
| SVO (u32) | 50,000,000 | <0.01 | 1,190,476.19 G/s |
| Heap ([64]u8) | 9,049,215 | 4.51 | 225.50 M/s |

## Arc — Downgrade + Upgrade
| Operation | Iterations | ns/op (median) | Throughput (ops/s) |
| --- | --- | --- | --- |
| downgrade+upgrade | 7,206,481 | 7.16 | 139.68 M/s |

## ArcPool — Heap vs Create/Recycle (stats=on)
| Scenario | Iterations | ns/op (median) | Throughput (ops/s) |
| --- | --- | --- | --- |
| direct heap | 16,497 | 3869.41 | 258.57 K/s |
| ArcPool recycle | 14,437,515 | 2.95 | 338.80 M/s |

## ArcPool — Stats Toggle
### Single-Threaded
| Variant | Iterations | ns/op (median) | Throughput (ops/s) |
| --- | --- | --- | --- |
| stats=on | 12,435,234 | 3.11 | 321.55 M/s |
| stats=off | 14,787,431 | 2.95 | 338.92 M/s |

## ArcPool — Cyclic Init (pool.createCyclic, stats=off)
| Operation | Iterations | ns/op (median) | Throughput (ops/s) |
| --- | --- | --- | --- |
| createCyclic(Node) | 11,755,026 | 4.19 | 238.53 M/s |

## ArcPool — In-place vs Copy (stats=off, ST)
| Variant | Iterations | ns/op (median) | Throughput (ops/s) |
| --- | --- | --- | --- |
| copy 64B | 15,761,849 | 3.11 | 322.43 M/s |
| in-place (memset) | 22,092,613 | 2.92 | 342.14 M/s |

## ArcPool — In-place vs Copy (stats=off, MT)
| Variant | Iterations | ns/op (median) | Throughput (ops/s) |
| --- | --- | --- | --- |
| copy 64B (MT) | 78,128,180 | 1.00 | 1.00 G/s |
| in-place (MT) | 74,538,792 | 0.76 | 1.31 G/s |

## ArcPool — TLS Capacity (stats=off) — TLS-heavy churn
| Capacity | Iterations | ns/op (median) | Throughput (ops/s) |
| --- | --- | --- | --- |
| 8 | 14,249,007 | 2.97 | 337.05 M/s |
| 16 | 22,655,873 | 2.93 | 341.03 M/s |
| 32 | 22,648,689 | 2.67 | 374.50 M/s |
| 64 | 22,669,911 | 3.44 | 291.18 M/s |

## ArcPool — TLS Capacity (stats=off) — Bursty cycles (burst=24)
| Capacity | Items | ns/item (median) | Throughput (items/s) |
| --- | --- | --- | --- |
| 8 | 588,432 | 99.55 | 10.04 M/s |
| 16 | 616,512 | 106.06 | 9.47 M/s |
| 32 | 541,608 | 101.99 | 9.81 M/s |
| 64 | 596,904 | 101.49 | 9.85 M/s |

## ArcPool — TLS Capacity (stats=off) — Bursty cycles (burst=72, no drain)
| Capacity | Items | ns/item (median) | Throughput (items/s) |
| --- | --- | --- | --- |
| 8 | 1,373,328 | 38.36 | 26.09 M/s |
| 16 | 1,510,416 | 38.13 | 26.23 M/s |
| 32 | 1,538,928 | 38.35 | 26.08 M/s |
| 64 | 1,566,144 | 37.50 | 26.67 M/s |

## ArcPool — Heap vs Create/Recycle (stats=off)
| Scenario | Iterations | ns/op (median) | Throughput (ops/s) |
| --- | --- | --- | --- |
| direct heap | 16,867 | 3409.01 | 293.35 K/s |
| ArcPool recycle | 15,560,812 | 2.92 | 342.19 M/s |

## ArcPool Split Scenarios (TLS / Global / Allocator)
| Scenario | Iterations | ns/op (median) | Throughput (ops/s) |
| --- | --- | --- | --- |
| TLS only | 13,136,289 | 3.06 | 326.92 M/s |
| Global only | 10,992,233 | 4.71 | 212.15 M/s |
| Allocator only | 2,826,856 | 12.65 | 79.03 M/s |


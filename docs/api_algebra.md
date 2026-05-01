# `mjolnir/algebra` — API Reference

Layer 1. Tiny module with bit / arithmetic helpers used across the engine.

| Proc | Signature | Purpose |
|---|---|---|
| `next_pow2` | `proc(v: u32) -> u32` | Smallest power-of-2 ≥ v. |
| `ilog2` | `proc(v: u32) -> u32` | Integer log₂ via bit manipulation. |
| `log2_greater_than` | `proc(x: u32) -> u32` | `floor(log₂(x)) + 1` via float. |
| `align` | `proc(value, alignment: int) -> int` | Round up to alignment boundary. |
| `next` | `proc(i, n: $T) -> T` | Circular `(i + 1) % n`. |
| `prev` | `proc(i, n: $T) -> T` | Circular `(i + n - 1) % n`.. |

All procs are pure, branchless where useful, and safe to call from any thread.

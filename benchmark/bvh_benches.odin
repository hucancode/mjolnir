package benchmark

import "../mjolnir/geometry"
import "core:fmt"
import "core:time"

@(private)
PrimEntry :: struct {
  bounds: geometry.Aabb,
  id:     u32,
}

@(private)
prim_lcg_next :: proc(state: ^u32) -> f32 {
  state^ = state^ * 1664525 + 1013904223
  // map to [-50, 50]
  return f32(state^) / f32(max(u32)) * 100.0 - 50.0
}

bench_bvh_build :: proc(b: ^Bench) {
  for n in ([]int{256, 1024, 4096}) {
    state: u32 = 0xdeadbeef
    entries := make([]PrimEntry, n, context.temp_allocator)
    for i in 0 ..< n {
      cx := prim_lcg_next(&state)
      cy := prim_lcg_next(&state)
      cz := prim_lcg_next(&state)
      r := (prim_lcg_next(&state) + 50) / 100.0 * 1.5 + 0.5
      entries[i] = PrimEntry {
        bounds = {min = {cx - r, cy - r, cz - r}, max = {cx + r, cy + r, cz + r}},
        id = u32(i),
      }
    }
    iters := 5
    samples := make([]f64, iters, context.temp_allocator)
    for it in 0 ..< iters {
      bvh: geometry.BVH(PrimEntry)
      bvh.bounds_func = proc(p: PrimEntry) -> geometry.Aabb {return p.bounds}
      defer geometry.bvh_destroy(&bvh)
      t := time.tick_now()
      geometry.bvh_build(&bvh, entries, 4)
      samples[it] = f64(time.tick_since(t)) / f64(time.Millisecond)
    }
    summarize(b, fmt.tprintf("bvh/build_%d", n), "ms", samples)
  }
}

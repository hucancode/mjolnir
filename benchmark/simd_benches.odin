package benchmark

import "../mjolnir/geometry"
import "core:fmt"
import "core:math/linalg"
import "core:time"

bench_simd_obb_to_aabb :: proc(b: ^Bench) {
  obbs: [4]geometry.Obb
  for i in 0 ..< 4 {
    obbs[i] = geometry.Obb {
      center       = {f32(i), 0, 0},
      half_extents = {1, 2, 3},
      rotation     = linalg.quaternion_angle_axis_f32(f32(i) * 0.1, {0, 1, 0}),
    }
  }
  N :: 1_000_000
  iters := 10
  per_iter_ms := make([]f64, iters, context.temp_allocator)
  for it in 0 ..< iters {
    t := time.tick_now()
    aabbs: [4]geometry.Aabb
    for _ in 0 ..< N {
      geometry.obb_to_aabb_batch4(obbs, &aabbs)
    }
    per_iter_ms[it] = f64(time.tick_since(t)) / f64(time.Millisecond)
    if aabbs[0].min.x == 9999.0 do fmt.println("noop")
  }
  summarize(b, "simd/obb_to_aabb_batch4/1M", "ms", per_iter_ms)
  ops := f64(N) * 4
  emit(
    b,
    "simd/obb_to_aabb_batch4/throughput",
    "M_ops_per_s",
    ops / 1e3 / per_iter_ms[len(per_iter_ms) / 2],
    "4 OBBs per call",
  )
}

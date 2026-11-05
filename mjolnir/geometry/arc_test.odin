#+build !js
#+private
package geometry

import "base:runtime"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:testing"
import "core:time"

@(private = "file")
near :: proc(a, b: [3]f32, eps: f32 = 1e-5) -> bool {
  return linalg.length(a - b) < eps
}

// An open arc passes through point k at k / (n - 1), curves between them, and runs on along its
// ends' tangents past them.
@(test)
test_arc_open :: proc(t: ^testing.T) {
  pts := [][3]f32{{0, 0, 0}, {0, 1, 1}, {1, 2, 1}, {2, 2, 0}}
  arc := Arc([3]f32){points = pts}
  for p, k in pts do testing.expectf(t, near(arc_sample(arc, f32(k) / 3), p), "point %d at %d/3: %v", k, k, arc_sample(arc, f32(k) / 3))
  testing.expectf(t, near(arc_sample(arc, 1.1), {2, 2, 0} + 0.3 * ({2, 2, 0} - {1, 2, 1}), 1e-4), "past its end, on along it: %v", arc_sample(arc, 1.1))
  testing.expectf(t, near(arc_sample(arc, -0.1), {0, 0, 0} - 0.3 * ({0, 1, 1} - {0, 0, 0}), 1e-4), "before its start, back along it: %v", arc_sample(arc, -0.1))
  mid := arc_sample(arc, 0.5)
  testing.expectf(t, linalg.length(mid - ({0, 1, 1} + {1, 2, 1}) / 2) > 0.01, "between points it curves, not a straight line: %v", mid)
}

// Between two corners an arc runs straight, at a steady speed.
@(test)
test_arc_corners :: proc(t: ^testing.T) {
  pts := [][3]f32{{0, 0, 0}, {0, 1, 1}, {1, 2, 1}, {2, 2, 0}}
  arc := Arc([3]f32){points = pts, sharp = []bool{false, true, true, false}}
  for s in ([]f32{0.4, 0.5, 0.6}) {
    want := linalg.lerp([3]f32{0, 1, 1}, [3]f32{1, 2, 1}, s * 3 - 1)
    testing.expectf(t, near(arc_sample(arc, s), want), "between corners at %v, straight and steady: %v, want %v", s, arc_sample(arc, s), want)
  }
}

// A closed arc runs on from its last point back to its first, point k at k / n, smooth through its
// seam unless it is a corner, and round again past its end.
@(test)
test_arc_closed :: proc(t: ^testing.T) {
  loop := [][3]f32{{0, 0, 0}, {1, 0, 0}, {1, 1, 0}, {0, 1, 0}}
  arc := Arc([3]f32){points = loop, closed = true}
  for p, k in loop do testing.expectf(t, near(arc_sample(arc, f32(k) / 4), p), "point %d at %d/4", k, k)
  testing.expect(t, near(arc_sample(arc, 1), loop[0]), "back at its first point at 1")
  testing.expect(t, near(arc_sample(arc, 1.25), loop[1]), "round again past 1")
  testing.expect(t, near(arc_sample(arc, -0.25), loop[3]), "round again before 0")
  e: f32 = 1e-3
  into, leave := (loop[0] - arc_sample(arc, 1 - e)) / e, (arc_sample(arc, e) - loop[0]) / e
  testing.expectf(t, linalg.length(into - leave) < 0.05 * linalg.length(leave), "smooth through the seam: in %v, out %v", into, leave)
  arc.sharp = []bool{true, false, false, false}
  into, leave = (loop[0] - arc_sample(arc, 1 - e)) / e, (arc_sample(arc, e) - loop[0]) / e
  testing.expectf(t, linalg.dot(linalg.normalize(into), linalg.normalize(leave)) < 0.1, "a corner at the seam turns hard: in %v, out %v", into, leave)
}

// Knots put each point where they say along the arc, however unevenly; adding a point between two
// leaves every other where it was.
@(test)
test_arc_knots :: proc(t: ^testing.T) {
  pts := [][3]f32{{0, 0, 0}, {1, 0, 0}, {1, 1, 0}}
  testing.expect(t, near(arc_sample(Arc([3]f32){points = pts}, 0.5), pts[1]), "evenly spread without knots")
  arc := Arc([3]f32){points = pts, knots = []f32{0, 0.2, 1}}
  for p, k in pts do testing.expectf(t, near(arc_sample(arc, arc.knots[k]), p), "point %d at its knot %v", k, arc.knots[k])
  more := Arc([3]f32){points = [][3]f32{{0, 0, 0}, {1, 0, 0}, {1.2, 0.5, 0}, {1, 1, 0}}, knots = []f32{0, 0.2, 0.6, 1}}
  for k in ([]int{0, 1, 3}) do testing.expectf(t, near(arc_sample(more, more.knots[k]), more.points[k]), "point %d where it was", k)
  testing.expect(t, near(arc_sample(more, 0.6), more.points[2]), "the new point at its own knot")
  loop := Arc([3]f32){points = [][3]f32{{0, 0, 0}, {1, 0, 0}, {1, 1, 0}, {0, 1, 0}}, knots = []f32{0, 0.1, 0.5, 0.6}, closed = true}
  for p, k in loop.points do testing.expectf(t, near(arc_sample(loop, loop.knots[k]), p), "closed: point %d at its knot", k)
  testing.expect(t, near(arc_sample(loop, 1), loop.points[0]), "closed: back to the first a pass on")
  // knots time the path, not its shape: the curve between two points is the same whatever they say
  even, uneven := Arc([3]f32){points = pts}, Arc([3]f32){points = pts, knots = []f32{0, 0.2, 1}}
  testing.expect(t, near(arc_sample(even, 0.25), arc_sample(uneven, 0.1)), "halfway along the first segment either way")
}

@(test)
test_arc_scalar :: proc(t: ^testing.T) {
  arc := Arc(f32){points = []f32{0, 10, 5, 15}}
  for v, k in arc.points do testing.expect_value(t, arc_sample(arc, f32(k) / 3), v)
  mid := arc_sample(arc, 1.0 / 6)
  testing.expect(t, mid > 0 && mid < 10, "between its points")
  prev := arc_sample(arc, 0)
  for i in 1 ..= 20 {
    cur := arc_sample(arc, f32(i) / 20)
    testing.expect(t, abs(cur - prev) < 5, "no jumps")
    prev = cur
  }
}

@(test)
test_arc_degenerate :: proc(t: ^testing.T) {
  testing.expect_value(t, arc_sample(Arc(f32){}, 0.5), 0)
  one := Arc(f32){points = []f32{42}}
  for s in ([]f32{-1, 0, 2}) do testing.expect_value(t, arc_sample(one, s), 42)
}

@(test)
test_arc_init_and_length :: proc(t: ^testing.T) {
  a: Arc([3]f32)
  testing.expect(t, !arc_init(&a, [][3]f32{{0, 0, 0}}), "one point rejected")
  testing.expect(t, !arc_init(&a, [][3]f32{{0, 0, 0}, {1, 0, 0}}, knots = []f32{0}), "knots not one per point rejected")
  testing.expect(t, !arc_init(&a, [][3]f32{{0, 0, 0}, {1, 0, 0}}, knots = []f32{1, 0}), "falling knots rejected")
  testing.expect(t, !arc_init(&a, [][3]f32{{0, 0, 0}, {1, 0, 0}}, sharp = []bool{true}), "corners not one per point rejected")
  testing.expect(t, arc_init(&a, [][3]f32{{0, 0, 0}, {3, 0, 0}}), "valid arc accepted")
  testing.expectf(t, abs(arc_length(a) - 3) < 1e-3, "length %f", arc_length(a))
  testing.expect(t, near(arc_sample_uniform(a, 1.5), {1.5, 0, 0}, 1e-3), "halfway along")
  arc_destroy(&a)
  // a closed square: its length is once round (the table's samples cut its corners a little)
  testing.expect(t, arc_init(&a, [][3]f32{{0, 0, 0}, {1, 0, 0}, {1, 1, 0}, {0, 1, 0}}, sharp = []bool{true, true, true, true}, closed = true))
  defer arc_destroy(&a)
  testing.expectf(t, abs(arc_length(a) - 4) < 0.02, "once round: %f", arc_length(a))
  testing.expect(t, near(arc_sample_uniform(a, 2.5), {0.5, 1, 0}, 0.02), "halfway along the third side")
}

@(test)
bench_arc_sample :: proc(t: ^testing.T) {
  State :: struct {
    arc: Arc([3]f32),
  }
  state: State
  opts := time.Benchmark_Options {
    rounds = 100_000,
    setup = proc(opts: ^time.Benchmark_Options, _: runtime.Allocator) -> time.Benchmark_Error {
      s := cast(^State)opts.user_data
      N :: 32
      points: [N][3]f32
      for &p, i in points {
        x := f32(i) / (N - 1)
        p = {math.cos(x * 6), x, math.sin(x * 6)}
      }
      arc_init(&s.arc, points[:], samples = 2)
      return .Okay
    },
    bench = proc(opts: ^time.Benchmark_Options, _: runtime.Allocator) -> time.Benchmark_Error {
      s := cast(^State)opts.user_data
      sum: [3]f32
      for k in 0 ..< opts.rounds do sum += arc_sample(s.arc, f32(k) / f32(opts.rounds))
      opts.count = opts.rounds
      if sum.x > 1e30 do opts.processed = 0
      return .Okay
    },
    teardown = proc(opts: ^time.Benchmark_Options, _: runtime.Allocator) -> time.Benchmark_Error {
      arc_destroy(&(cast(^State)opts.user_data).arc)
      return .Okay
    },
    user_data = &state,
  }
  err := time.benchmark(&opts)
  testing.expect(t, err == .Okay, "bench failed")
  log.infof("arc_sample N=32 points, %d rounds in %v, %.0f rounds/sec", opts.rounds, opts.duration, opts.rounds_per_second)
}

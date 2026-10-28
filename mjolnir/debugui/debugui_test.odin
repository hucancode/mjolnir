#+build !js
#+private file
package debugui

import "../anchor"
import "core:testing"
import mu "vendor:microui"

// tick runs one microui frame in a window of size `window`, with a window declared in `reference`, and returns where microui put it.
tick :: proc(self: ^Context, reference, window: [2]f32, rect: mu.Rect, pin: anchor.Anchor) -> mu.Rect {
  self.reference = reference
  self.size = window
  mu.begin(&self.mu)
  declare(self, rect, pin)
  mu.end(&self.mu)
  return mu.get_container(&self.mu, "W").rect
}

declare :: proc(self: ^Context, rect: mu.Rect, pin: anchor.Anchor) {
  if window(self, "W", rect, pin) {}
}

setup :: proc(self: ^Context) {
  mu.init(&self.mu)
  self.mu.text_width = mu.default_atlas_text_width
  self.mu.text_height = mu.default_atlas_text_height
}

@(test)
test_window_keeps_to_its_edges_in_a_taller_window :: proc(t: ^testing.T) {
  ctx := new(Context)
  defer free(ctx)
  setup(ctx)
  defer shutdown(ctx)
  // 800x600 designed, shown in 1000x1000: nothing scales, the extra space is 200x400
  design := [2]f32{800, 600}
  shown := [2]f32{1000, 1000}
  testing.expect_value(t, tick(ctx, design, shown, {700, 20, 80, 50}, {.RIGHT, .TOP}), mu.Rect{900, 20, 80, 50})
  testing.expect_value(t, tick(ctx, design, shown, {700, 20, 80, 50}, {.RIGHT, .TOP}), mu.Rect{900, 20, 80, 50})
}

@(test)
test_window_follows_a_resized_window :: proc(t: ^testing.T) {
  ctx := new(Context)
  defer free(ctx)
  setup(ctx)
  defer shutdown(ctx)
  design := [2]f32{800, 600}
  testing.expect_value(t, tick(ctx, design, {800, 600}, {700, 520, 80, 60}, {.RIGHT, .BOTTOM}), mu.Rect{700, 520, 80, 60})
  // a wider window of the same height
  testing.expect_value(t, tick(ctx, design, {1600, 600}, {700, 520, 80, 60}, {.RIGHT, .BOTTOM}), mu.Rect{1500, 520, 80, 60})
  // 1000x1000: no scaling, both edges follow by the extra 200x400
  testing.expect_value(t, tick(ctx, design, {1000, 1000}, {700, 520, 80, 60}, {.RIGHT, .BOTTOM}), mu.Rect{900, 920, 80, 60})
}

@(test)
test_unpinned_window_stays_top_left :: proc(t: ^testing.T) {
  ctx := new(Context)
  defer free(ctx)
  setup(ctx)
  defer shutdown(ctx)
  design := [2]f32{800, 600}
  testing.expect_value(t, tick(ctx, design, {1000, 1000}, {20, 20, 100, 100}, {}), mu.Rect{20, 20, 100, 100})
  testing.expect_value(t, tick(ctx, design, {2000, 1200}, {20, 20, 100, 100}, {}), mu.Rect{20, 20, 100, 100})
}

@(test)
test_stretch_widens :: proc(t: ^testing.T) {
  ctx := new(Context)
  defer free(ctx)
  setup(ctx)
  defer shutdown(ctx)
  design := [2]f32{800, 600}
  testing.expect_value(t, tick(ctx, design, {800, 600}, {10, 10, 300, 100}, {.STRETCH, .TOP}), mu.Rect{10, 10, 300, 100})
  testing.expect_value(t, tick(ctx, design, {1600, 600}, {10, 10, 300, 100}, {.STRETCH, .TOP}), mu.Rect{10, 10, 1100, 100})
}

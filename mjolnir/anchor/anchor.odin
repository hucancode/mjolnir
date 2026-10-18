package anchor

// Horizontal is how a rect holds to the left and right of its frame.
Horizontal :: enum u8 {
  LEFT, // keeps its distance to the left edge
  RIGHT, // keeps its distance to the right edge
  STRETCH, // keeps both, so it widens with the frame
}

// Vertical is how a rect holds to the top and bottom of its frame.
Vertical :: enum u8 {
  TOP,
  BOTTOM,
  STRETCH,
}

// Anchor says what a rect does on each axis when its frame changes size: always one choice per
// axis, so {.RIGHT, .TOP} is a top-right corner and {} is top-left.
Anchor :: struct {
  h: Horizontal,
  v: Vertical,
}

// Rect is an axis-aligned rectangle: top-left `pos` and `size`.
Rect :: struct {
  pos, size: [2]f32,
}

// Frame is a reference frame fitted to a window: `scale` maps reference units to window units,
// `size` is the window in reference units (the reference on the fitted axis, larger on the other).
Frame :: struct {
  scale: f32,
  size:  [2]f32,
}

// frame fits `reference` into `window`: scaled uniformly until one axis matches exactly. The
// other axis keeps the leftover space, which fit hands out by anchor.
frame :: proc(reference, window: [2]f32) -> Frame {
  if reference.x <= 0 || reference.y <= 0 || window.x <= 0 || window.y <= 0 do return {1, reference}
  scale := min(window.x / reference.x, window.y / reference.y)
  return {scale, window / scale}
}

// fit moves `r`, laid out in a frame of size `from`, to a frame of size `to` by its anchor.
fit :: proc(r: Rect, a: Anchor, from, to: [2]f32) -> Rect {
  r := r
  extra := to - from
  switch a.h {
  case .LEFT:
  case .RIGHT: r.pos.x += extra.x
  case .STRETCH: r.size.x += extra.x
  }
  switch a.v {
  case .TOP:
  case .BOTTOM: r.pos.y += extra.y
  case .STRETCH: r.size.y += extra.y
  }
  return r
}

// to_window converts a rect in reference units to window units.
to_window :: proc(r: Rect, f: Frame) -> Rect {
  return {r.pos * f.scale, r.size * f.scale}
}

// to_reference converts a point in window units to reference units.
to_reference :: proc(p: [2]f32, f: Frame) -> [2]f32 {
  return p / f.scale
}

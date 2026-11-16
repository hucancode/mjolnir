package ui

import "core:math"

// SkinMode says how a skin's middle covers its length on one axis.
SkinMode :: enum u8 {
  STRETCH, // one piece, stretched
  REPEAT, // pieces of its own size, the last one cut short
  ROUND, // whole pieces, stretched a little to fit exactly
}

// Skin is an image cut in nine (a nine-patch) to frame a rect of any size: its corners keep
// their size, its edges run along the rect's sides and its middle fills the rest, each
// stretched or tiled as `mode` says. Without a border it is the whole image, stretched or tiled.
Skin :: struct {
  image:  u32, // a texture the renderer knows (render.TextureHandle)
  // the texture coordinates of the region's top-left, top-right, bottom-right and bottom-left
  // corners (an atlas cell); zero is all of it
  uv:     [4][2]f32,
  // the region's size in texels
  size:   [2]f32,
  // the left, top, right and bottom cuts, in texels
  border: [4]f32,
  // window units per texel; 0 counts as 1
  scale:  f32,
  // across: the top and bottom edges and the middle; down: the left and right edges and the
  // middle
  mode:   [2]SkinMode,
  smooth: bool,
}

// skin frames `r` with `s`, tinted by `color`, its texels `scale` times larger again (a UI scale).
skin :: proc(self: ^Canvas, r: Rect, s: Skin, color := WHITE, scale: f32 = 1) {
  k := (s.scale if s.scale > 0 else 1) * scale
  p0, p1 := snap(self, r.pos), snap(self, r.pos + r.size)
  uv := s.uv if s.uv != {} else FULL_UV
  xs := spans(self, p0.x, p1.x, s.border[0], s.border[2], s.size.x, k, s.mode.x)
  ys := spans(self, p0.y, p1.y, s.border[1], s.border[3], s.size.y, k, s.mode.y)
  for y in ys do for x in xs {
    cell := [4][2]f32{uv_at(uv, x.t0, y.t0), uv_at(uv, x.t1, y.t0), uv_at(uv, x.t1, y.t1), uv_at(uv, x.t0, y.t1)}
    quad(self, {x.p0, y.p0}, {x.p1, y.p1}, cell, color, s.image, s.smooth)
  }
}

// A piece of a skin along one axis: from p0 to p1 on screen, t0 to t1 of the region.
@(private = "file")
Span :: struct {
  p0, p1, t0, t1: f32,
}

// The pieces from a to b: the cuts `lo` and `hi` texels of a region `size` texels long, k units
// per texel, on framebuffer pixels; cuts longer than the rect shrink to meet.
@(private = "file")
spans :: proc(self: ^Canvas, a, b, lo, hi, size, k: f32, mode: SkinMode) -> []Span {
  dpi := dpi_of(self)
  on_pixel :: proc(x, dpi: f32) -> f32 {return math.round(x * dpi) / dpi}
  out := make([dynamic]Span, 0, 3, context.temp_allocator)
  length := b - a
  if length <= 0 do return out[:]
  cut_lo, cut_hi := on_pixel(lo * k, dpi), on_pixel(hi * k, dpi)
  if sum := cut_lo + cut_hi; sum > length {
    cut_lo, cut_hi = cut_lo * length / sum, cut_hi * length / sum
  }
  t_lo, t_hi := lo / size if size > 0 else 0, hi / size if size > 0 else 0
  m0, m1 := a + cut_lo, b - cut_hi
  if cut_lo > 0 do append(&out, Span{a, m0, 0, t_lo})
  middle := m1 - m0
  tile := (size - lo - hi) * k
  if middle > 0 {
    count := 1
    #partial switch mode {
    case .REPEAT:
      if tile > 0 do count = int(math.ceil(middle / tile - 1e-4))
    case .ROUND:
      if tile > 0 do count = max(int(math.round(middle / tile)), 1)
    }
    count = clamp(count, 1, int(middle * dpi) + 1)
    step := tile if mode == .REPEAT && tile > 0 else middle / f32(count)
    for i in 0 ..< count {
      p := m0 + step * f32(i)
      end := min(p + step, m1) if i + 1 < count else m1
      t1 := 1 - t_hi
      // a piece cut short shows as much of the region as it covers
      if mode == .REPEAT && tile > 0 do t1 = t_lo + (1 - t_hi - t_lo) * min((end - p) / tile, 1)
      append(&out, Span{on_pixel(p, dpi) if i > 0 else m0, on_pixel(end, dpi) if i + 1 < count else m1, t_lo, t1})
    }
  }
  if cut_hi > 0 do append(&out, Span{m1, b, 1 - t_hi, 1})
  return out[:]
}

// The uv at (s, t), 0..1 across and down, of the quad whose corners show `uv`.
@(private = "file")
uv_at :: proc(uv: [4][2]f32, s, t: f32) -> [2]f32 {
  top := uv[0] + (uv[1] - uv[0]) * s
  bottom := uv[3] + (uv[2] - uv[3]) * s
  return top + (bottom - top) * t
}

// Font on its own: lay out lines in two fonts and draw their glyphs from the atlas into an image on the CPU. The command line writes artifacts/modules/font_only/{text.png,atlas.png}; on the web page, type to replace the last line.
package main

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:math"
import "core:strings"
import "mjolnir/font"
import stbi "vendor:stb/image"

WIDTH :: 900
HEIGHT :: 200

Line :: struct {
  face:  ^font.Font,
  text:  string,
  size:  f32,
  color: [3]f32,
}

outfit, hand: font.Font
lines: [3]Line

setup :: proc() -> bool {
  font.init(&outfit, #load("../../../assets/Outfit-Regular.ttf")) or_return
  font.init(&hand, #load("../../../assets/Excalifont-Regular.ttf")) or_return
  lines = {
    {&outfit, "Mjolnir font, no GPU involved", 48, {1, 0.82, 0.4}},
    {&hand, "glyph quads sampled from the atlas", 36, {0.5, 0.8, 1}},
    {&outfit, "The quick brown fox jumps over the lazy dog 0123456789", 24, {0.9, 0.9, 0.9}},
  }
  return true
}

teardown :: proc() {
  font.destroy(&outfit)
  font.destroy(&hand)
}

// text_png draws every line centered into one image and returns it as a PNG, with what it laid out.
text_png :: proc() -> (image: []u8, report: string) {
  pixels := make([]f32, WIDTH * HEIGHT * 3, context.temp_allocator)
  for &p, i in pixels do p = 0.08 if i % 3 != 2 else 0.12
  b := strings.builder_make(context.temp_allocator)
  y := f32(24)
  glyphs := make([dynamic]font.Glyph, context.temp_allocator)
  for l in lines {
    clear(&glyphs)
    width := font.measure(l.face, l.text, l.size)
    font.glyphs(l.face, l.text, {(WIDTH - width) / 2, y}, l.size, &glyphs)
    atlas, size, _ := font.atlas(l.face)
    for g in glyphs do blit(pixels, g, atlas, size, l.color)
    fmt.sbprintfln(&b, "%q at %.0fpx: %d glyphs, %.1fpx wide", l.text, l.size, len(glyphs), width)
    y += font.line_height(l.face, l.size) * 1.4
  }
  rgb := make([]u8, len(pixels), context.temp_allocator)
  for v, i in pixels do rgb[i] = u8(clamp(v, 0, 1) * 255)
  return png(WIDTH, HEIGHT, 3, rgb), strings.to_string(b)
}

atlas_png :: proc() -> []u8 {
  pixels, size, _ := font.atlas(&outfit)
  return png(int(size.x), int(size.y), 1, pixels)
}

blit :: proc(image: []f32, g: font.Glyph, atlas: []u8, size: [2]u32, color: [3]f32) {
  for py in int(math.floor(g.p0.y)) ..< int(math.ceil(g.p1.y)) {
    for px in int(math.floor(g.p0.x)) ..< int(math.ceil(g.p1.x)) {
      if px < 0 || py < 0 || px >= WIDTH || py >= HEIGHT do continue
      u := (f32(px) + 0.5 - g.p0.x) / (g.p1.x - g.p0.x)
      v := (f32(py) + 0.5 - g.p0.y) / (g.p1.y - g.p0.y)
      tx := clamp(int(g.uv0.x + u * (g.uv1.x - g.uv0.x)), 0, int(size.x) - 1)
      ty := clamp(int(g.uv0.y + v * (g.uv1.y - g.uv0.y)), 0, int(size.y) - 1)
      a := f32(atlas[ty * int(size.x) + tx]) / 255
      p := image[(py * WIDTH + px) * 3:]
      for k in 0 ..< 3 do p[k] = p[k] * (1 - a) + color[k] * a
    }
  }
}

// png encodes pixels as a PNG file in memory.
png :: proc(w, h, channels: int, pixels: []u8) -> []u8 {
  out := make([dynamic]u8, context.temp_allocator)
  write :: proc "c" (ctx: rawptr, data: rawptr, size: c.int) {
    context = runtime.default_context()
    append(cast(^[dynamic]u8)ctx, ..([^]u8)(data)[:size])
  }
  stbi.write_png_to_func(write, &out, i32(w), i32(h), i32(channels), raw_data(pixels), i32(w * channels))
  return out[:]
}

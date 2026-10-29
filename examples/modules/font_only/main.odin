// Font on its own: lay out lines in two fonts, draw their glyphs from the atlas into an image on the CPU, and export the atlas. Writes artifacts/modules/font_only/{text.png,atlas.png}.
package main

import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import "mjolnir/font"
import stbi "vendor:stb/image"

OUT :: "artifacts/modules/font_only/"
WIDTH :: 900
HEIGHT :: 200

Line :: struct {
  face:  ^font.Font,
  text:  string,
  size:  f32,
  color: [3]f32,
}

main :: proc() {
  outfit, hand: font.Font
  if !font.init(&outfit, #load("../../../assets/Outfit-Regular.ttf")) do return
  defer font.destroy(&outfit)
  if !font.init(&hand, #load("../../../assets/Excalifont-Regular.ttf")) do return
  defer font.destroy(&hand)
  lines := []Line {
    {&outfit, "Mjolnir font, no GPU involved", 48, {1, 0.82, 0.4}},
    {&hand, "glyph quads sampled from the atlas", 36, {0.5, 0.8, 1}},
    {&outfit, "The quick brown fox jumps over the lazy dog 0123456789", 24, {0.9, 0.9, 0.9}},
  }
  image := make([]f32, WIDTH * HEIGHT * 3, context.temp_allocator)
  for &p, i in image do p = 0.08 if i % 3 != 2 else 0.12
  y := f32(24)
  glyphs := make([dynamic]font.Glyph, context.temp_allocator)
  for l in lines {
    clear(&glyphs)
    width := font.measure(l.face, l.text, l.size)
    x := (WIDTH - width) / 2
    font.glyphs(l.face, l.text, {x, y}, l.size, &glyphs)
    pixels, size, _ := font.atlas(l.face)
    for g in glyphs do blit(image, g, pixels, size, l.color)
    fmt.printfln("%q at %.0fpx: %d glyphs, %.1fpx wide", l.text, l.size, len(glyphs), width)
    y += font.line_height(l.face, l.size) * 1.4
  }
  os.make_directory_all(OUT)
  rgb := make([]u8, len(image), context.temp_allocator)
  for v, i in image do rgb[i] = u8(clamp(v, 0, 1) * 255)
  write_png(OUT + "text.png", WIDTH, HEIGHT, 3, rgb)
  pixels, size, _ := font.atlas(&outfit)
  write_png(OUT + "atlas.png", int(size.x), int(size.y), 1, pixels)
  fmt.printfln("atlas %dx%d; wrote %stext.png, %satlas.png", size.x, size.y, OUT, OUT)
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

write_png :: proc(path: string, w, h, channels: int, pixels: []u8) {
  stbi.write_png(strings.clone_to_cstring(path, context.temp_allocator), i32(w), i32(h), i32(channels), raw_data(pixels), i32(w * channels))
}

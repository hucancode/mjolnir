// ui on its own: a HUD drawn into a canvas with no renderer, a bar, a framed panel whose skin tiles its edges, and text, pinned to the window's corners by anchors. The command line draws it at two window sizes and writes each triangle of artifacts/modules/ui_only/canvas_<w>x<h>.svg (skin pieces outlined, glyphs as boxes); the web page is live, sized to the window.
package main

import "core:fmt"
import "core:strings"
import "mjolnir/font"
import "mjolnir/ui"

REFERENCE :: [2]f32{800, 600}

face: font.Font
canvas: ui.Canvas
frame_skin := ui.Skin{image = 1, size = {48, 48}, border = {16, 16, 16, 16}, mode = {.REPEAT, .ROUND}}

setup :: proc() -> bool {
  font.init(&face, #load("../../../assets/Outfit-Regular.ttf")) or_return
  return true
}

teardown :: proc() {
  ui.destroy(&canvas)
  font.destroy(&face)
}

draw :: proc(window: [2]f32, health: f32) {
  c := &canvas
  ui.reset(c)
  bar := ui.fit({{20, 20}, {260, 22}}, {}, REFERENCE, window)
  ui.rect(c, bar, {0, 0, 0, 180})
  ui.rect(c, {bar.pos + 2, {(bar.size.x - 4) * health, bar.size.y - 4}}, {200, 50, 50, 255})
  ui.text(c, &face, fmt.tprintf("HP %.0f%%", health * 100), bar.pos + bar.size / 2, 14, pivot = {0.5, 0.5})
  panel := ui.fit({{480, 300}, {300, 280}}, {.RIGHT, .STRETCH}, REFERENCE, window)
  c.z = 1
  ui.rect(c, panel, {18, 18, 24, 230})
  ui.skin(c, panel, frame_skin)
  c.clip = panel
  ui.text(c, &face, "Quests", panel.pos + {24, 22}, 20, {250, 210, 120, 255})
  ui.text(c, &face, "Thin out the slimes 4 / 10", panel.pos + {24, 54}, 15)
  ui.border(c, {panel.pos + {24, 84}, {panel.size.x - 48, 2}}, 1, {120, 110, 90, 255})
}

svg :: proc(window: [2]f32) -> string {
  b := strings.builder_make(context.temp_allocator)
  fmt.sbprintfln(&b, `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 %d %d" width="%d" height="%d" style="background:#3a4a5a">`, int(window.x), int(window.y), int(window.x), int(window.y))
  vertices, indices, batches := ui.mesh(&canvas)
  for batch in batches {
    vs := vertices[batch.first_vertex:][:batch.vertex_count]
    for k := u32(0); k + 2 < batch.index_count; k += 3 {
      i := indices[batch.first_index:][k:]
      a, p, q := vs[i[0]], vs[i[1]], vs[i[2]]
      fill := fmt.tprintf("rgba(%d,%d,%d,%.2f)", a.color.r, a.color.g, a.color.b, f32(a.color.a) / 255)
      stroke := "none"
      switch batch.texture {
      case ui.FONT_TEXTURE: fill = "rgba(255,255,255,0.5)"
      case 0:
      case: fill, stroke = "rgba(160,150,120,0.35)", "#c8b070"
      }
      fmt.sbprintfln(&b, `<polygon points="%.1f,%.1f %.1f,%.1f %.1f,%.1f" fill="%s" stroke="%s" stroke-width="0.5"/>`, a.pos.x, a.pos.y, p.pos.x, p.pos.y, q.pos.x, q.pos.y, fill, stroke)
    }
  }
  fmt.sbprintln(&b, "</svg>")
  return strings.to_string(b)
}

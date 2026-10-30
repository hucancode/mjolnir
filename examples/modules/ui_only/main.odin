// UI on its own: a panel with a button, wrapped text, a clipped scrolling list and a pinned badge, laid out and hit-tested with no renderer. The command line lays it out at two window sizes, clicks the button with scripted input and writes artifacts/modules/ui_only/layout_<w>x<h>.svg; the web page is live, sized to the window and driven by the mouse.
package main

import "core:fmt"
import "core:strings"
import "mjolnir/font"
import "mjolnir/input"
import "mjolnir/ui"

gui: ui.UI
face: font.Font
button, counter, list: ui.NodeHandle
clicks: int

setup :: proc() -> bool {
  font.init(&face, #load("../../../assets/Outfit-Regular.ttf")) or_return
  ui.init(&gui)
  panel_style := ui.style_create(&gui, {fill = {30, 30, 46, 255}, color = 255})
  button_style := ui.style_create(&gui, {fill = {200, 80, 80, 255}, color = 255}, ui.Style{fill = {216, 96, 96, 255}, color = 255}, ui.Style{fill = {224, 112, 112, 255}, color = 255})
  list_style := ui.style_create(&gui, {fill = {18, 18, 26, 255}})
  rows := [2]ui.StyleHandle{ui.style_create(&gui, {fill = {50, 60, 90, 255}, color = 255}), ui.style_create(&gui, {fill = {40, 48, 72, 255}, color = 255})}
  badge_style := ui.style_create(&gui, {fill = {0, 0, 0, 170}, color = 255})
  screen := ui.node_create(&gui, {size = {{.PERCENT, 1}, {.PERCENT, 1}}})
  panel := ui.node_create(&gui, {parent = screen, direction = .COLUMN, size = {{.PERCENT, 0.9}, {}}, padding = {16, 16, 16, 16}, gap = 12, offset = {20, 20}, style = panel_style})
  text(panel, "Settings", 28)
  row := ui.node_create(&gui, {parent = panel, gap = 16, align = {.START, .CENTER}})
  button = ui.node_create(&gui, {parent = row, size = {{.FIXED, 160}, {.FIXED, 44}}, interactive = true, align = {.CENTER, .CENTER}, style = button_style})
  text(button, "Apply", 20)
  counter = text(row, "Clicks: 0")
  text(panel, "ui lays out nodes and answers hit tests on its own: this paragraph wraps to the panel, which takes nine tenths of the window, so it reflows as the window widens.", 16, {size = {{.PERCENT, 1}, {}}, wrap = true})
  list = ui.node_create(&gui, {parent = panel, direction = .COLUMN, size = {{.PERCENT, 1}, {.FIXED, 120}}, gap = 4, clip = true, scroll = {0, 40}, interactive = true, style = list_style})
  for i in 0 ..< 6 {
    item := ui.node_create(&gui, {parent = list, size = {{.GROW, 0}, {.FIXED, 28}}, padding = {8, 0, 8, 0}, align = {.START, .CENTER}, style = rows[i % 2]})
    text(item, fmt.tprintf("Option %d", i + 1))
  }
  badge := ui.node_create(&gui, {parent = screen, position = .ABSOLUTE, anchor = {1, 1}, offset = {-16, -16}, padding = {10, 6, 10, 6}, style = badge_style})
  text(badge, "pinned bottom-right", 14)
  return true
}

teardown :: proc() {
  ui.shutdown(&gui)
  font.destroy(&face)
}

text :: proc(parent: ui.NodeHandle, s: string, size: f32 = 18, n: ui.Node = {}) -> ui.NodeHandle {
  n := n
  n.parent, n.text, n.font_size = parent, s, size
  return ui.node_create(&gui, n)
}

tick :: proc(s: ^input.State, size: [2]f32) -> bool {
  _, before := ui.update(&gui, size, &face)
  ui.update_input(&gui, s)
  if ui.clicked(&gui, button) {
    clicks += 1
    ui.set_text(&gui, counter, fmt.tprintf("Clicks: %d", clicks))
  }
  if ui.hovered(&gui, list) {
    l := ui.node(&gui, list)
    l.scroll.y = clamp(l.scroll.y - s.scroll.y * 20, 0, ui.max_scroll(&gui, list).y)
  }
  _, after := ui.update(&gui, size, &face)
  return before || after
}

svg :: proc(size: [2]f32) -> string {
  b := strings.builder_make(context.temp_allocator)
  fmt.sbprintfln(&b, `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 %d %d" width="%d" height="%d" style="background:#3a4a5a">`, int(size.x), int(size.y), int(size.x), int(size.y))
  for h in gui.draw_order {
    clip := ui.clip(&gui, h)
    look := ui.look(&gui, h)
    if c := look.fill; c.a > 0 {
      r := overlap(ui.rect(&gui, h), clip)
      if r.size.x <= 0 || r.size.y <= 0 do continue
      fmt.sbprintfln(&b, `<rect x="%.1f" y="%.1f" width="%.1f" height="%.1f" fill="rgba(%d,%d,%d,%.2f)"/>`, r.pos.x, r.pos.y, r.size.x, r.size.y, c.r, c.g, c.b, f32(c.a) / 255)
    }
    n := ui.node(&gui, h)
    for line in ui.lines(&gui, h) {
      if line.pos.y < clip.pos.y || line.pos.y + line.size > clip.pos.y + clip.size.y do continue
      fmt.sbprintfln(&b, `<text x="%.1f" y="%.1f" font-size="%.0f" fill="rgb(%d,%d,%d)" font-family="sans-serif">%s</text>`, line.pos.x, line.pos.y + line.size * 0.8, line.size, look.color.r, look.color.g, look.color.b, n.text[line.start:line.end])
    }
  }
  fmt.sbprintln(&b, "</svg>")
  return strings.to_string(b)
}

overlap :: proc(a, b: ui.Rect) -> ui.Rect {
  lo := [2]f32{max(a.pos.x, b.pos.x), max(a.pos.y, b.pos.y)}
  hi := [2]f32{min(a.pos.x + a.size.x, b.pos.x + b.size.x), min(a.pos.y + a.size.y, b.pos.y + b.size.y)}
  return {lo, hi - lo}
}

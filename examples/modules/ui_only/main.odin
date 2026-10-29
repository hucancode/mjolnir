// UI on its own: a panel with a button, wrapped text, a clipped scrolling list and a pinned badge, laid out and hit-tested with no renderer. The command line lays it out at two window sizes, clicks the button with scripted input and writes artifacts/modules/ui_only/layout_<w>x<h>.svg; the web page is live, sized to the window and driven by the mouse.
package main

import "core:fmt"
import "core:strings"
import "mjolnir/font"
import "mjolnir/input"
import "mjolnir/ui"

gui: ui.UI
face: font.Font
colors: map[ui.NodeHandle]string
button, counter, list: ui.NodeHandle
clicks: int

setup :: proc() -> bool {
  font.init(&face, #load("../../../assets/Outfit-Regular.ttf")) or_return
  ui.init(&gui)
  screen := ui.node_create(&gui, {size = {{.PERCENT, 1}, {.PERCENT, 1}}, pin = {.STRETCH, .STRETCH}})
  panel := ui.node_create(&gui, {parent = screen, direction = .COLUMN, size = {{.PERCENT, 0.9}, {}}, padding = {16, 16, 16, 16}, gap = 12, offset = {20, 20}})
  colors[panel] = "#1e1e2e"
  text(panel, "Settings", 28)
  row := ui.node_create(&gui, {parent = panel, gap = 16, align = {.START, .CENTER}})
  button = ui.node_create(&gui, {parent = row, size = {{.FIXED, 160}, {.FIXED, 44}}, interactive = true, align = {.CENTER, .CENTER}})
  text(button, "Apply", 20)
  counter = text(row, "Clicks: 0")
  text(panel, "ui lays out nodes and answers hit tests on its own: this paragraph wraps to the panel, which takes nine tenths of the window, so it reflows as the window widens.", 16, {size = {{.PERCENT, 1}, {}}, wrap = true})
  list = ui.node_create(&gui, {parent = panel, direction = .COLUMN, size = {{.PERCENT, 1}, {.FIXED, 120}}, gap = 4, clip = true, scroll = {0, 40}, interactive = true})
  colors[list] = "#12121a"
  for i in 0 ..< 6 {
    item := ui.node_create(&gui, {parent = list, size = {{.GROW, 0}, {.FIXED, 28}}, padding = {8, 0, 8, 0}, align = {.START, .CENTER}})
    colors[item] = "#323c5a" if i % 2 == 0 else "#283048"
    text(item, fmt.tprintf("Option %d", i + 1))
  }
  badge := ui.node_create(&gui, {parent = screen, position = .ABSOLUTE, anchor = {1, 1}, offset = {-16, -16}, padding = {10, 6, 10, 6}})
  colors[badge] = "#000000aa"
  text(badge, "pinned bottom-right", 14)
  return true
}

teardown :: proc() {
  delete(colors)
  ui.shutdown(&gui)
  font.destroy(&face)
}

text :: proc(parent: ui.NodeHandle, s: string, size: f32 = 18, n: ui.Node = {}) -> ui.NodeHandle {
  n := n
  n.parent, n.text, n.font_size = parent, s, size
  return ui.node_create(&gui, n)
}

// tick lays the panel out for a window of `size` and answers one tick of input.
tick :: proc(s: ^input.State, size: [2]f32) {
  ui.layout(&gui, size, &face)
  ui.update_input(&gui, s)
  if ui.clicked(&gui, button) {
    clicks += 1
    ui.set_text(&gui, counter, fmt.tprintf("Clicks: %d", clicks))
  }
  if ui.hovered(&gui, list) {
    l := ui.node(&gui, list)
    l.scroll.y = clamp(l.scroll.y - s.scroll.y * 20, 0, ui.max_scroll(&gui, list).y)
  }
  colors[button] = "#e07070" if ui.pressed(&gui, button) else "#d86060" if ui.hovered(&gui, button) else "#c85050"
  ui.layout(&gui, size, &face)
}

svg :: proc(size: [2]f32) -> string {
  b := strings.builder_make(context.temp_allocator)
  fmt.sbprintfln(&b, `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 %d %d" width="%d" height="%d" style="background:#3a4a5a">`, int(size.x), int(size.y), int(size.x), int(size.y))
  for h in gui.draw_order {
    clip := ui.clip(&gui, h)
    if color, ok := colors[h]; ok {
      r := overlap(ui.rect(&gui, h), clip)
      if r.size.x <= 0 || r.size.y <= 0 do continue
      fmt.sbprintfln(&b, `<rect x="%.1f" y="%.1f" width="%.1f" height="%.1f" fill="%s"/>`, r.pos.x, r.pos.y, r.size.x, r.size.y, color)
    }
    n := ui.node(&gui, h)
    for line in ui.lines(&gui, h) {
      if line.pos.y < clip.pos.y || line.pos.y + line.size > clip.pos.y + clip.size.y do continue
      fmt.sbprintfln(&b, `<text x="%.1f" y="%.1f" font-size="%.0f" fill="#ebebf5" font-family="sans-serif">%s</text>`, line.pos.x, line.pos.y + line.size * 0.8, line.size, n.text[line.start:line.end])
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

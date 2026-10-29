// UI on its own: lay out a panel at two window sizes, scroll a clipped list and click a button with scripted input. Writes artifacts/modules/ui_only/layout_<w>x<h>.svg.
package main

import "core:fmt"
import "core:os"
import "core:strings"
import "mjolnir/font"
import "mjolnir/input"
import "mjolnir/ui"

OUT :: "artifacts/modules/ui_only/"
SIZES :: [?][2]f32{{1024, 768}, {1600, 800}}

App :: struct {
  gui:     ui.UI,
  font:    font.Font,
  colors:  map[ui.NodeHandle]string,
  button:  ui.NodeHandle,
  counter: ui.NodeHandle,
  clicks:  int,
}

main :: proc() {
  app: App
  if !font.init(&app.font, #load("../../../assets/Outfit-Regular.ttf")) do return
  defer font.destroy(&app.font)
  ui.init(&app.gui)
  defer ui.shutdown(&app.gui)
  defer delete(app.colors)
  build(&app)
  for size in SIZES {
    ui.layout(&app.gui, size, &app.font)
    click(&app, ui.rect(&app.gui, app.button))
    ui.layout(&app.gui, size, &app.font)
    path := fmt.tprintf("%slayout_%dx%d.svg", OUT, int(size.x), int(size.y))
    write_svg(&app, path, size)
    b := ui.rect(&app.gui, app.button)
    fmt.printfln("%v: button at %v size %v, clicks %d, wrote %s", size, b.pos, b.size, app.clicks, path)
  }
}

text :: proc(app: ^App, parent: ui.NodeHandle, s: string, size: f32 = 18, n: ui.Node = {}) -> ui.NodeHandle {
  n := n
  n.parent, n.text, n.font_size = parent, s, size
  return ui.node_create(&app.gui, n)
}

build :: proc(app: ^App) {
  screen := ui.node_create(&app.gui, {size = {{.PERCENT, 1}, {.PERCENT, 1}}, pin = {.STRETCH, .STRETCH}})
  panel := ui.node_create(&app.gui, {parent = screen, direction = .COLUMN, size = {{.PERCENT, 0.9}, {}}, padding = {16, 16, 16, 16}, gap = 12, offset = {20, 20}})
  app.colors[panel] = "#1e1e2e"
  text(app, panel, "Settings", 28)
  row := ui.node_create(&app.gui, {parent = panel, gap = 16, align = {.START, .CENTER}})
  app.button = ui.node_create(&app.gui, {parent = row, size = {{.FIXED, 160}, {.FIXED, 44}}, interactive = true, align = {.CENTER, .CENTER}})
  app.colors[app.button] = "#c85050"
  text(app, app.button, "Apply", 20)
  app.counter = text(app, row, "Clicks: 0")
  text(app, panel, "ui lays out nodes and answers hit tests on its own: this paragraph wraps to the panel, which takes nine tenths of the window, so it reflows as the window widens.", 16, {size = {{.PERCENT, 1}, {}}, wrap = true})
  list := ui.node_create(&app.gui, {parent = panel, direction = .COLUMN, size = {{.PERCENT, 1}, {.FIXED, 120}}, gap = 4, clip = true, scroll = {0, 40}})
  app.colors[list] = "#12121a"
  for i in 0 ..< 6 {
    item := ui.node_create(&app.gui, {parent = list, size = {{.GROW, 0}, {.FIXED, 28}}, padding = {8, 0, 8, 0}, align = {.START, .CENTER}})
    app.colors[item] = "#323c5a" if i % 2 == 0 else "#283048"
    text(app, item, fmt.tprintf("Option %d", i + 1))
  }
  badge := ui.node_create(&app.gui, {parent = screen, position = .ABSOLUTE, anchor = {1, 1}, offset = {-16, -16}, padding = {10, 6, 10, 6}})
  app.colors[badge] = "#000000aa"
  text(app, badge, "pinned bottom-right", 14)
}

click :: proc(app: ^App, r: ui.Rect) {
  center := r.pos + r.size / 2
  for action in ([]input.Action{.PRESS, .RELEASE}) {
    acc, s: input.State
    input.cursor_event(&acc, center)
    input.button_event(&acc, .LEFT, action)
    input.drain(&acc, &s)
    ui.update_input(&app.gui, &s)
    if ui.clicked(&app.gui, app.button) {
      app.clicks += 1
      ui.set_text(&app.gui, app.counter, fmt.tprintf("Clicks: %d", app.clicks))
    }
  }
}

write_svg :: proc(app: ^App, path: string, size: [2]f32) {
  b := strings.builder_make(context.temp_allocator)
  fmt.sbprintfln(&b, `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 %d %d" width="%d" height="%d" style="background:#3a4a5a">`, int(size.x), int(size.y), int(size.x), int(size.y))
  for h in app.gui.draw_order {
    clip := ui.clip(&app.gui, h)
    if color, ok := app.colors[h]; ok {
      r := overlap(ui.rect(&app.gui, h), clip)
      if r.size.x <= 0 || r.size.y <= 0 do continue
      fmt.sbprintfln(&b, `<rect x="%.1f" y="%.1f" width="%.1f" height="%.1f" fill="%s"/>`, r.pos.x, r.pos.y, r.size.x, r.size.y, color)
    }
    n := ui.node(&app.gui, h)
    for line in ui.lines(&app.gui, h) {
      if line.pos.y < clip.pos.y || line.pos.y + line.size > clip.pos.y + clip.size.y do continue
      fmt.sbprintfln(&b, `<text x="%.1f" y="%.1f" font-size="%.0f" fill="#ebebf5" font-family="sans-serif">%s</text>`, line.pos.x, line.pos.y + line.size * 0.8, line.size, n.text[line.start:line.end])
    }
  }
  fmt.sbprintln(&b, "</svg>")
  os.make_directory_all(OUT)
  _ = os.write_entire_file(path, strings.to_string(b))
}

overlap :: proc(a, b: ui.Rect) -> ui.Rect {
  lo := [2]f32{max(a.pos.x, b.pos.x), max(a.pos.y, b.pos.y)}
  hi := [2]f32{min(a.pos.x + a.size.x, b.pos.x + b.size.x), min(a.pos.y + a.size.y, b.pos.y + b.size.y)}
  return {lo, hi - lo}
}

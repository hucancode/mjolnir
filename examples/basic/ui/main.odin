// ui layout (flex, anchors, wrap, clip, scroll) drawn through the 2D overlay.
package main

import "mjolnir"
import "mjolnir/font"
import "mjolnir/input"
import "mjolnir/platform"
import "mjolnir/render"
import "mjolnir/ui"
import "mjolnir/world"
import "core:fmt"
import "core:log"
import "core:math"

Look :: struct {
  color:   [4]u8,
  texture: render.TextureHandle,
}

App :: struct {
  window:   platform.Platform,
  scene:    world.World,
  renderer: render.Renderer,
  input:    input.State,
  font:     font.Font,
  gui:      ui.UI,
  looks:    map[ui.NodeHandle]Look,
  button:   ui.NodeHandle,
  counter:  ui.NodeHandle,
  list:     ui.NodeHandle,
  star:     ui.NodeHandle,
  clicks:   int,
  orbit:    render.Orbit,
}

TEXT_COLOR :: [4]u8{235, 235, 245, 255}
BUTTON_COLOR :: [4]u8{200, 80, 80, 255}
BUTTON_HOVER :: [4]u8{230, 120, 90, 255}
BUTTON_PRESSED :: [4]u8{110, 200, 110, 255}
REFERENCE :: [2]f32{900, 700}
LIST_ITEMS :: 12
LIST_ITEM_HEIGHT :: 28
LIST_GAP :: 4
LIST_HEIGHT :: 120
LIST_MAX_SCROLL :: LIST_ITEMS * LIST_ITEM_HEIGHT + (LIST_ITEMS - 1) * LIST_GAP - LIST_HEIGHT

main :: proc() {
  context.logger = log.create_console_logger()
  app := new(App)
  w := &app.window
  if !platform.init(w, 900, 700, "UI") do return
  if !render.init(&app.renderer, "UI", w.window, platform.framebuffer_size(w), platform.dpi_scale(w)) do return
  if !world.init(&app.scene) do return
  mjolnir.run(
    mjolnir.Loop(App) {
      app = app,
      setup = setup,
      shutdown = shutdown,
      should_close = should_close,
      update = update,
      frame = frame,
    },
  )
}

setup :: proc(app: ^App) -> mjolnir.Setup {
  if !render.ready(&app.renderer) do return .WAIT
  if !font.init(&app.font, #load("assets/Outfit-Regular.ttf")) do return .FAIL
  ui.init(&app.gui)
  build_ui(app)
  cube := world.spawn(&app.scene)
  render.attach(&app.renderer, render.SlotHandle(cube.index), render.primitive(&app.renderer, .CUBE, .BLUE))
  render.camera_look_at(render.main_camera(&app.renderer), {3, 2, 3}, {0, 0, 0})
  app.orbit = render.orbit_from_camera(render.main_camera(&app.renderer), {0, 0, 0})
  return .READY
}

shutdown :: proc(app: ^App) {
  delete(app.looks)
  ui.shutdown(&app.gui)
  font.destroy(&app.font)
  world.shutdown(&app.scene)
  render.shutdown(&app.renderer)
  platform.shutdown(&app.window)
  free(app)
}

text :: proc(app: ^App, parent: ui.NodeHandle, s: string, size: f32 = 18, n: ui.Node = {}) -> ui.NodeHandle {
  n := n
  n.parent, n.text, n.font_size = parent, s, size
  return ui.node_create(&app.gui, n)
}

build_ui :: proc(app: ^App) {
  panel := ui.node_create(&app.gui, {direction = .COLUMN, padding = {16, 16, 16, 16}, gap = 12, offset = {32, 32}})
  app.looks[panel] = {{30, 30, 46, 220}, render.NO_TEXTURE}
  text(app, panel, "Mjolnir UI", 28)
  row := ui.node_create(&app.gui, {parent = panel, gap = 16, align = {.START, .CENTER}})
  app.button = ui.node_create(&app.gui, {parent = row, size = {{.FIXED, 160}, {.FIXED, 44}}, interactive = true, align = {.CENTER, .CENTER}})
  app.looks[app.button] = {BUTTON_COLOR, render.NO_TEXTURE}
  text(app, app.button, "Click me!", 20)
  app.counter = text(app, row, "Clicks: 0")
  text(
    app,
    panel,
    "ui lays out nodes and answers hit tests; the app turns rects and text lines into render's overlay commands. This paragraph wraps to its width.",
    16,
    {size = {{.FIXED, 360}, {}}, wrap = true},
  )
  app.list = ui.node_create(&app.gui, {parent = panel, direction = .COLUMN, size = {{.FIXED, 360}, {.FIXED, LIST_HEIGHT}}, gap = LIST_GAP, clip = true, interactive = true})
  app.looks[app.list] = {{18, 18, 26, 255}, render.NO_TEXTURE}
  for i in 0 ..< LIST_ITEMS {
    item := ui.node_create(&app.gui, {parent = app.list, size = {{.GROW, 0}, {.FIXED, LIST_ITEM_HEIGHT}}, padding = {8, 0, 8, 0}, align = {.START, .CENTER}})
    app.looks[item] = {{50, 60, 90, 255} if i % 2 == 0 else {40, 48, 72, 255}, render.NO_TEXTURE}
    text(app, item, fmt.tprintf("Item %d", i + 1))
  }
  screen := ui.node_create(&app.gui, {size = {{.PERCENT, 1}, {.PERCENT, 1}}, pin = {.STRETCH, .STRETCH}})
  hint := ui.node_create(&app.gui, {parent = screen, position = .ABSOLUTE, anchor = {1, 0}, offset = {-16, 16}, padding = {10, 6, 10, 6}})
  app.looks[hint] = {{0, 0, 0, 160}, render.NO_TEXTURE}
  text(app, hint, "drag: orbit   wheel over list: scroll", 14)
  if star_texture, ok := render.texture_create(&app.renderer, #load("assets/gold-star.png")); ok {
    image := ui.node_create(&app.gui, {parent = screen, position = .ABSOLUTE, anchor = {1, 1}, offset = {-16, -16}, size = {{.FIXED, 128}, {.FIXED, 128}}})
    app.looks[image] = {{255, 255, 255, 255}, star_texture}
  }
  app.star = ui.node_create(&app.gui, {parent = screen, position = .ABSOLUTE, anchor = {0, 1}, offset = {16, -16}, size = {{.FIXED, 140}, {.FIXED, 140}}})
}

should_close :: proc(app: ^App) -> bool {
  return platform.should_close(&app.window)
}

update :: proc(app: ^App, dt: f32) {
  render.lock(&app.renderer)
  defer render.unlock(&app.renderer)
  platform.read_input(&app.window, &app.input)
  size := platform.framebuffer_size(&app.window)
  dpi := platform.dpi_scale(&app.window)
  ui.layout(&app.gui, REFERENCE, {f32(size.x), f32(size.y)} / dpi, &app.font)
  ui.update_input(&app.gui, &app.input)
  if ui.clicked(&app.gui, app.button) {
    app.clicks += 1
    ui.set_text(&app.gui, app.counter, fmt.tprintf("Clicks: %d", app.clicks))
  }
  look := &app.looks[app.button]
  look.color = BUTTON_PRESSED if ui.pressed(&app.gui, app.button) else BUTTON_HOVER if ui.hovered(&app.gui, app.button) else BUTTON_COLOR
  if ui.hovered(&app.gui, app.list) {
    list := ui.node(&app.gui, app.list)
    list.scroll.y = clamp(list.scroll.y - app.input.scroll.y * 20, 0, LIST_MAX_SCROLL)
  }
  if !app.input.mouse_captured {
    drag := app.input.mouse_delta if input.mouse_down(&app.input, .LEFT) else 0
    render.orbit_drag(&app.orbit, drag, app.input.scroll.y)
  }
  render.camera_orbit(render.main_camera(&app.renderer), app.orbit)
  world.update(&app.scene)
  render.stage_transforms(&app.renderer, world.changes(&app.scene))
  draw_hud(app)
  render.update(&app.renderer, dt)
}

frame :: proc(app: ^App) -> bool {
  platform.poll_events(&app.window)
  return render.frame(&app.renderer, platform.framebuffer_size(&app.window), platform.dpi_scale(&app.window))
}

draw_hud :: proc(app: ^App) {
  commands := make([dynamic]render.RenderCommand, context.temp_allocator)
  for h, z in app.gui.draw_order {
    r, c := ui.rect(&app.gui, h), ui.clip(&app.gui, h)
    clip := [4]f32{c.pos.x, c.pos.y, c.size.x, c.size.y}
    if look, ok := app.looks[h]; ok {
      append(&commands, render.RenderCommand{render.DrawQuadCommand{r.pos, r.size, look.color, look.texture}, i32(z), clip})
    }
    if h == app.star {
      vertices, indices := star_mesh(r.size * 0.5, {255, 215, 0, 255})
      append(&commands, render.RenderCommand{render.DrawMeshCommand{r.pos, vertices, indices, render.NO_TEXTURE}, i32(z), clip})
    }
    n := ui.node(&app.gui, h)
    for line in ui.lines(&app.gui, h) {
      text := render.DrawTextCommand{text = n.text[line.start:line.end], position = line.pos, size = line.size, color = TEXT_COLOR}
      append(&commands, render.RenderCommand{text, i32(z), clip})
    }
  }
  render.stage_overlay(&app.renderer, commands[:], &app.font)
}

star_mesh :: proc(r: [2]f32, color: [4]u8) -> (vertices: []render.Vertex2D, indices: []u32) {
  vertices = make([]render.Vertex2D, 11, context.temp_allocator)
  indices = make([]u32, 30, context.temp_allocator)
  vertices[0] = {pos = r, uv = {0.5, 0.5}, color = color}
  for i in 0 ..< 10 {
    angle := f32(i) * math.PI / 5 - math.PI / 2
    radius: f32 = 1 if i % 2 == 0 else 0.4
    dir := [2]f32{math.cos(angle), math.sin(angle)}
    vertices[1 + i] = {pos = r + r * dir * radius, uv = 0.5 + dir * radius * 0.5, color = color}
    p := indices[i * 3:]
    p[0], p[1], p[2] = 0, u32(1 + i), u32(1 + (i + 1) % 10)
  }
  return
}

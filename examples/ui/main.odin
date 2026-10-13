// ui layout (flex, anchors, wrap, clip, scroll) drawn through the 2D overlay.
package main

import "../../mjolnir"
import "../../mjolnir/font"
import "../../mjolnir/input"
import "../../mjolnir/platform"
import "../../mjolnir/render"
import "../../mjolnir/ui"
import "../../mjolnir/world"
import "core:fmt"
import "core:log"
import "core:math"
import "core:os"

// How the app draws a node: ui lays nodes out, the app gives them a look.
Look :: struct {
  color:   [4]u8,
  texture: u32, // render.NO_TEXTURE for a flat color
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
  // orbit controller state, owned by the app
  yaw, pitch, dist: f32,
}

TEXT_COLOR :: [4]u8{235, 235, 245, 255}
BUTTON_COLOR :: [4]u8{200, 80, 80, 255}
BUTTON_HOVER :: [4]u8{230, 120, 90, 255}
BUTTON_PRESSED :: [4]u8{110, 200, 110, 255}

main :: proc() {
  context.logger = log.create_console_logger()
  app := new(App)
  defer free(app)
  w := &app.window
  if !platform.init(w, 900, 700, "UI") do return
  defer platform.shutdown(w)
  if !render.init(&app.renderer, "UI", platform.vulkan_instance_extensions(), platform.vulkan_get_instance_proc_addr(), platform.create_surface, w, platform.framebuffer_size(w), platform.dpi_scale(w)) do return
  defer render.shutdown(&app.renderer)
  if !world.init(&app.scene) do return
  defer world.shutdown(&app.scene)
  render.load_environment_map(&app.renderer, "assets/Cannon_Exterior.hdr")
  font_data, err := os.read_entire_file("assets/Outfit-Regular.ttf", context.allocator)
  if err != nil do return
  defer delete(font_data)
  if !font.init(&app.font, font_data) do return
  defer font.destroy(&app.font)
  ui.init(&app.gui)
  defer ui.destroy(&app.gui)
  defer delete(app.looks)
  build_ui(app)
  cube := world.spawn(&app.scene)
  render.attach(&app.renderer, cube.index, render.primitive(&app.renderer, .CUBE, .BLUE))
  render.main_camera_look_at(&app.renderer, {3, 2, 3}, {0, 0, 0})
  app.yaw, app.pitch, app.dist = render.camera_orbit_state(render.main_camera(&app.renderer))
  mjolnir.run(mjolnir.Loop(App){app = app, should_close = should_close, update = update, frame = frame})
}

text :: proc(app: ^App, parent: ui.NodeHandle, s: string, size: f32 = 18, n: ui.Node = {}) -> ui.NodeHandle {
  n := n
  n.parent, n.text, n.font_size = parent, s, size
  return ui.create(&app.gui, n)
}

build_ui :: proc(app: ^App) {
  // a column panel: title, a row with a button and a counter, wrapped text
  // and a clipped list that scrolls with the wheel
  panel := ui.create(&app.gui, {direction = .COLUMN, padding = {16, 16, 16, 16}, gap = 12, offset = {32, 32}})
  app.looks[panel] = {{30, 30, 46, 220}, render.NO_TEXTURE}
  text(app, panel, "Mjolnir UI", 28)
  row := ui.create(&app.gui, {parent = panel, gap = 16, align = {.START, .CENTER}})
  app.button = ui.create(&app.gui, {parent = row, size = {{.FIXED, 160}, {.FIXED, 44}}, interactive = true, align = {.CENTER, .CENTER}})
  app.looks[app.button] = {BUTTON_COLOR, render.NO_TEXTURE}
  // the label sits in the button: hovering or clicking it counts for the button
  text(app, app.button, "Click me!", 20)
  app.counter = text(app, row, "Clicks: 0")
  text(
    app,
    panel,
    "ui lays out nodes and answers hit tests; the app turns rects and text lines into render's overlay commands. This paragraph wraps to its width.",
    16,
    {size = {{.FIXED, 360}, {}}, wrap = true},
  )
  app.list = ui.create(&app.gui, {parent = panel, direction = .COLUMN, size = {{.FIXED, 360}, {.FIXED, 120}}, gap = 4, clip = true, interactive = true})
  app.looks[app.list] = {{18, 18, 26, 255}, render.NO_TEXTURE}
  for i in 0 ..< 12 {
    item := ui.create(&app.gui, {parent = app.list, size = {{.GROW, 0}, {.FIXED, 28}}, padding = {8, 0, 8, 0}, align = {.START, .CENTER}})
    app.looks[item] = {{50, 60, 90, 255} if i % 2 == 0 else {40, 48, 72, 255}, render.NO_TEXTURE}
    text(app, item, fmt.tprintf("Item %d", i + 1))
  }
  // HUD corner: anchored to the window's top-right
  hint := ui.create(&app.gui, {position = .ABSOLUTE, anchor = {1, 0}, offset = {-16, 16}, padding = {10, 6, 10, 6}})
  app.looks[hint] = {{0, 0, 0, 160}, render.NO_TEXTURE}
  text(app, hint, "drag: orbit   wheel over list: scroll", 14)
  // an image anchored bottom-right, and a star mesh bottom-left
  if star_texture, ret := render.create_texture_from_path(&app.renderer, "assets/gold-star.png"); ret == .SUCCESS {
    image := ui.create(&app.gui, {position = .ABSOLUTE, anchor = {1, 1}, offset = {-16, -16}, size = {{.FIXED, 128}, {.FIXED, 128}}})
    app.looks[image] = {{255, 255, 255, 255}, u32(star_texture)}
  }
  app.star = ui.create(&app.gui, {position = .ABSOLUTE, anchor = {0, 1}, offset = {16, -16}, size = {{.FIXED, 140}, {.FIXED, 140}}})
}

should_close :: proc(app: ^App) -> bool {
  return platform.should_close(&app.window)
}

update :: proc(app: ^App, dt: f32) {
  platform.read_input(&app.window, &app.input)
  // layout in window pixels, where the cursor is; frame scales to the framebuffer
  size := platform.framebuffer_size(&app.window)
  dpi := platform.dpi_scale(&app.window)
  ui.layout(&app.gui, {size = {f32(size.x), f32(size.y)} / dpi}, &app.font)
  ui.update_input(&app.gui, &app.input)
  if ui.clicked(&app.gui, app.button) {
    app.clicks += 1
    ui.set_text(&app.gui, app.counter, fmt.tprintf("Clicks: %d", app.clicks))
  }
  look := &app.looks[app.button]
  look.color = BUTTON_PRESSED if ui.pressed(&app.gui, app.button) else BUTTON_HOVER if ui.hovered(&app.gui, app.button) else BUTTON_COLOR
  if ui.hovered(&app.gui, app.list) {
    list := ui.node(&app.gui, app.list)
    list.scroll.y = clamp(list.scroll.y - app.input.scroll.y * 20, 0, 12 * 32 - 4 - 120)
  }
  if !app.input.mouse_captured {
    if input.mouse_down(&app.input, .LEFT) {
      app.yaw += app.input.mouse_delta.x * 0.02
      app.pitch = clamp(app.pitch + app.input.mouse_delta.y * 0.02, -1.5, 1.5)
    }
    app.dist = clamp(app.dist - app.input.scroll.y * 2, 1, 200)
  }
  render.main_camera_orbit(&app.renderer, app.yaw, app.pitch, app.dist)
  world.update(&app.scene)
  render.stage_transforms(&app.renderer, world.changes(&app.scene))
  render.update(&app.renderer, dt)
}

// The app's half of the UI: every shown node, back to front, as overlay
// commands in framebuffer pixels.
frame :: proc(app: ^App) -> bool {
  platform.poll_events(&app.window)
  s := platform.dpi_scale(&app.window)
  commands := make([dynamic]render.RenderCommand, context.temp_allocator)
  for h, z in app.gui.draw_order {
    r, c := ui.rect(&app.gui, h), ui.clip(&app.gui, h)
    clip := [4]f32{c.pos.x, c.pos.y, c.size.x, c.size.y} * s
    if look, ok := app.looks[h]; ok {
      append(&commands, render.DrawQuadCommand{r.pos * s, r.size * s, look.color, look.texture, i32(z), clip})
    }
    if h == app.star {
      vertices, indices := star_mesh(r.size * s * 0.5, {255, 215, 0, 255})
      append(&commands, render.DrawMeshCommand{r.pos * s, vertices, indices, render.NO_TEXTURE, i32(z), clip})
    }
    n := ui.node(&app.gui, h)
    for line in ui.lines(&app.gui, h) {
      glyphs := make([dynamic]font.Glyph, context.temp_allocator)
      font.glyphs(&app.font, n.text[line.start:line.end], line.pos * s, n.font_size * s, &glyphs)
      append(&commands, render.DrawTextCommand{glyphs[:], TEXT_COLOR, i32(z), clip})
    }
  }
  pixels, atlas_size, changed := font.atlas(&app.font)
  render.stage_overlay(&app.renderer, {commands = commands[:], atlas = pixels if changed else nil, atlas_size = atlas_size})
  return render.frame(&app.renderer, platform.framebuffer_size(&app.window), s)
}

// A five-pointed star filling a box of half extent `r`, centered in it.
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

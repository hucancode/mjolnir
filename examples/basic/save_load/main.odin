// Save and load: click the ground to place boxes; S saves them to boxes.json, L loads it back, C clears.
package main

import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:math/linalg"
import "mjolnir"
import "mjolnir/font"
import "mjolnir/geometry"
import "mjolnir/input"
import "mjolnir/platform"
import "mjolnir/render"
import "mjolnir/world"

SAVE_PATH :: "boxes.json"

Save :: struct {
  boxes: [dynamic][3]f32,
}

App :: struct {
  platform: platform.Platform,
  scene:    world.World,
  renderer: render.Renderer,
  input:    input.State,
  font:     font.Font,
  orbit:    render.Orbit,
  save:     Save,
  nodes:    [dynamic]world.NodeHandle,
  status:   string,
  text:     [64]u8,
}

main :: proc() {
  context.logger = log.create_console_logger()
  app := new(App)
  if !platform.init(&app.platform, 1280, 720, "Save and load") do return
  if !render.init(&app.renderer, app.platform.window) do return
  if !world.init(&app.scene) do return
  mjolnir.run(
    mjolnir.Loop(App) {
      app = app,
      setup = setup,
      shutdown = shutdown,
      update = update,
      render = draw,
    },
  )
}

setup :: proc(app: ^App) -> mjolnir.Setup {
  if !render.ready(&app.renderer) do return .WAIT
  sun := render.light_create(&app.renderer, render.make_directional_light())
  mjolnir.spawn(&app.scene, &app.renderer, sun, rotation = linalg.quaternion_from_forward_and_up([3]f32{-0.4, -1, -0.3}, [3]f32{0, 1, 0}))
  if !font.init(&app.font, #load("assets/Outfit-Regular.ttf")) do return .FAIL
  r := &app.renderer
  mjolnir.spawn(&app.scene, r, render.primitive(r, .QUAD_XZ, .GRAY, no_shadow = true), scale = 20)
  app.orbit = render.make_orbit({0, 10, 12}, {})
  app.status = "click to place boxes"
  return .READY
}

shutdown :: proc(app: ^App) {
  delete(app.save.boxes)
  delete(app.nodes)
  font.destroy(&app.font)
  world.shutdown(&app.scene)
  render.shutdown(&app.renderer)
  platform.shutdown(&app.platform)
  free(app)
}

place :: proc(app: ^App, position: [3]f32) {
  append(&app.save.boxes, position)
  append(&app.nodes, mjolnir.spawn(&app.scene, &app.renderer, render.primitive(&app.renderer, .CUBE, .CYAN), position + {0, 0.5, 0}))
}

clear_boxes :: proc(app: ^App) {
  for n in app.nodes do world.destroy(&app.scene, n)
  clear(&app.nodes)
  clear(&app.save.boxes)
}

save :: proc(app: ^App) {
  data, err := json.marshal(app.save, allocator = context.temp_allocator)
  if err != nil || !platform.write_file(SAVE_PATH, data) {
    app.status = "save failed"
    return
  }
  app.status = fmt.bprintf(app.text[:], "saved %d boxes", len(app.save.boxes))
}

load :: proc(app: ^App) {
  data, ok := platform.read_file(SAVE_PATH, context.temp_allocator)
  loaded: Save
  if !ok || json.unmarshal(data, &loaded, allocator = context.temp_allocator) != nil {
    app.status = "nothing to load"
    return
  }
  clear_boxes(app)
  for p in loaded.boxes do place(app, p)
  app.status = fmt.bprintf(app.text[:], "loaded %d boxes", len(loaded.boxes))
}

update :: proc(app: ^App, dt: f32) {
  render.lock(&app.renderer)
  platform.read_input(&app.platform, &app.input)
  mjolnir.orbit_drag(&app.orbit, render.main_camera(&app.renderer), &app.input, rotate_with = {.RIGHT})
  if input.mouse_pressed(&app.input, .LEFT) {
    if ray, ok := render.cursor_ray(&app.renderer, app.input.cursor); ok {
      if at, hit := geometry.ray_plane_intersection(ray, {}, {0, 1, 0}); hit do place(app, at)
    }
  }
  if input.key_pressed(&app.input, .S) do save(app)
  if input.key_pressed(&app.input, .L) do load(app)
  if input.key_pressed(&app.input, .C) do clear_boxes(app)
  hud := [?]render.OverlayCommand {
    {shape = render.OverlayText{text = fmt.tprintf("%d boxes: %s", len(app.nodes), app.status), position = {20, 20}, size = 24, color = 255}},
    {shape = render.OverlayText{text = "left click: place   right drag: turn   S: save   L: load   C: clear", position = {20, 54}, size = 18, color = {200, 200, 200, 255}}},
  }
  render.stage_overlay(&app.renderer, hud[:], &app.font)
  mjolnir.update(&app.scene, &app.renderer, dt)
}

draw :: proc(app: ^App) -> bool {
  return mjolnir.frame(&app.platform, &app.renderer)
}

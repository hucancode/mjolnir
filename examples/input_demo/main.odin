// Keyboard, mouse, scroll event plumbing.
package main

import "../../mjolnir"
import "../../mjolnir/debugui"
import "../../mjolnir/input"
import "../../mjolnir/platform"
import "../../mjolnir/render"
import "../../mjolnir/world"
import "core:fmt"
import "core:log"
import mu "vendor:microui"

Seen :: struct {
  key:            Maybe(input.Key),
  key_pressed:    bool,
  button:         input.MouseButton,
  button_pressed: bool,
  scroll:         [2]f32,
  cursor:         [2]f32,
  drag:           [2]f32,
  dragging:       bool,
  text:           [64]u8,
  text_len:       int,
}

App :: struct {
  window:   platform.Platform,
  scene:    world.World,
  renderer: render.Renderer,
  debug:    debugui.Context,
  input:    input.State,
  orbit:    render.Orbit,
  cube:     world.NodeHandle,
  cube_pos: [3]f32,
  cube_yaw: f32,
  light:    render.LightHandle,
  seen:     Seen,
}

move_speed: mu.Real = 4.0
light_intensity: mu.Real = 4.0

main :: proc() {
  context.logger = log.create_console_logger()
  app := new(App)
  w := &app.window
  if !platform.init(w, 1000, 700, "Input") do return
  if !render.init(&app.renderer, "Input", w.window, platform.framebuffer_size(w), platform.dpi_scale(w)) do return
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

should_close :: proc(app: ^App) -> bool {
  return platform.should_close(&app.window)
}

setup :: proc(app: ^App) -> bool {
  if !render.ready(&app.renderer) do return false
  if !debugui.init(&app.debug, &app.renderer) do return false
  render.environment_map_load(&app.renderer, #load("../../assets/Cannon_Exterior.hdr"))
  render.camera_look_at(render.main_camera(&app.renderer), {0, 8, 12}, {0, 0.5, 0})
  app.orbit = render.orbit_from_camera(render.main_camera(&app.renderer), {0, 0.5, 0})

  app.light = render.light_create(&app.renderer, render.make_directional_light({1, 0.97, 0.92}, f32(light_intensity), 15.0))
  sun := world.spawn(&app.scene, {4, 8, 4})
  render.attach(&app.renderer, render.SlotHandle(sun.index), app.light)

  ground := world.spawn(&app.scene)
  render.attach(&app.renderer, render.SlotHandle(ground.index), render.primitive(&app.renderer, .QUAD_XZ, .GRAY, cast_shadow = false))
  world.scale(&app.scene, ground, 8.0)

  app.cube_pos = {0, 0.5, 0}
  app.cube = world.spawn(&app.scene, app.cube_pos)
  render.attach(&app.renderer, render.SlotHandle(app.cube.index), render.primitive(&app.renderer, .CUBE, .CYAN))
  world.scale(&app.scene, app.cube, 0.5)
  log.info("Input demo  WASD: move cube  Q/E: yaw  LMB drag, RMB, scroll, typing read from the input snapshot")
  return true
}

shutdown :: proc(app: ^App) {
  world.shutdown(&app.scene)
  debugui.shutdown(&app.debug)
  render.shutdown(&app.renderer)
  platform.shutdown(&app.window)
  free(app)
}

record_input :: proc(app: ^App) {
  inp := &app.input
  seen := &app.seen
  if !inp.keyboard_captured {
    it := 0
    for key, pressed in input.next_key_edge(inp, &it) {
      seen.key, seen.key_pressed = key, pressed
    }
    if t := input.text(inp); len(t) > 0 do seen.text_len = copy(seen.text[:], t)
  }
  seen.cursor = inp.cursor
  if !inp.mouse_captured {
    for b in input.MouseButton {
      if input.mouse_pressed(inp, b) {
        seen.button, seen.button_pressed = b, true
        if b == .LEFT do seen.dragging = true
      }
      if input.mouse_released(inp, b) do seen.button, seen.button_pressed = b, false
    }
    if inp.scroll != {} {
      seen.scroll = inp.scroll
      light_intensity = clamp(light_intensity + mu.Real(inp.scroll.y) * 0.5, 0.0, 20.0)
    }
  }
  if !input.mouse_down(inp, .LEFT) do seen.dragging = false
  seen.drag = inp.mouse_delta if seen.dragging else {}
}

update :: proc(app: ^App, dt: f32) {
  platform.read_input(&app.window, &app.input)
  debugui.feed(&app.debug, &app.input)
  if !app.input.mouse_captured {
    drag := app.input.mouse_delta if input.mouse_down(&app.input, .LEFT) else 0
    render.orbit_drag(&app.orbit, drag, 0)
  }
  render.camera_orbit(render.main_camera(&app.renderer), app.orbit)
  record_input(app)
  if !app.input.keyboard_captured {
    step := f32(move_speed) * dt
    app.cube_pos.x = clamp(app.cube_pos.x + input.axis(&app.input, .A, .D) * step, -7.5, 7.5)
    app.cube_pos.z = clamp(app.cube_pos.z + input.axis(&app.input, .W, .S) * step, -7.5, 7.5)
    app.cube_yaw += input.axis(&app.input, .E, .Q) * dt * 2.0
  }
  world.translate(&app.scene, app.cube, app.cube_pos)
  world.rotate(&app.scene, app.cube, app.cube_yaw)
  render.light(&app.renderer, app.light).intensity = f32(light_intensity)
  world.update(&app.scene)
  render.stage_transforms(&app.renderer, world.changes(&app.scene))
  render.update(&app.renderer, dt)
}

frame :: proc(app: ^App) -> bool {
  platform.poll_events(&app.window)
  debug_ui(app)
  render.stage_overlay(&app.renderer, {commands = debugui.end(&app.debug, platform.dpi_scale(&app.window))})
  return render.frame(&app.renderer, platform.framebuffer_size(&app.window), platform.dpi_scale(&app.window))
}

debug_ui :: proc(app: ^App) {
  seen := &app.seen
  ctx := debugui.begin(&app.debug)
  if mu.window(ctx, "Input", {700, 20, 280, 400}, {.NO_CLOSE}) {
    mu.layout_row(ctx, {-1}, 0)
    mu.label(ctx, "WASD move, Q/E yaw")
    mu.label(ctx, fmt.tprintf("Last key: %v %v", seen.key, "PRESS" if seen.key_pressed else "RELEASE"))
    mu.label(ctx, fmt.tprintf("Typed: %s", string(seen.text[:seen.text_len])))
    mu.label(ctx, "Move speed")
    mu.slider(ctx, &move_speed, 0.5, 20.0)
    mu.label(ctx, fmt.tprintf("Mouse: %.0f %.0f", seen.cursor.x, seen.cursor.y))
    mu.label(ctx, fmt.tprintf("Drag delta: %.1f %.1f", seen.drag.x, seen.drag.y))
    mu.label(ctx, fmt.tprintf("Last mouse button: %v %v", seen.button, "PRESS" if seen.button_pressed else "RELEASE"))
    mu.label(ctx, fmt.tprintf("Scroll: %.1f %.1f", seen.scroll.x, seen.scroll.y))
    mu.label(ctx, "Light (Scroll to adjust):")
    mu.slider(ctx, &light_intensity, 0.0, 20.0)
  }
}

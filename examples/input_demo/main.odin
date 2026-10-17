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

App :: struct {
  window:   platform.Platform,
  scene:    world.World,
  renderer: render.Renderer,
  debug:    debugui.Context,
  input:    input.State,
  // orbit controller state, owned by the app
  yaw, pitch, dist: f32,
}

cube_handle: world.NodeHandle
light_handle: world.NodeHandle
cube_pos: [3]f32 = {0, 0.5, 0}
cube_yaw: f32

last_key: input.Key
last_key_pressed: bool
last_button: input.MouseButton
last_button_pressed: bool
last_scroll: [2]f32
last_mouse: [2]f32
last_drag: [2]f32
lmb_down: bool
last_text: [64]u8
last_text_len: int
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

// On the web the renderer's device arrives after main returns: build the scene once it is up.
setup :: proc(app: ^App) -> bool {
  if !render.ready(&app.renderer) do return false
  if !debugui.init(&app.debug, &app.renderer) do return false
  render.environment_map_load(&app.renderer, #load("../../assets/Cannon_Exterior.hdr"))
  render.camera_look_at(render.main_camera(&app.renderer), {0, 8, 12}, {0, 0.5, 0})
  app.yaw, app.pitch, app.dist = render.camera_orbit_state(render.main_camera(&app.renderer))

  light_handle = world.spawn(&app.scene, {4, 8, 4})
  render.attach(&app.renderer, render.SlotHandle(light_handle.index), render.light_create(&app.renderer, render.make_directional_light({1, 0.97, 0.92, f32(light_intensity)}, 15.0, true)))

  ground := world.spawn(&app.scene)
  render.attach(&app.renderer, render.SlotHandle(ground.index), render.primitive(&app.renderer, .QUAD_XZ, .GRAY, cast_shadow = false))
  world.scale(&app.scene, ground, 8.0)

  cube_handle = world.spawn(&app.scene, cube_pos)
  render.attach(&app.renderer, render.SlotHandle(cube_handle.index), render.primitive(&app.renderer, .CUBE, .CYAN))
  world.scale(&app.scene, cube_handle, 0.5)
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

// Track the latest edges from this tick's input snapshot, skipping devices
// the debug UI owns.
read_input :: proc(app: ^App) {
  inp := &app.input
  if !app.input.keyboard_captured {
    it := 0
    for key, pressed in input.next_key_edge(inp, &it) {
      last_key = key; last_key_pressed = pressed
    }
    if t := input.text(inp); len(t) > 0 {
      last_text_len = copy(last_text[:], t)
    }
  }
  last_mouse = inp.cursor
  if !app.input.mouse_captured {
    for b in input.MouseButton {
      if input.mouse_pressed(inp, b) {
        last_button = b; last_button_pressed = true
        if b == .LEFT do lmb_down = true
      }
      if input.mouse_released(inp, b) {
        last_button = b; last_button_pressed = false
      }
    }
    if s := inp.scroll; s != {} {
      last_scroll = s
      light_intensity = clamp(light_intensity + mu.Real(s.y) * 0.5, 0.0, 20.0)
    }
  }
  if !input.mouse_down(inp, .LEFT) do lmb_down = false
  last_drag = inp.mouse_delta if lmb_down else {}
}

update :: proc(app: ^App, dt: f32) {
  platform.read_input(&app.window, &app.input)
  debugui.feed(&app.debug, &app.input)
  if !app.input.mouse_captured {
    if input.mouse_down(&app.input, .LEFT) {
      app.yaw += app.input.mouse_delta.x * 0.02
      app.pitch = clamp(app.pitch + app.input.mouse_delta.y * 0.02, -1.5, 1.5)
    }
    app.dist = clamp(app.dist - app.input.scroll.y * 2, 1, 200)
  }
  render.camera_orbit(render.main_camera(&app.renderer), app.yaw, app.pitch, app.dist)
  read_input(app)
  move := [3]f32{0, 0, 0}
  if !app.input.keyboard_captured {
    move.x = input.axis(&app.input, .A, .D)
    move.z = input.axis(&app.input, .W, .S)
    cube_yaw += input.axis(&app.input, .E, .Q) * dt * 2.0
  }
  if move.x != 0 || move.z != 0 {
    speed := f32(move_speed) * dt
    cube_pos.x = clamp(cube_pos.x + move.x * speed, -7.5, 7.5)
    cube_pos.z = clamp(cube_pos.z + move.z * speed, -7.5, 7.5)
  }
  world.translate(&app.scene, cube_handle, cube_pos)
  world.rotate(&app.scene, cube_handle, cube_yaw)
  if l, ok := render.light(&app.renderer, render.attachment(&app.renderer, render.SlotHandle(light_handle.index), render.LightHandle)); ok {
    l.color[3] = f32(light_intensity)
  }
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
  ctx := debugui.begin(&app.debug)
  if mu.window(ctx, "Input", {700, 20, 200, 300}, {.NO_CLOSE}) {
    mu.label(ctx, "WASD move, Q/E yaw")
    mu.label(ctx, fmt.tprintf("Last key: %v %v", last_key, "PRESS" if last_key_pressed else "RELEASE"))
    mu.label(ctx, fmt.tprintf("Typed: %s", string(last_text[:last_text_len])))
    mu.label(ctx, "Move speed")
    mu.slider(ctx, &move_speed, 0.5, 20.0)
    mu.label(ctx, fmt.tprintf("Mouse: %.0f %.0f", last_mouse.x, last_mouse.y))
    mu.label(ctx, fmt.tprintf("Drag delta: %.1f %.1f", last_drag.x, last_drag.y))
    mu.label(ctx, fmt.tprintf("Last mouse button: %v %v", last_button, "PRESS" if last_button_pressed else "RELEASE"))
    mu.label(ctx, fmt.tprintf("Scroll: %.1f %.1f", last_scroll.x, last_scroll.y))
    mu.label(ctx, "Light (Scroll to adjust):")
    mu.slider(ctx, &light_intensity, 0.0, 20.0)
  }
}

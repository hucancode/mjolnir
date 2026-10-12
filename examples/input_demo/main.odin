package main

import "../../mjolnir"
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
  input:    input.State,
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
  defer free(app)
  w := &app.window
  if !platform.init(w, 1000, 700, "Input") do return
  defer platform.shutdown(w)
  if !render.init(&app.renderer, "Input", platform.vulkan_instance_extensions(), platform.vulkan_get_instance_proc_addr(), platform.create_surface, w, platform.framebuffer_size(w), platform.dpi_scale(w)) do return
  defer render.shutdown(&app.renderer)
  if !world.init(&app.scene) do return
  defer world.shutdown(&app.scene)
  render.load_environment_map(&app.renderer, "assets/Cannon_Exterior.hdr")
  setup(app)
  mjolnir.run(mjolnir.Loop(App){app = app, should_close = should_close, update = update, frame = frame})
}

should_close :: proc(app: ^App) -> bool {
  return platform.should_close(&app.window)
}

setup :: proc(app: ^App) {
  render.main_camera_look_at(&app.renderer, {0, 8, 12}, {0, 0.5, 0})

  light_handle = world.spawn(&app.scene, {4, 8, 4})
  render.attach(&app.renderer, light_handle.index, render.directional_light_attachment({1, 0.97, 0.92, f32(light_intensity)}, 15.0, true))

  ground := world.spawn(&app.scene)
  render.attach(&app.renderer, ground.index, render.primitive(&app.renderer, .QUAD_XZ, .GRAY, cast_shadow = false))
  world.scale(&app.scene, ground, 8.0)

  cube_handle = world.spawn(&app.scene, cube_pos)
  render.attach(&app.renderer, cube_handle.index, render.primitive(&app.renderer, .CUBE, .CYAN))
  world.scale(&app.scene, cube_handle, 0.5)
  log.info("Input demo  WASD: move cube  Q/E: yaw  LMB drag, RMB, scroll, typing read from the input snapshot")
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
  last_mouse = input.cursor(inp)
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
    if s := input.scroll(inp); s != {} {
      last_scroll = s
      light_intensity = clamp(light_intensity + mu.Real(s.y) * 0.5, 0.0, 20.0)
    }
  }
  if !input.mouse_down(inp, .LEFT) do lmb_down = false
  last_drag = input.mouse_delta(inp) if lmb_down else {}
}

update :: proc(app: ^App, dt: f32) {
  platform.read_input(&app.window, &app.input)
  render.debug_ui_input(&app.renderer, &app.input)
  if cam, ok := render.main_camera(&app.renderer); ok && !app.input.mouse_captured {
    yaw, pitch, dist := render.camera_orbit_state(cam)
    if input.mouse_down(&app.input, .LEFT) {
      yaw += app.input.mouse_delta.x * 0.02
      pitch = clamp(pitch + app.input.mouse_delta.y * 0.02, -1.5, 1.5)
    }
    render.camera_orbit(cam, yaw, pitch, clamp(dist - app.input.scroll.y * 2, 1, 200))
  }
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
  if l, ok := render.attachment(&app.renderer, light_handle.index, render.Light); ok {
    l.color[3] = f32(light_intensity)
    render.attach(&app.renderer, light_handle.index, l)
  }
  world.update(&app.scene)
  for i in world.removed_nodes(&app.scene) do render.stage_slot_removal(&app.renderer, i)
  render.stage_transforms(&app.renderer, world.changed_nodes(&app.scene))
  render.update(&app.renderer, dt)
}

frame :: proc(app: ^App) -> bool {
  platform.poll_events(&app.window)
  debug_ui(app)
  return render.frame(&app.renderer, platform.framebuffer_size(&app.window), platform.dpi_scale(&app.window))
}

debug_ui :: proc(app: ^App) {
  ctx := render.debug_ui(&app.renderer)
  if mu.window(ctx, "Input", {700, 20, 200, 300}, {.NO_CLOSE}) {
    mu.label(ctx, "WASD move, Q/E yaw")
    mu.label(ctx, fmt.tprintf("Last key: %v %v", last_key, "PRESS" if last_key_pressed else "RELEASE"))
    mu.label(ctx, fmt.tprintf("Typed: %s", string(last_text[:last_text_len])))
    mu.label(ctx, fmt.tprintf("Move speed: %.1f", move_speed))
    mu.slider(ctx, &move_speed, 0.5, 20.0)
    mu.label(ctx, fmt.tprintf("Mouse: %.0f %.0f", last_mouse.x, last_mouse.y))
    mu.label(ctx, fmt.tprintf("Drag delta: %.1f %.1f", last_drag.x, last_drag.y))
    mu.label(ctx, fmt.tprintf("Last mouse button: %v %v", last_button, "PRESS" if last_button_pressed else "RELEASE"))
    mu.label(ctx, fmt.tprintf("Scroll: %.1f %.1f", last_scroll.x, last_scroll.y))
    mu.label(ctx, "Light (Scroll to adjust):")
    mu.slider(ctx, &light_intensity, 0.0, 20.0)
  }
}

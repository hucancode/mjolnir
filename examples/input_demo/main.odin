package main

import "../../mjolnir"
import "../../mjolnir/platform"
import "../../mjolnir/render"
import "../../mjolnir/world"
import "core:fmt"
import "core:log"
import mu "vendor:microui"

cube_handle: world.NodeHandle
light_handle: world.NodeHandle
cube_pos: [3]f32 = {0, 0.5, 0}
cube_yaw: f32

last_key: platform.Key
last_key_action: platform.Action
last_button: platform.MouseButton
last_button_action: platform.Action
last_scroll: [2]f64
last_mouse: [2]f64
last_drag: [2]f64
prev_mouse: [2]f64
lmb_down: bool
move_speed: mu.Real = 4.0
light_intensity: mu.Real = 4.0

main :: proc() {
  mjolnir.run_app({
    title        = "Input",
    width        = 1000,
    height       = 700,
    debug_ui     = true,
    setup        = setup,
    update       = update,
    pre_render   = debug_ui,
    key_press    = on_key,
    mouse_press  = on_mouse_button,
    mouse_move   = on_mouse_move,
    mouse_scroll = on_mouse_scroll,
  })
}

setup :: proc(engine: ^mjolnir.Engine) {
  engine.camera_controller = {}
  render.main_camera_look_at(&engine.render, {0, 8, 12}, {0, 0.5, 0})

  light_handle = mjolnir.spawn(engine, {4, 8, 4}, render.directional_light_attachment({1, 0.97, 0.92, f32(light_intensity)}, 15.0, true))

  mjolnir.spawn_ground(engine, 8.0)

  cube_handle = mjolnir.spawn_primitive_mesh(engine, .CUBE, .CYAN, position = cube_pos, scale_factor = 0.5)
  log.info("Input demo  WASD: move cube  Q/E: yaw  LMB drag, RMB, scroll, mouse-move hooked")
}

on_key :: proc(engine: ^mjolnir.Engine, key: platform.Key, action: platform.Action) {
  last_key = key; last_key_action = action
}

on_mouse_button :: proc(engine: ^mjolnir.Engine, button: platform.MouseButton, action: platform.Action) {
  last_button = button; last_button_action = action
  if button == .LEFT {
    if action == .PRESS {
      lmb_down = true; prev_mouse = last_mouse; last_drag = {0, 0}
    } else if action == .RELEASE {
      lmb_down = false; last_drag = {0, 0}
    }
  }
}

on_mouse_move :: proc(engine: ^mjolnir.Engine, pos, delta: [2]f64) {
  last_mouse = pos
  if lmb_down {
    last_drag = pos - prev_mouse
    prev_mouse = pos
  }
}

on_mouse_scroll :: proc(engine: ^mjolnir.Engine, offset: [2]f64) {
  last_scroll = offset
  light_intensity = clamp(light_intensity + mu.Real(offset.y) * 0.5, 0.0, 20.0)
}

update :: proc(engine: ^mjolnir.Engine, dt: f32) {
  move := [3]f32{0, 0, 0}
  if platform.input_key_down(&engine.platform.input, .W) do move.z -= 1
  if platform.input_key_down(&engine.platform.input, .S) do move.z += 1
  if platform.input_key_down(&engine.platform.input, .A) do move.x -= 1
  if platform.input_key_down(&engine.platform.input, .D) do move.x += 1
  if platform.input_key_down(&engine.platform.input, .Q) do cube_yaw += dt * 2.0
  if platform.input_key_down(&engine.platform.input, .E) do cube_yaw -= dt * 2.0
  if move.x != 0 || move.z != 0 {
    speed := f32(move_speed) * dt
    cube_pos.x = clamp(cube_pos.x + move.x * speed, -7.5, 7.5)
    cube_pos.z = clamp(cube_pos.z + move.z * speed, -7.5, 7.5)
  }
  world.translate(&engine.world, cube_handle, cube_pos)
  world.rotate(&engine.world, cube_handle, cube_yaw)
  render.set_light_intensity(&engine.render, light_handle.index, f32(light_intensity))
}

debug_ui :: proc(engine: ^mjolnir.Engine) {
  ctx := render.debug_ui(&engine.render)
  if mu.window(ctx, "Input", {700, 20, 200, 300}, {.NO_CLOSE}) {
    mu.label(ctx, "WASD move, Q/E yaw")
    mu.label(ctx, fmt.tprintf("Last key: %v %v", last_key, last_key_action))
    mu.label(ctx, fmt.tprintf("Move speed: %.1f", move_speed))
    mu.slider(ctx, &move_speed, 0.5, 20.0)
    mu.label(ctx, fmt.tprintf("Mouse: %.0f %.0f", last_mouse.x, last_mouse.y))
    mu.label(ctx, fmt.tprintf("Drag delta: %.1f %.1f", last_drag.x, last_drag.y))
    mu.label(ctx, fmt.tprintf("Last mouse button: %v %v", last_button, last_button_action))
    mu.label(ctx, fmt.tprintf("Scroll: %.1f %.1f", last_scroll.x, last_scroll.y))
    mu.label(ctx, "Light (Scroll to adjust):")
    mu.slider(ctx, &light_intensity, 0.0, 20.0)
  }
}

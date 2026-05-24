package main

import "../../mjolnir"
import "core:fmt"
import "core:log"
import "core:math"
import mu "vendor:microui"
import "vendor:glfw"

cube_handle: mjolnir.NodeHandle
light_handle: mjolnir.NodeHandle
cube_pos: [3]f32 = {0, 0.5, 0}
cube_yaw: f32

last_key, last_key_action: int
last_button, last_button_action: int
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
  engine.camera_controller_enabled = false
  mjolnir.main_camera_look_at(engine, {0, 8, 12}, {0, 0.5, 0})

  light_handle = mjolnir.spawn_light_directional(engine, {4, 8, 4}, {1, 0.97, 0.92, f32(light_intensity)}, 15.0, true)

  ground := mjolnir.spawn_primitive_mesh(engine, .QUAD_XZ, .GRAY, cast_shadow = false)
  mjolnir.scale(engine, ground, 8.0)

  cube_handle = mjolnir.spawn_primitive_mesh(engine, .CUBE, .CYAN, position = cube_pos, scale_factor = 0.5)
  log.info("Input demo  WASD: move cube  Q/E: yaw  LMB drag, RMB, scroll, mouse-move hooked")
}

on_key :: proc(engine: ^mjolnir.Engine, key, action, mods: int) {
  last_key = key; last_key_action = action
}

on_mouse_button :: proc(engine: ^mjolnir.Engine, key, action, mods: int) {
  last_button = key; last_button_action = action
  if key == int(glfw.MOUSE_BUTTON_LEFT) {
    if action == int(glfw.PRESS) {
      lmb_down = true; prev_mouse = last_mouse; last_drag = {0, 0}
    } else if action == int(glfw.RELEASE) {
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
  if mjolnir.is_key_down(engine, glfw.KEY_W) do move.z -= 1
  if mjolnir.is_key_down(engine, glfw.KEY_S) do move.z += 1
  if mjolnir.is_key_down(engine, glfw.KEY_A) do move.x -= 1
  if mjolnir.is_key_down(engine, glfw.KEY_D) do move.x += 1
  if mjolnir.is_key_down(engine, glfw.KEY_Q) do cube_yaw += dt * 2.0
  if mjolnir.is_key_down(engine, glfw.KEY_E) do cube_yaw -= dt * 2.0
  if move.x != 0 || move.z != 0 {
    speed := f32(move_speed) * dt
    cube_pos.x = clamp(cube_pos.x + move.x * speed, -7.5, 7.5)
    cube_pos.z = clamp(cube_pos.z + move.z * speed, -7.5, 7.5)
  }
  mjolnir.translate(engine, cube_handle, cube_pos)
  mjolnir.rotate(engine, cube_handle, quat_y(cube_yaw))
  mjolnir.set_light_intensity(engine, light_handle, f32(light_intensity))
}

quat_y :: proc(angle: f32) -> quaternion128 {
  half := angle * 0.5
  return quaternion(w = math.cos(half), x = 0, y = math.sin(half), z = 0)
}

debug_ui :: proc(engine: ^mjolnir.Engine) {
  ctx := mjolnir.ui_ctx(engine)
  if mu.window(ctx, "Input", {700, 20, 200, 300}, {.NO_CLOSE}) {
    mu.label(ctx, "WASD move, Q/E yaw")
    mu.label(ctx, fmt.tprintf("Last key: %d action %d", last_key, last_key_action))
    mu.label(ctx, fmt.tprintf("Move speed: %.1f", move_speed))
    mu.slider(ctx, &move_speed, 0.5, 20.0)
    mu.label(ctx, fmt.tprintf("Mouse: %.0f %.0f", last_mouse.x, last_mouse.y))
    mu.label(ctx, fmt.tprintf("Drag delta: %.1f %.1f", last_drag.x, last_drag.y))
    mu.label(ctx, fmt.tprintf("Last mouse button: %d action %d", last_button, last_button_action))
    mu.label(ctx, fmt.tprintf("Scroll: %.1f %.1f", last_scroll.x, last_scroll.y))
    mu.label(ctx, "Light (Scroll to adjust):")
    mu.slider(ctx, &light_intensity, 0.0, 20.0)
  }
}

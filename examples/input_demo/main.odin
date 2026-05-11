package main

import "../../mjolnir"
import "../../mjolnir/world"
import "core:fmt"
import "core:log"
import "core:math"
import mu "vendor:microui"
import "vendor:glfw"

cube_handle: world.NodeHandle
light_handle: world.NodeHandle
cube_pos: [3]f32 = {0, 0.5, 0}
cube_yaw: f32

last_key: int
last_key_action: int
last_button: int
last_button_action: int
last_scroll: [2]f64
last_mouse: [2]f64
last_drag: [2]f64
prev_mouse: [2]f64
lmb_down: bool
move_speed: mu.Real = 4.0
light_intensity: mu.Real = 4.0

main :: proc() {
  context.logger = log.create_console_logger()
  engine := new(mjolnir.Engine)
  engine.setup_proc = setup
  engine.update_proc = update
  engine.pre_render_proc = debug_ui
  engine.key_press_proc = on_key
  engine.mouse_press_proc = on_mouse_button
  engine.mouse_move_proc = on_mouse_move
  engine.mouse_scroll_proc = on_mouse_scroll
  mjolnir.run(engine, 1000, 700, "Input")
}

setup :: proc(engine: ^mjolnir.Engine) {
  engine.debug_ui_enabled = true
  engine.camera_controller_enabled = false
  world.main_camera_look_at(&engine.world, {0, 8, 12}, {0, 0.5, 0})

  light_handle =
    world.spawn(
      &engine.world,
      {4, 8, 4},
      world.create_directional_light_attachment(
        {1, 0.97, 0.92, f32(light_intensity)},
        15.0,
        true,
      ),
    ) or_else {}

  ground_mesh := world.get_builtin_mesh(&engine.world, .QUAD_XZ)
  ground_mat := world.get_builtin_material(&engine.world, .GRAY)
  ground :=
    world.spawn(
      &engine.world,
      {0, 0, 0},
      world.MeshAttachment {
        handle = ground_mesh,
        material = ground_mat,
        cast_shadow = false,
      },
    ) or_else {}
  world.scale(&engine.world, ground, 8.0)

  // Marker grid — orientation reference
  for x := -2; x <= 2; x += 1 {
    for z := -2; z <= 2; z += 1 {
      if x == 0 && z == 0 do continue
      world.spawn_primitive_mesh(
        &engine.world,
        .CUBE,
        .GRAY,
        position = {f32(x) * 2.0, 0.15, f32(z) * 2.0},
        scale_factor = 0.15,
      )
    }
  }

  cube_handle = world.spawn_primitive_mesh(
    &engine.world,
    .CUBE,
    .CYAN,
    position = cube_pos,
    scale_factor = 0.5,
  )

  log.info("=========================================")
  log.info("Input demo")
  log.info("  WASD : move cube")
  log.info("  Q/E  : yaw cube")
  log.info("  LMB drag, RMB, scroll, mouse-move all hooked")
  log.info("=========================================")
}

on_key :: proc(engine: ^mjolnir.Engine, key, action, mods: int) {
  last_key = key
  last_key_action = action
}

on_mouse_button :: proc(engine: ^mjolnir.Engine, key, action, mods: int) {
  last_button = key
  last_button_action = action
  if key == int(glfw.MOUSE_BUTTON_LEFT) {
    if action == int(glfw.PRESS) {
      lmb_down = true
      prev_mouse = last_mouse
      last_drag = {0, 0}
    } else if action == int(glfw.RELEASE) {
      lmb_down = false
      last_drag = {0, 0}
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
  // Wheel adjusts light intensity directly
  light_intensity = clamp(light_intensity + mu.Real(offset.y) * 0.5, 0.0, 20.0)
}

update :: proc(engine: ^mjolnir.Engine, delta_time: f32) {
  // WASD polling — engine.input.keys[] is unused, use glfw directly
  win := engine.window
  move := [3]f32{0, 0, 0}
  if glfw.GetKey(win, glfw.KEY_W) == glfw.PRESS do move.z -= 1
  if glfw.GetKey(win, glfw.KEY_S) == glfw.PRESS do move.z += 1
  if glfw.GetKey(win, glfw.KEY_A) == glfw.PRESS do move.x -= 1
  if glfw.GetKey(win, glfw.KEY_D) == glfw.PRESS do move.x += 1
  if glfw.GetKey(win, glfw.KEY_Q) == glfw.PRESS do cube_yaw += delta_time * 2.0
  if glfw.GetKey(win, glfw.KEY_E) == glfw.PRESS do cube_yaw -= delta_time * 2.0
  if move.x != 0 || move.z != 0 {
    speed := f32(move_speed) * delta_time
    cube_pos.x = clamp(cube_pos.x + move.x * speed, -7.5, 7.5)
    cube_pos.z = clamp(cube_pos.z + move.z * speed, -7.5, 7.5)
  }
  if cn, ok := world.node(&engine.world, cube_handle); ok {
    cn.transform.position = cube_pos
    cn.transform.rotation = quat_y(cube_yaw)
    cn.transform.is_dirty = true
  }

  // Apply light intensity slider/wheel
  if ln, ok := world.node(&engine.world, light_handle); ok {
    if att, ok := &ln.attachment.(world.DirectionalLightAttachment); ok {
      att.color.a = f32(light_intensity)
    }
    ln.transform.is_dirty = true
    world.stage_light_data(&engine.world.staging, light_handle)
  }
}

quat_y :: proc(angle: f32) -> quaternion128 {
  half := angle * 0.5
  return quaternion(w = math.cos(half), x = 0, y = math.sin(half), z = 0)
}

debug_ui :: proc(engine: ^mjolnir.Engine) {
  ctx := &engine.render.debug_ui.ctx
  if mu.window(ctx, "Input", {700, 20, 280, 460}, {.NO_CLOSE}) {
    mu.label(ctx, "--- Keyboard ---")
    mu.label(ctx, "WASD move, Q/E yaw")
    mu.label(ctx, fmt.tprintf("Last key: %d action %d", last_key, last_key_action))
    mu.label(ctx, fmt.tprintf("Move speed: %.1f", move_speed))
    mu.slider(ctx, &move_speed, 0.5, 20.0)

    mu.label(ctx, "")
    mu.label(ctx, "--- Mouse ---")
    mu.label(
      ctx,
      fmt.tprintf("Pos: %.0f %.0f", last_mouse.x, last_mouse.y),
    )
    mu.label(
      ctx,
      fmt.tprintf("Drag delta: %.1f %.1f", last_drag.x, last_drag.y),
    )
    mu.label(
      ctx,
      fmt.tprintf("Last btn: %d action %d", last_button, last_button_action),
    )
    mu.label(
      ctx,
      fmt.tprintf("Scroll: %.1f %.1f", last_scroll.x, last_scroll.y),
    )

    mu.label(ctx, "")
    mu.label(ctx, "--- Cube state ---")
    mu.label(
      ctx,
      fmt.tprintf("Pos: %.2f %.2f %.2f", cube_pos.x, cube_pos.y, cube_pos.z),
    )
    mu.label(ctx, fmt.tprintf("Yaw: %.2f rad", cube_yaw))

    mu.label(ctx, "")
    mu.label(ctx, fmt.tprintf("Light (wheel): %.1f", light_intensity))
    mu.slider(ctx, &light_intensity, 0.0, 20.0)
  }
}

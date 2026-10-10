package main

import "../../mjolnir"
import "../../mjolnir/input"
import "../../mjolnir/render"
import "../../mjolnir/world"
import "core:fmt"
import "core:log"
import mu "vendor:microui"

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
  mjolnir.run_app({
    title        = "Input",
    width        = 1000,
    height       = 700,
    debug_ui     = true,
    setup        = setup,
    update       = update,
    pre_render   = debug_ui,
  })
}

setup :: proc(engine: ^mjolnir.Engine) {
  engine.camera_controller = {}
  render.main_camera_look_at(&engine.render, {0, 8, 12}, {0, 0.5, 0})

  light_handle = mjolnir.spawn(engine, {4, 8, 4}, render.directional_light_attachment({1, 0.97, 0.92, f32(light_intensity)}, 15.0, true))

  mjolnir.spawn_ground(engine, 8.0)

  cube_handle = mjolnir.spawn_primitive_mesh(engine, .CUBE, .CYAN, position = cube_pos, scale_factor = 0.5)
  log.info("Input demo  WASD: move cube  Q/E: yaw  LMB drag, RMB, scroll, typing read from the input snapshot")
}

// Track the latest edges from this tick's input snapshot, skipping devices
// the debug UI owns.
read_input :: proc(engine: ^mjolnir.Engine) {
  inp := &engine.input
  if !engine.keyboard_captured {
    it := 0
    for key, pressed in input.next_key_edge(inp, &it) {
      last_key = key; last_key_pressed = pressed
    }
    if t := input.text(inp); len(t) > 0 {
      last_text_len = copy(last_text[:], t)
    }
  }
  last_mouse = input.cursor(inp)
  if !engine.mouse_captured {
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

update :: proc(engine: ^mjolnir.Engine, dt: f32) {
  read_input(engine)
  move := [3]f32{0, 0, 0}
  if !engine.keyboard_captured {
    move.x = input.axis(&engine.input, .A, .D)
    move.z = input.axis(&engine.input, .W, .S)
    cube_yaw += input.axis(&engine.input, .E, .Q) * dt * 2.0
  }
  if move.x != 0 || move.z != 0 {
    speed := f32(move_speed) * dt
    cube_pos.x = clamp(cube_pos.x + move.x * speed, -7.5, 7.5)
    cube_pos.z = clamp(cube_pos.z + move.z * speed, -7.5, 7.5)
  }
  world.translate(&engine.world, cube_handle, cube_pos)
  world.rotate(&engine.world, cube_handle, cube_yaw)
  if l, ok := render.attachment(&engine.render, light_handle.index, render.DirectionalLightAttachment); ok {
    l.color[3] = f32(light_intensity)
    render.mark_slot_dirty(&engine.render, light_handle.index)
  }
  world.update(&engine.world)
  for i in world.removed_nodes(&engine.world) do render.stage_slot_removal(&engine.render, i)
  for n in world.changed_nodes(&engine.world) do render.stage_transform(&engine.render, n.index, n.world_matrix, n.visible)
}

debug_ui :: proc(engine: ^mjolnir.Engine) {
  ctx := render.debug_ui(&engine.render)
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

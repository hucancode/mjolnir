package main

import "../../mjolnir"
import "../../mjolnir/physics"
import "core:fmt"
import "core:math/linalg"
import "vendor:glfw"
import mu "vendor:microui"

cube_handle: mjolnir.NodeHandle
cube_body: physics.DynamicRigidBodyHandle
time_since_jump: f32

jump_force: mu.Real = 1000.0
move_force: mu.Real = 20.0
jump_interval: mu.Real = 5.0
mass: mu.Real = 2.0
last_mass: mu.Real = 2.0

main :: proc() {
  mjolnir.run_app({
    title      = "Character Controller",
    width      = 1000, height = 700,
    debug_ui   = true,
    setup      = setup,
    update     = update,
    pre_render = debug_ui,
  })
}

setup :: proc(engine: ^mjolnir.Engine) {
  engine.physics.gravity = {0, -10, 0}
  mjolnir.spawn_static(engine, {0, -0.5, 0}, physics.BoxCollider{half_extents = {40.0, 0.5, 40.0}},
    mjolnir.builtin_mesh(engine, .CUBE), mjolnir.builtin_material(engine, .GRAY), visual_scale = {40.0, 0.5, 40.0})
  cube_handle, cube_body = mjolnir.spawn_dynamic(engine, {0, 3, 0}, f32(mass), physics.BoxCollider{half_extents = {0.5, 0.5, 0.5}},
    mjolnir.builtin_mesh(engine, .CUBE), mjolnir.builtin_material(engine, .CYAN))
  mjolnir.main_camera_look_at(engine, {8, 5, 8}, {0, 2, 0})
}

update :: proc(engine: ^mjolnir.Engine, dt: f32) {
  time_since_jump += dt
  body, ok := mjolnir.get_dynamic_body(engine, cube_body)
  if !ok do return
  if mass != last_mass {
    physics.set_mass(body, f32(mass))
    physics.set_box_inertia(body, {1, 1, 1})
    last_mass = mass
  }
  f := [3]f32{0, 0, 0}
  if engine.input.keys[glfw.KEY_W] do f.z -= f32(move_force)
  if engine.input.keys[glfw.KEY_S] do f.z += f32(move_force)
  if engine.input.keys[glfw.KEY_A] do f.x -= f32(move_force)
  if engine.input.keys[glfw.KEY_D] do f.x += f32(move_force)
  if linalg.length(f) > 0.1 do physics.apply_force(body, f)
  if time_since_jump >= f32(jump_interval) {
    time_since_jump = 0.0
    physics.apply_force(body, {0, f32(jump_force), 0})
  }
}

debug_ui :: proc(engine: ^mjolnir.Engine) {
  ctx := mjolnir.ui_ctx(engine)
  if mu.window(ctx, "Jump", {720, 20, 260, 280}, {.NO_CLOSE}) {
    mu.layout_row(ctx, {-1}, 0)
    mu.label(ctx, fmt.tprintf("Mass: %.1f kg", mass))
    mu.slider(ctx, &mass, 1.0, 100.0)
    mu.label(ctx, fmt.tprintf("Jump force: %.0f", jump_force))
    mu.slider(ctx, &jump_force, 50.0, 5000.0)
    mu.label(ctx, fmt.tprintf("Move force: %.1f", move_force))
    mu.slider(ctx, &move_force, 1.0, 200.0)
    mu.label(ctx, fmt.tprintf("Auto-jump interval: %.1f s", jump_interval))
    mu.slider(ctx, &jump_interval, 0.5, 10.0)
    mu.label(ctx, "")
    if .SUBMIT in mu.button(ctx, "Jump now") {
      if body, ok := mjolnir.get_dynamic_body(engine, cube_body); ok {
        physics.apply_force(body, {0, f32(jump_force), 0})
        time_since_jump = 0
      }
    }
    mu.label(ctx, "W/A/S/D moves the cube")
  }
}

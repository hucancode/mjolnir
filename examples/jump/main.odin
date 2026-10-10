package main

import "../../mjolnir"
import "../../mjolnir/platform"
import "../../mjolnir/render"
import "../../mjolnir/world"
import "../../mjolnir/physics"
import "core:fmt"
import "core:math/linalg"
import mu "vendor:microui"

cube_handle: world.NodeHandle
cube_body: physics.DynamicRigidBodyHandle
box_collider := physics.BoxCollider{half_extents = {0.5, 0.5, 0.5}}
time_since_jump: f32

jump_force: mu.Real = 20.0
move_force: mu.Real = 20.0
jump_interval: mu.Real = 5.0
mass: mu.Real = 2.0
last_mass: mu.Real = 2.0
auto_jump: bool = true

phys: physics.World

main :: proc() {
  physics.init(&phys)
  defer physics.shutdown(&phys)
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
  phys.gravity = {0, -10, 0}
  mjolnir.spawn_static(engine, &phys, {0, -0.5, 0}, physics.BoxCollider{half_extents = {40.0, 0.5, 40.0}},
    render.get_builtin_mesh(&engine.render, .CUBE), render.get_builtin_material(&engine.render, .GRAY))
  cube_handle, cube_body = mjolnir.spawn_dynamic(engine, &phys, {0, 3, 0}, f32(mass), box_collider,
    render.get_builtin_mesh(&engine.render, .CUBE), render.get_builtin_material(&engine.render, .CYAN))
  render.main_camera_look_at(&engine.render, {8, 5, 8}, {0, 2, 0})
}

update :: proc(engine: ^mjolnir.Engine, dt: f32) {
  time_since_jump += dt
  if mass != last_mass {
    if b, ok := physics.get_dynamic_body(&phys, cube_body); ok {
      physics.set_mass(b, f32(mass))
      physics.set_inertia_from_collider(b, box_collider)
    }
    last_mass = mass
  }
  f := [3]f32{0, 0, 0}
  if platform.input_key_down(&engine.platform.input, .W) do f.z -= f32(move_force)
  if platform.input_key_down(&engine.platform.input, .S) do f.z += f32(move_force)
  if platform.input_key_down(&engine.platform.input, .A) do f.x -= f32(move_force)
  if platform.input_key_down(&engine.platform.input, .D) do f.x += f32(move_force)
  if b, ok := physics.get_dynamic_body(&phys, cube_body); ok {
    if linalg.length(f) > 0.1 do physics.apply_force(b, f)
    if platform.input_key_pressed(&engine.platform.input, .SPACE) {
      physics.apply_impulse(b, {0, f32(jump_force), 0})
      time_since_jump = 0.0
    }
    if auto_jump && time_since_jump >= f32(jump_interval) {
      time_since_jump = 0.0
      physics.apply_impulse(b, {0, f32(jump_force), 0})
    }
  }
  physics.step(&phys, dt)
  for b in physics.body_poses(&phys) do world.set_world_pose(&engine.world, world.NodeHandle(b.user), b.position, b.rotation)
}

debug_ui :: proc(engine: ^mjolnir.Engine) {
  ctx := render.debug_ui(&engine.render)
  if mu.window(ctx, "Jump", {720, 20, 260, 350}, {.NO_CLOSE}) {
    mu.layout_row(ctx, {-1}, 0)
    mu.label(ctx, fmt.tprintf("Mass: %.1f kg", mass))
    mu.slider(ctx, &mass, 1.0, 10.0)
    mu.label(ctx, fmt.tprintf("Jump force: %.0f", jump_force))
    mu.slider(ctx, &jump_force, 5.0, 50.0)
    mu.label(ctx, fmt.tprintf("Move force: %.1f", move_force))
    mu.slider(ctx, &move_force, 1.0, 20.0)
    mu.checkbox(ctx, "Auto-jump", &auto_jump)
    mu.label(ctx, fmt.tprintf("Auto-jump interval: %.1f s", jump_interval))
    mu.slider(ctx, &jump_interval, 0.5, 10.0)
    mu.label(ctx, "")
    if .SUBMIT in mu.button(ctx, "Jump now") {
      if b, ok := physics.get_dynamic_body(&phys, cube_body); ok {
        physics.apply_impulse(b, {0, f32(jump_force), 0})
      }
      time_since_jump = 0
    }
    mu.label(ctx, "W/A/S/D moves, Space jumps")
  }
}

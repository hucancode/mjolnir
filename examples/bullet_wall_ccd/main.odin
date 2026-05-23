package main

import "../../mjolnir"
import "../../mjolnir/physics"
import "core:fmt"
import "core:log"
import "core:math/linalg"
import mu "vendor:microui"

WALL_COUNT :: 3
WALL_X :: f32(0.0)
wall_heights := [3]f32{0.05, 0.2, 0.8}
WALL_SPACING :: f32(5.0)
BULLET_RADIUS :: f32(0.15)
BULLET_MASS :: f32(0.05)
START_POS :: [3]f32{-15.0, 1.5, 0.0}

bullet_body: physics.DynamicRigidBodyHandle
bullet_node: mjolnir.NodeHandle
wall_nodes: [WALL_COUNT]mjolnir.NodeHandle
target_wall: i32 = 1
bullet_speed: mu.Real = 60.0
auto_fire: bool = false
auto_fire_timer: f32

main :: proc() {
  mjolnir.run_app({
    title      = "Bullet vs Thin Wall (CCD)",
    width      = 1000,
    height     = 700,
    debug_ui   = true,
    setup      = setup,
    update     = update,
    pre_render = debug_ui,
  })
}

setup :: proc(engine: ^mjolnir.Engine) {
  engine.physics.gravity = {0, 0, 0}
  mjolnir.main_camera_look_at(engine, {-14, 8, 14}, {0, 1, 0})
  mjolnir.spawn_light_directional(engine, {-5, 12, 5}, {1, 0.95, 0.9, 1}, 6.0, true)

  cube_mesh := mjolnir.builtin_mesh(engine, .CUBE)
  mjolnir.spawn_static(engine, {0, -0.5, 0}, physics.BoxCollider{half_extents = {30.0, 0.5, 12.0}},
    cube_mesh, mjolnir.builtin_material(engine, .GRAY), visual_scale = {30.0, 0.5, 12.0})

  wall_colors := [WALL_COUNT]mjolnir.Color{.RED, .YELLOW, .GREEN}
  for i in 0 ..< WALL_COUNT {
    half_thick := wall_heights[i] * 0.5
    wall_z := (f32(i) - f32(WALL_COUNT - 1) * 0.5) * WALL_SPACING
    wall_nodes[i] = mjolnir.spawn_static(engine, {WALL_X, 1.5, wall_z}, physics.BoxCollider{half_extents = {half_thick, 1.5, 2.0}},
      cube_mesh, mjolnir.builtin_material(engine, wall_colors[i]), visual_scale = {half_thick, 1.5, 2.0})
  }

  bullet_node, bullet_body = mjolnir.spawn_dynamic(engine, START_POS, BULLET_MASS, physics.SphereCollider{radius = BULLET_RADIUS},
    mjolnir.builtin_mesh(engine, .SPHERE), mjolnir.builtin_material(engine, .CYAN), visual_scale = {BULLET_RADIUS, BULLET_RADIUS, BULLET_RADIUS})
  if body, ok := mjolnir.get_dynamic_body(engine, bullet_body); ok {
    body.linear_damping = 0; body.angular_damping = 0
    body.restitution = 0.1;  body.friction = 0.2
  }
}

target_z :: proc() -> f32 {
  return (f32(target_wall) - f32(WALL_COUNT - 1) * 0.5) * WALL_SPACING
}

fire_bullet :: proc(engine: ^mjolnir.Engine) {
  body, ok := mjolnir.get_dynamic_body(engine, bullet_body)
  if !ok do return
  body.position = {START_POS.x, START_POS.y, target_z()}
  body.velocity = {f32(bullet_speed), 0, 0}
  body.angular_velocity = {}
  body.force = {}; body.torque = {}
  body.is_sleeping = false; body.sleep_timer = 0
}

update :: proc(engine: ^mjolnir.Engine, dt: f32) {
  body, ok := mjolnir.get_dynamic_body(engine, bullet_body)
  if !ok do return
  if auto_fire {
    auto_fire_timer += dt
    if auto_fire_timer >= 2.0 { auto_fire_timer = 0; fire_bullet(engine) }
  }
  if body.position.x > 20.0 || body.position.x < -25.0 {
    body.velocity = {}
    body.position = {START_POS.x, START_POS.y, target_z()}
  }
}

debug_ui :: proc(engine: ^mjolnir.Engine) {
  ctx := mjolnir.ui_ctx(engine)
  if mu.window(ctx, "Bullet CCD", {700, 20, 280, 380}, {.NO_CLOSE}) {
    mu.layout_row(ctx, {-1}, 0)
    mu.label(ctx, "Target wall:")
    mu.layout_row(ctx, {90, 90, 90}, 0)
    if .SUBMIT in mu.button(ctx, "Red 0.05")   do target_wall = 0
    if .SUBMIT in mu.button(ctx, "Yellow 0.2") do target_wall = 1
    if .SUBMIT in mu.button(ctx, "Green 0.8")  do target_wall = 2

    mu.layout_row(ctx, {-1}, 0)
    mu.label(ctx, fmt.tprintf("Velocity: %.1f m/s", bullet_speed))
    mu.slider(ctx, &bullet_speed, 1.0, 400.0)
    mu.label(ctx, "CCD: ACTIVE (>=5 m/s threshold)" if bullet_speed >= 5.0 else "CCD: off (low velocity)")

    mu.layout_row(ctx, {130, -1}, 0)
    if .SUBMIT in mu.button(ctx, "Fire") do fire_bullet(engine)
    mu.checkbox(ctx, "Auto-fire (2s)", &auto_fire)

    mu.layout_row(ctx, {-1}, 0)
    mu.label(ctx, "--- Last Frame Stats ---")
    perf := engine.physics.last_perf
    mu.label(ctx, fmt.tprintf("CCD bodies tested: %d", perf.ccd_bodies_tested))
    mu.label(ctx, fmt.tprintf("CCD swept candidates: %d", perf.ccd_total_candidates))
    mu.label(ctx, fmt.tprintf("CCD time: %.3f ms", perf.ccd_ms))
    mu.label(ctx, fmt.tprintf("Static contacts: %d", perf.static_contact_count))
    if body, ok := mjolnir.get_dynamic_body(engine, bullet_body); ok {
      mu.label(ctx, fmt.tprintf("Bullet x: %.2f  vel: %.1f", body.position.x, linalg.length(body.velocity)))
    }
  }
}

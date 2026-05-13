package main

import "../../mjolnir"
import "../../mjolnir/physics"
import "../../mjolnir/world"
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
bullet_node: world.NodeHandle
wall_nodes: [WALL_COUNT]world.NodeHandle
target_wall: i32 = 1
bullet_speed: mu.Real = 60.0
auto_fire: bool = false
auto_fire_timer: f32

main :: proc() {
  context.logger = log.create_console_logger()
  engine := new(mjolnir.Engine)
  engine.setup_proc = setup
  engine.update_proc = update
  engine.pre_render_proc = debug_ui
  mjolnir.run(engine, 1000, 700, "Bullet vs Thin Wall (CCD)")
}

setup :: proc(engine: ^mjolnir.Engine) {
  engine.physics.gravity = {0, 0, 0}
  engine.debug_ui_enabled = true

  world.main_camera_look_at(&engine.world, {-14, 8, 14}, {0, 1, 0})

  world.spawn_light_directional(&engine.world, {-5, 12, 5}, {1, 0.95, 0.9, 1}, 6.0, true)

  ground_mesh := world.get_builtin_mesh(&engine.world, .CUBE)
  ground_mat := world.get_builtin_material(&engine.world, .GRAY)
  ground := world.spawn(&engine.world, {0, -0.5, 0}) or_else {}
  ground_node := world.node(&engine.world, ground)
  physics.create_static_body(
    &engine.physics,
    ground_node.transform.position,
    ground_node.transform.rotation,
    physics.BoxCollider{half_extents = {30.0, 0.5, 12.0}},
  )
  ground_mesh_node :=
    world.spawn_child(
      &engine.world,
      ground,
      attachment = world.MeshAttachment {
        handle = ground_mesh,
        material = ground_mat,
      },
    ) or_else {}
  world.scale_xyz(&engine.world, ground_mesh_node, 30.0, 0.5, 12.0)

  wall_mat_colors := [WALL_COUNT]world.Color{.RED, .YELLOW, .GREEN}
  for i in 0 ..< WALL_COUNT {
    half_thick := wall_heights[i] * 0.5
    wall_z := (f32(i) - f32(WALL_COUNT - 1) * 0.5) * WALL_SPACING
    cube_mesh := world.get_builtin_mesh(&engine.world, .CUBE)
    wall_mat := world.get_builtin_material(&engine.world, wall_mat_colors[i])
    wall := world.spawn(&engine.world, {WALL_X, 1.5, wall_z}) or_else {}
    wall_node := world.node(&engine.world, wall)
    physics.create_static_body(
      &engine.physics,
      wall_node.transform.position,
      wall_node.transform.rotation,
      physics.BoxCollider{half_extents = {half_thick, 1.5, 2.0}},
    )
    visual :=
      world.spawn_child(
        &engine.world,
        wall,
        attachment = world.MeshAttachment {
          handle = cube_mesh,
          material = wall_mat,
          cast_shadow = true,
        },
      ) or_else {}
    world.scale_xyz(&engine.world, visual, half_thick, 1.5, 2.0)
    wall_nodes[i] = wall
  }

  sphere_mesh := world.get_builtin_mesh(&engine.world, .SPHERE)
  sphere_mat := world.get_builtin_material(&engine.world, .CYAN)
  bullet_body = physics.create_dynamic_body(
    &engine.physics,
    START_POS,
    linalg.QUATERNIONF32_IDENTITY,
    BULLET_MASS,
    physics.SphereCollider{radius = BULLET_RADIUS},
  )
  if body, ok := physics.get_dynamic_body(&engine.physics, bullet_body); ok {
    physics.set_sphere_inertia(body, BULLET_RADIUS)
    body.linear_damping = 0.0
    body.angular_damping = 0.0
    body.restitution = 0.1
    body.friction = 0.2
  }
  bullet_node =
    world.spawn(
      &engine.world,
      START_POS,
      world.RigidBodyAttachment{body_handle = bullet_body},
    ) or_else {}
  visual :=
    world.spawn_child(
      &engine.world,
      bullet_node,
      attachment = world.MeshAttachment {
        handle = sphere_mesh,
        material = sphere_mat,
        cast_shadow = true,
      },
    ) or_else {}
  world.scale(&engine.world, visual, BULLET_RADIUS)

  log.info("=========================================")
  log.info("Bullet vs Thin Wall — CCD demo")
  log.info("  Walls: red=thin(0.05) yellow=mid(0.2) green=thick(0.8)")
  log.info("  Use debug UI to pick target, fire bullet")
  log.info("  CCD auto-engages above 5 m/s (engine threshold)")
  log.info("=========================================")
}

target_z :: proc() -> f32 {
  return (f32(target_wall) - f32(WALL_COUNT - 1) * 0.5) * WALL_SPACING
}

fire_bullet :: proc(engine: ^mjolnir.Engine) {
  body, ok := physics.get_dynamic_body(&engine.physics, bullet_body)
  if !ok do return
  body.position = {START_POS.x, START_POS.y, target_z()}
  body.velocity = {f32(bullet_speed), 0, 0}
  body.angular_velocity = {}
  body.force = {}
  body.torque = {}
  body.is_sleeping = false
  body.sleep_timer = 0
}

update :: proc(engine: ^mjolnir.Engine, delta_time: f32) {
  body, ok := physics.get_dynamic_body(&engine.physics, bullet_body)
  if !ok do return

  if auto_fire {
    auto_fire_timer += delta_time
    if auto_fire_timer >= 2.0 {
      auto_fire_timer = 0
      fire_bullet(engine)
    }
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
    if .SUBMIT in mu.button(ctx, "Red 0.05") do target_wall = 0
    if .SUBMIT in mu.button(ctx, "Yellow 0.2") do target_wall = 1
    if .SUBMIT in mu.button(ctx, "Green 0.8") do target_wall = 2

    mu.layout_row(ctx, {-1}, 0)
    mu.label(ctx, fmt.tprintf("Velocity: %.1f m/s", bullet_speed))
    mu.slider(ctx, &bullet_speed, 1.0, 400.0)

    mu.layout_row(ctx, {-1}, 0)
    ccd_active := bullet_speed >= 5.0
    if ccd_active {
      mu.label(ctx, "CCD: ACTIVE (>=5 m/s threshold)")
    } else {
      mu.label(ctx, "CCD: off (low velocity)")
    }

    mu.layout_row(ctx, {130, -1}, 0)
    if .SUBMIT in mu.button(ctx, "Fire") do fire_bullet(engine)
    mu.checkbox(ctx, "Auto-fire (2s)", &auto_fire)

    mu.layout_row(ctx, {-1}, 0)
    mu.label(ctx, "--- Last Frame Stats ---")
    perf := engine.physics.last_perf
    mu.label(ctx, fmt.tprintf("CCD bodies tested: %d", perf.ccd_bodies_tested))
    mu.label(
      ctx,
      fmt.tprintf("CCD swept candidates: %d", perf.ccd_total_candidates),
    )
    mu.label(ctx, fmt.tprintf("CCD time: %.3f ms", perf.ccd_ms))
    mu.label(
      ctx,
      fmt.tprintf("Static contacts: %d", perf.static_contact_count),
    )

    if body, ok := physics.get_dynamic_body(&engine.physics, bullet_body); ok {
      mu.label(
        ctx,
        fmt.tprintf("Bullet x: %.2f  vel: %.1f", body.position.x, linalg.length(body.velocity)),
      )
    }
  }
}

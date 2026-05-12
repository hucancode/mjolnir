package main

import "../../mjolnir"
import "../../mjolnir/world"
import "core:log"
import "core:math/linalg"

ff_handle: world.NodeHandle

main :: proc() {
  context.logger = log.create_console_logger()
  engine := new(mjolnir.Engine)
  engine.setup_proc = setup
  engine.update_proc = update
  mjolnir.run(engine, 800, 600, "Forcefield")
}

setup :: proc(engine: ^mjolnir.Engine) {
  world.main_camera_look_at(&engine.world, {0, 4, 9}, {0, 2, 0})

  ground := world.spawn_primitive_mesh(&engine.world, .QUAD_XZ, .GRAY, cast_shadow=false)
  world.scale(&engine.world, ground, 8.0)

  // Particle source at center, large position spread
  if tex, ok := mjolnir.create_texture(engine, "assets/gold-star.png"); ok {
    world.spawn_emitter(
      &engine.world,
      position          = {0, 2, 0},
      texture           = tex,
      emission_rate     = 60,
      initial_velocity  = {0, 0, 0},
      velocity_spread   = 0.05,
      color_start       = {1, 0.95, 0.4, 1},
      color_end         = {1, 0.2, 0, 0},
      aabb_min          = {-6, -6, -6},
      aabb_max          = {6, 6, 6},
      particle_lifetime = 4.0,
      position_spread   = 2.5,
      size_start        = 100,
      size_end          = 30,
      weight            = 0.0,
      weight_spread     = 0.0,
    )
  }

  // Orbiting forcefield: parent rotates, child has the field offset
  ff_handle = world.spawn(&engine.world, {0, 2, 0})
  child := world.spawn_forcefield(
    &engine.world,
    position         = {2.5, 0, 0},
    area_of_effect   = 4.0,
    strength         = -15.0,
    tangent_strength = 8.0,
  )
  world.attach(engine.world.nodes, ff_handle, child)

  // Visualize the field with a small sphere
  marker_mat := world.material_pbr(
    &engine.world,
    base_color = {0.2, 0.6, 1.0, 1},
    emissive   = 2.0,
    roughness  = 0.3,
  )
  world.spawn_child(
    &engine.world,
    child,
    attachment = world.mesh_attach(
      world.get_builtin_mesh(&engine.world, .SPHERE),
      marker_mat,
      cast_shadow = false,
    ),
  )

  world.spawn_light_directional(
    &engine.world,
    position = {3, 6, 3},
    color    = {1, 1, 1, 1},
    radius   = 10,
  )
}

update :: proc(engine: ^mjolnir.Engine, delta_time: f32) {
  t := mjolnir.time_since_start(engine)
  if n, ok := world.node(&engine.world, ff_handle); ok {
    world.rotate(&n.transform, t * 1.2, linalg.VECTOR3F32_Y_AXIS)
  }
}

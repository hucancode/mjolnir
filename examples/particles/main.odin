package main

import "../../mjolnir"
import "../../mjolnir/world"
import "core:log"

main :: proc() {
  context.logger = log.create_console_logger()
  engine := new(mjolnir.Engine)
  engine.setup_proc = setup
  mjolnir.run(engine, 800, 600, "Particles")
}

setup :: proc(engine: ^mjolnir.Engine) {
  world.main_camera_look_at(&engine.world, {0, 4, 12}, {0, 2, 0})

  ground := world.spawn_primitive_mesh(
    &engine.world,
    .QUAD_XZ,
    .GRAY,
    cast_shadow = false,
  )
  world.scale(&engine.world, ground, 8.0)

  // Spark fountain — gold star, upward
  if spark_tex, ok := mjolnir.create_texture(engine, "assets/gold-star.png"); ok {
    world.spawn_emitter(
      &engine.world,
      position          = {-1.5, 0.2, 0},
      texture           = spark_tex,
      emission_rate     = 200,
      initial_velocity  = {0, 3.0, 0},
      velocity_spread   = 1.5,
      color_start       = {1, 1, 0.4, 1},
      color_end         = {1, 0.2, 0, 0},
      aabb_min          = {-4, -4, -4},
      aabb_max          = {4, 6, 4},
      particle_lifetime = 2.0,
      position_spread   = 0.3,
      size_start        = 350,
      size_end          = 80,
      weight            = 1.5,
      weight_spread     = 0.3,
    )
  }

  // Smoke plume — black circle, slow rising
  if smoke_tex, ok := mjolnir.create_texture(engine, "assets/black-circle.png"); ok {
    world.spawn_emitter(
      &engine.world,
      position          = {1.5, 0.2, 0},
      texture           = smoke_tex,
      emission_rate     = 80,
      initial_velocity  = {0, 0.8, 0},
      velocity_spread   = 0.4,
      color_start       = {0.2, 0.2, 0.25, 0.8},
      color_end         = {0.05, 0.05, 0.08, 0},
      aabb_min          = {-4, -4, -4},
      aabb_max          = {4, 7, 4},
      particle_lifetime = 4.0,
      position_spread   = 0.4,
      size_start        = 250,
      size_end          = 700,
      weight            = 0.05,
      weight_spread     = 0.02,
    )
  }

  world.spawn_light_point(
    &engine.world,
    position    = {3, 5, 3},
    color       = {1, 0.9, 0.6, 1},
    radius      = 12,
    cast_shadow = false,
  )
}

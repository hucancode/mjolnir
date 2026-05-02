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

  plane := world.get_builtin_mesh(&engine.world, .QUAD_XZ)
  plane_mat := world.get_builtin_material(&engine.world, .GRAY)
  ground := world.spawn(
    &engine.world,
    {0, 0, 0},
    world.MeshAttachment{handle = plane, material = plane_mat, cast_shadow = false},
  ) or_else {}
  world.scale(&engine.world, ground, 8.0)

  // Spark fountain — gold star, upward
  spark_tex, spark_ok := mjolnir.create_texture(engine, "assets/gold-star.png")
  if spark_ok {
    spark_root := world.spawn(&engine.world, {-1.5, 0.2, 0})
    if emitter, ok := world.create_emitter(
      &engine.world,
      spark_root,
      texture_handle = spark_tex,
      emission_rate = 200,
      initial_velocity = {0, 3.0, 0},
      velocity_spread = 1.5,
      color_start = {1, 1, 0.4, 1},
      color_end = {1, 0.2, 0, 0},
      aabb_min = {-4, -4, -4},
      aabb_max = {4, 6, 4},
      particle_lifetime = 2.0,
      position_spread = 0.3,
      size_start = 350,
      size_end = 80,
      weight = 1.5,
      weight_spread = 0.3,
    ); ok {
      world.spawn_child(
        &engine.world,
        spark_root,
        attachment = world.EmitterAttachment{emitter},
      )
    }
  }

  // Smoke plume — black circle, slow rising
  smoke_tex, smoke_ok := mjolnir.create_texture(engine, "assets/black-circle.png")
  if smoke_ok {
    smoke_root := world.spawn(&engine.world, {1.5, 0.2, 0})
    if emitter, ok := world.create_emitter(
      &engine.world,
      smoke_root,
      texture_handle = smoke_tex,
      emission_rate = 80,
      initial_velocity = {0, 0.8, 0},
      velocity_spread = 0.4,
      color_start = {0.2, 0.2, 0.25, 0.8},
      color_end = {0.05, 0.05, 0.08, 0},
      aabb_min = {-4, -4, -4},
      aabb_max = {4, 7, 4},
      particle_lifetime = 4.0,
      position_spread = 0.4,
      size_start = 250,
      size_end = 700,
      weight = 0.05,
      weight_spread = 0.02,
    ); ok {
      world.spawn_child(
        &engine.world,
        smoke_root,
        attachment = world.EmitterAttachment{emitter},
      )
    }
  }

  world.spawn(
    &engine.world,
    {3, 5, 3},
    world.create_point_light_attachment({1, 0.9, 0.6, 1}, 12, false),
  )
}

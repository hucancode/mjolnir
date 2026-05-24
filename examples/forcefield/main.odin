package main

import "../../mjolnir"
import "../../mjolnir/world"
import "core:math/linalg"

ff_handle: mjolnir.NodeHandle

main :: proc() {
  mjolnir.run_app({title = "Forcefield", setup = setup, update = update})
}

setup :: proc(engine: ^mjolnir.Engine) {
  mjolnir.main_camera_look_at(engine, {0, 4, 9}, {0, 2, 0})

  ground := mjolnir.spawn_primitive_mesh(engine, .QUAD_XZ, .GRAY, cast_shadow = false)
  mjolnir.scale(engine, ground, 8.0)

  // Particle source at center, large position spread
  if tex, ok := mjolnir.create_texture(engine, "assets/particles/star_09.png"); ok {
    mjolnir.spawn_emitter(
      engine,
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
  ff_handle = mjolnir.spawn(engine, {0, 2, 0})
  child := mjolnir.spawn_forcefield(engine, position = {2.5, 0, 0}, area_of_effect = 4.0, strength = -15.0, tangent_strength = 8.0)
  mjolnir.attach(engine, ff_handle, child)

  // Visualize the field with a small sphere
  marker_mat := mjolnir.material_pbr(engine, base_color = {0.2, 0.6, 1.0, 1}, emissive = 2.0, roughness = 0.3)
  mjolnir.spawn_child(engine, child, attachment = world.mesh_attach(mjolnir.builtin_mesh(engine, .SPHERE), marker_mat, cast_shadow = false))

  mjolnir.spawn_light_directional(engine, position = {3, 6, 3}, color = {1, 1, 1, 1}, radius = 10)
}

update :: proc(engine: ^mjolnir.Engine, dt: f32) {
  t := mjolnir.time_since_start(engine)
  mjolnir.rotate(engine, ff_handle, t * 1.2, linalg.VECTOR3F32_Y_AXIS)
}

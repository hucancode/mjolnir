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

  plane := world.get_builtin_mesh(&engine.world, .QUAD_XZ)
  plane_mat := world.get_builtin_material(&engine.world, .GRAY)
  ground := world.spawn(
    &engine.world,
    {0, 0, 0},
    world.MeshAttachment{handle = plane, material = plane_mat, cast_shadow = false},
  ) or_else {}
  world.scale(&engine.world, ground, 8.0)

  // Particle source at center, large position spread
  tex, tex_ok := mjolnir.create_texture(engine, "assets/gold-star.png")
  if tex_ok {
    src := world.spawn(&engine.world, {0, 2, 0})
    if emitter, ok := world.create_emitter(
      &engine.world,
      src,
      texture_handle = tex,
      emission_rate = 60,
      initial_velocity = {0, 0, 0},
      velocity_spread = 0.05,
      color_start = {1, 0.95, 0.4, 1},
      color_end = {1, 0.2, 0, 0},
      aabb_min = {-6, -6, -6},
      aabb_max = {6, 6, 6},
      particle_lifetime = 4.0,
      position_spread = 2.5,
      size_start = 100,
      size_end = 30,
      weight = 0.0,
      weight_spread = 0.0,
    ); ok {
      world.spawn_child(&engine.world, src, attachment = world.EmitterAttachment{emitter})
    }
  }

  // Orbiting forcefield: parent rotates, child has the field offset
  ff_handle = world.spawn(&engine.world, {0, 2, 0})
  child := world.spawn_child(&engine.world, ff_handle)
  world.translate(&engine.world, child, 2.5, 0, 0)
  if n, ok := world.node(&engine.world, child); ok {
    n.attachment = world.ForceFieldAttachment {
      handle = world.create_forcefield(
        &engine.world,
        child,
        area_of_effect = 4.0,
        strength = -15.0,        // negative = attract
        tangent_strength = 8.0,  // swirl
      ),
    }
  }

  // Visualize the field with a small sphere
  sphere := world.get_builtin_mesh(&engine.world, .SPHERE)
  marker_mat := world.create_material(
    &engine.world,
    type = .PBR,
    base_color_factor = {0.2, 0.6, 1.0, 1},
    emissive_value = 2.0,
    roughness_value = 0.3,
  ) or_else {}
  world.spawn_child(
    &engine.world,
    child,
    attachment = world.MeshAttachment{handle = sphere, material = marker_mat, cast_shadow = false},
  )

  world.spawn(
    &engine.world,
    {3, 6, 3},
    world.create_directional_light_attachment({1, 1, 1, 1}, 10, false),
  )
}

update :: proc(engine: ^mjolnir.Engine, delta_time: f32) {
  t := mjolnir.time_since_start(engine)
  if n, ok := world.node(&engine.world, ff_handle); ok {
    n.transform.rotation = linalg.quaternion_angle_axis(t * 1.2, linalg.VECTOR3F32_Y_AXIS)
    n.transform.is_dirty = true
  }
}

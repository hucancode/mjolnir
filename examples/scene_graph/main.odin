package main

import "../../mjolnir"
import "../../mjolnir/world"
import "core:fmt"
import "core:log"
import "core:math"
import "core:math/linalg"
import mu "vendor:microui"

sun_handle: world.NodeHandle
planet_handles: [3]world.NodeHandle
moon_handle: world.NodeHandle

orbit_speed: mu.Real = 1.0
spin_speed: mu.Real = 2.0
phase: f32

main :: proc() {
  context.logger = log.create_console_logger()
  engine := new(mjolnir.Engine)
  engine.setup_proc = setup
  engine.update_proc = update
  engine.pre_render_proc = debug_ui
  mjolnir.run(engine, 1000, 700, "Scene Graph")
}

setup :: proc(engine: ^mjolnir.Engine) {
  engine.debug_ui_enabled = true
  world.main_camera_look_at(&engine.world, {0, 14, 18}, {0, 0, 0})

  world.spawn(
    &engine.world,
    {8, 14, 8},
    world.create_directional_light_attachment({1, 0.97, 0.92, 1}, 8.0, true),
  )

  ground_mesh := world.get_builtin_mesh(&engine.world, .QUAD_XZ)
  ground_mat := world.get_builtin_material(&engine.world, .GRAY)
  ground :=
    world.spawn(
      &engine.world,
      {0, -2, 0},
      world.MeshAttachment{handle = ground_mesh, material = ground_mat, cast_shadow = false},
    ) or_else {}
  world.scale(&engine.world, ground, 20.0)

  // Sun — root of the rotating subtree
  sun_mat := world.create_material(
    &engine.world,
    type = .PBR,
    base_color_factor = {1.0, 0.8, 0.2, 1.0},
    emissive_value = 2.0,
  ) or_else {}
  sun_mesh := world.get_builtin_mesh(&engine.world, .SPHERE)
  sun_handle =
    world.spawn(
      &engine.world,
      {0, 0, 0},
      world.MeshAttachment{handle = sun_mesh, material = sun_mat},
    ) or_else {}
  world.scale(&engine.world, sun_handle, 1.2)

  // Planets — children of sun, each at fixed local offset
  planet_colors := [3]world.Color{.CYAN, .GREEN, .MAGENTA}
  planet_radii := [3]f32{3.5, 6.0, 9.0}
  for i in 0 ..< 3 {
    planet_handles[i] =
      world.spawn_child(
        &engine.world,
        sun_handle,
        {planet_radii[i], 0, 0},
        world.MeshAttachment {
          handle = world.get_builtin_mesh(&engine.world, .SPHERE),
          material = world.get_builtin_material(&engine.world, planet_colors[i]),
        },
      ) or_else {}
    world.scale(&engine.world, planet_handles[i], 0.5)
  }

  // Moon — child of outermost planet
  moon_handle =
    world.spawn_child(
      &engine.world,
      planet_handles[2],
      {1.5, 0, 0},
      world.MeshAttachment {
        handle = world.get_builtin_mesh(&engine.world, .CUBE),
        material = world.get_builtin_material(&engine.world, .WHITE),
      },
    ) or_else {}
  world.scale(&engine.world, moon_handle, 0.3)
}

update :: proc(engine: ^mjolnir.Engine, delta_time: f32) {
  phase += delta_time * f32(orbit_speed)
  // Sun spins slowly — propagates to planet world positions through hierarchy
  if n, ok := world.node(&engine.world, sun_handle); ok {
    n.transform.rotation = quat_y(phase * 0.3)
    n.transform.is_dirty = true
  }
  // Each planet spins on own axis
  for h, i in planet_handles {
    if n, ok := world.node(&engine.world, h); ok {
      n.transform.rotation = quat_y(phase * f32(spin_speed) * f32(i + 1) * 0.5)
      n.transform.is_dirty = true
    }
  }
  // Moon spins fast on planet's local frame
  if n, ok := world.node(&engine.world, moon_handle); ok {
    n.transform.rotation = quat_y(phase * 4.0)
    n.transform.is_dirty = true
  }
}

debug_ui :: proc(engine: ^mjolnir.Engine) {
  ctx := &engine.render.debug_ui.ctx
  if mu.window(ctx, "Scene Graph", {720, 20, 260, 240}, {.NO_CLOSE}) {
    mu.label(ctx, "Hierarchy: sun > planets > moon")
    mu.label(ctx, "Each planet inherits sun rotation.")
    mu.label(ctx, "Moon inherits outer planet too.")
    mu.label(ctx, "")
    mu.label(ctx, fmt.tprintf("Orbit speed: %.2f", orbit_speed))
    mu.slider(ctx, &orbit_speed, 0.0, 4.0)
    mu.label(ctx, fmt.tprintf("Spin speed: %.2f", spin_speed))
    mu.slider(ctx, &spin_speed, 0.0, 6.0)
  }
}

quat_y :: proc(angle: f32) -> quaternion128 {
  return linalg.quaternion_angle_axis(angle, linalg.VECTOR3F32_Y_AXIS)
}

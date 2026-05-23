package main

import "../../mjolnir"
import "../../mjolnir/world"
import "core:fmt"
import mu "vendor:microui"

sun_handle: mjolnir.NodeHandle
planet_handles: [3]mjolnir.NodeHandle
moon_handle: mjolnir.NodeHandle

orbit_speed: mu.Real = 1.0
spin_speed: mu.Real = 2.0
phase: f32

main :: proc() {
  mjolnir.run_app({
    title      = "Scene Graph",
    width      = 1000,
    height     = 700,
    debug_ui   = true,
    setup      = setup,
    update     = update,
    pre_render = debug_ui,
  })
}

setup :: proc(engine: ^mjolnir.Engine) {
  mjolnir.main_camera_look_at(engine, {0, 14, 18}, {0, 0, 0})

  mjolnir.spawn_light_directional(
    engine,
    position    = {8, 14, 8},
    color       = {1, 0.97, 0.92, 1},
    radius      = 8.0,
    cast_shadow = true,
  )

  ground := mjolnir.spawn_primitive_mesh(engine, .QUAD_XZ, .GRAY, position = {0, -2, 0}, cast_shadow = false)
  mjolnir.scale(engine, ground, 20.0)

  // Sun — root of the rotating subtree
  sun_mat := mjolnir.material_pbr(engine, base_color = {1.0, 0.8, 0.2, 1.0}, emissive = 2.0)
  sun_handle = mjolnir.spawn_mesh(engine, mjolnir.builtin_mesh(engine, .SPHERE), sun_mat)
  mjolnir.scale(engine, sun_handle, 1.2)

  // Planets — children of sun, each at fixed local offset
  planet_colors := [3]mjolnir.Color{.CYAN, .GREEN, .MAGENTA}
  planet_radii := [3]f32{3.5, 6.0, 9.0}
  for i in 0 ..< 3 {
    planet_handles[i] = mjolnir.spawn_child(
      engine,
      sun_handle,
      {planet_radii[i], 0, 0},
      world.mesh_attach(mjolnir.builtin_mesh(engine, .SPHERE), mjolnir.builtin_material(engine, planet_colors[i])),
    )
    mjolnir.scale(engine, planet_handles[i], 0.5)
  }

  // Moon — child of outermost planet
  moon_handle = mjolnir.spawn_child(
    engine,
    planet_handles[2],
    {1.5, 0, 0},
    world.mesh_attach(mjolnir.builtin_mesh(engine, .CUBE), mjolnir.builtin_material(engine, .WHITE)),
  )
  mjolnir.scale(engine, moon_handle, 0.3)
}

update :: proc(engine: ^mjolnir.Engine, delta_time: f32) {
  phase += delta_time * f32(orbit_speed)
  mjolnir.rotate(engine, sun_handle, phase * 0.3)
  for h, i in planet_handles {
    mjolnir.rotate(engine, h, phase * f32(spin_speed) * f32(i + 1) * 0.5)
  }
  mjolnir.rotate(engine, moon_handle, phase * 4.0)
}

debug_ui :: proc(engine: ^mjolnir.Engine) {
  ctx := mjolnir.ui_ctx(engine)
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

package main

import "../../mjolnir"
import "../../mjolnir/world"
import "core:fmt"
import mu "vendor:microui"

sun_handle: world.NodeHandle
planet_handles: [3]world.NodeHandle
moon_handle: world.NodeHandle

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
  world.main_camera_look_at(&engine.world, {0, 14, 18}, {0, 0, 0})

  world.spawn_light_directional(&engine.world,
    position    = {8, 14, 8},
    color       = {1, 0.97, 0.92, 1},
    radius      = 8.0,
    cast_shadow = true,
  )

  world.spawn_ground(&engine.world, 20.0, position = {0, -2, 0})

  // Sun — root of the rotating subtree
  sun_mat := world.material_pbr(&engine.world, base_color = {1.0, 0.8, 0.2, 1.0}, emissive = 2.0)
  sun_handle = world.spawn_mesh(&engine.world, world.get_builtin_mesh(&engine.world, .SPHERE), sun_mat)
  world.scale(&engine.world, sun_handle, 1.2)

  // Planets — children of sun, each at fixed local offset
  planet_colors := [3]world.Color{.CYAN, .GREEN, .MAGENTA}
  planet_radii := [3]f32{3.5, 6.0, 9.0}
  for i in 0 ..< 3 {
    planet_handles[i] = world.spawn_primitive_mesh_child(&engine.world, sun_handle, .SPHERE, planet_colors[i],
      position = {planet_radii[i], 0, 0}, scale_factor = 0.5,
    )
  }

  // Moon — child of outermost planet
  moon_handle = world.spawn_primitive_mesh_child(&engine.world, planet_handles[2], .CUBE, .WHITE,
    position = {1.5, 0, 0}, scale_factor = 0.3,
  )
}

update :: proc(engine: ^mjolnir.Engine, delta_time: f32) {
  phase += delta_time * f32(orbit_speed)
  world.rotate(&engine.world, sun_handle, phase * 0.3)
  for h, i in planet_handles {
    world.rotate(&engine.world, h, phase * f32(spin_speed) * f32(i + 1) * 0.5)
  }
  world.rotate(&engine.world, moon_handle, phase * 4.0)
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

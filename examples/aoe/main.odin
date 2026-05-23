package main

import "../../mjolnir"
import "../../mjolnir/geometry"
import "../../mjolnir/physics"
import "../../mjolnir/render"
import "../../mjolnir/world"
import "core:log"
import "core:math"
import "vendor:glfw"

cube_mesh_handles: [dynamic]mjolnir.NodeHandle
cube_body_to_mesh: map[physics.TriggerHandle]mjolnir.NodeHandle
effector_sphere: mjolnir.NodeHandle
effector_position: [3]f32
orbit_angle: f32 = 0.0
orbit_radius: f32 = 15.0
effect_radius: f32 = 10.0
cube_scale: f32 = 0.3
clicked_cube: mjolnir.NodeHandle
last_mouse_button_state: bool = false

main :: proc() {
  mjolnir.run_app({title = "AOE Query", setup = setup, update = update})
}

setup :: proc(engine: ^mjolnir.Engine) {
  cube_body_to_mesh = make(map[physics.TriggerHandle]mjolnir.NodeHandle)
  render.set_visibility_stats_enabled(&engine.render, false)
  cube_mesh := mjolnir.builtin_mesh(engine, .CUBE)
  sphere_mesh := mjolnir.builtin_mesh(engine, .SPHERE)
  cube_mat := mjolnir.builtin_material(engine, .CYAN)
  effector_mat := mjolnir.material_pbr(engine, emissive = 5.0)
  grid_size := 50
  spacing: f32 = 1.0
  log.infof("Spawning %dx%d grid of cubes...", grid_size, grid_size)
  for x in 0 ..< grid_size do for z in 0 ..< grid_size {
    world_x := (f32(x) - f32(grid_size) * 0.5) * spacing
    world_z := (f32(z) - f32(grid_size) * 0.5) * spacing
    body_handle := physics.create_trigger(
      &engine.physics,
      position = {world_x, 0.5, world_z},
      collider = physics.BoxCollider{half_extents = {0.5 * cube_scale, 0.5 * cube_scale, 0.5 * cube_scale}},
    ) or_continue
    pn := mjolnir.spawn(engine, {world_x, 0.5, world_z}) or_continue
    mh := mjolnir.spawn_child(engine, pn, attachment = world.mesh_attach(cube_mesh, cube_mat, cast_shadow = false)) or_continue
    mjolnir.scale(engine, mh, cube_scale)
    append(&cube_mesh_handles, mh)
    cube_body_to_mesh[body_handle] = mh
  }
  effector_position = {0, 1, 0}
  effector_sphere = mjolnir.spawn_mesh(engine, sphere_mesh, effector_mat, cast_shadow = false)
  mjolnir.translate(engine, effector_sphere, effector_position)
  mjolnir.scale(engine, effector_sphere, 0.5)
  mjolnir.main_camera_look_at(engine, {10, 30, 10}, {0, 0, 0})
  log.infof("AOE test setup complete: %d cubes", len(cube_mesh_handles))
}

update :: proc(engine: ^mjolnir.Engine, dt: f32) {
  mouse_button_pressed := engine.input.mouse_buttons[glfw.MOUSE_BUTTON_LEFT]
  mouse_just_clicked := mouse_button_pressed && !last_mouse_button_state
  last_mouse_button_state = mouse_button_pressed
  mouse_click: if mouse_just_clicked {
    cam, ok := mjolnir.main_camera(engine)
    if !ok do break mouse_click
    dpi := mjolnir.get_window_dpi(engine.window)
    mx := f32(engine.input.mouse_pos.x) * dpi
    my := f32(engine.input.mouse_pos.y) * dpi
    ray_origin, ray_dir := world.camera_viewport_to_world_ray(cam, mx, my)
    log.infof("Ray: origin=%v, direction=%v", ray_origin, ray_dir)
    hit := physics.raycast_trigger(&engine.physics, geometry.Ray{origin = ray_origin, direction = ray_dir})
    clicked_cube = {}
    if !hit.hit do break mouse_click
    #partial switch bh in hit.body_handle {
    case physics.TriggerHandle:
      if mh, ok := cube_body_to_mesh[bh]; ok do clicked_cube = mh
    }
  }
  orbit_angle += dt * 0.5
  effector_position = {math.cos(orbit_angle) * orbit_radius, 1.0, math.sin(orbit_angle) * orbit_radius}
  mjolnir.translate(engine, effector_sphere, effector_position)
  for h in cube_mesh_handles do mjolnir.scale(engine, h, cube_scale)
  affected: [dynamic]physics.TriggerHandle
  defer delete(affected)
  physics.query_triggers_in_sphere(&engine.physics, effector_position, effect_radius, &affected)
  for bh in affected do if mh, ok := cube_body_to_mesh[bh]; ok do mjolnir.scale(engine, mh, 0.1)
  mjolnir.scale(engine, clicked_cube, cube_scale * 3.0)
}

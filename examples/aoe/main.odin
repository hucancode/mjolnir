package main

import "../../mjolnir"
import "../../mjolnir/platform"
import "../../mjolnir/render"
import "../../mjolnir/geometry"
import "../../mjolnir/world"
import "../../mjolnir/physics"
import "core:log"
import "core:math"

cube_mesh_handles: [dynamic]world.NodeHandle
cube_body_to_mesh: map[physics.TriggerHandle]world.NodeHandle
effector_sphere: world.NodeHandle
effector_position: [3]f32
orbit_angle: f32 = 0.0
orbit_radius: f32 = 15.0
effect_radius: f32 = 10.0
cube_scale: f32 = 0.3
clicked_cube: world.NodeHandle

phys: physics.World

main :: proc() {
  physics.init(&phys)
  defer physics.shutdown(&phys)
  mjolnir.run_app({title = "AOE Query", setup = setup, update = update})
}

setup :: proc(engine: ^mjolnir.Engine) {
  cube_body_to_mesh = make(map[physics.TriggerHandle]world.NodeHandle)
  render.set_visibility_stats_enabled(&engine.render, false)
  cube_mesh := render.get_builtin_mesh(&engine.render, .CUBE)
  sphere_mesh := render.get_builtin_mesh(&engine.render, .SPHERE)
  cube_mat := render.get_builtin_material(&engine.render, .CYAN)
  effector_mat := render.material_pbr(&engine.render, emissive = 5.0)
  grid_size := 50
  spacing: f32 = 1.0
  log.infof("Spawning %dx%d grid of cubes...", grid_size, grid_size)
  for x in 0 ..< grid_size do for z in 0 ..< grid_size {
    world_x := (f32(x) - f32(grid_size) * 0.5) * spacing
    world_z := (f32(z) - f32(grid_size) * 0.5) * spacing
    parent, body_handle, ok := mjolnir.spawn_trigger(
      engine, &phys,
      {world_x, 0.5, world_z},
      physics.BoxCollider{half_extents = {0.5 * cube_scale, 0.5 * cube_scale, 0.5 * cube_scale}},
      cube_mesh, cube_mat, cast_shadow = false,
    )
    if !ok do continue
    mh, has_visual := mesh_child(engine, parent)
    if !has_visual do continue
    append(&cube_mesh_handles, mh)
    cube_body_to_mesh[body_handle] = mh
  }
  effector_position = {0, 1, 0}
  effector_sphere = mjolnir.spawn_mesh(engine, sphere_mesh, effector_mat, cast_shadow = false)
  world.translate(&engine.world, effector_sphere, effector_position)
  world.scale(&engine.world, effector_sphere, 0.5)
  render.main_camera_look_at(&engine.render, {10, 30, 10}, {0, 0, 0})
  log.infof("AOE test setup complete: %d cubes", len(cube_mesh_handles))
}

update :: proc(engine: ^mjolnir.Engine, dt: f32) {
  mouse_click: if platform.input_mouse_pressed(&engine.platform.input, .LEFT) {
    ray_origin, ray_dir, ok := mjolnir.cursor_world_ray(engine)
    if !ok do break mouse_click
    log.infof("Ray: origin=%v, direction=%v", ray_origin, ray_dir)
    hit := physics.raycast_trigger(&phys, geometry.Ray{origin = ray_origin, direction = ray_dir})
    clicked_cube = {}
    if !hit.hit do break mouse_click
    #partial switch bh in hit.body_handle {
    case physics.TriggerHandle:
      if mh, ok := cube_body_to_mesh[bh]; ok do clicked_cube = mh
    }
  }
  orbit_angle += dt * 0.5
  effector_position = {math.cos(orbit_angle) * orbit_radius, 1.0, math.sin(orbit_angle) * orbit_radius}
  world.translate(&engine.world, effector_sphere, effector_position)
  for h in cube_mesh_handles do world.scale(&engine.world, h, cube_scale)
  affected: [dynamic]physics.TriggerHandle
  defer delete(affected)
  physics.query_triggers_in_sphere(&phys, effector_position, effect_radius, &affected)
  for bh in affected do if mh, ok := cube_body_to_mesh[bh]; ok do world.scale(&engine.world, mh, 0.1)
  world.scale(&engine.world, clicked_cube, cube_scale * 3.0)
  physics.step(&phys, dt)
  for b in physics.body_poses(&phys) do world.set_world_pose(&engine.world, world.NodeHandle(b.user), b.position, b.rotation)
}

mesh_child :: proc(engine: ^mjolnir.Engine, parent: world.NodeHandle) -> (child: world.NodeHandle, ok: bool) {
  n := world.node(&engine.world, parent) or_return
  for c in n.children do if _, has := render.mesh_attachment(&engine.render, c.index); has do return c, true
  return {}, false
}

package main

import "../../mjolnir"
import "../../mjolnir/input"
import "../../mjolnir/render/mesh"
import "../../mjolnir/render"
import "../../mjolnir/world"
import nav "../../mjolnir/navigation"
import "../../mjolnir/navigation/bake"
import "core:log"
import "core:math/linalg"

end_pos: [3]f32
current_path: [][3]f32
end_marker_handle: world.NodeHandle
agent_handle: world.NodeHandle
agent_pos: [3]f32 = {-20, 0, -20}
agent_speed: f32 = 5.0
current_waypoint_idx: int
path_completed: bool

ground_handle: world.NodeHandle
obstacle_handles: [dynamic]world.NodeHandle
obj_mesh_handle: render.MeshHandle
obj_node_handle: world.NodeHandle
use_procedural: bool = true

nav_builder: bake.NavGeometryBuilder
navmesh_node_handle: world.NodeHandle
path_spawn_time: f32

TAG_ENVIRONMENT :: u32(1 << 0)
TAG_OBSTACLE :: u32(1 << 1)
path_active: bool
navmesh: nav.NavMesh

main :: proc() {
  defer {
    nav.destroy(&navmesh)
    bake.builder_destroy(&nav_builder)
  }
  mjolnir.run_app({
    title       = "Navigation Mesh",
    setup       = demo_setup,
    update      = demo_update,
  })
}

demo_setup :: proc(engine: ^mjolnir.Engine) {
  log.info("Navigation mesh demo setup with world integration")
  bake.builder_destroy(&nav_builder)
  render.main_camera_look_at(&engine.render, {35, 25, 35}, {0, 0, 0})

  if use_procedural do create_demo_scene(engine)
  else              do create_obj_visualization_mesh(engine, "assets/nav_test.obj")

  setup_navigation_mesh(engine)
  agent_pos = {-20, 0, -20}
  end_pos = {20, 0, 20}
  update_position_marker(engine, &end_marker_handle, end_pos, {1, 0, 0, 1})
  create_agent(engine)
  start_find_path(engine)
}

create_demo_scene :: proc(engine: ^mjolnir.Engine) {
  ground_geom := mesh.make_quad({0.2, 0.6, 0.2, 1.0})
  for &v in ground_geom.vertices { v.position.x *= 50; v.position.z *= 50 }
  bake.append_triangles(&nav_builder, mesh.positions(ground_geom, context.temp_allocator), ground_geom.indices)
  ground_mesh := render.create_mesh(&engine.render, ground_geom)
  ground_mat := render.material_pbr(&engine.render, metallic = 0.1, roughness = 0.8, emissive = 0.02)
  ground_handle = mjolnir.spawn_mesh(engine, ground_mesh, ground_mat)
  world.tag(&engine.world, ground_handle, TAG_ENVIRONMENT)

  obstacle_positions := [][3]f32{{-10, 1.5, -10}, {10, 1.5, -10}, {-10, 1.5, 10}, {10, 1.5, 10}, {0, 2, 0}}
  obstacle_sizes := [][3]f32{{2, 3, 2}, {2, 3, 2}, {2, 3, 2}, {2, 3, 2}, {4, 4, 4}}
  for pos, i in obstacle_positions {
    size := obstacle_sizes[i]
    g := mesh.make_cube({0.8, 0.2, 0.2, 1.0})
    for &v in g.vertices { v.position.x *= size.x; v.position.y *= size.y; v.position.z *= size.z }
    bake.append_triangles(&nav_builder, mesh.positions(g, context.temp_allocator), g.indices, pos, true)
    mh := render.create_mesh(&engine.render, g)
    mat := render.material_pbr(&engine.render, metallic = 0.3, roughness = 0.7, emissive = 0.1)
    h := mjolnir.spawn_mesh(engine, mh, mat, pos)
    world.tag(&engine.world, h, TAG_OBSTACLE)
    append(&obstacle_handles, h)
  }
  log.infof("Created demo scene with ground and %d obstacles", len(obstacle_handles))
}

create_agent :: proc(engine: ^mjolnir.Engine) {
  agent_geom := mesh.make_cylinder(16, 2, 0.5, {0.2, 0.5, 1.0, 1.0})
  mh := render.create_mesh(&engine.render, agent_geom)
  mat := render.material_pbr(&engine.render, metallic = 0.3, roughness = 0.6, emissive = 0.3)
  agent_handle = mjolnir.spawn_mesh(engine, mh, mat, agent_pos + {0, 1, 0})
  if n, ok := world.node(&engine.world, agent_handle); ok do n.name = "agent"
}

create_obj_visualization_mesh :: proc(engine: ^mjolnir.Engine, obj_file: string) {
  obj, ok := mesh.load_obj(obj_file, 1.0)
  if !ok { log.error("Failed to load OBJ file as geometry"); return }
  defer mesh.obj_mesh_destroy(&obj)
  bake.append_triangles(&nav_builder, obj.positions, obj.indices)
  obj_mesh_handle = render.create_mesh(&engine.render, mesh.from_triangles(obj.positions, obj.indices))
  mat := render.material_pbr(&engine.render, metallic = 0.1, roughness = 0.8, emissive = 0.02)
  obj_node_handle = mjolnir.spawn_mesh(engine, obj_mesh_handle, mat)
  world.tag(&engine.world, obj_node_handle, TAG_ENVIRONMENT)
  if n, ok := world.node(&engine.world, obj_node_handle); ok do n.name = "obj_mesh"
}

setup_navigation_mesh :: proc(engine: ^mjolnir.Engine) {
  if len(nav_builder.vertices) == 0 || len(nav_builder.indices) == 0 {
    log.error("No source geometry available for navmesh generation"); return
  }
  if !bake.build(&navmesh, bake.geometry_view(&nav_builder)) {
    log.error("Failed to build navmesh"); return
  }
  visualize_navmesh(engine)
}

visualize_navmesh :: proc(engine: ^mjolnir.Engine) {
  world.despawn(&engine.world, navmesh_node_handle)
  positions, indices := nav.debug_triangles(&navmesh, context.temp_allocator)
  navmesh_geom := mesh.from_triangles(positions, indices)
  log.infof("Built navmesh visualization geometry: %d vertices, %d indices", len(navmesh_geom.vertices), len(navmesh_geom.indices))
  m, m_ok := render.create_mesh(&engine.render, navmesh_geom)
  if !m_ok { log.error("Failed to create navmesh visualization mesh"); return }
  mat, mat_ok := render.create_material(&engine.render, type = .RANDOM_COLOR, base_color_factor = {1.0, 0.8, 0.3, 0.3})
  if !mat_ok { log.error("Failed to create navmesh material"); return }
  navmesh_node_handle = mjolnir.spawn_mesh(engine, m, mat)
}

start_find_path :: proc(engine: ^mjolnir.Engine) {
  log.infof("Finding path from %v to %v", agent_pos, end_pos)
  path := nav.find_path(&navmesh, agent_pos, end_pos, 256)
  if path != nil && len(path) > 0 {
    delete(current_path)
    current_path = path
    log.infof("Path found with %d waypoints", len(path))
    path_spawn_time = 0
    path_active = true
    current_waypoint_idx = 0
    path_completed = false
  }
}

update_position_marker :: proc(engine: ^mjolnir.Engine, handle: ^world.NodeHandle, pos: [3]f32, color: [4]f32) {
  world.despawn(&engine.world, handle^)
  g := mesh.make_sphere(12, 6, 0.3, color)
  m := render.create_mesh(&engine.render, g)
  mat := render.material_pbr(&engine.render, metallic = 0.2, roughness = 0.8, emissive = 0.5)
  handle^ = mjolnir.spawn_mesh(engine, m, mat, pos + {0, 0.2, 0})
}

draw_path_debug :: proc(engine: ^mjolnir.Engine) {
  if !path_active || len(current_path) < 2 do return
  lift := [3]f32{0, 0.15, 0}
  for i in 0 ..< len(current_path) - 1 {
    render.debug_segment(&engine.render, current_path[i] + lift, current_path[i + 1] + lift, {1.0, 0.8, 0.0, 1.0})
  }
}

find_navmesh_point_from_mouse :: proc(engine: ^mjolnir.Engine) -> ([3]f32, bool) {
  ray_origin, ray_dir, ok := mjolnir.cursor_world_ray(engine)
  if !ok do return {}, false
  return nav.raycast(&navmesh, ray_origin, ray_dir)
}

demo_mouse_pressed :: proc(engine: ^mjolnir.Engine) {
  if engine.mouse_captured || !input.mouse_pressed(&engine.input, .RIGHT) do return
  pos, valid := find_navmesh_point_from_mouse(engine)
  if !valid { log.warn("No valid navmesh position found at click location"); return }
  end_pos = pos
  log.infof("Destination set to: %v", pos)
  update_position_marker(engine, &end_marker_handle, pos, {1, 0, 0, 1})
  start_find_path(engine)
}

demo_update :: proc(engine: ^mjolnir.Engine, dt: f32) {
  demo_mouse_pressed(engine)
  if path_active {
    path_spawn_time += dt
    if path_spawn_time >= 5.0 do path_active = false
    else                       do draw_path_debug(engine)
  }
  if len(current_path) > 0 && !path_completed && current_waypoint_idx < len(current_path) {
    target := current_path[current_waypoint_idx]
    diff := target - agent_pos
    distance := linalg.length(diff)
    if distance < 0.5 {
      current_waypoint_idx += 1
      if current_waypoint_idx >= len(current_path) { path_completed = true; log.info("Agent reached destination!") }
    } else {
      move := agent_speed * dt
      if move > distance do move = distance
      agent_pos += linalg.normalize(diff) * move
      world.translate(&engine.world, agent_handle, agent_pos + {0, 1, 0})
    }
  }
  world.update(&engine.world)
  for i in world.removed_nodes(&engine.world) do render.stage_slot_removal(&engine.render, i)
  for n in world.changed_nodes(&engine.world) do render.stage_transform(&engine.render, n.index, n.world_matrix, n.visible)
}

package main

import "../../mjolnir"
import "../../mjolnir/geometry"
import nav "../../mjolnir/navigation"
import "../../mjolnir/navigation/recast"
import "../../mjolnir/world"
import "core:log"
import "core:math"
import "core:math/linalg"
import "vendor:glfw"

end_pos: [3]f32
current_path: [][3]f32
end_marker_handle: mjolnir.NodeHandle
agent_handle: mjolnir.NodeHandle
agent_pos: [3]f32 = {-20, 0, -20}
agent_speed: f32 = 5.0
current_waypoint_idx: int
path_completed: bool

ground_handle: mjolnir.NodeHandle
obstacle_handles: [dynamic]mjolnir.NodeHandle
obj_mesh_handle: mjolnir.MeshHandle
obj_node_handle: mjolnir.NodeHandle
use_procedural: bool = true

nav_builder: nav.NavGeometryBuilder
navmesh_node_handle: mjolnir.NodeHandle
path_spawn_time: f32
path_active: bool

main :: proc() {
  mjolnir.run_app({
    title       = "Navigation Mesh",
    setup       = demo_setup,
    update      = demo_update,
    mouse_press = demo_mouse_pressed,
  })
}

demo_setup :: proc(engine: ^mjolnir.Engine) {
  log.info("Navigation mesh demo setup with world integration")
  nav.destroy_builder(&nav_builder)
  nav_builder = {}
  mjolnir.main_camera_look_at(engine, {35, 25, 35}, {0, 0, 0})

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
  ground_geom := geometry.make_quad({0.2, 0.6, 0.2, 1.0})
  for &v in ground_geom.vertices { v.position.x *= 50; v.position.z *= 50 }
  nav.append_geometry(&nav_builder, ground_geom)
  ground_mesh := mjolnir.create_mesh(engine, ground_geom)
  ground_mat := mjolnir.material_pbr(engine, metallic = 0.1, roughness = 0.8, emissive = 0.02)
  ground_handle = mjolnir.spawn_mesh(engine, ground_mesh, ground_mat)
  mjolnir.tag(engine, ground_handle, {.ENVIRONMENT})

  obstacle_positions := [][3]f32{{-10, 1.5, -10}, {10, 1.5, -10}, {-10, 1.5, 10}, {10, 1.5, 10}, {0, 2, 0}}
  obstacle_sizes := [][3]f32{{2, 3, 2}, {2, 3, 2}, {2, 3, 2}, {2, 3, 2}, {4, 4, 4}}
  for pos, i in obstacle_positions {
    size := obstacle_sizes[i]
    g := geometry.make_cube({0.8, 0.2, 0.2, 1.0})
    for &v in g.vertices { v.position.x *= size.x; v.position.y *= size.y; v.position.z *= size.z }
    nav.append_geometry(&nav_builder, g, pos, true)
    mh := mjolnir.create_mesh(engine, g)
    mat := mjolnir.material_pbr(engine, metallic = 0.3, roughness = 0.7, emissive = 0.1)
    h := mjolnir.spawn_mesh(engine, mh, mat, pos)
    mjolnir.tag(engine, h, {.NAVMESH_OBSTACLE})
    append(&obstacle_handles, h)
  }
  log.infof("Created demo scene with ground and %d obstacles", len(obstacle_handles))
}

create_agent :: proc(engine: ^mjolnir.Engine) {
  agent_geom := geometry.make_cylinder(16, 2, 0.5, {0.2, 0.5, 1.0, 1.0})
  mh := mjolnir.create_mesh(engine, agent_geom)
  mat := mjolnir.material_pbr(engine, metallic = 0.3, roughness = 0.6, emissive = 0.3)
  agent_handle = mjolnir.spawn_mesh(engine, mh, mat, agent_pos + {0, 1, 0})
  if n, ok := mjolnir.node(engine, agent_handle); ok do n.name = "agent"
}

create_obj_visualization_mesh :: proc(engine: ^mjolnir.Engine, obj_file: string) {
  geom, ok := geometry.load_obj(obj_file, 1.0)
  if !ok { log.error("Failed to load OBJ file as geometry"); return }
  nav.append_geometry(&nav_builder, geom)
  obj_mesh_handle = mjolnir.create_mesh(engine, geom)
  mat := mjolnir.material_pbr(engine, metallic = 0.1, roughness = 0.8, emissive = 0.02)
  obj_node_handle = mjolnir.spawn_mesh(engine, obj_mesh_handle, mat)
  mjolnir.tag(engine, obj_node_handle, {.ENVIRONMENT})
  if n, ok := mjolnir.node(engine, obj_node_handle); ok do n.name = "obj_mesh"
}

setup_navigation_mesh :: proc(engine: ^mjolnir.Engine) {
  if len(nav_builder.vertices) == 0 || len(nav_builder.indices) == 0 {
    log.error("No source geometry available for navmesh generation"); return
  }
  cfg := recast.config_create()
  if !nav.build_navmesh(&engine.nav.nav_mesh, nav.geometry_view(&nav_builder), cfg) {
    log.error("Failed to build navmesh"); return
  }
  if !nav.init(&engine.nav) { log.error("Failed to initialize navmesh query"); return }
  visualize_navmesh(engine)
}

visualize_navmesh :: proc(engine: ^mjolnir.Engine) {
  mjolnir.despawn(engine, navmesh_node_handle)
  navmesh_geom := nav.build_geometry(&engine.nav.nav_mesh)
  log.infof("Built navmesh visualization geometry: %d vertices, %d indices", len(navmesh_geom.vertices), len(navmesh_geom.indices))
  m, m_ok := mjolnir.create_mesh(engine, navmesh_geom)
  if !m_ok { log.error("Failed to create navmesh visualization mesh"); return }
  mat, mat_ok := mjolnir.create_material(engine, type = .RANDOM_COLOR, base_color_factor = {1.0, 0.8, 0.3, 0.3})
  if !mat_ok { log.error("Failed to create navmesh material"); return }
  navmesh_node_handle = mjolnir.spawn_mesh(engine, m, mat)
}

start_find_path :: proc(engine: ^mjolnir.Engine) {
  log.infof("Finding path from %v to %v", agent_pos, end_pos)
  path := mjolnir.find_path(engine, agent_pos, end_pos, 256)
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

update_position_marker :: proc(engine: ^mjolnir.Engine, handle: ^mjolnir.NodeHandle, pos: [3]f32, color: [4]f32) {
  mjolnir.despawn(engine, handle^)
  g := geometry.make_sphere(12, 6, 0.3, color)
  m := mjolnir.create_mesh(engine, g)
  mat := mjolnir.material_pbr(engine, metallic = 0.2, roughness = 0.8, emissive = 0.5)
  handle^ = mjolnir.spawn_mesh(engine, m, mat, pos + {0, 0.2, 0})
}

draw_path_debug :: proc(engine: ^mjolnir.Engine) {
  if !path_active || len(current_path) < 2 do return
  lift := [3]f32{0, 0.15, 0}
  for i in 0 ..< len(current_path) - 1 {
    mjolnir.debug_segment(engine, current_path[i] + lift, current_path[i + 1] + lift, {1.0, 0.8, 0.0, 1.0})
  }
}

find_navmesh_point_from_mouse :: proc(engine: ^mjolnir.Engine, mx, my: f32) -> ([3]f32, bool) {
  cam, ok := mjolnir.main_camera(engine)
  if !ok do return {}, false
  ray_origin, ray_dir := world.camera_viewport_to_world_ray(cam, mx, my)
  if math.abs(ray_dir.y) > 0.001 {
    t := -ray_origin.y / ray_dir.y
    if t > 0 && t < 1000 {
      gi := ray_origin + ray_dir * t
      if pos, ok := mjolnir.find_nearest_point(engine, gi, {2, 5, 2}); ok do return pos, true
    }
  }
  samples := [10]f32{5, 10, 15, 20, 25, 30, 35, 40, 50, 60}
  for dist in samples {
    if pos, ok := mjolnir.find_nearest_point(engine, ray_origin + ray_dir * dist, {5, 10, 5}); ok do return pos, true
  }
  return {}, false
}

demo_mouse_pressed :: proc(engine: ^mjolnir.Engine, button, action, mods: int) {
  if action != glfw.PRESS do return
  mx, my := glfw.GetCursorPos(engine.window)
  if button != glfw.MOUSE_BUTTON_RIGHT do return
  pos, valid := find_navmesh_point_from_mouse(engine, f32(mx), f32(my))
  if !valid { log.warn("No valid navmesh position found at click location"); return }
  end_pos = pos
  log.infof("Destination set to: %v", pos)
  update_position_marker(engine, &end_marker_handle, pos, {1, 0, 0, 1})
  start_find_path(engine)
}

demo_update :: proc(engine: ^mjolnir.Engine, dt: f32) {
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
      mjolnir.translate(engine, agent_handle, agent_pos + {0, 1, 0})
    }
  }
}

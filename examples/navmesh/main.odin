package main

import "../../mjolnir"
import "../../mjolnir/input"
import "../../mjolnir/platform"
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

nav_builder: bake.NavGeometryBuilder
navmesh_node_handle: world.NodeHandle
path_spawn_time: f32

TAG_ENVIRONMENT :: u32(1 << 0)
TAG_OBSTACLE :: u32(1 << 1)
path_active: bool
navmesh: nav.NavMesh

App :: struct {
  window:   platform.Platform,
  scene:    world.World,
  renderer: render.Manager,
  input:    input.State,
}

main :: proc() {
  context.logger = log.create_console_logger()
  defer {
    nav.destroy(&navmesh)
    bake.builder_destroy(&nav_builder)
  }
  app := new(App)
  defer free(app)
  w := &app.window
  if !platform.init(w, 800, 600, "Navigation Mesh") do return
  defer platform.shutdown(w)
  if !render.init(&app.renderer, "Navigation Mesh", platform.vulkan_instance_extensions(), platform.vulkan_get_instance_proc_addr(), platform.create_surface, w, platform.framebuffer_size(w), platform.dpi_scale(w)) do return
  defer render.shutdown(&app.renderer)
  if !world.init(&app.scene) do return
  defer world.shutdown(&app.scene)
  render.load_environment_map(&app.renderer, "assets/Cannon_Exterior.hdr")
  demo_setup(app)
  mjolnir.run(mjolnir.Loop(App){app = app, should_close = should_close, update = update, frame = frame})
}

should_close :: proc(app: ^App) -> bool {
  return platform.should_close(&app.window)
}

frame :: proc(app: ^App) -> bool {
  platform.poll_events(&app.window)
  return render.frame(&app.renderer, platform.framebuffer_size(&app.window), platform.dpi_scale(&app.window))
}

spawn_mesh :: proc(app: ^App, mesh_handle: render.MeshHandle, material: render.MaterialHandle, pos: [3]f32 = {}) -> world.NodeHandle {
  n := world.spawn(&app.scene, pos)
  render.attach(&app.renderer, n.index, render.MeshAttachment{handle = mesh_handle, material = material, cast_shadow = true})
  return n
}

demo_setup :: proc(app: ^App) {
  log.info("Navigation mesh demo setup with world integration")
  bake.builder_destroy(&nav_builder)
  render.main_camera_look_at(&app.renderer, {35, 25, 35}, {0, 0, 0})

  create_demo_scene(app)

  setup_navigation_mesh(app)
  agent_pos = {-20, 0, -20}
  end_pos = {20, 0, 20}
  update_position_marker(app, &end_marker_handle, end_pos, {1, 0, 0, 1})
  create_agent(app)
  start_find_path(app)
}

create_demo_scene :: proc(app: ^App) {
  ground_geom := mesh.make_quad({0.2, 0.6, 0.2, 1.0})
  for &v in ground_geom.vertices { v.position.x *= 50; v.position.z *= 50 }
  bake.append_triangles(&nav_builder, mesh.positions(ground_geom, context.temp_allocator), ground_geom.indices)
  ground_mesh := render.create_mesh(&app.renderer, ground_geom)
  ground_mat := render.material_pbr(&app.renderer, metallic = 0.1, roughness = 0.8, emissive = 0.02)
  ground_handle = spawn_mesh(app, ground_mesh, ground_mat)
  world.tag(&app.scene, ground_handle, TAG_ENVIRONMENT)

  obstacle_positions := [][3]f32{{-10, 1.5, -10}, {10, 1.5, -10}, {-10, 1.5, 10}, {10, 1.5, 10}, {0, 2, 0}}
  obstacle_sizes := [][3]f32{{2, 3, 2}, {2, 3, 2}, {2, 3, 2}, {2, 3, 2}, {4, 4, 4}}
  for pos, i in obstacle_positions {
    size := obstacle_sizes[i]
    g := mesh.make_cube({0.8, 0.2, 0.2, 1.0})
    for &v in g.vertices { v.position.x *= size.x; v.position.y *= size.y; v.position.z *= size.z }
    bake.append_triangles(&nav_builder, mesh.positions(g, context.temp_allocator), g.indices, pos, true)
    mh := render.create_mesh(&app.renderer, g)
    mat := render.material_pbr(&app.renderer, metallic = 0.3, roughness = 0.7, emissive = 0.1)
    h := spawn_mesh(app, mh, mat, pos)
    world.tag(&app.scene, h, TAG_OBSTACLE)
    append(&obstacle_handles, h)
  }
  log.infof("Created demo scene with ground and %d obstacles", len(obstacle_handles))
}

create_agent :: proc(app: ^App) {
  agent_geom := mesh.make_cylinder(16, 2, 0.5, {0.2, 0.5, 1.0, 1.0})
  mh := render.create_mesh(&app.renderer, agent_geom)
  mat := render.material_pbr(&app.renderer, metallic = 0.3, roughness = 0.6, emissive = 0.3)
  agent_handle = spawn_mesh(app, mh, mat, agent_pos + {0, 1, 0})
  world.node(&app.scene, agent_handle).name = "agent"
}

setup_navigation_mesh :: proc(app: ^App) {
  if len(nav_builder.vertices) == 0 || len(nav_builder.indices) == 0 {
    log.error("No source geometry available for navmesh generation"); return
  }
  if !bake.build(&navmesh, &nav_builder) {
    log.error("Failed to build navmesh"); return
  }
  visualize_navmesh(app)
}

visualize_navmesh :: proc(app: ^App) {
  world.despawn(&app.scene, navmesh_node_handle)
  positions, indices := nav.debug_triangles(&navmesh, context.temp_allocator)
  navmesh_geom := mesh.from_triangles(positions, indices)
  log.infof("Built navmesh visualization geometry: %d vertices, %d indices", len(navmesh_geom.vertices), len(navmesh_geom.indices))
  m, m_ok := render.create_mesh(&app.renderer, navmesh_geom)
  if !m_ok { log.error("Failed to create navmesh visualization mesh"); return }
  mat, mat_ok := render.create_material(&app.renderer, type = .RANDOM_COLOR, base_color_factor = {1.0, 0.8, 0.3, 0.3})
  if !mat_ok { log.error("Failed to create navmesh material"); return }
  navmesh_node_handle = spawn_mesh(app, m, mat)
}

start_find_path :: proc(app: ^App) {
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

update_position_marker :: proc(app: ^App, handle: ^world.NodeHandle, pos: [3]f32, color: [4]f32) {
  world.despawn(&app.scene, handle^)
  g := mesh.make_sphere(12, 6, 0.3, color)
  m := render.create_mesh(&app.renderer, g)
  mat := render.material_pbr(&app.renderer, metallic = 0.2, roughness = 0.8, emissive = 0.5)
  handle^ = spawn_mesh(app, m, mat, pos + {0, 0.2, 0})
}

draw_path_debug :: proc(app: ^App) {
  if !path_active || len(current_path) < 2 do return
  lift := [3]f32{0, 0.15, 0}
  for i in 0 ..< len(current_path) - 1 {
    render.debug_segment(&app.renderer, current_path[i] + lift, current_path[i + 1] + lift, {1.0, 0.8, 0.0, 1.0})
  }
}

find_navmesh_point_from_mouse :: proc(app: ^App) -> ([3]f32, bool) {
  ray_origin, ray_dir, ok := render.cursor_ray(&app.renderer, app.input.cursor)
  if !ok do return {}, false
  return nav.raycast(&navmesh, ray_origin, ray_dir)
}

demo_mouse_pressed :: proc(app: ^App) {
  if app.input.mouse_captured || !input.mouse_pressed(&app.input, .RIGHT) do return
  pos, valid := find_navmesh_point_from_mouse(app)
  if !valid { log.warn("No valid navmesh position found at click location"); return }
  end_pos = pos
  log.infof("Destination set to: %v", pos)
  update_position_marker(app, &end_marker_handle, pos, {1, 0, 0, 1})
  start_find_path(app)
}

update :: proc(app: ^App, dt: f32) {
  platform.read_input(&app.window, &app.input)
  if cam, ok := render.main_camera(&app.renderer); ok && !app.input.mouse_captured {
    yaw, pitch, dist := render.camera_orbit_state(cam)
    if input.mouse_down(&app.input, .LEFT) {
      yaw += app.input.mouse_delta.x * 0.02
      pitch = clamp(pitch + app.input.mouse_delta.y * 0.02, -1.5, 1.5)
    }
    render.camera_orbit(cam, yaw, pitch, clamp(dist - app.input.scroll.y * 2, 1, 200))
  }
  demo_mouse_pressed(app)
  if path_active {
    path_spawn_time += dt
    if path_spawn_time >= 5.0 do path_active = false
    else                       do draw_path_debug(app)
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
      world.translate(&app.scene, agent_handle, agent_pos + {0, 1, 0})
    }
  }
  world.update(&app.scene)
  for i in world.removed_nodes(&app.scene) do render.stage_slot_removal(&app.renderer, i)
  render.stage_transforms(&app.renderer, world.changed_nodes(&app.scene))
  render.update(&app.renderer, dt)
}

package main
import "../../../mjolnir"
import "../../../mjolnir/geometry"
import "../../../mjolnir/navigation/detour"
import "../../../mjolnir/navigation/recast"
import navigation_renderer "../../../mjolnir/render/navigation"
import "../../../mjolnir/resources"
import "../../../mjolnir/world"
import "core:fmt"
import "core:log"
import "core:math"
import "core:math/rand"
import "vendor:glfw"
import mu "vendor:microui"

demo_state: struct {
  nav_mesh_handle:       resources.Handle,
  nav_context_handle:    resources.Handle,
  // Pathfinding state
  start_pos:             [3]f32,
  end_pos:               [3]f32,
  current_path:          [][3]f32,
  has_path:              bool,
  // Visual markers
  start_marker_handle:   resources.Handle,
  end_marker_handle:     resources.Handle,
  path_waypoint_handles: [dynamic]resources.Handle,
  // Demo scene nodes
  ground_handle:         resources.Handle,
  obstacle_handles:      [dynamic]resources.Handle,
  // OBJ file support
  obj_mesh_handle:       resources.Handle,
  obj_node_handle:       resources.Handle,
  obj_mesh_node:         ^world.Node,
  show_original_mesh:    bool,
  use_procedural:        bool,
  // Camera control
  camera_auto_rotate:    bool,
  camera_distance:       f32,
  camera_height:         f32,
  camera_angle:          f32,
  // Mouse picking
  last_mouse_pos:        [2]f32,
  mouse_move_threshold:  f32,
  // Navigation mesh info
  navmesh_info:          string,
} = {
  camera_distance      = 40,
  camera_height        = 25,
  camera_angle         = 0,
  camera_auto_rotate   = false,
  mouse_move_threshold = 5.0,
  show_original_mesh   = true,
  use_procedural       = true,
}

main :: proc() {
  context.logger = log.create_console_logger()
  engine := new(mjolnir.Engine)
  engine.setup_proc = demo_setup
  engine.update_proc = demo_update
  engine.post_render_proc = demo_render2d
  engine.mouse_press_proc = demo_mouse_pressed
  engine.mouse_move_proc = demo_mouse_moved
  mjolnir.run(engine, 800, 600, "Navigation Mesh Visual Test")
}

demo_setup :: proc(engine: ^mjolnir.Engine) {
  using mjolnir, geometry
  log.info("Navigation mesh demo setup with world integration")
  demo_state.obstacle_handles = make([dynamic]resources.Handle, 0)
  demo_state.path_waypoint_handles = make([dynamic]resources.Handle, 0)
  demo_state.camera_auto_rotate = false
  // engine.debug_ui_enabled = true
  main_camera := get_main_camera(engine)
  if main_camera != nil {
    camera_look_at(main_camera, {35, 25, 35}, {0, 0, 0}, {0, 1, 0})
  }
  if demo_state.use_procedural {
    create_demo_scene(engine)
  }
  setup_navigation_mesh(engine)
  demo_state.start_pos = {-20, 0, -20}
  demo_state.end_pos = {20, 0, 20}
  update_position_marker(
    engine,
    &demo_state.start_marker_handle,
    demo_state.start_pos,
    {0, 1, 0, 1},
  )
  update_position_marker(
    engine,
    &demo_state.end_marker_handle,
    demo_state.end_pos,
    {1, 0, 0, 1},
  )
  find_path(engine)
  // engine.debug_ui_enabled = true
  log.info("Navigation mesh demo setup complete")
}

create_demo_scene :: proc(engine: ^mjolnir.Engine) {
  using mjolnir, geometry
  log.info("Creating demo scene with world nodes")
  ground_geom := geometry.make_quad([4]f32{0.2, 0.6, 0.2, 1.0})
  for &vertex in ground_geom.vertices {
    vertex.position.x *= 50
    vertex.position.z *= 50
  }
  ground_mesh_handle, ground_mesh_ok := create_mesh(engine, ground_geom)
  ground_material_handle, ground_material_ok := create_material(
    engine,
    metallic_value = 0.1,
    roughness_value = 0.8,
    emissive_value = 0.02,
  )
  if ground_mesh_ok && ground_material_ok {
    demo_state.ground_handle = spawn(
      engine,
      world.MeshAttachment {
        handle              = ground_mesh_handle,
        material            = ground_material_handle,
        cast_shadow         = false,
        navigation_obstacle = false, // Ground should be walkable
      },
    )
  }
  obstacle_positions := [][3]f32 {
    {-10, 1.5, -10}, // Obstacle 1
    {10, 1.5, -10}, // Obstacle 2
    {-10, 1.5, 10}, // Obstacle 3
    {10, 1.5, 10}, // Obstacle 4
    {0, 2, 0}, // Central obstacle (taller)
  }
  obstacle_sizes := [][3]f32 {
    {2, 3, 2}, // Small obstacles
    {2, 3, 2},
    {2, 3, 2},
    {2, 3, 2},
    {4, 4, 4}, // Larger central obstacle
  }
  for position, i in obstacle_positions {
    size := obstacle_sizes[i]
    obstacle_geom := geometry.make_cube([4]f32{0.8, 0.2, 0.2, 1.0})
    for &vertex in obstacle_geom.vertices {
      vertex.position.x *= size.x
      vertex.position.y *= size.y
      vertex.position.z *= size.z
    }
    obstacle_mesh_handle, obstacle_mesh_ok := create_mesh(
      engine,
      obstacle_geom,
    )
    obstacle_material_handle, obstacle_material_ok := create_material(
      engine,
      metallic_value = 0.3,
      roughness_value = 0.7,
      emissive_value = 0.1,
    )
    if obstacle_mesh_ok && obstacle_material_ok {
      obstacle_handle := spawn_at(
        engine,
        position,
        world.MeshAttachment {
          handle              = obstacle_mesh_handle,
          material            = obstacle_material_handle,
          cast_shadow         = true,
          navigation_obstacle = true, // Mark as navigation obstacle
        },
      )
      append(&demo_state.obstacle_handles, obstacle_handle)
    }
  }
  log.infof(
    "Created demo scene with ground and %d obstacles",
    len(demo_state.obstacle_handles),
  )
}

create_obj_visualization_mesh :: proc(
  engine: ^mjolnir.Engine,
  obj_file: string,
) {
  using mjolnir, geometry
  log.infof("Creating OBJ visualization from file: %s", obj_file)
  geom, ok := geometry.load_obj(obj_file, 1.0)
  if !ok {
    log.error("Failed to load OBJ file as geometry")
    return
  }
  obj_mesh_handle, obj_mesh_ok := create_mesh(engine, geom)
  if obj_mesh_ok {
    demo_state.obj_mesh_handle = obj_mesh_handle
  } else {
    demo_state.obj_mesh_handle = {}
  }
  obj_material_handle, obj_material_ok := create_material(
    engine,
    metallic_value = 0.1,
    roughness_value = 0.8,
    emissive_value = 0.02,
  )
  obj_spawn_ok: bool
  if obj_mesh_ok && obj_material_ok {
    demo_state.obj_node_handle, obj_spawn_ok =
      spawn_at(
        engine,
        [3]f32{0, 0, 0},
        world.MeshAttachment {
          handle              = demo_state.obj_mesh_handle,
          material            = obj_material_handle,
          cast_shadow         = false,
          navigation_obstacle = false, // OBJ mesh should be walkable
        },
      )
    demo_state.obj_mesh_node = get_node(engine, demo_state.obj_mesh_handle)
  }
  if obj_spawn_ok {
    demo_state.obj_mesh_node.name = "obj_mesh"
    demo_state.show_original_mesh = true
    log.infof(
      "Created OBJ visualization mesh with %d vertices",
      len(geom.vertices),
    )
  }
}

setup_navigation_mesh :: proc(engine: ^mjolnir.Engine) {
  using mjolnir
  log.info("Setting up navigation mesh with visualization")
  config := recast.Config {
      cs                       = 0.3, // Cell size
      ch                       = 0.2, // Cell height
      walkable_slope_angle     = 45, // Max slope
      walkable_height          = i32(math.ceil_f32(2.0 / 0.2)), // Agent height
      walkable_climb           = i32(math.floor_f32(0.9 / 0.2)), // Agent max climb
      walkable_radius          = i32(math.ceil_f32(0.6 / 0.3)), // Agent radius
      max_edge_len             = i32(12.0 / 0.3), // Max edge length
      max_simplification_error = 1.3,
      min_region_area          = 8 * 8,
      merge_region_area        = 20 * 20,
      max_verts_per_poly       = 6,
      detail_sample_dist       = 6.0 * 0.3,
      detail_sample_max_error  = 1.0 * 0.2,
      border_size              = 0,
    }
  nav_mesh_handle, success := build_and_visualize_navigation_mesh(
    engine,
    config,
  )
  if !success {
    log.error("Failed to build navigation mesh from world")
    return
  }
  demo_state.nav_mesh_handle = nav_mesh_handle
  log.infof("Navigation mesh built with handle %v", nav_mesh_handle)
  context_handle, context_ok := create_navigation_context(
    engine,
    nav_mesh_handle,
  )
  if !context_ok {
    log.error("Failed to create navigation context")
    return
  }
  demo_state.nav_context_handle = context_handle
  log.infof("Navigation context created with handle %v", context_handle)
  renderer := &engine.render.navigation
  renderer.enabled = true
  renderer.color_mode = .Random_Colors
  log.info("Navigation mesh building and visualization complete")
}

find_path :: proc(engine: ^mjolnir.Engine) {
  using mjolnir
  if demo_state.nav_context_handle.generation == 0 {
    log.error("No navigation context available for pathfinding")
    return
  }
  log.infof(
    "Finding path from (%.2f, %.2f, %.2f) to (%.2f, %.2f, %.2f)",
    demo_state.start_pos.x,
    demo_state.start_pos.y,
    demo_state.start_pos.z,
    demo_state.end_pos.x,
    demo_state.end_pos.y,
    demo_state.end_pos.z,
  )
  path := nav_find_path(
    engine,
    demo_state.nav_context_handle,
    demo_state.start_pos,
    demo_state.end_pos,
    256,
  )
  if path != nil && len(path) > 0 {
    delete(demo_state.current_path)
    demo_state.current_path = path
    demo_state.has_path = true
    log.infof("Path found with %d waypoints", len(path))
    for point, idx in path {
      log.infof(
        "  Waypoint %d: (%.2f, %.2f, %.2f)",
        idx,
        point.x,
        point.y,
        point.z,
      )
    }
    visualize_path(engine)
  } else {
    log.warn("Failed to find path")
    demo_state.has_path = false
    clear_path_visualization(engine)
  }
}

update_position_marker :: proc(
  engine: ^mjolnir.Engine,
  handle: ^resources.Handle,
  pos: [3]f32,
  color: [4]f32,
) {
  using mjolnir, geometry
  if handle.generation != 0 {
    despawn(engine, handle^)
  }
  marker_geom := geometry.make_sphere(12, 6, 0.3, color)
  marker_mesh_handle, marker_mesh_ok := create_mesh(engine, marker_geom)
  marker_material_handle, marker_material_ok := create_material(
    engine,
    metallic_value = 0.2,
    roughness_value = 0.8,
    emissive_value = 0.5,
  )
  node: ^world.Node
  spawn_ok: bool
  if marker_mesh_ok && marker_material_ok {
    handle^, spawn_ok = spawn_at(
      engine,
      pos + [3]f32{0, 0.2, 0}, // Slightly above ground
      world.MeshAttachment {
        handle              = marker_mesh_handle,
        material            = marker_material_handle,
        cast_shadow         = false,
        navigation_obstacle = false, // Markers should not be obstacles
      },
    )
  }
  if !spawn_ok do handle^ = {}
}

visualize_path :: proc(engine: ^mjolnir.Engine) {
  using mjolnir, geometry
  clear_path_visualization(engine)
  if !demo_state.has_path || len(demo_state.current_path) == 0 {
    return
  }
  renderer := &engine.render.navigation
  if len(demo_state.current_path) >= 2 {
    log.infof(
      "Updating path renderer with %d points",
      len(demo_state.current_path),
    )
    navigation_renderer.update_path(
      renderer,
      demo_state.current_path[:],
      {1.0, 0.8, 0.0, 1.0},
    ) // Orange/yellow path
  } else if len(demo_state.current_path) == 1 {
    log.info("Path has only 1 point - need at least 2 points to draw a line")
    navigation_renderer.clear_path(renderer)
  } else {
    navigation_renderer.clear_path(renderer)
  }
  log.infof("Path visualization updated using navigation renderer")
}

clear_path_visualization :: proc(engine: ^mjolnir.Engine) {
  using mjolnir
  for handle in demo_state.path_waypoint_handles {
    despawn(engine, handle)
  }
  clear(&demo_state.path_waypoint_handles)
  renderer := &engine.render.navigation
  navigation_renderer.clear_path(renderer)
}

find_navmesh_point_from_mouse :: proc(
  engine: ^mjolnir.Engine,
  mouse_x, mouse_y: f32,
) -> (
  pos: [3]f32,
  found: bool,
) {
  if demo_state.nav_context_handle.generation == 0 {
    return {}, false
  }
  width, height := glfw.GetWindowSize(engine.window)
  log.debugf(
    "Mouse coordinates: (%.2f, %.2f), Window size: (%d, %d)",
    mouse_x,
    mouse_y,
    width,
    height,
  )
  // GLFW returns coordinates with origin at top-left, Y increases downward
  camera := mjolnir.get_main_camera(engine)
  ray_origin, ray_dir := resources.camera_viewport_to_world_ray(
    camera,
    mouse_x,
    mouse_y,
  )
  log.debugf(
    "Ray: origin=(%.2f, %.2f, %.2f), dir=(%.2f, %.2f, %.2f)",
    ray_origin.x,
    ray_origin.y,
    ray_origin.z,
    ray_dir.x,
    ray_dir.y,
    ray_dir.z,
  )
  // Strategy 1: Try intersection with ground plane (y=0) first
  if abs(ray_dir.y) > 0.001 {
    t := -ray_origin.y / ray_dir.y
    if t > 0 && t < 1000 {   // Reasonable distance
      ground_intersection := ray_origin + ray_dir * t
      log.debugf(
        "Ground plane intersection: (%.2f, %.2f, %.2f)",
        ground_intersection.x,
        ground_intersection.y,
        ground_intersection.z,
      )
      search_extents := [3]f32{2.0, 5.0, 2.0}
      nearest_pos, found := mjolnir.nav_find_nearest_point(
        engine,
        demo_state.nav_context_handle,
        ground_intersection,
        search_extents,
      )
      if found {
        log.debugf(
          "Found navmesh point via ground intersection: (%.2f, %.2f, %.2f)",
          nearest_pos.x,
          nearest_pos.y,
          nearest_pos.z,
        )
        return nearest_pos, true
      }
    }
  }
  // Strategy 2: Sample along the ray at various distances (fallback)
  sample_distances := [10]f32{5, 10, 15, 20, 25, 30, 35, 40, 50, 60}
  for dist in sample_distances {
    sample_pos := ray_origin + ray_dir * dist
    log.debugf(
      "Testing ray sample at distance %.1f: (%.2f, %.2f, %.2f)",
      dist,
      sample_pos.x,
      sample_pos.y,
      sample_pos.z,
    )
    search_extents := [3]f32{5.0, 10.0, 5.0}
    nearest_pos, found := mjolnir.nav_find_nearest_point(
      engine,
      demo_state.nav_context_handle,
      sample_pos,
      search_extents,
    )
    if found {
      log.debugf(
        "Found navmesh point via ray sampling at distance %.1f: (%.2f, %.2f, %.2f)",
        dist,
        nearest_pos.x,
        nearest_pos.y,
        nearest_pos.z,
      )
      return nearest_pos, true
    }
  }
  log.warn("No navmesh point found for mouse click")
  return {}, false
}

generate_random_path :: proc(engine: ^mjolnir.Engine) {
  demo_state.start_pos = {
    rand.float32_range(-15, 15),
    0,
    rand.float32_range(-15, 15),
  }
  demo_state.end_pos = {
    rand.float32_range(-15, 15),
    0,
    rand.float32_range(-15, 15),
  }
  log.infof(
    "Generated random path: start=(%.2f, %.2f, %.2f) end=(%.2f, %.2f, %.2f)",
    demo_state.start_pos.x,
    demo_state.start_pos.y,
    demo_state.start_pos.z,
    demo_state.end_pos.x,
    demo_state.end_pos.y,
    demo_state.end_pos.z,
  )
  update_position_marker(
    engine,
    &demo_state.start_marker_handle,
    demo_state.start_pos,
    {0, 1, 0, 1},
  )
  update_position_marker(
    engine,
    &demo_state.end_marker_handle,
    demo_state.end_pos,
    {1, 0, 0, 1},
  )
  find_path(engine)
}

demo_mouse_pressed :: proc(
  engine: ^mjolnir.Engine,
  button, action, mods: int,
) {
  using mjolnir
  if action != glfw.PRESS {
    return
  }
  mouse_x, mouse_y := glfw.GetCursorPos(engine.window)
  switch button {
  case glfw.MOUSE_BUTTON_LEFT:
    pos, valid := find_navmesh_point_from_mouse(
      engine,
      f32(mouse_x),
      f32(mouse_y),
    )
    if valid {
      demo_state.start_pos = pos
      log.infof(
        "Start position set to: (%.2f, %.2f, %.2f)",
        pos.x,
        pos.y,
        pos.z,
      )
      update_position_marker(
        engine,
        &demo_state.start_marker_handle,
        pos,
        {0, 1, 0, 1},
      )
      demo_state.has_path = false
    } else {
      log.warn("No valid navmesh position found at click location")
    }
  case glfw.MOUSE_BUTTON_RIGHT:
    pos, valid := find_navmesh_point_from_mouse(
      engine,
      f32(mouse_x),
      f32(mouse_y),
    )
    if valid {
      demo_state.end_pos = pos
      log.infof("End position set to: (%.2f, %.2f, %.2f)", pos.x, pos.y, pos.z)
      update_position_marker(
        engine,
        &demo_state.end_marker_handle,
        pos,
        {1, 0, 0, 1},
      )
      find_path(engine)
    } else {
      log.warn("No valid navmesh position found at right click location")
    }
  case glfw.MOUSE_BUTTON_MIDDLE:
    demo_state.camera_auto_rotate = !demo_state.camera_auto_rotate
  }
}

demo_mouse_moved :: proc(engine: ^mjolnir.Engine, pos, delta: [2]f64) {
  demo_state.last_mouse_pos = [2]f32{f32(pos.x), f32(pos.y)}
}

demo_update :: proc(engine: ^mjolnir.Engine, delta_time: f32) {
  using mjolnir, geometry
  main_camera := get_main_camera(engine)
  if main_camera != nil {
    if demo_state.camera_auto_rotate {
      demo_state.camera_angle += delta_time * 0.2
    }
    camera_x := math.cos(demo_state.camera_angle) * demo_state.camera_distance
    camera_z := math.sin(demo_state.camera_angle) * demo_state.camera_distance
    camera_pos := [3]f32{camera_x, demo_state.camera_height, camera_z}
    camera_look_at(main_camera, camera_pos, {0, 0, 0}, {0, 1, 0})
  }
}

demo_render2d :: proc(engine: ^mjolnir.Engine) {
  using mjolnir
  ctx := &engine.render.ui.ctx
  if mu.window(ctx, "Navigation Mesh Demo", {40, 40, 380, 500}, {.NO_CLOSE}) {
    mu.label(ctx, "World-Integrated Navigation System")
    if demo_state.nav_mesh_handle.generation != 0 {
      mu.label(ctx, "Status: Navigation mesh ready")
      mu.label(ctx, "")
      mu.label(ctx, "NavMesh Settings:")
      renderer := &engine.render.navigation
      enabled := renderer.enabled
      if .CHANGE in mu.checkbox(ctx, "Show NavMesh", &enabled) {
        renderer.enabled = enabled
      }
      mu.label(ctx, "")
      mu.label(ctx, "Color Mode:")
      color_mode_names := [?]string {
        "Area Colors",
        "Uniform",
        "Height Based",
        "Random Colors",
        "Region Colors",
      }
      current_mode := int(renderer.color_mode)
      for name, i in color_mode_names {
        if i == current_mode {
          mu.label(ctx, fmt.tprintf("> %s", name))
        } else {
          if .SUBMIT in mu.button(ctx, name) {
            renderer.color_mode = auto_cast i
          }
        }
      }
      mu.label(ctx, "")
      mu.label(ctx, "Camera:")
      mu.checkbox(ctx, "Auto Rotate", &demo_state.camera_auto_rotate)
      mu.label(ctx, "")
      mu.label(ctx, "Pathfinding:")
      if demo_state.has_path {
        mu.label(
          ctx,
          fmt.tprintf("Path Points: %d", len(demo_state.current_path)),
        )
        mu.label(
          ctx,
          fmt.tprintf(
            "Start: (%.1f, %.1f, %.1f)",
            demo_state.start_pos.x,
            demo_state.start_pos.y,
            demo_state.start_pos.z,
          ),
        )
        mu.label(
          ctx,
          fmt.tprintf(
            "End: (%.1f, %.1f, %.1f)",
            demo_state.end_pos.x,
            demo_state.end_pos.y,
            demo_state.end_pos.z,
          ),
        )
      } else {
        mu.label(ctx, "No path set")
      }
      if .SUBMIT in mu.button(ctx, "Generate Random Path (SPACE)") {
        generate_random_path(engine)
      }
      if .SUBMIT in mu.button(ctx, "Clear Path (C)") {
        demo_state.has_path = false
        log.info("Path cleared")
      }
      if .SUBMIT in mu.button(ctx, "Rebuild NavMesh (R)") {
        setup_navigation_mesh(engine)
      }
      if demo_state.navmesh_info != "" {
        mu.label(ctx, "")
        mu.label(ctx, "NavMesh Info:")
        mu.label(ctx, demo_state.navmesh_info)
      }
      mu.label(ctx, "")
      mu.label(ctx, "Scene Type:")
      if demo_state.use_procedural {
        mu.label(ctx, "Procedural geometry")
      } else {
        mu.label(ctx, "OBJ file loaded")
        if demo_state.obj_mesh_node != nil {
          visibility_text :=
            demo_state.show_original_mesh ? "visible" : "hidden"
          mu.label(ctx, fmt.tprintf("Original mesh: %s", visibility_text))
          if .SUBMIT in mu.button(ctx, "Toggle Mesh (M)") {
            demo_state.show_original_mesh = !demo_state.show_original_mesh
          }
        }
      }
    } else {
      mu.label(ctx, "Status: Building navigation mesh...")
    }
    mu.label(ctx, "")
    mu.label(ctx, "Controls:")
    mu.label(ctx, "Left Click - Set Start")
    mu.label(ctx, "Right Click - Set End & Find Path")
    mu.label(ctx, "Middle Click - Toggle Auto Rotate")
    mu.label(ctx, "C - Clear Path")
    mu.label(ctx, "D - Cycle Color Modes")
    mu.label(ctx, "M - Toggle Original Mesh")
    mu.label(ctx, "P - Print NavMesh Info")
    mu.label(ctx, "R - Rebuild NavMesh")
    mu.label(ctx, "S - Save NavMesh")
    mu.label(ctx, "L - Load NavMesh")
    mu.label(ctx, "V - Toggle NavMesh")
    mu.label(ctx, "SPACE - Random Path")
  }
}

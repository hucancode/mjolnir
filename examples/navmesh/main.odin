package main
import "../../mjolnir"
import cont "../../mjolnir/containers"
import "../../mjolnir/geometry"
import "../../mjolnir/gpu"
import nav "../../mjolnir/navigation"
import "../../mjolnir/navigation/detour"
import "../../mjolnir/navigation/recast"
import "../../mjolnir/resources"
import "../../mjolnir/world"
import "core:fmt"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:math/rand"
import "vendor:glfw"
import mu "vendor:microui"

demo_state: struct {
  // Pathfinding state
  end_pos:              [3]f32,
  current_path:         [][3]f32,
  // Visual markers
  end_marker_handle:    resources.NodeHandle,
  // Agent
  agent_handle:         resources.NodeHandle,
  agent_pos:            [3]f32,
  agent_speed:          f32,
  current_waypoint_idx: int,
  path_completed:       bool,
  // Demo scene nodes
  ground_handle:        resources.NodeHandle,
  obstacle_handles:     [dynamic]resources.NodeHandle,
  // OBJ file support
  obj_mesh_handle:      resources.MeshHandle,
  obj_node_handle:      resources.NodeHandle,
  use_procedural:       bool,
  // Navigation mesh info
  navmesh_info:         string,
  // Debug draw handles
  navmesh_debug_handle: mjolnir.DebugObjectHandle,
} = {
  use_procedural = true,
  agent_speed    = 5.0,
  agent_pos      = {-20, 0, -20},
}

main :: proc() {
  context.logger = log.create_console_logger()
  engine := new(mjolnir.Engine)
  engine.setup_proc = demo_setup
  engine.update_proc = demo_update
  engine.mouse_press_proc = demo_mouse_pressed
  mjolnir.run(engine, 800, 600, "Navigation Mesh")
}

demo_setup :: proc(engine: ^mjolnir.Engine) {
  log.info("Navigation mesh demo setup with world integration")
  // Setup camera
  main_camera := mjolnir.get_main_camera(engine)
  if camera := mjolnir.get_main_camera(engine); camera != nil {
    mjolnir.camera_look_at(main_camera, {35, 25, 35}, {0, 0, 0})
    mjolnir.sync_active_camera_controller(engine)
  }
  if demo_state.use_procedural {
    create_demo_scene(engine)
  } else {
    create_obj_visualization_mesh(engine, "assets/nav_test.obj")
  }
  setup_navigation_mesh(engine)
  demo_state.agent_pos = {-20, 0, -20}
  demo_state.end_pos = {20, 0, 20}
  update_position_marker(
    engine,
    &demo_state.end_marker_handle,
    demo_state.end_pos,
    {1, 0, 0, 1},
  )
  create_agent(engine)
  start_find_path(engine)
  log.info("Navigation mesh demo setup complete")
}

create_demo_scene :: proc(engine: ^mjolnir.Engine) {
  log.info("Creating demo scene with world nodes")
  ground_geom := geometry.make_quad([4]f32{0.2, 0.6, 0.2, 1.0})
  for &vertex in ground_geom.vertices {
    vertex.position.x *= 50
    vertex.position.z *= 50
  }
  ground_mesh_handle, ground_mesh_ok := mjolnir.create_mesh(engine, ground_geom)
  ground_material_handle, ground_material_ok := mjolnir.create_material(
    engine,
    metallic_value = 0.1,
    roughness_value = 0.8,
    emissive_value = 0.02,
  )
  if ground_mesh_ok && ground_material_ok {
    demo_state.ground_handle = mjolnir.spawn(
      engine,
      attachment = world.MeshAttachment {
        handle = ground_mesh_handle,
        material = ground_material_handle,
      },
    )
    // Tag as environment for baking
    if ground_node, ok := mjolnir.get_node(engine, demo_state.ground_handle); ok {
      ground_node.tags += {.ENVIRONMENT}
    }
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
    obstacle_mesh_handle, obstacle_mesh_ok := mjolnir.create_mesh(
      engine,
      obstacle_geom,
    )
    obstacle_material_handle, obstacle_material_ok := mjolnir.create_material(
      engine,
      metallic_value = 0.3,
      roughness_value = 0.7,
      emissive_value = 0.1,
    )
    if obstacle_mesh_ok && obstacle_material_ok {
      obstacle_handle := mjolnir.spawn(
        engine,
        position,
        world.MeshAttachment {
          handle = obstacle_mesh_handle,
          material = obstacle_material_handle,
        },
      )
      // Tag obstacles as NAVMESH_OBSTACLE for baking
      if obstacle_node, ok := mjolnir.get_node(engine, obstacle_handle); ok {
        obstacle_node.tags += {.NAVMESH_OBSTACLE}
      }
      append(&demo_state.obstacle_handles, obstacle_handle)
    }
  }
  log.infof(
    "Created demo scene with ground and %d obstacles",
    len(demo_state.obstacle_handles),
  )
}

create_agent :: proc(engine: ^mjolnir.Engine) {
  log.info("Creating agent cylinder")
  // Create a cylinder geometry for the agent
  agent_geom := geometry.make_cylinder(16, 2, 0.5, {0.2, 0.5, 1.0, 1.0})
  agent_mesh_handle, agent_mesh_ok := mjolnir.create_mesh(engine, agent_geom)
  agent_material_handle, agent_material_ok := mjolnir.create_material(
    engine,
    metallic_value = 0.3,
    roughness_value = 0.6,
    emissive_value = 0.3,
  )
  if agent_mesh_ok && agent_material_ok {
    demo_state.agent_handle = mjolnir.spawn(
      engine,
      demo_state.agent_pos + [3]f32{0, 1, 0}, // Raise to half height
      world.MeshAttachment {
        handle = agent_mesh_handle,
        material = agent_material_handle,
      },
    )
    if agent_node, ok := mjolnir.get_node(engine, demo_state.agent_handle); ok {
      agent_node.name = "agent"
      log.info("Agent cylinder created successfully")
    }
  }
}

create_obj_visualization_mesh :: proc(
  engine: ^mjolnir.Engine,
  obj_file: string,
) {
  log.infof("Creating OBJ visualization from file: %s", obj_file)
  geom, ok := geometry.load_obj(obj_file, 1.0)
  if !ok {
    log.error("Failed to load OBJ file as geometry")
    return
  }
  obj_mesh_handle, obj_mesh_ok := mjolnir.create_mesh(engine, geom)
  if obj_mesh_ok {
    demo_state.obj_mesh_handle = obj_mesh_handle
  } else {
    demo_state.obj_mesh_handle = {}
  }
  obj_material_handle, obj_material_ok := mjolnir.create_material(
    engine,
    metallic_value = 0.1,
    roughness_value = 0.8,
    emissive_value = 0.02,
  )
  obj_spawn_ok: bool
  if obj_mesh_ok && obj_material_ok {
    demo_state.obj_node_handle, obj_spawn_ok = mjolnir.spawn(
      engine,
      [3]f32{0, 0, 0},
      world.MeshAttachment {
        handle = demo_state.obj_mesh_handle,
        material = obj_material_handle,
      },
    )
  }
  if node, ok := mjolnir.get_node(engine, demo_state.obj_node_handle); ok {
    node.name = "obj_mesh"
    node.tags += {.ENVIRONMENT}
    log.infof(
      "Created OBJ visualization mesh with %d vertices",
      len(geom.vertices),
    )
  }
}

setup_navigation_mesh :: proc(engine: ^mjolnir.Engine) {
  log.info("Setting up navigation mesh with visualization")
  if !mjolnir.setup_navmesh(engine) {
    log.error("Failed to setup navigation mesh")
    return
  }
  visualize_navmesh(engine)
  log.info("Navigation mesh building and visualization complete")
}

visualize_navmesh :: proc(engine: ^mjolnir.Engine) {
  if demo_state.navmesh_debug_handle != {} {
    mjolnir.debug_draw_destroy(engine, demo_state.navmesh_debug_handle)
    demo_state.navmesh_debug_handle = {}
  }
  navmesh_geom := nav.build_geometry(&engine.nav_sys.nav_mesh)
  log.infof(
    "Built navmesh visualization geometry: %d vertices, %d indices",
    len(navmesh_geom.vertices),
    len(navmesh_geom.indices),
  )
  // NOTE: create_mesh takes ownership of geometry and will delete it
  navmesh_mesh_handle, mesh_ok := mjolnir.create_mesh(engine, navmesh_geom)
  if !mesh_ok {
    log.error("Failed to create navmesh visualization mesh")
    return
  }
  demo_state.navmesh_debug_handle = mjolnir.debug_draw_spawn_mesh(
    engine,
    navmesh_mesh_handle,
    linalg.MATRIX4F32_IDENTITY,
    {1.0, 0.8, 0.3, 0.2},
    .RANDOM_COLOR,
  )
  log.infof(
    "Navmesh visualization spawned with debug draw %v %v",
    navmesh_mesh_handle,
    demo_state.navmesh_debug_handle,
  )
}

start_find_path :: proc(engine: ^mjolnir.Engine) {
  log.infof(
    "Finding path from (%.2f, %.2f, %.2f) to (%.2f, %.2f, %.2f)",
    demo_state.agent_pos.x,
    demo_state.agent_pos.y,
    demo_state.agent_pos.z,
    demo_state.end_pos.x,
    demo_state.end_pos.y,
    demo_state.end_pos.z,
  )
  path := mjolnir.find_path(engine, demo_state.agent_pos, demo_state.end_pos, 256)
  if path != nil && len(path) > 0 {
    delete(demo_state.current_path)
    demo_state.current_path = path
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
    // Start following the path
    demo_state.current_waypoint_idx = 0
    demo_state.path_completed = false
  }
}

update_position_marker :: proc(
  engine: ^mjolnir.Engine,
  handle: ^resources.NodeHandle,
  pos: [3]f32,
  color: [4]f32,
) {
  mjolnir.despawn(engine, handle^)
  marker_geom := geometry.make_sphere(12, 6, 0.3, color)
  marker_mesh_handle, marker_mesh_ok := mjolnir.create_mesh(engine, marker_geom)
  marker_material_handle, marker_material_ok := mjolnir.create_material(
    engine,
    metallic_value = 0.2,
    roughness_value = 0.8,
    emissive_value = 0.5,
  )
  node: ^world.Node
  spawn_ok: bool
  if marker_mesh_ok && marker_material_ok {
    handle^, spawn_ok = mjolnir.spawn(
      engine,
      pos + [3]f32{0, 0.2, 0}, // Slightly above ground
      world.MeshAttachment {
        handle = marker_mesh_handle,
        material = marker_material_handle,
      },
    )
  }
  if !spawn_ok do handle^ = {}
}

update_agent_position :: proc(engine: ^mjolnir.Engine) {
  pos := demo_state.agent_pos + [3]f32{0, 1, 0}
  mjolnir.translate(engine, demo_state.agent_handle, pos.x, pos.y, pos.z)
}

visualize_path :: proc(engine: ^mjolnir.Engine) {
  if len(demo_state.current_path) >= 2 {
    log.infof(
      "Visualizing path with %d points using debug draw",
      len(demo_state.current_path),
    )
    // Convert [3]f32 positions to geometry.Vertex
    path_vertices := make(
      []geometry.Vertex,
      len(demo_state.current_path),
      context.temp_allocator,
    )
    for pos, i in demo_state.current_path {
      path_vertices[i] = geometry.Vertex {
        position = pos,
      }
    }
    mjolnir.debug_draw_spawn_line_strip_temporary(
      engine,
      path_vertices,
      5.0,
      [4]f32{1.0, 0.8, 0.0, 1.0}, // Orange/yellow path
    )
  }
}

find_navmesh_point_from_mouse :: proc(
  engine: ^mjolnir.Engine,
  mouse_x, mouse_y: f32,
) -> (
  pos: [3]f32,
  found: bool,
) {
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

demo_mouse_pressed :: proc(
  engine: ^mjolnir.Engine,
  button, action, mods: int,
) {
  if action != glfw.PRESS {
    return
  }
  mouse_x, mouse_y := glfw.GetCursorPos(engine.window)
  switch button {
  case glfw.MOUSE_BUTTON_RIGHT:
    pos, valid := find_navmesh_point_from_mouse(
      engine,
      f32(mouse_x),
      f32(mouse_y),
    )
    if valid {
      demo_state.end_pos = pos
      log.infof("Destination set to: (%.2f, %.2f, %.2f)", pos.x, pos.y, pos.z)
      update_position_marker(
        engine,
        &demo_state.end_marker_handle,
        pos,
        {1, 0, 0, 1},
      )
      start_find_path(engine)
    } else {
      log.warn("No valid navmesh position found at click location")
    }
  }
}

demo_update :: proc(engine: ^mjolnir.Engine, delta_time: f32) {
  // Update camera controller
  mjolnir.update_camera_controller(engine, delta_time)
  // Update agent movement along path
  if len(demo_state.current_path) > 0 && !demo_state.path_completed {
    if demo_state.current_waypoint_idx < len(demo_state.current_path) {
      target_pos := demo_state.current_path[demo_state.current_waypoint_idx]
      // Calculate direction to target
      direction := target_pos - demo_state.agent_pos
      distance := linalg.length(direction)
      // Check if we reached the waypoint
      if distance < 0.5 {
        demo_state.current_waypoint_idx += 1
        if demo_state.current_waypoint_idx >= len(demo_state.current_path) {
          demo_state.path_completed = true
          log.info("Agent reached destination!")
        }
      } else {
        // Move toward the waypoint
        direction = linalg.normalize(direction)
        move_distance := demo_state.agent_speed * delta_time
        if move_distance > distance {
          move_distance = distance
        }
        demo_state.agent_pos += direction * move_distance
        update_agent_position(engine)
      }
    }
  }
}

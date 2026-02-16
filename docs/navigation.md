# Navigation Module (`mjolnir/navigation`)

The Navigation module provides navmesh generation (Recast) and pathfinding (Detour) for AI agent navigation.

## Quick Setup

```odin
import nav "../../mjolnir/navigation"
import "../../mjolnir/navigation/recast"

// Tag nodes for navmesh baking
if ground_node, ok := cont.get(engine.world.nodes, ground_handle); ok {
  ground_node.tags += {.ENVIRONMENT}
}
if obstacle_node, ok := cont.get(engine.world.nodes, obstacle_handle); ok {
  obstacle_node.tags += {.NAVMESH_OBSTACLE}
}

// Build navmesh from tagged world geometry
success := mjolnir.setup_navmesh(
  engine,
  config = mjolnir.DEFAULT_NAVMESH_CONFIG,
  include_filter = {.ENVIRONMENT},
  exclude_filter = {},
)

// Find path
path := nav.find_path(&engine.nav, start_pos, end_pos, max_waypoints = 256)
```

## Manual Navmesh Building

### Collecting Geometry

```odin
nav_vertices := make([dynamic][3]f32)
nav_indices := make([dynamic]i32)
nav_area_types := make([dynamic]u8)

// Helper to add geometry
append_nav_geometry :: proc(
  geom: geometry.Geometry,
  offset: [3]f32 = {},
  is_obstacle := false,
) {
  vertex_base := i32(len(nav_vertices))
  
  for vertex in geom.vertices {
    append(&nav_vertices, vertex.position + offset)
  }
  
  for index in geom.indices {
    append(&nav_indices, vertex_base + i32(index))
  }
  
  triangle_count := len(geom.indices) / 3
  area_type := is_obstacle ? u8(recast.RC_NULL_AREA) : u8(recast.RC_WALKABLE_AREA)
  for _ in 0..<triangle_count {
    append(&nav_area_types, area_type)
  }
}

// Add ground geometry
ground_geom := geometry.make_quad(...)
append_nav_geometry(ground_geom)

// Add obstacle geometry (marked as non-walkable)
obstacle_geom := geometry.make_cube(...)
append_nav_geometry(obstacle_geom, position, is_obstacle = true)
```

### Building Navmesh

```odin
// Create navigation geometry
nav_geom := nav.NavigationGeometry{
  vertices = nav_vertices[:],
  indices = nav_indices[:],
  area_types = nav_area_types[:],
}

// Create config
cfg := recast.config_create()

// Build navmesh
if !nav.build_navmesh(&engine.nav.nav_mesh, nav_geom, cfg) {
  log.error("Failed to build navmesh")
  return
}

// Initialize query system
if !nav.init(&engine.nav) {
  log.error("Failed to initialize navmesh query")
  return
}
```

## Configuration

### Quality Presets

```odin
import "../../mjolnir"

config := mjolnir.NavMeshConfig{
  agent_height = 2.0,
  agent_radius = 0.6,
  agent_max_climb = 0.9,
  agent_max_slope = math.PI * 0.25,
  quality = .MEDIUM, // .LOW, .MEDIUM, .HIGH, .ULTRA
}

mjolnir.setup_navmesh(engine, config)
```

Quality levels:
- `LOW`: Fast generation, coarse mesh - good for large open areas
- `MEDIUM`: Balanced quality and performance - recommended default
- `HIGH`: Higher precision - better for detailed environments
- `ULTRA`: Maximum precision - use for small intricate spaces

### Manual Recast Config

```odin
cfg := recast.Config{
  cs = 0.3,                   // Cell size
  ch = 0.2,                   // Cell height
  walkable_slope = math.PI * 0.25,
  walkable_height = 10,       // Agent height in cells
  walkable_climb = 4,         // Max climb in cells
  walkable_radius = 2,        // Agent radius in cells
  max_edge_len = 12,
  max_simplification_error = 1.3,
  min_region_area = 64,
  merge_region_area = 400,
  max_verts_per_poly = 6,
  detail_sample_dist = 6.0,
  detail_sample_max_error = 1.0,
  border_size = 0,
}
```

## Pathfinding

### Finding Paths

```odin
// Find path between two points
start := [3]f32{-20, 0, -20}
end := [3]f32{20, 0, 20}

path := nav.find_path(&engine.nav, start, end, max_waypoints = 256)

if path != nil && len(path) > 0 {
  log.infof("Path found with %d waypoints", len(path))
  for point, idx in path {
    log.infof("Waypoint %d: %v", idx, point)
  }
  defer delete(path)
}
```

### Spatial Queries

```odin
// Find nearest point on navmesh
search_extents := [3]f32{2.0, 5.0, 2.0}
nearest_pos, found := nav.find_nearest_point(
  &engine.nav,
  query_position,
  search_extents,
)

if found {
  log.infof("Nearest navmesh point: %v", nearest_pos)
}
```

### Mouse Picking with Navmesh

```odin
// Cast ray from camera through mouse
mouse_x, mouse_y := glfw.GetCursorPos(engine.window)
camera := cont.get(engine.world.cameras, engine.world.main_camera)
ray_origin, ray_dir := world.camera_viewport_to_world_ray(camera, mouse_x, mouse_y)

// Intersect with ground plane
if math.abs(ray_dir.y) > 0.001 {
  t := -ray_origin.y / ray_dir.y
  if t > 0 {
    ground_intersection := ray_origin + ray_dir * t
    
    // Find nearest navmesh point
    search_extents := [3]f32{2.0, 5.0, 2.0}
    navmesh_pos, found := nav.find_nearest_point(
      &engine.nav,
      ground_intersection,
      search_extents,
    )
    
    if found {
      // Use navmesh_pos for agent destination
    }
  }
}
```

## Agent Movement

### Following Path

```odin
// Agent state
agent_pos: [3]f32
current_path: [][3]f32
current_waypoint_idx: int
agent_speed: f32 = 5.0

// Update loop
update :: proc(engine: ^mjolnir.Engine, delta_time: f32) {
  if len(current_path) > 0 && current_waypoint_idx < len(current_path) {
    target_pos := current_path[current_waypoint_idx]
    
    // Calculate direction to target
    direction := target_pos - agent_pos
    distance := linalg.length(direction)
    
    // Check if reached waypoint
    if distance < 0.5 {
      current_waypoint_idx += 1
      if current_waypoint_idx >= len(current_path) {
        log.info("Reached destination!")
      }
    } else {
      // Move toward waypoint
      direction = linalg.normalize(direction)
      move_distance := agent_speed * delta_time
      if move_distance > distance {
        move_distance = distance
      }
      agent_pos += direction * move_distance
      
      // Update visual node
      world.translate(&engine.world, agent_handle, agent_pos.x, agent_pos.y, agent_pos.z)
    }
  }
}
```

## Visualization

### Visualize Navmesh

```odin
// Build navmesh geometry for rendering
navmesh_geom := nav.build_geometry(&engine.nav.nav_mesh)

navmesh_mesh, _, ok := world.create_mesh(&engine.world, navmesh_geom)
if !ok do return

navmesh_material, ok := world.create_material(
  &engine.world,
  type = .RANDOM_COLOR,
  base_color_factor = {1.0, 0.8, 0.3, 0.3}, // Semi-transparent
)

navmesh_node := world.spawn(
  &engine.world,
  {0, 0, 0},
  world.MeshAttachment{handle = navmesh_mesh, material = navmesh_material},
) or_else {}
```

### Visualize Path

```odin
// Create line strip from path
path_vertices := make([]geometry.Vertex, len(current_path))
for pos, i in current_path {
  path_vertices[i] = geometry.Vertex{position = pos}
}

indices := make([]u32, len(path_vertices))
for i in 0..<len(indices) {
  indices[i] = u32(i)
}

path_geom := geometry.Geometry{
  vertices = path_vertices,
  indices = indices,
  aabb = geometry.aabb_from_vertices(path_vertices),
}

path_mesh, _, ok := world.create_mesh(&engine.world, path_geom)
path_material, ok := world.create_material(
  &engine.world,
  type = .LINE_STRIP,
  base_color_factor = {1.0, 0.8, 0.0, 1.0},
)

path_node := world.spawn(
  &engine.world,
  {0, 0, 0},
  world.MeshAttachment{handle = path_mesh, material = path_material},
) or_else {}
```

## Baking from World

Use the engine API to automatically bake geometry from tagged nodes:

```odin
// Tag walkable geometry
ground_node.tags += {.ENVIRONMENT}

// Tag obstacles
obstacle_node.tags += {.NAVMESH_OBSTACLE}

// Bake and build navmesh
mjolnir.setup_navmesh(
  engine,
  config = mjolnir.DEFAULT_NAVMESH_CONFIG,
  include_filter = {.ENVIRONMENT},
  exclude_filter = {},
)
```

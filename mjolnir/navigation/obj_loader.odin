package navigation

import "../geometry"
import "./recast"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:slice"

// Load OBJ file and extract data for navigation mesh input
// Note: areas are initialized to 0 (RC_NULL_AREA) and must be marked by calling mark_walkable_triangles
load_obj_to_navmesh_input :: proc(
  filename: string,
  scale: f32 = 1.0,
  walkable_slope_angle: f32 = 45.0,
) -> (
  vertices: [][3]f32,
  indices: []i32,
  areas: []u8,
  ok: bool,
) {
  geom := geometry.load_obj(filename, scale) or_return
  defer geometry.delete_geometry(geom)
  // Extract vertex positions
  vertex_count := len(geom.vertices)
  vertices = make([][3]f32, vertex_count)
  for i in 0 ..< vertex_count {
    vertices[i] = geom.vertices[i].position
  }
  // Convert indices from u32 to i32
  index_count := len(geom.indices)
  indices = make([]i32, index_count)
  for i in 0 ..< index_count {
    indices[i] = i32(geom.indices[i])
  }
  // Create area array - start with RC_NULL_AREA (0)
  triangle_count := index_count / 3
  areas = make([]u8, triangle_count)
  // Areas start at 0 (RC_NULL_AREA)
  // Mark walkable triangles based on slope
  walkable_thr := math.cos(walkable_slope_angle * math.PI / 180.0)
  for i in 0 ..< triangle_count {
    idx := i * 3
    v0 := vertices[indices[idx + 0]]
    v1 := vertices[indices[idx + 1]]
    v2 := vertices[indices[idx + 2]]
    // Calculate triangle normal
    e0 := v1 - v0
    e1 := v2 - v0
    norm := linalg.normalize(linalg.cross(e0, e1))
    // Check if the face is walkable (normal.y > threshold)
    if norm.y > walkable_thr {
      areas[i] = recast.RC_WALKABLE_AREA
    }
  }
  return vertices, indices, areas, true
}

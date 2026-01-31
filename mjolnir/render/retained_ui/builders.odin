package retained_ui

import "core:math/linalg"

// =============================================================================
// Transform Builders
// =============================================================================

// Create a transform with just position
make_transform_position :: proc(x, y: f32) -> Transform2D {
  t := TRANSFORM2D_IDENTITY
  t.position = {x, y}
  return t
}

// Create a transform with position and rotation
make_transform_rotated :: proc(x, y: f32, radians: f32) -> Transform2D {
  t := TRANSFORM2D_IDENTITY
  t.position = {x, y}
  t.rotation = radians
  return t
}

// Create a transform with position and scale
make_transform_scaled :: proc(
  x, y: f32,
  scale_x, scale_y: f32,
) -> Transform2D {
  t := TRANSFORM2D_IDENTITY
  t.position = {x, y}
  t.scale = {scale_x, scale_y}
  return t
}

// Create a full transform
make_transform :: proc(
  position: [2]f32,
  rotation: f32,
  scale: [2]f32,
  pivot: [2]f32,
) -> Transform2D {
  return Transform2D {
    position = position,
    rotation = rotation,
    scale = scale,
    pivot = pivot,
  }
}

// =============================================================================
// Quad Vertex Generation
// =============================================================================

// Generate quad vertices for a rectangle
generate_quad_vertices :: proc(
  rect: [4]f32,
  uv: [4]f32,
  color: [4]u8,
) -> [4]Mesh2DVertex {
  x, y, w, h := rect.x, rect.y, rect.z, rect.w
  u0, v0, u1, v1 := uv.x, uv.y, uv.z, uv.w

  return {
    {pos = {x, y}, uv = {u0, v0}, color = color},
    {pos = {x + w, y}, uv = {u1, v0}, color = color},
    {pos = {x + w, y + h}, uv = {u1, v1}, color = color},
    {pos = {x, y + h}, uv = {u0, v1}, color = color},
  }
}

// Generate quad indices
generate_quad_indices :: proc() -> [6]u32 {
  return {0, 1, 2, 2, 3, 0}
}

// =============================================================================
// Mesh Builders
// =============================================================================

// Create a simple rectangle mesh
build_rect_mesh :: proc(
  width, height: f32,
  color: [4]u8 = WHITE,
) -> (
  vertices: [dynamic]Mesh2DVertex,
  indices: [dynamic]u32,
) {
  vertices = make([dynamic]Mesh2DVertex, 4)
  indices = make([dynamic]u32, 6)

  vertices[0] = {
    pos   = {0, 0},
    uv    = {0, 0},
    color = color,
  }
  vertices[1] = {
    pos   = {width, 0},
    uv    = {1, 0},
    color = color,
  }
  vertices[2] = {
    pos   = {width, height},
    uv    = {1, 1},
    color = color,
  }
  vertices[3] = {
    pos   = {0, height},
    uv    = {0, 1},
    color = color,
  }

  indices[0] = 0
  indices[1] = 1
  indices[2] = 2
  indices[3] = 2
  indices[4] = 3
  indices[5] = 0

  return
}

// Create a triangle mesh
build_triangle_mesh :: proc(
  p1, p2, p3: [2]f32,
  color: [4]u8 = WHITE,
) -> (
  vertices: [dynamic]Mesh2DVertex,
  indices: [dynamic]u32,
) {
  vertices = make([dynamic]Mesh2DVertex, 3)
  indices = make([dynamic]u32, 3)

  vertices[0] = {
    pos   = p1,
    uv    = {0.5, 0},
    color = color,
  }
  vertices[1] = {
    pos   = p2,
    uv    = {0, 1},
    color = color,
  }
  vertices[2] = {
    pos   = p3,
    uv    = {1, 1},
    color = color,
  }

  indices[0] = 0
  indices[1] = 1
  indices[2] = 2

  return
}

// Create a circle mesh (approximated with segments)
build_circle_mesh :: proc(
  radius: f32,
  segments: int = 32,
  color: [4]u8 = WHITE,
) -> (
  vertices: [dynamic]Mesh2DVertex,
  indices: [dynamic]u32,
) {
  vertices = make([dynamic]Mesh2DVertex, segments + 1)
  indices = make([dynamic]u32, segments * 3)

  // Center vertex
  vertices[0] = {
    pos   = {0, 0},
    uv    = {0.5, 0.5},
    color = color,
  }

  // Circle vertices
  for i in 0 ..< segments {
    angle := f32(i) / f32(segments) * 2 * 3.14159265
    x := radius * linalg.cos(angle)
    y := radius * linalg.sin(angle)
    u := (linalg.cos(angle) + 1) * 0.5
    v := (linalg.sin(angle) + 1) * 0.5

    vertices[i + 1] = {
      pos   = {x, y},
      uv    = {u, v},
      color = color,
    }
  }

  // Triangle indices (fan from center)
  for i in 0 ..< segments {
    base := i * 3
    indices[base + 0] = 0
    indices[base + 1] = u32(i + 1)
    indices[base + 2] = u32((i + 1) % segments + 1)
  }

  return
}

// Create a rounded rectangle mesh
build_rounded_rect_mesh :: proc(
  width, height: f32,
  radius: f32,
  segments_per_corner: int = 8,
  color: [4]u8 = WHITE,
) -> (
  vertices: [dynamic]Mesh2DVertex,
  indices: [dynamic]u32,
) {
  // Clamp radius to half of smaller dimension
  r := min(radius, width / 2, height / 2)
  segs := segments_per_corner

  // Calculate vertex count: 4 corners × segments + 4 edge vertices + 1 center
  vertex_count := segs * 4 + 4 + 1
  vertices = make([dynamic]Mesh2DVertex, vertex_count)
  indices = make([dynamic]u32, 0, vertex_count * 3)

  // Center vertex
  center := [2]f32{width / 2, height / 2}
  vertices[0] = {
    pos   = center,
    uv    = {0.5, 0.5},
    color = color,
  }

  idx := 1

  // Generate corner vertices
  corners := [4][2]f32 {
    {r, r}, // Top-left
    {width - r, r}, // Top-right
    {width - r, height - r}, // Bottom-right
    {r, height - r}, // Bottom-left
  }

  start_angles := [4]f32 {
    3.14159265, // Top-left: π to 3π/2
    3.14159265 * 1.5, // Top-right: 3π/2 to 2π
    0, // Bottom-right: 0 to π/2
    3.14159265 * 0.5, // Bottom-left: π/2 to π
  }

  for corner in 0 ..< 4 {
    corner_center := corners[corner]
    start_angle := start_angles[corner]

    for i in 0 ..= segs {
      angle := start_angle + f32(i) / f32(segs) * (3.14159265 / 2)
      x := corner_center.x + r * linalg.cos(angle)
      y := corner_center.y + r * linalg.sin(angle)
      u := x / width
      v := y / height

      vertices[idx] = {
        pos   = {x, y},
        uv    = {u, v},
        color = color,
      }
      idx += 1
    }
  }

  // Generate triangle indices (fan from center)
  total_edge_verts := (segs + 1) * 4
  for i in 0 ..< total_edge_verts {
    next := (i + 1) % total_edge_verts
    append(&indices, u32(0))
    append(&indices, u32(i + 1))
    append(&indices, u32(next + 1))
  }

  return
}

// =============================================================================
// Size Mode Helpers
// =============================================================================

// Create absolute size
absolute_size :: proc(width, height: f32) -> SizeMode {
  return SizeAbsolute{width, height}
}

// Create relative size (percentage of parent)
relative_size :: proc(width_pct, height_pct: f32) -> SizeMode {
  return SizeRelativeParent{width_pct, height_pct}
}

// Create fill remaining size
fill_size :: proc(
  width_weight: f32 = 1.0,
  height_weight: f32 = 1.0,
) -> SizeMode {
  return SizeFillRemaining{width_weight, height_weight}
}

// =============================================================================
// Position Mode Helpers
// =============================================================================

// Create absolute position
absolute_pos :: proc(x, y: f32) -> PositionMode {
  return PosAbsolute{x, y}
}

// Create relative position (percentage of parent)
relative_pos :: proc(x_pct, y_pct: f32) -> PositionMode {
  return PosRelative{x_pct, y_pct}
}

// =============================================================================
// Edge Insets Helpers
// =============================================================================

// Create uniform edge insets
uniform_insets :: proc(value: f32) -> EdgeInsets {
  return EdgeInsets{value, value, value, value}
}

// Create symmetric edge insets
symmetric_insets :: proc(vertical, horizontal: f32) -> EdgeInsets {
  return EdgeInsets{vertical, horizontal, vertical, horizontal}
}

// Create edge insets from individual values
edge_insets :: proc(top, right, bottom, left: f32) -> EdgeInsets {
  return EdgeInsets{top, right, bottom, left}
}

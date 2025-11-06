package geometry

import "core:log"
import "core:math/linalg"
import "core:os"
import "core:strconv"
import "core:strings"

load_obj :: proc(
  filename: string,
  scale: f32 = 1.0,
) -> (
  geom: Geometry,
  ok: bool,
) {
  data, read_ok := os.read_entire_file(filename)
  if !read_ok {
    log.errorf("Failed to read OBJ file: %s", filename)
    return {}, false
  }
  defer delete(data)
  content := string(data)
  lines := strings.split_lines(content)
  defer delete(lines)
  temp_positions: [dynamic][3]f32
  defer delete(temp_positions)
  temp_indices: [dynamic]u32
  defer delete(temp_indices)
  for line in lines {
    trimmed := strings.trim_space(line)
    if len(trimmed) == 0 || trimmed[0] == '#' do continue
    parts := strings.split(trimmed, " ")
    defer delete(parts)
    if len(parts) == 0 do continue
    switch parts[0] {
    case "v":
      if len(parts) >= 4 {
        x, x_ok := strconv.parse_f32(parts[1])
        y, y_ok := strconv.parse_f32(parts[2])
        z, z_ok := strconv.parse_f32(parts[3])
        if x_ok && y_ok && z_ok {
          append(&temp_positions, [3]f32{x * scale, y * scale, z * scale})
        }
      }
    case "f":
      face_indices: [dynamic]i32
      defer delete(face_indices)
      for i in 1 ..< len(parts) {
        face_part := parts[i]
        if len(face_part) == 0 do continue
        slash_idx := strings.index_byte(face_part, '/')
        vertex_str := face_part
        if slash_idx >= 0 {
          vertex_str = face_part[:slash_idx]
        }
        if vertex_idx, ok := strconv.parse_i64(vertex_str); ok {
          idx := i32(vertex_idx)
          if idx < 0 {
            // Negative indices count from the end
            idx = i32(len(temp_positions)) + idx + 1
          }
          // Convert from 1-based to 0-based index
          idx = idx - 1
          // Validate index range
          if idx >= 0 && idx < i32(len(temp_positions)) {
            append(&face_indices, idx)
          }
        }
      }
      // Triangulate the face
      for i := 2; i < len(face_indices); i += 1 {
        a := face_indices[0]
        b := face_indices[i - 1]
        c := face_indices[i]
        if a >= 0 &&
           a < i32(len(temp_positions)) &&
           b >= 0 &&
           b < i32(len(temp_positions)) &&
           c >= 0 &&
           c < i32(len(temp_positions)) {
          append(&temp_indices, u32(a), u32(b), u32(c))
        }
      }
    }
  }
  vertex_count := len(temp_positions)
  if vertex_count == 0 || len(temp_indices) == 0 {
    log.errorf("No valid geometry found in OBJ file: %s", filename)
    return {}, false
  }
  vertices := make([]Vertex, vertex_count)
  vertex_normals := make([][3]f32, vertex_count)
  vertex_normal_counts := make([]int, vertex_count)
  defer delete(vertex_normals)
  defer delete(vertex_normal_counts)
  // Process each triangle to calculate face normals
  for i := 0; i < len(temp_indices); i += 3 {
    idx0 := temp_indices[i]
    idx1 := temp_indices[i + 1]
    idx2 := temp_indices[i + 2]
    v0 := temp_positions[idx0]
    v1 := temp_positions[idx1]
    v2 := temp_positions[idx2]
    e0 := v1 - v0
    e1 := v2 - v0
    face_normal := linalg.cross(e0, e1)
    d := linalg.length(face_normal)
    if d > 0 {
      face_normal = face_normal / d
    }
    vertex_normals[idx0] += face_normal
    vertex_normals[idx1] += face_normal
    vertex_normals[idx2] += face_normal
    vertex_normal_counts[idx0] += 1
    vertex_normal_counts[idx1] += 1
    vertex_normal_counts[idx2] += 1
  }
  for i in 0 ..< vertex_count {
    vertices[i].position = temp_positions[i]
    // Normal (average of face normals)
    if vertex_normal_counts[i] > 0 {
      n := vertex_normals[i] / f32(vertex_normal_counts[i])
      len := linalg.length(n)
      if len > 0 {
        vertices[i].normal = n / len
      } else {
        vertices[i].normal = linalg.VECTOR3F32_Y_AXIS
      }
    } else {
      vertices[i].normal = linalg.VECTOR3F32_Y_AXIS
    }
    // Default color (white)
    vertices[i].color = [4]f32{1, 1, 1, 1}
    // Simple UV mapping
    vertices[i].uv = [2]f32 {
      vertices[i].position.x * 0.1,
      vertices[i].position.z * 0.1,
    }
    // Tangent will be calculated by make_geometry
    vertices[i].tangent = [4]f32{0, 0, 0, 0}
  }
  // Convert indices to slice
  indices := make([]u32, len(temp_indices))
  copy(indices, temp_indices[:])
  // Create geometry (this will calculate tangents and AABB)
  geom = make_geometry(vertices, indices)
  // log.infof("Loaded OBJ file: %s", filename)
  // log.infof("  Vertices: %d, Triangles: %d", len(vertices), len(indices)/3)
  return geom, true
}

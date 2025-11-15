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
  data := os.read_entire_file(filename) or_return
  defer delete(data)
  content := string(data)
  lines := strings.split_lines(content)
  defer delete(lines)
  positions: [dynamic][3]f32
  defer delete(positions)
  indices: [dynamic]u32
  // NOTE: don't defer delete(indices) - ownership transferred to Geometry
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
          append(&positions, [3]f32{x, y, z} * scale)
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
            idx = i32(len(positions)) + idx + 1
          }
          // Convert from 1-based to 0-based index
          idx -= 1
          // Validate index range
          if idx >= 0 && idx < i32(len(positions)) {
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
           a < i32(len(positions)) &&
           b >= 0 &&
           b < i32(len(positions)) &&
           c >= 0 &&
           c < i32(len(positions)) {
          append(&indices, u32(a), u32(b), u32(c))
        }
      }
    }
  }
  vertex_count := len(positions)
  if vertex_count == 0 || len(indices) == 0 {
    log.errorf("No valid geometry found in OBJ file: %s", filename)
    return {}, false
  }
  vertices := make([]Vertex, vertex_count)
  vertex_normals := make([][3]f32, vertex_count)
  vertex_normal_counts := make([]int, vertex_count)
  defer delete(vertex_normals)
  defer delete(vertex_normal_counts)
  // Process each triangle to calculate face normals
  for i := 0; i < len(indices); i += 3 {
    idx0 := indices[i]
    idx1 := indices[i + 1]
    idx2 := indices[i + 2]
    v0 := positions[idx0]
    v1 := positions[idx1]
    v2 := positions[idx2]
    e0 := v1 - v0
    e1 := v2 - v0
    face_normal := linalg.cross(e0, e1)
    face_normal = linalg.normalize0(face_normal)
    vertex_normals[idx0] += face_normal
    vertex_normals[idx1] += face_normal
    vertex_normals[idx2] += face_normal
    vertex_normal_counts[idx0] += 1
    vertex_normal_counts[idx1] += 1
    vertex_normal_counts[idx2] += 1
  }
  for i in 0 ..< vertex_count {
    vertices[i].position = positions[i]
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
    vertices[i].uv = vertices[i].position.xz * 0.1
  }
  // Convert dynamic array to slice - ownership transferred to Geometry
  indices_slice := indices[:]
  geom = make_geometry(vertices, indices_slice)
  // log.infof("Loaded OBJ file: %s", filename)
  // log.infof("  Vertices: %d, Triangles: %d", len(vertices), len(indices)/3)
  return geom, true
}

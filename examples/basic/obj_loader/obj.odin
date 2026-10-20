package main

import "core:log"
import "core:strconv"
import "core:strings"

// Triangle mesh read from a Wavefront OBJ file: positions and triangulated
// faces only.
ObjMesh :: struct {
  positions: [][3]f32,
  indices:   []u32,
}

obj_mesh_destroy :: proc(self: ^ObjMesh) {
  delete(self.positions)
  delete(self.indices)
  self^ = {}
}

// Load the vertex positions and faces (fan-triangulated) of OBJ text,
// scaled by `scale`.
load_obj :: proc(
  data: []u8,
  scale: f32 = 1.0,
) -> (
  obj: ObjMesh,
  ok: bool,
) {
  content := string(data)
  lines := strings.split_lines(content)
  defer delete(lines)
  positions: [dynamic][3]f32
  indices: [dynamic]u32
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
  if len(positions) == 0 || len(indices) == 0 {
    log.errorf("No valid geometry found in OBJ data")
    delete(positions)
    delete(indices)
    return {}, false
  }
  return {positions = positions[:], indices = indices[:]}, true
}

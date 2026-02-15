package ui

import cont "../containers"
import "../gpu"
import cmd "../gpu/ui"
import "core:log"
import "core:slice"

create_mesh2d :: proc(
  sys: ^System,
  position: [2]f32,
  vertices: []cmd.Vertex2D,
  indices: []u32,
  texture: gpu.Texture2DHandle = {},
  z_order: i32 = 0,
) -> (
  Mesh2DHandle,
  bool,
) {
  handle, widget, ok := cont.alloc(&sys.widget_pool, UIWidgetHandle)
  if !ok {
    log.error("Failed to allocate UI widget handle for Mesh2D")
    return {}, false
  }

  // Copy vertices and indices
  vertices_copy := make([]cmd.Vertex2D, len(vertices))
  copy(vertices_copy, vertices)
  indices_copy := make([]u32, len(indices))
  copy(indices_copy, indices)

  // Use default texture if none specified
  final_texture :=
    texture if texture != (gpu.Texture2DHandle{}) else sys.default_texture

  widget^ = Mesh2D {
    position       = position,
    world_position = position,
    z_order        = z_order,
    visible        = true,
    vertices       = vertices_copy,
    indices        = indices_copy,
    texture        = final_texture,
  }

  return Mesh2DHandle(handle), true
}

create_quad2d :: proc(
  sys: ^System,
  position: [2]f32,
  size: [2]f32,
  texture: gpu.Texture2DHandle = {},
  color: [4]u8 = {255, 255, 255, 255},
  z_order: i32 = 0,
) -> (
  Quad2DHandle,
  bool,
) {
  handle, widget, ok := cont.alloc(&sys.widget_pool, UIWidgetHandle)
  if !ok {
    log.error("Failed to allocate UI widget handle for Quad2D")
    return {}, false
  }

  // Use default texture if none specified
  final_texture :=
    texture if texture != (gpu.Texture2DHandle{}) else sys.default_texture

  widget^ = Quad2D {
    position       = position,
    world_position = position,
    z_order        = z_order,
    visible        = true,
    size           = size,
    texture        = final_texture,
    color          = color,
  }

  return Quad2DHandle(handle), true
}

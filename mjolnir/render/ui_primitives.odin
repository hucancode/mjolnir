package render

import cont "../containers"
import "core:log"
import "core:math/linalg"

create_mesh2d :: proc(
  sys: ^UISystem,
  position: [2]f32,
  vertices: []Vertex2D,
  indices: []u32,
  texture: u32 = NO_TEXTURE,
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
  vertices_copy := make([]Vertex2D, len(vertices))
  copy(vertices_copy, vertices)
  indices_copy := make([]u32, len(indices))
  copy(indices_copy, indices)


  widget^ = Mesh2D {
    position       = position,
    world_position = position,
    z_order        = z_order,
    visible        = true,
    vertices       = vertices_copy,
    indices        = indices_copy,
    texture        = texture,
  }
  if len(vertices) > 0 {
    m := &widget.(Mesh2D)
    m.local_min, m.local_max = vertices[0].pos, vertices[0].pos
    for v in vertices {
      m.local_min = linalg.min(m.local_min, v.pos)
      m.local_max = linalg.max(m.local_max, v.pos)
    }
  }

  return Mesh2DHandle(handle), true
}

create_quad2d :: proc(
  sys: ^UISystem,
  position: [2]f32,
  size: [2]f32,
  texture: u32 = NO_TEXTURE,
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


  widget^ = Quad2D {
    position       = position,
    world_position = position,
    z_order        = z_order,
    visible        = true,
    size           = size,
    texture        = texture,
    color          = color,
  }

  return Quad2DHandle(handle), true
}

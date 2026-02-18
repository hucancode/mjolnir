package geometry

import vk "vendor:vulkan"

Vertex :: struct {
  position: [3]f32,
  normal:   [3]f32,
  color:    [4]f32,
  uv:       [2]f32,
  tangent:  [4]f32, // xyz = tangent, w = handedness (for bitangent reconstruction)
}

SkinningData :: struct {
  joints:  [4]u32,
  weights: [4]f32,
}

Vertex2D :: struct {
  pos:        [2]f32,
  uv:         [2]f32,
  color:      [4]u8,
  texture_id: u32,
}

VERTEX_BINDING_DESCRIPTION := [?]vk.VertexInputBindingDescription {
  {binding = 0, stride = size_of(Vertex), inputRate = .VERTEX},
}

VERTEX_ATTRIBUTE_DESCRIPTIONS := [?]vk.VertexInputAttributeDescription {
  {
    binding = 0,
    location = 0,
    format = .R32G32B32_SFLOAT,
    offset = u32(offset_of(Vertex, position)),
  },
  {
    binding = 0,
    location = 1,
    format = .R32G32B32_SFLOAT,
    offset = u32(offset_of(Vertex, normal)),
  },
  {
    binding = 0,
    location = 2,
    format = .R32G32B32A32_SFLOAT,
    offset = u32(offset_of(Vertex, color)),
  },
  {
    binding = 0,
    location = 3,
    format = .R32G32_SFLOAT,
    offset = u32(offset_of(Vertex, uv)),
  },
  {
    binding = 0,
    location = 4,
    format = .R32G32B32A32_SFLOAT,
    offset = u32(offset_of(Vertex, tangent)),
  },
}

VERTEX2D_BINDING_DESCRIPTION := vk.VertexInputBindingDescription {
  binding   = 0,
  stride    = size_of(Vertex2D),
  inputRate = .VERTEX,
}

VERTEX2D_ATTRIBUTE_DESCRIPTIONS := [?]vk.VertexInputAttributeDescription {
  {binding = 0, location = 0, format = .R32G32_SFLOAT,  offset = u32(offset_of(Vertex2D, pos))},
  {binding = 0, location = 1, format = .R32G32_SFLOAT,  offset = u32(offset_of(Vertex2D, uv))},
  {binding = 0, location = 2, format = .R8G8B8A8_UNORM, offset = u32(offset_of(Vertex2D, color))},
  {binding = 0, location = 3, format = .R32_UINT,       offset = u32(offset_of(Vertex2D, texture_id))},
}

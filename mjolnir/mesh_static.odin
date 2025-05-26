package mjolnir

import "core:fmt"
import linalg "core:math/linalg"
import "geometry"
import "resource"
import vk "vendor:vulkan"

StaticMesh :: struct {
  material:      Handle,
  vertices_len:  u32,
  indices_len:   u32,
  vertex_buffer: DataBuffer,
  index_buffer:  DataBuffer,
  aabb:          geometry.Aabb,
  ctx:           ^VulkanContext,
}

static_mesh_deinit :: proc(self: ^StaticMesh) {
  if self.ctx == nil {
    return
  }
  if self.vertex_buffer.buffer != 0 {
    data_buffer_deinit(&self.vertex_buffer, self.ctx)
  }
  if self.index_buffer.buffer != 0 {
    data_buffer_deinit(&self.index_buffer, self.ctx)
  }
  self.vertices_len = 0
  self.indices_len = 0
  self.aabb = {}
  self.ctx = nil
}

static_mesh_init :: proc(
  self: ^StaticMesh,
  data: ^geometry.Geometry,
  ctx: ^VulkanContext,
) -> vk.Result {
  self.ctx = ctx
  self.vertices_len = u32(len(data.vertices))
  self.indices_len = u32(len(data.indices))
  self.aabb = data.aabb
  size := len(data.vertices) * size_of(geometry.Vertex)
  self.vertex_buffer = create_local_buffer(
    ctx,
    vk.DeviceSize(size),
    {.VERTEX_BUFFER},
    raw_data(data.vertices),
  ) or_return

  size = len(data.indices) * size_of(u32)
  self.index_buffer = create_local_buffer(
    ctx,
    vk.DeviceSize(size),
    {.INDEX_BUFFER},
    raw_data(data.indices),
  ) or_return

  return .SUCCESS
}

create_static_mesh :: proc(
  engine: ^Engine,
  geom: ^geometry.Geometry,
  material: Handle,
) -> Handle {
  handle, mesh := resource.alloc(&engine.meshes)
  if mesh != nil {
    if static_mesh_init(mesh, geom, &engine.ctx) != .SUCCESS {
      fmt.eprintln("Failed to initialize static mesh geometry")
      return handle
    }
    mesh.material = material
    fmt.printfln("Created static mesh with material handle %v", material)
  }
  return handle
}

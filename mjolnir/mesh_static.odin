package mjolnir

import "base:runtime"
import "core:fmt"
import linalg "core:math/linalg"
import "geometry"
import "resource"
import vk "vendor:vulkan"

StaticMesh :: struct {
  material:             Handle, // Handle to a Material resource
  vertices_len:         u32,
  indices_len:          u32,
  simple_vertex_buffer: DataBuffer, // For shadow passes (positions only)
  vertex_buffer:        DataBuffer, // Full vertex data
  index_buffer:         DataBuffer,
  aabb:                 geometry.Aabb,
  ctx_ref:              ^VulkanContext,
}

// deinit_static_mesh releases the Vulkan buffers.
static_mesh_deinit :: proc(self: ^StaticMesh) {
  if self.ctx_ref == nil {
    return // Not initialized or already deinitialized
  }
  vkd := self.ctx_ref.vkd

  if self.vertex_buffer.buffer != 0 {
    data_buffer_deinit(&self.vertex_buffer, self.ctx_ref)
  }
  if self.simple_vertex_buffer.buffer != 0 {
    data_buffer_deinit(&self.simple_vertex_buffer, self.ctx_ref)
  }
  if self.index_buffer.buffer != 0 {
    data_buffer_deinit(&self.index_buffer, self.ctx_ref)
  }
  // Reset fields
  self.vertices_len = 0
  self.indices_len = 0
  self.aabb = {}
  self.ctx_ref = nil
}

// init_static_mesh initializes the mesh and creates Vulkan buffers.
static_mesh_init :: proc(
  self: ^StaticMesh,
  data: ^geometry.Geometry,
  ctx: ^VulkanContext,
) -> vk.Result {
  self.ctx_ref = ctx
  self.vertices_len = u32(len(data.vertices))
  self.indices_len = u32(len(data.indices))
  self.aabb = data.aabb

  positions_slice := geometry.extract_positions_geometry(data)
  size := len(positions_slice) * size_of(linalg.Vector4f32)
  self.simple_vertex_buffer = create_local_buffer(
    ctx,
    vk.DeviceSize(size),
    {.VERTEX_BUFFER},
    raw_data(positions_slice),
  ) or_return

  size = len(data.vertices) * size_of(geometry.Vertex)
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


// Creates a static mesh and returns its handle
create_static_mesh :: proc(
  engine: ^Engine,
  geom: ^geometry.Geometry,
  material: Handle,
) -> Handle {
  handle, mesh := resource.alloc(&engine.meshes)
  if mesh != nil {
    // Initialize geometry buffers
    if static_mesh_init(mesh, geom, &engine.vk_ctx) != .SUCCESS {
      fmt.eprintln("Failed to initialize static mesh geometry")
      return handle
    }
    // Set material
    mesh.material = material
    fmt.printfln("Created static mesh with material handle %v", material)
  }
  return handle
}

# `mjolnir/gpu` — API Reference

Layer 1. Thin Vulkan 1.3 abstraction. **Does not** hide Vulkan — it codifies
the patterns mjolnir uses (bindless texture array, slab-allocated mesh
buffers, dynamic rendering, frame-in-flight semaphores). Most engine users
never touch this directly; it exists for `render` and as an escape hatch.

## GPUContext

```odin
GPUContext :: struct {
  window:               glfw.WindowHandle,
  instance:             vk.Instance,
  device:               vk.Device,
  surface:              vk.SurfaceKHR,
  surface_capabilities: vk.SurfaceCapabilitiesKHR,
  surface_formats:      []vk.SurfaceFormatKHR,
  present_modes:        []vk.PresentModeKHR,
  debug_messenger:      vk.DebugUtilsMessengerEXT,
  physical_device:      vk.PhysicalDevice,
  graphics_family:      u32,
  graphics_queue:       vk.Queue,
  present_family:       u32,
  present_queue:        vk.Queue,
  compute_family:       Maybe(u32),
  compute_queue:        Maybe(vk.Queue),
  descriptor_pool:      vk.DescriptorPool,
  command_pool:         vk.CommandPool,
  compute_command_pool: Maybe(vk.CommandPool),
  device_properties:    vk.PhysicalDeviceProperties,
  has_async_compute:    bool,
}

SwapchainSupport :: struct {
  capabilities:  vk.SurfaceCapabilitiesKHR,
  formats:       []vk.SurfaceFormatKHR,
  present_modes: []vk.PresentModeKHR,
}

FoundQueueFamilyIndices :: struct {
  graphics_family: u32,
  present_family:  u32,
  compute_family:  Maybe(u32),
}
```

```odin
gpu_context_init(self, window) -> vk.Result
shutdown(self)
swapchain_support_destroy(support: ^SwapchainSupport)
```

Constants: `FRAMES_IN_FLIGHT :: 2`, `ENGINE_NAME :: "Mjolnir"`,
`TITLE :: "Mjolnir"`, `ENABLE_VALIDATION_LAYERS :: ODIN_DEBUG`.

## Image

```odin
ImageType :: enum { D2, D2_ARRAY, D3, CUBE, CUBE_ARRAY }

ImageSpec :: struct {
  type:         ImageType,
  using extent: vk.Extent2D,
  depth:        u32,
  array_layers: u32,
  format:       vk.Format,
  mip_levels:   u32,
  tiling:       vk.ImageTiling,
  usage:        vk.ImageUsageFlags,
  memory_flags: vk.MemoryPropertyFlags,
  create_view:  bool,
  view_type:    vk.ImageViewType,
  aspect_mask:  vk.ImageAspectFlags,
}

Image :: struct {
  image:  vk.Image,
  memory: vk.DeviceMemory,
  spec:   ImageSpec,
  view:   vk.ImageView,
}

CubeImage :: /* same shape as Image, six faces */
```

| Proc | Purpose |
|---|---|
| `infer_view_type(img_type, array_layers) -> vk.ImageViewType` | Helper. |
| `infer_image_type(view_type) -> vk.ImageType` | Helper. |
| `infer_aspect_mask(format) -> vk.ImageAspectFlags` | Color/depth/stencil. |
| `calculate_mip_levels(width, height) -> u32` | Mip count. |
| `validate_spec(spec)` | Fill defaults (mips, aspect, layers, depth). |
| `image_create(gctx, spec) -> (Image, vk.Result)` | Allocate + view. |
| `image_create_with_data(gctx, spec, data, size, initial_layout=.SHADER_READ_ONLY_OPTIMAL) -> (Image, vk.Result)` | Upload via staging. |
| `image_create_with_mipmaps(gctx, spec, data, size) -> (Image, vk.Result)` | + blit mipmap chain. |
| `image_create_view(device, img, view_type, base_mip=0, mip_count=1, base_layer=0, layer_count=1) -> (vk.ImageView, vk.Result)` | Sub-view. |
| `image_destroy(device, img)` | Free image, view, memory. |
| `image_spec_2d(extent, format, usage, mipmaps=false) -> ImageSpec` | Sugar. |
| `image_spec_cube(size, format, usage, mipmaps=false) -> ImageSpec` | Sugar. |

## Memory (typed buffers)

```odin
MutableBuffer($T) :: struct {
  buffer:       vk.Buffer,
  memory:       vk.DeviceMemory,
  mapped:       [^]T,
  element_size: int,
  bytes_count:  int,
}

ImmutableBuffer($T) :: struct {
  buffer:       vk.Buffer,
  memory:       vk.DeviceMemory,
  element_size: int,
  bytes_count:  int,
}

ImmutableBindlessBuffer($T) :: /* + descriptor_set + descriptor_layout */
```

```odin
malloc_mutable_buffer(gctx, $T, count, usage) -> (MutableBuffer(T), vk.Result)
malloc_buffer        (gctx, $T, count, usage) -> (ImmutableBuffer(T), vk.Result)

write(buffer: ^MutableBuffer($T), data: ^T, index: int = 0) -> vk.Result
write(buffer: ^MutableBuffer($T), data: []T, index: int = 0) -> vk.Result
write(gctx, buffer: ^ImmutableBuffer($T), data: ^T, index: int = 0) -> vk.Result
write(gctx, buffer: ^ImmutableBuffer($T), data: []T, index: int = 0) -> vk.Result

get(buffer: ^MutableBuffer($T), index: u32 = 0) -> ^T
get_all(buffer: ^MutableBuffer($T)) -> []T
get_all(buffer: ^ImmutableBuffer($T)) -> []T   // CPU-side view, not GPU readback

mutable_buffer_destroy(device, buffer: ^MutableBuffer($T))
buffer_destroy        (device, buffer: ^ImmutableBuffer($T))
```

`MutableBuffer` is `HOST_VISIBLE | HOST_COHERENT` (CPU-mapped, writes visible
without flush). `ImmutableBuffer` is `DEVICE_LOCAL` (uploads via a staging
buffer inside `write`).

## TextureManager

The bindless texture arena. All sampled textures in mjolnir live here.

```odin
Texture2DHandle   :: distinct cont.Handle
TextureCubeHandle :: distinct cont.Handle

TextureManager :: struct {
  images_2d:      cont.Pool(Image),
  images_cube:    cont.Pool(CubeImage),
  set_layout:     vk.DescriptorSetLayout,
  descriptor_set: vk.DescriptorSet,
}

MAX_TEXTURES      :: 1000
MAX_CUBE_TEXTURES :: 200
```

| Proc | Purpose |
|---|---|
| `texture_manager_init(self, gctx)` | Create descriptor set layout. |
| `texture_manager_setup(self, gctx, samplers: [MAX_SAMPLERS]vk.Sampler)` | Allocate descriptor set + write samplers. |
| `texture_manager_teardown(self, gctx)` | Destroy all textures (called before pool reset). |
| `texture_manager_shutdown(self, gctx)` | Destroy descriptor layout. |
| `allocate_texture_2d(self, gctx, extent, format, usage, generate_mips=false) -> (Texture2DHandle, vk.Result)` | Empty texture. |
| `allocate_texture_2d_with_data(self, gctx, pixels, size, extent, format, usage, generate_mips=false) -> ...` | Texture with initial data. |
| `allocate_texture_cube(self, gctx, size, format, usage, generate_mips=false) -> (TextureCubeHandle, vk.Result)` | Empty cubemap. |
| `allocate_texture_cube_with_data(self, gctx, faces: [6][]u8, size, format, usage, generate_mips=false) -> ...` | Cubemap with per-face data. |
| `free_texture_2d(self, gctx, handle)` | Free + update descriptor. |
| `free_texture_cube(self, gctx, handle)` | Free + update descriptor. |

## Swapchain

```odin
Swapchain :: struct {
  handle:                      vk.SwapchainKHR,
  format:                      vk.SurfaceFormatKHR,
  extent:                      vk.Extent2D,
  images:                      []vk.Image,
  views:                       []vk.ImageView,
  image_index:                 u32,
  in_flight_fences:            [FRAMES_IN_FLIGHT]vk.Fence,
  image_available_semaphores:  [FRAMES_IN_FLIGHT]vk.Semaphore,
  render_finished_semaphores:  []vk.Semaphore,
  compute_finished_semaphores: [FRAMES_IN_FLIGHT]vk.Semaphore,
}

swapchain_init(self, gctx, window) -> vk.Result
swapchain_destroy(self, device)
acquire_next_image(self, device, frame_in_flight: u32) -> (image_index: u32, frame_ready: bool, ret: vk.Result)
present(self, present_queue, frame_in_flight: u32) -> vk.Result
```

## Pipeline helpers

Pre-baked Vulkan state objects (`ALL_CAPS` constants) cover the common cases —
opaque triangle, line, point, double-sided, depth-test, additive blend, etc.
Reading `gpu/pipeline.odin` is the fastest way to see the full set:

`VERTEX_INPUT_NONE`, `READ_WRITE_DEPTH_STATE`, `READ_ONLY_DEPTH_STATE`,
`READ_ONLY_INVERSE_DEPTH_STATE`, `DYNAMIC_STATES`, `STANDARD_DYNAMIC_STATES`,
`STANDARD_RASTERIZER`, `INVERSE_RASTERIZER`, `DOUBLE_SIDED_RASTERIZER`,
`LINE_RASTERIZER`, `BOLD_DOUBLE_SIDED_RASTERIZER`,
`STANDARD_INPUT_ASSEMBLY`, `POINT_INPUT_ASSEMBLY`, `LINE_INPUT_ASSEMBLY`,
`STANDARD_VIEWPORT_STATE`, `STANDARD_MULTISAMPLING`,
`BLEND_OVERRIDE`, `COLOR_BLENDING_OVERRIDE`,
`BLEND_ADDITIVE`, `COLOR_BLENDING_ADDITIVE`,
`BLEND_OVERFLOW`, `COLOR_BLENDING_OVERFLOW`,
`STANDARD_COLOR_FORMAT`, `STANDARD_RENDERING_INFO`,
`COLOR_ONLY_RENDERING_INFO`, `DEPTH_ONLY_RENDERING_INFO`.

**Stage builders:**

```odin
create_vert_frag_stages    (vert, frag, specialization=nil) -> [2]vk.PipelineShaderStageCreateInfo
create_vert_stage          (vert, specialization=nil)        -> [1]…
create_frag_stage          (frag, specialization=nil)        -> [1]…
create_vert_geo_frag_stages(vert, geo, frag, specialization=nil) -> [3]…
```

**Command buffers:**

```odin
begin_record(cmd, flags = {.ONE_TIME_SUBMIT}) -> vk.Result
end_record  (cmd) -> vk.Result

allocate_command_buffer_single(gctx, level=.PRIMARY) -> (vk.CommandBuffer, vk.Result)
allocate_command_buffer_multi (gctx, out: []vk.CommandBuffer, level=.PRIMARY) -> vk.Result
allocate_compute_command_buffer_single(gctx, level=.PRIMARY) -> (vk.CommandBuffer, vk.Result)
allocate_compute_command_buffer_multi (gctx, out, level=.PRIMARY) -> vk.Result
free_command_buffer        (gctx, ..vk.CommandBuffer)
free_compute_command_buffer(gctx, ^vk.CommandBuffer)
free_compute_command_buffer(gctx, []vk.CommandBuffer)
```

**Descriptors / layouts / pipeline layouts:**

```odin
allocate_descriptor_set_single(gctx, ^vk.DescriptorSet, ^vk.DescriptorSetLayout) -> vk.Result
allocate_descriptor_set_multi (gctx, []vk.DescriptorSet, vk.DescriptorSetLayout) -> vk.Result

create_descriptor_set_layout      (gctx, bindings: ..struct{type, flags}) -> (vk.DescriptorSetLayout, vk.Result)
create_descriptor_set_layout_array(gctx, bindings: ..struct{type, count, flags}) -> (vk.DescriptorSetLayout, vk.Result)

create_descriptor_set(gctx, ^vk.DescriptorSetLayout, buffers: ..struct{type, info}) -> (vk.DescriptorSet, vk.Result)

update_descriptor_set        (gctx, dst, buffers: ..struct{...})
update_descriptor_set_array  (gctx, dst, dst_binding, buffers)
update_descriptor_set_array_offset(gctx, dst, dst_binding, dst_offset, buffers)

create_pipeline_layout(gctx, pc_range: Maybe(vk.PushConstantRange), ds: ..vk.DescriptorSetLayout) -> (vk.PipelineLayout, vk.Result)
create_compute_pipeline(gctx, shader, layout, entry_point: cstring = "main") -> (vk.Pipeline, vk.Result)
```

**Recording:**

```odin
bind_graphics_pipeline(cmd, pipeline, layout, ds: ..vk.DescriptorSet)
bind_compute_pipeline (cmd, pipeline, layout, ds: ..vk.DescriptorSet)

image_barrier (cmd, image, old_layout, new_layout, src_access, dst_access,
               src_stage, dst_stage, aspect_mask,
               mip_level=0, level_count=1, base_layer=0, layer_count=1)
memory_barrier(cmd, src_access, dst_access, src_stage, dst_stage)
buffer_barrier(cmd, buffer, size, src_access, dst_access, src_stage, dst_stage, offset=0)

bind_vertex_index_buffers(cmd, vertex_buffer, index_buffer,
                          vertex_offset=0, index_offset=0, index_type=.UINT32)
set_viewport_scissor(cmd, extent, flip_x=false, flip_y=true)
```

**Dynamic rendering:**

```odin
begin_depth_rendering(cmd, extent, depth_attachment: ^vk.RenderingAttachmentInfo, layer_count=1)
begin_rendering(cmd, extent, depth_attachment: Maybe(vk.RenderingAttachmentInfo),
                color_attachments: ..vk.RenderingAttachmentInfo)

create_color_attachment       (image, load_op=.CLEAR, store_op=.STORE, clear_color={0,0,0,1}) -> vk.RenderingAttachmentInfo
create_color_attachment_view  (image_view, load_op=.CLEAR, store_op=.STORE, clear_color={0,0,0,1}) -> ...
create_depth_attachment       (image, load_op=.CLEAR, store_op=.STORE, clear_depth=1.0) -> ...
create_cube_depth_attachment  (image: ^CubeImage, load_op=.CLEAR, store_op=.STORE, clear_depth=1.0) -> ...
create_dynamic_state(states: []vk.DynamicState) -> vk.PipelineDynamicStateCreateInfo
```

## MeshManager

Backs all geometry on the GPU with three giant buffers + slab allocators.

```odin
MeshHandle :: distinct cont.Handle

BufferAllocation :: struct {
  offset: u32,
  count:  u32,
}

MeshAllocations :: struct {
  vertices: BufferAllocation,
  indices:  BufferAllocation,
  skinning: BufferAllocation,
}

MeshManager :: struct {
  vertex_skinning_buffer: ImmutableBindlessBuffer(geometry.SkinningData),
  vertex_buffer:          ImmutableBuffer(geometry.Vertex),
  index_buffer:           ImmutableBuffer(u32),
  vertex_skinning_slab:   cont.SlabAllocator,
  vertex_slab:            cont.SlabAllocator,
  index_slab:             cont.SlabAllocator,
}

BINDLESS_VERTEX_BUFFER_SIZE   :: 128 * 1024 * 1024
BINDLESS_INDEX_BUFFER_SIZE    ::  64 * 1024 * 1024
BINDLESS_SKINNING_BUFFER_SIZE :: 128 * 1024 * 1024
```

| Proc | Purpose |
|---|---|
| `mesh_manager_init(manager, gctx)` | Create buffers + slab allocators. |
| `mesh_manager_shutdown(manager, gctx)` | Free buffers. |
| `mesh_manager_realloc_descriptors(manager, gctx)` | Reallocate descriptors after pool reset. |
| `allocate_vertices(manager, gctx, vertices) -> (BufferAllocation, vk.Result)` | Upload + sub-allocate. |
| `allocate_indices(manager, gctx, indices) -> (BufferAllocation, vk.Result)` | |
| `allocate_vertex_skinning(manager, gctx, skinning) -> (BufferAllocation, vk.Result)` | |
| `allocate_mesh(manager, gctx, geometry) -> (MeshAllocations, has_skinning: bool, vk.Result)` | All three at once. |
| `free_vertices` / `free_indices` / `free_vertex_skinning` | Recycle. |
| `free_mesh(manager, va, ia, sa, has_skinning)` | Free a complete mesh. |

The returned `BufferAllocation.offset` is stable for the lifetime of the
allocation — bindless draw indirect commands rely on this.

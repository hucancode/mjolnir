#+private
package render

import "gpu"
import vk "vendor:vulkan"

// Culling set bindings: nodes, meshes, cameras, draw counts, draw commands,
// depth pyramid sampler.
BINDING_COUNT :: 6
MAX_DEPTH_MIPS_LEVEL :: 16

OcclusionCullPushConstants :: struct {
  camera_index: u32,
  node_count:   u32,
  max_draws:    u32,
}

// Frustum + occlusion culling into per-pipeline indirect draw lists, and the
// depth reduction that builds the pyramid it tests against. `sampler` reduces
// with MAX and serves every pyramid.
OcclusionSystem :: struct {
  cull_set_layout:   vk.DescriptorSetLayout,
  cull_layout:       vk.PipelineLayout,
  cull_pipeline:     vk.Pipeline,
  reduce_set_layout: vk.DescriptorSetLayout,
  reduce_layout:     vk.PipelineLayout,
  reduce_pipeline:   vk.Pipeline,
  sampler:           vk.Sampler,
  max_draws:         u32,
}

// Hierarchical max-depth buffer at half the camera's resolution, one view per
// mip for the reduce pass to write.
DepthPyramid :: struct {
  texture: Texture2DHandle,
  views:   [MAX_DEPTH_MIPS_LEVEL]vk.ImageView,
}

occlusion_init :: proc(
  self: ^OcclusionSystem,
  gctx: ^gpu.GPUContext,
  max_draws: u32,
) -> (
  ret: vk.Result,
) {
  defer if ret != .SUCCESS do occlusion_shutdown(self, gctx)
  self.max_draws = max_draws
  bindings: [BINDING_COUNT]struct {
    type:  vk.DescriptorType,
    flags: vk.ShaderStageFlags,
  }
  for &b in bindings do b = {.STORAGE_BUFFER, {.COMPUTE}}
  bindings[BINDING_COUNT - 1] = {.COMBINED_IMAGE_SAMPLER, {.COMPUTE}}
  self.cull_set_layout = gpu.create_descriptor_set_layout(gctx, ..bindings[:]) or_return
  self.cull_layout = gpu.create_pipeline_layout(
    gctx,
    vk.PushConstantRange{stageFlags = {.COMPUTE}, size = size_of(OcclusionCullPushConstants)},
    self.cull_set_layout,
  ) or_return
  self.cull_pipeline = gpu.create_compute_pipeline(gctx, #load("shader/occlusion_culling/cull.spv"), self.cull_layout) or_return
  self.reduce_set_layout = gpu.create_descriptor_set_layout(
    gctx,
    {.COMBINED_IMAGE_SAMPLER, {.COMPUTE}},
    {.STORAGE_IMAGE, {.COMPUTE}},
  ) or_return
  self.reduce_layout = gpu.create_pipeline_layout(
    gctx,
    vk.PushConstantRange{stageFlags = {.COMPUTE}, size = size_of(u32)},
    self.reduce_set_layout,
  ) or_return
  self.reduce_pipeline = gpu.create_compute_pipeline(gctx, #load("shader/occlusion_culling/depth_reduce.spv"), self.reduce_layout) or_return
  reduction_mode := vk.SamplerReductionModeCreateInfo {
    sType         = .SAMPLER_REDUCTION_MODE_CREATE_INFO,
    reductionMode = .MAX,
  }
  sampler_info := vk.SamplerCreateInfo {
    sType        = .SAMPLER_CREATE_INFO,
    pNext        = &reduction_mode,
    magFilter    = .LINEAR,
    minFilter    = .LINEAR,
    mipmapMode   = .NEAREST,
    addressModeU = .CLAMP_TO_EDGE,
    addressModeV = .CLAMP_TO_EDGE,
    addressModeW = .CLAMP_TO_EDGE,
    maxLod       = vk.LOD_CLAMP_NONE,
  }
  vk.CreateSampler(gctx.device, &sampler_info, nil, &self.sampler) or_return
  return .SUCCESS
}

occlusion_shutdown :: proc(self: ^OcclusionSystem, gctx: ^gpu.GPUContext) {
  vk.DestroySampler(gctx.device, self.sampler, nil)
  vk.DestroyPipeline(gctx.device, self.reduce_pipeline, nil)
  vk.DestroyPipelineLayout(gctx.device, self.reduce_layout, nil)
  vk.DestroyDescriptorSetLayout(gctx.device, self.reduce_set_layout, nil)
  vk.DestroyPipeline(gctx.device, self.cull_pipeline, nil)
  vk.DestroyPipelineLayout(gctx.device, self.cull_layout, nil)
  vk.DestroyDescriptorSetLayout(gctx.device, self.cull_set_layout, nil)
  self^ = {}
}

// Create the pyramid texture for a camera of `extent` and its per-mip views.
occlusion_setup_pyramid :: proc(
  gctx: ^gpu.GPUContext,
  pyramid: ^DepthPyramid,
  texture_manager: ^TextureManager,
  extent: vk.Extent2D,
) -> vk.Result {
  extent := vk.Extent2D{max(1, extent.width / 2), max(1, extent.height / 2)}
  pyramid.texture = allocate_texture_2d(
    texture_manager,
    gctx,
    extent,
    .R32_SFLOAT,
    {.SAMPLED, .STORAGE, .TRANSFER_DST},
    generate_mips = true,
  ) or_return
  img := get_texture_2d(texture_manager, pyramid.texture)
  cmd := gpu.begin_single_time_command(gctx) or_return
  gpu.image_discard_barrier(
    cmd,
    img.image,
    {.SHADER_READ, .SHADER_WRITE},
    {.COMPUTE_SHADER},
    {.COLOR},
    level_count = img.mip_levels,
  )
  gpu.end_single_time_command(gctx, &cmd) or_return
  for mip in 0 ..< img.mip_levels {
    pyramid.views[mip] = gpu.image_create_view(gctx.device, img, .D2, base_mip = mip) or_return
  }
  return .SUCCESS
}

occlusion_destroy_pyramid :: proc(
  gctx: ^gpu.GPUContext,
  pyramid: ^DepthPyramid,
  texture_manager: ^TextureManager,
) {
  for view in pyramid.views do vk.DestroyImageView(gctx.device, view, nil)
  if pyramid.texture != {} do free_texture_2d(texture_manager, gctx, pyramid.texture)
  pyramid^ = {}
}

// Reduce the camera's depth into every mip of `pyramid`, one dispatch per mip.
occlusion_build_pyramid :: proc(
  self: ^OcclusionSystem,
  command_buffer: vk.CommandBuffer,
  texture_manager: ^TextureManager,
  pyramid: ^DepthPyramid,
  descriptor_sets: []vk.DescriptorSet,
) {
  img := get_texture_2d(texture_manager, pyramid.texture)
  if img == nil do return
  vk.CmdBindPipeline(command_buffer, .COMPUTE, self.reduce_pipeline)
  for mip in 0 ..< img.mip_levels {
    if mip > 0 {
      gpu.memory_barrier(
        command_buffer,
        {.SHADER_WRITE},
        {.SHADER_READ},
        {.COMPUTE_SHADER},
        {.COMPUTE_SHADER},
      )
    }
    vk.CmdBindDescriptorSets(
      command_buffer,
      .COMPUTE,
      self.reduce_layout,
      0,
      1,
      &descriptor_sets[mip],
      0,
      nil,
    )
    current_mip := mip
    vk.CmdPushConstants(command_buffer, self.reduce_layout, {.COMPUTE}, 0, size_of(u32), &current_mip)
    width := max(1, img.extent.width >> mip)
    height := max(1, img.extent.height >> mip)
    vk.CmdDispatch(command_buffer, (width + 31) / 32, (height + 31) / 32, 1)
  }
}

occlusion_perform_culling :: proc(
  self: ^OcclusionSystem,
  command_buffer: vk.CommandBuffer,
  camera_index: u32,
  frame_index: u32,
  node_count: u32,
  draws: ^DrawBuffers,
  descriptor_set: vk.DescriptorSet,
) {
  if node_count == 0 do return
  // Zero this frame's counts so the shader can append. The previous frame's
  // draws may still read these lists on this queue; wait for them first.
  count := &draws.count[frame_index]
  gpu.memory_barrier(command_buffer, {}, {}, {.DRAW_INDIRECT}, {.TRANSFER, .COMPUTE_SHADER})
  vk.CmdFillBuffer(command_buffer, count.buffer, 0, vk.DeviceSize(count.bytes_count), 0)
  gpu.memory_barrier(
    command_buffer,
    {.TRANSFER_WRITE},
    {.SHADER_READ, .SHADER_WRITE},
    {.TRANSFER},
    {.COMPUTE_SHADER},
  )
  gpu.bind_pipeline(
    command_buffer,
    .COMPUTE,
    self.cull_pipeline,
    self.cull_layout,
    descriptor_set,
  )
  push_constants := OcclusionCullPushConstants {
    camera_index = camera_index,
    node_count   = node_count,
    max_draws    = self.max_draws,
  }
  vk.CmdPushConstants(
    command_buffer,
    self.cull_layout,
    {.COMPUTE},
    0,
    size_of(push_constants),
    &push_constants,
  )
  vk.CmdDispatch(command_buffer, (node_count + 63) / 64, 1, 1)
}

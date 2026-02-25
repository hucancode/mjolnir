package occlusion_culling

import alg "../../algebra"
import cont "../../containers"
import "../../geometry"
import "../../gpu"
import cam "../camera"
import d "../data"
import rd "../data"
import rg "../graph"
import "core:log"
import "core:math"
import vk "vendor:vulkan"

/*
Current Visibility Synchronization

Compute:
1. Build pyramid[N-1] from depth[N-1]
2. Cull using camera[N] + pyramid[N-1] → draw_list[N+1]
Meanwhile, render:
a. Render depth[N] using draw_list[N], camera[N]
b. Render geometry pass N using draw_list[N], camera[N]
c. Render shadow_depth[N] using shadow_draw_list[N], shadow_camera[N]
d. Render lighting pass with geometry pass N, shadow depth N
_________ end frame, sync _________
1,2 and a,b,c,d run in parallel
*/

SHADER_CULLING :: #load("../../shader/occlusion_culling/cull.spv")
SHADER_DEPTH_REDUCE :: #load("../../shader/occlusion_culling/depth_reduce.spv")
SHADER_DEPTH_VERT :: #load("../../shader/occlusion_culling/vert.spv")

VisibilityPushConstants :: struct {
  camera_index:      u32,
  node_count:        u32,
  max_draws:         u32,
  include_flags:     rd.NodeFlagSet,
  exclude_flags:     rd.NodeFlagSet,
  pyramid_width:     f32,
  pyramid_height:    f32,
  depth_bias:        f32,
  occlusion_enabled: u32,
}

DepthReducePushConstants :: struct {
  current_mip: u32,
}

CullingStats :: struct {
  opaque_draw_count: u32,
  camera_index:      u32,
  frame_index:       u32,
}

System :: struct {
  cull_layout:                    vk.PipelineLayout,
  cull_pipeline:                  vk.Pipeline, // Generates 3 draw lists in one dispatch
  depth_pipeline_layout:          vk.PipelineLayout,
  depth_pipeline:                 vk.Pipeline,
  depth_reduce_layout:            vk.PipelineLayout,
  depth_reduce_pipeline:          vk.Pipeline,
  cull_input_descriptor_layout:   vk.DescriptorSetLayout, // Set 0: inputs (nodes, meshes, cameras, depth pyramid)
  cull_output_descriptor_layout:  vk.DescriptorSetLayout, // Set 1: outputs (draw command buffers)
  depth_reduce_descriptor_layout: vk.DescriptorSetLayout,
  max_draws:                      u32,
  node_count:                     u32,
  depth_width:                    u32,
  depth_height:                   u32,
  depth_bias:                     f32,
  stats_enabled:                  bool,
}

init :: proc(
  self: ^System,
  gctx: ^gpu.GPUContext,
  depth_width, depth_height: u32,
  camera_set_layout: vk.DescriptorSetLayout,
  textures_set_layout: vk.DescriptorSetLayout,
  bone_set_layout: vk.DescriptorSetLayout,
  material_set_layout: vk.DescriptorSetLayout,
  node_data_set_layout: vk.DescriptorSetLayout,
  mesh_data_set_layout: vk.DescriptorSetLayout,
  vertex_skinning_set_layout: vk.DescriptorSetLayout,
) -> (
  ret: vk.Result,
) {
  self.max_draws = d.MAX_NODES_IN_SCENE
  self.depth_width = depth_width
  self.depth_height = depth_height
  self.depth_bias = 0.0001
  // Set 0: Input descriptor layout (read-only)
  self.cull_input_descriptor_layout = gpu.create_descriptor_set_layout(
  gctx,
  {.STORAGE_BUFFER, {.COMPUTE}}, // node data
  {.STORAGE_BUFFER, {.COMPUTE}}, // mesh data
  {.STORAGE_BUFFER, {.COMPUTE}}, // camera data
  {.COMBINED_IMAGE_SAMPLER, {.COMPUTE}}, // depth pyramid
  ) or_return
  defer if ret != .SUCCESS {
    vk.DestroyDescriptorSetLayout(
      gctx.device,
      self.cull_input_descriptor_layout,
      nil,
    )
    self.cull_input_descriptor_layout = 0
  }

  // Set 1: Output descriptor layout (draw command buffers)
  self.cull_output_descriptor_layout = gpu.create_descriptor_set_layout(
    gctx,
    {.STORAGE_BUFFER, {.COMPUTE}}, // opaque draw count
    {.STORAGE_BUFFER, {.COMPUTE}}, // opaque draw commands
    {.STORAGE_BUFFER, {.COMPUTE}}, // transparent draw count
    {.STORAGE_BUFFER, {.COMPUTE}}, // transparent draw commands
    {.STORAGE_BUFFER, {.COMPUTE}}, // wireframe draw count
    {.STORAGE_BUFFER, {.COMPUTE}}, // wireframe draw commands
    {.STORAGE_BUFFER, {.COMPUTE}}, // random_color draw count
    {.STORAGE_BUFFER, {.COMPUTE}}, // random_color draw commands
    {.STORAGE_BUFFER, {.COMPUTE}}, // line_strip draw count
    {.STORAGE_BUFFER, {.COMPUTE}}, // line_strip draw commands
    {.STORAGE_BUFFER, {.COMPUTE}}, // sprite draw count
    {.STORAGE_BUFFER, {.COMPUTE}}, // sprite draw commands
  ) or_return
  defer if ret != .SUCCESS {
    vk.DestroyDescriptorSetLayout(
      gctx.device,
      self.cull_output_descriptor_layout,
      nil,
    )
    self.cull_output_descriptor_layout = 0
  }
  self.depth_reduce_descriptor_layout = gpu.create_descriptor_set_layout(
    gctx,
    {.COMBINED_IMAGE_SAMPLER, {.COMPUTE}}, // source mip
    {.STORAGE_IMAGE, {.COMPUTE}}, // dest mip
  ) or_return
  defer if ret != .SUCCESS {
    vk.DestroyDescriptorSetLayout(
      gctx.device,
      self.depth_reduce_descriptor_layout,
      nil,
    )
    self.depth_reduce_descriptor_layout = 0
  }
  create_compute_pipelines(self, gctx) or_return
  defer if ret != .SUCCESS {
    vk.DestroyPipelineLayout(gctx.device, self.depth_reduce_layout, nil)
    vk.DestroyPipeline(gctx.device, self.depth_reduce_pipeline, nil)
    vk.DestroyPipelineLayout(gctx.device, self.cull_layout, nil)
    vk.DestroyPipeline(gctx.device, self.cull_pipeline, nil)
  }
  create_depth_pipeline(
    self,
    gctx,
    camera_set_layout,
    bone_set_layout,
    node_data_set_layout,
    mesh_data_set_layout,
    vertex_skinning_set_layout,
  ) or_return
  defer if ret != .SUCCESS {
    vk.DestroyPipelineLayout(gctx.device, self.depth_pipeline_layout, nil)
    vk.DestroyPipeline(gctx.device, self.depth_pipeline, nil)
  }
  return .SUCCESS
}

shutdown :: proc(self: ^System, gctx: ^gpu.GPUContext) {
  vk.DestroyPipeline(gctx.device, self.cull_pipeline, nil)
  vk.DestroyPipeline(gctx.device, self.depth_reduce_pipeline, nil)
  vk.DestroyPipeline(gctx.device, self.depth_pipeline, nil)
  self.cull_pipeline = 0
  self.depth_reduce_pipeline = 0
  self.depth_pipeline = 0
  vk.DestroyPipelineLayout(gctx.device, self.cull_layout, nil)
  vk.DestroyPipelineLayout(gctx.device, self.depth_reduce_layout, nil)
  vk.DestroyPipelineLayout(gctx.device, self.depth_pipeline_layout, nil)
  self.cull_layout = 0
  self.depth_reduce_layout = 0
  self.depth_pipeline_layout = 0
  vk.DestroyDescriptorSetLayout(
    gctx.device,
    self.cull_input_descriptor_layout,
    nil,
  )
  self.cull_input_descriptor_layout = 0
  vk.DestroyDescriptorSetLayout(
    gctx.device,
    self.cull_output_descriptor_layout,
    nil,
  )
  self.cull_output_descriptor_layout = 0
  vk.DestroyDescriptorSetLayout(
    gctx.device,
    self.depth_reduce_descriptor_layout,
    nil,
  )
  self.depth_reduce_descriptor_layout = 0
}

stats :: proc(
  self: ^System,
  opaque_draw_count: ^gpu.MutableBuffer(u32),
  camera_index: u32,
  frame_index: u32,
) -> CullingStats {
  stats := CullingStats {
    camera_index = camera_index,
    frame_index  = frame_index,
  }
  if opaque_draw_count != nil && opaque_draw_count.mapped != nil {
    stats.opaque_draw_count = opaque_draw_count.mapped[0]
  }
  return stats
}

// STEP 2: Render depth - reads draw list, writes depth[N]
// draw_list_source_gpu: Camera to use for draw lists (allows sharing culling results)
render_depth :: proc(
  self: ^System,
  gctx: ^gpu.GPUContext,
  command_buffer: vk.CommandBuffer,
  depth_attachment: gpu.Texture2DHandle,
  draw_commands: ^gpu.MutableBuffer(vk.DrawIndexedIndirectCommand),
  draw_count: ^gpu.MutableBuffer(u32),
  texture_manager: ^gpu.TextureManager,
  camera_index: u32,
  frame_index: u32,
  include_flags: rd.NodeFlagSet,
  exclude_flags: rd.NodeFlagSet,
  cameras_descriptor_set: vk.DescriptorSet,
  bone_descriptor_set: vk.DescriptorSet,
  node_data_descriptor_set: vk.DescriptorSet,
  mesh_data_descriptor_set: vk.DescriptorSet,
  vertex_skinning_descriptor_set: vk.DescriptorSet,
  vertex_buffer: vk.Buffer,
  index_buffer: vk.Buffer,
) {
  _ = include_flags
  _ = exclude_flags
  _ = frame_index

  depth_texture := gpu.get_texture_2d(
    texture_manager,
    depth_attachment,
  )
  if depth_texture == nil do return
  gpu.image_barrier(
    command_buffer,
    depth_texture.image,
    .UNDEFINED,
    .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
    {},
    {.DEPTH_STENCIL_ATTACHMENT_WRITE},
    {.TOP_OF_PIPE},
    {.EARLY_FRAGMENT_TESTS},
    {.DEPTH},
  )
  depth_attachment := gpu.create_depth_attachment(
    depth_texture,
    .CLEAR,
    .STORE,
  )
  gpu.begin_depth_rendering(
    command_buffer,
    depth_texture.spec.extent,
    &depth_attachment,
  )
  gpu.set_viewport_scissor(command_buffer, depth_texture.spec.extent)
  gpu.bind_graphics_pipeline(
    command_buffer,
    self.depth_pipeline,
    self.depth_pipeline_layout,
    cameras_descriptor_set,
    bone_descriptor_set,
    node_data_descriptor_set,
    mesh_data_descriptor_set,
    vertex_skinning_descriptor_set,
  )
  camera_index := camera_index
  vk.CmdPushConstants(
    command_buffer,
    self.depth_pipeline_layout,
    {.VERTEX, .FRAGMENT},
    0,
    size_of(u32),
    &camera_index,
  )
  gpu.bind_vertex_index_buffers(command_buffer, vertex_buffer, index_buffer)
  // Use current frame's draw list (prepared by frame N-1 compute)
  // draw_list[frame_index] was written by Compute N-1, safe to read during Render N
  vk.CmdDrawIndexedIndirectCount(
    command_buffer,
    draw_commands.buffer,
    0, // offset
    draw_count.buffer,
    0, // count offset
    self.max_draws,
    u32(size_of(vk.DrawIndexedIndirectCommand)),
  )
  vk.CmdEndRendering(command_buffer)
  // Barrier: depth writes complete, transition for compute + fragment shader reads
  // Pyramid generation (compute) and lighting (fragment) both sample this depth
  gpu.image_barrier(
    command_buffer,
    depth_texture.image,
    .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
    .DEPTH_STENCIL_READ_ONLY_OPTIMAL,
    {.DEPTH_STENCIL_ATTACHMENT_WRITE},
    {.SHADER_READ},
    {.LATE_FRAGMENT_TESTS},
    {.COMPUTE_SHADER, .FRAGMENT_SHADER},
    {.DEPTH},
  )
}

// STEP 3: Build pyramid - reads depth[N-1], builds pyramid[N]
build_pyramid :: proc(
  self: ^System,
  gctx: ^gpu.GPUContext,
  command_buffer: vk.CommandBuffer,
  depth_pyramid: ^cam.DepthPyramid,
  depth_reduce_descriptor_sets: ^[cam.MAX_DEPTH_MIPS_LEVEL]vk.DescriptorSet,
  opaque_draw_count: ^gpu.MutableBuffer(u32),
  camera_index: u32,
  frame_index: u32, // Which pyramid to write to
) {
  _ = gctx
  _ = frame_index
  if self.node_count == 0 do return
  if depth_pyramid == nil do return
  // Build pyramid[target] from depth[target-1]
  // This allows async compute to build pyramid[N] from depth[N-1] while graphics renders depth[N]
  vk.CmdBindPipeline(command_buffer, .COMPUTE, self.depth_reduce_pipeline)
  // Generate ALL mip levels using the same shader
  // Mip 0: reads from depth[N-1] (configured in descriptor sets)
  // Other mips: read from pyramid[N] mip-1
  for mip in 0 ..< depth_pyramid.mip_levels {
    vk.CmdBindDescriptorSets(
      command_buffer,
      .COMPUTE,
      self.depth_reduce_layout,
      0,
      1,
      &depth_reduce_descriptor_sets[mip],
      0,
      nil,
    )
    push_constants := DepthReducePushConstants {
      current_mip = u32(mip),
    }
    vk.CmdPushConstants(
      command_buffer,
      self.depth_reduce_layout,
      {.COMPUTE},
      0,
      size_of(push_constants),
      &push_constants,
    )
    mip_width := max(1, depth_pyramid.width >> mip)
    mip_height := max(1, depth_pyramid.height >> mip)
    dispatch_x := (mip_width + 31) / 32
    dispatch_y := (mip_height + 31) / 32
    vk.CmdDispatch(command_buffer, dispatch_x, dispatch_y, 1)
    // only synchronize the dependency chain, don't transition layouts
    if mip < depth_pyramid.mip_levels - 1 {
      gpu.memory_barrier(
        command_buffer,
        {.SHADER_WRITE},
        {.SHADER_READ},
        {.COMPUTE_SHADER},
        {.COMPUTE_SHADER},
      )
    }
  }
  if self.stats_enabled {
    count: u32 = 0
    if opaque_draw_count != nil && opaque_draw_count.mapped != nil {
      count = opaque_draw_count.mapped[0]
    }
    efficiency: f32 = 0.0
    if self.node_count > 0 {
      efficiency = f32(count) / f32(self.node_count) * 100.0
    }
    log.infof(
      "[Camera %d Frame %d] Culling Stats: Total Objects=%d | Late Pass=%d | Efficiency=%.1f%%",
      camera_index,
      frame_index,
      self.node_count,
      count,
      efficiency,
    )
  }
}

// Frame N compute writes to buffer[N], while frame N graphics reads buffer[N-1]
// Uses multi_pass pipeline but only opaque_draw_count/commands are used
perform_culling :: proc(
  self: ^System,
  gctx: ^gpu.GPUContext,
  command_buffer: vk.CommandBuffer,
  camera_index: u32,
  frame_index: u32,
  include_flags: rd.NodeFlagSet,
  exclude_flags: rd.NodeFlagSet,
  opaque_draw_count: ^gpu.MutableBuffer(u32),
  transparent_draw_count: ^gpu.MutableBuffer(u32),
  wireframe_draw_count: ^gpu.MutableBuffer(u32),
  random_color_draw_count: ^gpu.MutableBuffer(u32),
  line_strip_draw_count: ^gpu.MutableBuffer(u32),
  sprite_draw_count: ^gpu.MutableBuffer(u32),
  cull_input_descriptor_set: vk.DescriptorSet,
  cull_output_descriptor_set: vk.DescriptorSet,
  pyramid_width, pyramid_height: u32,
) {
  _ = gctx
  if self.node_count == 0 do return
  vk.CmdFillBuffer(
    command_buffer,
    opaque_draw_count.buffer,
    0,
    vk.DeviceSize(opaque_draw_count.bytes_count),
    0,
  )
  vk.CmdFillBuffer(
    command_buffer,
    transparent_draw_count.buffer,
    0,
    vk.DeviceSize(transparent_draw_count.bytes_count),
    0,
  )
  vk.CmdFillBuffer(
    command_buffer,
    wireframe_draw_count.buffer,
    0,
    vk.DeviceSize(wireframe_draw_count.bytes_count),
    0,
  )
  vk.CmdFillBuffer(
    command_buffer,
    random_color_draw_count.buffer,
    0,
    vk.DeviceSize(random_color_draw_count.bytes_count),
    0,
  )
  vk.CmdFillBuffer(
    command_buffer,
    line_strip_draw_count.buffer,
    0,
    vk.DeviceSize(line_strip_draw_count.bytes_count),
    0,
  )
  vk.CmdFillBuffer(
    command_buffer,
    sprite_draw_count.buffer,
    0,
    vk.DeviceSize(sprite_draw_count.bytes_count),
    0,
  )
  gpu.bind_compute_pipeline(
    command_buffer,
    self.cull_pipeline,
    self.cull_layout,
    cull_input_descriptor_set, // Set 0: inputs
    cull_output_descriptor_set, // Set 1: outputs
  )
  _ = alg.prev(frame_index, d.FRAMES_IN_FLIGHT)
  push_constants := VisibilityPushConstants {
    camera_index      = camera_index,
    node_count        = self.node_count,
    max_draws         = self.max_draws,
    include_flags     = include_flags,
    exclude_flags     = exclude_flags,
    pyramid_width     = f32(pyramid_width),
    pyramid_height    = f32(pyramid_height),
    depth_bias        = self.depth_bias,
    occlusion_enabled = 1,
  }
  vk.CmdPushConstants(
    command_buffer,
    self.cull_layout,
    {.COMPUTE},
    0,
    size_of(push_constants),
    &push_constants,
  )
  dispatch_x := (self.node_count + 63) / 64
  vk.CmdDispatch(command_buffer, dispatch_x, 1, 1)
}

@(private)
create_compute_pipelines :: proc(
  self: ^System,
  gctx: ^gpu.GPUContext,
) -> vk.Result {
  self.cull_layout = gpu.create_pipeline_layout(
    gctx,
    vk.PushConstantRange {
      stageFlags = {.COMPUTE},
      size = size_of(VisibilityPushConstants),
    },
    self.cull_input_descriptor_layout, // Set 0: inputs
    self.cull_output_descriptor_layout, // Set 1: outputs
  ) or_return
  self.depth_reduce_layout = gpu.create_pipeline_layout(
    gctx,
    vk.PushConstantRange {
      stageFlags = {.COMPUTE},
      size = size_of(DepthReducePushConstants),
    },
    self.depth_reduce_descriptor_layout,
  ) or_return
  shader := gpu.create_shader_module(gctx.device, SHADER_CULLING) or_return
  defer vk.DestroyShaderModule(gctx.device, shader, nil)
  depth_shader := gpu.create_shader_module(
    gctx.device,
    SHADER_DEPTH_REDUCE,
  ) or_return
  defer vk.DestroyShaderModule(gctx.device, depth_shader, nil)
  self.cull_pipeline = gpu.create_compute_pipeline(
    gctx,
    shader,
    self.cull_layout,
  ) or_return
  self.depth_reduce_pipeline = gpu.create_compute_pipeline(
    gctx,
    depth_shader,
    self.depth_reduce_layout,
  ) or_return
  return .SUCCESS
}

@(private)
create_depth_pipeline :: proc(
  self: ^System,
  gctx: ^gpu.GPUContext,
  camera_set_layout: vk.DescriptorSetLayout,
  bone_set_layout: vk.DescriptorSetLayout,
  node_data_set_layout: vk.DescriptorSetLayout,
  mesh_data_set_layout: vk.DescriptorSetLayout,
  vertex_skinning_set_layout: vk.DescriptorSetLayout,
) -> vk.Result {
  self.depth_pipeline_layout = gpu.create_pipeline_layout(
    gctx,
    vk.PushConstantRange {
      stageFlags = {.VERTEX, .FRAGMENT},
      size = size_of(u32),
    },
    camera_set_layout,
    bone_set_layout,
    node_data_set_layout,
    mesh_data_set_layout,
    vertex_skinning_set_layout,
  ) or_return
  vert_shader := gpu.create_shader_module(
    gctx.device,
    SHADER_DEPTH_VERT,
  ) or_return
  defer vk.DestroyShaderModule(gctx.device, vert_shader, nil)
  shader_stages := gpu.create_vert_stage(vert_shader)
  vertex_bindings := [?]vk.VertexInputBindingDescription {
    {binding = 0, stride = size_of(geometry.Vertex), inputRate = .VERTEX},
  }
  vertex_attributes := [?]vk.VertexInputAttributeDescription {
    {
      location = 0,
      binding = 0,
      format = .R32G32B32_SFLOAT,
      offset = u32(offset_of(geometry.Vertex, position)),
    },
  }
  vertex_input_info := vk.PipelineVertexInputStateCreateInfo {
    sType                           = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
    vertexBindingDescriptionCount   = len(vertex_bindings),
    pVertexBindingDescriptions      = raw_data(vertex_bindings[:]),
    vertexAttributeDescriptionCount = len(vertex_attributes),
    pVertexAttributeDescriptions    = raw_data(vertex_attributes[:]),
  }
  pipeline_info := vk.GraphicsPipelineCreateInfo {
    sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
    pNext               = &gpu.DEPTH_ONLY_RENDERING_INFO,
    stageCount          = len(shader_stages),
    pStages             = raw_data(shader_stages[:]),
    pVertexInputState   = &vertex_input_info,
    pInputAssemblyState = &gpu.STANDARD_INPUT_ASSEMBLY,
    pViewportState      = &gpu.STANDARD_VIEWPORT_STATE,
    pRasterizationState = &gpu.STANDARD_RASTERIZER,
    pMultisampleState   = &gpu.STANDARD_MULTISAMPLING,
    pDepthStencilState  = &gpu.READ_WRITE_DEPTH_STATE,
    pDynamicState       = &gpu.STANDARD_DYNAMIC_STATES,
    layout              = self.depth_pipeline_layout,
  }
  vk.CreateGraphicsPipelines(
    gctx.device,
    0,
    1,
    &pipeline_info,
    nil,
    &self.depth_pipeline,
  ) or_return
  return .SUCCESS
}

// ============================================================================
// RENDER GRAPH INTEGRATION
// ============================================================================

DepthPyramidBlackboard :: struct {
  depth:                        rg.DepthTexture,
  pyramid:                      rg.Texture,
  enable_depth_pyramid:         bool,
  mip_levels:                   u32,
  depth_reduce_descriptor_sets: [cam.MAX_DEPTH_MIPS_LEVEL]vk.DescriptorSet,
}

depth_pyramid_pass_deps_from_context :: proc(
  pass_ctx: ^rg.PassContext,
) -> DepthPyramidBlackboard {
  return DepthPyramidBlackboard {
    depth = rg.get_depth(pass_ctx, .CAMERA_DEPTH),
    pyramid = rg.get_texture(pass_ctx, .CAMERA_DEPTH_PYRAMID),
  }
}

depth_pyramid_pass_execute :: proc(
  self: ^System,
  pass_ctx: ^rg.PassContext,
  deps: DepthPyramidBlackboard,
) {
  cam_idx := pass_ctx.scope_index
  if cam_idx >= rg.MAX_CAMERAS || !deps.enable_depth_pyramid do return
  if self.node_count == 0 do return

  _ = deps.depth
  pyramid := deps.pyramid

  mip_levels := deps.mip_levels
  if mip_levels == 0 do return

  vk.CmdBindPipeline(pass_ctx.cmd, .COMPUTE, self.depth_reduce_pipeline)
  for mip in 0 ..< mip_levels {
    descriptor_set := deps.depth_reduce_descriptor_sets[mip]
    vk.CmdBindDescriptorSets(
      pass_ctx.cmd,
      .COMPUTE,
      self.depth_reduce_layout,
      0,
      1,
      &descriptor_set,
      0,
      nil,
    )
    push_constants := DepthReducePushConstants {
      current_mip = mip,
    }
    vk.CmdPushConstants(
      pass_ctx.cmd,
      self.depth_reduce_layout,
      {.COMPUTE},
      0,
      size_of(push_constants),
      &push_constants,
    )
    mip_width := max(1, pyramid.extent.width >> mip)
    mip_height := max(1, pyramid.extent.height >> mip)
    dispatch_x := (mip_width + 31) / 32
    dispatch_y := (mip_height + 31) / 32
    vk.CmdDispatch(pass_ctx.cmd, dispatch_x, dispatch_y, 1)
    if mip < mip_levels - 1 {
      gpu.memory_barrier(
        pass_ctx.cmd,
        {.SHADER_WRITE},
        {.SHADER_READ},
        {.COMPUTE_SHADER},
        {.COMPUTE_SHADER},
      )
    }
  }
}

CullingBlackboard :: struct {
  opaque_draw_count:       rg.Buffer,
  transparent_draw_count:  rg.Buffer,
  wireframe_draw_count:    rg.Buffer,
  random_color_draw_count: rg.Buffer,
  line_strip_draw_count:   rg.Buffer,
  sprite_draw_count:       rg.Buffer,
  enable_culling:          bool,
  cull_input_descriptor_set:  vk.DescriptorSet,
  cull_output_descriptor_set: vk.DescriptorSet,
  pyramid_width:           u32,
  pyramid_height:          u32,
}

visibility_culling_pass_deps_from_context :: proc(
  pass_ctx: ^rg.PassContext,
) -> CullingBlackboard {
  return CullingBlackboard {
    opaque_draw_count = rg.get_buffer(pass_ctx, .CAMERA_OPAQUE_DRAW_COUNT),
    transparent_draw_count = rg.get_buffer(
      pass_ctx,
      .CAMERA_TRANSPARENT_DRAW_COUNT,
    ),
    wireframe_draw_count = rg.get_buffer(
      pass_ctx,
      .CAMERA_WIREFRAME_DRAW_COUNT,
    ),
    random_color_draw_count = rg.get_buffer(
      pass_ctx,
      .CAMERA_RANDOM_COLOR_DRAW_COUNT,
    ),
    line_strip_draw_count = rg.get_buffer(
      pass_ctx,
      .CAMERA_LINE_STRIP_DRAW_COUNT,
    ),
    sprite_draw_count = rg.get_buffer(pass_ctx, .CAMERA_SPRITE_DRAW_COUNT),
  }
}

visibility_culling_pass_execute :: proc(
  self: ^System,
  pass_ctx: ^rg.PassContext,
  deps: CullingBlackboard,
) {
  cam_idx := pass_ctx.scope_index
  if cam_idx >= rg.MAX_CAMERAS || !deps.enable_culling do return
  if self.node_count == 0 do return

  opaque_draw_count := deps.opaque_draw_count
  transparent_draw_count := deps.transparent_draw_count
  wireframe_draw_count := deps.wireframe_draw_count
  random_color_draw_count := deps.random_color_draw_count
  line_strip_draw_count := deps.line_strip_draw_count
  sprite_draw_count := deps.sprite_draw_count

  vk.CmdFillBuffer(
    pass_ctx.cmd,
    opaque_draw_count.buffer,
    0,
    opaque_draw_count.size,
    0,
  )
  vk.CmdFillBuffer(
    pass_ctx.cmd,
    transparent_draw_count.buffer,
    0,
    transparent_draw_count.size,
    0,
  )
  vk.CmdFillBuffer(
    pass_ctx.cmd,
    wireframe_draw_count.buffer,
    0,
    wireframe_draw_count.size,
    0,
  )
  vk.CmdFillBuffer(
    pass_ctx.cmd,
    random_color_draw_count.buffer,
    0,
    random_color_draw_count.size,
    0,
  )
  vk.CmdFillBuffer(
    pass_ctx.cmd,
    line_strip_draw_count.buffer,
    0,
    line_strip_draw_count.size,
    0,
  )
  vk.CmdFillBuffer(
    pass_ctx.cmd,
    sprite_draw_count.buffer,
    0,
    sprite_draw_count.size,
    0,
  )

  input_set := deps.cull_input_descriptor_set
  output_set := deps.cull_output_descriptor_set
  gpu.bind_compute_pipeline(
    pass_ctx.cmd,
    self.cull_pipeline,
    self.cull_layout,
    input_set,
    output_set,
  )

  _ = alg.prev(pass_ctx.frame_index, d.FRAMES_IN_FLIGHT)
  push_constants := VisibilityPushConstants {
    camera_index      = cam_idx,
    node_count        = self.node_count,
    max_draws         = self.max_draws,
    include_flags     = {.VISIBLE},
    exclude_flags     = {},
    pyramid_width     = f32(deps.pyramid_width),
    pyramid_height    = f32(deps.pyramid_height),
    depth_bias        = self.depth_bias,
    occlusion_enabled = 1,
  }
  vk.CmdPushConstants(
    pass_ctx.cmd,
    self.cull_layout,
    {.COMPUTE},
    0,
    size_of(push_constants),
    &push_constants,
  )
  dispatch_x := (self.node_count + 63) / 64
  vk.CmdDispatch(pass_ctx.cmd, dispatch_x, 1, 1)
}

// Execute phase: render with resolved resources
DepthRenderBlackboard :: struct {
  depth:                        rg.DepthTexture,
  draw_commands:                rg.Buffer,
  draw_count:                   rg.Buffer,
  cameras_descriptor_set:       vk.DescriptorSet,
  bone_descriptor_set:          vk.DescriptorSet,
  node_data_descriptor_set:     vk.DescriptorSet,
  mesh_data_descriptor_set:     vk.DescriptorSet,
  vertex_skinning_descriptor_set: vk.DescriptorSet,
  vertex_buffer:                vk.Buffer,
  index_buffer:                 vk.Buffer,
}

depth_pass_deps_from_context :: proc(
  pass_ctx: ^rg.PassContext,
) -> DepthRenderBlackboard {
  return DepthRenderBlackboard {
    depth = rg.get_depth(pass_ctx, .CAMERA_DEPTH),
    draw_commands = rg.get_buffer(pass_ctx, .CAMERA_OPAQUE_DRAW_COMMANDS),
    draw_count = rg.get_buffer(pass_ctx, .CAMERA_OPAQUE_DRAW_COUNT),
  }
}

depth_pass_execute :: proc(
  self: ^System,
  pass_ctx: ^rg.PassContext,
  deps: DepthRenderBlackboard,
) {
  cmd := pass_ctx.cmd
  cam_idx := pass_ctx.scope_index

  depth_handle := deps.depth

  // Begin depth rendering
  depth_attachment := vk.RenderingAttachmentInfo {
    sType = .RENDERING_ATTACHMENT_INFO,
    imageView = depth_handle.view,
    imageLayout = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
    loadOp = .CLEAR,
    storeOp = .STORE,
    clearValue = {depthStencil = {depth = 1.0}},
  }

  gpu.begin_depth_rendering(cmd, depth_handle.extent, &depth_attachment)

  gpu.set_viewport_scissor(cmd, depth_handle.extent)

  // Bind graphics pipeline
  gpu.bind_graphics_pipeline(
    cmd,
    self.depth_pipeline,
    self.depth_pipeline_layout,
    deps.cameras_descriptor_set,
    deps.bone_descriptor_set,
    deps.node_data_descriptor_set,
    deps.mesh_data_descriptor_set,
    deps.vertex_skinning_descriptor_set,
  )

  // Push camera index
  camera_index := cam_idx
  vk.CmdPushConstants(
    cmd,
    self.depth_pipeline_layout,
    {.VERTEX, .FRAGMENT},
    0,
    size_of(u32),
    &camera_index,
  )

  gpu.bind_vertex_index_buffers(cmd, deps.vertex_buffer, deps.index_buffer)

  draw_cmd_handle := deps.draw_commands

  draw_count_handle := deps.draw_count

  // Draw indexed indirect count
  vk.CmdDrawIndexedIndirectCount(
    cmd,
    draw_cmd_handle.buffer,
    0, // offset
    draw_count_handle.buffer,
    0, // count offset
    self.max_draws,
    u32(size_of(vk.DrawIndexedIndirectCommand)),
  )

  vk.CmdEndRendering(cmd)
}

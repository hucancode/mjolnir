package occlusion_culling

import alg "../../algebra"
import cont "../../containers"
import "../../geometry"
import "../../gpu"
import cam "../camera"
import d "../data"
import rd "../data"
import "core:fmt"
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
  camera: ^cam.Camera,
  camera_index: u32,
  frame_index: u32,
) -> CullingStats {
  stats := CullingStats {
    camera_index = camera_index,
    frame_index  = frame_index,
  }
  if camera.opaque_draw_count[frame_index].mapped != nil {
    stats.opaque_draw_count = camera.opaque_draw_count[frame_index].mapped[0]
  }
  return stats
}

// STEP 2: Render depth - reads draw list, writes depth[N]
// draw_list_source_gpu: Camera to use for draw lists (allows sharing culling results)
render_depth :: proc(
  self: ^System,
  gctx: ^gpu.GPUContext,
  command_buffer: vk.CommandBuffer,
  camera: ^cam.Camera,
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
  depth_texture := gpu.get_texture_2d(
    texture_manager,
    camera.attachments[.DEPTH][frame_index],
  )
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
    camera.opaque_draw_commands[frame_index].buffer,
    0, // offset
    camera.opaque_draw_count[frame_index].buffer,
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
  camera: ^cam.Camera,
  camera_index: u32,
  frame_index: u32, // Which pyramid to write to
) {
  if self.node_count == 0 do return
  // Build pyramid[target] from depth[target-1]
  // This allows async compute to build pyramid[N] from depth[N-1] while graphics renders depth[N]
  vk.CmdBindPipeline(command_buffer, .COMPUTE, self.depth_reduce_pipeline)
  // Generate ALL mip levels using the same shader
  // Mip 0: reads from depth[N-1] (configured in descriptor sets)
  // Other mips: read from pyramid[N] mip-1
  for mip in 0 ..< camera.depth_pyramid[frame_index].mip_levels {
    vk.CmdBindDescriptorSets(
      command_buffer,
      .COMPUTE,
      self.depth_reduce_layout,
      0,
      1,
      &camera.depth_reduce_descriptor_sets[frame_index][mip],
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
    mip_width := max(1, camera.depth_pyramid[frame_index].width >> mip)
    mip_height := max(1, camera.depth_pyramid[frame_index].height >> mip)
    dispatch_x := (mip_width + 31) / 32
    dispatch_y := (mip_height + 31) / 32
    vk.CmdDispatch(command_buffer, dispatch_x, dispatch_y, 1)
    // only synchronize the dependency chain, don't transition layouts
    if mip < camera.depth_pyramid[frame_index].mip_levels - 1 {
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
    if camera.opaque_draw_count[frame_index].mapped != nil {
      count = camera.opaque_draw_count[frame_index].mapped[0]
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
  camera: ^cam.Camera,
  camera_index: u32,
  frame_index: u32,
  include_flags: rd.NodeFlagSet,
  exclude_flags: rd.NodeFlagSet,
) {
  if self.node_count == 0 do return
  vk.CmdFillBuffer(
    command_buffer,
    camera.opaque_draw_count[frame_index].buffer,
    0,
    vk.DeviceSize(camera.opaque_draw_count[frame_index].bytes_count),
    0,
  )
  vk.CmdFillBuffer(
    command_buffer,
    camera.transparent_draw_count[frame_index].buffer,
    0,
    vk.DeviceSize(camera.transparent_draw_count[frame_index].bytes_count),
    0,
  )
  vk.CmdFillBuffer(
    command_buffer,
    camera.wireframe_draw_count[frame_index].buffer,
    0,
    vk.DeviceSize(camera.wireframe_draw_count[frame_index].bytes_count),
    0,
  )
  vk.CmdFillBuffer(
    command_buffer,
    camera.random_color_draw_count[frame_index].buffer,
    0,
    vk.DeviceSize(camera.random_color_draw_count[frame_index].bytes_count),
    0,
  )
  vk.CmdFillBuffer(
    command_buffer,
    camera.line_strip_draw_count[frame_index].buffer,
    0,
    vk.DeviceSize(camera.line_strip_draw_count[frame_index].bytes_count),
    0,
  )
  vk.CmdFillBuffer(
    command_buffer,
    camera.sprite_draw_count[frame_index].buffer,
    0,
    vk.DeviceSize(camera.sprite_draw_count[frame_index].bytes_count),
    0,
  )
  gpu.bind_compute_pipeline(
    command_buffer,
    self.cull_pipeline,
    self.cull_layout,
    camera.cull_input_descriptor_set[frame_index],  // Set 0: inputs
    camera.cull_output_descriptor_set[frame_index], // Set 1: outputs
  )
  prev_frame := alg.prev(frame_index, d.FRAMES_IN_FLIGHT)
  push_constants := VisibilityPushConstants {
    camera_index      = camera_index,
    node_count        = self.node_count,
    max_draws         = self.max_draws,
    include_flags     = include_flags,
    exclude_flags     = exclude_flags,
    pyramid_width     = f32(camera.depth_pyramid[prev_frame].width),
    pyramid_height    = f32(camera.depth_pyramid[prev_frame].height),
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

// Perform transparency culling - generates all 5 transparency draw lists in one dispatch
// This is used by the graph-based transparency culling pass
// ============================================================================
// Graph-based API for unified visibility culling pass
// This pass generates ALL draw lists (opaque + 5 transparency types) in one dispatch
// ============================================================================

VisibilityCullingPassGraphContext :: struct {
  system:       ^System,
  gctx:         ^gpu.GPUContext,
  camera:       ^cam.Camera,
  camera_index: u32,
}

// Execute phase: perform unified visibility culling
// Processes ALL visible objects and routes to appropriate buffers based on material flags
// Shader automatically applies occlusion culling only to opaque objects
visibility_culling_pass_execute :: proc(pass_ctx: ^rg.PassContext, user_data: rawptr) {
  ctx := cast(^VisibilityCullingPassGraphContext)user_data

  // Call perform_culling with flags that include ALL visible objects
  // The shader will route objects to appropriate buffers based on material flags
  // and automatically skip occlusion culling for transparent objects
  perform_culling(
    ctx.system,
    ctx.gctx,
    pass_ctx.cmd,
    ctx.camera,
    ctx.camera_index,
    pass_ctx.frame_index,
    rd.NodeFlagSet{.VISIBLE}, // Include all visible objects
    rd.NodeFlagSet{}, // No exclusions - shader handles routing
  )
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
    self.cull_input_descriptor_layout,  // Set 0: inputs
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

import rg "../graph"

// Context for graph-based depth pass rendering
DepthPassGraphContext :: struct {
  system:                    ^System,
  texture_manager:           ^gpu.TextureManager,
  include_flags:             rd.NodeFlagSet,
  exclude_flags:             rd.NodeFlagSet,
  cameras_descriptor_set:    vk.DescriptorSet,
  bone_descriptor_set:       vk.DescriptorSet,
  node_data_descriptor_set:  vk.DescriptorSet,
  mesh_data_descriptor_set:  vk.DescriptorSet,
  vertex_skinning_descriptor_set: vk.DescriptorSet,
  vertex_buffer:             vk.Buffer,
  index_buffer:              vk.Buffer,
}

// Setup phase: declare resource dependencies
// REMOVED: Old setup callback (replaced by declarative PassTemplate)

// Execute phase: render with resolved resources
depth_pass_execute :: proc(pass_ctx: ^rg.PassContext, user_data: rawptr) {
  ctx := cast(^DepthPassGraphContext)user_data
  self := ctx.system
  cmd := pass_ctx.cmd
  cam_idx := pass_ctx.scope_index

  // Resolve depth texture
  depth_name := fmt.tprintf("camera_%d_depth", cam_idx)
  depth_id := rg.ResourceId(depth_name)
  depth_handle, depth_ok := rg.resolve(rg.DepthTextureHandle, pass_ctx, depth_id)
  if !depth_ok do return

  // Begin depth rendering
  depth_attachment := vk.RenderingAttachmentInfo {
    sType = .RENDERING_ATTACHMENT_INFO,
    imageView = depth_handle.view,
    imageLayout = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
    loadOp = .CLEAR,
    storeOp = .STORE,
    clearValue = {depthStencil = {depth = 1.0}},
  }

  gpu.begin_depth_rendering(
    cmd,
    depth_handle.extent,
    &depth_attachment,
  )

  gpu.set_viewport_scissor(cmd, depth_handle.extent)

  // Bind graphics pipeline
  gpu.bind_graphics_pipeline(
    cmd,
    self.depth_pipeline,
    self.depth_pipeline_layout,
    ctx.cameras_descriptor_set,
    ctx.bone_descriptor_set,
    ctx.node_data_descriptor_set,
    ctx.mesh_data_descriptor_set,
    ctx.vertex_skinning_descriptor_set,
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

  gpu.bind_vertex_index_buffers(cmd, ctx.vertex_buffer, ctx.index_buffer)

  // Resolve draw commands buffer
  draw_cmd_name := fmt.tprintf("camera_%d_opaque_draw_commands", cam_idx)
  draw_cmd_id := rg.ResourceId(draw_cmd_name)
  draw_cmd_handle, draw_cmd_ok := rg.resolve(rg.BufferHandle, pass_ctx, draw_cmd_id)
  if !draw_cmd_ok {
    vk.CmdEndRendering(cmd)
    return
  }

  // Resolve draw count buffer
  draw_count_name := fmt.tprintf("camera_%d_opaque_draw_count", cam_idx)
  draw_count_id := rg.ResourceId(draw_count_name)
  draw_count_handle, draw_count_ok := rg.resolve(rg.BufferHandle, pass_ctx, draw_count_id)
  if !draw_count_ok {
    vk.CmdEndRendering(cmd)
    return
  }

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

  // Note: Barriers are now handled automatically by the graph
  // The manual barriers (UNDEFINED->DEPTH_ATTACHMENT and DEPTH_ATTACHMENT->SHADER_READ)
  // are replaced by automatic graph barrier computation
}

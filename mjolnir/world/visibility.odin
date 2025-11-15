package world

import cont "../containers"
import geometry "../geometry"
import gpu "../gpu"
import resources "../resources"
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

SHADER_SPHERECAM_CULLING :: #load(
  "../shader/occlusion_culling/sphere_cull.spv",
)
SHADER_CULLING :: #load("../shader/occlusion_culling/cull.spv")
SHADER_DEPTH_REDUCE :: #load("../shader/occlusion_culling/depth_reduce.spv")
SHADER_DEPTH_VERT :: #load("../shader/occlusion_culling/vert.spv")
SHADER_SPHERECAM_DEPTH_VERT :: #load("../shader/shadow_spherical/vert.spv")
SHADER_SPHERECAM_DEPTH_GEOM :: #load("../shader/shadow_spherical/geom.spv")
SHADER_SPHERECAM_DEPTH_FRAG :: #load("../shader/shadow_spherical/frag.spv")

VisibilityPushConstants :: struct {
  camera_index:      u32,
  node_count:        u32,
  max_draws:         u32,
  include_flags:     resources.NodeFlagSet,
  exclude_flags:     resources.NodeFlagSet,
  pyramid_width:     f32,
  pyramid_height:    f32,
  depth_bias:        f32,
  occlusion_enabled: u32,
}

DepthReducePushConstants :: struct {
  current_mip: u32,
  _padding:    [3]u32,
}

CullingStats :: struct {
  late_draw_count: u32,
  camera_index:    u32,
  frame_index:     u32,
}

VisibilitySystem :: struct {
  sphere_cull_pipeline:     vk.Pipeline, // For SphericalCamera (radius-based culling)
  cull_pipeline:            vk.Pipeline, // Generates 3 draw lists in one dispatch
  depth_reduce_pipeline:    vk.Pipeline,
  sphere_cull_layout:       vk.PipelineLayout,
  cull_layout:              vk.PipelineLayout,
  depth_reduce_layout:      vk.PipelineLayout,
  depth_pipeline:           vk.Pipeline, // uses geometry_pipeline_layout
  spherical_depth_pipeline: vk.Pipeline, // uses spherical_camera_pipeline_layout
  max_draws:                u32,
  node_count:               u32,
  depth_width:              u32,
  depth_height:             u32,
  depth_bias:               f32,
  stats_enabled:            bool,
}

visibility_system_init :: proc(
  system: ^VisibilitySystem,
  gctx: ^gpu.GPUContext,
  rm: ^resources.Manager,
  depth_width: u32,
  depth_height: u32,
) -> (
  ret: vk.Result,
) {
  system.max_draws = resources.MAX_NODES_IN_SCENE
  system.depth_width = depth_width
  system.depth_height = depth_height
  system.depth_bias = 0.0001
  create_descriptor_layouts(system, gctx, rm) or_return
  defer if ret != .SUCCESS {
    vk.DestroyDescriptorSetLayout(
      gctx.device,
      rm.visibility_depth_reduce_descriptor_layout,
      nil,
    )
    vk.DestroyDescriptorSetLayout(
      gctx.device,
      rm.visibility_descriptor_layout,
      nil,
    )
    vk.DestroyDescriptorSetLayout(
      gctx.device,
      rm.visibility_sphere_descriptor_layout,
      nil,
    )
  }
  create_compute_pipelines(system, gctx, rm) or_return
  defer if ret != .SUCCESS {
    vk.DestroyPipelineLayout(gctx.device, system.depth_reduce_layout, nil)
    vk.DestroyPipeline(gctx.device, system.depth_reduce_pipeline, nil)
    vk.DestroyPipelineLayout(gctx.device, system.cull_layout, nil)
    vk.DestroyPipeline(gctx.device, system.cull_pipeline, nil)
    vk.DestroyPipelineLayout(gctx.device, system.sphere_cull_layout, nil)
    vk.DestroyPipeline(gctx.device, system.sphere_cull_pipeline, nil)
  }
  create_depth_pipeline(system, gctx, rm) or_return
  defer if ret != .SUCCESS {
    vk.DestroyPipeline(gctx.device, system.depth_pipeline, nil)
  }
  create_spherical_depth_pipeline(system, gctx, rm) or_return
  defer if ret != .SUCCESS {
    vk.DestroyPipeline(gctx.device, system.spherical_depth_pipeline, nil)
  }
  return .SUCCESS
}

visibility_system_shutdown :: proc(
  system: ^VisibilitySystem,
  gctx: ^gpu.GPUContext,
  rm: ^resources.Manager,
) {
  vk.DestroyPipeline(gctx.device, system.sphere_cull_pipeline, nil)
  vk.DestroyPipeline(gctx.device, system.cull_pipeline, nil)
  vk.DestroyPipeline(gctx.device, system.depth_reduce_pipeline, nil)
  vk.DestroyPipeline(gctx.device, system.depth_pipeline, nil)
  vk.DestroyPipeline(gctx.device, system.spherical_depth_pipeline, nil)
  vk.DestroyPipelineLayout(gctx.device, system.sphere_cull_layout, nil)
  vk.DestroyPipelineLayout(gctx.device, system.cull_layout, nil)
  vk.DestroyPipelineLayout(gctx.device, system.depth_reduce_layout, nil)
}

visibility_system_set_node_count :: proc(
  system: ^VisibilitySystem,
  count: u32,
) {
  system.node_count = min(count, system.max_draws)
}

visibility_system_get_stats :: proc(
  system: ^VisibilitySystem,
  camera: ^resources.Camera,
  camera_index: u32,
  frame_index: u32,
) -> CullingStats {
  stats := CullingStats {
    camera_index = camera_index,
    frame_index  = frame_index,
  }
  if camera.late_draw_count[frame_index].mapped != nil {
    stats.late_draw_count = camera.late_draw_count[frame_index].mapped[0]
  }
  return stats
}

// STEP 2: Render depth - reads draw list, writes depth[N]
visibility_system_dispatch_depth :: proc(
  system: ^VisibilitySystem,
  gctx: ^gpu.GPUContext,
  command_buffer: vk.CommandBuffer,
  camera: ^resources.Camera,
  camera_index: u32,
  frame_index: u32,
  include_flags: resources.NodeFlagSet,
  exclude_flags: resources.NodeFlagSet,
  rm: ^resources.Manager,
) {
  if system.node_count == 0 {
    return
  }
  depth_texture := cont.get(
    rm.images_2d,
    camera.attachments[.DEPTH][frame_index],
  )
  render_depth_pass(
    system,
    gctx,
    command_buffer,
    camera,
    camera_index,
    frame_index,
    rm,
    include_flags,
    exclude_flags,
  )
}

// STEP 3: Build pyramid - reads depth[N-1], builds pyramid[N]
visibility_system_dispatch_pyramid :: proc(
  system: ^VisibilitySystem,
  gctx: ^gpu.GPUContext,
  command_buffer: vk.CommandBuffer,
  camera: ^resources.Camera,
  camera_index: u32,
  target_frame_index: u32, // Which pyramid to write to
  rm: ^resources.Manager,
) {
  if system.node_count == 0 {
    return
  }
  // Build pyramid[target] from depth[target-1]
  // This allows async compute to build pyramid[N] from depth[N-1] while graphics renders depth[N]
  build_depth_pyramid(system, gctx, command_buffer, camera, target_frame_index)
  if system.stats_enabled {
    log_culling_stats(system, camera, camera_index, target_frame_index)
  }
}

// Frame N compute writes to buffer[N], while frame N graphics reads buffer[N-1]
// Uses multi_pass pipeline but only late_draw_count/commands are used
visibility_system_dispatch_culling :: proc(
  system: ^VisibilitySystem,
  gctx: ^gpu.GPUContext,
  command_buffer: vk.CommandBuffer,
  camera: ^resources.Camera,
  camera_index: u32,
  target_frame_index: u32,
  include_flags: resources.NodeFlagSet,
  exclude_flags: resources.NodeFlagSet,
  rm: ^resources.Manager,
) {
  if system.node_count == 0 {
    return
  }
  // Clear all draw count buffers (multi_pass writes to all 3)
  vk.CmdFillBuffer(
    command_buffer,
    camera.late_draw_count[target_frame_index].buffer,
    0,
    vk.DeviceSize(camera.late_draw_count[target_frame_index].bytes_count),
    0,
  )
  vk.CmdFillBuffer(
    command_buffer,
    camera.transparent_draw_count[target_frame_index].buffer,
    0,
    vk.DeviceSize(camera.transparent_draw_count[target_frame_index].bytes_count),
    0,
  )
  vk.CmdFillBuffer(
    command_buffer,
    camera.sprite_draw_count[target_frame_index].buffer,
    0,
    vk.DeviceSize(camera.sprite_draw_count[target_frame_index].bytes_count),
    0,
  )
  gpu.bind_compute_pipeline(
    command_buffer,
    system.cull_pipeline,
    system.cull_layout,
    camera.descriptor_set[target_frame_index],
  )
  prev_frame :=
    (target_frame_index + resources.MAX_FRAMES_IN_FLIGHT - 1) %
    resources.MAX_FRAMES_IN_FLIGHT
  push_constants := VisibilityPushConstants {
    camera_index      = camera_index,
    node_count        = system.node_count,
    max_draws         = system.max_draws,
    include_flags     = include_flags,
    exclude_flags     = exclude_flags,
    pyramid_width     = f32(camera.depth_pyramid[prev_frame].width),
    pyramid_height    = f32(camera.depth_pyramid[prev_frame].height),
    depth_bias        = system.depth_bias,
    occlusion_enabled = 1,
  }
  vk.CmdPushConstants(
    command_buffer,
    system.cull_layout,
    {.COMPUTE},
    0,
    size_of(push_constants),
    &push_constants,
  )
  dispatch_x := (system.node_count + 63) / 64
  vk.CmdDispatch(command_buffer, dispatch_x, 1, 1)
}

// SphericalCamera visibility dispatch - culling + depth cube rendering
visibility_system_dispatch_spherical :: proc(
  system: ^VisibilitySystem,
  gctx: ^gpu.GPUContext,
  command_buffer: vk.CommandBuffer,
  camera: ^resources.SphericalCamera,
  camera_index: u32,
  frame_index: u32,
  include_flags: resources.NodeFlagSet,
  exclude_flags: resources.NodeFlagSet,
  rm: ^resources.Manager,
) {
  if system.node_count == 0 {
    return
  }
  // STEP 1: Clear draw count and execute sphere culling
  vk.CmdFillBuffer(
    command_buffer,
    camera.draw_count.buffer,
    0,
    vk.DeviceSize(camera.draw_count.bytes_count),
    0,
  )
  gpu.bind_compute_pipeline(
    command_buffer,
    system.sphere_cull_pipeline,
    system.sphere_cull_layout,
    camera.descriptor_sets[frame_index],
  )
  push_constants := VisibilityPushConstants {
    camera_index      = camera_index,
    node_count        = system.node_count,
    max_draws         = system.max_draws,
    include_flags     = include_flags,
    exclude_flags     = exclude_flags,
    pyramid_width     = 0,
    pyramid_height    = 0,
    depth_bias        = 0,
    occlusion_enabled = 0,
  }
  vk.CmdPushConstants(
    command_buffer,
    system.sphere_cull_layout,
    {.COMPUTE},
    0,
    size_of(push_constants),
    &push_constants,
  )
  dispatch_x := (system.node_count + 63) / 64
  vk.CmdDispatch(command_buffer, dispatch_x, 1, 1)
  // STEP 2: Barrier - Wait for compute to finish before reading draw commands
  gpu.buffer_barrier(
    command_buffer,
    camera.draw_commands.buffer,
    vk.DeviceSize(camera.draw_commands.bytes_count),
    {.SHADER_WRITE},
    {.INDIRECT_COMMAND_READ},
    {.COMPUTE_SHADER},
    {.DRAW_INDIRECT},
  )
  gpu.buffer_barrier(
    command_buffer,
    camera.draw_count.buffer,
    vk.DeviceSize(camera.draw_count.bytes_count),
    {.SHADER_WRITE},
    {.INDIRECT_COMMAND_READ},
    {.COMPUTE_SHADER},
    {.DRAW_INDIRECT},
  )
  // STEP 3: Render depth to cube map
  render_spherical_depth_pass(
    system,
    gctx,
    command_buffer,
    camera,
    camera_index,
    frame_index,
    rm,
  )
}

@(private)
create_descriptor_layouts :: proc(
  system: ^VisibilitySystem,
  gctx: ^gpu.GPUContext,
  rm: ^resources.Manager,
) -> vk.Result {
  rm.visibility_sphere_descriptor_layout = gpu.create_descriptor_set_layout(
    gctx,
    {.STORAGE_BUFFER, {.COMPUTE}},
    {.STORAGE_BUFFER, {.COMPUTE}},
    {.STORAGE_BUFFER, {.COMPUTE}},
    {.STORAGE_BUFFER, {.COMPUTE}},
    {.STORAGE_BUFFER, {.COMPUTE}},
    {.STORAGE_BUFFER, {.COMPUTE}},
  ) or_return
  rm.visibility_descriptor_layout = gpu.create_descriptor_set_layout(
    gctx,
    {.STORAGE_BUFFER, {.COMPUTE}}, // node data
    {.STORAGE_BUFFER, {.COMPUTE}}, // mesh data
    {.STORAGE_BUFFER, {.COMPUTE}}, // world matrices
    {.STORAGE_BUFFER, {.COMPUTE}}, // camera data
    {.STORAGE_BUFFER, {.COMPUTE}}, // late draw count
    {.STORAGE_BUFFER, {.COMPUTE}}, // late draw commands
    {.STORAGE_BUFFER, {.COMPUTE}}, // transparent draw count
    {.STORAGE_BUFFER, {.COMPUTE}}, // transparent draw commands
    {.STORAGE_BUFFER, {.COMPUTE}}, // sprite draw count
    {.STORAGE_BUFFER, {.COMPUTE}}, // sprite draw commands
    {.COMBINED_IMAGE_SAMPLER, {.COMPUTE}}, // depth pyramid
  ) or_return
  rm.visibility_depth_reduce_descriptor_layout =
    gpu.create_descriptor_set_layout(
      gctx,
      {.COMBINED_IMAGE_SAMPLER, {.COMPUTE}}, // source mip
      {.STORAGE_IMAGE, {.COMPUTE}}, // dest mip
    ) or_return
  return .SUCCESS
}

@(private)
create_compute_pipelines :: proc(
  self: ^VisibilitySystem,
  gctx: ^gpu.GPUContext,
  rm: ^resources.Manager,
) -> vk.Result {
  self.sphere_cull_layout = gpu.create_pipeline_layout(
    gctx,
    vk.PushConstantRange {
      stageFlags = {.COMPUTE},
      size = size_of(VisibilityPushConstants),
    },
    rm.visibility_sphere_descriptor_layout,
  ) or_return
  self.cull_layout = gpu.create_pipeline_layout(
    gctx,
    vk.PushConstantRange {
      stageFlags = {.COMPUTE},
      size = size_of(VisibilityPushConstants),
    },
    rm.visibility_descriptor_layout,
  ) or_return
  self.depth_reduce_layout = gpu.create_pipeline_layout(
    gctx,
    vk.PushConstantRange {
      stageFlags = {.COMPUTE},
      size = size_of(DepthReducePushConstants),
    },
    rm.visibility_depth_reduce_descriptor_layout,
  ) or_return
  sphere_shader := gpu.create_shader_module(
    gctx.device,
    SHADER_SPHERECAM_CULLING,
  ) or_return
  defer vk.DestroyShaderModule(gctx.device, sphere_shader, nil)
  shader := gpu.create_shader_module(gctx.device, SHADER_CULLING) or_return
  defer vk.DestroyShaderModule(gctx.device, shader, nil)
  depth_shader := gpu.create_shader_module(
    gctx.device,
    SHADER_DEPTH_REDUCE,
  ) or_return
  defer vk.DestroyShaderModule(gctx.device, depth_shader, nil)
  self.sphere_cull_pipeline = gpu.create_compute_pipeline(
    gctx,
    sphere_shader,
    self.sphere_cull_layout,
  ) or_return
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
  system: ^VisibilitySystem,
  gctx: ^gpu.GPUContext,
  rm: ^resources.Manager,
) -> vk.Result {
  vert_shader := gpu.create_shader_module(
    gctx.device,
    SHADER_DEPTH_VERT,
  ) or_return
  defer vk.DestroyShaderModule(gctx.device, vert_shader, nil)
  shader_stages := [?]vk.PipelineShaderStageCreateInfo {
    {
      sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
      stage = {.VERTEX},
      module = vert_shader,
      pName = "main",
    },
  }
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
  input_assembly := vk.PipelineInputAssemblyStateCreateInfo {
    sType                  = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
    topology               = .TRIANGLE_LIST,
    primitiveRestartEnable = false,
  }
  viewport_state := vk.PipelineViewportStateCreateInfo {
    sType         = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
    viewportCount = 1,
    scissorCount  = 1,
  }
  // Note: Using CLOCKWISE because viewport Y is flipped (negative height)
  // When Y is flipped, CCW triangles become CW on screen
  rasterizer := vk.PipelineRasterizationStateCreateInfo {
    sType                   = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
    depthClampEnable        = false,
    rasterizerDiscardEnable = false,
    polygonMode             = .FILL,
    cullMode                = {.BACK},
    frontFace               = .COUNTER_CLOCKWISE,
    depthBiasEnable         = false,
    lineWidth               = 1.0,
  }
  multisampling := vk.PipelineMultisampleStateCreateInfo {
    sType                = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
    rasterizationSamples = {._1},
    sampleShadingEnable  = false,
  }
  depth_stencil := vk.PipelineDepthStencilStateCreateInfo {
    sType                 = .PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
    depthTestEnable       = true,
    depthWriteEnable      = true,
    depthCompareOp        = .LESS,
    depthBoundsTestEnable = false,
    stencilTestEnable     = false,
  }
  color_blend := vk.PipelineColorBlendStateCreateInfo {
    sType           = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
    logicOpEnable   = false,
    attachmentCount = 0,
    pAttachments    = nil,
  }
  dynamic_states := [?]vk.DynamicState{.VIEWPORT, .SCISSOR}
  dynamic_state := vk.PipelineDynamicStateCreateInfo {
    sType             = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
    dynamicStateCount = len(dynamic_states),
    pDynamicStates    = raw_data(dynamic_states[:]),
  }
  if rm.geometry_pipeline_layout == 0 {
    return .ERROR_INITIALIZATION_FAILED
  }
  depth_dynamic_rendering := vk.PipelineRenderingCreateInfo {
    sType                 = .PIPELINE_RENDERING_CREATE_INFO,
    depthAttachmentFormat = .D32_SFLOAT,
  }
  pipeline_info := vk.GraphicsPipelineCreateInfo {
    sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
    pNext               = &depth_dynamic_rendering,
    stageCount          = len(shader_stages),
    pStages             = raw_data(shader_stages[:]),
    pVertexInputState   = &vertex_input_info,
    pInputAssemblyState = &input_assembly,
    pViewportState      = &viewport_state,
    pRasterizationState = &rasterizer,
    pMultisampleState   = &multisampling,
    pDepthStencilState  = &depth_stencil,
    pColorBlendState    = &color_blend,
    pDynamicState       = &dynamic_state,
    layout              = rm.geometry_pipeline_layout,
  }
  vk.CreateGraphicsPipelines(
    gctx.device,
    0,
    1,
    &pipeline_info,
    nil,
    &system.depth_pipeline,
  ) or_return
  return .SUCCESS
}

@(private)
create_spherical_depth_pipeline :: proc(
  system: ^VisibilitySystem,
  gctx: ^gpu.GPUContext,
  rm: ^resources.Manager,
) -> vk.Result {
  // create depth rendering pipeline for spherical cameras (point light shadows)
  // uses geometry shader to render to all 6 cube faces in one pass
  vert_shader := gpu.create_shader_module(
    gctx.device,
    SHADER_SPHERECAM_DEPTH_VERT,
  ) or_return
  defer vk.DestroyShaderModule(gctx.device, vert_shader, nil)
  geom_shader := gpu.create_shader_module(
    gctx.device,
    SHADER_SPHERECAM_DEPTH_GEOM,
  ) or_return
  defer vk.DestroyShaderModule(gctx.device, geom_shader, nil)
  frag_shader := gpu.create_shader_module(
    gctx.device,
    SHADER_SPHERECAM_DEPTH_FRAG,
  ) or_return
  defer vk.DestroyShaderModule(gctx.device, frag_shader, nil)
  shader_stages := [?]vk.PipelineShaderStageCreateInfo {
    {
      sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
      stage = {.VERTEX},
      module = vert_shader,
      pName = "main",
    },
    {
      sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
      stage = {.GEOMETRY},
      module = geom_shader,
      pName = "main",
    },
    {
      sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
      stage = {.FRAGMENT},
      module = frag_shader,
      pName = "main",
    },
  }
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
  input_assembly := vk.PipelineInputAssemblyStateCreateInfo {
    sType                  = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
    topology               = .TRIANGLE_LIST,
    primitiveRestartEnable = false,
  }
  viewport_state := vk.PipelineViewportStateCreateInfo {
    sType         = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
    viewportCount = 1,
    scissorCount  = 1,
  }
  rasterizer := vk.PipelineRasterizationStateCreateInfo {
    sType                   = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
    depthClampEnable        = false,
    rasterizerDiscardEnable = false,
    polygonMode             = .FILL,
    cullMode                = {.BACK},
    frontFace               = .COUNTER_CLOCKWISE,
    depthBiasEnable         = false,
    lineWidth               = 1.0,
  }
  multisampling := vk.PipelineMultisampleStateCreateInfo {
    sType                = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
    rasterizationSamples = {._1},
    sampleShadingEnable  = false,
  }
  depth_stencil := vk.PipelineDepthStencilStateCreateInfo {
    sType                 = .PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
    depthTestEnable       = true,
    depthWriteEnable      = true,
    depthCompareOp        = .LESS,
    depthBoundsTestEnable = false,
    stencilTestEnable     = false,
  }
  color_blend := vk.PipelineColorBlendStateCreateInfo {
    sType           = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
    logicOpEnable   = false,
    attachmentCount = 0,
    pAttachments    = nil,
  }
  dynamic_states := [?]vk.DynamicState{.VIEWPORT, .SCISSOR}
  dynamic_state := vk.PipelineDynamicStateCreateInfo {
    sType             = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
    dynamicStateCount = len(dynamic_states),
    pDynamicStates    = raw_data(dynamic_states[:]),
  }
  if rm.spherical_camera_pipeline_layout == 0 {
    return .ERROR_INITIALIZATION_FAILED
  }
  depth_dynamic_rendering := vk.PipelineRenderingCreateInfo {
    sType                 = .PIPELINE_RENDERING_CREATE_INFO,
    depthAttachmentFormat = .D32_SFLOAT,
    viewMask              = 0, // Not using multiview, geometry shader handles cube faces
  }
  pipeline_info := vk.GraphicsPipelineCreateInfo {
    sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
    pNext               = &depth_dynamic_rendering,
    stageCount          = len(shader_stages),
    pStages             = raw_data(shader_stages[:]),
    pVertexInputState   = &vertex_input_info,
    pInputAssemblyState = &input_assembly,
    pViewportState      = &viewport_state,
    pRasterizationState = &rasterizer,
    pMultisampleState   = &multisampling,
    pDepthStencilState  = &depth_stencil,
    pColorBlendState    = &color_blend,
    pDynamicState       = &dynamic_state,
    layout              = rm.spherical_camera_pipeline_layout,
  }
  vk.CreateGraphicsPipelines(
    gctx.device,
    0,
    1,
    &pipeline_info,
    nil,
    &system.spherical_depth_pipeline,
  ) or_return
  return .SUCCESS
}

@(private)
render_depth_pass :: proc(
  system: ^VisibilitySystem,
  gctx: ^gpu.GPUContext,
  command_buffer: vk.CommandBuffer,
  camera: ^resources.Camera,
  camera_index: u32,
  frame_index: u32,
  rm: ^resources.Manager,
  include_flags: resources.NodeFlagSet,
  exclude_flags: resources.NodeFlagSet,
) {
  depth_texture := cont.get(
    rm.images_2d,
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
    camera.extent.width,
    camera.extent.height,
    &depth_attachment,
  )
  gpu.set_viewport_scissor(command_buffer, camera.extent.width, camera.extent.height)
  if system.depth_pipeline != 0 {
    gpu.bind_graphics_pipeline(
      command_buffer,
      system.depth_pipeline,
      rm.geometry_pipeline_layout,
      rm.camera_buffer_descriptor_sets[frame_index], // Per-frame to avoid overlap
      rm.textures_descriptor_set,
      rm.bone_buffer_descriptor_set,
      rm.material_buffer_descriptor_set,
      rm.world_matrix_descriptor_set,
      rm.node_data_descriptor_set,
      rm.mesh_data_descriptor_set,
      rm.vertex_skinning_descriptor_set,
    )
    camera_index := camera_index
    vk.CmdPushConstants(
      command_buffer,
      rm.geometry_pipeline_layout,
      {.VERTEX, .FRAGMENT},
      0,
      size_of(u32),
      &camera_index,
    )
    gpu.bind_vertex_index_buffers(
      command_buffer,
      rm.vertex_buffer.buffer,
      rm.index_buffer.buffer,
    )
    // Use current frame's draw list (prepared by frame N-1 compute)
    // draw_list[frame_index] was written by Compute N-1, safe to read during Render N
    vk.CmdDrawIndexedIndirectCount(
      command_buffer,
      camera.late_draw_commands[frame_index].buffer,
      0, // offset
      camera.late_draw_count[frame_index].buffer,
      0, // count offset
      system.max_draws,
      u32(size_of(vk.DrawIndexedIndirectCommand)),
    )
  }
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

@(private)
build_depth_pyramid :: proc(
  system: ^VisibilitySystem,
  gctx: ^gpu.GPUContext,
  command_buffer: vk.CommandBuffer,
  camera: ^resources.Camera,
  target_frame_index: u32, // Frame N builds pyramid[N] from depth[N-1] (via descriptors)
) {
  vk.CmdBindPipeline(command_buffer, .COMPUTE, system.depth_reduce_pipeline)
  // Generate ALL mip levels using the same shader
  // Mip 0: reads from depth[N-1] (configured in descriptor sets)
  // Other mips: read from pyramid[N] mip-1
  for mip in 0 ..< camera.depth_pyramid[target_frame_index].mip_levels {
    vk.CmdBindDescriptorSets(
      command_buffer,
      .COMPUTE,
      system.depth_reduce_layout,
      0,
      1,
      &camera.depth_reduce_descriptor_sets[target_frame_index][mip],
      0,
      nil,
    )
    push_constants := DepthReducePushConstants {
      current_mip = u32(mip),
    }
    vk.CmdPushConstants(
      command_buffer,
      system.depth_reduce_layout,
      {.COMPUTE},
      0,
      size_of(push_constants),
      &push_constants,
    )
    mip_width := max(1, camera.depth_pyramid[target_frame_index].width >> mip)
    mip_height := max(
      1,
      camera.depth_pyramid[target_frame_index].height >> mip,
    )
    dispatch_x := (mip_width + 31) / 32
    dispatch_y := (mip_height + 31) / 32
    vk.CmdDispatch(command_buffer, dispatch_x, dispatch_y, 1)
    // only synchronize the dependency chain, don't transition layouts
    if mip < camera.depth_pyramid[target_frame_index].mip_levels - 1 {
      gpu.memory_barrier(
        command_buffer,
        {.SHADER_WRITE},
        {.SHADER_READ},
        {.COMPUTE_SHADER},
        {.COMPUTE_SHADER},
      )
    }
  }
}

@(private)
log_culling_stats :: proc(
  system: ^VisibilitySystem,
  camera: ^resources.Camera,
  camera_index: u32,
  frame_index: u32,
) {
  late_count: u32 = 0
  if camera.late_draw_count[frame_index].mapped != nil {
    late_count = camera.late_draw_count[frame_index].mapped[0]
  }
  efficiency: f32 = 0.0
  if system.node_count > 0 {
    efficiency = f32(late_count) / f32(system.node_count) * 100.0
  }
  log.infof(
    "[Camera %d Frame %d] Culling Stats: Total Objects=%d | Late Pass=%d | Efficiency=%.1f%%",
    camera_index,
    frame_index,
    system.node_count,
    late_count,
    efficiency,
  )
}

@(private)
render_spherical_depth_pass :: proc(
  system: ^VisibilitySystem,
  gctx: ^gpu.GPUContext,
  command_buffer: vk.CommandBuffer,
  camera: ^resources.SphericalCamera,
  camera_index: u32,
  frame_index: u32,
  rm: ^resources.Manager,
) {
  // Frame N writes to depth_cube[N]
  depth_cube := cont.get(rm.images_cube, camera.depth_cube[frame_index])
  if depth_cube == nil {
    log.error("Failed to get depth cube for spherical camera")
    return
  }
  // Layout transition before rendering shadow depth
  gpu.image_barrier(
    command_buffer,
    depth_cube.image,
    .UNDEFINED,
    .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
    {},
    {.DEPTH_STENCIL_ATTACHMENT_WRITE},
    {.TOP_OF_PIPE},
    {.EARLY_FRAGMENT_TESTS},
    {.DEPTH},
    layer_count = 6,
  )
  depth_attachment := gpu.create_cube_depth_attachment(
    depth_cube,
    .CLEAR,
    .STORE,
  )
  // the geometry shader will emit primitives to each face using gl_Layer
  gpu.begin_depth_rendering(
    command_buffer,
    camera.size,
    camera.size,
    &depth_attachment,
    layer_count = 6,
  )
  gpu.set_viewport_scissor(command_buffer, camera.size, camera.size)
  if system.spherical_depth_pipeline != 0 {
    gpu.bind_graphics_pipeline(
      command_buffer,
      system.spherical_depth_pipeline,
      rm.spherical_camera_pipeline_layout,
      rm.spherical_camera_buffer_descriptor_sets[frame_index], // Per-frame to avoid overlap
      rm.textures_descriptor_set,
      rm.bone_buffer_descriptor_set,
      rm.material_buffer_descriptor_set,
      rm.world_matrix_descriptor_set,
      rm.node_data_descriptor_set,
      rm.mesh_data_descriptor_set,
      rm.vertex_skinning_descriptor_set,
    )
    cam_idx := camera_index
    vk.CmdPushConstants(
      command_buffer,
      rm.spherical_camera_pipeline_layout,
      {.VERTEX, .GEOMETRY, .FRAGMENT},
      0,
      size_of(u32),
      &cam_idx,
    )
    gpu.bind_vertex_index_buffers(
      command_buffer,
      rm.vertex_buffer.buffer,
      rm.index_buffer.buffer,
    )
    vk.CmdDrawIndexedIndirectCount(
      command_buffer,
      camera.draw_commands.buffer,
      0, // offset
      camera.draw_count.buffer,
      0, // count offset
      system.max_draws,
      u32(size_of(vk.DrawIndexedIndirectCommand)),
    )
  }
  vk.CmdEndRendering(command_buffer)
  // Barrier: depth cube writes complete, transition for fragment shader reads
  // Lighting samples this cube map for point light shadows
  gpu.image_barrier(
    command_buffer,
    depth_cube.image,
    .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
    .DEPTH_STENCIL_READ_ONLY_OPTIMAL,
    {.DEPTH_STENCIL_ATTACHMENT_WRITE},
    {.SHADER_READ},
    {.LATE_FRAGMENT_TESTS},
    {.FRAGMENT_SHADER},
    {.DEPTH},
    layer_count = 6,
  )
}

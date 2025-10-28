package world

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
  late_cull_pipeline:       vk.Pipeline,
  sphere_cull_pipeline:     vk.Pipeline, // For SphericalCamera (radius-based culling)
  depth_reduce_pipeline:    vk.Pipeline,
  late_cull_layout:         vk.PipelineLayout,
  sphere_cull_layout:       vk.PipelineLayout,
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

draw_command_stride :: proc() -> u32 {
  return u32(size_of(vk.DrawIndexedIndirectCommand))
}

visibility_system_init :: proc(
  system: ^VisibilitySystem,
  gctx: ^gpu.GPUContext,
  rm: ^resources.Manager,
  depth_width: u32,
  depth_height: u32,
) -> vk.Result {
  system.max_draws = resources.MAX_NODES_IN_SCENE
  system.depth_width = depth_width
  system.depth_height = depth_height
  system.depth_bias = 0.0001
  create_descriptor_layouts(system, gctx, rm) or_return
  create_compute_pipelines(system, gctx, rm) or_return
  create_depth_pipeline(system, gctx, rm) or_return
  create_spherical_depth_pipeline(system, gctx, rm) or_return
  return vk.Result.SUCCESS
}

visibility_system_shutdown :: proc(
  system: ^VisibilitySystem,
  gctx: ^gpu.GPUContext,
  rm: ^resources.Manager,
) {
  vk.DestroyPipeline(gctx.device, system.late_cull_pipeline, nil)
  vk.DestroyPipeline(gctx.device, system.sphere_cull_pipeline, nil)
  vk.DestroyPipeline(gctx.device, system.depth_reduce_pipeline, nil)
  vk.DestroyPipeline(gctx.device, system.depth_pipeline, nil)
  vk.DestroyPipeline(gctx.device, system.spherical_depth_pipeline, nil)
  vk.DestroyPipelineLayout(gctx.device, system.late_cull_layout, nil)
  vk.DestroyPipelineLayout(gctx.device, system.sphere_cull_layout, nil)
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

visibility_system_set_stats_enabled :: proc(
  system: ^VisibilitySystem,
  enabled: bool,
) {
  system.stats_enabled = enabled
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
  depth_texture := resources.get(
    rm.image_2d_buffers,
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
  build_depth_pyramid(system, gctx, command_buffer, camera, target_frame_index, rm)
  if system.stats_enabled {
    log_culling_stats(system, camera, camera_index, target_frame_index)
  }
}

// Frame N compute writes to buffer[N%2], while frame N graphics reads buffer[(N-1)%2]
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
  // write to target_frame buffer, read from (target_frame-1) pyramid
  vk.CmdFillBuffer(
    command_buffer,
    camera.late_draw_count[target_frame_index].buffer,
    0,
    vk.DeviceSize(camera.late_draw_count[target_frame_index].bytes_count),
    0,
  )
  vk.CmdBindPipeline(command_buffer, .COMPUTE, system.late_cull_pipeline)
  vk.CmdBindDescriptorSets(
    command_buffer,
    .COMPUTE,
    system.late_cull_layout,
    0,
    1,
    &camera.late_descriptor_set[target_frame_index],
    0,
    nil,
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
    system.late_cull_layout,
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
  vk.CmdBindPipeline(command_buffer, .COMPUTE, system.sphere_cull_pipeline)
  vk.CmdBindDescriptorSets(
    command_buffer,
    .COMPUTE,
    system.sphere_cull_layout,
    0,
    1,
    &camera.descriptor_set,
    0,
    nil,
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
  compute_done := [?]vk.BufferMemoryBarrier {
    {
      sType = .BUFFER_MEMORY_BARRIER,
      srcAccessMask = {.SHADER_WRITE},
      dstAccessMask = {.INDIRECT_COMMAND_READ},
      buffer = camera.draw_commands.buffer,
      size = vk.DeviceSize(camera.draw_commands.bytes_count),
    },
    {
      sType = .BUFFER_MEMORY_BARRIER,
      srcAccessMask = {.SHADER_WRITE},
      dstAccessMask = {.INDIRECT_COMMAND_READ},
      buffer = camera.draw_count.buffer,
      size = vk.DeviceSize(camera.draw_count.bytes_count),
    },
  }
  vk.CmdPipelineBarrier(
    command_buffer,
    {.COMPUTE_SHADER},
    {.DRAW_INDIRECT},
    {},
    0,
    nil,
    len(compute_done),
    raw_data(compute_done[:]),
    0,
    nil,
  )
  // STEP 3: Render depth to cube map
  render_spherical_depth_pass(
    system,
    gctx,
    command_buffer,
    camera,
    camera_index,
    rm,
  )
}

@(private)
create_descriptor_layouts :: proc(
  system: ^VisibilitySystem,
  gctx: ^gpu.GPUContext,
  rm: ^resources.Manager,
) -> vk.Result {
  late_bindings := [?]vk.DescriptorSetLayoutBinding {
    {
      binding = 0,
      descriptorType = .STORAGE_BUFFER,
      descriptorCount = 1,
      stageFlags = {.COMPUTE},
    }, // node data
    {
      binding = 1,
      descriptorType = .STORAGE_BUFFER,
      descriptorCount = 1,
      stageFlags = {.COMPUTE},
    }, // mesh data
    {
      binding = 2,
      descriptorType = .STORAGE_BUFFER,
      descriptorCount = 1,
      stageFlags = {.COMPUTE},
    }, // world matrices
    {
      binding = 3,
      descriptorType = .STORAGE_BUFFER,
      descriptorCount = 1,
      stageFlags = {.COMPUTE},
    }, // camera data
    {
      binding = 4,
      descriptorType = .STORAGE_BUFFER,
      descriptorCount = 1,
      stageFlags = {.COMPUTE},
    }, // draw count
    {
      binding = 5,
      descriptorType = .STORAGE_BUFFER,
      descriptorCount = 1,
      stageFlags = {.COMPUTE},
    }, // draw commands
    {
      binding = 6,
      descriptorType = .COMBINED_IMAGE_SAMPLER,
      descriptorCount = 1,
      stageFlags = {.COMPUTE},
    }, // depth pyramid
  }
  vk.CreateDescriptorSetLayout(
    gctx.device,
    &vk.DescriptorSetLayoutCreateInfo {
      sType = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
      bindingCount = len(late_bindings),
      pBindings = raw_data(late_bindings[:]),
    },
    nil,
    &rm.visibility_late_descriptor_layout,
  ) or_return
  // Sphere pass descriptor layout (matches sphere_cull.comp shader)
  // NOTE: Binding 4 is intentionally skipped to maintain compatibility
  sphere_bindings := [?]vk.DescriptorSetLayoutBinding {
    {
      binding = 0,
      descriptorType = .STORAGE_BUFFER,
      descriptorCount = 1,
      stageFlags = {.COMPUTE},
    },
    {
      binding = 1,
      descriptorType = .STORAGE_BUFFER,
      descriptorCount = 1,
      stageFlags = {.COMPUTE},
    },
    {
      binding = 2,
      descriptorType = .STORAGE_BUFFER,
      descriptorCount = 1,
      stageFlags = {.COMPUTE},
    },
    {
      binding = 3,
      descriptorType = .STORAGE_BUFFER,
      descriptorCount = 1,
      stageFlags = {.COMPUTE},
    },
    {
      binding = 5,
      descriptorType = .STORAGE_BUFFER,
      descriptorCount = 1,
      stageFlags = {.COMPUTE},
    },
    {
      binding = 6,
      descriptorType = .STORAGE_BUFFER,
      descriptorCount = 1,
      stageFlags = {.COMPUTE},
    },
  }
  vk.CreateDescriptorSetLayout(
    gctx.device,
    &vk.DescriptorSetLayoutCreateInfo {
      sType = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
      bindingCount = len(sphere_bindings),
      pBindings = raw_data(sphere_bindings[:]),
    },
    nil,
    &rm.visibility_sphere_descriptor_layout,
  ) or_return
  depth_bindings := [?]vk.DescriptorSetLayoutBinding {
    {
      binding = 0,
      descriptorType = .COMBINED_IMAGE_SAMPLER,
      descriptorCount = 1,
      stageFlags = {.COMPUTE},
    }, // source mip
    {
      binding = 1,
      descriptorType = .STORAGE_IMAGE,
      descriptorCount = 1,
      stageFlags = {.COMPUTE},
    }, // dest mip
  }
  vk.CreateDescriptorSetLayout(
    gctx.device,
    &vk.DescriptorSetLayoutCreateInfo {
      sType = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
      bindingCount = len(depth_bindings),
      pBindings = raw_data(depth_bindings[:]),
    },
    nil,
    &rm.visibility_depth_reduce_descriptor_layout,
  ) or_return
  return vk.Result.SUCCESS
}

@(private)
create_compute_pipelines :: proc(
  system: ^VisibilitySystem,
  gctx: ^gpu.GPUContext,
  rm: ^resources.Manager,
) -> vk.Result {
  push_constant_range := vk.PushConstantRange {
    stageFlags = {.COMPUTE},
    size       = size_of(VisibilityPushConstants),
  }
  vk.CreatePipelineLayout(
    gctx.device,
    &vk.PipelineLayoutCreateInfo {
      sType = .PIPELINE_LAYOUT_CREATE_INFO,
      setLayoutCount = 1,
      pSetLayouts = &rm.visibility_late_descriptor_layout,
      pushConstantRangeCount = 1,
      pPushConstantRanges = &push_constant_range,
    },
    nil,
    &system.late_cull_layout,
  ) or_return
  vk.CreatePipelineLayout(
    gctx.device,
    &vk.PipelineLayoutCreateInfo {
      sType = .PIPELINE_LAYOUT_CREATE_INFO,
      setLayoutCount = 1,
      pSetLayouts = &rm.visibility_sphere_descriptor_layout,
      pushConstantRangeCount = 1,
      pPushConstantRanges = &push_constant_range,
    },
    nil,
    &system.sphere_cull_layout,
  ) or_return
  depth_push_range := vk.PushConstantRange {
    stageFlags = {.COMPUTE},
    size       = size_of(DepthReducePushConstants),
  }
  vk.CreatePipelineLayout(
    gctx.device,
    &vk.PipelineLayoutCreateInfo {
      sType = .PIPELINE_LAYOUT_CREATE_INFO,
      setLayoutCount = 1,
      pSetLayouts = &rm.visibility_depth_reduce_descriptor_layout,
      pushConstantRangeCount = 1,
      pPushConstantRanges = &depth_push_range,
    },
    nil,
    &system.depth_reduce_layout,
  ) or_return
  late_shader := gpu.create_shader_module(
    gctx.device,
    #load("../shader/occlusion_culling/late_cull.spv"),
  ) or_return
  defer vk.DestroyShaderModule(gctx.device, late_shader, nil)
  sphere_shader := gpu.create_shader_module(
    gctx.device,
    #load("../shader/occlusion_culling/sphere_cull.spv"),
  ) or_return
  defer vk.DestroyShaderModule(gctx.device, sphere_shader, nil)
  depth_shader := gpu.create_shader_module(
    gctx.device,
    #load("../shader/occlusion_culling/depth_reduce.spv"),
  ) or_return
  defer vk.DestroyShaderModule(gctx.device, depth_shader, nil)
  late_info := vk.ComputePipelineCreateInfo {
    sType = .COMPUTE_PIPELINE_CREATE_INFO,
    stage = {
      sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
      stage = {.COMPUTE},
      module = late_shader,
      pName = "main",
    },
    layout = system.late_cull_layout,
  }
  vk.CreateComputePipelines(
    gctx.device,
    0,
    1,
    &late_info,
    nil,
    &system.late_cull_pipeline,
  ) or_return
  sphere_info := vk.ComputePipelineCreateInfo {
    sType = .COMPUTE_PIPELINE_CREATE_INFO,
    stage = {
      sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
      stage = {.COMPUTE},
      module = sphere_shader,
      pName = "main",
    },
    layout = system.sphere_cull_layout,
  }
  vk.CreateComputePipelines(
    gctx.device,
    0,
    1,
    &sphere_info,
    nil,
    &system.sphere_cull_pipeline,
  ) or_return
  depth_info := vk.ComputePipelineCreateInfo {
    sType = .COMPUTE_PIPELINE_CREATE_INFO,
    stage = {
      sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
      stage = {.COMPUTE},
      module = depth_shader,
      pName = "main",
    },
    layout = system.depth_reduce_layout,
  }
  vk.CreateComputePipelines(
    gctx.device,
    0,
    1,
    &depth_info,
    nil,
    &system.depth_reduce_pipeline,
  ) or_return
  return vk.Result.SUCCESS
}

@(private)
create_depth_pipeline :: proc(
  system: ^VisibilitySystem,
  gctx: ^gpu.GPUContext,
  rm: ^resources.Manager,
) -> vk.Result {
  vert_shader := gpu.create_shader_module(
    gctx.device,
    #load("../shader/occlusion_culling/vert.spv"),
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
  return vk.Result.SUCCESS
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
    #load("../shader/shadow_spherical/vert.spv"),
  ) or_return
  defer vk.DestroyShaderModule(gctx.device, vert_shader, nil)
  geom_shader := gpu.create_shader_module(
    gctx.device,
    #load("../shader/shadow_spherical/geom.spv"),
  ) or_return
  defer vk.DestroyShaderModule(gctx.device, geom_shader, nil)
  frag_shader := gpu.create_shader_module(
    gctx.device,
    #load("../shader/shadow_spherical/frag.spv"),
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
  return vk.Result.SUCCESS
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
  depth_texture := resources.get(
    rm.image_2d_buffers,
    camera.attachments[.DEPTH][frame_index],
  )
  // Transition from READ_ONLY_OPTIMAL (left by previous frame's post-processing)
  // to ATTACHMENT_OPTIMAL (needed for clear and write)
  depth_ready_to_write := vk.ImageMemoryBarrier {
    sType = .IMAGE_MEMORY_BARRIER,
    srcAccessMask = {.SHADER_READ},
    dstAccessMask = {.DEPTH_STENCIL_ATTACHMENT_WRITE},
    oldLayout = .DEPTH_STENCIL_READ_ONLY_OPTIMAL,
    newLayout = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
    srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
    dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
    image = depth_texture.image,
    subresourceRange = {
      aspectMask = {.DEPTH},
      baseMipLevel = 0,
      levelCount = 1,
      baseArrayLayer = 0,
      layerCount = 1,
    },
  }
  vk.CmdPipelineBarrier(
    command_buffer,
    {.FRAGMENT_SHADER}, // previous frame's post-processing reads done
    {.EARLY_FRAGMENT_TESTS}, // this frame's depth writes start
    {},
    0,
    nil,
    0,
    nil,
    1,
    &depth_ready_to_write,
  )
  depth_attachment := vk.RenderingAttachmentInfo {
    sType = .RENDERING_ATTACHMENT_INFO,
    imageView = depth_texture.view,
    imageLayout = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
    loadOp = .CLEAR,
    storeOp = .STORE,
    clearValue = {depthStencil = {depth = 1.0, stencil = 0}},
  }
  render_info := vk.RenderingInfo {
    sType = .RENDERING_INFO,
    renderArea = {offset = {0, 0}, extent = camera.extent},
    layerCount = 1,
    pDepthAttachment = &depth_attachment,
  }
  vk.CmdBeginRendering(command_buffer, &render_info)
  // set viewport and scissor
  // use negative height to flip Y axis (Vulkan convention: +Y down, we want +Y up)
  viewport := vk.Viewport {
    x        = 0,
    y        = f32(camera.extent.height),
    width    = f32(camera.extent.width),
    height   = -f32(camera.extent.height),
    minDepth = 0.0,
    maxDepth = 1.0,
  }
  scissor := vk.Rect2D {
    offset = {0, 0},
    extent = camera.extent,
  }
  vk.CmdSetViewport(command_buffer, 0, 1, &viewport)
  vk.CmdSetScissor(command_buffer, 0, 1, &scissor)
  if system.depth_pipeline != 0 {
    vk.CmdBindPipeline(command_buffer, .GRAPHICS, system.depth_pipeline)
    descriptor_sets := [?]vk.DescriptorSet {
      rm.camera_buffer_descriptor_set,
      rm.textures_descriptor_set,
      rm.bone_buffer_descriptor_set,
      rm.material_buffer_descriptor_set,
      rm.world_matrix_descriptor_set,
      rm.node_data_descriptor_set,
      rm.mesh_data_descriptor_set,
      rm.vertex_skinning_descriptor_set,
    }
    vk.CmdBindDescriptorSets(
      command_buffer,
      .GRAPHICS,
      rm.geometry_pipeline_layout,
      0,
      len(descriptor_sets),
      raw_data(descriptor_sets[:]),
      0,
      nil,
    )
    camera_index := camera_index
    vk.CmdPushConstants(
      command_buffer,
      rm.geometry_pipeline_layout,
      {.VERTEX},
      0,
      size_of(u32),
      &camera_index,
    )
    vertex_buffers := [?]vk.Buffer{rm.vertex_buffer.buffer}
    offsets := [?]vk.DeviceSize{0}
    vk.CmdBindVertexBuffers(
      command_buffer,
      0,
      1,
      raw_data(vertex_buffers[:]),
      raw_data(offsets[:]),
    )
    vk.CmdBindIndexBuffer(command_buffer, rm.index_buffer.buffer, 0, .UINT32)
    // Use current frame's draw list (prepared by frame N-1 compute)
    // draw_list[frame_index] was written by Compute N-1, safe to read during Render N
    vk.CmdDrawIndexedIndirectCount(
      command_buffer,
      camera.late_draw_commands[frame_index].buffer,
      0, // offset
      camera.late_draw_count[frame_index].buffer,
      0, // count offset
      system.max_draws,
      draw_command_stride(),
    )
  }
  vk.CmdEndRendering(command_buffer)
}

@(private)
build_depth_pyramid :: proc(
  system: ^VisibilitySystem,
  gctx: ^gpu.GPUContext,
  command_buffer: vk.CommandBuffer,
  camera: ^resources.Camera,
  target_frame_index: u32, // Frame N builds pyramid[N] from depth[N-1] (via descriptors)
  rm: ^resources.Manager,
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
    mip_height := max(1, camera.depth_pyramid[target_frame_index].height >> mip)
    dispatch_x := (mip_width + 31) / 32
    dispatch_y := (mip_height + 31) / 32
    vk.CmdDispatch(command_buffer, dispatch_x, dispatch_y, 1)
    // only synchronize the dependency chain, don't transition layouts
    if mip < camera.depth_pyramid[target_frame_index].mip_levels - 1 {
      vk.CmdPipelineBarrier(
        command_buffer,
        {.COMPUTE_SHADER},
        {.COMPUTE_SHADER},
        {},
        0,
        nil,
        0,
        nil,
        0,
        nil,
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
  rm: ^resources.Manager,
) {
  depth_cube := resources.get(rm.image_cube_buffers, camera.depth_cube)
  if depth_cube == nil {
    log.error("Failed to get depth cube for spherical camera")
    return
  }
  // transition all cube faces to ATTACHMENT_OPTIMAL for rendering
  cube_ready_to_write := vk.ImageMemoryBarrier {
    sType = .IMAGE_MEMORY_BARRIER,
    srcAccessMask = {.SHADER_READ},
    dstAccessMask = {.DEPTH_STENCIL_ATTACHMENT_WRITE},
    oldLayout = .SHADER_READ_ONLY_OPTIMAL,
    newLayout = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
    srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
    dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
    image = depth_cube.image,
    subresourceRange = {
      aspectMask     = {.DEPTH},
      baseMipLevel   = 0,
      levelCount     = 1,
      baseArrayLayer = 0,
      layerCount     = 6,
    },
  }
  vk.CmdPipelineBarrier(
    command_buffer,
    {.FRAGMENT_SHADER},
    {.EARLY_FRAGMENT_TESTS},
    {},
    0,
    nil,
    0,
    nil,
    1,
    &cube_ready_to_write,
  )
  // the geometry shader will emit primitives to each face using gl_Layer
  depth_attachment := vk.RenderingAttachmentInfo {
    sType = .RENDERING_ATTACHMENT_INFO,
    imageView = depth_cube.view,
    imageLayout = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
    loadOp = .CLEAR,
    storeOp = .STORE,
    clearValue = {depthStencil = {depth = 1.0, stencil = 0}},
  }
  render_info := vk.RenderingInfo {
    sType = .RENDERING_INFO,
    renderArea = {
      offset = {0, 0},
      extent = {width = camera.size, height = camera.size},
    },
    layerCount = 6,
    pDepthAttachment = &depth_attachment,
  }
  vk.CmdBeginRendering(command_buffer, &render_info)
  // Set viewport and scissor for cube face size
  viewport := vk.Viewport {
    x        = 0,
    y        = f32(camera.size),
    width    = f32(camera.size),
    height   = -f32(camera.size),
    minDepth = 0.0,
    maxDepth = 1.0,
  }
  scissor := vk.Rect2D {
    offset = {0, 0},
    extent = {width = camera.size, height = camera.size},
  }
  vk.CmdSetViewport(command_buffer, 0, 1, &viewport)
  vk.CmdSetScissor(command_buffer, 0, 1, &scissor)
  if system.spherical_depth_pipeline != 0 {
    vk.CmdBindPipeline(
      command_buffer,
      .GRAPHICS,
      system.spherical_depth_pipeline,
    )
    descriptor_sets := [?]vk.DescriptorSet {
      rm.spherical_camera_buffer_descriptor_set,
      rm.textures_descriptor_set,
      rm.bone_buffer_descriptor_set,
      rm.material_buffer_descriptor_set,
      rm.world_matrix_descriptor_set,
      rm.node_data_descriptor_set,
      rm.mesh_data_descriptor_set,
      rm.vertex_skinning_descriptor_set,
    }
    vk.CmdBindDescriptorSets(
      command_buffer,
      .GRAPHICS,
      rm.spherical_camera_pipeline_layout,
      0,
      len(descriptor_sets),
      raw_data(descriptor_sets[:]),
      0,
      nil,
    )
    cam_idx := camera_index
    vk.CmdPushConstants(
      command_buffer,
      rm.spherical_camera_pipeline_layout,
      {.VERTEX, .GEOMETRY},
      0,
      size_of(u32),
      &cam_idx,
    )
    vertex_buffers := [?]vk.Buffer{rm.vertex_buffer.buffer}
    offsets := [?]vk.DeviceSize{0}
    vk.CmdBindVertexBuffers(
      command_buffer,
      0,
      1,
      raw_data(vertex_buffers[:]),
      raw_data(offsets[:]),
    )
    vk.CmdBindIndexBuffer(command_buffer, rm.index_buffer.buffer, 0, .UINT32)
    // Draw using indirect commands from culling pass
    vk.CmdDrawIndexedIndirectCount(
      command_buffer,
      camera.draw_commands.buffer,
      0, // offset
      camera.draw_count.buffer,
      0, // count offset
      system.max_draws,
      draw_command_stride(),
    )
  }
  vk.CmdEndRendering(command_buffer)
  // Transition cube back to SHADER_READ_ONLY for shadow sampling
  cube_ready_to_read := vk.ImageMemoryBarrier {
    sType = .IMAGE_MEMORY_BARRIER,
    srcAccessMask = {.DEPTH_STENCIL_ATTACHMENT_WRITE},
    dstAccessMask = {.SHADER_READ},
    oldLayout = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
    newLayout = .SHADER_READ_ONLY_OPTIMAL,
    srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
    dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
    image = depth_cube.image,
    subresourceRange = {
      aspectMask     = {.DEPTH},
      baseMipLevel   = 0,
      levelCount     = 1,
      baseArrayLayer = 0,
      layerCount     = 6, // all 6 cube faces
    },
  }
  vk.CmdPipelineBarrier(
    command_buffer,
    {.LATE_FRAGMENT_TESTS},
    {.FRAGMENT_SHADER},
    {},
    0,
    nil,
    0,
    nil,
    1,
    &cube_ready_to_read,
  )
}

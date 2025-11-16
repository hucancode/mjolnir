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
  opaque_draw_count: u32,
  camera_index:      u32,
  frame_index:       u32,
}

VisibilitySystem :: struct {
  cull_layout:           vk.PipelineLayout,
  cull_pipeline:         vk.Pipeline, // Generates 3 draw lists in one dispatch
  depth_pipeline:        vk.Pipeline, // uses general_pipeline_layout
  depth_reduce_layout:   vk.PipelineLayout,
  depth_reduce_pipeline: vk.Pipeline,
  sphere_cull_layout:    vk.PipelineLayout,
  sphere_cull_pipeline:  vk.Pipeline, // For SphericalCamera (radius-based culling)
  sphere_depth_pipeline: vk.Pipeline, // uses sphere_pipeline_layout
  max_draws:             u32,
  node_count:            u32,
  depth_width:           u32,
  depth_height:          u32,
  depth_bias:            f32,
  stats_enabled:         bool,
}

visibility_init :: proc(
  self: ^VisibilitySystem,
  gctx: ^gpu.GPUContext,
  rm: ^resources.Manager,
  depth_width: u32,
  depth_height: u32,
) -> (
  ret: vk.Result,
) {
  self.max_draws = resources.MAX_NODES_IN_SCENE
  self.depth_width = depth_width
  self.depth_height = depth_height
  self.depth_bias = 0.0001
  create_compute_pipelines(self, gctx, rm) or_return
  defer if ret != .SUCCESS {
    vk.DestroyPipelineLayout(gctx.device, self.depth_reduce_layout, nil)
    vk.DestroyPipeline(gctx.device, self.depth_reduce_pipeline, nil)
    vk.DestroyPipelineLayout(gctx.device, self.cull_layout, nil)
    vk.DestroyPipeline(gctx.device, self.cull_pipeline, nil)
    vk.DestroyPipelineLayout(gctx.device, self.sphere_cull_layout, nil)
    vk.DestroyPipeline(gctx.device, self.sphere_cull_pipeline, nil)
  }
  create_depth_pipeline(self, gctx, rm) or_return
  defer if ret != .SUCCESS {
    vk.DestroyPipeline(gctx.device, self.depth_pipeline, nil)
    vk.DestroyPipeline(gctx.device, self.sphere_depth_pipeline, nil)
  }
  return .SUCCESS
}

visibility_shutdown :: proc(
  self: ^VisibilitySystem,
  gctx: ^gpu.GPUContext,
) {
  vk.DestroyPipeline(gctx.device, self.sphere_cull_pipeline, nil)
  vk.DestroyPipeline(gctx.device, self.cull_pipeline, nil)
  vk.DestroyPipeline(gctx.device, self.depth_reduce_pipeline, nil)
  vk.DestroyPipeline(gctx.device, self.depth_pipeline, nil)
  vk.DestroyPipeline(gctx.device, self.sphere_depth_pipeline, nil)
  vk.DestroyPipelineLayout(gctx.device, self.sphere_cull_layout, nil)
  vk.DestroyPipelineLayout(gctx.device, self.cull_layout, nil)
  vk.DestroyPipelineLayout(gctx.device, self.depth_reduce_layout, nil)
}

visibility_stats :: proc(
  self: ^VisibilitySystem,
  camera: ^resources.Camera,
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
visibility_render_depth :: proc(
  self: ^VisibilitySystem,
  gctx: ^gpu.GPUContext,
  command_buffer: vk.CommandBuffer,
  camera: ^resources.Camera,
  camera_index: u32,
  frame_index: u32,
  include_flags: resources.NodeFlagSet,
  exclude_flags: resources.NodeFlagSet,
  rm: ^resources.Manager,
) {
  if self.node_count == 0 do return
  // Clear all draw count buffers (multi_pass writes to all 3)
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
    camera.sprite_draw_count[frame_index].buffer,
    0,
    vk.DeviceSize(camera.sprite_draw_count[frame_index].bytes_count),
    0,
  )
  gpu.bind_compute_pipeline(
    command_buffer,
    self.cull_pipeline,
    self.cull_layout,
    camera.descriptor_set[frame_index],
  )
  prev_frame :=
    (frame_index + resources.FRAMES_IN_FLIGHT - 1) % resources.FRAMES_IN_FLIGHT
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
  if self.node_count == 0 do return
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
  gpu.set_viewport_scissor(
    command_buffer,
    camera.extent.width,
    camera.extent.height,
  )
  if self.depth_pipeline != 0 {
    gpu.bind_graphics_pipeline(
      command_buffer,
      self.depth_pipeline,
      rm.general_pipeline_layout,
      rm.camera_buffer.descriptor_sets[frame_index], // Per-frame to avoid overlap
      rm.textures_descriptor_set,
      rm.bone_buffer.descriptor_set,
      rm.material_buffer.descriptor_set,
      rm.world_matrix_buffer.descriptor_set,
      rm.node_data_buffer.descriptor_set,
      rm.mesh_data_buffer.descriptor_set,
      rm.vertex_skinning_buffer.descriptor_set,
    )
    camera_index := camera_index
    vk.CmdPushConstants(
      command_buffer,
      rm.general_pipeline_layout,
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
      camera.opaque_draw_commands[frame_index].buffer,
      0, // offset
      camera.opaque_draw_count[frame_index].buffer,
      0, // count offset
      self.max_draws,
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

// STEP 3: Build pyramid - reads depth[N-1], builds pyramid[N]
visibility_build_pyramid :: proc(
  self: ^VisibilitySystem,
  gctx: ^gpu.GPUContext,
  command_buffer: vk.CommandBuffer,
  camera: ^resources.Camera,
  camera_index: u32,
  frame_index: u32, // Which pyramid to write to
  rm: ^resources.Manager,
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
visibility_perform_culling :: proc(
  self: ^VisibilitySystem,
  gctx: ^gpu.GPUContext,
  command_buffer: vk.CommandBuffer,
  camera: ^resources.Camera,
  camera_index: u32,
  frame_index: u32,
  include_flags: resources.NodeFlagSet,
  exclude_flags: resources.NodeFlagSet,
  rm: ^resources.Manager,
) {
  if self.node_count == 0 {
    return
  }
  // Clear all draw count buffers (multi_pass writes to all 3)
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
    camera.sprite_draw_count[frame_index].buffer,
    0,
    vk.DeviceSize(camera.sprite_draw_count[frame_index].bytes_count),
    0,
  )
  gpu.bind_compute_pipeline(
    command_buffer,
    self.cull_pipeline,
    self.cull_layout,
    camera.descriptor_set[frame_index],
  )
  prev_frame :=
    (frame_index + resources.FRAMES_IN_FLIGHT - 1) % resources.FRAMES_IN_FLIGHT
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

// SphericalCamera visibility dispatch - culling + depth cube rendering
visibility_render_sphere_depth :: proc(
  self: ^VisibilitySystem,
  gctx: ^gpu.GPUContext,
  command_buffer: vk.CommandBuffer,
  camera: ^resources.SphericalCamera,
  camera_index: u32,
  frame_index: u32,
  include_flags: resources.NodeFlagSet,
  exclude_flags: resources.NodeFlagSet,
  rm: ^resources.Manager,
) {
  if self.node_count == 0 do return
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
    self.sphere_cull_pipeline,
    self.sphere_cull_layout,
    camera.descriptor_sets[frame_index],
  )
  push_constants := VisibilityPushConstants {
    camera_index      = camera_index,
    node_count        = self.node_count,
    max_draws         = self.max_draws,
    include_flags     = include_flags,
    exclude_flags     = exclude_flags,
    pyramid_width     = 0,
    pyramid_height    = 0,
    depth_bias        = 0,
    occlusion_enabled = 0,
  }
  vk.CmdPushConstants(
    command_buffer,
    self.sphere_cull_layout,
    {.COMPUTE},
    0,
    size_of(push_constants),
    &push_constants,
  )
  dispatch_x := (self.node_count + 63) / 64
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
  if self.sphere_depth_pipeline != 0 {
    gpu.bind_graphics_pipeline(
      command_buffer,
      self.sphere_depth_pipeline,
      rm.sphere_pipeline_layout,
      rm.spherical_camera_buffer.descriptor_sets[frame_index], // Per-frame to avoid overlap
      rm.textures_descriptor_set,
      rm.bone_buffer.descriptor_set,
      rm.material_buffer.descriptor_set,
      rm.world_matrix_buffer.descriptor_set,
      rm.node_data_buffer.descriptor_set,
      rm.mesh_data_buffer.descriptor_set,
      rm.vertex_skinning_buffer.descriptor_set,
    )
    cam_idx := camera_index
    vk.CmdPushConstants(
      command_buffer,
      rm.sphere_pipeline_layout,
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
      self.max_draws,
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
    rm.sphere_cam_descriptor_layout,
  ) or_return
  self.cull_layout = gpu.create_pipeline_layout(
    gctx,
    vk.PushConstantRange {
      stageFlags = {.COMPUTE},
      size = size_of(VisibilityPushConstants),
    },
    rm.normal_cam_descriptor_layout,
  ) or_return
  self.depth_reduce_layout = gpu.create_pipeline_layout(
    gctx,
    vk.PushConstantRange {
      stageFlags = {.COMPUTE},
      size = size_of(DepthReducePushConstants),
    },
    rm.depth_reduce_descriptor_layout,
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
  self: ^VisibilitySystem,
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
  if rm.general_pipeline_layout == 0 {
    return .ERROR_INITIALIZATION_FAILED
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
    layout              = rm.general_pipeline_layout,
  }
  vk.CreateGraphicsPipelines(
    gctx.device,
    0,
    1,
    &pipeline_info,
    nil,
    &self.depth_pipeline,
  ) or_return
  // create depth rendering pipeline for spherical cameras (point light shadows)
  // uses geometry shader to render to all 6 cube faces in one pass
  sphere_vert_shader := gpu.create_shader_module(
    gctx.device,
    SHADER_SPHERECAM_DEPTH_VERT,
  ) or_return
  defer vk.DestroyShaderModule(gctx.device, sphere_vert_shader, nil)
  sphere_geom_shader := gpu.create_shader_module(
    gctx.device,
    SHADER_SPHERECAM_DEPTH_GEOM,
  ) or_return
  defer vk.DestroyShaderModule(gctx.device, sphere_geom_shader, nil)
  sphere_frag_shader := gpu.create_shader_module(
    gctx.device,
    SHADER_SPHERECAM_DEPTH_FRAG,
  ) or_return
  defer vk.DestroyShaderModule(gctx.device, sphere_frag_shader, nil)
  sphere_shader_stages := [?]vk.PipelineShaderStageCreateInfo {
    {
      sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
      stage = {.VERTEX},
      module = sphere_vert_shader,
      pName = "main",
    },
    {
      sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
      stage = {.GEOMETRY},
      module = sphere_geom_shader,
      pName = "main",
    },
    {
      sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
      stage = {.FRAGMENT},
      module = sphere_frag_shader,
      pName = "main",
    },
  }
  if rm.sphere_pipeline_layout == 0 {
    return .ERROR_INITIALIZATION_FAILED
  }
  sphere_pipeline_info := vk.GraphicsPipelineCreateInfo {
    sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
    pNext               = &gpu.DEPTH_ONLY_RENDERING_INFO,
    stageCount          = len(sphere_shader_stages),
    pStages             = raw_data(sphere_shader_stages[:]),
    pVertexInputState   = &vertex_input_info,
    pInputAssemblyState = &gpu.STANDARD_INPUT_ASSEMBLY,
    pViewportState      = &gpu.STANDARD_VIEWPORT_STATE,
    pRasterizationState = &gpu.STANDARD_RASTERIZER,
    pMultisampleState   = &gpu.STANDARD_MULTISAMPLING,
    pDepthStencilState  = &gpu.READ_WRITE_DEPTH_STATE,
    pDynamicState       = &gpu.STANDARD_DYNAMIC_STATES,
    layout              = rm.sphere_pipeline_layout,
  }
  vk.CreateGraphicsPipelines(
    gctx.device,
    0,
    1,
    &sphere_pipeline_info,
    nil,
    &self.sphere_depth_pipeline,
  ) or_return
  return .SUCCESS
}

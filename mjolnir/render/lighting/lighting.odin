package lighting

import geometry "../../geometry"
import gpu "../../gpu"
import resources "../../resources"
import "core:fmt"
import "core:log"
import "core:slice"
import mu "vendor:microui"
import vk "vendor:vulkan"

LightKind :: enum u32 {
  POINT       = 0,
  DIRECTIONAL = 1,
  SPOT        = 2,
}

ShadowResources :: struct {
  cube_render_targets: [6]resources.Handle,
  cube_cameras:        [6]resources.Handle,
  shadow_map:          resources.Handle,
  render_target:       resources.Handle,
  camera:              resources.Handle,
}

AmbientPushConstant :: struct {
  camera_index:           u32,
  environment_index:      u32,
  brdf_lut_index:         u32,
  position_texture_index: u32,
  normal_texture_index:   u32,
  albedo_texture_index:   u32,
  metallic_texture_index: u32,
  emissive_texture_index: u32,
  depth_texture_index:    u32,
  environment_max_lod:    f32,
  ibl_intensity:          f32,
}

LightPushConstant :: struct {
  light_index:            u32,
  scene_camera_idx:       u32,
  position_texture_index: u32,
  normal_texture_index:   u32,
  albedo_texture_index:   u32,
  metallic_texture_index: u32,
  emissive_texture_index: u32,
  depth_texture_index:    u32,
  input_image_index:      u32,
}

begin_ambient_pass :: proc(
  self: ^Renderer,
  target: ^resources.RenderTarget,
  command_buffer: vk.CommandBuffer,
  resources_manager: ^resources.Manager,
  frame_index: u32,
) {
  color_texture := resources.get(
    resources_manager.image_2d_buffers,
    resources.get_final_image(target, frame_index),
  )
  color_attachment := vk.RenderingAttachmentInfo {
    sType = .RENDERING_ATTACHMENT_INFO,
    imageView = color_texture.view,
    imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
    loadOp = .CLEAR,
    storeOp = .STORE,
    clearValue = {color = {float32 = {0, 0, 0, 1}}},
  }
  render_info := vk.RenderingInfo {
    sType = .RENDERING_INFO,
    renderArea = {extent = target.extent},
    layerCount = 1,
    colorAttachmentCount = 1,
    pColorAttachments = &color_attachment,
  }
  vk.CmdBeginRendering(command_buffer, &render_info)
  viewport := vk.Viewport {
    width    = f32(target.extent.width),
    height   = f32(target.extent.height),
    minDepth = 0.0,
    maxDepth = 1.0,
  }
  scissor := vk.Rect2D {
    extent = target.extent,
  }
  vk.CmdSetViewport(command_buffer, 0, 1, &viewport)
  vk.CmdSetScissor(command_buffer, 0, 1, &scissor)
  descriptor_sets := [?]vk.DescriptorSet {
    resources_manager.camera_buffer_descriptor_set, // set = 0 (bindless camera buffer)
    resources_manager.textures_descriptor_set, // set = 1 (bindless textures)
  }
  vk.CmdBindDescriptorSets(
    command_buffer,
    .GRAPHICS,
    self.ambient_pipeline_layout,
    0,
    len(descriptor_sets),
    raw_data(descriptor_sets[:]),
    0,
    nil,
  )
  vk.CmdBindPipeline(command_buffer, .GRAPHICS, self.ambient_pipeline)
}

render_ambient :: proc(
  self: ^Renderer,
  render_target: ^resources.RenderTarget,
  command_buffer: vk.CommandBuffer,
  resources_manager: ^resources.Manager,
  frame_index: u32,
) {
  push := AmbientPushConstant {
    camera_index           = render_target.camera.index,
    environment_index      = self.environment_map.index,
    brdf_lut_index         = self.brdf_lut.index,
    position_texture_index = resources.get_position_texture(render_target, frame_index).index,
    normal_texture_index   = resources.get_normal_texture(render_target, frame_index).index,
    albedo_texture_index   = resources.get_albedo_texture(render_target, frame_index).index,
    metallic_texture_index = resources.get_metallic_roughness_texture(render_target, frame_index).index,
    emissive_texture_index = resources.get_emissive_texture(render_target, frame_index).index,
    depth_texture_index    = resources.get_depth_texture(render_target, frame_index).index,
    environment_max_lod    = self.environment_max_lod,
    ibl_intensity          = self.ibl_intensity,
  }
  vk.CmdPushConstants(
    command_buffer,
    self.ambient_pipeline_layout,
    {.FRAGMENT},
    0,
    size_of(AmbientPushConstant),
    &push,
  )
  vk.CmdDraw(command_buffer, 3, 1, 0, 0) // fullscreen triangle
}

end_ambient_pass :: proc(command_buffer: vk.CommandBuffer) {
  vk.CmdEndRendering(command_buffer)
}

init :: proc(
  self: ^Renderer,
  gpu_context: ^gpu.GPUContext,
  resources_manager: ^resources.Manager,
  width, height: u32,
  color_format: vk.Format = .B8G8R8A8_SRGB,
  depth_format: vk.Format = .D32_SFLOAT,
) -> vk.Result {
  gpu.allocate_secondary_buffers(
    gpu_context.device,
    gpu_context.command_pool,
    self.commands[:],
  ) or_return

  log.debugf("renderer lighting init %d x %d", width, height)

  // Initialize ambient pipeline
  ambient_pipeline_set_layouts := [?]vk.DescriptorSetLayout {
    resources_manager.camera_buffer_set_layout, // set = 0 (bindless camera buffer)
    resources_manager.textures_set_layout, // set = 1 (bindless textures)
  }
  ambient_push_constant_range := vk.PushConstantRange {
    stageFlags = {.FRAGMENT},
    size       = size_of(AmbientPushConstant),
  }
  vk.CreatePipelineLayout(
    gpu_context.device,
    &{
      sType = .PIPELINE_LAYOUT_CREATE_INFO,
      setLayoutCount = len(ambient_pipeline_set_layouts),
      pSetLayouts = raw_data(ambient_pipeline_set_layouts[:]),
      pushConstantRangeCount = 1,
      pPushConstantRanges = &ambient_push_constant_range,
    },
    nil,
    &self.ambient_pipeline_layout,
  ) or_return

  ambient_vert_shader_code := #load("../../shader/lighting_ambient/vert.spv")
  ambient_vert_module := gpu.create_shader_module(
    gpu_context.device,
    ambient_vert_shader_code,
  ) or_return
  defer vk.DestroyShaderModule(gpu_context.device, ambient_vert_module, nil)
  ambient_frag_shader_code := #load("../../shader/lighting_ambient/frag.spv")
  ambient_frag_module := gpu.create_shader_module(
    gpu_context.device,
    ambient_frag_shader_code,
  ) or_return
  defer vk.DestroyShaderModule(gpu_context.device, ambient_frag_module, nil)

  ambient_dynamic_states := [?]vk.DynamicState{.VIEWPORT, .SCISSOR}
  ambient_dynamic_state := vk.PipelineDynamicStateCreateInfo {
    sType             = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
    dynamicStateCount = len(ambient_dynamic_states),
    pDynamicStates    = raw_data(ambient_dynamic_states[:]),
  }
  ambient_input_assembly := vk.PipelineInputAssemblyStateCreateInfo {
    sType    = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
    topology = .TRIANGLE_LIST,
  }
  ambient_vertex_input := vk.PipelineVertexInputStateCreateInfo {
    sType = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
  }
  ambient_viewport_state := vk.PipelineViewportStateCreateInfo {
    sType         = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
    viewportCount = 1,
    scissorCount  = 1,
  }
  ambient_rasterizer := vk.PipelineRasterizationStateCreateInfo {
    sType       = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
    polygonMode = .FILL,
    lineWidth   = 1.0,
  }
  ambient_multisampling := vk.PipelineMultisampleStateCreateInfo {
    sType                = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
    rasterizationSamples = {._1},
  }
  ambient_color_blend_attachment := vk.PipelineColorBlendAttachmentState {
    colorWriteMask      = {.R, .G, .B, .A},
    blendEnable         = false,
    srcColorBlendFactor = .ONE,
    dstColorBlendFactor = .ZERO,
    colorBlendOp        = .ADD,
    srcAlphaBlendFactor = .ONE,
    dstAlphaBlendFactor = .ZERO,
    alphaBlendOp        = .ADD,
  }
  ambient_color_blending := vk.PipelineColorBlendStateCreateInfo {
    sType           = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
    attachmentCount = 1,
    pAttachments    = &ambient_color_blend_attachment,
  }
  ambient_depth_stencil := vk.PipelineDepthStencilStateCreateInfo {
    sType = .PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
  }
  ambient_color_formats := [?]vk.Format{color_format}
  ambient_rendering_info := vk.PipelineRenderingCreateInfo {
    sType                   = .PIPELINE_RENDERING_CREATE_INFO,
    colorAttachmentCount    = len(ambient_color_formats),
    pColorAttachmentFormats = raw_data(ambient_color_formats[:]),
  }
  ambient_shader_stages := [?]vk.PipelineShaderStageCreateInfo {
    {
      sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
      stage = {.VERTEX},
      module = ambient_vert_module,
      pName = "main",
    },
    {
      sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
      stage = {.FRAGMENT},
      module = ambient_frag_module,
      pName = "main",
    },
  }
  ambient_pipeline_info := vk.GraphicsPipelineCreateInfo {
    sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
    pNext               = &ambient_rendering_info,
    stageCount          = len(ambient_shader_stages),
    pStages             = raw_data(ambient_shader_stages[:]),
    pVertexInputState   = &ambient_vertex_input,
    pInputAssemblyState = &ambient_input_assembly,
    pViewportState      = &ambient_viewport_state,
    pRasterizationState = &ambient_rasterizer,
    pMultisampleState   = &ambient_multisampling,
    pColorBlendState    = &ambient_color_blending,
    pDynamicState       = &ambient_dynamic_state,
    pDepthStencilState  = &ambient_depth_stencil,
    layout              = self.ambient_pipeline_layout,
  }
  vk.CreateGraphicsPipelines(
    gpu_context.device,
    0,
    1,
    &ambient_pipeline_info,
    nil,
    &self.ambient_pipeline,
  ) or_return

  // Initialize environment resources
  environment_map: ^gpu.ImageBuffer
  self.environment_map, environment_map =
    resources.create_texture_from_path(
      gpu_context,
      resources_manager,
      "assets/Cannon_Exterior.hdr",
      .R32G32B32A32_SFLOAT,
      true,
      {.SAMPLED},
      true,
    ) or_return
  self.environment_max_lod = 8.0 // default fallback
  if environment_map != nil {
    self.environment_max_lod =
      resources.calculate_mip_levels(
        environment_map.width,
        environment_map.height,
      ) -
      1.0
  }
  brdf_lut: ^gpu.ImageBuffer
  brdf_handle, _, brdf_ret := resources.create_texture_from_data(
    gpu_context,
    resources_manager,
    #load("../../assets/lut_ggx.png"),
  )
  if brdf_ret != .SUCCESS {
    return brdf_ret
  }
  self.brdf_lut = brdf_handle
  self.ibl_intensity = 1.0 // Default IBL intensity

  log.info("Ambient pipeline initialized successfully")

  // Initialize lighting pipeline
  lighting_pipeline_set_layouts := [?]vk.DescriptorSetLayout {
    resources_manager.camera_buffer_set_layout,
    resources_manager.textures_set_layout,
    resources_manager.lights_buffer_set_layout,
    resources_manager.world_matrix_buffer_set_layout,
  }
  lighting_push_constant_range := vk.PushConstantRange {
    stageFlags = {.VERTEX, .FRAGMENT},
    size       = size_of(LightPushConstant),
  }
  vk.CreatePipelineLayout(
    gpu_context.device,
    &vk.PipelineLayoutCreateInfo {
      sType = .PIPELINE_LAYOUT_CREATE_INFO,
      setLayoutCount = len(lighting_pipeline_set_layouts),
      pSetLayouts = raw_data(lighting_pipeline_set_layouts[:]),
      pushConstantRangeCount = 1,
      pPushConstantRanges = &lighting_push_constant_range,
    },
    nil,
    &self.lighting_pipeline_layout,
  ) or_return

  lighting_vert_shader_code := #load("../../shader/lighting/vert.spv")
  lighting_vert_module := gpu.create_shader_module(
    gpu_context.device,
    lighting_vert_shader_code,
  ) or_return
  defer vk.DestroyShaderModule(gpu_context.device, lighting_vert_module, nil)
  lighting_frag_shader_code := #load("../../shader/lighting/frag.spv")
  lighting_frag_module := gpu.create_shader_module(
    gpu_context.device,
    lighting_frag_shader_code,
  ) or_return
  defer vk.DestroyShaderModule(gpu_context.device, lighting_frag_module, nil)

  lighting_dynamic_states := [?]vk.DynamicState{.VIEWPORT, .SCISSOR, .DEPTH_COMPARE_OP}
  lighting_dynamic_state := vk.PipelineDynamicStateCreateInfo {
    sType             = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
    dynamicStateCount = len(lighting_dynamic_states),
    pDynamicStates    = raw_data(lighting_dynamic_states[:]),
  }
  lighting_input_assembly := vk.PipelineInputAssemblyStateCreateInfo {
    sType    = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
    topology = .TRIANGLE_LIST,
  }
  lighting_vertex_input := vk.PipelineVertexInputStateCreateInfo {
    sType                           = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
    vertexBindingDescriptionCount   = 1,
    pVertexBindingDescriptions      = &geometry.VERTEX_BINDING_DESCRIPTION[0],
    vertexAttributeDescriptionCount = 1, // Only position needed for lighting
    pVertexAttributeDescriptions    = &geometry.VERTEX_ATTRIBUTE_DESCRIPTIONS[0], // Position at location 0
  }
  lighting_viewport_state := vk.PipelineViewportStateCreateInfo {
    sType         = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
    viewportCount = 1,
    scissorCount  = 1,
  }
  lighting_rasterizer := vk.PipelineRasterizationStateCreateInfo {
    sType       = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
    polygonMode = .FILL,
    cullMode    = {.FRONT},
    frontFace   = .COUNTER_CLOCKWISE,
    lineWidth   = 1.0,
  }
  lighting_multisampling := vk.PipelineMultisampleStateCreateInfo {
    sType                = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
    rasterizationSamples = {._1},
  }
  lighting_color_blend_attachment := vk.PipelineColorBlendAttachmentState {
    colorWriteMask      = {.R, .G, .B, .A},
    blendEnable         = true,
    srcColorBlendFactor = .ONE,
    dstColorBlendFactor = .ONE,
    colorBlendOp        = .ADD,
    srcAlphaBlendFactor = .ONE,
    dstAlphaBlendFactor = .ONE,
    alphaBlendOp        = .ADD,
  }
  lighting_color_blending := vk.PipelineColorBlendStateCreateInfo {
    sType           = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
    attachmentCount = 1,
    pAttachments    = &lighting_color_blend_attachment,
  }
  lighting_depth_stencil := vk.PipelineDepthStencilStateCreateInfo {
    sType           = .PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
    depthTestEnable = true,
    // Greater or equal for point light, less or equal for spot light
    depthCompareOp  = .GREATER_OR_EQUAL,
  }
  lighting_color_formats := [?]vk.Format{color_format}
  lighting_rendering_info := vk.PipelineRenderingCreateInfo {
    sType                   = .PIPELINE_RENDERING_CREATE_INFO,
    colorAttachmentCount    = len(lighting_color_formats),
    pColorAttachmentFormats = raw_data(lighting_color_formats[:]),
    depthAttachmentFormat   = depth_format,
  }
  lighting_shader_stages := [?]vk.PipelineShaderStageCreateInfo {
    {
      sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
      stage = {.VERTEX},
      module = lighting_vert_module,
      pName = "main",
    },
    {
      sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
      stage = {.FRAGMENT},
      module = lighting_frag_module,
      pName = "main",
    },
  }
  lighting_pipeline_info := vk.GraphicsPipelineCreateInfo {
    sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
    pNext               = &lighting_rendering_info,
    stageCount          = len(lighting_shader_stages),
    pStages             = raw_data(lighting_shader_stages[:]),
    pVertexInputState   = &lighting_vertex_input,
    pInputAssemblyState = &lighting_input_assembly,
    pViewportState      = &lighting_viewport_state,
    pRasterizationState = &lighting_rasterizer,
    pMultisampleState   = &lighting_multisampling,
    pColorBlendState    = &lighting_color_blending,
    pDynamicState       = &lighting_dynamic_state,
    pDepthStencilState  = &lighting_depth_stencil,
    layout              = self.lighting_pipeline_layout,
  }
  vk.CreateGraphicsPipelines(
    gpu_context.device,
    0,
    1,
    &lighting_pipeline_info,
    nil,
    &self.lighting_pipeline,
  ) or_return
  log.info("Lighting pipeline initialized successfully")

  // Initialize light volume meshes
  self.sphere_mesh, _ = resources.create_mesh(
    gpu_context,
    resources_manager,
    geometry.make_sphere(segments = 64, rings = 64),
  ) or_return
  self.cone_mesh, _ = resources.create_mesh(
    gpu_context,
    resources_manager,
    geometry.make_cone(segments = 128, height = 1, radius = 0.5),
  ) or_return
  self.fullscreen_triangle_mesh, _ = resources.create_mesh(
    gpu_context,
    resources_manager,
    geometry.make_fullscreen_triangle(),
  ) or_return
  log.info("Light volume meshes initialized")

  return .SUCCESS
}

shutdown :: proc(
  self: ^Renderer,
  device: vk.Device,
  command_pool: vk.CommandPool,
  resources_manager: ^resources.Manager,
) {
  gpu.free_command_buffers(device, command_pool, self.commands[:])
  vk.DestroyPipeline(device, self.ambient_pipeline, nil)
  self.ambient_pipeline = 0
  vk.DestroyPipelineLayout(
    device,
    self.ambient_pipeline_layout,
    nil,
  )
  self.ambient_pipeline_layout = 0
  if item, freed := resources.free(
    &resources_manager.image_2d_buffers,
    self.environment_map,
  ); freed {
    gpu.image_buffer_destroy(device, item)
  }
  if item, freed := resources.free(
    &resources_manager.image_2d_buffers,
    self.brdf_lut,
  ); freed {
    gpu.image_buffer_destroy(device, item)
  }
  vk.DestroyPipelineLayout(
    device,
    self.lighting_pipeline_layout,
    nil,
  )
  vk.DestroyPipeline(device, self.lighting_pipeline, nil)
}

begin_record :: proc(
  self: ^Renderer,
  frame_index: u32,
  color_format: vk.Format,
) -> (command_buffer: vk.CommandBuffer, ret: vk.Result) {
  command_buffer = self.commands[frame_index]
  vk.ResetCommandBuffer(command_buffer, {}) or_return
  color_formats := [1]vk.Format{color_format}
  rendering_info := vk.CommandBufferInheritanceRenderingInfo{
    sType = .COMMAND_BUFFER_INHERITANCE_RENDERING_INFO,
    colorAttachmentCount = 1,
    pColorAttachmentFormats = &color_formats[0],
    depthAttachmentFormat = .D32_SFLOAT,
  }
  inheritance := vk.CommandBufferInheritanceInfo {
    sType = .COMMAND_BUFFER_INHERITANCE_INFO,
    pNext = &rendering_info,
  }
  vk.BeginCommandBuffer(
    command_buffer,
    &vk.CommandBufferBeginInfo{
      sType = .COMMAND_BUFFER_BEGIN_INFO,
      flags = {.ONE_TIME_SUBMIT},
      pInheritanceInfo = &inheritance,
    },
  ) or_return
  ret = .SUCCESS
  return
}

end_record :: proc(command_buffer: vk.CommandBuffer) -> vk.Result {
  vk.EndCommandBuffer(command_buffer) or_return
  return .SUCCESS
}

BG_BLUE_GRAY :: [4]f32{0.0117, 0.0117, 0.0179, 1.0}
BG_DARK_GRAY :: [4]f32{0.0117, 0.0117, 0.0117, 1.0}
BG_ORANGE_GRAY :: [4]f32{0.0179, 0.0179, 0.0117, 1.0}

Renderer :: struct {
  ambient_pipeline:         vk.Pipeline,
  ambient_pipeline_layout:  vk.PipelineLayout,
  environment_map:          resources.Handle,
  brdf_lut:                 resources.Handle,
  environment_max_lod:      f32,
  ibl_intensity:            f32,
  lighting_pipeline:        vk.Pipeline,
  lighting_pipeline_layout: vk.PipelineLayout,
  // Light volume meshes
  sphere_mesh:              resources.Handle,
  cone_mesh:                resources.Handle,
  fullscreen_triangle_mesh: resources.Handle,
  commands:                 [resources.MAX_FRAMES_IN_FLIGHT]vk.CommandBuffer,
}

lighting_recreate_images :: proc(
  self: ^Renderer,
  width, height: u32,
  color_format: vk.Format,
  depth_format: vk.Format,
) -> vk.Result {
  log.debugf("Updated G-buffer indices for lighting pass on resize")
  return .SUCCESS
}

begin_pass :: proc(
  self: ^Renderer,
  target: ^resources.RenderTarget,
  command_buffer: vk.CommandBuffer,
  resources_manager: ^resources.Manager,
  frame_index: u32,
) {
  final_image := resources.get(
    resources_manager.image_2d_buffers,
    resources.get_final_image(target, frame_index),
  )
  color_attachment := vk.RenderingAttachmentInfo {
    sType = .RENDERING_ATTACHMENT_INFO,
    imageView = final_image.view,
    imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
    loadOp = .LOAD,
    storeOp = .STORE,
    clearValue = {color = {float32 = BG_BLUE_GRAY}},
  }
  depth_texture := resources.get(
    resources_manager.image_2d_buffers,
    resources.get_depth_texture(target, frame_index),
  )
  depth_attachment := vk.RenderingAttachmentInfo {
    sType       = .RENDERING_ATTACHMENT_INFO,
    imageView   = depth_texture.view,
    imageLayout = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
    loadOp      = .LOAD,
    storeOp     = .DONT_CARE,
  }
  render_info := vk.RenderingInfo {
    sType = .RENDERING_INFO,
    renderArea = {extent = target.extent},
    layerCount = 1,
    colorAttachmentCount = 1,
    pColorAttachments = &color_attachment,
    pDepthAttachment = &depth_attachment,
  }
  vk.CmdBeginRendering(command_buffer, &render_info)
  viewport := vk.Viewport {
    x        = 0,
    y        = f32(target.extent.height),
    width    = f32(target.extent.width),
    height   = -f32(target.extent.height),
    minDepth = 0.0,
    maxDepth = 1.0,
  }
  scissor := vk.Rect2D {
    extent = target.extent,
  }
  vk.CmdSetViewport(command_buffer, 0, 1, &viewport)
  vk.CmdSetScissor(command_buffer, 0, 1, &scissor)
  descriptor_sets := [?]vk.DescriptorSet {
    resources_manager.camera_buffer_descriptor_set,
    resources_manager.textures_descriptor_set,
    resources_manager.lights_buffer_descriptor_set,
    resources_manager.world_matrix_descriptor_set,
  }
  vk.CmdBindDescriptorSets(
    command_buffer,
    .GRAPHICS,
    self.lighting_pipeline_layout,
    0,
    len(descriptor_sets),
    raw_data(descriptor_sets[:]),
    0,
    nil,
  )
  vk.CmdBindPipeline(command_buffer, .GRAPHICS, self.lighting_pipeline)
}

render :: proc(
  self: ^Renderer,
  render_target: ^resources.RenderTarget,
  command_buffer: vk.CommandBuffer,
  resources_manager: ^resources.Manager,
  frame_index: u32,
) {
  // Helper proc to bind and draw a mesh
  bind_and_draw_mesh :: proc(
    mesh_handle: resources.Handle,
    command_buffer: vk.CommandBuffer,
    resources_manager: ^resources.Manager,
  ) {
    mesh_ptr, ok := resources.get_mesh(resources_manager, mesh_handle)
    if !ok || mesh_ptr == nil {
      log.errorf("Failed to get mesh for handle %v", mesh_handle)
      return
    }
    vertex_offset := vk.DeviceSize(
      mesh_ptr.vertex_allocation.offset * size_of(geometry.Vertex),
    )
    vk.CmdBindVertexBuffers(
      command_buffer,
      0,
      1,
      &resources_manager.vertex_buffer.buffer,
      &vertex_offset,
    )
    vk.CmdBindIndexBuffer(
      command_buffer,
      resources_manager.index_buffer.buffer,
      vk.DeviceSize(mesh_ptr.index_allocation.offset * size_of(u32)),
      .UINT32,
    )
    vk.CmdDrawIndexed(
      command_buffer,
      mesh_ptr.index_allocation.count,
      1,
      0,
      0,
      0,
    )
  }
  // Push constant structure for light index-based rendering
  push_constant := LightPushConstant {
    scene_camera_idx = render_target.camera.index,
    position_texture_index = resources.get_position_texture(render_target, frame_index).index,
    normal_texture_index = resources.get_normal_texture(render_target, frame_index).index,
    albedo_texture_index = resources.get_albedo_texture(render_target, frame_index).index,
    metallic_texture_index = resources.get_metallic_roughness_texture(render_target, frame_index).index,
    emissive_texture_index = resources.get_emissive_texture(render_target, frame_index).index,
    depth_texture_index = resources.get_depth_texture(render_target, frame_index).index,
    input_image_index = resources.get_final_image(render_target, frame_index).index,
  }
  for idx in 0 ..< len(resources_manager.lights.entries) {
    entry := &resources_manager.lights.entries[idx]
    if entry.generation > 0 && entry.active {
      light := &entry.item
      push_constant.light_index = u32(idx)
      switch light.type {
      case .POINT:
        vk.CmdSetDepthCompareOp(command_buffer, .GREATER_OR_EQUAL)
        vk.CmdPushConstants(
          command_buffer,
          self.lighting_pipeline_layout,
          {.VERTEX, .FRAGMENT},
          0,
          size_of(push_constant),
          &push_constant,
        )
        bind_and_draw_mesh(self.sphere_mesh, command_buffer, resources_manager)
      case .DIRECTIONAL:
        vk.CmdSetDepthCompareOp(command_buffer, .ALWAYS)
        vk.CmdPushConstants(
          command_buffer,
          self.lighting_pipeline_layout,
          {.VERTEX, .FRAGMENT},
          0,
          size_of(push_constant),
          &push_constant,
        )
        bind_and_draw_mesh(
          self.fullscreen_triangle_mesh,
          command_buffer,
          resources_manager,
        )
      case .SPOT:
        vk.CmdSetDepthCompareOp(command_buffer, .LESS_OR_EQUAL)
        vk.CmdPushConstants(
          command_buffer,
          self.lighting_pipeline_layout,
          {.VERTEX, .FRAGMENT},
          0,
          size_of(push_constant),
          &push_constant,
        )
        bind_and_draw_mesh(self.cone_mesh, command_buffer, resources_manager)
      }
    }
  }
}

end_pass :: proc(command_buffer: vk.CommandBuffer) {
  vk.CmdEndRendering(command_buffer)
}

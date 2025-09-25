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

LightPushConstant :: struct {
  scene_camera_idx:       u32,
  light_camera_idx:       u32, // for shadow mapping
  shadow_map_id:          u32,
  light_kind:             LightKind,
  light_color:            [3]f32,
  light_angle:            f32,
  light_position:         [3]f32,
  light_radius:           f32,
  light_direction:        [3]f32,
  light_cast_shadow:      b32,
  position_texture_index: u32,
  normal_texture_index:   u32,
  albedo_texture_index:   u32,
  metallic_texture_index: u32,
  emissive_texture_index: u32,
  depth_texture_index:    u32,
  input_image_index:      u32,
}

ShadowResources :: struct {
  cube_render_targets: [6]resources.Handle,
  cube_cameras:        [6]resources.Handle,
  shadow_map:          resources.Handle,
  render_target:       resources.Handle,
  camera:              resources.Handle,
}

LightInfo :: struct {
  using gpu_data:         LightPushConstant,
  node_handle:            resources.Handle,
  transform_generation:   u64,
  using shadow_resources: ShadowResources,
  dirty:                  bool,
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

ambient_begin_pass :: proc(
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

ambient_render :: proc(
  self: ^Renderer,
  render_target: ^resources.RenderTarget,
  command_buffer: vk.CommandBuffer,
  resources_manager: ^resources.Manager,
  frame_index: u32,
) {
  // Use the same environment/IBL values as RendererMain (assume engine.ambient is initialized like main)
  // Use environment/BRDF LUT/IBL values from the main renderer (assume ambient renderer is initialized with these fields)
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

ambient_end_pass :: proc(command_buffer: vk.CommandBuffer) {
  vk.CmdEndRendering(command_buffer)
}

ambient_init :: proc(
  self: ^Renderer,
  gpu_context: ^gpu.GPUContext,
  resources_manager: ^resources.Manager,
  width, height: u32,
  color_format: vk.Format = .B8G8R8A8_SRGB,
) -> vk.Result {
  log.debugf("renderer ambient init %d x %d", width, height)
  pipeline_set_layouts := [?]vk.DescriptorSetLayout {
    resources_manager.camera_buffer_set_layout, // set = 0 (bindless camera buffer)
    resources_manager.textures_set_layout, // set = 1 (bindless textures)
  }
  push_constant_range := vk.PushConstantRange {
    stageFlags = {.FRAGMENT},
    size       = size_of(AmbientPushConstant),
  }
  vk.CreatePipelineLayout(
    gpu_context.device,
    &{
      sType = .PIPELINE_LAYOUT_CREATE_INFO,
      setLayoutCount = len(pipeline_set_layouts),
      pSetLayouts = raw_data(pipeline_set_layouts[:]),
      pushConstantRangeCount = 1,
      pPushConstantRanges = &push_constant_range,
    },
    nil,
    &self.ambient_pipeline_layout,
  ) or_return

  vert_shader_code := #load("../../shader/lighting_ambient/vert.spv")
  vert_module := gpu.create_shader_module(
    gpu_context,
    vert_shader_code,
  ) or_return
  defer vk.DestroyShaderModule(gpu_context.device, vert_module, nil)
  frag_shader_code := #load("../../shader/lighting_ambient/frag.spv")
  frag_module := gpu.create_shader_module(
    gpu_context,
    frag_shader_code,
  ) or_return
  defer vk.DestroyShaderModule(gpu_context.device, frag_module, nil)

  dynamic_states := [?]vk.DynamicState{.VIEWPORT, .SCISSOR}
  dynamic_state := vk.PipelineDynamicStateCreateInfo {
    sType             = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
    dynamicStateCount = len(dynamic_states),
    pDynamicStates    = raw_data(dynamic_states[:]),
  }
  input_assembly := vk.PipelineInputAssemblyStateCreateInfo {
    sType    = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
    topology = .TRIANGLE_LIST,
  }
  vertex_input := vk.PipelineVertexInputStateCreateInfo {
    sType = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
  }
  viewport_state := vk.PipelineViewportStateCreateInfo {
    sType         = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
    viewportCount = 1,
    scissorCount  = 1,
  }
  rasterizer := vk.PipelineRasterizationStateCreateInfo {
    sType       = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
    polygonMode = .FILL,
    lineWidth   = 1.0,
  }
  multisampling := vk.PipelineMultisampleStateCreateInfo {
    sType                = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
    rasterizationSamples = {._1},
  }
  color_blend_attachment := vk.PipelineColorBlendAttachmentState {
    colorWriteMask      = {.R, .G, .B, .A},
    blendEnable         = false,
    srcColorBlendFactor = .ONE,
    dstColorBlendFactor = .ZERO,
    colorBlendOp        = .ADD,
    srcAlphaBlendFactor = .ONE,
    dstAlphaBlendFactor = .ZERO,
    alphaBlendOp        = .ADD,
  }
  color_blending := vk.PipelineColorBlendStateCreateInfo {
    sType           = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
    attachmentCount = 1,
    pAttachments    = &color_blend_attachment,
  }
  depth_stencil := vk.PipelineDepthStencilStateCreateInfo {
    sType = .PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
  }
  color_formats := [?]vk.Format{color_format}
  rendering_info := vk.PipelineRenderingCreateInfo {
    sType                   = .PIPELINE_RENDERING_CREATE_INFO,
    colorAttachmentCount    = len(color_formats),
    pColorAttachmentFormats = raw_data(color_formats[:]),
  }
  shader_stages := [?]vk.PipelineShaderStageCreateInfo {
    {
      sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
      stage = {.VERTEX},
      module = vert_module,
      pName = "main",
    },
    {
      sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
      stage = {.FRAGMENT},
      module = frag_module,
      pName = "main",
    },
  }
  pipeline_info := vk.GraphicsPipelineCreateInfo {
    sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
    pNext               = &rendering_info,
    stageCount          = len(shader_stages),
    pStages             = raw_data(shader_stages[:]),
    pVertexInputState   = &vertex_input,
    pInputAssemblyState = &input_assembly,
    pViewportState      = &viewport_state,
    pRasterizationState = &rasterizer,
    pMultisampleState   = &multisampling,
    pColorBlendState    = &color_blending,
    pDynamicState       = &dynamic_state,
    pDepthStencilState  = &depth_stencil,
    layout              = self.ambient_pipeline_layout,
  }
  vk.CreateGraphicsPipelines(
    gpu_context.device,
    0,
    1,
    &pipeline_info,
    nil,
    &self.ambient_pipeline,
  ) or_return

  // Initialize environment resources
  environment_map: ^gpu.ImageBuffer
  self.environment_map, environment_map =
    resources.create_hdr_texture_from_path_with_mips(
      gpu_context,
      resources_manager,
      "assets/Cannon_Exterior.hdr",
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
  return .SUCCESS
}

ambient_shutdown :: proc(
  self: ^Renderer,
  gpu_context: ^gpu.GPUContext,
  resources_manager: ^resources.Manager,
) {
  vk.DestroyPipeline(gpu_context.device, self.ambient_pipeline, nil)
  self.ambient_pipeline = 0
  vk.DestroyPipelineLayout(
    gpu_context.device,
    self.ambient_pipeline_layout,
    nil,
  )
  self.ambient_pipeline_layout = 0
  // Clean up environment resources
  if item, freed := resources.free(
    &resources_manager.image_2d_buffers,
    self.environment_map,
  ); freed {
    gpu.image_buffer_detroy(gpu_context, item)
  }
  if item, freed := resources.free(
    &resources_manager.image_2d_buffers,
    self.brdf_lut,
  ); freed {
    gpu.image_buffer_detroy(gpu_context, item)
  }
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
}

lighting_init :: proc(
  self: ^Renderer,
  gpu_context: ^gpu.GPUContext,
  width, height: u32,
  color_format: vk.Format = .B8G8R8A8_SRGB,
  depth_format: vk.Format = .D32_SFLOAT,
  resources_manager: ^resources.Manager,
) -> vk.Result {
  log.debugf("renderer main init %d x %d", width, height)
  pipeline_set_layouts := [?]vk.DescriptorSetLayout {
    resources_manager.camera_buffer_set_layout,
    resources_manager.textures_set_layout,
  }
  push_constant_range := vk.PushConstantRange {
    stageFlags = {.VERTEX, .FRAGMENT},
    size       = size_of(LightPushConstant),
  }
  vk.CreatePipelineLayout(
    gpu_context.device,
    &vk.PipelineLayoutCreateInfo {
      sType = .PIPELINE_LAYOUT_CREATE_INFO,
      setLayoutCount = len(pipeline_set_layouts),
      pSetLayouts = raw_data(pipeline_set_layouts[:]),
      pushConstantRangeCount = 1,
      pPushConstantRanges = &push_constant_range,
    },
    nil,
    &self.lighting_pipeline_layout,
  ) or_return
  vert_shader_code := #load("../../shader/lighting/vert.spv")
  vert_module := gpu.create_shader_module(
    gpu_context,
    vert_shader_code,
  ) or_return
  defer vk.DestroyShaderModule(gpu_context.device, vert_module, nil)
  frag_shader_code := #load("../../shader/lighting/frag.spv")
  frag_module := gpu.create_shader_module(
    gpu_context,
    frag_shader_code,
  ) or_return
  defer vk.DestroyShaderModule(gpu_context.device, frag_module, nil)
  dynamic_states := [?]vk.DynamicState{.VIEWPORT, .SCISSOR, .DEPTH_COMPARE_OP}
  dynamic_state := vk.PipelineDynamicStateCreateInfo {
    sType             = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
    dynamicStateCount = len(dynamic_states),
    pDynamicStates    = raw_data(dynamic_states[:]),
  }
  input_assembly := vk.PipelineInputAssemblyStateCreateInfo {
    sType    = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
    topology = .TRIANGLE_LIST,
  }
  vertex_input := vk.PipelineVertexInputStateCreateInfo {
    sType                           = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
    vertexBindingDescriptionCount   = 1,
    pVertexBindingDescriptions      = &geometry.VERTEX_BINDING_DESCRIPTION[0],
    vertexAttributeDescriptionCount = 1, // Only position needed for lighting
    pVertexAttributeDescriptions    = &geometry.VERTEX_ATTRIBUTE_DESCRIPTIONS[0], // Position at location 0
  }
  viewport_state := vk.PipelineViewportStateCreateInfo {
    sType         = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
    viewportCount = 1,
    scissorCount  = 1,
  }
  rasterizer := vk.PipelineRasterizationStateCreateInfo {
    sType       = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
    polygonMode = .FILL,
    cullMode    = {.FRONT},
    frontFace   = .COUNTER_CLOCKWISE,
    lineWidth   = 1.0,
  }
  multisampling := vk.PipelineMultisampleStateCreateInfo {
    sType                = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
    rasterizationSamples = {._1},
  }
  color_blend_attachment := vk.PipelineColorBlendAttachmentState {
    colorWriteMask      = {.R, .G, .B, .A},
    blendEnable         = true,
    srcColorBlendFactor = .ONE,
    dstColorBlendFactor = .ONE,
    colorBlendOp        = .ADD,
    srcAlphaBlendFactor = .ONE,
    dstAlphaBlendFactor = .ONE,
    alphaBlendOp        = .ADD,
  }
  color_blending := vk.PipelineColorBlendStateCreateInfo {
    sType           = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
    attachmentCount = 1,
    pAttachments    = &color_blend_attachment,
  }
  depth_stencil := vk.PipelineDepthStencilStateCreateInfo {
    sType           = .PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
    depthTestEnable = true,
    // Greater or equal for point light, less or equal for spot light
    depthCompareOp  = .GREATER_OR_EQUAL,
  }
  color_formats := [?]vk.Format{color_format}
  rendering_info := vk.PipelineRenderingCreateInfo {
    sType                   = .PIPELINE_RENDERING_CREATE_INFO,
    colorAttachmentCount    = len(color_formats),
    pColorAttachmentFormats = raw_data(color_formats[:]),
    depthAttachmentFormat   = depth_format,
  }
  shader_stages := [?]vk.PipelineShaderStageCreateInfo {
    {
      sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
      stage = {.VERTEX},
      module = vert_module,
      pName = "main",
    },
    {
      sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
      stage = {.FRAGMENT},
      module = frag_module,
      pName = "main",
    },
  }
  pipeline_info := vk.GraphicsPipelineCreateInfo {
    sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
    pNext               = &rendering_info,
    stageCount          = len(shader_stages),
    pStages             = raw_data(shader_stages[:]),
    pVertexInputState   = &vertex_input,
    pInputAssemblyState = &input_assembly,
    pViewportState      = &viewport_state,
    pRasterizationState = &rasterizer,
    pMultisampleState   = &multisampling,
    pColorBlendState    = &color_blending,
    pDynamicState       = &dynamic_state,
    pDepthStencilState  = &depth_stencil,
    layout              = self.lighting_pipeline_layout,
  }
  vk.CreateGraphicsPipelines(
    gpu_context.device,
    0,
    1,
    &pipeline_info,
    nil,
    &self.lighting_pipeline,
  ) or_return
  log.info("Lighting pipeline initialized successfully")
  // light volume meshes
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

lighting_shutdown :: proc(self: ^Renderer, gpu_context: ^gpu.GPUContext) {
  vk.DestroyPipelineLayout(
    gpu_context.device,
    self.lighting_pipeline_layout,
    nil,
  )
  vk.DestroyPipeline(gpu_context.device, self.lighting_pipeline, nil)
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

lighting_begin_pass :: proc(
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

lighting_render :: proc(
  self: ^Renderer,
  input: []LightInfo,
  render_target: ^resources.RenderTarget,
  command_buffer: vk.CommandBuffer,
  resources_manager: ^resources.Manager,
  frame_index: u32,
) -> int {
  rendered_count := 0
  node_count := 0

  // Helper proc to bind and draw a mesh
  bind_and_draw_mesh :: proc(
    mesh_handle: resources.Handle,
    command_buffer: vk.CommandBuffer,
    resources_manager: ^resources.Manager,
  ) {
    mesh_ptr, ok := resources.get_mesh(resources_manager, mesh_handle)
    if !ok || mesh_ptr == nil {
      log.error("Failed to get mesh for handle", mesh_handle)
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

  for &light_info in input {
    node_count += 1
    light_info.scene_camera_idx = render_target.camera.index
    light_info.position_texture_index =
      resources.get_position_texture(render_target, frame_index).index
    light_info.normal_texture_index =
      resources.get_normal_texture(render_target, frame_index).index
    light_info.albedo_texture_index =
      resources.get_albedo_texture(render_target, frame_index).index
    light_info.metallic_texture_index =
      resources.get_metallic_roughness_texture(render_target, frame_index).index
    light_info.emissive_texture_index =
      resources.get_emissive_texture(render_target, frame_index).index
    light_info.depth_texture_index =
      resources.get_depth_texture(render_target, frame_index).index
    light_info.input_image_index =
      resources.get_final_image(render_target, frame_index).index

    switch light_info.light_kind {
    case .POINT:
      vk.CmdSetDepthCompareOp(command_buffer, .GREATER_OR_EQUAL)
      vk.CmdPushConstants(
        command_buffer,
        self.lighting_pipeline_layout,
        {.VERTEX, .FRAGMENT},
        0,
        size_of(LightPushConstant),
        &light_info.gpu_data,
      )
      bind_and_draw_mesh(self.sphere_mesh, command_buffer, resources_manager)
      rendered_count += 1

    case .DIRECTIONAL:
      vk.CmdSetDepthCompareOp(command_buffer, .GREATER_OR_EQUAL)
      vk.CmdPushConstants(
        command_buffer,
        self.lighting_pipeline_layout,
        {.VERTEX, .FRAGMENT},
        0,
        size_of(LightPushConstant),
        &light_info.gpu_data,
      )
      bind_and_draw_mesh(
        self.fullscreen_triangle_mesh,
        command_buffer,
        resources_manager,
      )
      rendered_count += 1

    case .SPOT:
      vk.CmdSetDepthCompareOp(command_buffer, .LESS_OR_EQUAL)
      vk.CmdPushConstants(
        command_buffer,
        self.lighting_pipeline_layout,
        {.VERTEX, .FRAGMENT},
        0,
        size_of(LightPushConstant),
        &light_info.gpu_data,
      )
      bind_and_draw_mesh(self.cone_mesh, command_buffer, resources_manager)
      rendered_count += 1
    }
  }
  return rendered_count
}

lighting_end_pass :: proc(command_buffer: vk.CommandBuffer) {
  vk.CmdEndRendering(command_buffer)
}

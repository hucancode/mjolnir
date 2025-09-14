package mjolnir

import "core:log"
import "core:slice"
import "gpu"
import "resource"
import vk "vendor:vulkan"

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

RendererAmbient :: struct {
  pipeline:            vk.Pipeline,
  pipeline_layout:     vk.PipelineLayout,
  // Environment resources (moved from lighting pass)
  environment_map:     Handle,
  brdf_lut:            Handle,
  environment_max_lod: f32,
  ibl_intensity:       f32,
}

ambient_begin :: proc(
  self: ^RendererAmbient,
  target: ^RenderTarget,
  command_buffer: vk.CommandBuffer,
  warehouse: ^ResourceWarehouse,
  frame_index: u32,
) {
  color_texture := resource.get(
    warehouse.image_2d_buffers,
    render_target_final_image(target, frame_index),
  )
  color_attachment := vk.RenderingAttachmentInfoKHR {
    sType = .RENDERING_ATTACHMENT_INFO_KHR,
    imageView = color_texture.view,
    imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
    loadOp = .CLEAR,
    storeOp = .STORE,
    clearValue = {color = {float32 = {0, 0, 0, 1}}},
  }
  render_info := vk.RenderingInfoKHR {
    sType = .RENDERING_INFO_KHR,
    renderArea = {extent = target.extent},
    layerCount = 1,
    colorAttachmentCount = 1,
    pColorAttachments = &color_attachment,
  }
  vk.CmdBeginRenderingKHR(command_buffer, &render_info)
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
    warehouse.camera_buffer_descriptor_set, // set = 0 (bindless camera buffer)
    warehouse.textures_descriptor_set, // set = 1 (bindless textures)
  }
  vk.CmdBindDescriptorSets(
    command_buffer,
    .GRAPHICS,
    self.pipeline_layout,
    0,
    len(descriptor_sets),
    raw_data(descriptor_sets[:]),
    0,
    nil,
  )
  vk.CmdBindPipeline(command_buffer, .GRAPHICS, self.pipeline)
}

ambient_render :: proc(
  self: ^RendererAmbient,
  render_target: ^RenderTarget,
  command_buffer: vk.CommandBuffer,
  warehouse: ^ResourceWarehouse,
  frame_index: u32,
) {
  // Use the same environment/IBL values as RendererMain (assume engine.ambient is initialized like main)
  // Use environment/BRDF LUT/IBL values from the main renderer (assume ambient renderer is initialized with these fields)
  push := AmbientPushConstant {
    camera_index           = render_target.camera.index,
    environment_index      = self.environment_map.index,
    brdf_lut_index         = self.brdf_lut.index,
    position_texture_index = render_target_position_texture(render_target, frame_index).index,
    normal_texture_index   = render_target_normal_texture(render_target, frame_index).index,
    albedo_texture_index   = render_target_albedo_texture(render_target, frame_index).index,
    metallic_texture_index = render_target_metallic_roughness_texture(render_target, frame_index).index,
    emissive_texture_index = render_target_emissive_texture(render_target, frame_index).index,
    depth_texture_index    = render_target_depth_texture(render_target, frame_index).index,
    environment_max_lod    = self.environment_max_lod,
    ibl_intensity          = self.ibl_intensity,
  }
  vk.CmdPushConstants(
    command_buffer,
    self.pipeline_layout,
    {.FRAGMENT},
    0,
    size_of(AmbientPushConstant),
    &push,
  )
  vk.CmdDraw(command_buffer, 3, 1, 0, 0) // fullscreen triangle
}

ambient_end :: proc(command_buffer: vk.CommandBuffer) {
  vk.CmdEndRenderingKHR(command_buffer)
}

ambient_init :: proc(
  self: ^RendererAmbient,
  gpu_context: ^gpu.GPUContext,
  warehouse: ^ResourceWarehouse,
  width, height: u32,
  color_format: vk.Format = .B8G8R8A8_SRGB,
) -> vk.Result {
  log.debugf("renderer ambient init %d x %d", width, height)
  pipeline_set_layouts := [?]vk.DescriptorSetLayout {
    warehouse.camera_buffer_set_layout, // set = 0 (bindless camera buffer)
    warehouse.textures_set_layout, // set = 1 (bindless textures)
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
    &self.pipeline_layout,
  ) or_return

  vert_shader_code := #load("shader/lighting_ambient/vert.spv")
  vert_module := gpu.create_shader_module(
    gpu_context,
    vert_shader_code,
  ) or_return
  defer vk.DestroyShaderModule(gpu_context.device, vert_module, nil)
  frag_shader_code := #load("shader/lighting_ambient/frag.spv")
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
    layout              = self.pipeline_layout,
  }
  vk.CreateGraphicsPipelines(
    gpu_context.device,
    0,
    1,
    &pipeline_info,
    nil,
    &self.pipeline,
  ) or_return

  // Initialize environment resources
  environment_map: ^gpu.ImageBuffer
  self.environment_map, environment_map =
    create_hdr_texture_from_path_with_mips(
      gpu_context,
      warehouse,
      "assets/Cannon_Exterior.hdr",
    ) or_return
  self.environment_max_lod = 8.0 // default fallback
  if environment_map != nil {
    self.environment_max_lod =
      calculate_mip_levels(environment_map.width, environment_map.height) - 1.0
  }
  brdf_lut: ^gpu.ImageBuffer
  self.brdf_lut, brdf_lut = create_texture(
    gpu_context,
    warehouse,
    #load("assets/lut_ggx.png"),
  ) or_return
  self.ibl_intensity = 1.0 // Default IBL intensity

  log.info("Ambient pipeline initialized successfully")
  return .SUCCESS
}

ambient_deinit :: proc(
  self: ^RendererAmbient,
  gpu_context: ^gpu.GPUContext,
  warehouse: ^ResourceWarehouse,
) {
  vk.DestroyPipeline(gpu_context.device, self.pipeline, nil)
  self.pipeline = 0
  vk.DestroyPipelineLayout(gpu_context.device, self.pipeline_layout, nil)
  self.pipeline_layout = 0
  // Clean up environment resources
  if item, freed := resource.free(
    &warehouse.image_2d_buffers,
    self.environment_map,
  ); freed {
    gpu.image_buffer_deinit(gpu_context, item)
  }
  if item, freed := resource.free(&warehouse.image_2d_buffers, self.brdf_lut);
     freed {
    gpu.image_buffer_deinit(gpu_context, item)
  }
}

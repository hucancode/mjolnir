package mjolnir

import "core:log"
import linalg "core:math/linalg"
import "core:slice"
import vk "vendor:vulkan"

AmbientPushConstant :: struct {
  camera_position:     [3]f32,
  environment_index:   u32,
  brdf_lut_index:      u32,
  environment_max_lod: f32,
  ibl_intensity:       f32,
}

RendererAmbient :: struct {
  pipeline:            vk.Pipeline,
  pipeline_layout:     vk.PipelineLayout,
  set_layout:          vk.DescriptorSetLayout,
  descriptor_sets:     [MAX_FRAMES_IN_FLIGHT]vk.DescriptorSet,
  environment_index:   u32,
  brdf_lut_index:      u32,
  environment_max_lod: f32,
  ibl_intensity:       f32,
}

renderer_ambient_begin :: proc(
  self: ^RendererAmbient,
  target: RenderTarget,
  command_buffer: vk.CommandBuffer,
) {
  color_attachment := vk.RenderingAttachmentInfoKHR {
    sType = .RENDERING_ATTACHMENT_INFO_KHR,
    imageView = target.final,
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
    self.descriptor_sets[g_frame_index], // set = 0 (gbuffer, etc)
    g_textures_descriptor_set, // set = 1 (bindless textures)
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

renderer_ambient_render :: proc(
  self: ^RendererAmbient,
  camera_position: linalg.Vector3f32,
  command_buffer: vk.CommandBuffer,
) {
  // Use the same environment/IBL values as RendererMain (assume engine.ambient is initialized like main)
  // Use environment/BRDF LUT/IBL values from the main renderer (assume ambient renderer is initialized with these fields)
  push := AmbientPushConstant {
    camera_position     = camera_position,
    environment_index   = self.environment_index,
    brdf_lut_index      = self.brdf_lut_index,
    environment_max_lod = self.environment_max_lod,
    ibl_intensity       = self.ibl_intensity,
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

renderer_ambient_end :: proc(command_buffer: vk.CommandBuffer) {
  vk.CmdEndRenderingKHR(command_buffer)
}

renderer_ambient_init :: proc(
  self: ^RendererAmbient,
  frames: ^[MAX_FRAMES_IN_FLIGHT]FrameData,
  width: u32,
  height: u32,
  color_format: vk.Format = .B8G8R8A8_SRGB,
) -> vk.Result {
  log.debugf("renderer ambient init %d x %d", width, height)
  bindings := [?]vk.DescriptorSetLayoutBinding {
    {   // Position
      binding         = 0,
      descriptorType  = .COMBINED_IMAGE_SAMPLER,
      descriptorCount = 1,
      stageFlags      = {.FRAGMENT},
    },
    {   // Normal
      binding         = 1,
      descriptorType  = .COMBINED_IMAGE_SAMPLER,
      descriptorCount = 1,
      stageFlags      = {.FRAGMENT},
    },
    {   // Albedo
      binding         = 2,
      descriptorType  = .COMBINED_IMAGE_SAMPLER,
      descriptorCount = 1,
      stageFlags      = {.FRAGMENT},
    },
    {   // Metallic Roughness
      binding         = 3,
      descriptorType  = .COMBINED_IMAGE_SAMPLER,
      descriptorCount = 1,
      stageFlags      = {.FRAGMENT},
    },
    {   // Emissive
      binding         = 4,
      descriptorType  = .COMBINED_IMAGE_SAMPLER,
      descriptorCount = 1,
      stageFlags      = {.FRAGMENT},
    },
  }
  set_layout_info := vk.DescriptorSetLayoutCreateInfo {
    sType        = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
    bindingCount = len(bindings),
    pBindings    = raw_data(bindings[:]),
  }
  vk.CreateDescriptorSetLayout(
    g_device,
    &set_layout_info,
    nil,
    &self.set_layout,
  ) or_return
  pipeline_set_layouts := [?]vk.DescriptorSetLayout {
    self.set_layout, // set = 0 (gbuffer)
    g_textures_set_layout, // set = 1 (bindless textures)
  }
  push_constant_range := vk.PushConstantRange {
    stageFlags = {.FRAGMENT},
    size       = size_of(AmbientPushConstant),
  }
  vk.CreatePipelineLayout(
    g_device,
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
  vert_module := create_shader_module(vert_shader_code) or_return
  defer vk.DestroyShaderModule(g_device, vert_module, nil)
  frag_shader_code := #load("shader/lighting_ambient/frag.spv")
  frag_module := create_shader_module(frag_shader_code) or_return
  defer vk.DestroyShaderModule(g_device, frag_module, nil)

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
    g_device,
    0,
    1,
    &pipeline_info,
    nil,
    &self.pipeline,
  ) or_return

  // Allocate and update descriptor sets for G-buffer
  set_layouts: [MAX_FRAMES_IN_FLIGHT]vk.DescriptorSetLayout
  slice.fill(set_layouts[:], self.set_layout)
  vk.AllocateDescriptorSets(
    g_device,
    &{
      sType = .DESCRIPTOR_SET_ALLOCATE_INFO,
      descriptorPool = g_descriptor_pool,
      descriptorSetCount = len(set_layouts),
      pSetLayouts = raw_data(set_layouts[:]),
    },
    auto_cast &self.descriptor_sets,
  ) or_return

  for frame, i in frames {
    writes := [?]vk.WriteDescriptorSet {
      {
        sType = .WRITE_DESCRIPTOR_SET,
        dstSet = self.descriptor_sets[i],
        dstBinding = 0,
        descriptorCount = 1,
        descriptorType = .COMBINED_IMAGE_SAMPLER,
        pImageInfo = &{
          sampler = g_linear_clamp_sampler,
          imageView = frame.gbuffer_position.view,
          imageLayout = .SHADER_READ_ONLY_OPTIMAL,
        },
      },
      {
        sType = .WRITE_DESCRIPTOR_SET,
        dstSet = self.descriptor_sets[i],
        dstBinding = 1,
        descriptorCount = 1,
        descriptorType = .COMBINED_IMAGE_SAMPLER,
        pImageInfo = &{
          sampler = g_linear_clamp_sampler,
          imageView = frame.gbuffer_normal.view,
          imageLayout = .SHADER_READ_ONLY_OPTIMAL,
        },
      },
      {
        sType = .WRITE_DESCRIPTOR_SET,
        dstSet = self.descriptor_sets[i],
        dstBinding = 2,
        descriptorCount = 1,
        descriptorType = .COMBINED_IMAGE_SAMPLER,
        pImageInfo = &{
          sampler = g_linear_clamp_sampler,
          imageView = frame.gbuffer_albedo.view,
          imageLayout = .SHADER_READ_ONLY_OPTIMAL,
        },
      },
      {
        sType = .WRITE_DESCRIPTOR_SET,
        dstSet = self.descriptor_sets[i],
        dstBinding = 3,
        descriptorCount = 1,
        descriptorType = .COMBINED_IMAGE_SAMPLER,
        pImageInfo = &{
          sampler = g_linear_clamp_sampler,
          imageView = frame.gbuffer_metallic_roughness.view,
          imageLayout = .SHADER_READ_ONLY_OPTIMAL,
        },
      },
      {
        sType = .WRITE_DESCRIPTOR_SET,
        dstSet = self.descriptor_sets[i],
        dstBinding = 4,
        descriptorCount = 1,
        descriptorType = .COMBINED_IMAGE_SAMPLER,
        pImageInfo = &{
          sampler = g_linear_clamp_sampler,
          imageView = frame.gbuffer_emissive.view,
          imageLayout = .SHADER_READ_ONLY_OPTIMAL,
        },
      },
    }
    vk.UpdateDescriptorSets(g_device, len(writes), raw_data(writes[:]), 0, nil)
  }
  log.info("Ambient pipeline initialized successfully")
  return .SUCCESS
}

renderer_ambient_recreate_images :: proc(
  self: ^RendererAmbient,
  frames: ^[MAX_FRAMES_IN_FLIGHT]FrameData,
  width: u32,
  height: u32,
  format: vk.Format,
) -> vk.Result {
  // Only update descriptor sets that reference G-buffer images
  // The pipeline and layouts can remain unchanged

  // Extract the same descriptor set update logic from init
  for frame, i in frames {
    writes := [?]vk.WriteDescriptorSet {
      {
        sType = .WRITE_DESCRIPTOR_SET,
        dstSet = self.descriptor_sets[i],
        dstBinding = 0,
        descriptorCount = 1,
        descriptorType = .COMBINED_IMAGE_SAMPLER,
        pImageInfo = &{
          sampler = g_linear_clamp_sampler,
          imageView = frame.gbuffer_position.view,
          imageLayout = .SHADER_READ_ONLY_OPTIMAL,
        },
      },
      {
        sType = .WRITE_DESCRIPTOR_SET,
        dstSet = self.descriptor_sets[i],
        dstBinding = 1,
        descriptorCount = 1,
        descriptorType = .COMBINED_IMAGE_SAMPLER,
        pImageInfo = &{
          sampler = g_linear_clamp_sampler,
          imageView = frame.gbuffer_normal.view,
          imageLayout = .SHADER_READ_ONLY_OPTIMAL,
        },
      },
      {
        sType = .WRITE_DESCRIPTOR_SET,
        dstSet = self.descriptor_sets[i],
        dstBinding = 2,
        descriptorCount = 1,
        descriptorType = .COMBINED_IMAGE_SAMPLER,
        pImageInfo = &{
          sampler = g_linear_clamp_sampler,
          imageView = frame.gbuffer_albedo.view,
          imageLayout = .SHADER_READ_ONLY_OPTIMAL,
        },
      },
      {
        sType = .WRITE_DESCRIPTOR_SET,
        dstSet = self.descriptor_sets[i],
        dstBinding = 3,
        descriptorCount = 1,
        descriptorType = .COMBINED_IMAGE_SAMPLER,
        pImageInfo = &{
          sampler = g_linear_clamp_sampler,
          imageView = frame.gbuffer_metallic_roughness.view,
          imageLayout = .SHADER_READ_ONLY_OPTIMAL,
        },
      },
      {
        sType = .WRITE_DESCRIPTOR_SET,
        dstSet = self.descriptor_sets[i],
        dstBinding = 4,
        descriptorCount = 1,
        descriptorType = .COMBINED_IMAGE_SAMPLER,
        pImageInfo = &{
          sampler = g_linear_clamp_sampler,
          imageView = frame.gbuffer_emissive.view,
          imageLayout = .SHADER_READ_ONLY_OPTIMAL,
        },
      },
    }
    // TODO: investigate this, why do we need this
    vk.DeviceWaitIdle(g_device)
    vk.UpdateDescriptorSets(g_device, len(writes), raw_data(writes[:]), 0, nil)
  }

  return .SUCCESS
}

renderer_ambient_deinit :: proc(self: ^RendererAmbient) {
  vk.DestroyPipeline(g_device, self.pipeline, nil)
  self.pipeline = 0
  vk.DestroyPipelineLayout(g_device, self.pipeline_layout, nil)
  self.pipeline_layout = 0
  vk.DestroyDescriptorSetLayout(g_device, self.set_layout, nil)
  self.set_layout = 0
}

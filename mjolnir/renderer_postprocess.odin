package mjolnir

import "core:log"
import vk "vendor:vulkan"

SHADER_POSTPROCESS_VERT :: #load("shader/postprocess/vert.spv")
SHADER_POSTPROCESS_FRAG :: #load("shader/postprocess/frag.spv")
SHADER_BLOOM_FRAG :: #load("shader/bloom/frag.spv")
SHADER_BLUR_FRAG :: #load("shader/blur/frag.spv")
SHADER_GRAYSCALE_FRAG :: #load("shader/grayscale/frag.spv")
SHADER_TONEMAP_FRAG :: #load("shader/tonemap/frag.spv")
SHADER_OUTLINE_FRAG :: #load("shader/outline/frag.spv")
SHADER_FOG_FRAG :: #load("shader/fog/frag.spv")

GrayscaleEffect :: struct {
  weights:  [3]f32,
  strength: f32,
}

ToneMapEffect :: struct {
  exposure: f32,
  gamma:    f32,
  padding:  [2]f32,
}

BlurEffect :: struct {
  radius:  f32,
  padding: [3]f32,
}

BloomEffect :: struct {
  threshold:   f32,
  intensity:   f32,
  blur_radius: f32,
  padding:     f32,
}

OutlineEffect :: struct {
  color:     [3]f32,
  thickness: f32,
}

FogEffect :: struct {
  color:     [3]f32,
  density:   f32,
  start:     f32,
  end:       f32,
  padding:   [2]f32,
}

PostProcessEffectType :: enum int {
  GRAYSCALE,
  TONEMAP,
  BLUR,
  BLOOM,
  OUTLINE,
  FOG,
  NONE,
}

PostprocessEffect :: union {
  GrayscaleEffect,
  ToneMapEffect,
  BlurEffect,
  BloomEffect,
  OutlineEffect,
  FogEffect,
}

RendererPostProcess :: struct {
  pipelines:              [len(PostProcessEffectType)]vk.Pipeline,
  pipeline_layouts:       [len(PostProcessEffectType)]vk.PipelineLayout,
  descriptor_sets:        [3]vk.DescriptorSet,
  descriptor_set_layouts: [1]vk.DescriptorSetLayout,
  sampler:                vk.Sampler,
  effect_stack:           [dynamic]PostprocessEffect,
  images:                 [2]ImageBuffer,
  depth_view:             vk.ImageView, // Store depth view for binding to all descriptor sets
  frames:                 [MAX_FRAMES_IN_FLIGHT]struct {
    image_available_semaphore: vk.Semaphore,
    render_finished_semaphore: vk.Semaphore,
    fence:                     vk.Fence,
    command_buffer:            vk.CommandBuffer,
    descriptor_set:            vk.DescriptorSet,
    postprocess_images:        [2]ImageBuffer,
  },
}

get_effect_type :: proc(effect: PostprocessEffect) -> PostProcessEffectType {
  switch _ in effect {
  case GrayscaleEffect:
    return .GRAYSCALE
  case ToneMapEffect:
    return .TONEMAP
  case BlurEffect:
    return .BLUR
  case BloomEffect:
    return .BLOOM
  case OutlineEffect:
    return .OUTLINE
  case FogEffect:
    return .FOG
  }
  return .NONE
}

effect_add_grayscale :: proc(
  self: ^RendererPostProcess,
  strength: f32 = 1.0,
  weights: [3]f32 = {0.299, 0.587, 0.114},
) {
  effect := GrayscaleEffect {
    strength = strength,
    weights  = weights,
  }
  append(&self.effect_stack, effect)
}

effect_add_blur :: proc(self: ^RendererPostProcess, radius: f32) {
  effect := BlurEffect {
    radius = radius,
  }
  append(&self.effect_stack, effect)
}

effect_add_bloom :: proc(
  self: ^RendererPostProcess,
  threshold: f32 = 0.2,
  intensity: f32 = 1.0,
  blur_radius: f32 = 4.0,
) {
  effect := BloomEffect {
    threshold   = threshold,
    intensity   = intensity,
    blur_radius = blur_radius,
  }
  append(&self.effect_stack, effect)
}

effect_add_tonemap :: proc(
  self: ^RendererPostProcess,
  exposure: f32 = 1.0,
  gamma: f32 = 2.2,
) {
  effect := ToneMapEffect {
    exposure = exposure,
    gamma    = gamma,
  }
  append(&self.effect_stack, effect)
}

effect_add_outline :: proc(
  self: ^RendererPostProcess,
  thickness: f32,
  color: [3]f32,
) {
  effect := OutlineEffect {
    thickness = thickness,
    color     = color,
  }
  append(&self.effect_stack, effect)
}

effect_add_fog :: proc(
  self: ^RendererPostProcess,
  color: [3]f32 = {0.7, 0.7, 0.8},
  density: f32 = 0.02,
  start: f32 = 10.0,
  end: f32 = 100.0,
) {
  effect := FogEffect {
    color   = color,
    density = density,
    start   = start,
    end     = end,
  }
  append(&self.effect_stack, effect)
}

effect_clear :: proc(self: ^RendererPostProcess) {
  resize(&self.effect_stack, 0)
}

postprocess_update_input :: proc(
  self: ^RendererPostProcess,
  set_idx: int,
  input_view: vk.ImageView,
) -> vk.Result {
  write := vk.WriteDescriptorSet {
    sType           = .WRITE_DESCRIPTOR_SET,
    dstSet          = self.descriptor_sets[set_idx],
    dstBinding      = 0,
    descriptorType  = .COMBINED_IMAGE_SAMPLER,
    descriptorCount = 1,
    pImageInfo      = &{
      sampler = g_nearest_repeat_sampler,
      imageView = input_view,
      imageLayout = .SHADER_READ_ONLY_OPTIMAL,
    },
  }
  vk.UpdateDescriptorSets(g_device, 1, &write, 0, nil)
  return .SUCCESS
}

postprocess_update_depth_input :: proc(
  self: ^RendererPostProcess,
  set_idx: int,
  depth_view: vk.ImageView,
) -> vk.Result {
  write := vk.WriteDescriptorSet {
    sType           = .WRITE_DESCRIPTOR_SET,
    dstSet          = self.descriptor_sets[set_idx],
    dstBinding      = 1,
    descriptorType  = .COMBINED_IMAGE_SAMPLER,
    descriptorCount = 1,
    pImageInfo      = &{
      sampler = g_nearest_repeat_sampler,
      imageView = depth_view,
      imageLayout = .DEPTH_STENCIL_READ_ONLY_OPTIMAL,
    },
  }
  vk.UpdateDescriptorSets(g_device, 1, &write, 0, nil)
  return .SUCCESS
}

renderer_postprocess_init :: proc(
  self: ^RendererPostProcess,
  color_format: vk.Format,
  width: u32,
  height: u32,
) -> vk.Result {
  self.effect_stack = make([dynamic]PostprocessEffect)
  count :: len(PostProcessEffectType)
  vert_module := create_shader_module(SHADER_POSTPROCESS_VERT) or_return
  defer vk.DestroyShaderModule(g_device, vert_module, nil)
  frag_modules: [count]vk.ShaderModule
  defer for m in frag_modules do vk.DestroyShaderModule(g_device, m, nil)
  for effect_type, i in PostProcessEffectType {
    shader_code: []u8
    switch effect_type {
    case .BLOOM:
      shader_code = SHADER_BLOOM_FRAG
    case .BLUR:
      shader_code = SHADER_BLUR_FRAG
    case .GRAYSCALE:
      shader_code = SHADER_GRAYSCALE_FRAG
    case .TONEMAP:
      shader_code = SHADER_TONEMAP_FRAG
    case .OUTLINE:
      shader_code = SHADER_OUTLINE_FRAG
    case .FOG:
      shader_code = SHADER_FOG_FRAG
    case .NONE:
      shader_code = SHADER_POSTPROCESS_FRAG
    }
    frag_modules[i] = create_shader_module(shader_code) or_return
  }
  color_blend_attachment := vk.PipelineColorBlendAttachmentState {
    colorWriteMask = {.R, .G, .B, .A},
  }
  color_blending := vk.PipelineColorBlendStateCreateInfo {
    sType           = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
    attachmentCount = 1,
    pAttachments    = &color_blend_attachment,
  }
  dynamic_states := [?]vk.DynamicState{.VIEWPORT, .SCISSOR}
  dynamic_state := vk.PipelineDynamicStateCreateInfo {
    sType             = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
    dynamicStateCount = len(dynamic_states),
    pDynamicStates    = raw_data(dynamic_states[:]),
  }
  color_formats := [?]vk.Format{color_format}
  rendering_info := vk.PipelineRenderingCreateInfoKHR {
    sType                   = .PIPELINE_RENDERING_CREATE_INFO_KHR,
    colorAttachmentCount    = len(color_formats),
    pColorAttachmentFormats = raw_data(color_formats[:]),
  }
  vertex_input := vk.PipelineVertexInputStateCreateInfo {
    sType = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
  }
  input_assembly := vk.PipelineInputAssemblyStateCreateInfo {
    sType    = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
    topology = .TRIANGLE_LIST,
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
  depth_stencil_state := vk.PipelineDepthStencilStateCreateInfo {
    sType            = .PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
    depthTestEnable  = false,
    depthWriteEnable = false,
  }
  bindings := [?]vk.DescriptorSetLayoutBinding {
    {
      binding = 0,
      descriptorType = .COMBINED_IMAGE_SAMPLER,
      descriptorCount = 1,
      stageFlags = {.FRAGMENT},
    },
    {
      binding = 1,
      descriptorType = .COMBINED_IMAGE_SAMPLER,
      descriptorCount = 1,
      stageFlags = {.FRAGMENT},
    },
  }
  layout_info := vk.DescriptorSetLayoutCreateInfo {
    sType        = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
    bindingCount = len(bindings),
    pBindings    = raw_data(bindings[:]),
  }
  for &set_layout in self.descriptor_set_layouts {
    vk.CreateDescriptorSetLayout(
      g_device,
      &layout_info,
      nil,
      &set_layout,
    ) or_return
  }
  for &set in self.descriptor_sets {
    vk.AllocateDescriptorSets(
      g_device,
      &{
        sType = .DESCRIPTOR_SET_ALLOCATE_INFO,
        descriptorPool = g_descriptor_pool,
        descriptorSetCount = len(self.descriptor_set_layouts),
        pSetLayouts = raw_data(self.descriptor_set_layouts[:]),
      },
      &set,
    ) or_return
  }
  for &image in self.images {
    image = malloc_image_buffer(
      width,
      height,
      color_format,
      .OPTIMAL,
      {.COLOR_ATTACHMENT, .SAMPLED, .TRANSFER_SRC, .TRANSFER_DST},
      {.DEVICE_LOCAL},
    ) or_return
    image.view = create_image_view(
      image.image,
      color_format,
      {.COLOR},
    ) or_return
  }
  shader_stages_arr: [count][2]vk.PipelineShaderStageCreateInfo
  pipeline_infos: [count]vk.GraphicsPipelineCreateInfo
  for effect_type, i in PostProcessEffectType {
    push_constant_size: u32
    switch effect_type {
    case .BLUR:
      push_constant_size = size_of(BlurEffect)
    case .OUTLINE:
      push_constant_size = size_of(OutlineEffect)
    case .GRAYSCALE:
      push_constant_size = size_of(GrayscaleEffect)
    case .BLOOM:
      push_constant_size = size_of(BloomEffect)
    case .TONEMAP:
      push_constant_size = size_of(ToneMapEffect)
    case .FOG:
      push_constant_size = size_of(FogEffect)
    case .NONE:
      push_constant_size = 0
    }
    push_constant_range := vk.PushConstantRange {
      stageFlags = {.FRAGMENT},
      size       = push_constant_size,
    }
    vk.CreatePipelineLayout(
      g_device,
      &{
        sType = .PIPELINE_LAYOUT_CREATE_INFO,
        setLayoutCount = len(self.descriptor_set_layouts),
        pSetLayouts = raw_data(self.descriptor_set_layouts[:]),
        pushConstantRangeCount = 1 if push_constant_size > 0 else 0,
        pPushConstantRanges = &push_constant_range,
      },
      nil,
      &self.pipeline_layouts[i],
    ) or_return
    shader_stages_arr[i] = [2]vk.PipelineShaderStageCreateInfo {
      {
        sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
        stage = {.VERTEX},
        module = vert_module,
        pName = "main",
      },
      {
        sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
        stage = {.FRAGMENT},
        module = frag_modules[i],
        pName = "main",
      },
    }
    pipeline_infos[i] = {
      sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
      pNext               = &rendering_info,
      stageCount          = len(shader_stages_arr[i]),
      pStages             = raw_data(shader_stages_arr[i][:]),
      pVertexInputState   = &vertex_input,
      pInputAssemblyState = &input_assembly,
      pViewportState      = &viewport_state,
      pRasterizationState = &rasterizer,
      pMultisampleState   = &multisampling,
      pColorBlendState    = &color_blending,
      pDepthStencilState  = &depth_stencil_state,
      pDynamicState       = &dynamic_state,
      layout              = self.pipeline_layouts[i],
    }
  }
  vk.CreateGraphicsPipelines(
    g_device,
    0,
    count,
    raw_data(pipeline_infos[:]),
    nil,
    raw_data(self.pipelines[:]),
  ) or_return
  log.info("Postprocess pipeline initialized successfully")
  for &frame in self.frames {
    vk.CreateSemaphore(
      g_device,
      &{sType = .SEMAPHORE_CREATE_INFO},
      nil,
      &frame.image_available_semaphore,
    ) or_return
    vk.CreateSemaphore(
      g_device,
      &{sType = .SEMAPHORE_CREATE_INFO},
      nil,
      &frame.render_finished_semaphore,
    ) or_return
    vk.CreateFence(
      g_device,
      &{sType = .FENCE_CREATE_INFO, flags = {.SIGNALED}},
      nil,
      &frame.fence,
    ) or_return
    vk.AllocateDescriptorSets(
      g_device,
      &{
        sType = .DESCRIPTOR_SET_ALLOCATE_INFO,
        descriptorPool = g_descriptor_pool,
        descriptorSetCount = 1,
        pSetLayouts = &self.descriptor_set_layouts[0],
      },
      &frame.descriptor_set,
    ) or_return
    for &image in frame.postprocess_images {
      image = malloc_image_buffer(
        width,
        height,
        color_format,
        .OPTIMAL,
        {.COLOR_ATTACHMENT, .SAMPLED, .TRANSFER_SRC, .TRANSFER_DST},
        {.DEVICE_LOCAL},
      ) or_return
      image.view = create_image_view(
        image.image,
        color_format,
        {.COLOR},
      ) or_return
    }
  }
  postprocess_update_input(self, 1, self.images[0].view)
  postprocess_update_input(self, 2, self.images[1].view)
  return .SUCCESS
}

renderer_postprocess_deinit :: proc(self: ^RendererPostProcess) {
  for &frame in self.frames {
    vk.DestroySemaphore(g_device, frame.image_available_semaphore, nil)
    vk.DestroySemaphore(g_device, frame.render_finished_semaphore, nil)
    vk.DestroyFence(g_device, frame.fence, nil)
    vk.FreeCommandBuffers(g_device, g_command_pool, 1, &frame.command_buffer)
    for &image in frame.postprocess_images {
      image_buffer_deinit(&image)
    }
    frame.descriptor_set = 0
  }
  for &p in self.pipelines {
    vk.DestroyPipeline(g_device, p, nil)
    p = 0
  }
  for &layout in self.pipeline_layouts {
    vk.DestroyPipelineLayout(g_device, layout, nil)
    layout = 0
  }
  for &layout in self.descriptor_set_layouts {
    vk.DestroyDescriptorSetLayout(g_device, layout, nil)
    layout = 0
  }
  delete(self.effect_stack)
  for &image in self.images do image_buffer_deinit(&image)
}

// Modular postprocess API
renderer_postprocess_begin :: proc(
  self: ^RendererPostProcess,
  command_buffer: vk.CommandBuffer,
  input_view: vk.ImageView,
  depth_view: vk.ImageView,
  extent: vk.Extent2D,
) {
  if len(self.effect_stack) == 0 {
    // if no postprocess effect, just copy the input to output
    append(&self.effect_stack, nil)
  }
  self.depth_view = depth_view
  postprocess_update_input(self, 0, input_view)
  postprocess_update_depth_input(self, 0, depth_view)
  postprocess_update_depth_input(self, 1, depth_view)
  postprocess_update_depth_input(self, 2, depth_view)
  viewport := vk.Viewport {
    width    = f32(extent.width),
    height   = f32(extent.height),
    minDepth = 0.0,
    maxDepth = 1.0,
  }
  scissor := vk.Rect2D {
    extent = extent,
  }
  vk.CmdSetViewport(command_buffer, 0, 1, &viewport)
  vk.CmdSetScissor(command_buffer, 0, 1, &scissor)
}

renderer_postprocess_render :: proc(
  self: ^RendererPostProcess,
  command_buffer: vk.CommandBuffer,
  extent: vk.Extent2D,
  output_view: vk.ImageView,
) {
  for effect, i in self.effect_stack {
    is_first := i == 0
    is_last := i == len(self.effect_stack) - 1
    src_idx := 0 if is_first else (i - 1) % 2 + 1
    dst_image_idx := i % 2
    src_image_idx := (i - 1) % 2
    // For the last pass, always sample from the last offscreen image
    if is_last && !is_first {
      postprocess_update_input(self, src_idx, self.images[src_image_idx].view)
      postprocess_update_depth_input(self, src_idx, self.depth_view)
    }
    // Prepare destination image for rendering
    if !is_last {
      prepare_image_for_render(
        command_buffer,
        self.images[dst_image_idx].image,
        .COLOR_ATTACHMENT_OPTIMAL,
      )
    } else {
      // For the last effect, output is the swapchain image, which should already be transitioned
    }
    if !is_first {
      prepare_image_for_shader_read(
        command_buffer,
        self.images[src_image_idx].image,
      )
    }
    color_attachment := vk.RenderingAttachmentInfoKHR {
      sType = .RENDERING_ATTACHMENT_INFO_KHR,
      imageView = self.images[dst_image_idx].view if !is_last else output_view,
      imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
      loadOp = .CLEAR,
      storeOp = .STORE,
      clearValue = {color = {float32 = BG_BLUE_GRAY}},
    }
    render_info := vk.RenderingInfoKHR {
      sType = .RENDERING_INFO_KHR,
      renderArea = {extent = extent},
      layerCount = 1,
      colorAttachmentCount = 1,
      pColorAttachments = &color_attachment,
    }
    vk.CmdBeginRenderingKHR(command_buffer, &render_info)
    effect_type := get_effect_type(effect)
    vk.CmdBindPipeline(command_buffer, .GRAPHICS, self.pipelines[effect_type])
    vk.CmdBindDescriptorSets(
      command_buffer,
      .GRAPHICS,
      self.pipeline_layouts[effect_type],
      0,
      1,
      &self.descriptor_sets[src_idx],
      0,
      nil,
    )
    switch &e in effect {
    case BlurEffect:
      vk.CmdPushConstants(
        command_buffer,
        self.pipeline_layouts[effect_type],
        {.FRAGMENT},
        0,
        size_of(BlurEffect),
        &e,
      )
    case GrayscaleEffect:
      vk.CmdPushConstants(
        command_buffer,
        self.pipeline_layouts[effect_type],
        {.FRAGMENT},
        0,
        size_of(GrayscaleEffect),
        &e,
      )
    case ToneMapEffect:
      vk.CmdPushConstants(
        command_buffer,
        self.pipeline_layouts[effect_type],
        {.FRAGMENT},
        0,
        size_of(ToneMapEffect),
        &e,
      )
    case BloomEffect:
      vk.CmdPushConstants(
        command_buffer,
        self.pipeline_layouts[effect_type],
        {.FRAGMENT},
        0,
        size_of(BloomEffect),
        &e,
      )
    case OutlineEffect:
      vk.CmdPushConstants(
        command_buffer,
        self.pipeline_layouts[effect_type],
        {.FRAGMENT},
        0,
        size_of(OutlineEffect),
        &e,
      )
    case FogEffect:
      vk.CmdPushConstants(
        command_buffer,
        self.pipeline_layouts[effect_type],
        {.FRAGMENT},
        0,
        size_of(FogEffect),
        &e,
      )
    }
    vk.CmdDraw(command_buffer, 3, 1, 0, 0)
    vk.CmdEndRenderingKHR(command_buffer)
  }
}

renderer_postprocess_end :: proc(
  self: ^RendererPostProcess,
  command_buffer: vk.CommandBuffer,
) {

}

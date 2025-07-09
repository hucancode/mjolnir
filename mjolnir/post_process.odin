package mjolnir

import "core:log"
import "resource"
import vk "vendor:vulkan"

SHADER_POSTPROCESS_VERT :: #load("shader/postprocess/vert.spv")
SHADER_POSTPROCESS_FRAG :: #load("shader/postprocess/frag.spv")
SHADER_BLOOM_FRAG :: #load("shader/bloom/frag.spv")
SHADER_BLUR_FRAG :: #load("shader/blur/frag.spv")
SHADER_GRAYSCALE_FRAG :: #load("shader/grayscale/frag.spv")
SHADER_TONEMAP_FRAG :: #load("shader/tonemap/frag.spv")
SHADER_OUTLINE_FRAG :: #load("shader/outline/frag.spv")
SHADER_FOG_FRAG :: #load("shader/fog/frag.spv")
SHADER_CROSSHATCH_FRAG :: #load("shader/crosshatch/frag.spv")
SHADER_DOF_FRAG :: #load("shader/dof/frag.spv")

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
  radius:         f32,
  direction:      f32, // 0.0 = horizontal, 1.0 = vertical
  weight_falloff: f32, // 0.0 = box blur, 1.0 = gaussian blur
  padding:        f32,
}

BloomEffect :: struct {
  threshold:   f32,
  intensity:   f32,
  blur_radius: f32,
  direction:   f32, // 0.0 = horizontal, 1.0 = vertical
}

OutlineEffect :: struct {
  color:     [3]f32,
  thickness: f32,
}

FogEffect :: struct {
  color:   [3]f32,
  density: f32,
  start:   f32,
  end:     f32,
  padding: [2]f32,
}

CrossHatchEffect :: struct {
  resolution:       [2]f32,
  hatch_offset_y:   f32,
  lum_threshold_01: f32,
  lum_threshold_02: f32,
  lum_threshold_03: f32,
  lum_threshold_04: f32,
  padding:          f32, // For alignment
}

DoFEffect :: struct {
  focus_distance:  f32, // Distance to the focus plane
  focus_range:     f32, // Range where objects are in focus
  blur_strength:   f32, // Maximum blur radius
  bokeh_intensity: f32, // Bokeh effect intensity
}

PostProcessEffectType :: enum int {
  GRAYSCALE,
  TONEMAP,
  BLUR,
  BLOOM,
  OUTLINE,
  FOG,
  CROSSHATCH,
  DOF,
  NONE,
}

PostprocessEffect :: union {
  GrayscaleEffect,
  ToneMapEffect,
  BlurEffect,
  BloomEffect,
  OutlineEffect,
  FogEffect,
  CrossHatchEffect,
  DoFEffect,
}

RendererPostProcess :: struct {
  pipelines:              [len(PostProcessEffectType)]vk.Pipeline,
  pipeline_layouts:       [len(PostProcessEffectType)]vk.PipelineLayout,
  descriptor_sets:        [3]vk.DescriptorSet,
  descriptor_set_layouts: [1]vk.DescriptorSetLayout,
  uniform_buffers:        [3]DataBuffer(GBufferIndicesUniform),
  effect_stack:           [dynamic]PostprocessEffect,
  images:                 [2]Handle,
  frames:                 [MAX_FRAMES_IN_FLIGHT]struct {
    image_available_semaphore: vk.Semaphore,
    render_finished_semaphore: vk.Semaphore,
    fence:                     vk.Fence,
    command_buffer:            vk.CommandBuffer,
    descriptor_set:            vk.DescriptorSet,
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
  case CrossHatchEffect:
    return .CROSSHATCH
  case DoFEffect:
    return .DOF
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

effect_add_blur :: proc(
  self: ^RendererPostProcess,
  radius: f32,
  gaussian: bool = true,
) {
  horizontal_effect := BlurEffect {
    radius         = radius,
    direction      = 0.0, // horizontal
    weight_falloff = 1.0 if gaussian else 0.0,
  }
  append(&self.effect_stack, horizontal_effect)
  vertical_effect := BlurEffect {
    radius         = radius,
    direction      = 1.0, // vertical
    weight_falloff = 1.0 if gaussian else 0.0,
  }
  append(&self.effect_stack, vertical_effect)
}

effect_add_directional_blur :: proc(
  self: ^RendererPostProcess,
  radius: f32,
  direction: f32 = 0.0, // 0.0 = horizontal, 1.0 = vertical
  gaussian: bool = true,
) {
  effect := BlurEffect {
    radius         = radius,
    direction      = direction,
    weight_falloff = 1.0 if gaussian else 0.0,
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
    direction   = 0.0, // horizontal
  }
  append(&self.effect_stack, effect)
  effect = BloomEffect {
    threshold   = threshold,
    intensity   = intensity,
    blur_radius = blur_radius,
    direction   = 1.0, // vertical
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

effect_add_crosshatch :: proc(
  self: ^RendererPostProcess,
  resolution: [2]f32,
  hatch_offset_y: f32 = 5.0,
  lum_threshold_01: f32 = 0.6,
  lum_threshold_02: f32 = 0.3,
  lum_threshold_03: f32 = 0.15,
  lum_threshold_04: f32 = 0.07,
) {
  effect := CrossHatchEffect {
    resolution       = resolution,
    hatch_offset_y   = hatch_offset_y,
    lum_threshold_01 = lum_threshold_01,
    lum_threshold_02 = lum_threshold_02,
    lum_threshold_03 = lum_threshold_03,
    lum_threshold_04 = lum_threshold_04,
  }
  append(&self.effect_stack, effect)
}

effect_add_dof :: proc(
  self: ^RendererPostProcess,
  focus_distance: f32 = 3.0,
  focus_range: f32 = 2.0,
  blur_strength: f32 = 20.0,
  bokeh_intensity: f32 = 0.5,
) {
  effect := DoFEffect {
    focus_distance  = focus_distance,
    focus_range     = focus_range,
    blur_strength   = blur_strength,
    bokeh_intensity = bokeh_intensity,
  }
  append(&self.effect_stack, effect)
}

effect_clear :: proc(self: ^RendererPostProcess) {
  resize(&self.effect_stack, 0)
}

postprocess_update_indices :: proc(
  self: ^RendererPostProcess,
  set_idx: int,
  frame: FrameData,
) -> vk.Result {
  for &b in self.uniform_buffers {
    u := data_buffer_get(&b)
    u.gbuffer_position_index = frame.gbuffer_position.index
    u.gbuffer_normal_index = frame.gbuffer_normal.index
    u.gbuffer_albedo_index = frame.gbuffer_albedo.index
    u.gbuffer_metallic_index = frame.gbuffer_metallic_roughness.index
    u.gbuffer_emissive_index = frame.gbuffer_emissive.index
    u.gbuffer_depth_index = frame.depth_buffer.index
  }
  u0 := data_buffer_get(&self.uniform_buffers[0])
  u1 := data_buffer_get(&self.uniform_buffers[1])
  u2 := data_buffer_get(&self.uniform_buffers[2])
  u0.input_image_index = frame.final_image.index
  u1.input_image_index = self.images[1].index
  u2.input_image_index = self.images[0].index
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
    case .CROSSHATCH:
      shader_code = SHADER_CROSSHATCH_FRAG
    case .DOF:
      shader_code = SHADER_DOF_FRAG
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
    sType = .PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
  }
  bindings := [?]vk.DescriptorSetLayoutBinding {
    {
      binding         = 0, // indices uniform buffer
      descriptorType  = .UNIFORM_BUFFER,
      descriptorCount = 1,
      stageFlags      = {.FRAGMENT},
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

  // Initialize uniform buffers
  for i in 0 ..< len(self.uniform_buffers) {
    self.uniform_buffers[i] = create_host_visible_buffer(
      GBufferIndicesUniform,
      1,
      {.UNIFORM_BUFFER},
    ) or_return

    write := vk.WriteDescriptorSet {
      sType           = .WRITE_DESCRIPTOR_SET,
      dstSet          = self.descriptor_sets[i],
      dstBinding      = 0,
      descriptorCount = 1,
      descriptorType  = .UNIFORM_BUFFER,
      pBufferInfo     = &{
        buffer = self.uniform_buffers[i].buffer,
        offset = 0,
        range = size_of(GBufferIndicesUniform),
      },
    }
    vk.UpdateDescriptorSets(g_device, 1, &write, 0, nil)
  }
  renderer_postprocess_create_images(
    self,
    width,
    height,
    color_format,
  ) or_return
  shader_stages: [count][2]vk.PipelineShaderStageCreateInfo
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
    case .CROSSHATCH:
      push_constant_size = size_of(CrossHatchEffect)
    case .DOF:
      push_constant_size = size_of(DoFEffect)
    case .NONE:
      push_constant_size = 0
    }
    push_constant_range := vk.PushConstantRange {
      stageFlags = {.FRAGMENT},
      size       = push_constant_size,
    }
    layout_sets := [?]vk.DescriptorSetLayout {
      self.descriptor_set_layouts[0], // set = 0 (indices uniform buffer)
      g_textures_set_layout, // set = 1 (bindless textures)
    }
    vk.CreatePipelineLayout(
      g_device,
      &{
        sType = .PIPELINE_LAYOUT_CREATE_INFO,
        setLayoutCount = len(layout_sets),
        pSetLayouts = raw_data(layout_sets[:]),
        pushConstantRangeCount = 1 if push_constant_size > 0 else 0,
        pPushConstantRanges = &push_constant_range,
      },
      nil,
      &self.pipeline_layouts[i],
    ) or_return
    shader_stages[i] = [2]vk.PipelineShaderStageCreateInfo {
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
      stageCount          = len(shader_stages[i]),
      pStages             = raw_data(shader_stages[i][:]),
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
  }
  return .SUCCESS
}

renderer_postprocess_create_images :: proc(
  self: ^RendererPostProcess,
  width: u32,
  height: u32,
  format: vk.Format,
) -> vk.Result {
  for &handle in self.images {
    handle, _ = create_empty_texture_2d(
      width,
      height,
      format,
      {.COLOR_ATTACHMENT, .SAMPLED, .TRANSFER_SRC, .TRANSFER_DST},
    ) or_return
  }
  log.debugf("created post-process image")
  return .SUCCESS
}

renderer_postprocess_deinit_images :: proc(self: ^RendererPostProcess) {
  for handle in self.images {
    resource.free(&g_image_2d_buffers, handle, image_buffer_deinit)
  }
}

renderer_postprocess_recreate_images :: proc(
  self: ^RendererPostProcess,
  width: u32,
  height: u32,
  format: vk.Format,
) -> vk.Result {
  renderer_postprocess_deinit_images(self)
  return renderer_postprocess_create_images(self, width, height, format)
}

renderer_postprocess_deinit :: proc(self: ^RendererPostProcess) {
  for &buffer in self.uniform_buffers {
    data_buffer_deinit(&buffer)
  }
  for &frame in self.frames {
    vk.DestroySemaphore(g_device, frame.image_available_semaphore, nil)
    vk.DestroySemaphore(g_device, frame.render_finished_semaphore, nil)
    vk.DestroyFence(g_device, frame.fence, nil)
    vk.FreeCommandBuffers(g_device, g_command_pool, 1, &frame.command_buffer)
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
  renderer_postprocess_deinit_images(self)
}

// Modular postprocess API
renderer_postprocess_begin :: proc(
  self: ^RendererPostProcess,
  command_buffer: vk.CommandBuffer,
  frame: FrameData,
  extent: vk.Extent2D,
) {
  if len(self.effect_stack) == 0 {
    // if no postprocess effect, just copy the input to output
    append(&self.effect_stack, nil)
  }

  // Update indices for all descriptor sets
  for i in 0 ..< len(self.descriptor_sets) {
    postprocess_update_indices(self, i, frame)
  }

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

    // Simple ping-pong logic:
    // Pass 0: reads from original input (descriptor_set[0]), writes to image[0]
    // Pass 1: reads from image[0] (descriptor_set[2]), writes to image[1]
    // Pass 2: reads from image[1] (descriptor_set[1]), writes to image[0]
    // etc.

    src_idx: u32
    dst_image_idx: u32

    if is_first {
      src_idx = 0 // Use original input
      dst_image_idx = 0 // Write to image[0]
    } else {
      prev_dst_image_idx := (i - 1) % 2
      if prev_dst_image_idx == 0 {
        src_idx = 2 // Read from image[0] using descriptor_set[2]
      } else {
        src_idx = 1 // Read from image[1] using descriptor_set[1]
      }
      dst_image_idx = u32(i % 2) // Alternate between image[0] and image[1]
    }

    // Ping-pong logic:
    // Pass 0: input -> image[0]     (src: original input, dst: image[0])
    // Pass 1: image[0] -> image[1]  (src: image[0], dst: image[1])
    // Pass 2: image[1] -> image[0]  (src: image[1], dst: image[0])
    // Pass N: image[(N+1)%2] -> swapchain (src: image[(N-1)%2], dst: swapchain)

    dst_view := output_view
    if !is_last {
      dst_texture := resource.get(
        g_image_2d_buffers,
        self.images[dst_image_idx],
      )
      transition_image(
        command_buffer,
        dst_texture.image,
        .UNDEFINED,
        .COLOR_ATTACHMENT_OPTIMAL,
        {.COLOR},
        {.TOP_OF_PIPE},
        {.COLOR_ATTACHMENT_OUTPUT},
        {},
        {.COLOR_ATTACHMENT_WRITE},
      )
      dst_view = dst_texture.view
    } else {
      // For the last effect, output is the swapchain image, which should already be transitioned
    }
    if !is_first {
      src_texture_idx := (i - 1) % 2 // Which ping-pong buffer the previous pass wrote to
      src_texture := resource.get(
        g_image_2d_buffers,
        self.images[src_texture_idx],
      )
      transition_image_to_shader_read(command_buffer, src_texture.image)
    }
    color_attachment := vk.RenderingAttachmentInfoKHR {
      sType = .RENDERING_ATTACHMENT_INFO_KHR,
      imageView = dst_view,
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
    descriptor_sets := [?]vk.DescriptorSet {
      self.descriptor_sets[src_idx], // set 0 = inputs
      g_textures_descriptor_set, // set = 1 (bindless textures)
    }
    vk.CmdBindDescriptorSets(
      command_buffer,
      .GRAPHICS,
      self.pipeline_layouts[effect_type],
      0,
      len(descriptor_sets),
      raw_data(descriptor_sets[:]),
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
    case CrossHatchEffect:
      vk.CmdPushConstants(
        command_buffer,
        self.pipeline_layouts[effect_type],
        {.FRAGMENT},
        0,
        size_of(CrossHatchEffect),
        &e,
      )
    case DoFEffect:
      vk.CmdPushConstants(
        command_buffer,
        self.pipeline_layouts[effect_type],
        {.FRAGMENT},
        0,
        size_of(DoFEffect),
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

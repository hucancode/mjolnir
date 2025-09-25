package mjolnir

import "core:log"
import "gpu"
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

// Combined push constant structures for each effect type
GrayscalePushConstant :: struct {
  using base: BasePushConstant,
  // Effect parameters
  weights:    [3]f32,
  strength:   f32,
}

ToneMapPushConstant :: struct {
  using base: BasePushConstant,
  // Effect parameters
  exposure:   f32,
  gamma:      f32,
}

BlurPushConstant :: struct {
  using base:     BasePushConstant,
  // Effect parameters
  radius:         f32,
  direction:      f32,
  weight_falloff: f32,
}

BloomPushConstant :: struct {
  using base:  BasePushConstant,
  // Effect parameters
  threshold:   f32,
  intensity:   f32,
  blur_radius: f32,
  direction:   f32,
}

OutlinePushConstant :: struct {
  using base: BasePushConstant,
  // Effect parameters
  color:      [3]f32,
  thickness:  f32,
}

FogPushConstant :: struct {
  using base: BasePushConstant,
  // Effect parameters
  color:      [4]f32, // Changed from [3]f32 to [4]f32 to match GLSL vec4
  density:    f32,
  start:      f32,
  end:        f32,
}

CrossHatchPushConstant :: struct {
  using base:       BasePushConstant,
  // Effect parameters
  resolution:       [2]f32,
  hatch_offset_y:   f32,
  lum_threshold_01: f32,
  lum_threshold_02: f32,
  lum_threshold_03: f32,
  lum_threshold_04: f32,
}

DoFPushConstant :: struct {
  using base:      BasePushConstant,
  // Effect parameters
  focus_distance:  f32,
  focus_range:     f32,
  blur_strength:   f32,
  bokeh_intensity: f32,
}

BasePushConstant :: struct {
  position_texture_index: u32,
  normal_texture_index:   u32,
  albedo_texture_index:   u32,
  metallic_texture_index: u32,
  emissive_texture_index: u32,
  depth_texture_index:    u32,
  input_image_index:      u32,
  padding:                u32, // Add padding to align to 16-byte boundary for next vec4
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
  pipelines:        [len(PostProcessEffectType)]vk.Pipeline,
  pipeline_layouts: [len(PostProcessEffectType)]vk.PipelineLayout,
  effect_stack:     [dynamic]PostprocessEffect,
  images:           [2]Handle,
  frames:           [MAX_FRAMES_IN_FLIGHT]struct {
    image_available_semaphore: vk.Semaphore,
    render_finished_semaphore: vk.Semaphore,
    fence:                     vk.Fence,
    command_buffer:            vk.CommandBuffer,
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

postprocess_init :: proc(
  self: ^RendererPostProcess,
  gpu_context: ^gpu.GPUContext,
  color_format: vk.Format,
  width, height: u32,
  warehouse: ^ResourceWarehouse,
) -> vk.Result {
  self.effect_stack = make([dynamic]PostprocessEffect)
  count :: len(PostProcessEffectType)
  vert_module := gpu.create_shader_module(
    gpu_context,
    SHADER_POSTPROCESS_VERT,
  ) or_return
  defer vk.DestroyShaderModule(gpu_context.device, vert_module, nil)
  frag_modules: [count]vk.ShaderModule
  defer for m in frag_modules do vk.DestroyShaderModule(gpu_context.device, m, nil)
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
    frag_modules[i] = gpu.create_shader_module(
      gpu_context,
      shader_code,
    ) or_return
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
  rendering_info := vk.PipelineRenderingCreateInfo{
    sType                   = .PIPELINE_RENDERING_CREATE_INFO,
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
  postprocess_create_images(
    gpu_context,
    self,
    warehouse,
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
      push_constant_size = size_of(BlurPushConstant)
    case .OUTLINE:
      push_constant_size = size_of(OutlinePushConstant)
    case .GRAYSCALE:
      push_constant_size = size_of(GrayscalePushConstant)
    case .BLOOM:
      push_constant_size = size_of(BloomPushConstant)
    case .TONEMAP:
      push_constant_size = size_of(ToneMapPushConstant)
    case .FOG:
      push_constant_size = size_of(FogPushConstant)
    case .CROSSHATCH:
      push_constant_size = size_of(CrossHatchPushConstant)
    case .DOF:
      push_constant_size = size_of(DoFPushConstant)
    case .NONE:
      push_constant_size = size_of(BasePushConstant)
    }
    push_constant_ranges := [?]vk.PushConstantRange {
      {stageFlags = {.FRAGMENT}, offset = 0, size = push_constant_size},
    }

    layout_sets := [?]vk.DescriptorSetLayout {
      warehouse.textures_set_layout, // set = 0 (bindless textures)
    }
    vk.CreatePipelineLayout(
      gpu_context.device,
      &{
        sType = .PIPELINE_LAYOUT_CREATE_INFO,
        setLayoutCount = len(layout_sets),
        pSetLayouts = raw_data(layout_sets[:]),
        pushConstantRangeCount = 1 if push_constant_size > 0 else 0,
        pPushConstantRanges = raw_data(push_constant_ranges[:]),
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
    gpu_context.device,
    0,
    count,
    raw_data(pipeline_infos[:]),
    nil,
    raw_data(self.pipelines[:]),
  ) or_return
  log.info("Postprocess pipeline initialized successfully")
  for &frame in self.frames {
    vk.CreateSemaphore(
      gpu_context.device,
      &{sType = .SEMAPHORE_CREATE_INFO},
      nil,
      &frame.image_available_semaphore,
    ) or_return
    vk.CreateSemaphore(
      gpu_context.device,
      &{sType = .SEMAPHORE_CREATE_INFO},
      nil,
      &frame.render_finished_semaphore,
    ) or_return
    vk.CreateFence(
      gpu_context.device,
      &{sType = .FENCE_CREATE_INFO, flags = {.SIGNALED}},
      nil,
      &frame.fence,
    ) or_return
  }
  return .SUCCESS
}

postprocess_create_images :: proc(
  gpu_context: ^gpu.GPUContext,
  self: ^RendererPostProcess,
  warehouse: ^ResourceWarehouse,
  width, height: u32,
  format: vk.Format,
) -> vk.Result {
  for &handle in self.images {
    handle, _ = create_texture(
      gpu_context,
      warehouse,
      width,
      height,
      format,
      vk.ImageUsageFlags{.COLOR_ATTACHMENT, .SAMPLED, .TRANSFER_SRC, .TRANSFER_DST},
    ) or_return
  }
  log.debugf("created post-process image")
  return .SUCCESS
}

postprocess_deinit_images :: proc(
  self: ^RendererPostProcess,
  gpu_context: ^gpu.GPUContext,
  warehouse: ^ResourceWarehouse,
) {
  for handle in self.images {
    if item, freed := resource.free(&warehouse.image_2d_buffers, handle);
       freed {
      gpu.image_buffer_deinit(gpu_context, item)
    }
  }
}

postprocess_recreate_images :: proc(
  gpu_context: ^gpu.GPUContext,
  self: ^RendererPostProcess,
  width, height: u32,
  format: vk.Format,
  warehouse: ^ResourceWarehouse,
) -> vk.Result {
  postprocess_deinit_images(self, gpu_context, warehouse)
  return postprocess_create_images(
    gpu_context,
    self,
    warehouse,
    width,
    height,
    format,
  )
}

postprocess_deinit :: proc(
  self: ^RendererPostProcess,
  gpu_context: ^gpu.GPUContext,
  warehouse: ^ResourceWarehouse,
) {
  for &frame in self.frames {
    vk.DestroySemaphore(
      gpu_context.device,
      frame.image_available_semaphore,
      nil,
    )
    vk.DestroySemaphore(
      gpu_context.device,
      frame.render_finished_semaphore,
      nil,
    )
    vk.DestroyFence(gpu_context.device, frame.fence, nil)
    vk.FreeCommandBuffers(
      gpu_context.device,
      gpu_context.command_pool,
      1,
      &frame.command_buffer,
    )
  }
  for &p in self.pipelines {
    vk.DestroyPipeline(gpu_context.device, p, nil)
    p = 0
  }
  for &layout in self.pipeline_layouts {
    vk.DestroyPipelineLayout(gpu_context.device, layout, nil)
    layout = 0
  }
  delete(self.effect_stack)
  postprocess_deinit_images(self, gpu_context, warehouse)
}

// Modular postprocess API
postprocess_begin :: proc(
  self: ^RendererPostProcess,
  command_buffer: vk.CommandBuffer,
  extent: vk.Extent2D,
) {
  if len(self.effect_stack) == 0 {
    // if no postprocess effect, just copy the input to output
    append(&self.effect_stack, nil)
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

postprocess_render :: proc(
  self: ^RendererPostProcess,
  command_buffer: vk.CommandBuffer,
  extent: vk.Extent2D,
  output_view: vk.ImageView,
  render_target: ^RenderTarget,
  warehouse: ^ResourceWarehouse,
  frame_index: u32,
) {
  for effect, i in self.effect_stack {
    is_first := i == 0
    is_last := i == len(self.effect_stack) - 1

    // Simple ping-pong logic:
    // Pass 0: reads from original input (final_image), writes to image[0]
    // Pass 1: reads from image[0], writes to image[1]
    // Pass 2: reads from image[1], writes to image[0]
    // etc.

    input_image_index: u32
    dst_image_idx: u32

    if is_first {
      input_image_index = get_final_image(render_target, frame_index).index // Use original input
      dst_image_idx = 0 // Write to image[0]
    } else {
      prev_dst_image_idx := (i - 1) % 2
      input_image_index = self.images[prev_dst_image_idx].index // Read from previous output
      dst_image_idx = u32(i % 2) // Alternate between image[0] and image[1]
    }

    // Ping-pong logic:
    // Pass 0: input -> image[0]     (src: original input, dst: image[0])
    // Pass 1: image[0] -> image[1]  (src: image[0], dst: image[1])
    // Pass 2: image[1] -> image[0]  (src: image[1], dst: image[0])
    // Pass N: image[(N+1)%2] -> swapchain (src: image[(N-1)%2], dst: swapchain)

    dst_view := output_view
    if !is_last {
      dst_texture := image_2d(warehouse, self.images[dst_image_idx])
      gpu.transition_image(
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
        warehouse.image_2d_buffers,
        self.images[src_texture_idx],
      )
      gpu.transition_image_to_shader_read(command_buffer, src_texture.image)
    }
    color_attachment := vk.RenderingAttachmentInfo{
      sType = .RENDERING_ATTACHMENT_INFO,
      imageView = dst_view,
      imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
      loadOp = .CLEAR,
      storeOp = .STORE,
      clearValue = {color = {float32 = BG_BLUE_GRAY}},
    }
    render_info := vk.RenderingInfo{
      sType = .RENDERING_INFO,
      renderArea = {extent = extent},
      layerCount = 1,
      colorAttachmentCount = 1,
      pColorAttachments = &color_attachment,
    }
    vk.CmdBeginRendering(command_buffer, &render_info)
    effect_type := get_effect_type(effect)
    vk.CmdBindPipeline(command_buffer, .GRAPHICS, self.pipelines[effect_type])

    // Bind textures descriptor set
    descriptor_sets := [?]vk.DescriptorSet {
      warehouse.textures_descriptor_set, // set = 0 (bindless textures)
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
    base: BasePushConstant
    base.position_texture_index =
      get_position_texture(render_target, frame_index).index
    base.normal_texture_index =
      get_normal_texture(render_target, frame_index).index
    base.albedo_texture_index =
      get_albedo_texture(render_target, frame_index).index
    base.metallic_texture_index =
      get_metallic_roughness_texture(render_target, frame_index).index
    base.emissive_texture_index =
      get_emissive_texture(render_target, frame_index).index
    base.depth_texture_index =
      get_depth_texture(render_target, frame_index).index
    base.input_image_index = input_image_index
    // Create and push combined push constants based on effect type
    switch &e in effect {
    case BlurEffect:
      push_constant := BlurPushConstant {
        radius         = e.radius,
        direction      = e.direction,
        weight_falloff = e.weight_falloff,
      }
      push_constant.base = base
      vk.CmdPushConstants(
        command_buffer,
        self.pipeline_layouts[effect_type],
        {.FRAGMENT},
        0,
        size_of(BlurPushConstant),
        &push_constant,
      )
    case GrayscaleEffect:
      push_constant := GrayscalePushConstant {
        weights  = e.weights,
        strength = e.strength,
      }
      push_constant.base = base
      vk.CmdPushConstants(
        command_buffer,
        self.pipeline_layouts[effect_type],
        {.FRAGMENT},
        0,
        size_of(GrayscalePushConstant),
        &push_constant,
      )
    case ToneMapEffect:
      push_constant := ToneMapPushConstant {
        exposure = e.exposure,
        gamma    = e.gamma,
      }
      push_constant.base = base
      vk.CmdPushConstants(
        command_buffer,
        self.pipeline_layouts[effect_type],
        {.FRAGMENT},
        0,
        size_of(ToneMapPushConstant),
        &push_constant,
      )
    case BloomEffect:
      push_constant := BloomPushConstant {
        threshold   = e.threshold,
        intensity   = e.intensity,
        blur_radius = e.blur_radius,
        direction   = e.direction,
      }
      push_constant.base = base
      vk.CmdPushConstants(
        command_buffer,
        self.pipeline_layouts[effect_type],
        {.FRAGMENT},
        0,
        size_of(BloomPushConstant),
        &push_constant,
      )
    case OutlineEffect:
      push_constant := OutlinePushConstant {
        color     = e.color,
        thickness = e.thickness,
      }
      push_constant.base = base
      vk.CmdPushConstants(
        command_buffer,
        self.pipeline_layouts[effect_type],
        {.FRAGMENT},
        0,
        size_of(OutlinePushConstant),
        &push_constant,
      )
    case FogEffect:
      push_constant: FogPushConstant
      push_constant.base = base
      push_constant.color = {e.color.x, e.color.y, e.color.z, 1.0} // Convert [3]f32 to [4]f32
      push_constant.density = e.density
      push_constant.start = e.start
      push_constant.end = e.end
      vk.CmdPushConstants(
        command_buffer,
        self.pipeline_layouts[effect_type],
        {.FRAGMENT},
        0,
        size_of(FogPushConstant),
        &push_constant,
      )
    case CrossHatchEffect:
      push_constant := CrossHatchPushConstant {
        resolution       = e.resolution,
        hatch_offset_y   = e.hatch_offset_y,
        lum_threshold_01 = e.lum_threshold_01,
        lum_threshold_02 = e.lum_threshold_02,
        lum_threshold_03 = e.lum_threshold_03,
        lum_threshold_04 = e.lum_threshold_04,
      }
      push_constant.base = base
      vk.CmdPushConstants(
        command_buffer,
        self.pipeline_layouts[effect_type],
        {.FRAGMENT},
        0,
        size_of(CrossHatchPushConstant),
        &push_constant,
      )
    case DoFEffect:
      push_constant := DoFPushConstant {
        focus_distance  = e.focus_distance,
        focus_range     = e.focus_range,
        blur_strength   = e.blur_strength,
        bokeh_intensity = e.bokeh_intensity,
      }
      push_constant.base = base
      vk.CmdPushConstants(
        command_buffer,
        self.pipeline_layouts[effect_type],
        {.FRAGMENT},
        0,
        size_of(DoFPushConstant),
        &push_constant,
      )
    case:
      // No effect or nil effect - just copy input to output
      vk.CmdPushConstants(
        command_buffer,
        self.pipeline_layouts[effect_type],
        {.FRAGMENT},
        0,
        size_of(BasePushConstant),
        &base,
      )
    }
    vk.CmdDraw(command_buffer, 3, 1, 0, 0)
    vk.CmdEndRendering(command_buffer)
  }
}

postprocess_end :: proc(
  self: ^RendererPostProcess,
  command_buffer: vk.CommandBuffer,
) {

}

package post_process

import "../../gpu"
import "../../resources"
import "../shared"
import "core:log"
import vk "vendor:vulkan"

SHADER_POSTPROCESS_VERT :: #load("../../shader/postprocess/vert.spv")
SHADER_POSTPROCESS_FRAG :: #load("../../shader/postprocess/frag.spv")
SHADER_BLOOM_FRAG :: #load("../../shader/bloom/frag.spv")
SHADER_BLUR_FRAG :: #load("../../shader/blur/frag.spv")
SHADER_GRAYSCALE_FRAG :: #load("../../shader/grayscale/frag.spv")
SHADER_TONEMAP_FRAG :: #load("../../shader/tonemap/frag.spv")
SHADER_OUTLINE_FRAG :: #load("../../shader/outline/frag.spv")
SHADER_FOG_FRAG :: #load("../../shader/fog/frag.spv")
SHADER_CROSSHATCH_FRAG :: #load("../../shader/crosshatch/frag.spv")
SHADER_DOF_FRAG :: #load("../../shader/dof/frag.spv")

BG_BLUE_GRAY :: [4]f32{0.0117, 0.0117, 0.0179, 1.0}
BG_DARK_GRAY :: [4]f32{0.0117, 0.0117, 0.0117, 1.0}
BG_ORANGE_GRAY :: [4]f32{0.0179, 0.0179, 0.0117, 1.0}

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
  padding:          f32,
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

Renderer :: struct {
  pipelines:        [len(PostProcessEffectType)]vk.Pipeline,
  pipeline_layouts: [len(PostProcessEffectType)]vk.PipelineLayout,
  effect_stack:     [dynamic]PostprocessEffect,
  images:           [2]resources.Handle,
  commands:         [resources.MAX_FRAMES_IN_FLIGHT]vk.CommandBuffer,
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

add_grayscale :: proc(
  self: ^Renderer,
  strength: f32 = 1.0,
  weights: [3]f32 = {0.299, 0.587, 0.114},
) {
  effect := GrayscaleEffect {
    strength = strength,
    weights  = weights,
  }
  append(&self.effect_stack, effect)
}

add_blur :: proc(self: ^Renderer, radius: f32, gaussian: bool = true) {
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

add_directional_blur :: proc(
  self: ^Renderer,
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

add_bloom :: proc(
  self: ^Renderer,
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

add_tonemap :: proc(self: ^Renderer, exposure: f32 = 1.0, gamma: f32 = 2.2) {
  effect := ToneMapEffect {
    exposure = exposure,
    gamma    = gamma,
  }
  append(&self.effect_stack, effect)
}

add_outline :: proc(self: ^Renderer, thickness: f32, color: [3]f32) {
  effect := OutlineEffect {
    thickness = thickness,
    color     = color,
  }
  append(&self.effect_stack, effect)
}

add_fog :: proc(
  self: ^Renderer,
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

add_crosshatch :: proc(
  self: ^Renderer,
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

add_dof :: proc(
  self: ^Renderer,
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

clear_effects :: proc(self: ^Renderer) {
  clear(&self.effect_stack)
}

effect_clear :: proc(self: ^Renderer) {
  resize(&self.effect_stack, 0)
}

init :: proc(
  self: ^Renderer,
  gctx: ^gpu.GPUContext,
  color_format: vk.Format,
  width, height: u32,
  rm: ^resources.Manager,
) -> vk.Result {
  vk.AllocateCommandBuffers(
    gctx.device,
    &vk.CommandBufferAllocateInfo {
      sType = .COMMAND_BUFFER_ALLOCATE_INFO,
      commandPool = gctx.command_pool,
      level = .SECONDARY,
      commandBufferCount = u32(len(self.commands)),
    },
    raw_data(self.commands[:]),
  ) or_return
  self.effect_stack = make([dynamic]PostprocessEffect)
  count :: len(PostProcessEffectType)
  vert_module := gpu.create_shader_module(
    gctx.device,
    SHADER_POSTPROCESS_VERT,
  ) or_return
  defer vk.DestroyShaderModule(gctx.device, vert_module, nil)
  frag_modules: [count]vk.ShaderModule
  defer for m in frag_modules do vk.DestroyShaderModule(gctx.device, m, nil)
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
      gctx.device,
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
  rendering_info := vk.PipelineRenderingCreateInfo {
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
  create_images(gctx, self, rm, width, height, color_format) or_return
  spec_data, spec_entries, spec_info := shared.make_shader_spec_constants()
  spec_info.pData = cast(rawptr)&spec_data
  defer delete(spec_entries)
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
      rm.textures_set_layout, // set = 0 (bindless textures)
    }
    vk.CreatePipelineLayout(
      gctx.device,
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
        pSpecializationInfo = &spec_info,
      },
      {
        sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
        stage = {.FRAGMENT},
        module = frag_modules[i],
        pName = "main",
        pSpecializationInfo = &spec_info,
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
    gctx.device,
    0,
    count,
    raw_data(pipeline_infos[:]),
    nil,
    raw_data(self.pipelines[:]),
  ) or_return
  log.info("Postprocess pipeline initialized successfully")
  return .SUCCESS
}

create_images :: proc(
  gctx: ^gpu.GPUContext,
  self: ^Renderer,
  rm: ^resources.Manager,
  width, height: u32,
  format: vk.Format,
) -> vk.Result {
  for &handle in self.images {
    handle, _ = resources.create_texture(
      gctx,
      rm,
      width,
      height,
      format,
      vk.ImageUsageFlags {
        .COLOR_ATTACHMENT,
        .SAMPLED,
        .TRANSFER_SRC,
        .TRANSFER_DST,
      },
    ) or_return
  }
  log.debugf("created post-process image")
  return .SUCCESS
}

destroy_images :: proc(
  self: ^Renderer,
  device: vk.Device,
  rm: ^resources.Manager,
) {
  for handle in self.images {
    if item, freed := resources.free(&rm.image_2d_buffers, handle); freed {
      gpu.image_destroy(device, item)
    }
  }
}

recreate_images :: proc(
  gctx: ^gpu.GPUContext,
  self: ^Renderer,
  width, height: u32,
  format: vk.Format,
  rm: ^resources.Manager,
) -> vk.Result {
  destroy_images(self, gctx.device, rm)
  return create_images(gctx, self, rm, width, height, format)
}

shutdown :: proc(
  self: ^Renderer,
  device: vk.Device,
  command_pool: vk.CommandPool,
  rm: ^resources.Manager,
) {
  vk.FreeCommandBuffers(device, command_pool, u32(len(self.commands)), raw_data(self.commands[:]))
  for &p in self.pipelines {
    vk.DestroyPipeline(device, p, nil)
    p = 0
  }
  for &layout in self.pipeline_layouts {
    vk.DestroyPipelineLayout(device, layout, nil)
    layout = 0
  }
  delete(self.effect_stack)
  destroy_images(self, device, rm)
}

// Modular postprocess API
begin_pass :: proc(
  self: ^Renderer,
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

render :: proc(
  self: ^Renderer,
  command_buffer: vk.CommandBuffer,
  extent: vk.Extent2D,
  output_view: vk.ImageView,
  camera_handle: resources.Handle,
  rm: ^resources.Manager,
  frame_index: u32,
) {
  camera := resources.get(rm.cameras, camera_handle)
  if camera == nil do return
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
      input_image_index =
        resources.camera_get_attachment(camera, .FINAL_IMAGE, frame_index).index // Use original input
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
      dst_texture := resources.get(
        rm.image_2d_buffers,
        self.images[dst_image_idx],
      )
      if dst_texture == nil {
        log.errorf(
          "Post-process image handle %v not found",
          self.images[dst_image_idx],
        )
        continue
      }
      // Transition dst texture from UNDEFINED to COLOR_ATTACHMENT_OPTIMAL
      dst_barrier := vk.ImageMemoryBarrier {
        sType = .IMAGE_MEMORY_BARRIER,
        srcAccessMask = {},
        dstAccessMask = {.COLOR_ATTACHMENT_WRITE},
        oldLayout = .UNDEFINED,
        newLayout = .COLOR_ATTACHMENT_OPTIMAL,
        srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
        dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
        image = dst_texture.image,
        subresourceRange = {
          aspectMask = {.COLOR},
          baseMipLevel = 0,
          levelCount = 1,
          baseArrayLayer = 0,
          layerCount = 1,
        },
      }
      vk.CmdPipelineBarrier(
        command_buffer,
        {.TOP_OF_PIPE},
        {.COLOR_ATTACHMENT_OUTPUT},
        {},
        0,
        nil,
        0,
        nil,
        1,
        &dst_barrier,
      )
      dst_view = dst_texture.view
    } else {
      // For the last effect, output is the swapchain image, which should already be transitioned
    }
    if !is_first {
      src_texture_idx := (i - 1) % 2 // Which ping-pong buffer the previous pass wrote to
      src_texture := resources.get(
        rm.image_2d_buffers,
        self.images[src_texture_idx],
      )
      if src_texture == nil {
        log.errorf(
          "Post-process source image handle %v not found",
          self.images[src_texture_idx],
        )
        continue
      }
      // Transition src texture from COLOR_ATTACHMENT to SHADER_READ_ONLY
      src_barrier := vk.ImageMemoryBarrier {
        sType = .IMAGE_MEMORY_BARRIER,
        srcAccessMask = {.COLOR_ATTACHMENT_WRITE},
        dstAccessMask = {.SHADER_READ},
        oldLayout = .COLOR_ATTACHMENT_OPTIMAL,
        newLayout = .SHADER_READ_ONLY_OPTIMAL,
        srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
        dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
        image = src_texture.image,
        subresourceRange = {
          aspectMask = {.COLOR},
          baseMipLevel = 0,
          levelCount = 1,
          baseArrayLayer = 0,
          layerCount = 1,
        },
      }
      vk.CmdPipelineBarrier(
        command_buffer,
        {.COLOR_ATTACHMENT_OUTPUT},
        {.FRAGMENT_SHADER},
        {},
        0,
        nil,
        0,
        nil,
        1,
        &src_barrier,
      )
    }
    color_attachment := vk.RenderingAttachmentInfo {
      sType = .RENDERING_ATTACHMENT_INFO,
      imageView = dst_view,
      imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
      loadOp = .CLEAR,
      storeOp = .STORE,
      clearValue = {color = {float32 = BG_BLUE_GRAY}},
    }
    render_info := vk.RenderingInfo {
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
      rm.textures_descriptor_set, // set = 0 (bindless textures)
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
      resources.camera_get_attachment(camera, .POSITION, frame_index).index
    base.normal_texture_index =
      resources.camera_get_attachment(camera, .NORMAL, frame_index).index
    base.albedo_texture_index =
      resources.camera_get_attachment(camera, .ALBEDO, frame_index).index
    base.metallic_texture_index =
      resources.camera_get_attachment(camera, .METALLIC_ROUGHNESS, frame_index).index
    base.emissive_texture_index =
      resources.camera_get_attachment(camera, .EMISSIVE, frame_index).index
    base.depth_texture_index =
      resources.camera_get_attachment(camera, .DEPTH, frame_index).index
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

end_pass :: proc(self: ^Renderer, command_buffer: vk.CommandBuffer) {

}

begin_record :: proc(
  self: ^Renderer,
  frame_index: u32,
  color_format: vk.Format,
  camera_handle: resources.Handle,
  rm: ^resources.Manager,
  swapchain_image: vk.Image,
) -> (
  command_buffer: vk.CommandBuffer,
  ret: vk.Result,
) {
  command_buffer = self.commands[frame_index]
  vk.ResetCommandBuffer(command_buffer, {}) or_return
  color_formats := [1]vk.Format{color_format}
  rendering_info := vk.CommandBufferInheritanceRenderingInfo {
    sType                   = .COMMAND_BUFFER_INHERITANCE_RENDERING_INFO,
    colorAttachmentCount    = 1,
    pColorAttachmentFormats = &color_formats[0],
  }
  inheritance := vk.CommandBufferInheritanceInfo {
    sType = .COMMAND_BUFFER_INHERITANCE_INFO,
    pNext = &rendering_info,
  }
  vk.BeginCommandBuffer(
    command_buffer,
    &vk.CommandBufferBeginInfo {
      sType = .COMMAND_BUFFER_BEGIN_INFO,
      flags = {.ONE_TIME_SUBMIT},
      pInheritanceInfo = &inheritance,
    },
  ) or_return
  camera := resources.get(rm.cameras, camera_handle)
  if camera == nil do return command_buffer, .ERROR_UNKNOWN
  // Transition final image to shader read optimal
  if final_image, ok := resources.get(
    rm.image_2d_buffers,
    resources.camera_get_attachment(camera, .FINAL_IMAGE, frame_index),
  ); ok {
    final_barrier := vk.ImageMemoryBarrier {
      sType = .IMAGE_MEMORY_BARRIER,
      srcAccessMask = {.COLOR_ATTACHMENT_WRITE},
      dstAccessMask = {.SHADER_READ},
      oldLayout = .COLOR_ATTACHMENT_OPTIMAL,
      newLayout = .SHADER_READ_ONLY_OPTIMAL,
      srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
      dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
      image = final_image.image,
      subresourceRange = {
        aspectMask = {.COLOR},
        baseMipLevel = 0,
        levelCount = 1,
        baseArrayLayer = 0,
        layerCount = 1,
      },
    }
    vk.CmdPipelineBarrier(
      command_buffer,
      {.COLOR_ATTACHMENT_OUTPUT},
      {.FRAGMENT_SHADER},
      {},
      0,
      nil,
      0,
      nil,
      1,
      &final_barrier,
    )
  }
  // Transition swapchain image from UNDEFINED to COLOR_ATTACHMENT_OPTIMAL
  swapchain_barrier := vk.ImageMemoryBarrier {
    sType = .IMAGE_MEMORY_BARRIER,
    srcAccessMask = {},
    dstAccessMask = {.COLOR_ATTACHMENT_WRITE},
    oldLayout = .UNDEFINED,
    newLayout = .COLOR_ATTACHMENT_OPTIMAL,
    srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
    dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
    image = swapchain_image,
    subresourceRange = {
      aspectMask = {.COLOR},
      baseMipLevel = 0,
      levelCount = 1,
      baseArrayLayer = 0,
      layerCount = 1,
    },
  }
  vk.CmdPipelineBarrier(
    command_buffer,
    {.TOP_OF_PIPE},
    {.COLOR_ATTACHMENT_OUTPUT},
    {},
    0,
    nil,
    0,
    nil,
    1,
    &swapchain_barrier,
  )
  return command_buffer, .SUCCESS
}

end_record :: proc(command_buffer: vk.CommandBuffer) -> vk.Result {
  vk.EndCommandBuffer(command_buffer) or_return
  return .SUCCESS
}

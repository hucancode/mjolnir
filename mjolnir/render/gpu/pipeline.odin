package gpu

import vk "vendor:vulkan"

// READ_WRITE_DEPTH_STATE tests and writes depth with LESS_OR_EQUAL.
READ_WRITE_DEPTH_STATE := vk.PipelineDepthStencilStateCreateInfo {
  depthTestEnable  = true,
  depthWriteEnable = true,
  depthCompareOp   = .LESS_OR_EQUAL,
}

// READ_ONLY_DEPTH_STATE tests depth with LESS_OR_EQUAL without writing it.
READ_ONLY_DEPTH_STATE := vk.PipelineDepthStencilStateCreateInfo {
  depthTestEnable = true,
  depthCompareOp  = .LESS_OR_EQUAL,
}

// BLEND_OVERRIDE writes color with no blending.
BLEND_OVERRIDE := vk.PipelineColorBlendAttachmentState {
  colorWriteMask = {.R, .G, .B, .A},
}

// BLEND_ALPHA is standard source-alpha blending.
BLEND_ALPHA := vk.PipelineColorBlendAttachmentState {
  blendEnable         = true,
  srcColorBlendFactor = .SRC_ALPHA,
  dstColorBlendFactor = .ONE_MINUS_SRC_ALPHA,
  colorBlendOp        = .ADD,
  srcAlphaBlendFactor = .SRC_ALPHA,
  dstAlphaBlendFactor = .ONE_MINUS_SRC_ALPHA,
  alphaBlendOp        = .ADD,
  colorWriteMask      = {.R, .G, .B, .A},
}

// BLEND_ADDITIVE adds source color to the target.
BLEND_ADDITIVE := vk.PipelineColorBlendAttachmentState {
  blendEnable         = true,
  srcColorBlendFactor = .ONE,
  dstColorBlendFactor = .ONE,
  colorBlendOp        = .ADD,
  srcAlphaBlendFactor = .ONE,
  dstAlphaBlendFactor = .ONE,
  alphaBlendOp        = .ADD,
  colorWriteMask      = {.R, .G, .B, .A},
}

// HDR_COLOR_FORMAT is the format of the scene color target.
HDR_COLOR_FORMAT :: vk.Format.R16G16B16A16_SFLOAT

// GraphicsPipelineDesc is everything that varies between the engine's graphics pipelines.
// Shaders are SPIR-V with entry point "main"; `frag` may be empty. Front faces wind
// counter-clockwise; zero `polygon_mode` and `cull_mode` fill both faces. `depth` applies only
// when `depth_format` is set; `blend` has one entry per color format. Empty `dynamic_states`
// means viewport + scissor.
GraphicsPipelineDesc :: struct {
  vert, frag:        []u8,
  specialization:    ^vk.SpecializationInfo,
  vertex_bindings:   []vk.VertexInputBindingDescription,
  vertex_attributes: []vk.VertexInputAttributeDescription,
  topology:          vk.PrimitiveTopology,
  polygon_mode:      vk.PolygonMode,
  cull_mode:         vk.CullModeFlags,
  // clamp depth instead of clipping at the near and far planes
  depth_clamp:       b32,
  // constant and slope-scaled depth bias factors; zero disables the bias
  depth_bias:        [2]f32,
  depth:             vk.PipelineDepthStencilStateCreateInfo,
  blend:             []vk.PipelineColorBlendAttachmentState,
  color_formats:     []vk.Format,
  depth_format:      vk.Format,
  dynamic_states:    []vk.DynamicState,
  layout:            vk.PipelineLayout,
}

// create_graphics_pipeline builds a dynamic-rendering pipeline from desc.
create_graphics_pipeline :: proc(
  gctx: ^GPUContext,
  desc: GraphicsPipelineDesc,
) -> (
  pipeline: vk.Pipeline,
  ret: vk.Result,
) {
  desc := desc
  stages: [2]vk.PipelineShaderStageCreateInfo
  stage_count: u32
  defer for s in stages[:stage_count] do vk.DestroyShaderModule(gctx.device, s.module, nil)
  codes := [2][]u8{desc.vert, desc.frag}
  stage_flags := [2]vk.ShaderStageFlags{{.VERTEX}, {.FRAGMENT}}
  for code, i in codes {
    if len(code) == 0 do continue
    stages[stage_count] = {
      sType               = .PIPELINE_SHADER_STAGE_CREATE_INFO,
      stage               = stage_flags[i],
      module              = create_shader_module(gctx.device, code) or_return,
      pName               = "main",
      pSpecializationInfo = desc.specialization,
    }
    stage_count += 1
  }
  vertex_input := vk.PipelineVertexInputStateCreateInfo {
    sType                           = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
    vertexBindingDescriptionCount   = u32(len(desc.vertex_bindings)),
    pVertexBindingDescriptions      = raw_data(desc.vertex_bindings),
    vertexAttributeDescriptionCount = u32(len(desc.vertex_attributes)),
    pVertexAttributeDescriptions    = raw_data(desc.vertex_attributes),
  }
  input_assembly := vk.PipelineInputAssemblyStateCreateInfo {
    sType    = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
    topology = desc.topology,
  }
  viewport := vk.PipelineViewportStateCreateInfo {
    sType         = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
    viewportCount = 1,
    scissorCount  = 1,
  }
  raster := vk.PipelineRasterizationStateCreateInfo {
    sType       = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
    polygonMode = desc.polygon_mode,
    cullMode                = desc.cull_mode,
    frontFace               = .COUNTER_CLOCKWISE,
    lineWidth               = 1,
    depthClampEnable        = desc.depth_clamp,
    depthBiasEnable         = b32(desc.depth_bias != {}),
    depthBiasConstantFactor = desc.depth_bias[0],
    depthBiasSlopeFactor    = desc.depth_bias[1],
  }
  multisample := vk.PipelineMultisampleStateCreateInfo {
    sType                = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
    rasterizationSamples = {._1},
  }
  desc.depth.sType = .PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO
  blend := vk.PipelineColorBlendStateCreateInfo {
    sType           = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
    attachmentCount = u32(len(desc.blend)),
    pAttachments    = raw_data(desc.blend),
  }
  default_dynamic_states := [?]vk.DynamicState{.VIEWPORT, .SCISSOR}
  dynamic_states := desc.dynamic_states
  if len(dynamic_states) == 0 do dynamic_states = default_dynamic_states[:]
  dynamic_state := vk.PipelineDynamicStateCreateInfo {
    sType             = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
    dynamicStateCount = u32(len(dynamic_states)),
    pDynamicStates    = raw_data(dynamic_states),
  }
  rendering := vk.PipelineRenderingCreateInfo {
    sType                   = .PIPELINE_RENDERING_CREATE_INFO,
    colorAttachmentCount    = u32(len(desc.color_formats)),
    pColorAttachmentFormats = raw_data(desc.color_formats),
    depthAttachmentFormat   = desc.depth_format,
  }
  info := vk.GraphicsPipelineCreateInfo {
    sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
    pNext               = &rendering,
    stageCount          = stage_count,
    pStages             = raw_data(stages[:]),
    pVertexInputState   = &vertex_input,
    pInputAssemblyState = &input_assembly,
    pViewportState      = &viewport,
    pRasterizationState = &raster,
    pMultisampleState   = &multisample,
    pDepthStencilState  = &desc.depth if desc.depth_format != .UNDEFINED else nil,
    pColorBlendState    = &blend if len(desc.blend) > 0 else nil,
    pDynamicState       = &dynamic_state,
    layout              = desc.layout,
  }
  vk.CreateGraphicsPipelines(gctx.device, 0, 1, &info, nil, &pipeline) or_return
  return pipeline, .SUCCESS
}

// begin_record resets and begins command_buffer, one-time submit by default.
begin_record :: proc(
  command_buffer: vk.CommandBuffer,
  flags: vk.CommandBufferUsageFlags = {.ONE_TIME_SUBMIT},
) -> vk.Result {
  vk.ResetCommandBuffer(command_buffer, {}) or_return
  return vk.BeginCommandBuffer(
    command_buffer,
    &{sType = .COMMAND_BUFFER_BEGIN_INFO, flags = flags},
  )
}

// allocate_descriptor_set allocates one set of layout from the context pool.
allocate_descriptor_set :: proc(
  gctx: ^GPUContext,
  ret: ^vk.DescriptorSet,
  layout: ^vk.DescriptorSetLayout,
) -> vk.Result {
  return vk.AllocateDescriptorSets(
    gctx.device,
    &{
      sType = .DESCRIPTOR_SET_ALLOCATE_INFO,
      descriptorPool = gctx.descriptor_pool,
      descriptorSetCount = 1,
      pSetLayouts = layout,
    },
    ret,
  )
}

// allocate_command_buffer allocates primary command buffers from pool (default: the graphics pool).
allocate_command_buffer :: proc(
  gctx: ^GPUContext,
  out_commands: []vk.CommandBuffer,
  pool: vk.CommandPool = 0,
) -> vk.Result {
  return vk.AllocateCommandBuffers(
    gctx.device,
    &vk.CommandBufferAllocateInfo {
      sType = .COMMAND_BUFFER_ALLOCATE_INFO,
      commandPool = pool if pool != 0 else gctx.command_pool,
      level = .PRIMARY,
      commandBufferCount = u32(len(out_commands)),
    },
    raw_data(out_commands),
  )
}

// DescriptorInfo is the resource one descriptor points at.
DescriptorInfo :: union {
  vk.DescriptorBufferInfo,
  vk.DescriptorImageInfo,
}

// DescriptorBinding is one binding of a descriptor set layout: count descriptors of type.
DescriptorBinding :: struct {
  type:   vk.DescriptorType,
  count:  u32,
  stages: vk.ShaderStageFlags,
}

// create_descriptor_layout creates a layout whose binding i is bindings[i]. Every binding is
// PARTIALLY_BOUND and UPDATE_UNUSED_WHILE_PENDING: unwritten slots are legal while unread,
// and a slot no submitted work uses may be written while the set is in use.
create_descriptor_layout :: proc(
  gctx: ^GPUContext,
  bindings: ..DescriptorBinding,
) -> (
  layout: vk.DescriptorSetLayout,
  ret: vk.Result,
) {
  vk_bindings := make([]vk.DescriptorSetLayoutBinding, len(bindings), context.temp_allocator)
  binding_flags := make([]vk.DescriptorBindingFlags, len(bindings), context.temp_allocator)
  for &b, i in bindings {
    vk_bindings[i] = {
      binding         = u32(i),
      descriptorType  = b.type,
      descriptorCount = b.count,
      stageFlags      = b.stages,
    }
    binding_flags[i] = {.PARTIALLY_BOUND, .UPDATE_UNUSED_WHILE_PENDING}
  }
  flags_info := vk.DescriptorSetLayoutBindingFlagsCreateInfo {
    sType         = .DESCRIPTOR_SET_LAYOUT_BINDING_FLAGS_CREATE_INFO,
    bindingCount  = u32(len(binding_flags)),
    pBindingFlags = raw_data(binding_flags),
  }
  vk.CreateDescriptorSetLayout(
    gctx.device,
    &{
      sType = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
      pNext = &flags_info,
      bindingCount = u32(len(vk_bindings)),
      pBindings = raw_data(vk_bindings),
    },
    nil,
    &layout,
  ) or_return
  ret = .SUCCESS
  return
}

// write_descriptor points slot index of binding of set at info.
write_descriptor :: proc(
  gctx: ^GPUContext,
  set: vk.DescriptorSet,
  binding, index: u32,
  type: vk.DescriptorType,
  info: DescriptorInfo,
) {
  if set == 0 do return
  info := info
  write := vk.WriteDescriptorSet {
    sType           = .WRITE_DESCRIPTOR_SET,
    dstSet          = set,
    dstBinding      = binding,
    dstArrayElement = index,
    descriptorType  = type,
    descriptorCount = 1,
  }
  switch &v in info {
  case vk.DescriptorBufferInfo:
    write.pBufferInfo = &v
  case vk.DescriptorImageInfo:
    write.pImageInfo = &v
  }
  vk.UpdateDescriptorSets(gctx.device, 1, &write, 0, nil)
}


// ImageDiscard moves every mip and layer of one image from UNDEFINED to GENERAL, ready for access at stage.
ImageDiscard :: struct {
  image:  vk.Image,
  aspect: vk.ImageAspectFlags,
  access: vk.AccessFlags2,
  stage:  vk.PipelineStageFlags2,
}

// attachment_discard returns the ImageDiscard of an attachment image, ready for its color or depth writes.
attachment_discard :: proc(img: ^Image) -> ImageDiscard {
  aspect := infer_aspect_mask(img.format)
  if .COLOR in aspect do return {img.image, aspect, {.COLOR_ATTACHMENT_WRITE}, {.COLOR_ATTACHMENT_OUTPUT}}
  return {img.image, aspect, {.DEPTH_STENCIL_ATTACHMENT_WRITE}, {.EARLY_FRAGMENT_TESTS}}
}

// image_discard_barrier records every discard in one dependency.
image_discard_barrier :: proc(command_buffer: vk.CommandBuffer, discards: ..ImageDiscard) {
  barriers := make([]vk.ImageMemoryBarrier2, len(discards), context.temp_allocator)
  for d, i in discards {
    barriers[i] = {
      sType = .IMAGE_MEMORY_BARRIER_2,
      srcStageMask = {.TOP_OF_PIPE},
      dstStageMask = d.stage,
      dstAccessMask = d.access,
      oldLayout = .UNDEFINED,
      newLayout = .GENERAL,
      srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
      dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
      image = d.image,
      subresourceRange = {
        aspectMask = d.aspect,
        levelCount = vk.REMAINING_MIP_LEVELS,
        layerCount = vk.REMAINING_ARRAY_LAYERS,
      },
    }
  }
  dep := vk.DependencyInfo {
    sType                   = .DEPENDENCY_INFO,
    imageMemoryBarrierCount = u32(len(barriers)),
    pImageMemoryBarriers    = raw_data(barriers),
  }
  vk.CmdPipelineBarrier2(command_buffer, &dep)
}

// memory_barrier records a global memory dependency between the given stages and accesses.
memory_barrier :: proc(
  command_buffer: vk.CommandBuffer,
  src_access: vk.AccessFlags2,
  dst_access: vk.AccessFlags2,
  src_stage: vk.PipelineStageFlags2,
  dst_stage: vk.PipelineStageFlags2,
) {
  barrier := vk.MemoryBarrier2 {
    sType         = .MEMORY_BARRIER_2,
    srcStageMask  = src_stage,
    srcAccessMask = src_access,
    dstStageMask  = dst_stage,
    dstAccessMask = dst_access,
  }
  dep := vk.DependencyInfo {
    sType              = .DEPENDENCY_INFO,
    memoryBarrierCount = 1,
    pMemoryBarriers    = &barrier,
  }
  vk.CmdPipelineBarrier2(command_buffer, &dep)
}

// create_compute_pipeline builds a compute pipeline from SPIR-V code with entry point "main".
create_compute_pipeline :: proc(
  gctx: ^GPUContext,
  code: []u8,
  layout: vk.PipelineLayout,
  specialization: ^vk.SpecializationInfo = nil,
) -> (
  pipeline: vk.Pipeline,
  ret: vk.Result,
) {
  module := create_shader_module(gctx.device, code) or_return
  defer vk.DestroyShaderModule(gctx.device, module, nil)
  info := vk.ComputePipelineCreateInfo {
    sType = .COMPUTE_PIPELINE_CREATE_INFO,
    stage = {
      sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
      stage = {.COMPUTE},
      module = module,
      pName = "main",
      pSpecializationInfo = specialization,
    },
    layout = layout,
  }
  vk.CreateComputePipelines(gctx.device, 0, 1, &info, nil, &pipeline) or_return
  return pipeline, .SUCCESS
}

// bind_vertex_index_buffers binds one vertex and one index buffer.
bind_vertex_index_buffers :: proc(
  command_buffer: vk.CommandBuffer,
  vertex_buffer: vk.Buffer,
  index_buffer: vk.Buffer,
  vertex_offset: vk.DeviceSize = 0,
  index_offset: vk.DeviceSize = 0,
  index_type: vk.IndexType = .UINT32,
) {
  vertex_buffers := [?]vk.Buffer{vertex_buffer}
  offsets := [?]vk.DeviceSize{vertex_offset}
  vk.CmdBindVertexBuffers(
    command_buffer,
    0,
    1,
    raw_data(vertex_buffers[:]),
    raw_data(offsets[:]),
  )
  vk.CmdBindIndexBuffer(command_buffer, index_buffer, index_offset, index_type)
}

// create_color_attachment describes a color attachment for begin_rendering.
create_color_attachment :: proc(
  view: vk.ImageView,
  load_op: vk.AttachmentLoadOp = .CLEAR,
  store_op: vk.AttachmentStoreOp = .STORE,
  clear_color: [4]f32 = {0.0, 0.0, 0.0, 1.0},
) -> vk.RenderingAttachmentInfo {
  return vk.RenderingAttachmentInfo {
    sType = .RENDERING_ATTACHMENT_INFO,
    imageView = view,
    imageLayout = .GENERAL,
    loadOp = load_op,
    storeOp = store_op,
    clearValue = {color = {float32 = clear_color}},
  }
}

// create_depth_attachment describes a depth attachment for begin_rendering.
create_depth_attachment :: proc(
  view: vk.ImageView,
  load_op: vk.AttachmentLoadOp = .CLEAR,
  store_op: vk.AttachmentStoreOp = .STORE,
  clear_depth: f32 = 1.0,
) -> vk.RenderingAttachmentInfo {
  return vk.RenderingAttachmentInfo {
    sType = .RENDERING_ATTACHMENT_INFO,
    imageView = view,
    imageLayout = .GENERAL,
    loadOp = load_op,
    storeOp = store_op,
    clearValue = {depthStencil = {depth = clear_depth}},
  }
}

// begin_rendering begins a dynamic rendering scope over extent, with viewport and scissor covering it.
begin_rendering :: proc(
  command_buffer: vk.CommandBuffer,
  extent: vk.Extent2D,
  depth_attachment: Maybe(vk.RenderingAttachmentInfo),
  color_attachments: ..vk.RenderingAttachmentInfo,
  layer_count: u32 = 1,
) {
  depth, has_depth := depth_attachment.?
  render_info := vk.RenderingInfo {
    sType = .RENDERING_INFO,
    renderArea = {extent = extent},
    layerCount = layer_count,
    pDepthAttachment = &depth if has_depth else nil,
    colorAttachmentCount = u32(len(color_attachments)),
    pColorAttachments = raw_data(color_attachments),
  }
  vk.CmdBeginRendering(command_buffer, &render_info)
  viewport := vk.Viewport{width = f32(extent.width), height = f32(extent.height), maxDepth = 1}
  vk.CmdSetViewport(command_buffer, 0, 1, &viewport)
  vk.CmdSetScissor(command_buffer, 0, 1, &render_info.renderArea)
}

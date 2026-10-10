package gpu

import "core:slice"
import vk "vendor:vulkan"

READ_WRITE_DEPTH_STATE := vk.PipelineDepthStencilStateCreateInfo {
  depthTestEnable  = true,
  depthWriteEnable = true,
  depthCompareOp   = .LESS_OR_EQUAL,
}

READ_ONLY_DEPTH_STATE := vk.PipelineDepthStencilStateCreateInfo {
  depthTestEnable = true,
  depthCompareOp  = .LESS_OR_EQUAL,
}

STANDARD_RASTERIZER := vk.PipelineRasterizationStateCreateInfo {
  polygonMode = .FILL,
  cullMode    = {.BACK},
  frontFace   = .COUNTER_CLOCKWISE,
}

DOUBLE_SIDED_RASTERIZER := vk.PipelineRasterizationStateCreateInfo {
  polygonMode = .FILL,
  lineWidth   = 1.0,
}

LINE_RASTERIZER := vk.PipelineRasterizationStateCreateInfo {
  polygonMode = .LINE,
  lineWidth   = 1.0,
}

BLEND_OVERRIDE := vk.PipelineColorBlendAttachmentState {
  colorWriteMask = {.R, .G, .B, .A},
}

BLEND_ADDITIVE := vk.PipelineColorBlendAttachmentState {
  blendEnable         = true,
  srcColorBlendFactor = .SRC_ALPHA,
  dstColorBlendFactor = .ONE_MINUS_SRC_ALPHA,
  colorBlendOp        = .ADD,
  srcAlphaBlendFactor = .SRC_ALPHA,
  dstAlphaBlendFactor = .ONE_MINUS_SRC_ALPHA,
  alphaBlendOp        = .ADD,
  colorWriteMask      = {.R, .G, .B, .A},
}

BLEND_OVERFLOW := vk.PipelineColorBlendAttachmentState {
  blendEnable         = true,
  srcColorBlendFactor = .ONE,
  dstColorBlendFactor = .ONE,
  colorBlendOp        = .ADD,
  srcAlphaBlendFactor = .ONE,
  dstAlphaBlendFactor = .ONE,
  alphaBlendOp        = .ADD,
  colorWriteMask      = {.R, .G, .B, .A},
}

HDR_COLOR_FORMAT :: vk.Format.R16G16B16A16_SFLOAT

// Everything that varies between the engine's graphics pipelines, as the raw
// Vulkan values create_graphics_pipeline writes into GraphicsPipelineCreateInfo.
// Shader stages use entry point "main"; `geom` and `frag` are optional (0).
// `raster` and `depth` need no sType. `depth` applies only when
// `depth_format` is set; `blend` holds one entry per color format. Empty
// `dynamic_states` means viewport + scissor. Pipelines target dynamic
// rendering with one sample per pixel.
GraphicsPipelineDesc :: struct {
  vert, geom, frag:  vk.ShaderModule,
  specialization:    ^vk.SpecializationInfo,
  vertex_bindings:   []vk.VertexInputBindingDescription,
  vertex_attributes: []vk.VertexInputAttributeDescription,
  topology:          vk.PrimitiveTopology,
  raster:            vk.PipelineRasterizationStateCreateInfo,
  depth:             vk.PipelineDepthStencilStateCreateInfo,
  blend:             []vk.PipelineColorBlendAttachmentState,
  color_formats:     []vk.Format,
  depth_format:      vk.Format,
  dynamic_states:    []vk.DynamicState,
  layout:            vk.PipelineLayout,
}

create_graphics_pipeline :: proc(
  gctx: ^GPUContext,
  desc: GraphicsPipelineDesc,
) -> (
  pipeline: vk.Pipeline,
  ret: vk.Result,
) {
  desc := desc
  stages: [3]vk.PipelineShaderStageCreateInfo
  stage_count: u32
  modules := [3]vk.ShaderModule{desc.vert, desc.geom, desc.frag}
  stage_flags := [3]vk.ShaderStageFlags{{.VERTEX}, {.GEOMETRY}, {.FRAGMENT}}
  for module, i in modules {
    if module == 0 do continue
    stages[stage_count] = {
      sType               = .PIPELINE_SHADER_STAGE_CREATE_INFO,
      stage               = stage_flags[i],
      module              = module,
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
  desc.raster.sType = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO
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
    pRasterizationState = &desc.raster,
    pMultisampleState   = &multisample,
    pDepthStencilState  = &desc.depth if desc.depth_format != .UNDEFINED else nil,
    pColorBlendState    = &blend if len(desc.blend) > 0 else nil,
    pDynamicState       = &dynamic_state,
    layout              = desc.layout,
  }
  vk.CreateGraphicsPipelines(gctx.device, 0, 1, &info, nil, &pipeline) or_return
  return pipeline, .SUCCESS
}

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

end_record :: proc(command_buffer: vk.CommandBuffer) -> vk.Result {
  return vk.EndCommandBuffer(command_buffer)
}

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

// Return sets to the descriptor pool. Null handles are ignored.
free_descriptor_sets :: proc(gctx: ^GPUContext, sets: ..vk.DescriptorSet) {
  for set in sets {
    if set == 0 do continue
    s := set
    vk.FreeDescriptorSets(gctx.device, gctx.descriptor_pool, 1, &s)
  }
}

allocate_command_buffer :: proc(
  gctx: ^GPUContext,
  out_commands: []vk.CommandBuffer,
  level: vk.CommandBufferLevel = .PRIMARY,
) -> vk.Result {
  return vk.AllocateCommandBuffers(
    gctx.device,
    &vk.CommandBufferAllocateInfo {
      sType = .COMMAND_BUFFER_ALLOCATE_INFO,
      commandPool = gctx.command_pool,
      level = level,
      commandBufferCount = u32(len(out_commands)),
    },
    raw_data(out_commands),
  )
}

allocate_compute_command_buffer :: proc(
  gctx: ^GPUContext,
  out_commands: []vk.CommandBuffer,
  level: vk.CommandBufferLevel = .PRIMARY,
) -> vk.Result {
  vk.AllocateCommandBuffers(
    gctx.device,
    &{
      sType = .COMMAND_BUFFER_ALLOCATE_INFO,
      commandPool = gctx.compute_command_pool,
      level = level,
      commandBufferCount = u32(len(out_commands)),
    },
    raw_data(out_commands),
  ) or_return
  return .SUCCESS
}

free_command_buffer :: proc(gctx: ^GPUContext, commands: ..vk.CommandBuffer) {
  vk.FreeCommandBuffers(
    gctx.device,
    gctx.command_pool,
    u32(len(commands)),
    raw_data(commands),
  )
}

free_compute_command_buffer :: proc(
  gctx: ^GPUContext,
  commands: []vk.CommandBuffer,
) {
  vk.FreeCommandBuffers(
    gctx.device,
    gctx.compute_command_pool,
    u32(len(commands)),
    raw_data(commands),
  )
}

update_descriptor_set :: proc(
  gctx: ^GPUContext,
  dst: vk.DescriptorSet,
  buffers: ..struct {
    type: vk.DescriptorType,
    info: union {
      vk.DescriptorBufferInfo,
      vk.DescriptorImageInfo,
    },
  },
) {
  writes := make([]vk.WriteDescriptorSet, len(buffers))
  defer delete(writes)
  for &b, i in buffers {
    writes[i] = {
      sType           = .WRITE_DESCRIPTOR_SET,
      dstSet          = dst,
      dstBinding      = u32(i),
      descriptorType  = b.type,
      descriptorCount = 1,
    }
    switch &v in b.info {
    case vk.DescriptorBufferInfo:
      writes[i].pBufferInfo = &v
    case vk.DescriptorImageInfo:
      writes[i].pImageInfo = &v
    }
  }
  vk.UpdateDescriptorSets(
    gctx.device,
    u32(len(writes)),
    raw_data(writes),
    0,
    nil,
  )
}

create_descriptor_set :: proc(
  gctx: ^GPUContext,
  layout: ^vk.DescriptorSetLayout,
  buffers: ..struct {
    type: vk.DescriptorType,
    info: union {
      vk.DescriptorBufferInfo,
      vk.DescriptorImageInfo,
    },
  },
) -> (
  dst: vk.DescriptorSet,
  ret: vk.Result,
) {
  allocate_descriptor_set(gctx, &dst, layout) or_return
  update_descriptor_set(gctx, dst, ..buffers)
  return dst, .SUCCESS
}

create_descriptor_set_layout :: proc(gctx: ^GPUContext, bindings: ..struct {
    type:  vk.DescriptorType,
    flags: vk.ShaderStageFlags,
  }) -> (layout: vk.DescriptorSetLayout, ret: vk.Result) {
  vk_bindings := make([]vk.DescriptorSetLayoutBinding, len(bindings))
  defer delete(vk_bindings)
  for &b, i in bindings {
    vk_bindings[i] = {
      binding         = u32(i),
      descriptorType  = b.type,
      descriptorCount = 1,
      stageFlags      = b.flags,
    }
  }
  vk.CreateDescriptorSetLayout(
    gctx.device,
    &{
      sType = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
      bindingCount = u32(len(vk_bindings)),
      pBindings = raw_data(vk_bindings),
    },
    nil,
    &layout,
  ) or_return
  ret = .SUCCESS
  return
}

// Layout for bindless descriptor arrays: binding i holds `count` descriptors
// and is PARTIALLY_BOUND, so slots never written stay legal as long as shaders
// do not read them. Fill slots with write_descriptor_array_element.
create_descriptor_array_layout :: proc(
  gctx: ^GPUContext,
  bindings: ..struct {
    type:  vk.DescriptorType,
    count: u32,
    flags: vk.ShaderStageFlags,
  },
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
      stageFlags      = b.flags,
    }
    binding_flags[i] = {.PARTIALLY_BOUND}
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

// Write one image descriptor into slot `index` of array binding `binding`.
write_descriptor_array_element :: proc(
  gctx: ^GPUContext,
  set: vk.DescriptorSet,
  binding, index: u32,
  type: vk.DescriptorType,
  info: vk.DescriptorImageInfo,
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
    pImageInfo      = &info,
  }
  vk.UpdateDescriptorSets(gctx.device, 1, &write, 0, nil)
}

create_pipeline_layout :: proc(
  gctx: ^GPUContext,
  pc_range: Maybe(vk.PushConstantRange),
  ds: ..vk.DescriptorSetLayout,
) -> (
  layout: vk.PipelineLayout,
  ret: vk.Result,
) {
  pc_range, has_pc := pc_range.?
  vk.CreatePipelineLayout(
    gctx.device,
    &vk.PipelineLayoutCreateInfo {
      sType = .PIPELINE_LAYOUT_CREATE_INFO,
      setLayoutCount = u32(len(ds)),
      pSetLayouts = raw_data(ds),
      pushConstantRangeCount = 1 if has_pc else 0,
      pPushConstantRanges = &pc_range,
    },
    nil,
    &layout,
  ) or_return
  ret = .SUCCESS
  return
}

bind_pipeline :: proc(
  command_buffer: vk.CommandBuffer,
  bind_point: vk.PipelineBindPoint,
  pipeline: vk.Pipeline,
  layout: vk.PipelineLayout,
  ds: ..vk.DescriptorSet,
) {
  vk.CmdBindPipeline(command_buffer, bind_point, pipeline)
  vk.CmdBindDescriptorSets(
    command_buffer,
    bind_point,
    layout,
    0,
    u32(len(ds)),
    raw_data(ds),
    0,
    nil,
  )
}

image_discard_barrier :: proc(
  command_buffer: vk.CommandBuffer,
  image: vk.Image,
  dst_access: vk.AccessFlags2,
  dst_stage: vk.PipelineStageFlags2,
  aspect_mask: vk.ImageAspectFlags,
  level_count: u32 = 1,
  layer_count: u32 = 1,
) {
  barrier := vk.ImageMemoryBarrier2 {
    sType = .IMAGE_MEMORY_BARRIER_2,
    srcStageMask = {.TOP_OF_PIPE},
    dstStageMask = dst_stage,
    dstAccessMask = dst_access,
    oldLayout = .UNDEFINED,
    newLayout = .GENERAL,
    srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
    dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
    image = image,
    subresourceRange = {
      aspectMask = aspect_mask,
      levelCount = level_count,
      layerCount = layer_count,
    },
  }
  dep := vk.DependencyInfo {
    sType                   = .DEPENDENCY_INFO,
    imageMemoryBarrierCount = 1,
    pImageMemoryBarriers    = &barrier,
  }
  vk.CmdPipelineBarrier2(command_buffer, &dep)
}

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

buffer_barrier :: proc(
  command_buffer: vk.CommandBuffer,
  buffer: vk.Buffer,
  size: vk.DeviceSize,
  src_access: vk.AccessFlags2,
  dst_access: vk.AccessFlags2,
  src_stage: vk.PipelineStageFlags2,
  dst_stage: vk.PipelineStageFlags2,
  offset: vk.DeviceSize = 0,
) {
  barrier := vk.BufferMemoryBarrier2 {
    sType               = .BUFFER_MEMORY_BARRIER_2,
    srcStageMask        = src_stage,
    srcAccessMask       = src_access,
    dstStageMask        = dst_stage,
    dstAccessMask       = dst_access,
    srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
    dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
    buffer              = buffer,
    offset              = offset,
    size                = size,
  }
  dep := vk.DependencyInfo {
    sType                    = .DEPENDENCY_INFO,
    bufferMemoryBarrierCount = 1,
    pBufferMemoryBarriers    = &barrier,
  }
  vk.CmdPipelineBarrier2(command_buffer, &dep)
}

create_compute_pipeline :: proc(
  gctx: ^GPUContext,
  shader: vk.ShaderModule,
  layout: vk.PipelineLayout,
  entry_point: cstring = "main",
) -> (
  pipeline: vk.Pipeline,
  ret: vk.Result,
) {
  info := vk.ComputePipelineCreateInfo {
    sType = .COMPUTE_PIPELINE_CREATE_INFO,
    stage = {
      sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
      stage = {.COMPUTE},
      module = shader,
      pName = entry_point,
    },
    layout = layout,
  }
  vk.CreateComputePipelines(gctx.device, 0, 1, &info, nil, &pipeline) or_return
  ret = .SUCCESS
  return
}

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

set_viewport_scissor :: proc(
  command_buffer: vk.CommandBuffer,
  extent: vk.Extent2D,
  flip_x: bool = false,
  flip_y: bool = true,
) {
  viewport := vk.Viewport {
    x        = flip_x ? f32(extent.width) : 0,
    y        = flip_y ? f32(extent.height) : 0,
    width    = flip_x ? -f32(extent.width) : f32(extent.width),
    height   = flip_y ? -f32(extent.height) : f32(extent.height),
    minDepth = 0.0,
    maxDepth = 1.0,
  }
  scissor := vk.Rect2D {
    extent = extent,
  }
  vk.CmdSetViewport(command_buffer, 0, 1, &viewport)
  vk.CmdSetScissor(command_buffer, 0, 1, &scissor)
}

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
}

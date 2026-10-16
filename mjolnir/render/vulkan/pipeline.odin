package vulkan_backend

import vk "vendor:vulkan"

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

// begin_record begins command_buffer, fresh or of a pool reset since, one-time submit by default.
begin_record :: proc(
  command_buffer: vk.CommandBuffer,
  flags: vk.CommandBufferUsageFlags = {.ONE_TIME_SUBMIT},
) -> vk.Result {
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

// allocate_command_buffer allocates primary command buffers from pool.
allocate_command_buffer :: proc(
  gctx: ^GPUContext,
  out_commands: []vk.CommandBuffer,
  pool: vk.CommandPool,
) -> vk.Result {
  return vk.AllocateCommandBuffers(
    gctx.device,
    &vk.CommandBufferAllocateInfo {
      sType = .COMMAND_BUFFER_ALLOCATE_INFO,
      commandPool = pool,
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

// attachment_discard returns the ImageDiscard of an image about to be written whole: a color one
// as an attachment or a storage image (compute), a depth one as an attachment.
attachment_discard :: proc(img: ^Image) -> ImageDiscard {
  aspect := infer_aspect_mask(img.format)
  if .COLOR in aspect do return {img.image, aspect, {.COLOR_ATTACHMENT_WRITE, .SHADER_STORAGE_WRITE}, {.COLOR_ATTACHMENT_OUTPUT, .COMPUTE_SHADER}}
  return {img.image, aspect, {.DEPTH_STENCIL_ATTACHMENT_WRITE}, {.EARLY_FRAGMENT_TESTS}}
}

// image_discard_barrier records every discard in one dependency.
image_discard_barrier :: proc(command_buffer: vk.CommandBuffer, discards: ..ImageDiscard) {
  dep := vk.DependencyInfo{sType = .DEPENDENCY_INFO}
  image_discards_fill(&dep, discards)
  vk.CmdPipelineBarrier2(command_buffer, &dep)
}

// The image barriers of `discards` into dep. Each orders after all earlier work (the source is
// every stage, no access: a write-after-read), so it chains with any semaphore wait before it.
image_discards_fill :: proc(dep: ^vk.DependencyInfo, discards: []ImageDiscard) {
  barriers := make([]vk.ImageMemoryBarrier2, len(discards), context.temp_allocator)
  for d, i in discards {
    barriers[i] = {
      sType = .IMAGE_MEMORY_BARRIER_2,
      srcStageMask = {.ALL_COMMANDS},
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
  dep.imageMemoryBarrierCount = u32(len(barriers))
  dep.pImageMemoryBarriers = raw_data(barriers)
}

// present_barrier moves a swapchain image from GENERAL to PRESENT_SRC, the one layout
// transition unified image layouts do not cover.
present_barrier :: proc(command_buffer: vk.CommandBuffer, image: vk.Image) {
  barrier := vk.ImageMemoryBarrier2 {
    sType = .IMAGE_MEMORY_BARRIER_2,
    srcStageMask = {.COLOR_ATTACHMENT_OUTPUT},
    srcAccessMask = {.COLOR_ATTACHMENT_WRITE},
    dstStageMask = {.BOTTOM_OF_PIPE},
    oldLayout = .GENERAL,
    newLayout = .PRESENT_SRC_KHR,
    srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
    dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
    image = image,
    subresourceRange = {aspectMask = {.COLOR}, levelCount = 1, layerCount = 1},
  }
  dep := vk.DependencyInfo {
    sType                   = .DEPENDENCY_INFO,
    imageMemoryBarrierCount = 1,
    pImageMemoryBarriers    = &barrier,
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

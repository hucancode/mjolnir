package geometry_pass

import cont "../../containers"
import "../../geometry"
import "../../gpu"
import "../../resources"
import "../shared"
import "core:log"
import vk "vendor:vulkan"

SHADER_G_BUFFER_VERT :: #load("../../shader/gbuffer/vert.spv")
SHADER_G_BUFFER_FRAG :: #load("../../shader/gbuffer/frag.spv")

PushConstant :: struct {
  camera_index: u32,
}

Renderer :: struct {
  pipeline: vk.Pipeline,
  commands: [resources.MAX_FRAMES_IN_FLIGHT]vk.CommandBuffer,
}

init :: proc(
  self: ^Renderer,
  gctx: ^gpu.GPUContext,
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
  depth_format: vk.Format = .D32_SFLOAT
  if rm.geometry_pipeline_layout == 0 {
    return .ERROR_INITIALIZATION_FAILED
  }
  spec_data, spec_entries, spec_info := shared.make_shader_spec_constants()
  spec_info.pData = cast(rawptr)&spec_data
  defer delete(spec_entries)
  log.info("About to build G-buffer pipelines...")
  vert_module := gpu.create_shader_module(
    gctx.device,
    SHADER_G_BUFFER_VERT,
  ) or_return
  defer vk.DestroyShaderModule(gctx.device, vert_module, nil)
  frag_module := gpu.create_shader_module(
    gctx.device,
    SHADER_G_BUFFER_FRAG,
  ) or_return
  defer vk.DestroyShaderModule(gctx.device, frag_module, nil)
  vertex_input_info := vk.PipelineVertexInputStateCreateInfo {
    sType                           = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
    vertexBindingDescriptionCount   = len(geometry.VERTEX_BINDING_DESCRIPTION),
    pVertexBindingDescriptions      = raw_data(
      geometry.VERTEX_BINDING_DESCRIPTION[:],
    ),
    vertexAttributeDescriptionCount = len(
      geometry.VERTEX_ATTRIBUTE_DESCRIPTIONS,
    ),
    pVertexAttributeDescriptions    = raw_data(
      geometry.VERTEX_ATTRIBUTE_DESCRIPTIONS[:],
    ),
  }
  input_assembly := gpu.create_standard_input_assembly()
  viewport_state := vk.PipelineViewportStateCreateInfo {
    sType         = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
    viewportCount = 1,
    scissorCount  = 1,
  }
  rasterizer := gpu.create_standard_rasterizer()
  multisampling := gpu.create_standard_multisampling()
  depth_stencil := vk.PipelineDepthStencilStateCreateInfo {
    sType            = .PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
    depthTestEnable  = true,
    depthWriteEnable = false,
    depthCompareOp   = .LESS_OR_EQUAL,
  }
  color_blend_attachments := [?]vk.PipelineColorBlendAttachmentState {
    {colorWriteMask = {.R, .G, .B, .A}}, // position
    {colorWriteMask = {.R, .G, .B, .A}}, // normal
    {colorWriteMask = {.R, .G, .B, .A}}, // albedo
    {colorWriteMask = {.R, .G, .B, .A}}, // metallic/roughness
    {colorWriteMask = {.R, .G, .B, .A}}, // emissive
  }
  color_blending := vk.PipelineColorBlendStateCreateInfo {
    sType           = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
    attachmentCount = len(color_blend_attachments),
    pAttachments    = raw_data(color_blend_attachments[:]),
  }
  dynamic_state := gpu.create_dynamic_state(gpu.STANDARD_DYNAMIC_STATES[:])
  color_formats := [?]vk.Format {
    .R32G32B32A32_SFLOAT, // position
    .R8G8B8A8_UNORM, // normal
    .R8G8B8A8_UNORM, // albedo
    .R8G8B8A8_UNORM, // metallic/roughness
    .R8G8B8A8_UNORM, // emissive
  }
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
      pSpecializationInfo = &spec_info,
    },
    {
      sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
      stage = {.FRAGMENT},
      module = frag_module,
      pName = "main",
      pSpecializationInfo = &spec_info,
    },
  }
  pipeline_info := vk.GraphicsPipelineCreateInfo {
    sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
    stageCount          = len(shader_stages),
    pStages             = raw_data(shader_stages[:]),
    pVertexInputState   = &vertex_input_info,
    pInputAssemblyState = &input_assembly,
    pViewportState      = &viewport_state,
    pRasterizationState = &rasterizer,
    pMultisampleState   = &multisampling,
    pDepthStencilState  = &depth_stencil,
    pColorBlendState    = &color_blending,
    pDynamicState       = &dynamic_state,
    layout              = rm.geometry_pipeline_layout,
    pNext               = &rendering_info,
  }
  vk.CreateGraphicsPipelines(
    gctx.device,
    0,
    1,
    &pipeline_info,
    nil,
    &self.pipeline,
  ) or_return
  log.info("G-buffer renderer initialized successfully")
  return .SUCCESS
}

begin_pass :: proc(
  camera_handle: resources.Handle,
  command_buffer: vk.CommandBuffer,
  rm: ^resources.Manager,
  frame_index: u32,
) {
  camera := cont.get(rm.cameras, camera_handle)
  if camera == nil do return
  // Transition all G-buffer textures to COLOR_ATTACHMENT_OPTIMAL
  position_texture := cont.get(
    rm.image_2d_buffers,
    resources.camera_get_attachment(camera, .POSITION, frame_index),
  )
  normal_texture := cont.get(
    rm.image_2d_buffers,
    resources.camera_get_attachment(camera, .NORMAL, frame_index),
  )
  albedo_texture := cont.get(
    rm.image_2d_buffers,
    resources.camera_get_attachment(camera, .ALBEDO, frame_index),
  )
  metallic_roughness_texture := cont.get(
    rm.image_2d_buffers,
    resources.camera_get_attachment(camera, .METALLIC_ROUGHNESS, frame_index),
  )
  emissive_texture := cont.get(
    rm.image_2d_buffers,
    resources.camera_get_attachment(camera, .EMISSIVE, frame_index),
  )
  final_texture := cont.get(
    rm.image_2d_buffers,
    resources.camera_get_attachment(camera, .FINAL_IMAGE, frame_index),
  )
  // Transition all G-buffer images from UNDEFINED to COLOR_ATTACHMENT_OPTIMAL
  image_barriers := [?]vk.ImageMemoryBarrier {
    // Position
    {
      sType = .IMAGE_MEMORY_BARRIER,
      srcAccessMask = {},
      dstAccessMask = {.COLOR_ATTACHMENT_WRITE},
      oldLayout = .UNDEFINED,
      newLayout = .COLOR_ATTACHMENT_OPTIMAL,
      srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
      dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
      image = position_texture.image,
      subresourceRange = {
        aspectMask = {.COLOR},
        levelCount = 1,
        layerCount = 1,
      },
    },
    // Normal
    {
      sType = .IMAGE_MEMORY_BARRIER,
      srcAccessMask = {},
      dstAccessMask = {.COLOR_ATTACHMENT_WRITE},
      oldLayout = .UNDEFINED,
      newLayout = .COLOR_ATTACHMENT_OPTIMAL,
      srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
      dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
      image = normal_texture.image,
      subresourceRange = {
        aspectMask = {.COLOR},
        levelCount = 1,
        layerCount = 1,
      },
    },
    // Albedo
    {
      sType = .IMAGE_MEMORY_BARRIER,
      srcAccessMask = {},
      dstAccessMask = {.COLOR_ATTACHMENT_WRITE},
      oldLayout = .UNDEFINED,
      newLayout = .COLOR_ATTACHMENT_OPTIMAL,
      srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
      dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
      image = albedo_texture.image,
      subresourceRange = {
        aspectMask = {.COLOR},
        levelCount = 1,
        layerCount = 1,
      },
    },
    // Metallic/Roughness
    {
      sType = .IMAGE_MEMORY_BARRIER,
      srcAccessMask = {},
      dstAccessMask = {.COLOR_ATTACHMENT_WRITE},
      oldLayout = .UNDEFINED,
      newLayout = .COLOR_ATTACHMENT_OPTIMAL,
      srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
      dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
      image = metallic_roughness_texture.image,
      subresourceRange = {
        aspectMask = {.COLOR},
        levelCount = 1,
        layerCount = 1,
      },
    },
    // Emissive
    {
      sType = .IMAGE_MEMORY_BARRIER,
      srcAccessMask = {},
      dstAccessMask = {.COLOR_ATTACHMENT_WRITE},
      oldLayout = .UNDEFINED,
      newLayout = .COLOR_ATTACHMENT_OPTIMAL,
      srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
      dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
      image = emissive_texture.image,
      subresourceRange = {
        aspectMask = {.COLOR},
        levelCount = 1,
        layerCount = 1,
      },
    },
    // Final image
    {
      sType = .IMAGE_MEMORY_BARRIER,
      srcAccessMask = {},
      dstAccessMask = {.COLOR_ATTACHMENT_WRITE},
      oldLayout = .UNDEFINED,
      newLayout = .COLOR_ATTACHMENT_OPTIMAL,
      srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
      dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
      image = final_texture.image,
      subresourceRange = {
        aspectMask = {.COLOR},
        levelCount = 1,
        layerCount = 1,
      },
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
    len(image_barriers),
    raw_data(image_barriers[:]),
  )
  depth_texture := cont.get(
    rm.image_2d_buffers,
    camera.attachments[.DEPTH][frame_index],
  )
  position_attachment := vk.RenderingAttachmentInfo {
    sType = .RENDERING_ATTACHMENT_INFO,
    imageView = position_texture.view,
    imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
    loadOp = .CLEAR,
    storeOp = .STORE,
    clearValue = {color = {float32 = {0.0, 0.0, 0.0, 0.0}}},
  }
  normal_attachment := vk.RenderingAttachmentInfo {
    sType = .RENDERING_ATTACHMENT_INFO,
    imageView = normal_texture.view,
    imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
    loadOp = .CLEAR,
    storeOp = .STORE,
    clearValue = {color = {float32 = {0.0, 0.0, 0.0, 1.0}}},
  }
  albedo_attachment := vk.RenderingAttachmentInfo {
    sType = .RENDERING_ATTACHMENT_INFO,
    imageView = albedo_texture.view,
    imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
    loadOp = .CLEAR,
    storeOp = .STORE,
    clearValue = {color = {float32 = {0.0, 0.0, 0.0, 1.0}}},
  }
  metallic_roughness_attachment := vk.RenderingAttachmentInfo {
    sType = .RENDERING_ATTACHMENT_INFO,
    imageView = metallic_roughness_texture.view,
    imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
    loadOp = .CLEAR,
    storeOp = .STORE,
    clearValue = {color = {float32 = {0.0, 0.0, 0.0, 1.0}}},
  }
  emissive_attachment := vk.RenderingAttachmentInfo {
    sType = .RENDERING_ATTACHMENT_INFO,
    imageView = emissive_texture.view,
    imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
    loadOp = .CLEAR,
    storeOp = .STORE,
    clearValue = {color = {float32 = {0.0, 0.0, 0.0, 1.0}}},
  }
  depth_attachment := vk.RenderingAttachmentInfo {
    sType = .RENDERING_ATTACHMENT_INFO,
    imageView = depth_texture.view,
    imageLayout = .DEPTH_STENCIL_READ_ONLY_OPTIMAL,
    loadOp = .LOAD,
    storeOp = .STORE,
    clearValue = {depthStencil = {depth = 1.0, stencil = 0}},
  }
  color_attachments := [?]vk.RenderingAttachmentInfoKHR {
    position_attachment,
    normal_attachment,
    albedo_attachment,
    metallic_roughness_attachment,
    emissive_attachment,
  }
  extent := camera.extent
  render_info := vk.RenderingInfo {
    sType = .RENDERING_INFO,
    renderArea = {extent = extent},
    layerCount = 1,
    colorAttachmentCount = len(color_attachments),
    pColorAttachments = raw_data(color_attachments[:]),
    pDepthAttachment = &depth_attachment,
  }
  vk.CmdBeginRendering(command_buffer, &render_info)
  viewport := vk.Viewport {
    x        = 0,
    y        = f32(extent.height),
    width    = f32(extent.width),
    height   = -f32(extent.height),
    minDepth = 0.0,
    maxDepth = 1.0,
  }
  scissor := vk.Rect2D {
    extent = extent,
  }
  vk.CmdSetViewport(command_buffer, 0, 1, &viewport)
  vk.CmdSetScissor(command_buffer, 0, 1, &scissor)
}

end_pass :: proc(
  camera_handle: resources.Handle,
  command_buffer: vk.CommandBuffer,
  rm: ^resources.Manager,
  frame_index: u32,
) {
  vk.CmdEndRendering(command_buffer)
  camera := cont.get(rm.cameras, camera_handle)
  if camera == nil do return
  // transition all G-buffer textures to SHADER_READ_ONLY_OPTIMAL for use by lighting and post-processing
  position_texture := cont.get(
    rm.image_2d_buffers,
    resources.camera_get_attachment(camera, .POSITION, frame_index),
  )
  normal_texture := cont.get(
    rm.image_2d_buffers,
    resources.camera_get_attachment(camera, .NORMAL, frame_index),
  )
  albedo_texture := cont.get(
    rm.image_2d_buffers,
    resources.camera_get_attachment(camera, .ALBEDO, frame_index),
  )
  metallic_roughness_texture := cont.get(
    rm.image_2d_buffers,
    resources.camera_get_attachment(camera, .METALLIC_ROUGHNESS, frame_index),
  )
  emissive_texture := cont.get(
    rm.image_2d_buffers,
    resources.camera_get_attachment(camera, .EMISSIVE, frame_index),
  )
  depth_texture := cont.get(
    rm.image_2d_buffers,
    resources.camera_get_attachment(camera, .DEPTH, frame_index),
  )
  // transition all G-buffer attachments + depth to SHADER_READ_ONLY_OPTIMAL
  image_barriers := [?]vk.ImageMemoryBarrier {
    // Position
    {
      sType = .IMAGE_MEMORY_BARRIER,
      srcAccessMask = {.COLOR_ATTACHMENT_WRITE},
      dstAccessMask = {.SHADER_READ},
      oldLayout = .COLOR_ATTACHMENT_OPTIMAL,
      newLayout = .SHADER_READ_ONLY_OPTIMAL,
      srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
      dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
      image = position_texture.image,
      subresourceRange = {
        aspectMask = {.COLOR},
        levelCount = 1,
        layerCount = 1,
      },
    },
    // Normal
    {
      sType = .IMAGE_MEMORY_BARRIER,
      srcAccessMask = {.COLOR_ATTACHMENT_WRITE},
      dstAccessMask = {.SHADER_READ},
      oldLayout = .COLOR_ATTACHMENT_OPTIMAL,
      newLayout = .SHADER_READ_ONLY_OPTIMAL,
      srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
      dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
      image = normal_texture.image,
      subresourceRange = {
        aspectMask = {.COLOR},
        levelCount = 1,
        layerCount = 1,
      },
    },
    // Albedo
    {
      sType = .IMAGE_MEMORY_BARRIER,
      srcAccessMask = {.COLOR_ATTACHMENT_WRITE},
      dstAccessMask = {.SHADER_READ},
      oldLayout = .COLOR_ATTACHMENT_OPTIMAL,
      newLayout = .SHADER_READ_ONLY_OPTIMAL,
      srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
      dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
      image = albedo_texture.image,
      subresourceRange = {
        aspectMask = {.COLOR},
        levelCount = 1,
        layerCount = 1,
      },
    },
    // Metallic/Roughness
    {
      sType = .IMAGE_MEMORY_BARRIER,
      srcAccessMask = {.COLOR_ATTACHMENT_WRITE},
      dstAccessMask = {.SHADER_READ},
      oldLayout = .COLOR_ATTACHMENT_OPTIMAL,
      newLayout = .SHADER_READ_ONLY_OPTIMAL,
      srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
      dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
      image = metallic_roughness_texture.image,
      subresourceRange = {
        aspectMask = {.COLOR},
        levelCount = 1,
        layerCount = 1,
      },
    },
    // Emissive
    {
      sType = .IMAGE_MEMORY_BARRIER,
      srcAccessMask = {.COLOR_ATTACHMENT_WRITE},
      dstAccessMask = {.SHADER_READ},
      oldLayout = .COLOR_ATTACHMENT_OPTIMAL,
      newLayout = .SHADER_READ_ONLY_OPTIMAL,
      srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
      dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
      image = emissive_texture.image,
      subresourceRange = {
        aspectMask = {.COLOR},
        levelCount = 1,
        layerCount = 1,
      },
    },
  }
  vk.CmdPipelineBarrier(
    command_buffer,
    {.COLOR_ATTACHMENT_OUTPUT, .LATE_FRAGMENT_TESTS},
    {.FRAGMENT_SHADER},
    {},
    0,
    nil,
    0,
    nil,
    len(image_barriers),
    raw_data(image_barriers[:]),
  )
}

render :: proc(
  self: ^Renderer,
  camera_handle: resources.Handle,
  command_buffer: vk.CommandBuffer,
  rm: ^resources.Manager,
  frame_index: u32,
  draw_buffer: vk.Buffer,
  count_buffer: vk.Buffer,
  command_stride: u32,
) {
  if draw_buffer == 0 || count_buffer == 0 {
    return
  }
  descriptor_sets := [?]vk.DescriptorSet {
    rm.camera_buffer_descriptor_sets[frame_index], // Per-frame to avoid overlap
    rm.textures_descriptor_set,
    rm.bone_buffer_descriptor_set,
    rm.material_buffer_descriptor_set,
    rm.world_matrix_descriptor_set,
    rm.node_data_descriptor_set,
    rm.mesh_data_descriptor_set,
    rm.vertex_skinning_descriptor_set,
  }
  vk.CmdBindDescriptorSets(
    command_buffer,
    .GRAPHICS,
    rm.geometry_pipeline_layout,
    0,
    len(descriptor_sets),
    raw_data(descriptor_sets[:]),
    0,
    nil,
  )
  vk.CmdBindPipeline(command_buffer, .GRAPHICS, self.pipeline)
  push_constants := PushConstant {
    camera_index = camera_handle.index,
  }
  vk.CmdPushConstants(
    command_buffer,
    rm.geometry_pipeline_layout,
    {.VERTEX, .FRAGMENT},
    0,
    size_of(PushConstant),
    &push_constants,
  )
  vertex_buffers := [1]vk.Buffer{rm.vertex_buffer.buffer}
  vertex_offsets := [1]vk.DeviceSize{0}
  vk.CmdBindVertexBuffers(
    command_buffer,
    0,
    1,
    raw_data(vertex_buffers[:]),
    raw_data(vertex_offsets[:]),
  )
  vk.CmdBindIndexBuffer(command_buffer, rm.index_buffer.buffer, 0, .UINT32)
  vk.CmdDrawIndexedIndirectCount(
    command_buffer,
    draw_buffer,
    0,
    count_buffer,
    0,
    resources.MAX_NODES_IN_SCENE,
    command_stride,
  )
}

shutdown :: proc(
  self: ^Renderer,
  device: vk.Device,
  command_pool: vk.CommandPool,
) {
  vk.FreeCommandBuffers(
    device,
    command_pool,
    u32(len(self.commands)),
    raw_data(self.commands[:]),
  )
  vk.DestroyPipeline(device, self.pipeline, nil)
  self.pipeline = 0
}

begin_record :: proc(
  self: ^Renderer,
  frame_index: u32,
  camera_handle: resources.Handle,
  rm: ^resources.Manager,
) -> (
  command_buffer: vk.CommandBuffer,
  ret: vk.Result,
) {
  camera := cont.get(rm.cameras, camera_handle)
  if camera == nil {
    ret = .ERROR_UNKNOWN
    return
  }
  command_buffer = camera.geometry_commands[frame_index]
  vk.ResetCommandBuffer(command_buffer, {}) or_return
  color_formats := [?]vk.Format {
    .R32G32B32A32_SFLOAT,
    .R8G8B8A8_UNORM,
    .R8G8B8A8_UNORM,
    .R8G8B8A8_UNORM,
    .R8G8B8A8_UNORM,
  }
  rendering_info := vk.CommandBufferInheritanceRenderingInfo {
    sType                   = .COMMAND_BUFFER_INHERITANCE_RENDERING_INFO,
    colorAttachmentCount    = len(color_formats),
    pColorAttachmentFormats = raw_data(color_formats[:]),
    depthAttachmentFormat   = .D32_SFLOAT,
    rasterizationSamples    = {._1}, // No MSAA, single sample per pixel
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
  return command_buffer, .SUCCESS
}

end_record :: proc(
  command_buffer: vk.CommandBuffer,
  camera_handle: resources.Handle,
  rm: ^resources.Manager,
  frame_index: u32,
) -> vk.Result {
  vk.EndCommandBuffer(command_buffer) or_return
  return .SUCCESS
}

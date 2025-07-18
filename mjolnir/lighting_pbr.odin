package mjolnir

import "core:fmt"
import "core:log"
import "core:slice"
import "geometry"
import "gpu"
import "resource"
import mu "vendor:microui"
import vk "vendor:vulkan"

BG_BLUE_GRAY :: [4]f32{0.0117, 0.0117, 0.0179, 1.0}
BG_DARK_GRAY :: [4]f32{0.0117, 0.0117, 0.0117, 1.0}
BG_ORANGE_GRAY :: [4]f32{0.0179, 0.0179, 0.0117, 1.0}

RendererLighting :: struct {
  lighting_pipeline:        vk.Pipeline,
  spot_light_pipeline:      vk.Pipeline,
  lighting_pipeline_layout: vk.PipelineLayout,
  // Light volume meshes
  sphere_mesh:              Handle,
  cone_mesh:                Handle,
  fullscreen_triangle_mesh: Handle,
}
lighting_init :: proc(
  self: ^RendererLighting,
  gpu_context: ^gpu.GPUContext,
  width, height: u32,
  color_format: vk.Format = .B8G8R8A8_SRGB,
  depth_format: vk.Format = .D32_SFLOAT,
  warehouse: ^ResourceWarehouse,
) -> vk.Result {
  log.debugf("renderer main init %d x %d", width, height)
  // g_textures_set_layout (set 1) must be created and managed globally, not here
  pipeline_set_layouts := [?]vk.DescriptorSetLayout {
    warehouse.camera_buffer_set_layout, // set = 0 (camera)
    warehouse.textures_set_layout, // set = 1 (bindless textures)
  }
  push_constant_range := vk.PushConstantRange {
    stageFlags = {.VERTEX, .FRAGMENT},
    size       = size_of(LightPushConstant),
  }
  vk.CreatePipelineLayout(
    gpu_context.device,
    &vk.PipelineLayoutCreateInfo {
      sType = .PIPELINE_LAYOUT_CREATE_INFO,
      setLayoutCount = len(pipeline_set_layouts),
      pSetLayouts = raw_data(pipeline_set_layouts[:]),
      pushConstantRangeCount = 1,
      pPushConstantRanges = &push_constant_range,
    },
    nil,
    &self.lighting_pipeline_layout,
  ) or_return
  vert_shader_code := #load("shader/lighting/vert.spv")
  vert_module := gpu.create_shader_module(
    gpu_context,
    vert_shader_code,
  ) or_return
  defer vk.DestroyShaderModule(gpu_context.device, vert_module, nil)
  frag_shader_code := #load("shader/lighting/frag.spv")
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
    sType                           = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
    vertexBindingDescriptionCount   = 1,
    pVertexBindingDescriptions      = &geometry.VERTEX_BINDING_DESCRIPTION[0],
    vertexAttributeDescriptionCount = 1, // Only position needed for lighting
    pVertexAttributeDescriptions    = &geometry.VERTEX_ATTRIBUTE_DESCRIPTIONS[0], // Position at location 0
  }
  viewport_state := vk.PipelineViewportStateCreateInfo {
    sType         = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
    viewportCount = 1,
    scissorCount  = 1,
  }
  rasterizer := vk.PipelineRasterizationStateCreateInfo {
    sType       = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
    polygonMode = .FILL,
    cullMode    = {.FRONT},
    frontFace   = .COUNTER_CLOCKWISE,
    lineWidth   = 1.0,
  }
  multisampling := vk.PipelineMultisampleStateCreateInfo {
    sType                = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
    rasterizationSamples = {._1},
  }
  color_blend_attachment := vk.PipelineColorBlendAttachmentState {
    colorWriteMask      = {.R, .G, .B, .A},
    blendEnable         = true,
    srcColorBlendFactor = .ONE,
    dstColorBlendFactor = .ONE,
    colorBlendOp        = .ADD,
    srcAlphaBlendFactor = .ONE,
    dstAlphaBlendFactor = .ONE,
    alphaBlendOp        = .ADD,
  }
  color_blending := vk.PipelineColorBlendStateCreateInfo {
    sType           = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
    attachmentCount = 1,
    pAttachments    = &color_blend_attachment,
  }
  depth_stencil := vk.PipelineDepthStencilStateCreateInfo {
    sType           = .PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
    depthTestEnable = true,
    depthCompareOp  = .GREATER_OR_EQUAL, // Default value, will be overridden dynamically
  }
  color_formats := [?]vk.Format{color_format}
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
    layout              = self.lighting_pipeline_layout,
  }
  vk.CreateGraphicsPipelines(
    gpu_context.device,
    0,
    1,
    &pipeline_info,
    nil,
    &self.lighting_pipeline,
  ) or_return
  log.info("Lighting pipeline initialized successfully")

  // Create second pipeline for spot lights with LESS_OR_EQUAL depth test
  spot_depth_stencil := vk.PipelineDepthStencilStateCreateInfo {
    sType           = .PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
    depthTestEnable = true,
    depthCompareOp  = .LESS_OR_EQUAL,
  }
  spot_pipeline_info := vk.GraphicsPipelineCreateInfo {
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
    pDepthStencilState  = &spot_depth_stencil,
    layout              = self.lighting_pipeline_layout,
  }
  vk.CreateGraphicsPipelines(
    gpu_context.device,
    0,
    1,
    &spot_pipeline_info,
    nil,
    &self.spot_light_pipeline,
  ) or_return
  log.info("Spot light pipeline initialized successfully")
  // Initialize light volume meshes
  self.sphere_mesh, _, _ = create_mesh(
    gpu_context,
    warehouse,
    geometry.make_sphere(segments = 128, rings = 128),
  )
  self.cone_mesh, _, _ = create_mesh(
    gpu_context,
    warehouse,
    geometry.make_cone(segments = 128, height = 1, radius = 0.5),
  )
  self.fullscreen_triangle_mesh, _, _ = create_mesh(
    gpu_context,
    warehouse,
    geometry.make_fullscreen_triangle(),
  )
  log.info("Light volume meshes initialized")

  return .SUCCESS
}

lighting_deinit :: proc(
  self: ^RendererLighting,
  gpu_context: ^gpu.GPUContext,
) {
  vk.DestroyPipelineLayout(
    gpu_context.device,
    self.lighting_pipeline_layout,
    nil,
  )
  vk.DestroyPipeline(gpu_context.device, self.lighting_pipeline, nil)
  vk.DestroyPipeline(gpu_context.device, self.spot_light_pipeline, nil)
}

lighting_recreate_images :: proc(
  self: ^RendererLighting,
  width, height: u32,
  color_format: vk.Format,
  depth_format: vk.Format,
) -> vk.Result {
  log.debugf("Updated G-buffer indices for lighting pass on resize")
  return .SUCCESS
}

lighting_begin :: proc(
  self: ^RendererLighting,
  target: ^RenderTarget,
  command_buffer: vk.CommandBuffer,
  warehouse: ^ResourceWarehouse,
  frame_index: u32,
) {
  final_image := resource.get(
    warehouse.image_2d_buffers,
    render_target_final_image(target, frame_index),
  )
  color_attachment := vk.RenderingAttachmentInfoKHR {
    sType = .RENDERING_ATTACHMENT_INFO_KHR,
    imageView = final_image.view,
    imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
    loadOp = .LOAD,
    storeOp = .STORE,
    clearValue = {color = {float32 = BG_BLUE_GRAY}},
  }
  depth_texture := resource.get(
    warehouse.image_2d_buffers,
    render_target_depth_texture(target, frame_index),
  )
  depth_attachment := vk.RenderingAttachmentInfoKHR {
    sType       = .RENDERING_ATTACHMENT_INFO_KHR,
    imageView   = depth_texture.view,
    imageLayout = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
    loadOp      = .LOAD,
    storeOp     = .DONT_CARE,
  }
  render_info := vk.RenderingInfoKHR {
    sType = .RENDERING_INFO_KHR,
    renderArea = {extent = target.extent},
    layerCount = 1,
    colorAttachmentCount = 1,
    pColorAttachments = &color_attachment,
    pDepthAttachment = &depth_attachment,
  }
  vk.CmdBeginRenderingKHR(command_buffer, &render_info)
  viewport := vk.Viewport {
    x        = 0,
    y        = f32(target.extent.height),
    width    = f32(target.extent.width),
    height   = -f32(target.extent.height),
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
    self.lighting_pipeline_layout,
    0,
    len(descriptor_sets),
    raw_data(descriptor_sets[:]),
    0,
    nil,
  )
  vk.CmdBindPipeline(command_buffer, .GRAPHICS, self.lighting_pipeline)
}

lighting_render :: proc(
  self: ^RendererLighting,
  input: []LightInfo,
  render_target: ^RenderTarget,
  command_buffer: vk.CommandBuffer,
  warehouse: ^ResourceWarehouse,
  frame_index: u32,
) -> int {
  rendered_count := 0
  node_count := 0

  // Helper proc to bind and draw a mesh
  bind_and_draw_mesh :: proc(
    mesh_handle: Handle,
    command_buffer: vk.CommandBuffer,
    warehouse: ^ResourceWarehouse,
  ) {
    mesh := resource.get(warehouse.meshes, mesh_handle)
    offset: vk.DeviceSize = 0
    vk.CmdBindVertexBuffers(
      command_buffer,
      0,
      1,
      &mesh.vertex_buffer.buffer,
      &offset,
    )
    vk.CmdBindIndexBuffer(command_buffer, mesh.index_buffer.buffer, 0, .UINT32)
    vk.CmdDrawIndexed(command_buffer, mesh.indices_len, 1, 0, 0, 0)
  }

  for &light_info in input {
    node_count += 1
    // Fill in the common G-buffer indices that are always the same
    light_info.scene_camera_idx = render_target.camera.index
    light_info.position_texture_index =
      render_target_position_texture(render_target, frame_index).index
    light_info.normal_texture_index =
      render_target_normal_texture(render_target, frame_index).index
    light_info.albedo_texture_index =
      render_target_albedo_texture(render_target, frame_index).index
    light_info.metallic_texture_index =
      render_target_metallic_roughness_texture(render_target, frame_index).index
    light_info.emissive_texture_index =
      render_target_emissive_texture(render_target, frame_index).index
    light_info.depth_texture_index =
      render_target_depth_texture(render_target, frame_index).index
    light_info.input_image_index =
      render_target_final_image(render_target, frame_index).index

    // Render based on light type
    switch light_info.light_kind {
    case .POINT:
      vk.CmdBindPipeline(command_buffer, .GRAPHICS, self.lighting_pipeline)
      vk.CmdPushConstants(
        command_buffer,
        self.lighting_pipeline_layout,
        {.VERTEX, .FRAGMENT},
        0,
        size_of(LightPushConstant),
        &light_info.gpu_data,
      )
      bind_and_draw_mesh(self.sphere_mesh, command_buffer, warehouse)
      rendered_count += 1

    case .DIRECTIONAL:
      vk.CmdBindPipeline(command_buffer, .GRAPHICS, self.lighting_pipeline)
      vk.CmdPushConstants(
        command_buffer,
        self.lighting_pipeline_layout,
        {.VERTEX, .FRAGMENT},
        0,
        size_of(LightPushConstant),
        &light_info.gpu_data,
      )
      bind_and_draw_mesh(
        self.fullscreen_triangle_mesh,
        command_buffer,
        warehouse,
      )
      rendered_count += 1

    case .SPOT:
      vk.CmdBindPipeline(command_buffer, .GRAPHICS, self.spot_light_pipeline)
      vk.CmdPushConstants(
        command_buffer,
        self.lighting_pipeline_layout,
        {.VERTEX, .FRAGMENT},
        0,
        size_of(LightPushConstant),
        &light_info.gpu_data,
      )
      bind_and_draw_mesh(self.cone_mesh, command_buffer, warehouse)
      rendered_count += 1
    }
  }
  return rendered_count
}

lighting_end :: proc(command_buffer: vk.CommandBuffer) {
  vk.CmdEndRenderingKHR(command_buffer)
}

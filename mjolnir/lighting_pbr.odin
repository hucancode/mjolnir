package mjolnir

import "core:fmt"
import "core:log"
import "core:slice"
import "geometry"
import "resource"
import mu "vendor:microui"
import vk "vendor:vulkan"

BG_BLUE_GRAY :: [4]f32{0.0117, 0.0117, 0.0179, 1.0}
BG_DARK_GRAY :: [4]f32{0.0117, 0.0117, 0.0117, 1.0}
BG_ORANGE_GRAY :: [4]f32{0.0179, 0.0179, 0.0117, 1.0}

GBufferIndicesUniform :: struct {
  gbuffer_position_index: u32,
  gbuffer_normal_index:   u32,
  gbuffer_albedo_index:   u32,
  gbuffer_metallic_index: u32,
  gbuffer_emissive_index: u32,
  gbuffer_depth_index:    u32,
  input_image_index:      u32, // For post-processing input
  padding:                [1]u32,
}

RendererLighting :: struct {
  lighting_pipeline:        vk.Pipeline,
  lighting_pipeline_layout: vk.PipelineLayout,
  lighting_set_layout:      vk.DescriptorSetLayout,
  lighting_descriptor_sets: [MAX_FRAMES_IN_FLIGHT]vk.DescriptorSet,
  gbuffer_uniform_buffers:  [MAX_FRAMES_IN_FLIGHT]DataBuffer(
    GBufferIndicesUniform,
  ),
  environment_map:          Handle,
  brdf_lut:                 Handle,
  environment_max_lod:      f32,
  ibl_intensity:            f32,
  // Light volume meshes
  sphere_mesh:              Handle,
  cone_mesh:                Handle,
  fullscreen_triangle_mesh: Handle,
}
// Push constant struct for lighting pass (matches shader/lighting/shader.frag)
// 128 byte push constant budget
LightPushConstant :: struct {
  light_view_proj: matrix[4,4]f32, // 64 bytes - for shadow mapping
  light_color:     [3]f32, // 12 bytes
  light_angle:     f32, // 4 bytes
  light_position:  [3]f32, // 12 bytes
  light_radius:    f32, // 4 bytes
  light_direction: [3]f32, // 12 bytes
  light_kind:      LightKind, // 4 bytes
  camera_position: [3]f32, // 12 bytes
  shadow_map_id:   u32, // 4 bytes
}

renderer_lighting_init :: proc(
  self: ^RendererLighting,
  frames: ^[MAX_FRAMES_IN_FLIGHT]FrameData,
  width: u32,
  height: u32,
  color_format: vk.Format = .B8G8R8A8_SRGB,
  depth_format: vk.Format = .D32_SFLOAT,
) -> vk.Result {
  log.debugf("renderer main init %d x %d", width, height)
  bindings := [?]vk.DescriptorSetLayoutBinding {
    {   // G-buffer indices uniform buffer
      binding         = 0,
      descriptorType  = .UNIFORM_BUFFER,
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
    &self.lighting_set_layout,
  ) or_return
  // g_textures_set_layout (set 1) must be created and managed globally, not here
  pipeline_set_layouts := [?]vk.DescriptorSetLayout {
    g_camera_descriptor_set_layout, // set = 0 (camera)
    g_textures_set_layout, // set = 1 (bindless textures)
    self.lighting_set_layout, // set = 2 (gbuffer indices uniform buffer)
  }
  push_constant_range := vk.PushConstantRange {
    stageFlags = {.VERTEX, .FRAGMENT},
    size       = size_of(LightPushConstant),
  }
  vk.CreatePipelineLayout(
    g_device,
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
  vert_module := create_shader_module(vert_shader_code) or_return
  defer vk.DestroyShaderModule(g_device, vert_module, nil)
  frag_shader_code := #load("shader/lighting/frag.spv")
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
    depthCompareOp  = .GREATER_OR_EQUAL,
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
    g_device,
    0,
    1,
    &pipeline_info,
    nil,
    &self.lighting_pipeline,
  ) or_return
  log.info("Lighting pipeline initialized successfully")
  environment_map: ^ImageBuffer
  self.environment_map, environment_map =
    create_hdr_texture_from_path_with_mips(
      "assets/Cannon_Exterior.hdr",
    ) or_return
  self.environment_max_lod = 8.0 // default fallback
  if environment_map != nil {
    self.environment_max_lod =
      calculate_mip_levels(environment_map.width, environment_map.height) - 1.0
  }
  brdf_lut: ^ImageBuffer
  self.brdf_lut, brdf_lut = create_texture_from_data(
    #load("assets/lut_ggx.png"),
  ) or_return
  self.ibl_intensity = 1.0 // Default IBL intensity
  lighting_set_layouts: [MAX_FRAMES_IN_FLIGHT]vk.DescriptorSetLayout
  slice.fill(lighting_set_layouts[:], self.lighting_set_layout)
  vk.AllocateDescriptorSets(
    g_device,
    &{
      sType = .DESCRIPTOR_SET_ALLOCATE_INFO,
      descriptorPool = g_descriptor_pool,
      descriptorSetCount = len(lighting_set_layouts),
      pSetLayouts = raw_data(lighting_set_layouts[:]),
    },
    auto_cast &self.lighting_descriptor_sets,
  ) or_return

  // Initialize G-buffer uniform buffers and update descriptor sets
  for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
    self.gbuffer_uniform_buffers[i] = create_host_visible_buffer(
      GBufferIndicesUniform,
      1,
      {.UNIFORM_BUFFER},
    ) or_return

    // Update G-buffer indices with actual handle indices
    gbuffer_uniform := data_buffer_get(&self.gbuffer_uniform_buffers[i], 0)
    gbuffer_uniform.gbuffer_position_index = frames[i].gbuffer_position.index
    gbuffer_uniform.gbuffer_normal_index = frames[i].gbuffer_normal.index
    gbuffer_uniform.gbuffer_albedo_index = frames[i].gbuffer_albedo.index
    gbuffer_uniform.gbuffer_metallic_index =
      frames[i].gbuffer_metallic_roughness.index
    gbuffer_uniform.gbuffer_emissive_index = frames[i].gbuffer_emissive.index
    gbuffer_uniform.gbuffer_depth_index = frames[i].depth_buffer.index

    write := vk.WriteDescriptorSet {
      sType           = .WRITE_DESCRIPTOR_SET,
      dstSet          = self.lighting_descriptor_sets[i],
      dstBinding      = 0,
      descriptorCount = 1,
      descriptorType  = .UNIFORM_BUFFER,
      pBufferInfo     = &{
        buffer = self.gbuffer_uniform_buffers[i].buffer,
        offset = 0,
        range = size_of(GBufferIndicesUniform),
      },
    }
    vk.UpdateDescriptorSets(g_device, 1, &write, 0, nil)
  }

  // Initialize light volume meshes
  self.sphere_mesh, _, _ = create_mesh(
    geometry.make_sphere(segments = 128, rings = 128),
  )
  self.cone_mesh, _, _ = create_mesh(
    geometry.make_cone(segments = 128, height = 1, radius = 0.5),
  )
  self.fullscreen_triangle_mesh, _, _ = create_mesh(
    geometry.make_fullscreen_triangle(),
  )
  log.info("Light volume meshes initialized")

  return .SUCCESS
}

renderer_lighting_deinit :: proc(self: ^RendererLighting) {
  for &buffer in self.gbuffer_uniform_buffers {
    data_buffer_deinit(&buffer)
  }
  vk.DestroyPipelineLayout(g_device, self.lighting_pipeline_layout, nil)
  vk.DestroyPipeline(g_device, self.lighting_pipeline, nil)
  vk.DestroyDescriptorSetLayout(g_device, self.lighting_set_layout, nil)
}

renderer_lighting_recreate_images :: proc(
  self: ^RendererLighting,
  frames: ^[MAX_FRAMES_IN_FLIGHT]FrameData,
  width: u32,
  height: u32,
  color_format: vk.Format,
  depth_format: vk.Format,
) -> vk.Result {
  // Update G-buffer indices in uniform buffers
  for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
    gbuffer_uniform := data_buffer_get(&self.gbuffer_uniform_buffers[i], 0)
    gbuffer_uniform.gbuffer_position_index = frames[i].gbuffer_position.index
    gbuffer_uniform.gbuffer_normal_index = frames[i].gbuffer_normal.index
    gbuffer_uniform.gbuffer_albedo_index = frames[i].gbuffer_albedo.index
    gbuffer_uniform.gbuffer_metallic_index =
      frames[i].gbuffer_metallic_roughness.index
    gbuffer_uniform.gbuffer_emissive_index = frames[i].gbuffer_emissive.index
    gbuffer_uniform.gbuffer_depth_index = frames[i].depth_buffer.index
  }
  log.debugf("Updated G-buffer indices for lighting pass on resize")
  return .SUCCESS
}

renderer_lighting_begin :: proc(
  self: ^RendererLighting,
  target: RenderTarget,
  command_buffer: vk.CommandBuffer,
) {
  color_attachment := vk.RenderingAttachmentInfoKHR {
    sType = .RENDERING_ATTACHMENT_INFO_KHR,
    imageView = target.final,
    imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
    loadOp = .LOAD,
    storeOp = .STORE,
    clearValue = {color = {float32 = BG_BLUE_GRAY}},
  }
  depth_attachment := vk.RenderingAttachmentInfoKHR {
    sType       = .RENDERING_ATTACHMENT_INFO_KHR,
    imageView   = target.depth,
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
    g_camera_descriptor_sets[g_frame_index], // set = 0 (camera)
    g_textures_descriptor_set, // set = 1 (bindless textures)
    self.lighting_descriptor_sets[g_frame_index], // set = 2 (gbuffer indices uniform buffer)
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

renderer_lighting_render :: proc(
  self: ^RendererLighting,
  input: [dynamic]LightData,
  camera_position: [3]f32,
  command_buffer: vk.CommandBuffer,
) -> int {
  rendered_count := 0
  node_count := 0

  // Helper proc to bind and draw a mesh
  bind_and_draw_mesh :: proc(
    mesh_handle: Handle,
    command_buffer: vk.CommandBuffer,
  ) {
    mesh := resource.get(g_meshes, mesh_handle)
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

  for light_data, light_id in input {
    node_count += 1
    #partial switch light in light_data {
    case PointLightData:
      light_push := LightPushConstant {
        light_view_proj = light.proj * light.views[0],
        light_color     = light.color.xyz,
        light_position  = light.position.xyz,
        light_radius    = light.radius,
        light_kind      = LightKind.POINT,
        camera_position = camera_position.xyz,
        shadow_map_id   = u32(light_id),
      }
      vk.CmdPushConstants(
        command_buffer,
        self.lighting_pipeline_layout,
        {.VERTEX, .FRAGMENT},
        0,
        size_of(LightPushConstant),
        &light_push,
      )
      bind_and_draw_mesh(self.sphere_mesh, command_buffer)
      rendered_count += 1
    case DirectionalLightData:
      light_push := LightPushConstant {
        light_view_proj = light.proj * light.view,
        light_color     = light.color.xyz,
        light_direction = light.direction.xyz,
        light_kind      = LightKind.DIRECTIONAL,
        camera_position = camera_position.xyz,
        shadow_map_id   = u32(light_id),
      }
      vk.CmdPushConstants(
        command_buffer,
        self.lighting_pipeline_layout,
        {.VERTEX, .FRAGMENT},
        0,
        size_of(LightPushConstant),
        &light_push,
      )
      bind_and_draw_mesh(self.fullscreen_triangle_mesh, command_buffer)
      rendered_count += 1
    case SpotLightData:
      light_push := LightPushConstant {
        light_view_proj = light.proj * light.view,
        light_color     = light.color.rgb,
        light_angle     = light.angle,
        light_position  = light.position.xyz,
        light_radius    = light.radius,
        light_direction = light.direction.xyz,
        light_kind      = LightKind.SPOT,
        camera_position = camera_position.xyz,
        shadow_map_id   = u32(light_id),
      }
      vk.CmdPushConstants(
        command_buffer,
        self.lighting_pipeline_layout,
        {.VERTEX, .FRAGMENT},
        0,
        size_of(LightPushConstant),
        &light_push,
      )
      bind_and_draw_mesh(self.cone_mesh, command_buffer)
      rendered_count += 1
    }
  }
  return rendered_count
}

renderer_lighting_end :: proc(command_buffer: vk.CommandBuffer) {
  vk.CmdEndRenderingKHR(command_buffer)
}

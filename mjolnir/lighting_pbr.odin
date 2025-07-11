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

RendererLighting :: struct {
  lighting_pipeline:        vk.Pipeline,
  spot_light_pipeline:      vk.Pipeline,
  lighting_pipeline_layout: vk.PipelineLayout,
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
  scene_camera_idx:       u32,
  light_camera_idx:       u32, // for shadow mapping
  shadow_map_id:          u32, // 4 bytes
  light_kind:             LightKind, // 4 bytes
  light_color:            [3]f32, // 12 bytes
  light_angle:            f32, // 4 bytes
  light_position:         [3]f32,
  light_radius:           f32, // 4 bytes
  light_direction:        [3]f32,
  light_cast_shadow:      b32,
  gbuffer_position_index: u32,
  gbuffer_normal_index:   u32,
  gbuffer_albedo_index:   u32,
  gbuffer_metallic_index: u32,
  gbuffer_emissive_index: u32,
  gbuffer_depth_index:    u32,
  input_image_index:      u32, // For post-processing input
}

lighting_init :: proc(
  self: ^RendererLighting,
  width: u32,
  height: u32,
  color_format: vk.Format = .B8G8R8A8_SRGB,
  depth_format: vk.Format = .D32_SFLOAT,
) -> vk.Result {
  log.debugf("renderer main init %d x %d", width, height)
  // g_textures_set_layout (set 1) must be created and managed globally, not here
  pipeline_set_layouts := [?]vk.DescriptorSetLayout {
    g_bindless_camera_buffer_set_layout, // set = 0 (camera)
    g_textures_set_layout, // set = 1 (bindless textures)
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
    g_device,
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
    g_device,
    0,
    1,
    &spot_pipeline_info,
    nil,
    &self.spot_light_pipeline,
  ) or_return
  log.info("Spot light pipeline initialized successfully")

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

lighting_deinit :: proc(self: ^RendererLighting) {
  vk.DestroyPipelineLayout(g_device, self.lighting_pipeline_layout, nil)
  vk.DestroyPipeline(g_device, self.lighting_pipeline, nil)
  vk.DestroyPipeline(g_device, self.spot_light_pipeline, nil)
}

lighting_recreate_images :: proc(
  self: ^RendererLighting,
  width: u32,
  height: u32,
  color_format: vk.Format,
  depth_format: vk.Format,
) -> vk.Result {
  log.debugf("Updated G-buffer indices for lighting pass on resize")
  return .SUCCESS
}

lighting_begin :: proc(
  self: ^RendererLighting,
  target: RenderTarget,
  command_buffer: vk.CommandBuffer,
) {
  final_image := resource.get(g_image_2d_buffers, target.final_image)
  color_attachment := vk.RenderingAttachmentInfoKHR {
    sType = .RENDERING_ATTACHMENT_INFO_KHR,
    imageView = final_image.view,
    imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
    loadOp = .LOAD,
    storeOp = .STORE,
    clearValue = {color = {float32 = BG_BLUE_GRAY}},
  }
  depth_texture := resource.get(g_image_2d_buffers, target.depth_texture)
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
    g_bindless_camera_buffer_descriptor_set, // set = 0 (bindless camera buffer)
    g_textures_descriptor_set, // set = 1 (bindless textures)
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
  input: [dynamic]LightData,
  render_target: ^RenderTarget,
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
      // Bind regular pipeline with GREATER_OR_EQUAL depth test
      vk.CmdBindPipeline(command_buffer, .GRAPHICS, self.lighting_pipeline)

      // Get the first camera from the point light's render targets (all 6 have same position)
      rt := resource.get(g_render_targets, light.render_targets[0])
      light_push := LightPushConstant {
        scene_camera_idx       = render_target.camera.index,
        light_camera_idx       = rt.camera.index, // Use first cube face camera for position
        shadow_map_id          = light.shadow_map.index,
        light_kind             = LightKind.POINT,
        light_color            = light.color.xyz,
        light_position         = light.position.xyz,
        light_radius           = light.radius,
        light_cast_shadow      = light.shadow_map.generation != 0, // Check if shadow map is valid
        gbuffer_position_index = render_target.position_texture.index,
        gbuffer_normal_index   = render_target.normal_texture.index,
        gbuffer_albedo_index   = render_target.albedo_texture.index,
        gbuffer_metallic_index = render_target.metallic_roughness_texture.index,
        gbuffer_emissive_index = render_target.emissive_texture.index,
        gbuffer_depth_index    = render_target.depth_texture.index,
        input_image_index      = render_target.final_image.index,
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
      // Bind regular pipeline with GREATER_OR_EQUAL depth test
      vk.CmdBindPipeline(command_buffer, .GRAPHICS, self.lighting_pipeline)

      light_push := LightPushConstant {
        scene_camera_idx       = render_target.camera.index,
        light_camera_idx       = 0, // TODO: pass correct camera id
        light_kind             = LightKind.DIRECTIONAL,
        light_color            = light.color.xyz,
        light_direction        = light.direction.xyz,
        gbuffer_position_index = render_target.position_texture.index,
        gbuffer_normal_index   = render_target.normal_texture.index,
        gbuffer_albedo_index   = render_target.albedo_texture.index,
        gbuffer_metallic_index = render_target.metallic_roughness_texture.index,
        gbuffer_emissive_index = render_target.emissive_texture.index,
        gbuffer_depth_index    = render_target.depth_texture.index,
        input_image_index      = render_target.final_image.index,
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
      // Bind spot light pipeline with LESS_OR_EQUAL depth test
      vk.CmdBindPipeline(command_buffer, .GRAPHICS, self.spot_light_pipeline)

      rt := resource.get(g_render_targets, light.render_target)
      light_push := LightPushConstant {
        scene_camera_idx       = render_target.camera.index,
        light_camera_idx       = rt.camera.index,
        shadow_map_id          = light.shadow_map.index,
        light_kind             = LightKind.SPOT,
        light_color            = light.color.xyz,
        light_angle            = light.angle,
        light_position         = light.position.xyz,
        light_radius           = light.radius,
        light_direction        = light.direction.xyz,
        light_cast_shadow      = light.shadow_map.generation != 0, // Check if shadow map is valid
        gbuffer_position_index = render_target.position_texture.index,
        gbuffer_normal_index   = render_target.normal_texture.index,
        gbuffer_albedo_index   = render_target.albedo_texture.index,
        gbuffer_metallic_index = render_target.metallic_roughness_texture.index,
        gbuffer_emissive_index = render_target.emissive_texture.index,
        gbuffer_depth_index    = render_target.depth_texture.index,
        input_image_index      = render_target.final_image.index,
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

lighting_end :: proc(command_buffer: vk.CommandBuffer) {
  vk.CmdEndRenderingKHR(command_buffer)
}

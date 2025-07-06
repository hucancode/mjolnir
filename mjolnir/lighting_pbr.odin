package mjolnir

import "core:fmt"
import "core:image"
import "core:log"
import linalg "core:math/linalg"
import "core:slice"
import "geometry"
import "resource"
import mu "vendor:microui"
import vk "vendor:vulkan"

BG_BLUE_GRAY :: [4]f32{0.0117, 0.0117, 0.0179, 1.0}
BG_DARK_GRAY :: [4]f32{0.0117, 0.0117, 0.0117, 1.0}
BG_ORANGE_GRAY :: [4]f32{0.0179, 0.0179, 0.0117, 1.0}

// 128 byte push constant for G-buffer, PBR/IBL params are specialization constants
PushConstant :: struct {
  world:                    linalg.Matrix4f32, // 64 bytes
  bone_matrix_offset:       u32, // 4
  albedo_index:             u32, // 4
  metallic_roughness_index: u32, // 4
  normal_index:             u32, // 4
  displacement_index:       u32, // 4
  emissive_index:           u32, // 4
  metallic_value:           f32, // 4
  roughness_value:          f32, // 4
  emissive_value:           f32, // 4
  padding:                  [3]u32, // 4 (pad to 128)
}

ShaderFeatures :: enum {
  SKINNING                   = 0,
  ALBEDO_TEXTURE             = 1,
  METALLIC_ROUGHNESS_TEXTURE = 2,
  NORMAL_TEXTURE             = 3,
  DISPLACEMENT_TEXTURE       = 4,
  EMISSIVE_TEXTURE           = 5,
}

ShaderFeatureSet :: bit_set[ShaderFeatures;u32]
SHADER_OPTION_COUNT: u32 : len(ShaderFeatures)
SHADER_VARIANT_COUNT: u32 : 1 << SHADER_OPTION_COUNT

ShaderConfig :: struct {
  is_skinned:                     b32,
  has_albedo_texture:             b32,
  has_metallic_roughness_texture: b32,
  has_normal_texture:             b32,
  has_displacement_texture:       b32,
  has_emissive_texture:           b32,
}

RendererMain :: struct {
  lighting_pipeline:         vk.Pipeline,
  lighting_pipeline_layout:  vk.PipelineLayout,
  lighting_set_layout:       vk.DescriptorSetLayout,
  lighting_descriptor_sets:  [MAX_FRAMES_IN_FLIGHT]vk.DescriptorSet,
  environment_map:           Handle,
  brdf_lut:                  Handle,
  environment_max_lod:       f32,
  ibl_intensity:             f32,
  // Light volume meshes
  sphere_mesh:               Handle,
  cone_mesh:                 Handle,
  directional_triangle_mesh: Handle,
}
// Push constant struct for lighting pass (matches shader/lighting/shader.frag)
// 128 byte push constant budget, no world matrix for light volume
LightPushConstant :: struct {
  light_view_proj: linalg.Matrix4f32, // 64 bytes - for shadow mapping
  light_color:     [3]f32, // 12 bytes
  light_angle:     f32, // 4 bytes
  light_position:  [3]f32, // 12 bytes
  light_radius:    f32, // 4 bytes
  light_direction: [3]f32, // 12 bytes
  light_kind:      LightKind, // 4 bytes
  camera_position: [3]f32, // 12 bytes
  shadow_map_id:   u32, // 4 bytes
}

renderer_main_begin :: proc(
  self: ^RendererMain,
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
  render_info := vk.RenderingInfoKHR {
    sType = .RENDERING_INFO_KHR,
    renderArea = {extent = target.extent},
    layerCount = 1,
    colorAttachmentCount = 1,
    pColorAttachments = &color_attachment,
  }
  vk.CmdBeginRenderingKHR(command_buffer, &render_info)
  viewport := vk.Viewport {
    x        = 0.0,
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
    g_textures_descriptor_set, // set = 2 (bindless textures)
    self.lighting_descriptor_sets[g_frame_index], // set = 1 (gbuffer textures, shadow maps)
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

renderer_main_render :: proc(
  self: ^RendererMain,
  input: [dynamic]LightData,
  camera_position: linalg.Vector3f32,
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
      bind_and_draw_mesh(self.directional_triangle_mesh, command_buffer)
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

renderer_main_end :: proc(command_buffer: vk.CommandBuffer) {
  vk.CmdEndRenderingKHR(command_buffer)
}

renderer_main_init :: proc(
  self: ^RendererMain,
  frames: ^[MAX_FRAMES_IN_FLIGHT]FrameData,
  width: u32,
  height: u32,
  color_format: vk.Format = .B8G8R8A8_SRGB,
  depth_format: vk.Format = .D32_SFLOAT,
) -> vk.Result {
  log.debugf("renderer main init %d x %d", width, height)
  bindings := [?]vk.DescriptorSetLayoutBinding {
    {   // Position
      binding         = 0,
      descriptorType  = .COMBINED_IMAGE_SAMPLER,
      descriptorCount = 1,
      stageFlags      = {.FRAGMENT},
    },
    {   // Normal
      binding         = 1,
      descriptorType  = .COMBINED_IMAGE_SAMPLER,
      descriptorCount = 1,
      stageFlags      = {.FRAGMENT},
    },
    {   // Albedo
      binding         = 2,
      descriptorType  = .COMBINED_IMAGE_SAMPLER,
      descriptorCount = 1,
      stageFlags      = {.FRAGMENT},
    },
    {   // Metallic Roughness
      binding         = 3,
      descriptorType  = .COMBINED_IMAGE_SAMPLER,
      descriptorCount = 1,
      stageFlags      = {.FRAGMENT},
    },
    {   // Emissive
      binding         = 4,
      descriptorType  = .COMBINED_IMAGE_SAMPLER,
      descriptorCount = 1,
      stageFlags      = {.FRAGMENT},
    },
    {   // Shadow Map 2D
      binding         = 5,
      descriptorType  = .COMBINED_IMAGE_SAMPLER,
      descriptorCount = MAX_SHADOW_MAPS,
      stageFlags      = {.FRAGMENT},
    },
    {   // Shadow Map Cube
      binding         = 6,
      descriptorType  = .COMBINED_IMAGE_SAMPLER,
      descriptorCount = MAX_SHADOW_MAPS,
      stageFlags      = {.FRAGMENT},
    },
    // No bindless here; use g_textures_set_layout for set 1
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
    self.lighting_set_layout, // set = 2 (gbuffer textures, shadow maps)
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
    cullMode    = {.BACK},
    frontFace   = .CLOCKWISE,
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
    sType = .PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
  }
  color_formats := [?]vk.Format{color_format}
  rendering_info := vk.PipelineRenderingCreateInfo {
    sType                   = .PIPELINE_RENDERING_CREATE_INFO,
    colorAttachmentCount    = len(color_formats),
    pColorAttachmentFormats = raw_data(color_formats[:]),
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
  image_infos: [MAX_FRAMES_IN_FLIGHT * MAX_SHADOW_MAPS]vk.DescriptorImageInfo
  cube_image_infos: [MAX_FRAMES_IN_FLIGHT *
  MAX_SHADOW_MAPS]vk.DescriptorImageInfo
  DESCRIPTOR_PER_FRAME :: 7
  writes: [MAX_FRAMES_IN_FLIGHT * DESCRIPTOR_PER_FRAME]vk.WriteDescriptorSet
  for frame, i in frames {
    for image, j in frame.shadow_maps {
      image_infos[i * MAX_SHADOW_MAPS + j] = {
        sampler     = g_linear_clamp_sampler,
        imageView   = image.view,
        imageLayout = .SHADER_READ_ONLY_OPTIMAL,
      }
    }
    for image, j in frame.cube_shadow_maps {
      cube_image_infos[i * MAX_SHADOW_MAPS + j] = {
        sampler     = g_linear_clamp_sampler,
        imageView   = image.view,
        imageLayout = .SHADER_READ_ONLY_OPTIMAL,
      }
    }
    writes[i * DESCRIPTOR_PER_FRAME + 0] = vk.WriteDescriptorSet {
      sType           = .WRITE_DESCRIPTOR_SET,
      dstSet          = self.lighting_descriptor_sets[i],
      dstBinding      = 0,
      descriptorCount = 1,
      descriptorType  = .COMBINED_IMAGE_SAMPLER,
      pImageInfo      = &{
        sampler = g_linear_clamp_sampler,
        imageView = frame.gbuffer_position.view,
        imageLayout = .SHADER_READ_ONLY_OPTIMAL,
      },
    }
    writes[i * DESCRIPTOR_PER_FRAME + 1] = {
      sType           = .WRITE_DESCRIPTOR_SET,
      dstSet          = self.lighting_descriptor_sets[i],
      dstBinding      = 1,
      descriptorCount = 1,
      descriptorType  = .COMBINED_IMAGE_SAMPLER,
      pImageInfo      = &{
        sampler = g_linear_clamp_sampler,
        imageView = frame.gbuffer_normal.view,
        imageLayout = .SHADER_READ_ONLY_OPTIMAL,
      },
    }
    writes[i * DESCRIPTOR_PER_FRAME + 2] = {
      sType           = .WRITE_DESCRIPTOR_SET,
      dstSet          = self.lighting_descriptor_sets[i],
      dstBinding      = 2,
      descriptorCount = 1,
      descriptorType  = .COMBINED_IMAGE_SAMPLER,
      pImageInfo      = &{
        sampler = g_linear_clamp_sampler,
        imageView = frame.gbuffer_albedo.view,
        imageLayout = .SHADER_READ_ONLY_OPTIMAL,
      },
    }
    writes[i * DESCRIPTOR_PER_FRAME + 3] = {
      sType           = .WRITE_DESCRIPTOR_SET,
      dstSet          = self.lighting_descriptor_sets[i],
      dstBinding      = 3,
      descriptorCount = 1,
      descriptorType  = .COMBINED_IMAGE_SAMPLER,
      pImageInfo      = &{
        sampler = g_linear_clamp_sampler,
        imageView = frame.gbuffer_metallic_roughness.view,
        imageLayout = .SHADER_READ_ONLY_OPTIMAL,
      },
    }
    writes[i * DESCRIPTOR_PER_FRAME + 4] = {
      sType           = .WRITE_DESCRIPTOR_SET,
      dstSet          = self.lighting_descriptor_sets[i],
      dstBinding      = 4,
      descriptorCount = 1,
      descriptorType  = .COMBINED_IMAGE_SAMPLER,
      pImageInfo      = &{
        sampler = g_linear_clamp_sampler,
        imageView = frame.gbuffer_emissive.view,
        imageLayout = .SHADER_READ_ONLY_OPTIMAL,
      },
    }
    writes[i * DESCRIPTOR_PER_FRAME + 5] = {
      sType           = .WRITE_DESCRIPTOR_SET,
      dstSet          = self.lighting_descriptor_sets[i],
      dstBinding      = 5,
      descriptorCount = MAX_SHADOW_MAPS,
      descriptorType  = .COMBINED_IMAGE_SAMPLER,
      pImageInfo      = raw_data(image_infos[i * MAX_SHADOW_MAPS:]),
    }
    writes[i * DESCRIPTOR_PER_FRAME + 6] = {
      sType           = .WRITE_DESCRIPTOR_SET,
      dstSet          = self.lighting_descriptor_sets[i],
      dstBinding      = 6,
      descriptorCount = MAX_SHADOW_MAPS,
      descriptorType  = .COMBINED_IMAGE_SAMPLER,
      pImageInfo      = raw_data(cube_image_infos[i * MAX_SHADOW_MAPS:]),
    }
    // No writes for environment_map or brdf_lut; use bindless and push constant indices
  }
  log.debugf("Updating descriptor sets for lighting pass... %v", writes)
  vk.UpdateDescriptorSets(g_device, len(writes), raw_data(writes[:]), 0, nil)

  // Initialize light volume meshes
  self.sphere_mesh, _, _ = create_mesh(geometry.make_sphere())
  self.cone_mesh, _, _ = create_mesh(
    geometry.make_cone(height = 1, radius = 1),
  )
  self.directional_triangle_mesh, _, _ = create_mesh(
    geometry.make_fullscreen_triangle(),
  )
  log.info("Light volume meshes initialized")

  return .SUCCESS
}

renderer_main_deinit :: proc(self: ^RendererMain) {
  vk.DestroyPipelineLayout(g_device, self.lighting_pipeline_layout, nil)
  vk.DestroyPipeline(g_device, self.lighting_pipeline, nil)
}

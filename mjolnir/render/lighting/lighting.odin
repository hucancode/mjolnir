package lighting

import cont "../../containers"
import "../../geometry"
import "../../gpu"
import "../../resources"
import "../shared"
import "core:log"
import vk "vendor:vulkan"

SHADER_AMBIENT_VERT :: #load("../../shader/lighting_ambient/vert.spv")
SHADER_AMBIENT_FRAG :: #load("../../shader/lighting_ambient/frag.spv")
SHADER_LIGHTING_VERT := #load("../../shader/lighting/vert.spv")
SHADER_LIGHTING_FRAG := #load("../../shader/lighting/frag.spv")
TEXTURE_LUT_GGX :: #load("../../assets/lut_ggx.png")

LightKind :: enum u32 {
  POINT       = 0,
  DIRECTIONAL = 1,
  SPOT        = 2,
}

AmbientPushConstant :: struct {
  camera_index:           u32,
  environment_index:      u32,
  brdf_lut_index:         u32,
  position_texture_index: u32,
  normal_texture_index:   u32,
  albedo_texture_index:   u32,
  metallic_texture_index: u32,
  emissive_texture_index: u32,
  depth_texture_index:    u32,
  environment_max_lod:    f32,
  ibl_intensity:          f32,
}

LightPushConstant :: struct {
  light_index:            u32,
  scene_camera_idx:       u32,
  position_texture_index: u32,
  normal_texture_index:   u32,
  albedo_texture_index:   u32,
  metallic_texture_index: u32,
  emissive_texture_index: u32,
  depth_texture_index:    u32,
  input_image_index:      u32,
  padding:                [3]u32,
}

begin_ambient_pass :: proc(
  self: ^Renderer,
  camera_handle: resources.Handle,
  command_buffer: vk.CommandBuffer,
  rm: ^resources.Manager,
  frame_index: u32,
) {
  camera := cont.get(rm.cameras, camera_handle)
  if camera == nil do return
  color_texture := cont.get(
    rm.images_2d,
    camera.attachments[.FINAL_IMAGE][frame_index],
  )
  gpu.begin_rendering(
    command_buffer,
    camera.extent.width,
    camera.extent.height,
    nil,
    gpu.create_color_attachment(color_texture),
  )
  gpu.set_viewport_scissor(
    command_buffer,
    camera.extent.width,
    camera.extent.height,
    flip_y = false,
  )
  gpu.bind_graphics_pipeline(
    command_buffer,
    self.ambient_pipeline,
    self.ambient_pipeline_layout,
    rm.camera_buffer.descriptor_sets[frame_index], // set = 0 (per-frame camera buffer)
    rm.textures_descriptor_set, // set = 1 (bindless textures)
  )
}

render_ambient :: proc(
  self: ^Renderer,
  camera_handle: resources.Handle,
  command_buffer: vk.CommandBuffer,
  rm: ^resources.Manager,
  frame_index: u32,
) {
  camera := cont.get(rm.cameras, camera_handle)
  if camera == nil do return
  push := AmbientPushConstant {
    camera_index           = camera_handle.index,
    environment_index      = self.environment_map.index,
    brdf_lut_index         = self.brdf_lut.index,
    position_texture_index = camera.attachments[.POSITION][frame_index].index,
    normal_texture_index   = camera.attachments[.NORMAL][frame_index].index,
    albedo_texture_index   = camera.attachments[.ALBEDO][frame_index].index,
    metallic_texture_index = camera.attachments[.METALLIC_ROUGHNESS][frame_index].index,
    emissive_texture_index = camera.attachments[.EMISSIVE][frame_index].index,
    depth_texture_index    = camera.attachments[.DEPTH][frame_index].index,
    environment_max_lod    = self.environment_max_lod,
    ibl_intensity          = self.ibl_intensity,
  }
  vk.CmdPushConstants(
    command_buffer,
    self.ambient_pipeline_layout,
    {.FRAGMENT},
    0,
    size_of(AmbientPushConstant),
    &push,
  )
  vk.CmdDraw(command_buffer, 3, 1, 0, 0) // fullscreen triangle
}

end_ambient_pass :: proc(command_buffer: vk.CommandBuffer) {
  vk.CmdEndRendering(command_buffer)
}

init :: proc(
  self: ^Renderer,
  gctx: ^gpu.GPUContext,
  rm: ^resources.Manager,
  width, height: u32,
  color_format: vk.Format = .B8G8R8A8_SRGB,
  depth_format: vk.Format = .D32_SFLOAT,
) -> (
  ret: vk.Result,
) {
  log.debugf("renderer lighting init %d x %d", width, height)
  self.ambient_pipeline_layout = gpu.create_pipeline_layout(
    gctx,
    vk.PushConstantRange {
      stageFlags = {.FRAGMENT},
      size = size_of(AmbientPushConstant),
    },
    rm.camera_buffer.set_layout,
    rm.textures_set_layout,
  ) or_return
  defer if ret != .SUCCESS {
    vk.DestroyPipelineLayout(gctx.device, self.ambient_pipeline_layout, nil)
  }
  ambient_vert_module := gpu.create_shader_module(
    gctx.device,
    SHADER_AMBIENT_VERT,
  ) or_return
  defer vk.DestroyShaderModule(gctx.device, ambient_vert_module, nil)
  ambient_frag_module := gpu.create_shader_module(
    gctx.device,
    SHADER_AMBIENT_FRAG,
  ) or_return
  defer vk.DestroyShaderModule(gctx.device, ambient_frag_module, nil)
  ambient_shader_stages := [?]vk.PipelineShaderStageCreateInfo {
    {
      sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
      stage = {.VERTEX},
      module = ambient_vert_module,
      pName = "main",
      pSpecializationInfo = &shared.SHADER_SPEC_CONSTANTS,
    },
    {
      sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
      stage = {.FRAGMENT},
      module = ambient_frag_module,
      pName = "main",
      pSpecializationInfo = &shared.SHADER_SPEC_CONSTANTS,
    },
  }
  ambient_pipeline_info := vk.GraphicsPipelineCreateInfo {
    sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
    pNext               = &gpu.COLOR_ONLY_RENDERING_INFO,
    stageCount          = len(ambient_shader_stages),
    pStages             = raw_data(ambient_shader_stages[:]),
    pVertexInputState   = &gpu.VERTEX_INPUT_NONE,
    pInputAssemblyState = &gpu.STANDARD_INPUT_ASSEMBLY,
    pViewportState      = &gpu.STANDARD_VIEWPORT_STATE,
    pRasterizationState = &gpu.DOUBLE_SIDED_RASTERIZER,
    pMultisampleState   = &gpu.STANDARD_MULTISAMPLING,
    pColorBlendState    = &gpu.COLOR_BLENDING_OVERRIDE,
    pDynamicState       = &gpu.STANDARD_DYNAMIC_STATES,
    layout              = self.ambient_pipeline_layout,
  }
  vk.CreateGraphicsPipelines(
    gctx.device,
    0,
    1,
    &ambient_pipeline_info,
    nil,
    &self.ambient_pipeline,
  ) or_return
  defer if ret != .SUCCESS {
    vk.DestroyPipeline(gctx.device, self.ambient_pipeline, nil)
  }
  environment_map: ^gpu.Image
  self.environment_map, environment_map = resources.create_texture_from_path(
    gctx,
    rm,
    "assets/Cannon_Exterior.hdr",
    .R32G32B32A32_SFLOAT,
    true,
    {.SAMPLED},
    true,
  ) or_return
  defer if ret != .SUCCESS {
    if item, freed := cont.free(&rm.images_2d, self.environment_map); freed {
      gpu.image_destroy(gctx.device, item)
    }
  }
  self.environment_max_lod =
    f32(
      gpu.calculate_mip_levels(
        environment_map.spec.width,
        environment_map.spec.height,
      ),
    ) -
    1.0
  brdf_handle, _ := resources.create_texture_from_data(
    gctx,
    rm,
    TEXTURE_LUT_GGX,
  ) or_return
  defer if ret != .SUCCESS {
    if item, freed := cont.free(&rm.images_2d, brdf_handle); freed {
      gpu.image_destroy(gctx.device, item)
    }
  }
  self.brdf_lut = brdf_handle
  self.ibl_intensity = 1.0
  log.info("Ambient pipeline initialized successfully")
  self.lighting_pipeline_layout = gpu.create_pipeline_layout(
    gctx,
    vk.PushConstantRange {
      stageFlags = {.VERTEX, .FRAGMENT},
      size = size_of(LightPushConstant),
    },
    rm.camera_buffer.set_layout,
    rm.textures_set_layout,
    rm.lights_buffer.set_layout,
    rm.world_matrix_buffer.set_layout,
    rm.spherical_camera_buffer.set_layout,
    rm.dynamic_light_data_buffer.set_layout,
  ) or_return
  defer if ret != .SUCCESS {
    vk.DestroyPipelineLayout(gctx.device, self.lighting_pipeline_layout, nil)
  }
  lighting_vert_module := gpu.create_shader_module(
    gctx.device,
    SHADER_LIGHTING_VERT,
  ) or_return
  defer vk.DestroyShaderModule(gctx.device, lighting_vert_module, nil)
  lighting_frag_module := gpu.create_shader_module(
    gctx.device,
    SHADER_LIGHTING_FRAG,
  ) or_return
  defer vk.DestroyShaderModule(gctx.device, lighting_frag_module, nil)
  lighting_dynamic_states := [?]vk.DynamicState {
    .VIEWPORT,
    .SCISSOR,
    .DEPTH_COMPARE_OP,
  }
  lighting_dynamic_state := gpu.create_dynamic_state(
    lighting_dynamic_states[:],
  )
  lighting_vertex_input := vk.PipelineVertexInputStateCreateInfo {
    sType                           = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
    vertexBindingDescriptionCount   = 1,
    pVertexBindingDescriptions      = &geometry.VERTEX_BINDING_DESCRIPTION[0],
    vertexAttributeDescriptionCount = 1, // Only position needed for lighting
    pVertexAttributeDescriptions    = raw_data(
      geometry.VERTEX_ATTRIBUTE_DESCRIPTIONS[:],
    ), // Position at location 0
  }
  lighting_shader_stages := [?]vk.PipelineShaderStageCreateInfo {
    {
      sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
      stage = {.VERTEX},
      module = lighting_vert_module,
      pName = "main",
      pSpecializationInfo = &shared.SHADER_SPEC_CONSTANTS,
    },
    {
      sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
      stage = {.FRAGMENT},
      module = lighting_frag_module,
      pName = "main",
      pSpecializationInfo = &shared.SHADER_SPEC_CONSTANTS,
    },
  }
  lighting_pipeline_info := vk.GraphicsPipelineCreateInfo {
    sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
    pNext               = &gpu.STANDARD_RENDERING_INFO,
    stageCount          = len(lighting_shader_stages),
    pStages             = raw_data(lighting_shader_stages[:]),
    pVertexInputState   = &lighting_vertex_input,
    pInputAssemblyState = &gpu.STANDARD_INPUT_ASSEMBLY,
    pViewportState      = &gpu.STANDARD_VIEWPORT_STATE,
    pRasterizationState = &gpu.INVERSE_RASTERIZER,
    pMultisampleState   = &gpu.STANDARD_MULTISAMPLING,
    pColorBlendState    = &gpu.COLOR_BLENDING_OVERFLOW,
    pDynamicState       = &lighting_dynamic_state,
    pDepthStencilState  = &gpu.READ_ONLY_DEPTH_STATE,
    layout              = self.lighting_pipeline_layout,
  }
  vk.CreateGraphicsPipelines(
    gctx.device,
    0,
    1,
    &lighting_pipeline_info,
    nil,
    &self.lighting_pipeline,
  ) or_return
  defer if ret != .SUCCESS {
    vk.DestroyPipeline(gctx.device, self.lighting_pipeline, nil)
  }
  log.info("Lighting pipeline initialized successfully")
  self.sphere_mesh = resources.create_mesh(
    gctx,
    rm,
    geometry.make_sphere(segments = 64, rings = 64),
  ) or_return
  defer if ret != .SUCCESS {
    if mesh, freed := cont.free(&rm.meshes, self.sphere_mesh); freed {
      resources.mesh_destroy(mesh, rm)
    }
  }
  self.cone_mesh = resources.create_mesh(
    gctx,
    rm,
    geometry.make_cone(segments = 128, height = 1, radius = 0.5),
  ) or_return
  defer if ret != .SUCCESS {
    if mesh, freed := cont.free(&rm.meshes, self.cone_mesh); freed {
      resources.mesh_destroy(mesh, rm)
    }
  }
  self.triangle_mesh = resources.create_mesh(
    gctx,
    rm,
    geometry.make_fullscreen_triangle(),
  ) or_return
  defer if ret != .SUCCESS {
    if mesh, freed := cont.free(&rm.meshes, self.triangle_mesh); freed {
      resources.mesh_destroy(mesh, rm)
    }
  }
  log.info("Light volume meshes initialized")
  return .SUCCESS
}

shutdown :: proc(
  self: ^Renderer,
  gctx: ^gpu.GPUContext,
  rm: ^resources.Manager,
) {
  vk.DestroyPipeline(gctx.device, self.ambient_pipeline, nil)
  self.ambient_pipeline = 0
  vk.DestroyPipelineLayout(gctx.device, self.ambient_pipeline_layout, nil)
  self.ambient_pipeline_layout = 0
  if item, freed := cont.free(&rm.images_2d, self.environment_map); freed {
    gpu.image_destroy(gctx.device, item)
  }
  if item, freed := cont.free(&rm.images_2d, self.brdf_lut); freed {
    gpu.image_destroy(gctx.device, item)
  }
  vk.DestroyPipelineLayout(gctx.device, self.lighting_pipeline_layout, nil)
  vk.DestroyPipeline(gctx.device, self.lighting_pipeline, nil)
}

BG_BLUE_GRAY :: [4]f32{0.0117, 0.0117, 0.0179, 1.0}
BG_DARK_GRAY :: [4]f32{0.0117, 0.0117, 0.0117, 1.0}
BG_ORANGE_GRAY :: [4]f32{0.0179, 0.0179, 0.0117, 1.0}

Renderer :: struct {
  ambient_pipeline:         vk.Pipeline,
  ambient_pipeline_layout:  vk.PipelineLayout,
  environment_map:          resources.Handle,
  brdf_lut:                 resources.Handle,
  environment_max_lod:      f32,
  ibl_intensity:            f32,
  lighting_pipeline:        vk.Pipeline,
  lighting_pipeline_layout: vk.PipelineLayout,
  sphere_mesh:              resources.Handle,
  cone_mesh:                resources.Handle,
  triangle_mesh:            resources.Handle,
}

recreate_images :: proc(
  self: ^Renderer,
  width, height: u32,
  color_format: vk.Format,
  depth_format: vk.Format,
) -> vk.Result {
  log.debugf("Updated G-buffer indices for lighting pass on resize")
  return .SUCCESS
}

begin_pass :: proc(
  self: ^Renderer,
  camera_handle: resources.Handle,
  command_buffer: vk.CommandBuffer,
  rm: ^resources.Manager,
  frame_index: u32,
) {
  camera := cont.get(rm.cameras, camera_handle)
  if camera == nil do return
  final_image := cont.get(
    rm.images_2d,
    camera.attachments[.FINAL_IMAGE][frame_index],
  )
  depth_texture := cont.get(
    rm.images_2d,
    camera.attachments[.DEPTH][frame_index],
  )
  gpu.begin_rendering(
    command_buffer,
    camera.extent.width,
    camera.extent.height,
    gpu.create_depth_attachment(depth_texture, .LOAD, .DONT_CARE),
    gpu.create_color_attachment(final_image, .LOAD, .STORE, BG_BLUE_GRAY),
  )
  gpu.set_viewport_scissor(
    command_buffer,
    camera.extent.width,
    camera.extent.height,
  )
  gpu.bind_graphics_pipeline(
    command_buffer,
    self.lighting_pipeline,
    self.lighting_pipeline_layout,
    rm.camera_buffer.descriptor_sets[frame_index], // set = 0 (per-frame cameras)
    rm.textures_descriptor_set, // set = 1 (textures/samplers)
    rm.lights_buffer.descriptor_set, // set = 2 (lights)
    rm.world_matrix_buffer.descriptor_set, // set = 3 (world matrices)
    rm.spherical_camera_buffer.descriptor_sets[frame_index], // set = 4 (per-frame spherical cameras)
    rm.dynamic_light_data_buffer.descriptor_sets[frame_index], // set = 5 (per-frame position + shadow map)
  )
}

render :: proc(
  self: ^Renderer,
  camera_handle: resources.Handle,
  command_buffer: vk.CommandBuffer,
  rm: ^resources.Manager,
  frame_index: u32,
) {
  camera := cont.get(rm.cameras, camera_handle)
  if camera == nil do return
  bind_and_draw_mesh :: proc(
    mesh_handle: resources.Handle,
    command_buffer: vk.CommandBuffer,
    rm: ^resources.Manager,
  ) {
    mesh_ptr := cont.get(rm.meshes, mesh_handle)
    if mesh_ptr == nil {
      log.errorf("Failed to get mesh for handle %v", mesh_handle)
      return
    }
    gpu.bind_vertex_index_buffers(
      command_buffer,
      rm.vertex_buffer.buffer,
      rm.index_buffer.buffer,
      vk.DeviceSize(
        mesh_ptr.vertex_allocation.offset * size_of(geometry.Vertex),
      ),
      vk.DeviceSize(mesh_ptr.index_allocation.offset * size_of(u32)),
    )
    vk.CmdDrawIndexed(
      command_buffer,
      mesh_ptr.index_allocation.count,
      1,
      0,
      0,
      0,
    )
  }
  push_constant := LightPushConstant {
    scene_camera_idx       = camera_handle.index,
    position_texture_index = camera.attachments[.POSITION][frame_index].index,
    normal_texture_index   = camera.attachments[.NORMAL][frame_index].index,
    albedo_texture_index   = camera.attachments[.ALBEDO][frame_index].index,
    metallic_texture_index = camera.attachments[.METALLIC_ROUGHNESS][frame_index].index,
    emissive_texture_index = camera.attachments[.EMISSIVE][frame_index].index,
    depth_texture_index    = camera.attachments[.DEPTH][frame_index].index,
    input_image_index      = camera.attachments[.FINAL_IMAGE][frame_index].index,
  }
  for handle in rm.active_lights {
    light := cont.get(rm.lights, handle) or_continue
    push_constant.light_index = handle.index
    vk.CmdPushConstants(
      command_buffer,
      self.lighting_pipeline_layout,
      {.VERTEX, .FRAGMENT},
      0,
      size_of(push_constant),
      &push_constant,
    )
    switch light.type {
    case .POINT:
      vk.CmdSetDepthCompareOp(command_buffer, .GREATER_OR_EQUAL)
      bind_and_draw_mesh(self.sphere_mesh, command_buffer, rm)
    case .DIRECTIONAL:
      vk.CmdSetDepthCompareOp(command_buffer, .ALWAYS)
      bind_and_draw_mesh(self.triangle_mesh, command_buffer, rm)
    case .SPOT:
      vk.CmdSetDepthCompareOp(command_buffer, .LESS_OR_EQUAL)
      bind_and_draw_mesh(self.cone_mesh, command_buffer, rm)
    }
  }
}

end_pass :: proc(command_buffer: vk.CommandBuffer) {
  vk.CmdEndRendering(command_buffer)
}

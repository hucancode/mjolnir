package lighting

import cont "../../containers"
import d "../data"
import "../../geometry"
import "../../gpu"
import "../camera"
import "../shared"
import "core:log"
import vk "vendor:vulkan"

SHADER_AMBIENT_VERT :: #load("../../shader/lighting_ambient/vert.spv")
SHADER_AMBIENT_FRAG :: #load("../../shader/lighting_ambient/frag.spv")
SHADER_LIGHTING_VERT := #load("../../shader/lighting/vert.spv")
SHADER_LIGHTING_FRAG := #load("../../shader/lighting/frag.spv")
TEXTURE_LUT_GGX :: #load("../../assets/lut_ggx.png")

SpotLightGPU :: struct {
  color:            [4]f32, // RGB + intensity
  radius:           f32,
  angle_inner:      f32,
  angle_outer:      f32,
  projection:       matrix[4, 4]f32,
  view:             matrix[4, 4]f32,
  position:         [4]f32,
  direction:        [4]f32,
  near_far:         [2]f32,
  shadow_map:       [d.FRAMES_IN_FLIGHT]gpu.Texture2DHandle,
  draw_commands:   [d.FRAMES_IN_FLIGHT]gpu.MutableBuffer(
    vk.DrawIndexedIndirectCommand,
  ),
  draw_count:      [d.FRAMES_IN_FLIGHT]gpu.MutableBuffer(u32),
  descriptor_sets: [d.FRAMES_IN_FLIGHT]vk.DescriptorSet,
}

PointLightGPU :: struct {
  color:            [4]f32, // RGB + intensity
  radius:           f32,
  projection:       matrix[4, 4]f32,
  position:         [4]f32,
  near_far:         [2]f32,
  shadow_cube:      [d.FRAMES_IN_FLIGHT]gpu.TextureCubeHandle,
  draw_commands:   [d.FRAMES_IN_FLIGHT]gpu.MutableBuffer(
    vk.DrawIndexedIndirectCommand,
  ),
  draw_count:      [d.FRAMES_IN_FLIGHT]gpu.MutableBuffer(u32),
  descriptor_sets: [d.FRAMES_IN_FLIGHT]vk.DescriptorSet,
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
  input_image_index:      u32,
  light_position:         [4]f32,
  shadow_map_index:       u32,
}

begin_ambient_pass :: proc(
  self: ^Renderer,
  camera_gpu: ^camera.CameraGPU,
  camera_cpu: ^camera.Camera,
  texture_manager: ^gpu.TextureManager,
  command_buffer: vk.CommandBuffer,
  frame_index: u32,
) {
  color_texture := gpu.get_texture_2d(texture_manager,
    camera_gpu.attachments[.FINAL_IMAGE][frame_index],
  )
  gpu.begin_rendering(
    command_buffer,
    camera_cpu.extent[0],
    camera_cpu.extent[1],
    nil,
    gpu.create_color_attachment(color_texture),
  )
  gpu.set_viewport_scissor(
    command_buffer,
    camera_cpu.extent[0],
    camera_cpu.extent[1],
    flip_y = false,
  )
  gpu.bind_graphics_pipeline(
    command_buffer,
    self.ambient_pipeline,
    self.ambient_pipeline_layout,
    camera_gpu.camera_buffer_descriptor_sets[frame_index], // set = 0 (per-frame camera buffer)
    texture_manager.textures_descriptor_set, // set = 1 (bindless textures)
  )
}

render_ambient :: proc(
  self: ^Renderer,
  camera_handle: d.CameraHandle,
  camera_gpu: ^camera.CameraGPU,
  command_buffer: vk.CommandBuffer,
  frame_index: u32,
) {
  push := AmbientPushConstant {
    camera_index           = camera_handle.index,
    environment_index      = self.environment_map.index,
    brdf_lut_index         = self.brdf_lut.index,
    position_texture_index = camera_gpu.attachments[.POSITION][frame_index].index,
    normal_texture_index   = camera_gpu.attachments[.NORMAL][frame_index].index,
    albedo_texture_index   = camera_gpu.attachments[.ALBEDO][frame_index].index,
    metallic_texture_index = camera_gpu.attachments[.METALLIC_ROUGHNESS][frame_index].index,
    emissive_texture_index = camera_gpu.attachments[.EMISSIVE][frame_index].index,
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
  texture_manager: ^gpu.TextureManager,
  camera_set_layout: vk.DescriptorSetLayout,
  lights_set_layout: vk.DescriptorSetLayout,
  shadow_data_set_layout: vk.DescriptorSetLayout,
  textures_set_layout: vk.DescriptorSetLayout,
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
    camera_set_layout,
    textures_set_layout,
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
  ambient_shader_stages := gpu.create_vert_frag_stages(
    ambient_vert_module,
    ambient_frag_module,
    &shared.SHADER_SPEC_CONSTANTS,
  )
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
  env_map, env_result := gpu.create_texture_2d_from_path(
    gctx,
    texture_manager,
    "assets/Cannon_Exterior.hdr",
    .R32G32B32A32_SFLOAT,
    true,
    {.SAMPLED},
    true,
  )
  if env_result == .SUCCESS {
    self.environment_map = env_map
  } else {
    log.warn("HDR environment map not found, using default lighting")
    self.environment_map = {} // Empty handle - renderer should handle gracefully
  }
  defer if ret != .SUCCESS {
    gpu.free_texture_2d(texture_manager, gctx, self.environment_map)
  }
  environment_map := gpu.get_texture_2d(texture_manager, self.environment_map)
  if environment_map != nil {
    self.environment_max_lod =
      f32(
        gpu.calculate_mip_levels(
          environment_map.spec.width,
          environment_map.spec.height,
        ),
      ) -
      1.0
  } else {
    self.environment_max_lod = 0.0
  }
  brdf_handle := gpu.create_texture_2d_from_data(
    gctx,
    texture_manager,
    TEXTURE_LUT_GGX,
  ) or_return
  defer if ret != .SUCCESS {
    gpu.free_texture_2d(texture_manager, gctx, brdf_handle)
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
    camera_set_layout,
    textures_set_layout,
    lights_set_layout,
    shadow_data_set_layout,
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
    .CULL_MODE,
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
  lighting_shader_stages := gpu.create_vert_frag_stages(
    lighting_vert_module,
    lighting_frag_module,
    &shared.SHADER_SPEC_CONSTANTS,
  )
  lighting_pipeline_info := vk.GraphicsPipelineCreateInfo {
    sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
    pNext               = &gpu.STANDARD_RENDERING_INFO,
    stageCount          = len(lighting_shader_stages),
    pStages             = raw_data(lighting_shader_stages[:]),
    pVertexInputState   = &lighting_vertex_input,
    pInputAssemblyState = &gpu.STANDARD_INPUT_ASSEMBLY,
    pViewportState      = &gpu.STANDARD_VIEWPORT_STATE,
    pRasterizationState = &gpu.STANDARD_RASTERIZER,
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
  create_light_volume_mesh(
    gctx,
    &self.sphere_mesh,
    geometry.make_sphere(),
  ) or_return
  defer if ret != .SUCCESS {
    destroy_light_volume_mesh(gctx.device, &self.sphere_mesh)
  }
  create_light_volume_mesh(
    gctx,
    &self.cone_mesh,
    geometry.make_cone(),
  ) or_return
  defer if ret != .SUCCESS {
    destroy_light_volume_mesh(gctx.device, &self.cone_mesh)
  }
  create_light_volume_mesh(
    gctx,
    &self.triangle_mesh,
    geometry.make_fullscreen_triangle(),
  ) or_return
  defer if ret != .SUCCESS {
    destroy_light_volume_mesh(gctx.device, &self.triangle_mesh)
  }
  log.info("Light volume meshes initialized")
  return .SUCCESS
}

shutdown :: proc(
  self: ^Renderer,
  gctx: ^gpu.GPUContext,
  texture_manager: ^gpu.TextureManager,
) {
  vk.DestroyPipeline(gctx.device, self.ambient_pipeline, nil)
  self.ambient_pipeline = 0
  vk.DestroyPipelineLayout(gctx.device, self.ambient_pipeline_layout, nil)
  self.ambient_pipeline_layout = 0
  gpu.free_texture_2d(texture_manager, gctx, self.environment_map)
  gpu.free_texture_2d(texture_manager, gctx, self.brdf_lut)
  destroy_light_volume_mesh(gctx.device, &self.sphere_mesh)
  destroy_light_volume_mesh(gctx.device, &self.cone_mesh)
  destroy_light_volume_mesh(gctx.device, &self.triangle_mesh)
  vk.DestroyPipelineLayout(gctx.device, self.lighting_pipeline_layout, nil)
  vk.DestroyPipeline(gctx.device, self.lighting_pipeline, nil)
}

BG_BLUE_GRAY :: [4]f32{0.0117, 0.0117, 0.0179, 1.0}
BG_DARK_GRAY :: [4]f32{0.0117, 0.0117, 0.0117, 1.0}
BG_ORANGE_GRAY :: [4]f32{0.0179, 0.0179, 0.0117, 1.0}

Renderer :: struct {
  ambient_pipeline:         vk.Pipeline,
  ambient_pipeline_layout:  vk.PipelineLayout,
  environment_map:          gpu.Texture2DHandle,
  brdf_lut:                 gpu.Texture2DHandle,
  environment_max_lod:      f32,
  ibl_intensity:            f32,
  lighting_pipeline:        vk.Pipeline,
  lighting_pipeline_layout: vk.PipelineLayout,
  sphere_mesh:              LightVolumeMesh,
  cone_mesh:                LightVolumeMesh,
  triangle_mesh:            LightVolumeMesh,
}

LightVolumeMesh :: struct {
  vertex_buffer: gpu.ImmutableBuffer(geometry.Vertex),
  index_buffer:  gpu.ImmutableBuffer(u32),
  index_count:   u32,
}

@(private)
create_light_volume_mesh :: proc(
  gctx: ^gpu.GPUContext,
  out_mesh: ^LightVolumeMesh,
  geom: geometry.Geometry,
) -> vk.Result {
  out_mesh^ = {}
  vertex_buffer, ret_vertex := gpu.malloc_buffer(
    gctx,
    geometry.Vertex,
    len(geom.vertices),
    {.VERTEX_BUFFER},
  )
  if ret_vertex != .SUCCESS do return ret_vertex
  out_mesh.vertex_buffer = vertex_buffer
  index_buffer, ret_index := gpu.malloc_buffer(
    gctx,
    u32,
    len(geom.indices),
    {.INDEX_BUFFER},
  )
  if ret_index != .SUCCESS {
    gpu.buffer_destroy(gctx.device, &out_mesh.vertex_buffer)
    return ret_index
  }
  out_mesh.index_buffer = index_buffer
  if gpu.write(gctx, &out_mesh.vertex_buffer, geom.vertices) != .SUCCESS {
    destroy_light_volume_mesh(gctx.device, out_mesh)
    return .ERROR_UNKNOWN
  }
  if gpu.write(gctx, &out_mesh.index_buffer, geom.indices) != .SUCCESS {
    destroy_light_volume_mesh(gctx.device, out_mesh)
    return .ERROR_UNKNOWN
  }
  out_mesh.index_count = u32(len(geom.indices))
  return .SUCCESS
}

@(private)
destroy_light_volume_mesh :: proc(device: vk.Device, mesh: ^LightVolumeMesh) {
  gpu.buffer_destroy(device, &mesh.vertex_buffer)
  gpu.buffer_destroy(device, &mesh.index_buffer)
  mesh.index_count = 0
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
  camera_gpu: ^camera.CameraGPU,
  camera_cpu: ^camera.Camera,
  texture_manager: ^gpu.TextureManager,
  command_buffer: vk.CommandBuffer,
  lights_descriptor_set: vk.DescriptorSet,
  shadow_data_descriptor_set: vk.DescriptorSet,
  frame_index: u32,
) {
  final_image := gpu.get_texture_2d(texture_manager,
    camera_gpu.attachments[.FINAL_IMAGE][frame_index],
  )
  depth_texture := gpu.get_texture_2d(texture_manager,
    camera_gpu.attachments[.DEPTH][frame_index],
  )
  gpu.begin_rendering(
    command_buffer,
    camera_cpu.extent[0],
    camera_cpu.extent[1],
    gpu.create_depth_attachment(depth_texture, .LOAD, .DONT_CARE),
    gpu.create_color_attachment(final_image, .LOAD, .STORE, BG_BLUE_GRAY),
  )
  gpu.set_viewport_scissor(
    command_buffer,
    camera_cpu.extent[0],
    camera_cpu.extent[1],
  )
  gpu.bind_graphics_pipeline(
    command_buffer,
    self.lighting_pipeline,
    self.lighting_pipeline_layout,
    camera_gpu.camera_buffer_descriptor_sets[frame_index], // set = 0 (per-frame cameras)
    texture_manager.textures_descriptor_set, // set = 1 (textures/samplers)
    lights_descriptor_set, // set = 2 (lights)
    shadow_data_descriptor_set, // set = 3 (per-frame shadow data)
  )
}

render :: proc(
  self: ^Renderer,
  camera_handle: d.CameraHandle,
  camera_gpu: ^camera.CameraGPU,
  shadow_texture_indices: ^[d.MAX_LIGHTS]u32,
  command_buffer: vk.CommandBuffer,
  lights: d.Pool(d.Light),
  active_lights: []d.LightHandle,
  frame_index: u32,
) {
  bind_and_draw_mesh :: proc(
    mesh: ^LightVolumeMesh,
    command_buffer: vk.CommandBuffer,
  ) {
    gpu.bind_vertex_index_buffers(
      command_buffer,
      mesh.vertex_buffer.buffer,
      mesh.index_buffer.buffer,
      0,
      0,
    )
    vk.CmdDrawIndexed(
      command_buffer,
      mesh.index_count,
      1,
      0,
      0,
      0,
    )
  }
  push_constant := LightPushConstant {
    scene_camera_idx       = camera_handle.index,
    position_texture_index = camera_gpu.attachments[.POSITION][frame_index].index,
    normal_texture_index   = camera_gpu.attachments[.NORMAL][frame_index].index,
    albedo_texture_index   = camera_gpu.attachments[.ALBEDO][frame_index].index,
    metallic_texture_index = camera_gpu.attachments[.METALLIC_ROUGHNESS][frame_index].index,
    emissive_texture_index = camera_gpu.attachments[.EMISSIVE][frame_index].index,
    input_image_index      = camera_gpu.attachments[.FINAL_IMAGE][frame_index].index,
  }
  for handle in active_lights {
    light := cont.get(lights, handle) or_continue
    shadow_map_index := shadow_texture_indices[handle.index]
    push_constant.light_index = handle.index
    push_constant.light_position = light.position
    push_constant.shadow_map_index = shadow_map_index
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
      vk.CmdSetCullMode(command_buffer, {.FRONT})
      bind_and_draw_mesh(
        &self.sphere_mesh,
        command_buffer,
      )
    case .DIRECTIONAL:
      vk.CmdSetDepthCompareOp(command_buffer, .ALWAYS)
      vk.CmdSetCullMode(command_buffer, {.BACK})
      bind_and_draw_mesh(
        &self.triangle_mesh,
        command_buffer,
      )
    case .SPOT:
      vk.CmdSetDepthCompareOp(command_buffer, .GREATER_OR_EQUAL)
      vk.CmdSetCullMode(command_buffer, {.BACK})
      bind_and_draw_mesh(
        &self.cone_mesh,
        command_buffer,
      )
    }
  }
}

end_pass :: proc(command_buffer: vk.CommandBuffer) {
  vk.CmdEndRendering(command_buffer)
}

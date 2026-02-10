package lighting

import cont "../../containers"
import d "../../data"
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
  light_position:         [4]f32,
  input_image_index:      u32,
  shadow_map_index:       u32,
  padding:                [2]u32,
}

begin_ambient_pass :: proc(
  self: ^Renderer,
  camera_gpu: ^camera.CameraGPU,
  camera_cpu: ^d.Camera,
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
    depth_texture_index    = camera_gpu.attachments[.DEPTH][frame_index].index,
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
  world_matrix_set_layout: vk.DescriptorSetLayout,
  spherical_camera_set_layout: vk.DescriptorSetLayout,
  mesh_data_buffer: ^gpu.BindlessBuffer(d.MeshData),
  textures_set_layout: vk.DescriptorSetLayout,
  sphere_mesh, cone_mesh, triangle_mesh: d.MeshHandle,
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
  env_map, env_result := shared.create_texture_2d_from_path(
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
    shared.destroy_texture_2d(gctx, texture_manager, self.environment_map)
  }
  environment_map := shared.get_texture_2d(texture_manager, self.environment_map)
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
  brdf_handle := shared.create_texture_2d_from_data(
    gctx,
    texture_manager,
    TEXTURE_LUT_GGX,
  ) or_return
  defer if ret != .SUCCESS {
    shared.destroy_texture_2d(gctx, texture_manager, brdf_handle)
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
    world_matrix_set_layout,
    spherical_camera_set_layout,
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
  self.sphere_mesh = sphere_mesh
  self.cone_mesh = cone_mesh
  self.triangle_mesh = triangle_mesh
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
  shared.destroy_texture_2d(gctx, texture_manager, self.environment_map)
  shared.destroy_texture_2d(gctx, texture_manager, self.brdf_lut)
  vk.DestroyPipelineLayout(gctx.device, self.lighting_pipeline_layout, nil)
  vk.DestroyPipeline(gctx.device, self.lighting_pipeline, nil)
}

BG_BLUE_GRAY :: [4]f32{0.0117, 0.0117, 0.0179, 1.0}
BG_DARK_GRAY :: [4]f32{0.0117, 0.0117, 0.0117, 1.0}
BG_ORANGE_GRAY :: [4]f32{0.0179, 0.0179, 0.0117, 1.0}

Renderer :: struct {
  ambient_pipeline:         vk.Pipeline,
  ambient_pipeline_layout:  vk.PipelineLayout,
  environment_map:          d.Image2DHandle,
  brdf_lut:                 d.Image2DHandle,
  environment_max_lod:      f32,
  ibl_intensity:            f32,
  lighting_pipeline:        vk.Pipeline,
  lighting_pipeline_layout: vk.PipelineLayout,
  sphere_mesh:              d.MeshHandle,
  cone_mesh:                d.MeshHandle,
  triangle_mesh:            d.MeshHandle,
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
  camera_cpu: ^d.Camera,
  texture_manager: ^gpu.TextureManager,
  command_buffer: vk.CommandBuffer,
  lights_descriptor_set: vk.DescriptorSet,
  world_matrix_descriptor_set: vk.DescriptorSet,
  spherical_camera_descriptor_set: vk.DescriptorSet,
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
    world_matrix_descriptor_set, // set = 3 (world matrices)
    spherical_camera_descriptor_set, // set = 4 (per-frame spherical cameras)
  )
}

render :: proc(
  self: ^Renderer,
  camera_handle: d.CameraHandle,
  camera_gpu: ^camera.CameraGPU,
  cameras_gpu: ^[d.MAX_CAMERAS]camera.CameraGPU,
  spherical_cameras_gpu: ^[d.MAX_CAMERAS]camera.SphericalCameraGPU,
  command_buffer: vk.CommandBuffer,
  meshes: d.Pool(d.Mesh),
  cameras: d.Pool(d.Camera),
  lights: d.Pool(d.Light),
  active_lights: []d.LightHandle,
  world_matrix_buffer: ^gpu.BindlessBuffer(matrix[4, 4]f32),
  vertex_buffer: vk.Buffer,
  index_buffer: vk.Buffer,
  frame_index: u32,
) {
  bind_and_draw_mesh :: proc(
    mesh_handle: d.MeshHandle,
    command_buffer: vk.CommandBuffer,
    meshes: d.Pool(d.Mesh),
    vertex_buffer: vk.Buffer,
    index_buffer: vk.Buffer,
  ) {
    mesh_ptr := cont.get(meshes, mesh_handle)
    if mesh_ptr == nil {
      log.errorf("Failed to get mesh for handle %v", mesh_handle)
      return
    }
    gpu.bind_vertex_index_buffers(
      command_buffer,
      vertex_buffer,
      index_buffer,
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
    position_texture_index = camera_gpu.attachments[.POSITION][frame_index].index,
    normal_texture_index   = camera_gpu.attachments[.NORMAL][frame_index].index,
    albedo_texture_index   = camera_gpu.attachments[.ALBEDO][frame_index].index,
    metallic_texture_index = camera_gpu.attachments[.METALLIC_ROUGHNESS][frame_index].index,
    emissive_texture_index = camera_gpu.attachments[.EMISSIVE][frame_index].index,
    depth_texture_index    = camera_gpu.attachments[.DEPTH][frame_index].index,
    input_image_index      = camera_gpu.attachments[.FINAL_IMAGE][frame_index].index,
  }
  for handle in active_lights {
    light := cont.get(lights, handle) or_continue
    world_matrix := gpu.get(&world_matrix_buffer.buffer, light.node_index)
    if world_matrix == nil do continue
    light_position := world_matrix[3].xyz
    shadow_map_index: u32 = 0xFFFFFFFF
    if light.cast_shadow {
      switch light.type {
      case .POINT:
        if light.camera_handle.index > 0 {
          spherical_cam_gpu := &spherical_cameras_gpu[light.camera_handle.index]
          shadow_map_index = spherical_cam_gpu.depth_cube[frame_index].index
        }
      case .DIRECTIONAL, .SPOT:
        if shadow_cam := cont.get(cameras, light.camera_handle); shadow_cam != nil {
          shadow_cam_gpu := &cameras_gpu[light.camera_handle.index]
          shadow_map_index = shadow_cam_gpu.attachments[.DEPTH][frame_index].index
        }
      }
    }
    push_constant.light_index = handle.index
    push_constant.light_position = {
      light_position.x,
      light_position.y,
      light_position.z,
      1.0,
    }
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
        self.sphere_mesh,
        command_buffer,
        meshes,
        vertex_buffer,
        index_buffer,
      )
    case .DIRECTIONAL:
      vk.CmdSetDepthCompareOp(command_buffer, .ALWAYS)
      vk.CmdSetCullMode(command_buffer, {.BACK})
      bind_and_draw_mesh(
        self.triangle_mesh,
        command_buffer,
        meshes,
        vertex_buffer,
        index_buffer,
      )
    case .SPOT:
      vk.CmdSetDepthCompareOp(command_buffer, .GREATER_OR_EQUAL)
      vk.CmdSetCullMode(command_buffer, {.BACK})
      bind_and_draw_mesh(
        self.cone_mesh,
        command_buffer,
        meshes,
        vertex_buffer,
        index_buffer,
      )
    }
  }
}

end_pass :: proc(command_buffer: vk.CommandBuffer) {
  vk.CmdEndRendering(command_buffer)
}

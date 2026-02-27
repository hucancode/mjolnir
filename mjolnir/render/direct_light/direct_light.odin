package direct_light

import "../../geometry"
import "../../gpu"
import d "../data"
import "../shared"
import "core:log"
import vk "vendor:vulkan"

LightType :: d.LightType

SHADER_VERT := #load("../../shader/lighting/vert.spv")
SHADER_FRAG := #load("../../shader/lighting/frag.spv")

BG_BLUE_GRAY :: [4]f32{0.0117, 0.0117, 0.0179, 1.0}
BG_DARK_GRAY :: [4]f32{0.0117, 0.0117, 0.0117, 1.0}
BG_ORANGE_GRAY :: [4]f32{0.0179, 0.0179, 0.0117, 1.0}

DirectLightPushConstants :: struct {
  light_color:  [4]f32, // 16 bytes - color.rgb + intensity (all types)
  position:     [3]f32, // 12 bytes - world position (point/spot only)
  radius:       f32,    // 4 bytes - light range (point/spot only)
  direction:    [3]f32, // 12 bytes - direction vector (spot/directional only)
  angle_inner:  f32,    // 4 bytes - inner cone angle (spot only)
  angle_outer:     f32, // 4 bytes - outer cone angle (spot only)
  light_type:      u32, // 4 bytes - 0=Point, 1=Directional, 2=Spot
  shadow_map_idx:  u32, // 4 bytes - shadow texture index, 0xFFFFFFFF = no shadow
  scene_camera_idx: u32, // 4 bytes
  shadow_view_projection: matrix[4, 4]f32, // 64 bytes
  position_texture_index: u32, // 4 bytes
  normal_texture_index:   u32, // 4 bytes
  albedo_texture_index:   u32, // 4 bytes
  metallic_texture_index: u32, // 4 bytes
}

Renderer :: struct {
  pipeline:        vk.Pipeline,
  pipeline_layout: vk.PipelineLayout,
  sphere_mesh:     LightVolumeMesh,
  cone_mesh:       LightVolumeMesh,
  triangle_mesh:   LightVolumeMesh,
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

init :: proc(
  self: ^Renderer,
  gctx: ^gpu.GPUContext,
  camera_set_layout: vk.DescriptorSetLayout,
  textures_set_layout: vk.DescriptorSetLayout,
) -> (
  ret: vk.Result,
) {
  log.debug("Direct lighting renderer init")
  self.pipeline_layout = gpu.create_pipeline_layout(
    gctx,
    vk.PushConstantRange {
      stageFlags = {.VERTEX, .FRAGMENT},
      size = size_of(DirectLightPushConstants),
    },
    camera_set_layout,
    textures_set_layout,
  ) or_return
  defer if ret != .SUCCESS {
    vk.DestroyPipelineLayout(gctx.device, self.pipeline_layout, nil)
  }
  vert_module := gpu.create_shader_module(gctx.device, SHADER_VERT) or_return
  defer vk.DestroyShaderModule(gctx.device, vert_module, nil)
  frag_module := gpu.create_shader_module(gctx.device, SHADER_FRAG) or_return
  defer vk.DestroyShaderModule(gctx.device, frag_module, nil)
  dynamic_states := [?]vk.DynamicState {
    .VIEWPORT,
    .SCISSOR,
    .DEPTH_COMPARE_OP,
    .CULL_MODE,
  }
  dynamic_state := gpu.create_dynamic_state(dynamic_states[:])
  vertex_input := vk.PipelineVertexInputStateCreateInfo {
    sType                           = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
    vertexBindingDescriptionCount   = 1,
    pVertexBindingDescriptions      = &geometry.VERTEX_BINDING_DESCRIPTION[0],
    vertexAttributeDescriptionCount = 1, // Only position needed for lighting
    pVertexAttributeDescriptions    = raw_data(
      geometry.VERTEX_ATTRIBUTE_DESCRIPTIONS[:],
    ), // Position at location 0
  }
  shader_stages := gpu.create_vert_frag_stages(
    vert_module,
    frag_module,
    &shared.SHADER_SPEC_CONSTANTS,
  )
  pipeline_info := vk.GraphicsPipelineCreateInfo {
    sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
    pNext               = &gpu.STANDARD_RENDERING_INFO,
    stageCount          = len(shader_stages),
    pStages             = raw_data(shader_stages[:]),
    pVertexInputState   = &vertex_input,
    pInputAssemblyState = &gpu.STANDARD_INPUT_ASSEMBLY,
    pViewportState      = &gpu.STANDARD_VIEWPORT_STATE,
    pRasterizationState = &gpu.STANDARD_RASTERIZER,
    pMultisampleState   = &gpu.STANDARD_MULTISAMPLING,
    pColorBlendState    = &gpu.COLOR_BLENDING_OVERFLOW,
    pDynamicState       = &dynamic_state,
    pDepthStencilState  = &gpu.READ_ONLY_DEPTH_STATE,
    layout              = self.pipeline_layout,
  }
  vk.CreateGraphicsPipelines(
    gctx.device,
    0,
    1,
    &pipeline_info,
    nil,
    &self.pipeline,
  ) or_return
  defer if ret != .SUCCESS {
    vk.DestroyPipeline(gctx.device, self.pipeline, nil)
  }
  log.info("Direct lighting pipeline initialized successfully")
  return .SUCCESS
}

setup :: proc(self: ^Renderer, gctx: ^gpu.GPUContext) -> (ret: vk.Result) {
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
  log.info("Direct lighting GPU resources setup")
  return .SUCCESS
}

teardown :: proc(self: ^Renderer, gctx: ^gpu.GPUContext) {
  destroy_light_volume_mesh(gctx.device, &self.sphere_mesh)
  destroy_light_volume_mesh(gctx.device, &self.cone_mesh)
  destroy_light_volume_mesh(gctx.device, &self.triangle_mesh)
}

shutdown :: proc(self: ^Renderer, gctx: ^gpu.GPUContext) {
  vk.DestroyPipelineLayout(gctx.device, self.pipeline_layout, nil)
  vk.DestroyPipeline(gctx.device, self.pipeline, nil)
}

begin_pass :: proc(
  self: ^Renderer,
  final_image_handle: gpu.Texture2DHandle,
  depth_handle: gpu.Texture2DHandle,
  texture_manager: ^gpu.TextureManager,
  command_buffer: vk.CommandBuffer,
  cameras_descriptor_set: vk.DescriptorSet,
) {
  final_image := gpu.get_texture_2d(
    texture_manager,
    final_image_handle,
  )
  depth_texture := gpu.get_texture_2d(
    texture_manager,
    depth_handle,
  )
  gpu.begin_rendering(
    command_buffer,
    depth_texture.spec.extent,
    gpu.create_depth_attachment(depth_texture, .LOAD, .DONT_CARE),
    gpu.create_color_attachment(final_image, .LOAD, .STORE, BG_BLUE_GRAY),
  )
  gpu.set_viewport_scissor(command_buffer, depth_texture.spec.extent)
  gpu.bind_graphics_pipeline(
    command_buffer,
    self.pipeline,
    self.pipeline_layout,
    cameras_descriptor_set, // set = 0 (per-frame cameras)
    texture_manager.descriptor_set, // set = 1 (textures/samplers)
  )
}

@(private)
draw_light_volume_mesh :: proc(
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
  vk.CmdDrawIndexed(command_buffer, mesh.index_count, 1, 0, 0, 0)
}

@(private)
push_and_draw :: proc(
  self: ^Renderer,
  command_buffer: vk.CommandBuffer,
  push: ^DirectLightPushConstants,
  mesh: ^LightVolumeMesh,
  depth_compare_op: vk.CompareOp,
  cull_mode: vk.CullModeFlags,
) {
  vk.CmdPushConstants(
    command_buffer,
    self.pipeline_layout,
    {.VERTEX, .FRAGMENT},
    0,
    size_of(push^),
    push,
  )
  vk.CmdSetDepthCompareOp(command_buffer, depth_compare_op)
  vk.CmdSetCullMode(command_buffer, cull_mode)
  draw_light_volume_mesh(mesh, command_buffer)
}

render_point_light :: proc(
  self: ^Renderer,
  camera_handle: u32,
  position_texture_idx: u32,
  normal_texture_idx: u32,
  albedo_texture_idx: u32,
  metallic_texture_idx: u32,
  light_color: [4]f32,
  position: [3]f32,
  radius: f32,
  shadow_map_idx: u32,
  shadow_view_projection: matrix[4, 4]f32,
  command_buffer: vk.CommandBuffer,
) {
  push := DirectLightPushConstants{
    scene_camera_idx       = camera_handle,
    position_texture_index = position_texture_idx,
    normal_texture_index   = normal_texture_idx,
    albedo_texture_index   = albedo_texture_idx,
    metallic_texture_index = metallic_texture_idx,
    shadow_map_idx         = shadow_map_idx,
    light_color            = light_color,
    position               = position,
    radius                 = radius,
    light_type             = u32(LightType.POINT),
  }
  if shadow_map_idx != 0xFFFFFFFF {
    push.shadow_view_projection = shadow_view_projection
  }
  push_and_draw(
    self,
    command_buffer,
    &push,
    &self.sphere_mesh,
    .GREATER_OR_EQUAL,
    {.FRONT},
  )
}

render_spot_light :: proc(
  self: ^Renderer,
  camera_handle: u32,
  position_texture_idx: u32,
  normal_texture_idx: u32,
  albedo_texture_idx: u32,
  metallic_texture_idx: u32,
  light_color: [4]f32,
  position: [3]f32,
  direction: [3]f32,
  radius: f32,
  angle_inner: f32,
  angle_outer: f32,
  shadow_map_idx: u32,
  shadow_view_projection: matrix[4, 4]f32,
  command_buffer: vk.CommandBuffer,
) {
  push := DirectLightPushConstants{
    scene_camera_idx       = camera_handle,
    position_texture_index = position_texture_idx,
    normal_texture_index   = normal_texture_idx,
    albedo_texture_index   = albedo_texture_idx,
    metallic_texture_index = metallic_texture_idx,
    shadow_map_idx         = shadow_map_idx,
    light_color            = light_color,
    position               = position,
    direction              = direction,
    radius                 = radius,
    angle_inner            = angle_inner,
    angle_outer            = angle_outer,
    light_type             = u32(LightType.SPOT),
  }
  if shadow_map_idx != 0xFFFFFFFF {
    push.shadow_view_projection = shadow_view_projection
  }
  push_and_draw(
    self,
    command_buffer,
    &push,
    &self.cone_mesh,
    .GREATER_OR_EQUAL,
    {.BACK},
  )
}

render_directional_light :: proc(
  self: ^Renderer,
  camera_handle: u32,
  position_texture_idx: u32,
  normal_texture_idx: u32,
  albedo_texture_idx: u32,
  metallic_texture_idx: u32,
  light_color: [4]f32,
  direction: [3]f32,
  shadow_map_idx: u32,
  shadow_view_projection: matrix[4, 4]f32,
  command_buffer: vk.CommandBuffer,
) {
  push := DirectLightPushConstants{
    scene_camera_idx       = camera_handle,
    position_texture_index = position_texture_idx,
    normal_texture_index   = normal_texture_idx,
    albedo_texture_index   = albedo_texture_idx,
    metallic_texture_index = metallic_texture_idx,
    shadow_map_idx         = shadow_map_idx,
    light_color            = light_color,
    direction              = direction,
    light_type             = u32(LightType.DIRECTIONAL),
  }
  if shadow_map_idx != 0xFFFFFFFF {
    push.shadow_view_projection = shadow_view_projection
  }
  push_and_draw(
    self,
    command_buffer,
    &push,
    &self.triangle_mesh,
    .ALWAYS,
    {.BACK},
  )
}

end_pass :: proc(command_buffer: vk.CommandBuffer) {
  vk.CmdEndRendering(command_buffer)
}

package direct_light

import "../../geometry"
import "../../gpu"
import "../camera"
import d "../data"
import "../shared"
import "../shadow"
import rg "../graph"
import "core:fmt"
import "core:log"
import vk "vendor:vulkan"

SHADER_VERT := #load("../../shader/lighting/vert.spv")
SHADER_FRAG := #load("../../shader/lighting/frag.spv")

BG_BLUE_GRAY :: [4]f32{0.0117, 0.0117, 0.0179, 1.0}
BG_DARK_GRAY :: [4]f32{0.0117, 0.0117, 0.0117, 1.0}
BG_ORANGE_GRAY :: [4]f32{0.0179, 0.0179, 0.0117, 1.0}

PushConstant :: struct {
  light_index:            u32,
  scene_camera_idx:       u32,
  position_texture_index: u32,
  normal_texture_index:   u32,
  albedo_texture_index:   u32,
  metallic_texture_index: u32,
  emissive_texture_index: u32,
  input_image_index:      u32,
  shadow_map_index:       u32,
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
  lights_set_layout: vk.DescriptorSetLayout,
  shadow_data_set_layout: vk.DescriptorSetLayout,
  textures_set_layout: vk.DescriptorSetLayout,
) -> (
  ret: vk.Result,
) {
  log.debug("Direct lighting renderer init")
  self.pipeline_layout = gpu.create_pipeline_layout(
    gctx,
    vk.PushConstantRange {
      stageFlags = {.VERTEX, .FRAGMENT},
      size = size_of(PushConstant),
    },
    camera_set_layout,
    textures_set_layout,
    lights_set_layout,
    shadow_data_set_layout,
  ) or_return
  defer if ret != .SUCCESS {
    vk.DestroyPipelineLayout(gctx.device, self.pipeline_layout, nil)
  }
  vert_module := gpu.create_shader_module(
    gctx.device,
    SHADER_VERT,
  ) or_return
  defer vk.DestroyShaderModule(gctx.device, vert_module, nil)
  frag_module := gpu.create_shader_module(
    gctx.device,
    SHADER_FRAG,
  ) or_return
  defer vk.DestroyShaderModule(gctx.device, frag_module, nil)
  dynamic_states := [?]vk.DynamicState {
    .VIEWPORT,
    .SCISSOR,
    .DEPTH_COMPARE_OP,
    .CULL_MODE,
  }
  dynamic_state := gpu.create_dynamic_state(
    dynamic_states[:],
  )
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

setup :: proc(
  self: ^Renderer,
  gctx: ^gpu.GPUContext,
) -> (
  ret: vk.Result,
) {
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

teardown :: proc(
  self: ^Renderer,
  gctx: ^gpu.GPUContext,
) {
  destroy_light_volume_mesh(gctx.device, &self.sphere_mesh)
  destroy_light_volume_mesh(gctx.device, &self.cone_mesh)
  destroy_light_volume_mesh(gctx.device, &self.triangle_mesh)
}

shutdown :: proc(
  self: ^Renderer,
  gctx: ^gpu.GPUContext,
) {
  vk.DestroyPipelineLayout(gctx.device, self.pipeline_layout, nil)
  vk.DestroyPipeline(gctx.device, self.pipeline, nil)
}

begin_pass :: proc(
  self: ^Renderer,
  camera: ^camera.Camera,
  texture_manager: ^gpu.TextureManager,
  command_buffer: vk.CommandBuffer,
  cameras_descriptor_set: vk.DescriptorSet,
  lights_descriptor_set: vk.DescriptorSet,
  shadow_data_descriptor_set: vk.DescriptorSet,
  frame_index: u32,
) {
  final_image := gpu.get_texture_2d(
    texture_manager,
    camera.attachments[.FINAL_IMAGE][frame_index],
  )
  depth_texture := gpu.get_texture_2d(
    texture_manager,
    camera.attachments[.DEPTH][frame_index],
  )
  gpu.begin_rendering(
    command_buffer,
    depth_texture.spec.extent,
    gpu.create_depth_attachment(depth_texture, .LOAD, .DONT_CARE),
    gpu.create_color_attachment(final_image, .LOAD, .STORE, BG_BLUE_GRAY),
  )
  gpu.set_viewport_scissor(
    command_buffer,
    depth_texture.spec.extent,
  )
  gpu.bind_graphics_pipeline(
    command_buffer,
    self.pipeline,
    self.pipeline_layout,
    cameras_descriptor_set, // set = 0 (per-frame cameras)
    texture_manager.descriptor_set, // set = 1 (textures/samplers)
    lights_descriptor_set, // set = 2 (lights)
    shadow_data_descriptor_set, // set = 3 (per-frame shadow data)
  )
}

render :: proc(
  self: ^Renderer,
  camera_handle: u32,
  camera: ^camera.Camera,
  shadow_texture_indices: ^[d.MAX_LIGHTS]u32,
  command_buffer: vk.CommandBuffer,
  lights_buffer: ^gpu.BindlessBuffer(d.Light),
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
    vk.CmdDrawIndexed(command_buffer, mesh.index_count, 1, 0, 0, 0)
  }
  push_constant := PushConstant {
    scene_camera_idx       = camera_handle,
    position_texture_index = camera.attachments[.POSITION][frame_index].index,
    normal_texture_index   = camera.attachments[.NORMAL][frame_index].index,
    albedo_texture_index   = camera.attachments[.ALBEDO][frame_index].index,
    metallic_texture_index = camera.attachments[.METALLIC_ROUGHNESS][frame_index].index,
    emissive_texture_index = camera.attachments[.EMISSIVE][frame_index].index,
    input_image_index      = camera.attachments[.FINAL_IMAGE][frame_index].index,
  }
  for handle in active_lights {
    light := gpu.get(&lights_buffer.buffer, handle.index)
    shadow_map_index := shadow_texture_indices[handle.index]
    push_constant.light_index = handle.index
    push_constant.shadow_map_index = shadow_map_index
    vk.CmdPushConstants(
      command_buffer,
      self.pipeline_layout,
      {.VERTEX, .FRAGMENT},
      0,
      size_of(push_constant),
      &push_constant,
    )
    switch light.type {
    case .POINT:
      vk.CmdSetDepthCompareOp(command_buffer, .GREATER_OR_EQUAL)
      vk.CmdSetCullMode(command_buffer, {.FRONT})
      bind_and_draw_mesh(&self.sphere_mesh, command_buffer)
    case .DIRECTIONAL:
      vk.CmdSetDepthCompareOp(command_buffer, .ALWAYS)
      vk.CmdSetCullMode(command_buffer, {.BACK})
      bind_and_draw_mesh(&self.triangle_mesh, command_buffer)
    case .SPOT:
      vk.CmdSetDepthCompareOp(command_buffer, .GREATER_OR_EQUAL)
      vk.CmdSetCullMode(command_buffer, {.BACK})
      bind_and_draw_mesh(&self.cone_mesh, command_buffer)
    }
  }
}

end_pass :: proc(command_buffer: vk.CommandBuffer) {
  vk.CmdEndRendering(command_buffer)
}

// ============================================================================
// Graph-based API for render graph integration
// ============================================================================

DirectLightPassGraphContext :: struct {
  renderer:                 ^Renderer,
  texture_manager:          ^gpu.TextureManager,
  cameras_descriptor_set:   vk.DescriptorSet,
  lights_descriptor_set:    vk.DescriptorSet,
  shadow_data_descriptor_set: vk.DescriptorSet,
  cameras:                  ^map[u32]camera.Camera,
  lights_buffer:            ^gpu.BindlessBuffer(d.Light),
  active_lights:            []d.LightHandle,
  shadow_texture_indices:   ^[d.MAX_LIGHTS]u32,
}

direct_light_pass_setup :: proc(builder: ^rg.PassBuilder, user_data: rawptr) {
  cam_index := builder.scope_index

  // Read G-buffer attachments (written by geometry pass)
  rg.builder_read(builder, fmt.tprintf("camera_%d_gbuffer_position", cam_index))
  rg.builder_read(builder, fmt.tprintf("camera_%d_gbuffer_normal", cam_index))
  rg.builder_read(builder, fmt.tprintf("camera_%d_gbuffer_albedo", cam_index))
  rg.builder_read(builder, fmt.tprintf("camera_%d_gbuffer_metallic_roughness", cam_index))
  rg.builder_read(builder, fmt.tprintf("camera_%d_gbuffer_emissive", cam_index))

  // Read depth (for depth testing during light volume rendering)
  rg.builder_read(builder, fmt.tprintf("camera_%d_depth", cam_index))

  // Read shadow maps from all active shadow slots
  // Note: Dead pass elimination will remove unused shadow resources automatically
  for slot in 0 ..< shadow.MAX_SHADOW_MAPS {
    rg.builder_read(builder, fmt.tprintf("shadow_map_%d", slot))
  }

  // Read-write final_image (blend direct lighting with existing ambient lighting)
  // Must use read_write because loadOp = LOAD reads the existing framebuffer content
  rg.builder_read_write(builder, fmt.tprintf("camera_%d_final_image", cam_index))
}

direct_light_pass_execute :: proc(pass_ctx: ^rg.PassContext, user_data: rawptr) {
  ctx := cast(^DirectLightPassGraphContext)user_data
  self := ctx.renderer
  cam_idx := pass_ctx.scope_index
  cam, cam_ok := ctx.cameras[cam_idx]
  if !cam_ok do return

  // Resolve final_image resource ID
  final_image_name := fmt.tprintf("camera_%d_final_image", cam_idx)
  final_image_id := rg.ResourceId(final_image_name)
  final_image_handle, resolve_ok := rg.resolve(rg.TextureHandle, pass_ctx, final_image_id)
  if !resolve_ok {
    log.errorf("Failed to resolve final_image for camera %d", cam_idx)
    return
  }
  // Resolve depth resource ID
  depth_name := fmt.tprintf("camera_%d_depth", cam_idx)
  depth_id := rg.ResourceId(depth_name)
  depth_handle, depth_resolve_ok := rg.resolve(rg.DepthTextureHandle, pass_ctx, depth_id)
  if !depth_resolve_ok {
    log.errorf("Failed to resolve depth for camera %d", cam_idx)
    return
  }

  // Begin rendering to final_image with depth test
  color_attachment := vk.RenderingAttachmentInfo{
    sType = .RENDERING_ATTACHMENT_INFO,
    imageView = final_image_handle.view,
    imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
    loadOp = .LOAD,  // Load existing content (ambient lighting)
    storeOp = .STORE,
    clearValue = {color = {float32 = {0.0, 0.0, 0.0, 1.0}}},  // Unused with LOAD, but good practice
  }

  depth_attachment := vk.RenderingAttachmentInfo{
    sType = .RENDERING_ATTACHMENT_INFO,
    imageView = depth_handle.view,
    imageLayout = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
    loadOp = .LOAD,  // Load existing depth from geometry pass
    storeOp = .DONT_CARE,  // Don't need to save depth
    clearValue = {depthStencil = {depth = 1.0}},  // Unused with LOAD, but good practice
  }

  rendering_info := vk.RenderingInfo{
    sType = .RENDERING_INFO,
    renderArea = {extent = final_image_handle.extent},
    layerCount = 1,
    colorAttachmentCount = 1,
    pColorAttachments = &color_attachment,
    pDepthAttachment = &depth_attachment,
  }

  vk.CmdBeginRendering(pass_ctx.cmd, &rendering_info)

  gpu.set_viewport_scissor(
    pass_ctx.cmd,
    final_image_handle.extent,
  )

  gpu.bind_graphics_pipeline(
    pass_ctx.cmd,
    self.pipeline,
    self.pipeline_layout,
    ctx.cameras_descriptor_set,
    ctx.texture_manager.descriptor_set,
    ctx.lights_descriptor_set,
    ctx.shadow_data_descriptor_set,
  )

  // Helper to bind and draw mesh
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
    vk.CmdDrawIndexed(command_buffer, mesh.index_count, 1, 0, 0, 0)
  }

  // Build push constants using camera attachment texture indices
  push_constant := PushConstant{
    scene_camera_idx = cam_idx,
    position_texture_index = cam.attachments[.POSITION][pass_ctx.frame_index].index,
    normal_texture_index = cam.attachments[.NORMAL][pass_ctx.frame_index].index,
    albedo_texture_index = cam.attachments[.ALBEDO][pass_ctx.frame_index].index,
    metallic_texture_index = cam.attachments[.METALLIC_ROUGHNESS][pass_ctx.frame_index].index,
    emissive_texture_index = cam.attachments[.EMISSIVE][pass_ctx.frame_index].index,
    input_image_index = cam.attachments[.FINAL_IMAGE][pass_ctx.frame_index].index,
  }

  // Render light volumes for each active light
  for handle in ctx.active_lights {
    light := gpu.get(&ctx.lights_buffer.buffer, handle.index)
    shadow_map_index := ctx.shadow_texture_indices[handle.index]
    push_constant.light_index = handle.index
    push_constant.shadow_map_index = shadow_map_index

    vk.CmdPushConstants(
      pass_ctx.cmd,
      self.pipeline_layout,
      {.VERTEX, .FRAGMENT},
      0,
      size_of(push_constant),
      &push_constant,
    )

    switch light.type {
    case .POINT:
      vk.CmdSetDepthCompareOp(pass_ctx.cmd, .GREATER_OR_EQUAL)
      vk.CmdSetCullMode(pass_ctx.cmd, {.FRONT})
      bind_and_draw_mesh(&self.sphere_mesh, pass_ctx.cmd)
    case .DIRECTIONAL:
      vk.CmdSetDepthCompareOp(pass_ctx.cmd, .ALWAYS)
      vk.CmdSetCullMode(pass_ctx.cmd, {.BACK})
      bind_and_draw_mesh(&self.triangle_mesh, pass_ctx.cmd)
    case .SPOT:
      vk.CmdSetDepthCompareOp(pass_ctx.cmd, .GREATER_OR_EQUAL)
      vk.CmdSetCullMode(pass_ctx.cmd, {.BACK})
      bind_and_draw_mesh(&self.cone_mesh, pass_ctx.cmd)
    }
  }

  vk.CmdEndRendering(pass_ctx.cmd)
}

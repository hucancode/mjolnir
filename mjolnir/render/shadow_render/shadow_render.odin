package shadow_render

import "../../geometry"
import "../../gpu"
import d "../data"
import "core:math"
import "core:math/linalg"
import vk "vendor:vulkan"

SHADER_SHADOW_DEPTH_VERT :: #load("../../shader/shadow/vert.spv")

System :: struct {
  max_draws:            u32,
  depth_pipeline_layout: vk.PipelineLayout,
  depth_pipeline:       vk.Pipeline,
}

@(private)
safe_normalize :: proc(v: [3]f32, fallback: [3]f32) -> [3]f32 {
  len_sq := linalg.dot(v, v)
  if len_sq < 1e-6 do return fallback
  return linalg.normalize(v)
}

@(private)
make_light_view :: proc(position, direction: [3]f32) -> matrix[4, 4]f32 {
  forward := safe_normalize(direction, {0, -1, 0})
  up := [3]f32{0, 1, 0}
  if math.abs(linalg.dot(forward, up)) > 0.95 {
    up = {0, 0, 1}
  }
  target := position + forward
  return linalg.matrix4_look_at(position, target, up)
}

init :: proc(
  self: ^System,
  gctx: ^gpu.GPUContext,
  shadow_data_set_layout: vk.DescriptorSetLayout,
  textures_set_layout: vk.DescriptorSetLayout,
  bone_set_layout: vk.DescriptorSetLayout,
  material_set_layout: vk.DescriptorSetLayout,
  node_data_set_layout: vk.DescriptorSetLayout,
  mesh_data_set_layout: vk.DescriptorSetLayout,
  vertex_skinning_set_layout: vk.DescriptorSetLayout,
) -> (ret: vk.Result) {
  self.max_draws = d.MAX_NODES_IN_SCENE
  self.depth_pipeline_layout = gpu.create_pipeline_layout(
    gctx,
    vk.PushConstantRange {
      stageFlags = {.VERTEX, .FRAGMENT},
      size = size_of(u32),
    },
    shadow_data_set_layout,
    textures_set_layout,
    bone_set_layout,
    material_set_layout,
    node_data_set_layout,
    mesh_data_set_layout,
    vertex_skinning_set_layout,
  ) or_return
  defer if ret != .SUCCESS {
    vk.DestroyPipelineLayout(gctx.device, self.depth_pipeline_layout, nil)
    self.depth_pipeline_layout = 0
  }
  shader := gpu.create_shader_module(gctx.device, SHADER_SHADOW_DEPTH_VERT) or_return
  defer vk.DestroyShaderModule(gctx.device, shader, nil)
  vertex_bindings := [?]vk.VertexInputBindingDescription {
    {binding = 0, stride = size_of(geometry.Vertex), inputRate = .VERTEX},
  }
  vertex_attributes := [?]vk.VertexInputAttributeDescription {
    {
      location = 0,
      binding = 0,
      format = .R32G32B32_SFLOAT,
      offset = u32(offset_of(geometry.Vertex, position)),
    },
  }
  vertex_input_info := vk.PipelineVertexInputStateCreateInfo {
    sType                           = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
    vertexBindingDescriptionCount   = len(vertex_bindings),
    pVertexBindingDescriptions      = raw_data(vertex_bindings[:]),
    vertexAttributeDescriptionCount = len(vertex_attributes),
    pVertexAttributeDescriptions    = raw_data(vertex_attributes[:]),
  }
  stages := gpu.create_vert_stage(shader)
  info := vk.GraphicsPipelineCreateInfo {
    sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
    pNext               = &gpu.DEPTH_ONLY_RENDERING_INFO,
    stageCount          = len(stages),
    pStages             = raw_data(stages[:]),
    pVertexInputState   = &vertex_input_info,
    pInputAssemblyState = &gpu.STANDARD_INPUT_ASSEMBLY,
    pViewportState      = &gpu.STANDARD_VIEWPORT_STATE,
    pRasterizationState = &gpu.STANDARD_RASTERIZER,
    pMultisampleState   = &gpu.STANDARD_MULTISAMPLING,
    pDepthStencilState  = &gpu.READ_WRITE_DEPTH_STATE,
    pDynamicState       = &gpu.STANDARD_DYNAMIC_STATES,
    layout              = self.depth_pipeline_layout,
  }
  vk.CreateGraphicsPipelines(gctx.device, 0, 1, &info, nil, &self.depth_pipeline) or_return
  defer if ret != .SUCCESS {
    vk.DestroyPipeline(gctx.device, self.depth_pipeline, nil)
    self.depth_pipeline = 0
  }
  return .SUCCESS
}

shutdown :: proc(self: ^System, gctx: ^gpu.GPUContext) {
  vk.DestroyPipeline(gctx.device, self.depth_pipeline, nil)
  vk.DestroyPipelineLayout(gctx.device, self.depth_pipeline_layout, nil)
}

sync_lights :: proc(
  slot_state: ^d.ShadowSlotState,
  shadow_data_buffer: ^gpu.PerFrameBindlessBuffer(d.ShadowData, d.FRAMES_IN_FLIGHT),
  lights_buffer: ^gpu.BindlessBuffer(d.Light),
  active_lights: []d.LightHandle,
  frame_index: u32,
) {
  for i in 0 ..< d.MAX_SHADOW_MAPS {
    slot_state.slot_active[i] = false
  }
  for i in 0 ..< d.MAX_LIGHTS {
    slot_state.light_to_slot[i] = d.INVALID_SHADOW_INDEX
  }
  zero_shadow: d.ShadowData
  for slot in 0 ..< d.MAX_SHADOW_MAPS {
    gpu.write(&shadow_data_buffer.buffers[frame_index], &zero_shadow, int(slot))
  }

  next_slot: u32 = 0
  for handle in active_lights {
    light := gpu.get(&lights_buffer.buffer, handle.index)
    position := light.position.xyz
    direction := safe_normalize(light.direction.xyz, {0, -1, 0})
    if !light.cast_shadow || next_slot >= d.MAX_SHADOW_MAPS {
      light.shadow_index = d.INVALID_SHADOW_INDEX
      gpu.write(&lights_buffer.buffer, light, int(handle.index))
      continue
    }
    slot := next_slot
    next_slot += 1
    slot_state.slot_active[slot] = true
    slot_state.slot_kind[slot] = light.type
    slot_state.light_to_slot[handle.index] = slot
    light.shadow_index = slot
    gpu.write(&lights_buffer.buffer, light, int(handle.index))

    shadow_data := d.ShadowData {
      view       = linalg.MATRIX4F32_IDENTITY,
      projection = linalg.MATRIX4F32_IDENTITY,
      near       = 0.1,
      far        = max(0.2, light.radius),
      position   = position,
      direction  = direction,
    }
    switch light.type {
    case .POINT:
      near_plane: f32 = 0.1
      far_plane := max(near_plane + 0.1, light.radius)
      shadow_data.near = near_plane
      shadow_data.far = far_plane
      shadow_data.projection = linalg.matrix4_perspective(
        f32(math.PI * 0.5),
        1.0,
        near_plane,
        far_plane,
        flip_z_axis = false,
      )
      shadow_data.position = position
    case .SPOT:
      near_plane: f32 = 0.1
      far_plane := max(near_plane + 0.1, light.radius)
      shadow_data.view = make_light_view(position, direction)
      shadow_data.projection = linalg.matrix4_perspective(
        max(light.angle_outer * 2.0, 0.001),
        1.0,
        near_plane,
        far_plane,
      )
      shadow_data.near = near_plane
      shadow_data.far = far_plane
      shadow_data.frustum_planes =
        geometry.make_frustum(shadow_data.projection * shadow_data.view).planes
    case .DIRECTIONAL:
      near_plane: f32 = 0.1
      far_plane := max(near_plane + 0.1, light.radius * 2.0)
      camera_pos := position - direction * light.radius
      shadow_data.view = make_light_view(camera_pos, direction)
      half_extent := max(light.radius, 0.5)
      shadow_data.projection = linalg.matrix_ortho3d(
        -half_extent,
        half_extent,
        -half_extent,
        half_extent,
        near_plane,
        far_plane,
      )
      shadow_data.near = near_plane
      shadow_data.far = far_plane
      shadow_data.position = camera_pos
      shadow_data.frustum_planes =
        geometry.make_frustum(shadow_data.projection * shadow_data.view).planes
    }
    gpu.write(&shadow_data_buffer.buffers[frame_index], &shadow_data, int(slot))
  }
}

invalidate_light :: proc(slot_state: ^d.ShadowSlotState, light_index: u32) {
  if light_index >= d.MAX_LIGHTS do return
  slot := slot_state.light_to_slot[light_index]
  if slot == d.INVALID_SHADOW_INDEX do return
  slot_state.slot_active[slot] = false
  slot_state.light_to_slot[light_index] = d.INVALID_SHADOW_INDEX
}

shadow_render :: proc(
  self: ^System,
  command_buffer: vk.CommandBuffer,
  texture_manager: ^gpu.TextureManager,
  slot_state: ^d.ShadowSlotState,
  spot_lights: ^[d.MAX_SHADOW_MAPS]d.ShadowMap,
  directional_lights: ^[d.MAX_SHADOW_MAPS]d.ShadowMap,
  shadow_data_descriptor_set: vk.DescriptorSet,
  textures_descriptor_set: vk.DescriptorSet,
  bone_descriptor_set: vk.DescriptorSet,
  material_descriptor_set: vk.DescriptorSet,
  node_data_descriptor_set: vk.DescriptorSet,
  mesh_data_descriptor_set: vk.DescriptorSet,
  vertex_skinning_descriptor_set: vk.DescriptorSet,
  vertex_buffer: vk.Buffer,
  index_buffer: vk.Buffer,
  frame_index: u32,
) {
  for slot in 0 ..< d.MAX_SHADOW_MAPS {
    if !slot_state.slot_active[slot] do continue
    kind := slot_state.slot_kind[slot]
    if kind != .SPOT && kind != .DIRECTIONAL do continue

    if kind == .SPOT {
      gpu.buffer_barrier(
        command_buffer,
        spot_lights[slot].draw_commands[frame_index].buffer,
        vk.DeviceSize(spot_lights[slot].draw_commands[frame_index].bytes_count),
        {.SHADER_WRITE},
        {.INDIRECT_COMMAND_READ},
        {.COMPUTE_SHADER},
        {.DRAW_INDIRECT},
      )
      gpu.buffer_barrier(
        command_buffer,
        spot_lights[slot].draw_count[frame_index].buffer,
        vk.DeviceSize(spot_lights[slot].draw_count[frame_index].bytes_count),
        {.SHADER_WRITE},
        {.INDIRECT_COMMAND_READ},
        {.COMPUTE_SHADER},
        {.DRAW_INDIRECT},
      )
      depth_texture := gpu.get_texture_2d(texture_manager, spot_lights[slot].shadow_map[frame_index])
      if depth_texture == nil do continue
      gpu.image_barrier(
        command_buffer,
        depth_texture.image,
        .UNDEFINED,
        .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
        {},
        {.DEPTH_STENCIL_ATTACHMENT_WRITE},
        {.TOP_OF_PIPE},
        {.EARLY_FRAGMENT_TESTS},
        {.DEPTH},
      )
      depth_attachment := gpu.create_depth_attachment(depth_texture, .CLEAR, .STORE)
      gpu.begin_depth_rendering(command_buffer, vk.Extent2D{d.SHADOW_MAP_SIZE, d.SHADOW_MAP_SIZE}, &depth_attachment)
      gpu.set_viewport_scissor(command_buffer, vk.Extent2D{d.SHADOW_MAP_SIZE, d.SHADOW_MAP_SIZE})
      gpu.bind_graphics_pipeline(
        command_buffer,
        self.depth_pipeline,
        self.depth_pipeline_layout,
        shadow_data_descriptor_set,
        textures_descriptor_set,
        bone_descriptor_set,
        material_descriptor_set,
        node_data_descriptor_set,
        mesh_data_descriptor_set,
        vertex_skinning_descriptor_set,
      )
      cam_idx := u32(slot)
      vk.CmdPushConstants(command_buffer, self.depth_pipeline_layout, {.VERTEX, .FRAGMENT}, 0, size_of(u32), &cam_idx)
      gpu.bind_vertex_index_buffers(command_buffer, vertex_buffer, index_buffer)
      vk.CmdDrawIndexedIndirectCount(
        command_buffer,
        spot_lights[slot].draw_commands[frame_index].buffer,
        0,
        spot_lights[slot].draw_count[frame_index].buffer,
        0,
        self.max_draws,
        u32(size_of(vk.DrawIndexedIndirectCommand)),
      )
      vk.CmdEndRendering(command_buffer)
      gpu.image_barrier(
        command_buffer,
        depth_texture.image,
        .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
        .DEPTH_STENCIL_READ_ONLY_OPTIMAL,
        {.DEPTH_STENCIL_ATTACHMENT_WRITE},
        {.SHADER_READ},
        {.LATE_FRAGMENT_TESTS},
        {.FRAGMENT_SHADER},
        {.DEPTH},
      )
    } else {
      gpu.buffer_barrier(
        command_buffer,
        directional_lights[slot].draw_commands[frame_index].buffer,
        vk.DeviceSize(directional_lights[slot].draw_commands[frame_index].bytes_count),
        {.SHADER_WRITE},
        {.INDIRECT_COMMAND_READ},
        {.COMPUTE_SHADER},
        {.DRAW_INDIRECT},
      )
      gpu.buffer_barrier(
        command_buffer,
        directional_lights[slot].draw_count[frame_index].buffer,
        vk.DeviceSize(directional_lights[slot].draw_count[frame_index].bytes_count),
        {.SHADER_WRITE},
        {.INDIRECT_COMMAND_READ},
        {.COMPUTE_SHADER},
        {.DRAW_INDIRECT},
      )
      depth_texture := gpu.get_texture_2d(texture_manager, directional_lights[slot].shadow_map[frame_index])
      if depth_texture == nil do continue
      gpu.image_barrier(
        command_buffer,
        depth_texture.image,
        .UNDEFINED,
        .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
        {},
        {.DEPTH_STENCIL_ATTACHMENT_WRITE},
        {.TOP_OF_PIPE},
        {.EARLY_FRAGMENT_TESTS},
        {.DEPTH},
      )
      depth_attachment := gpu.create_depth_attachment(depth_texture, .CLEAR, .STORE)
      gpu.begin_depth_rendering(command_buffer, vk.Extent2D{d.SHADOW_MAP_SIZE, d.SHADOW_MAP_SIZE}, &depth_attachment)
      gpu.set_viewport_scissor(command_buffer, vk.Extent2D{d.SHADOW_MAP_SIZE, d.SHADOW_MAP_SIZE})
      gpu.bind_graphics_pipeline(
        command_buffer,
        self.depth_pipeline,
        self.depth_pipeline_layout,
        shadow_data_descriptor_set,
        textures_descriptor_set,
        bone_descriptor_set,
        material_descriptor_set,
        node_data_descriptor_set,
        mesh_data_descriptor_set,
        vertex_skinning_descriptor_set,
      )
      cam_idx := u32(slot)
      vk.CmdPushConstants(command_buffer, self.depth_pipeline_layout, {.VERTEX, .FRAGMENT}, 0, size_of(u32), &cam_idx)
      gpu.bind_vertex_index_buffers(command_buffer, vertex_buffer, index_buffer)
      vk.CmdDrawIndexedIndirectCount(
        command_buffer,
        directional_lights[slot].draw_commands[frame_index].buffer,
        0,
        directional_lights[slot].draw_count[frame_index].buffer,
        0,
        self.max_draws,
        u32(size_of(vk.DrawIndexedIndirectCommand)),
      )
      vk.CmdEndRendering(command_buffer)
      gpu.image_barrier(
        command_buffer,
        depth_texture.image,
        .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
        .DEPTH_STENCIL_READ_ONLY_OPTIMAL,
        {.DEPTH_STENCIL_ATTACHMENT_WRITE},
        {.SHADER_READ},
        {.LATE_FRAGMENT_TESTS},
        {.FRAGMENT_SHADER},
        {.DEPTH},
      )
    }
  }
}

get_texture_index :: proc(
  spot_lights: ^[d.MAX_SHADOW_MAPS]d.ShadowMap,
  directional_lights: ^[d.MAX_SHADOW_MAPS]d.ShadowMap,
  point_lights: ^[d.MAX_SHADOW_MAPS]d.ShadowMapCube,
  light_type: d.LightType,
  shadow_index: u32,
  frame_index: u32,
) -> u32 {
  if shadow_index == d.INVALID_SHADOW_INDEX || shadow_index >= d.MAX_SHADOW_MAPS {
    return d.INVALID_SHADOW_INDEX
  }
  switch light_type {
  case .SPOT:
    return spot_lights[shadow_index].shadow_map[frame_index].index
  case .DIRECTIONAL:
    return directional_lights[shadow_index].shadow_map[frame_index].index
  case .POINT:
    return point_lights[shadow_index].shadow_cube[frame_index].index
  }
  return d.INVALID_SHADOW_INDEX
}

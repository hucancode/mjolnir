package shadow

import "../../geometry"
import "../../gpu"
import d "../data"
import light "../lighting"
import "core:math"
import "core:math/linalg"
import vk "vendor:vulkan"

SHADER_SHADOW_CULLING :: #load("../../shader/shadow/cull.spv")
SHADER_SPHERE_CULLING :: #load("../../shader/shadow_spherical/cull.spv")
SHADER_SHADOW_DEPTH_VERT :: #load("../../shader/shadow/vert.spv")
SHADER_SPHERE_DEPTH_VERT :: #load("../../shader/shadow_spherical/vert.spv")
SHADER_SPHERE_DEPTH_GEOM :: #load("../../shader/shadow_spherical/geom.spv")
SHADER_SPHERE_DEPTH_FRAG :: #load("../../shader/shadow_spherical/frag.spv")

INVALID_SHADOW_INDEX :: 0xFFFFFFFF
MAX_SHADOW_MAPS :: 16
SHADOW_MAP_SIZE :: 512

ShadowData :: struct {
  view:           matrix[4, 4]f32,
  projection:     matrix[4, 4]f32,
  position:       [3]f32,
  near:           f32,
  direction:      [3]f32,
  far:            f32,
  frustum_planes: [6][4]f32,
}

VisibilityPushConstants :: struct {
  camera_index:  u32,
  node_count:    u32,
  max_draws:     u32,
  include_flags: d.NodeFlagSet,
  exclude_flags: d.NodeFlagSet,
}

SphereVisibilityPushConstants :: struct {
  camera_index:  u32,
  node_count:    u32,
  max_draws:     u32,
  include_flags: d.NodeFlagSet,
  exclude_flags: d.NodeFlagSet,
}

ShadowSystem :: struct {
  node_count:                    u32,
  max_draws:                     u32,
  shadow_cull_descriptor_layout: vk.DescriptorSetLayout,
  sphere_cull_descriptor_layout: vk.DescriptorSetLayout,
  shadow_cull_layout:            vk.PipelineLayout,
  sphere_cull_layout:            vk.PipelineLayout,
  shadow_cull_pipeline:          vk.Pipeline,
  sphere_cull_pipeline:          vk.Pipeline,
  depth_pipeline_layout:         vk.PipelineLayout,
  depth_pipeline:                vk.Pipeline,
  sphere_depth_pipeline_layout:  vk.PipelineLayout,
  sphere_depth_pipeline:         vk.Pipeline,
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

shadow_init :: proc(
  self: ^ShadowSystem,
  gctx: ^gpu.GPUContext,
  shadow_data_set_layout: vk.DescriptorSetLayout,
  textures_set_layout: vk.DescriptorSetLayout,
  bone_set_layout: vk.DescriptorSetLayout,
  material_set_layout: vk.DescriptorSetLayout,
  node_data_set_layout: vk.DescriptorSetLayout,
  mesh_data_set_layout: vk.DescriptorSetLayout,
  vertex_skinning_set_layout: vk.DescriptorSetLayout,
) -> (
  ret: vk.Result,
) {
  self.max_draws = d.MAX_NODES_IN_SCENE
  self.shadow_cull_descriptor_layout = gpu.create_descriptor_set_layout(
    gctx,
    {.STORAGE_BUFFER, {.COMPUTE}},
    {.STORAGE_BUFFER, {.COMPUTE}},
    {.STORAGE_BUFFER, {.COMPUTE}},
    {.STORAGE_BUFFER, {.COMPUTE}},
    {.STORAGE_BUFFER, {.COMPUTE}},
    {.STORAGE_BUFFER, {.COMPUTE}},
  ) or_return
  defer if ret != .SUCCESS {
    vk.DestroyDescriptorSetLayout(
      gctx.device,
      self.shadow_cull_descriptor_layout,
      nil,
    )
    self.shadow_cull_descriptor_layout = 0
  }
  self.sphere_cull_descriptor_layout = gpu.create_descriptor_set_layout(
    gctx,
    {.STORAGE_BUFFER, {.COMPUTE}},
    {.STORAGE_BUFFER, {.COMPUTE}},
    {.STORAGE_BUFFER, {.COMPUTE}},
    {.STORAGE_BUFFER, {.COMPUTE}},
    {.STORAGE_BUFFER, {.COMPUTE}},
    {.STORAGE_BUFFER, {.COMPUTE}},
  ) or_return
  defer if ret != .SUCCESS {
    vk.DestroyDescriptorSetLayout(
      gctx.device,
      self.sphere_cull_descriptor_layout,
      nil,
    )
    self.sphere_cull_descriptor_layout = 0
  }
  self.shadow_cull_layout = gpu.create_pipeline_layout(
    gctx,
    vk.PushConstantRange {
      stageFlags = {.COMPUTE},
      size = size_of(VisibilityPushConstants),
    },
    self.shadow_cull_descriptor_layout,
  ) or_return
  defer if ret != .SUCCESS {
    vk.DestroyPipelineLayout(gctx.device, self.shadow_cull_layout, nil)
    self.shadow_cull_layout = 0
  }
  self.sphere_cull_layout = gpu.create_pipeline_layout(
    gctx,
    vk.PushConstantRange {
      stageFlags = {.COMPUTE},
      size = size_of(SphereVisibilityPushConstants),
    },
    self.sphere_cull_descriptor_layout,
  ) or_return
  defer if ret != .SUCCESS {
    vk.DestroyPipelineLayout(gctx.device, self.sphere_cull_layout, nil)
    self.sphere_cull_layout = 0
  }
  shadow_cull_shader := gpu.create_shader_module(
    gctx.device,
    SHADER_SHADOW_CULLING,
  ) or_return
  defer vk.DestroyShaderModule(gctx.device, shadow_cull_shader, nil)
  sphere_cull_shader := gpu.create_shader_module(
    gctx.device,
    SHADER_SPHERE_CULLING,
  ) or_return
  defer vk.DestroyShaderModule(gctx.device, sphere_cull_shader, nil)
  self.shadow_cull_pipeline = gpu.create_compute_pipeline(
    gctx,
    shadow_cull_shader,
    self.shadow_cull_layout,
  ) or_return
  defer if ret != .SUCCESS {
    vk.DestroyPipeline(gctx.device, self.shadow_cull_pipeline, nil)
    self.shadow_cull_pipeline = 0
  }
  self.sphere_cull_pipeline = gpu.create_compute_pipeline(
    gctx,
    sphere_cull_shader,
    self.sphere_cull_layout,
  ) or_return
  defer if ret != .SUCCESS {
    vk.DestroyPipeline(gctx.device, self.sphere_cull_pipeline, nil)
    self.sphere_cull_pipeline = 0
  }
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
  self.sphere_depth_pipeline_layout = gpu.create_pipeline_layout(
    gctx,
    vk.PushConstantRange {
      stageFlags = {.VERTEX, .GEOMETRY, .FRAGMENT},
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
    vk.DestroyPipelineLayout(
      gctx.device,
      self.sphere_depth_pipeline_layout,
      nil,
    )
    self.sphere_depth_pipeline_layout = 0
  }
  shadow_vert_shader := gpu.create_shader_module(
    gctx.device,
    SHADER_SHADOW_DEPTH_VERT,
  ) or_return
  defer vk.DestroyShaderModule(gctx.device, shadow_vert_shader, nil)
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
  shadow_stages := gpu.create_vert_stage(shadow_vert_shader)
  shadow_info := vk.GraphicsPipelineCreateInfo {
    sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
    pNext               = &gpu.DEPTH_ONLY_RENDERING_INFO,
    stageCount          = len(shadow_stages),
    pStages             = raw_data(shadow_stages[:]),
    pVertexInputState   = &vertex_input_info,
    pInputAssemblyState = &gpu.STANDARD_INPUT_ASSEMBLY,
    pViewportState      = &gpu.STANDARD_VIEWPORT_STATE,
    pRasterizationState = &gpu.STANDARD_RASTERIZER,
    pMultisampleState   = &gpu.STANDARD_MULTISAMPLING,
    pDepthStencilState  = &gpu.READ_WRITE_DEPTH_STATE,
    pDynamicState       = &gpu.STANDARD_DYNAMIC_STATES,
    layout              = self.depth_pipeline_layout,
  }
  vk.CreateGraphicsPipelines(
    gctx.device,
    0,
    1,
    &shadow_info,
    nil,
    &self.depth_pipeline,
  ) or_return
  defer if ret != .SUCCESS {
    vk.DestroyPipeline(gctx.device, self.depth_pipeline, nil)
    self.depth_pipeline = 0
  }
  sphere_vert_shader := gpu.create_shader_module(
    gctx.device,
    SHADER_SPHERE_DEPTH_VERT,
  ) or_return
  defer vk.DestroyShaderModule(gctx.device, sphere_vert_shader, nil)
  sphere_geom_shader := gpu.create_shader_module(
    gctx.device,
    SHADER_SPHERE_DEPTH_GEOM,
  ) or_return
  defer vk.DestroyShaderModule(gctx.device, sphere_geom_shader, nil)
  sphere_frag_shader := gpu.create_shader_module(
    gctx.device,
    SHADER_SPHERE_DEPTH_FRAG,
  ) or_return
  defer vk.DestroyShaderModule(gctx.device, sphere_frag_shader, nil)
  sphere_stages := gpu.create_vert_geo_frag_stages(
    sphere_vert_shader,
    sphere_geom_shader,
    sphere_frag_shader,
  )
  sphere_info := vk.GraphicsPipelineCreateInfo {
    sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
    pNext               = &gpu.DEPTH_ONLY_RENDERING_INFO,
    stageCount          = len(sphere_stages),
    pStages             = raw_data(sphere_stages[:]),
    pVertexInputState   = &vertex_input_info,
    pInputAssemblyState = &gpu.STANDARD_INPUT_ASSEMBLY,
    pViewportState      = &gpu.STANDARD_VIEWPORT_STATE,
    pRasterizationState = &gpu.STANDARD_RASTERIZER,
    pMultisampleState   = &gpu.STANDARD_MULTISAMPLING,
    pDepthStencilState  = &gpu.READ_WRITE_DEPTH_STATE,
    pDynamicState       = &gpu.STANDARD_DYNAMIC_STATES,
    layout              = self.sphere_depth_pipeline_layout,
  }
  vk.CreateGraphicsPipelines(
    gctx.device,
    0,
    1,
    &sphere_info,
    nil,
    &self.sphere_depth_pipeline,
  ) or_return
  defer if ret != .SUCCESS {
    vk.DestroyPipeline(gctx.device, self.sphere_depth_pipeline, nil)
    self.sphere_depth_pipeline = 0
  }
  return .SUCCESS
}

// shadow_setup_slot allocates GPU resources for a SINGLE shadow slot.
// Call this once per shadow-casting light.
// NOTE: Allocates resources for ALL three light types (spot, directional, point)
// to maintain compatibility with existing code, even though only one type is used per slot.
shadow_setup_slot :: proc(
  self: ^ShadowSystem,
  shadow_data_buffer: ^gpu.PerFrameBindlessBuffer(ShadowData, d.FRAMES_IN_FLIGHT),
  slot: u32,
  spot_light: ^light.SpotLight,
  directional_light: ^light.DirectionalLight,
  point_light: ^light.PointLight,
  gctx: ^gpu.GPUContext,
  texture_manager: ^gpu.TextureManager,
  node_data_buffer: ^gpu.BindlessBuffer(d.Node),
  mesh_data_buffer: ^gpu.BindlessBuffer(d.Mesh),
) -> (
  ret: vk.Result,
) {
  if slot >= MAX_SHADOW_MAPS do return .ERROR_UNKNOWN

  spot := spot_light
  directional := directional_light
  point := point_light

  for frame in 0 ..< d.FRAMES_IN_FLIGHT {
    // Allocate spot light resources
    spot.shadow_map[frame] = gpu.allocate_texture_2d(
      texture_manager,
      gctx,
      vk.Extent2D{SHADOW_MAP_SIZE, SHADOW_MAP_SIZE},
      .D32_SFLOAT,
      {.DEPTH_STENCIL_ATTACHMENT, .SAMPLED},
    ) or_return
    spot.draw_count[frame] = gpu.create_mutable_buffer(
      gctx,
      u32,
      1,
      {.STORAGE_BUFFER, .INDIRECT_BUFFER},
    ) or_return
    spot.draw_commands[frame] = gpu.create_mutable_buffer(
      gctx,
      vk.DrawIndexedIndirectCommand,
      d.MAX_NODES_IN_SCENE,
      {.STORAGE_BUFFER, .INDIRECT_BUFFER},
    ) or_return
    spot.descriptor_sets[frame] = gpu.create_descriptor_set(
      gctx,
      &self.shadow_cull_descriptor_layout,
      {.STORAGE_BUFFER, gpu.buffer_info(&node_data_buffer.buffer)},
      {.STORAGE_BUFFER, gpu.buffer_info(&mesh_data_buffer.buffer)},
      {
        .STORAGE_BUFFER,
        gpu.buffer_info(&shadow_data_buffer.buffers[frame]),
      },
      {.STORAGE_BUFFER, gpu.buffer_info(&spot.draw_count[frame])},
      {.STORAGE_BUFFER, gpu.buffer_info(&spot.draw_commands[frame])},
    ) or_return

    // Allocate directional light resources
    directional.shadow_map[frame] = gpu.allocate_texture_2d(
      texture_manager,
      gctx,
      vk.Extent2D{SHADOW_MAP_SIZE, SHADOW_MAP_SIZE},
      .D32_SFLOAT,
      {.DEPTH_STENCIL_ATTACHMENT, .SAMPLED},
    ) or_return
    directional.draw_count[frame] = gpu.create_mutable_buffer(
      gctx,
      u32,
      1,
      {.STORAGE_BUFFER, .INDIRECT_BUFFER},
    ) or_return
    directional.draw_commands[frame] = gpu.create_mutable_buffer(
      gctx,
      vk.DrawIndexedIndirectCommand,
      d.MAX_NODES_IN_SCENE,
      {.STORAGE_BUFFER, .INDIRECT_BUFFER},
    ) or_return
    directional.descriptor_sets[frame] = gpu.create_descriptor_set(
      gctx,
      &self.shadow_cull_descriptor_layout,
      {.STORAGE_BUFFER, gpu.buffer_info(&node_data_buffer.buffer)},
      {.STORAGE_BUFFER, gpu.buffer_info(&mesh_data_buffer.buffer)},
      {
        .STORAGE_BUFFER,
        gpu.buffer_info(&shadow_data_buffer.buffers[frame]),
      },
      {.STORAGE_BUFFER, gpu.buffer_info(&directional.draw_count[frame])},
      {.STORAGE_BUFFER, gpu.buffer_info(&directional.draw_commands[frame])},
    ) or_return

    // Allocate point light resources
    point.shadow_cube[frame] = gpu.allocate_texture_cube(
      texture_manager,
      gctx,
      SHADOW_MAP_SIZE,
      .D32_SFLOAT,
      {.DEPTH_STENCIL_ATTACHMENT, .SAMPLED},
    ) or_return
    point.draw_count[frame] = gpu.create_mutable_buffer(
      gctx,
      u32,
      1,
      {.STORAGE_BUFFER, .INDIRECT_BUFFER},
    ) or_return
    point.draw_commands[frame] = gpu.create_mutable_buffer(
      gctx,
      vk.DrawIndexedIndirectCommand,
      d.MAX_NODES_IN_SCENE,
      {.STORAGE_BUFFER, .INDIRECT_BUFFER},
    ) or_return
    point.descriptor_sets[frame] = gpu.create_descriptor_set(
      gctx,
      &self.sphere_cull_descriptor_layout,
      {.STORAGE_BUFFER, gpu.buffer_info(&node_data_buffer.buffer)},
      {.STORAGE_BUFFER, gpu.buffer_info(&mesh_data_buffer.buffer)},
      {
        .STORAGE_BUFFER,
        gpu.buffer_info(&shadow_data_buffer.buffers[frame]),
      },
      {.STORAGE_BUFFER, gpu.buffer_info(&point.draw_count[frame])},
      {.STORAGE_BUFFER, gpu.buffer_info(&point.draw_commands[frame])},
    ) or_return
  }

  return .SUCCESS
}

// shadow_teardown_slot destroys GPU resources for a SINGLE shadow slot.
// Call this once per shadow-casting light that needs cleanup.
// NOTE: Destroys resources for ALL three light types to match shadow_setup_slot behavior.
shadow_teardown_slot :: proc(
  self: ^ShadowSystem,
  slot: u32,
  spot_light: ^light.SpotLight,
  directional_light: ^light.DirectionalLight,
  point_light: ^light.PointLight,
  gctx: ^gpu.GPUContext,
  texture_manager: ^gpu.TextureManager,
) {
  if slot >= MAX_SHADOW_MAPS do return

  spot := spot_light
  directional := directional_light
  point := point_light

  for frame in 0 ..< d.FRAMES_IN_FLIGHT {
    // Teardown spot light resources
    gpu.free_texture_2d(texture_manager, gctx, spot.shadow_map[frame])
    spot.shadow_map[frame] = {}
    gpu.mutable_buffer_destroy(gctx.device, &spot.draw_count[frame])
    gpu.mutable_buffer_destroy(gctx.device, &spot.draw_commands[frame])
    spot.descriptor_sets[frame] = 0

    // Teardown directional light resources
    gpu.free_texture_2d(texture_manager, gctx, directional.shadow_map[frame])
    directional.shadow_map[frame] = {}
    gpu.mutable_buffer_destroy(gctx.device, &directional.draw_count[frame])
    gpu.mutable_buffer_destroy(gctx.device, &directional.draw_commands[frame])
    directional.descriptor_sets[frame] = 0

    // Teardown point light resources
    gpu.free_texture_cube(texture_manager, gctx, point.shadow_cube[frame])
    point.shadow_cube[frame] = {}
    gpu.mutable_buffer_destroy(gctx.device, &point.draw_count[frame])
    gpu.mutable_buffer_destroy(gctx.device, &point.draw_commands[frame])
    point.descriptor_sets[frame] = 0
  }
}

// shadow_setup_buffers allocates global shadow data buffer descriptors.
// Call this once during render manager setup.
shadow_setup_buffers :: proc(
  shadow_data_buffer: ^gpu.PerFrameBindlessBuffer(ShadowData, d.FRAMES_IN_FLIGHT),
  gctx: ^gpu.GPUContext,
) -> vk.Result {
  return gpu.per_frame_bindless_buffer_realloc_descriptors(shadow_data_buffer, gctx)
}

shadow_shutdown :: proc(
  self: ^ShadowSystem,
  gctx: ^gpu.GPUContext,
) {
  vk.DestroyPipeline(gctx.device, self.sphere_depth_pipeline, nil)
  vk.DestroyPipeline(gctx.device, self.depth_pipeline, nil)
  vk.DestroyPipeline(gctx.device, self.sphere_cull_pipeline, nil)
  vk.DestroyPipeline(gctx.device, self.shadow_cull_pipeline, nil)
  vk.DestroyPipelineLayout(gctx.device, self.sphere_depth_pipeline_layout, nil)
  vk.DestroyPipelineLayout(gctx.device, self.depth_pipeline_layout, nil)
  vk.DestroyPipelineLayout(gctx.device, self.sphere_cull_layout, nil)
  vk.DestroyPipelineLayout(gctx.device, self.shadow_cull_layout, nil)
  vk.DestroyDescriptorSetLayout(
    gctx.device,
    self.sphere_cull_descriptor_layout,
    nil,
  )
  vk.DestroyDescriptorSetLayout(
    gctx.device,
    self.shadow_cull_descriptor_layout,
    nil,
  )
}

shadow_sync_lights :: proc(
  slot_active: ^[MAX_SHADOW_MAPS]bool,
  slot_kind: ^[MAX_SHADOW_MAPS]d.LightType,
  light_to_slot: ^[d.MAX_LIGHTS]u32,
  shadow_data_buffer: ^gpu.PerFrameBindlessBuffer(ShadowData, d.FRAMES_IN_FLIGHT),
  lights_buffer: ^gpu.BindlessBuffer(d.Light),
  active_lights: []d.LightHandle,
  frame_index: u32,
) {
  for i in 0 ..< MAX_SHADOW_MAPS {
    slot_active[i] = false
  }
  for i in 0 ..< d.MAX_LIGHTS {
    light_to_slot[i] = INVALID_SHADOW_INDEX
  }
  zero_shadow: ShadowData
  for slot in 0 ..< MAX_SHADOW_MAPS {
    gpu.write(
      &shadow_data_buffer.buffers[frame_index],
      &zero_shadow,
      int(slot),
    )
  }
  next_slot: u32 = 0
  for handle in active_lights {
    light := gpu.get(&lights_buffer.buffer, handle.index)
    position := light.position.xyz
    direction := safe_normalize(light.direction.xyz, {0, -1, 0})
    if !light.cast_shadow || next_slot >= MAX_SHADOW_MAPS {
      light.shadow_index = INVALID_SHADOW_INDEX
      gpu.write(&lights_buffer.buffer, light, int(handle.index))
      continue
    }
    slot := next_slot
    next_slot += 1
    slot_active[slot] = true
    slot_kind[slot] = light.type
    light_to_slot[handle.index] = slot
    light.shadow_index = slot
    gpu.write(&lights_buffer.buffer, light, int(handle.index))
    shadow_data := ShadowData {
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
    gpu.write(
      &shadow_data_buffer.buffers[frame_index],
      &shadow_data,
      int(slot),
    )
  }
}

shadow_invalidate_light :: proc(
  slot_active: ^[MAX_SHADOW_MAPS]bool,
  light_to_slot: ^[d.MAX_LIGHTS]u32,
  light_index: u32,
) {
  if light_index >= d.MAX_LIGHTS do return
  slot := light_to_slot[light_index]
  if slot == INVALID_SHADOW_INDEX do return
  slot_active[slot] = false
  light_to_slot[light_index] = INVALID_SHADOW_INDEX
}

shadow_compute_draw_list :: proc(
  self: ^ShadowSystem,
  command_buffer: vk.CommandBuffer,
  slot: u32,
  light_type: d.LightType,
  descriptor_set: vk.DescriptorSet,
  draw_count_buffer: vk.Buffer,
  draw_count_size: vk.DeviceSize,
) {
  if slot >= MAX_SHADOW_MAPS do return
  include_flags: d.NodeFlagSet = {.VISIBLE}
  exclude_flags: d.NodeFlagSet = {
    .MATERIAL_TRANSPARENT,
    .MATERIAL_WIREFRAME,
    .MATERIAL_RANDOM_COLOR,
    .MATERIAL_LINE_STRIP,
  }
  vk.CmdFillBuffer(
    command_buffer,
    draw_count_buffer,
    0,
    draw_count_size,
    0,
  )
  gpu.buffer_barrier(
    command_buffer,
    draw_count_buffer,
    draw_count_size,
    {.TRANSFER_WRITE},
    {.SHADER_READ, .SHADER_WRITE},
    {.TRANSFER},
    {.COMPUTE_SHADER},
  )
  switch light_type {
  case .SPOT, .DIRECTIONAL:
    gpu.bind_compute_pipeline(
      command_buffer,
      self.shadow_cull_pipeline,
      self.shadow_cull_layout,
      descriptor_set,
    )
    push := VisibilityPushConstants {
      camera_index  = slot,
      node_count    = self.node_count,
      max_draws     = self.max_draws,
      include_flags = include_flags,
      exclude_flags = exclude_flags,
    }
    vk.CmdPushConstants(
      command_buffer,
      self.shadow_cull_layout,
      {.COMPUTE},
      0,
      size_of(push),
      &push,
    )
  case .POINT:
    gpu.bind_compute_pipeline(
      command_buffer,
      self.sphere_cull_pipeline,
      self.sphere_cull_layout,
      descriptor_set,
    )
    push := SphereVisibilityPushConstants {
      camera_index  = slot,
      node_count    = self.node_count,
      max_draws     = self.max_draws,
      include_flags = include_flags,
      exclude_flags = exclude_flags,
    }
    vk.CmdPushConstants(
      command_buffer,
      self.sphere_cull_layout,
      {.COMPUTE},
      0,
      size_of(push),
      &push,
    )
  }
  dispatch_x := (self.node_count + 63) / 64
  vk.CmdDispatch(command_buffer, dispatch_x, 1, 1)
}

shadow_render_depth_slot :: proc(
  self: ^ShadowSystem,
  command_buffer: vk.CommandBuffer,
  texture_manager: ^gpu.TextureManager,
  shadow_data_descriptor_set: vk.DescriptorSet,
  textures_descriptor_set: vk.DescriptorSet,
  bone_descriptor_set: vk.DescriptorSet,
  material_descriptor_set: vk.DescriptorSet,
  node_data_descriptor_set: vk.DescriptorSet,
  mesh_data_descriptor_set: vk.DescriptorSet,
  vertex_skinning_descriptor_set: vk.DescriptorSet,
  vertex_buffer: vk.Buffer,
  index_buffer: vk.Buffer,
  slot: u32,
  light_type: d.LightType,
  draw_commands_buffer: vk.Buffer,
  draw_count_buffer: vk.Buffer,
  shadow_map_2d: gpu.Texture2DHandle,
  shadow_map_cube: gpu.TextureCubeHandle,
) {
  if slot >= MAX_SHADOW_MAPS do return
  switch light_type {
  case .SPOT:
    depth_texture := gpu.get_texture_2d(texture_manager, shadow_map_2d)
    if depth_texture == nil do return
    depth_attachment := gpu.create_depth_attachment(
      depth_texture,
      .CLEAR,
      .STORE,
    )
    gpu.begin_depth_rendering(
      command_buffer,
      vk.Extent2D{SHADOW_MAP_SIZE, SHADOW_MAP_SIZE},
      &depth_attachment,
    )
    gpu.set_viewport_scissor(
      command_buffer,
      vk.Extent2D{SHADOW_MAP_SIZE, SHADOW_MAP_SIZE},
    )
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
    cam_idx := slot
    vk.CmdPushConstants(
      command_buffer,
      self.depth_pipeline_layout,
      {.VERTEX, .FRAGMENT},
      0,
      size_of(u32),
      &cam_idx,
    )
    gpu.bind_vertex_index_buffers(
      command_buffer,
      vertex_buffer,
      index_buffer,
    )
    vk.CmdDrawIndexedIndirectCount(
      command_buffer,
      draw_commands_buffer,
      0,
      draw_count_buffer,
      0,
      self.max_draws,
      u32(size_of(vk.DrawIndexedIndirectCommand)),
    )
    vk.CmdEndRendering(command_buffer)
  case .DIRECTIONAL:
    depth_texture := gpu.get_texture_2d(texture_manager, shadow_map_2d)
    if depth_texture == nil do return
    depth_attachment := gpu.create_depth_attachment(
      depth_texture,
      .CLEAR,
      .STORE,
    )
    gpu.begin_depth_rendering(
      command_buffer,
      vk.Extent2D{SHADOW_MAP_SIZE, SHADOW_MAP_SIZE},
      &depth_attachment,
    )
    gpu.set_viewport_scissor(
      command_buffer,
      vk.Extent2D{SHADOW_MAP_SIZE, SHADOW_MAP_SIZE},
    )
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
    cam_idx := slot
    vk.CmdPushConstants(
      command_buffer,
      self.depth_pipeline_layout,
      {.VERTEX, .FRAGMENT},
      0,
      size_of(u32),
      &cam_idx,
    )
    gpu.bind_vertex_index_buffers(
      command_buffer,
      vertex_buffer,
      index_buffer,
    )
    vk.CmdDrawIndexedIndirectCount(
      command_buffer,
      draw_commands_buffer,
      0,
      draw_count_buffer,
      0,
      self.max_draws,
      u32(size_of(vk.DrawIndexedIndirectCommand)),
    )
    vk.CmdEndRendering(command_buffer)
  case .POINT:
    depth_cube := gpu.get_texture_cube(texture_manager, shadow_map_cube)
    if depth_cube == nil do return
    depth_attachment := gpu.create_cube_depth_attachment(
      depth_cube,
      .CLEAR,
      .STORE,
    )
    gpu.begin_depth_rendering(
      command_buffer,
      vk.Extent2D{SHADOW_MAP_SIZE, SHADOW_MAP_SIZE},
      &depth_attachment,
      layer_count = 6,
    )
    gpu.set_viewport_scissor(
      command_buffer,
      vk.Extent2D{SHADOW_MAP_SIZE, SHADOW_MAP_SIZE},
      flip_x = true,
      flip_y = false,
    )
    gpu.bind_graphics_pipeline(
      command_buffer,
      self.sphere_depth_pipeline,
      self.sphere_depth_pipeline_layout,
      shadow_data_descriptor_set,
      textures_descriptor_set,
      bone_descriptor_set,
      material_descriptor_set,
      node_data_descriptor_set,
      mesh_data_descriptor_set,
      vertex_skinning_descriptor_set,
    )
    cam_idx := slot
    vk.CmdPushConstants(
      command_buffer,
      self.sphere_depth_pipeline_layout,
      {.VERTEX, .GEOMETRY, .FRAGMENT},
      0,
      size_of(u32),
      &cam_idx,
    )
    gpu.bind_vertex_index_buffers(
      command_buffer,
      vertex_buffer,
      index_buffer,
    )
    vk.CmdDrawIndexedIndirectCount(
      command_buffer,
      draw_commands_buffer,
      0,
      draw_count_buffer,
      0,
      self.max_draws,
      u32(size_of(vk.DrawIndexedIndirectCommand)),
    )
    vk.CmdEndRendering(command_buffer)
  }
}

shadow_get_texture_index :: proc(
  light_type: d.LightType,
  spot_shadow_map: gpu.Texture2DHandle,
  directional_shadow_map: gpu.Texture2DHandle,
  point_shadow_cube: gpu.TextureCubeHandle,
) -> u32 {
  switch light_type {
  case .SPOT:
    return spot_shadow_map.index
  case .DIRECTIONAL:
    return directional_shadow_map.index
  case .POINT:
    return point_shadow_cube.index
  }
  return INVALID_SHADOW_INDEX
}

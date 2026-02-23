package shadow

import "../../geometry"
import "../../gpu"
import d "../data"
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

SpotLightGPU :: struct {
  shadow_map:      [d.FRAMES_IN_FLIGHT]gpu.Texture2DHandle,
  draw_commands:   [d.FRAMES_IN_FLIGHT]gpu.MutableBuffer(vk.DrawIndexedIndirectCommand),
  draw_count:      [d.FRAMES_IN_FLIGHT]gpu.MutableBuffer(u32),
  descriptor_sets: [d.FRAMES_IN_FLIGHT]vk.DescriptorSet,
}

DirectionalLightGPU :: struct {
  radius:          f32,
  projection:      matrix[4, 4]f32,
  view:            matrix[4, 4]f32,
  position:        [4]f32,
  direction:       [4]f32,
  near_far:        [2]f32,
  shadow_map:      [d.FRAMES_IN_FLIGHT]gpu.Texture2DHandle,
  draw_commands:   [d.FRAMES_IN_FLIGHT]gpu.MutableBuffer(vk.DrawIndexedIndirectCommand),
  draw_count:      [d.FRAMES_IN_FLIGHT]gpu.MutableBuffer(u32),
  descriptor_sets: [d.FRAMES_IN_FLIGHT]vk.DescriptorSet,
}

PointLightGPU :: struct {
  shadow_cube:     [d.FRAMES_IN_FLIGHT]gpu.TextureCubeHandle,
  draw_commands:   [d.FRAMES_IN_FLIGHT]gpu.MutableBuffer(vk.DrawIndexedIndirectCommand),
  draw_count:      [d.FRAMES_IN_FLIGHT]gpu.MutableBuffer(u32),
  descriptor_sets: [d.FRAMES_IN_FLIGHT]vk.DescriptorSet,
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
  shadow_data_buffer:            gpu.PerFrameBindlessBuffer(
    ShadowData,
    d.FRAMES_IN_FLIGHT,
  ),
  spot_lights:                   [MAX_SHADOW_MAPS]SpotLightGPU,
  directional_lights:            [MAX_SHADOW_MAPS]DirectionalLightGPU,
  point_lights:                  [MAX_SHADOW_MAPS]PointLightGPU,
  slot_active:                   [MAX_SHADOW_MAPS]bool,
  slot_kind:                     [MAX_SHADOW_MAPS]d.LightType,
  light_to_slot:                 [d.MAX_LIGHTS]u32,
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

init :: proc(
  self: ^ShadowSystem,
  gctx: ^gpu.GPUContext,
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
  for i in 0 ..< d.MAX_LIGHTS {
    self.light_to_slot[i] = INVALID_SHADOW_INDEX
  }
  // Initialize buffer + set_layout only (no descriptor sets yet — allocated in shadow_setup)
  gpu.per_frame_bindless_buffer_init(
    &self.shadow_data_buffer,
    gctx,
    MAX_SHADOW_MAPS,
    {.VERTEX, .FRAGMENT, .GEOMETRY, .COMPUTE},
  ) or_return
  defer if ret != .SUCCESS {
    gpu.per_frame_bindless_buffer_destroy(
      &self.shadow_data_buffer,
      gctx.device,
    )
  }
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
    self.shadow_data_buffer.set_layout,
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
    self.shadow_data_buffer.set_layout,
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

setup :: proc(
  self: ^ShadowSystem,
  gctx: ^gpu.GPUContext,
  texture_manager: ^gpu.TextureManager,
  node_data_buffer: ^gpu.BindlessBuffer(d.Node),
  mesh_data_buffer: ^gpu.BindlessBuffer(d.Mesh),
) -> (
  ret: vk.Result,
) {
  // Buffers + set_layouts created in shadow_init; just re-allocate descriptor sets here
  gpu.per_frame_bindless_buffer_realloc_descriptors(
    &self.shadow_data_buffer,
    gctx,
  ) or_return
  for slot in 0 ..< MAX_SHADOW_MAPS {
    spot := &self.spot_lights[slot]
    directional := &self.directional_lights[slot]
    point := &self.point_lights[slot]
    for frame in 0 ..< d.FRAMES_IN_FLIGHT {
      spot.shadow_map[frame] = gpu.allocate_texture_2d(
        texture_manager,
        gctx,
        vk.Extent2D{SHADOW_MAP_SIZE, SHADOW_MAP_SIZE},
        .D32_SFLOAT,
        {.DEPTH_STENCIL_ATTACHMENT, .SAMPLED},
      ) or_return
      directional.shadow_map[frame] = gpu.allocate_texture_2d(
        texture_manager,
        gctx,
        vk.Extent2D{SHADOW_MAP_SIZE, SHADOW_MAP_SIZE},
        .D32_SFLOAT,
        {.DEPTH_STENCIL_ATTACHMENT, .SAMPLED},
      ) or_return
      point.shadow_cube[frame] = gpu.allocate_texture_cube(
        texture_manager,
        gctx,
        SHADOW_MAP_SIZE,
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
      spot.descriptor_sets[frame] = gpu.create_descriptor_set(
        gctx,
        &self.shadow_cull_descriptor_layout,
        {.STORAGE_BUFFER, gpu.buffer_info(&node_data_buffer.buffer)},
        {.STORAGE_BUFFER, gpu.buffer_info(&mesh_data_buffer.buffer)},
        {
          .STORAGE_BUFFER,
          gpu.buffer_info(&self.shadow_data_buffer.buffers[frame]),
        },
        {.STORAGE_BUFFER, gpu.buffer_info(&spot.draw_count[frame])},
        {.STORAGE_BUFFER, gpu.buffer_info(&spot.draw_commands[frame])},
      ) or_return
      directional.descriptor_sets[frame] = gpu.create_descriptor_set(
        gctx,
        &self.shadow_cull_descriptor_layout,
        {.STORAGE_BUFFER, gpu.buffer_info(&node_data_buffer.buffer)},
        {.STORAGE_BUFFER, gpu.buffer_info(&mesh_data_buffer.buffer)},
        {
          .STORAGE_BUFFER,
          gpu.buffer_info(&self.shadow_data_buffer.buffers[frame]),
        },
        {.STORAGE_BUFFER, gpu.buffer_info(&directional.draw_count[frame])},
        {.STORAGE_BUFFER, gpu.buffer_info(&directional.draw_commands[frame])},
      ) or_return
      point.descriptor_sets[frame] = gpu.create_descriptor_set(
        gctx,
        &self.sphere_cull_descriptor_layout,
        {.STORAGE_BUFFER, gpu.buffer_info(&node_data_buffer.buffer)},
        {.STORAGE_BUFFER, gpu.buffer_info(&mesh_data_buffer.buffer)},
        {
          .STORAGE_BUFFER,
          gpu.buffer_info(&self.shadow_data_buffer.buffers[frame]),
        },
        {.STORAGE_BUFFER, gpu.buffer_info(&point.draw_count[frame])},
        {.STORAGE_BUFFER, gpu.buffer_info(&point.draw_commands[frame])},
      ) or_return
    }
  }
  return .SUCCESS
}

teardown :: proc(
  self: ^ShadowSystem,
  gctx: ^gpu.GPUContext,
  texture_manager: ^gpu.TextureManager,
) {
  for slot in 0 ..< MAX_SHADOW_MAPS {
    spot := &self.spot_lights[slot]
    directional := &self.directional_lights[slot]
    point := &self.point_lights[slot]
    for frame in 0 ..< d.FRAMES_IN_FLIGHT {
      gpu.free_texture_2d(texture_manager, gctx, spot.shadow_map[frame])
      spot.shadow_map[frame] = {}
      gpu.free_texture_2d(texture_manager, gctx, directional.shadow_map[frame])
      directional.shadow_map[frame] = {}
      gpu.free_texture_cube(texture_manager, gctx, point.shadow_cube[frame])
      point.shadow_cube[frame] = {}
      gpu.mutable_buffer_destroy(gctx.device, &spot.draw_count[frame])
      gpu.mutable_buffer_destroy(gctx.device, &spot.draw_commands[frame])
      gpu.mutable_buffer_destroy(gctx.device, &directional.draw_count[frame])
      gpu.mutable_buffer_destroy(
        gctx.device,
        &directional.draw_commands[frame],
      )
      gpu.mutable_buffer_destroy(gctx.device, &point.draw_count[frame])
      gpu.mutable_buffer_destroy(gctx.device, &point.draw_commands[frame])
      spot.descriptor_sets[frame] = 0
      directional.descriptor_sets[frame] = 0
      point.descriptor_sets[frame] = 0
    }
  }
  // Zero shadow buffer descriptor sets; buffers+set_layouts persist until shadow_shutdown
  for &ds in self.shadow_data_buffer.descriptor_sets do ds = 0
}

shutdown :: proc(self: ^ShadowSystem, gctx: ^gpu.GPUContext) {
  gpu.per_frame_bindless_buffer_destroy(&self.shadow_data_buffer, gctx.device)
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

sync_lights :: proc(
  self: ^ShadowSystem,
  lights_buffer: ^gpu.BindlessBuffer(d.Light),
  active_lights: []d.LightHandle,
  frame_index: u32,
) {
  for i in 0 ..< MAX_SHADOW_MAPS {
    self.slot_active[i] = false
  }
  for i in 0 ..< d.MAX_LIGHTS {
    self.light_to_slot[i] = INVALID_SHADOW_INDEX
  }
  zero_shadow: ShadowData
  for slot in 0 ..< MAX_SHADOW_MAPS {
    gpu.write(
      &self.shadow_data_buffer.buffers[frame_index],
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
    self.slot_active[slot] = true
    self.slot_kind[slot] = light.type
    self.light_to_slot[handle.index] = slot
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
      &self.shadow_data_buffer.buffers[frame_index],
      &shadow_data,
      int(slot),
    )
  }
}

invalidate_light :: proc(self: ^ShadowSystem, light_index: u32) {
  if light_index >= d.MAX_LIGHTS do return
  slot := self.light_to_slot[light_index]
  if slot == INVALID_SHADOW_INDEX do return
  self.slot_active[slot] = false
  self.light_to_slot[light_index] = INVALID_SHADOW_INDEX
}

compute_draw_lists :: proc(
  self: ^ShadowSystem,
  command_buffer: vk.CommandBuffer,
  frame_index: u32,
) {
  include_flags: d.NodeFlagSet = {.VISIBLE}
  exclude_flags: d.NodeFlagSet = {
    .MATERIAL_TRANSPARENT,
    .MATERIAL_WIREFRAME,
    .MATERIAL_RANDOM_COLOR,
    .MATERIAL_LINE_STRIP,
  }
  for slot in 0 ..< MAX_SHADOW_MAPS {
    if !self.slot_active[slot] do continue
    kind := self.slot_kind[slot]
    switch kind {
    case .SPOT:
      spot := &self.spot_lights[slot]
      vk.CmdFillBuffer(
        command_buffer,
        spot.draw_count[frame_index].buffer,
        0,
        vk.DeviceSize(spot.draw_count[frame_index].bytes_count),
        0,
      )
      gpu.buffer_barrier(
        command_buffer,
        spot.draw_count[frame_index].buffer,
        vk.DeviceSize(spot.draw_count[frame_index].bytes_count),
        {.TRANSFER_WRITE},
        {.SHADER_READ, .SHADER_WRITE},
        {.TRANSFER},
        {.COMPUTE_SHADER},
      )
      gpu.bind_compute_pipeline(
        command_buffer,
        self.shadow_cull_pipeline,
        self.shadow_cull_layout,
        spot.descriptor_sets[frame_index],
      )
      push := VisibilityPushConstants {
        camera_index  = u32(slot),
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
    case .DIRECTIONAL:
      directional := &self.directional_lights[slot]
      vk.CmdFillBuffer(
        command_buffer,
        directional.draw_count[frame_index].buffer,
        0,
        vk.DeviceSize(directional.draw_count[frame_index].bytes_count),
        0,
      )
      gpu.buffer_barrier(
        command_buffer,
        directional.draw_count[frame_index].buffer,
        vk.DeviceSize(directional.draw_count[frame_index].bytes_count),
        {.TRANSFER_WRITE},
        {.SHADER_READ, .SHADER_WRITE},
        {.TRANSFER},
        {.COMPUTE_SHADER},
      )
      gpu.bind_compute_pipeline(
        command_buffer,
        self.shadow_cull_pipeline,
        self.shadow_cull_layout,
        directional.descriptor_sets[frame_index],
      )
      push := VisibilityPushConstants {
        camera_index  = u32(slot),
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
      point := &self.point_lights[slot]
      vk.CmdFillBuffer(
        command_buffer,
        point.draw_count[frame_index].buffer,
        0,
        vk.DeviceSize(point.draw_count[frame_index].bytes_count),
        0,
      )
      gpu.buffer_barrier(
        command_buffer,
        point.draw_count[frame_index].buffer,
        vk.DeviceSize(point.draw_count[frame_index].bytes_count),
        {.TRANSFER_WRITE},
        {.SHADER_READ, .SHADER_WRITE},
        {.TRANSFER},
        {.COMPUTE_SHADER},
      )
      gpu.bind_compute_pipeline(
        command_buffer,
        self.sphere_cull_pipeline,
        self.sphere_cull_layout,
        point.descriptor_sets[frame_index],
      )
      push := SphereVisibilityPushConstants {
        camera_index  = u32(slot),
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
}

render_depth :: proc(
  self: ^ShadowSystem,
  command_buffer: vk.CommandBuffer,
  texture_manager: ^gpu.TextureManager,
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
  for slot in 0 ..< MAX_SHADOW_MAPS {
    if !self.slot_active[slot] do continue
    switch self.slot_kind[slot] {
    case .SPOT:
      spot := &self.spot_lights[slot]
      gpu.buffer_barrier(
        command_buffer,
        spot.draw_commands[frame_index].buffer,
        vk.DeviceSize(spot.draw_commands[frame_index].bytes_count),
        {.SHADER_WRITE},
        {.INDIRECT_COMMAND_READ},
        {.COMPUTE_SHADER},
        {.DRAW_INDIRECT},
      )
      gpu.buffer_barrier(
        command_buffer,
        spot.draw_count[frame_index].buffer,
        vk.DeviceSize(spot.draw_count[frame_index].bytes_count),
        {.SHADER_WRITE},
        {.INDIRECT_COMMAND_READ},
        {.COMPUTE_SHADER},
        {.DRAW_INDIRECT},
      )
      depth_texture := gpu.get_texture_2d(
        texture_manager,
        spot.shadow_map[frame_index],
      )
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
        self.shadow_data_buffer.descriptor_sets[frame_index],
        textures_descriptor_set,
        bone_descriptor_set,
        material_descriptor_set,
        node_data_descriptor_set,
        mesh_data_descriptor_set,
        vertex_skinning_descriptor_set,
      )
      cam_idx := u32(slot)
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
        spot.draw_commands[frame_index].buffer,
        0,
        spot.draw_count[frame_index].buffer,
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
    case .DIRECTIONAL:
      directional := &self.directional_lights[slot]
      gpu.buffer_barrier(
        command_buffer,
        directional.draw_commands[frame_index].buffer,
        vk.DeviceSize(directional.draw_commands[frame_index].bytes_count),
        {.SHADER_WRITE},
        {.INDIRECT_COMMAND_READ},
        {.COMPUTE_SHADER},
        {.DRAW_INDIRECT},
      )
      gpu.buffer_barrier(
        command_buffer,
        directional.draw_count[frame_index].buffer,
        vk.DeviceSize(directional.draw_count[frame_index].bytes_count),
        {.SHADER_WRITE},
        {.INDIRECT_COMMAND_READ},
        {.COMPUTE_SHADER},
        {.DRAW_INDIRECT},
      )
      depth_texture := gpu.get_texture_2d(
        texture_manager,
        directional.shadow_map[frame_index],
      )
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
        self.shadow_data_buffer.descriptor_sets[frame_index],
        textures_descriptor_set,
        bone_descriptor_set,
        material_descriptor_set,
        node_data_descriptor_set,
        mesh_data_descriptor_set,
        vertex_skinning_descriptor_set,
      )
      cam_idx := u32(slot)
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
        directional.draw_commands[frame_index].buffer,
        0,
        directional.draw_count[frame_index].buffer,
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
    case .POINT:
      point := &self.point_lights[slot]
      gpu.buffer_barrier(
        command_buffer,
        point.draw_commands[frame_index].buffer,
        vk.DeviceSize(point.draw_commands[frame_index].bytes_count),
        {.SHADER_WRITE},
        {.INDIRECT_COMMAND_READ},
        {.COMPUTE_SHADER},
        {.DRAW_INDIRECT},
      )
      gpu.buffer_barrier(
        command_buffer,
        point.draw_count[frame_index].buffer,
        vk.DeviceSize(point.draw_count[frame_index].bytes_count),
        {.SHADER_WRITE},
        {.INDIRECT_COMMAND_READ},
        {.COMPUTE_SHADER},
        {.DRAW_INDIRECT},
      )
      depth_cube := gpu.get_texture_cube(
        texture_manager,
        point.shadow_cube[frame_index],
      )
      if depth_cube == nil do continue
      gpu.image_barrier(
        command_buffer,
        depth_cube.image,
        .UNDEFINED,
        .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
        {},
        {.DEPTH_STENCIL_ATTACHMENT_WRITE},
        {.TOP_OF_PIPE},
        {.EARLY_FRAGMENT_TESTS},
        {.DEPTH},
        layer_count = 6,
      )
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
        self.shadow_data_buffer.descriptor_sets[frame_index],
        textures_descriptor_set,
        bone_descriptor_set,
        material_descriptor_set,
        node_data_descriptor_set,
        mesh_data_descriptor_set,
        vertex_skinning_descriptor_set,
      )
      cam_idx := u32(slot)
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
        point.draw_commands[frame_index].buffer,
        0,
        point.draw_count[frame_index].buffer,
        0,
        self.max_draws,
        u32(size_of(vk.DrawIndexedIndirectCommand)),
      )
      vk.CmdEndRendering(command_buffer)
      gpu.image_barrier(
        command_buffer,
        depth_cube.image,
        .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
        .DEPTH_STENCIL_READ_ONLY_OPTIMAL,
        {.DEPTH_STENCIL_ATTACHMENT_WRITE},
        {.SHADER_READ},
        {.LATE_FRAGMENT_TESTS},
        {.FRAGMENT_SHADER},
        {.DEPTH},
        layer_count = 6,
      )
    }
  }
}

get_texture_index :: proc(
  self: ^ShadowSystem,
  light_type: d.LightType,
  shadow_index: u32,
  frame_index: u32,
) -> u32 {
  if shadow_index == INVALID_SHADOW_INDEX || shadow_index >= MAX_SHADOW_MAPS {
    return INVALID_SHADOW_INDEX
  }
  switch light_type {
  case .SPOT:
    return self.spot_lights[shadow_index].shadow_map[frame_index].index
  case .DIRECTIONAL:
    return self.directional_lights[shadow_index].shadow_map[frame_index].index
  case .POINT:
    return self.point_lights[shadow_index].shadow_cube[frame_index].index
  }
  return INVALID_SHADOW_INDEX
}

package shadow_sphere_render

import "../../geometry"
import "../../gpu"
import d "../data"
import rg "../graph"
import vk "vendor:vulkan"

SHADER_SPHERE_DEPTH_VERT :: #load("../../shader/shadow_spherical/vert.spv")
SHADER_SPHERE_DEPTH_GEOM :: #load("../../shader/shadow_spherical/geom.spv")
SHADER_SPHERE_DEPTH_FRAG :: #load("../../shader/shadow_spherical/frag.spv")

ShadowTransform :: struct {
  view:            matrix[4, 4]f32,
  projection:      matrix[4, 4]f32,
  view_projection: matrix[4, 4]f32,
  near:            f32,
  far:             f32,
  frustum_planes:  [6][4]f32,
  position:        [3]f32,  // Light position for cubemap generation
}

ShadowDepthPushConstants :: struct {
  projection:     matrix[4, 4]f32,  // 64 bytes (aligned to 16 bytes)
  light_position: [3]f32,           // 12 bytes
  near_plane:     f32,              // 4 bytes
  far_plane:      f32,              // 4 bytes
}
// Total: 84 bytes (std140 layout)

System :: struct {
  max_draws:             u32,
  depth_pipeline_layout: vk.PipelineLayout,
  depth_pipeline:        vk.Pipeline,
}

init :: proc(
  self: ^System,
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
  self.depth_pipeline_layout = gpu.create_pipeline_layout(
    gctx,
    vk.PushConstantRange {
      stageFlags = {.VERTEX, .GEOMETRY, .FRAGMENT},
      size = size_of(ShadowDepthPushConstants),
    },
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
  vert := gpu.create_shader_module(
    gctx.device,
    SHADER_SPHERE_DEPTH_VERT,
  ) or_return
  defer vk.DestroyShaderModule(gctx.device, vert, nil)
  geom := gpu.create_shader_module(
    gctx.device,
    SHADER_SPHERE_DEPTH_GEOM,
  ) or_return
  defer vk.DestroyShaderModule(gctx.device, geom, nil)
  frag := gpu.create_shader_module(
    gctx.device,
    SHADER_SPHERE_DEPTH_FRAG,
  ) or_return
  defer vk.DestroyShaderModule(gctx.device, frag, nil)

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
  stages := gpu.create_vert_geo_frag_stages(vert, geom, frag)
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
  vk.CreateGraphicsPipelines(
    gctx.device,
    0,
    1,
    &info,
    nil,
    &self.depth_pipeline,
  ) or_return
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

render :: proc(
  self: ^System,
  command_buffer: vk.CommandBuffer,
  texture_manager: ^gpu.TextureManager,
  projection: matrix[4,4]f32,
  near, far: f32,
  position: [3]f32,
  shadow_map: gpu.TextureCubeHandle,
  draw_command: gpu.MutableBuffer(vk.DrawIndexedIndirectCommand),
  draw_count: gpu.MutableBuffer(u32),
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
  gpu.buffer_barrier(
    command_buffer,
    draw_command.buffer,
    vk.DeviceSize(draw_command.bytes_count),
    {.SHADER_WRITE},
    {.INDIRECT_COMMAND_READ},
    {.COMPUTE_SHADER},
    {.DRAW_INDIRECT},
  )
  gpu.buffer_barrier(
    command_buffer,
    draw_count.buffer,
    vk.DeviceSize(draw_count.bytes_count),
    {.SHADER_WRITE},
    {.INDIRECT_COMMAND_READ},
    {.COMPUTE_SHADER},
    {.DRAW_INDIRECT},
  )
  depth_cube := gpu.get_texture_cube(texture_manager, shadow_map)
  if depth_cube == nil do return
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
    vk.Extent2D{d.SHADOW_MAP_SIZE, d.SHADOW_MAP_SIZE},
    &depth_attachment,
    layer_count = 6,
  )
  gpu.set_viewport_scissor(
    command_buffer,
    vk.Extent2D{d.SHADOW_MAP_SIZE, d.SHADOW_MAP_SIZE},
    flip_x = true,
    flip_y = false,
  )
  gpu.bind_graphics_pipeline(
    command_buffer,
    self.depth_pipeline,
    self.depth_pipeline_layout,
    textures_descriptor_set,
    bone_descriptor_set,
    material_descriptor_set,
    node_data_descriptor_set,
    mesh_data_descriptor_set,
    vertex_skinning_descriptor_set,
  )
  push := ShadowDepthPushConstants{
    projection     = projection,
    near_plane     = near,
    far_plane      = far,
    light_position = position,
  }
  vk.CmdPushConstants(
    command_buffer,
    self.depth_pipeline_layout,
    {.VERTEX, .GEOMETRY, .FRAGMENT},
    0,
    size_of(push),
    &push,
  )
  gpu.bind_vertex_index_buffers(command_buffer, vertex_buffer, index_buffer)
  vk.CmdDrawIndexedIndirectCount(
    command_buffer,
    draw_command.buffer,
    0,
    draw_count.buffer,
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

execute_point :: proc(manager: $T, resources: ^rg.PassResources, cmd: vk.CommandBuffer, frame_index: u32)
	where type_of(manager.shadow_sphere_render) == System &&
	      type_of(manager.texture_manager) == gpu.TextureManager &&
	      type_of(manager.per_light_data) == map[u32]d.Light {
	light, ok := manager.per_light_data[resources.light_handle]
	if !ok do return
	l, is_point := light.(d.PointLight)
	if !is_point do return
	shadow, has_shadow := l.shadow.?
	if !has_shadow do return
	shadow_map_tex, found := rg.get_texture(resources, "shadow_map_cube")
	if !found do return
	render(
		&manager.shadow_sphere_render,
		cmd,
		&manager.texture_manager,
		shadow.projection,
		shadow.near,
		shadow.far,
		l.position,
		transmute(gpu.TextureCubeHandle)shadow_map_tex.handle_bits,
		shadow.draw_commands[frame_index],
		shadow.draw_count[frame_index],
		manager.texture_manager.descriptor_set,
		manager.bone_buffer.descriptor_sets[frame_index],
		manager.material_buffer.descriptor_set,
		manager.node_data_buffer.descriptor_set,
		manager.mesh_data_buffer.descriptor_set,
		manager.mesh_manager.vertex_skinning_buffer.descriptor_set,
		manager.mesh_manager.vertex_buffer.buffer,
		manager.mesh_manager.index_buffer.buffer,
		frame_index,
	)
}

declare_resources :: proc(setup: ^rg.PassSetup, builder: ^rg.PassBuilder) {
  // shadow_render_sphere only handles point lights — always creates a cube shadow map.
  shadow_draw_cmds, _ := rg.find_buffer(setup, builder, "shadow_draw_commands")
  shadow_draw_count, _ := rg.find_buffer(setup, builder, "shadow_draw_count")
  rg.reads_buffers(builder, shadow_draw_cmds, shadow_draw_count)
  shadow_map := rg.create_texture_cube(setup, builder, "shadow_map_cube", rg.TextureCubeDesc{
    width  = d.SHADOW_MAP_SIZE,
    format = .D32_SFLOAT,
    usage  = {.DEPTH_STENCIL_ATTACHMENT, .SAMPLED},
    aspect = {.DEPTH},
  })
  rg.write_texture(builder, shadow_map, .CURRENT)
}

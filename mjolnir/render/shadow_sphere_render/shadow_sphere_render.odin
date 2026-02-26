package shadow_sphere_render

import "../../geometry"
import "../../gpu"
import d "../data"
import vk "vendor:vulkan"

SHADER_SPHERE_DEPTH_VERT :: #load("../../shader/shadow_spherical/vert.spv")
SHADER_SPHERE_DEPTH_GEOM :: #load("../../shader/shadow_spherical/geom.spv")
SHADER_SPHERE_DEPTH_FRAG :: #load("../../shader/shadow_spherical/frag.spv")

System :: struct {
  max_draws:                   u32,
  depth_pipeline_layout:       vk.PipelineLayout,
  depth_pipeline:              vk.Pipeline,
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
    vk.DestroyPipelineLayout(gctx.device, self.depth_pipeline_layout, nil)
    self.depth_pipeline_layout = 0
  }
  vert := gpu.create_shader_module(gctx.device, SHADER_SPHERE_DEPTH_VERT) or_return
  defer vk.DestroyShaderModule(gctx.device, vert, nil)
  geom := gpu.create_shader_module(gctx.device, SHADER_SPHERE_DEPTH_GEOM) or_return
  defer vk.DestroyShaderModule(gctx.device, geom, nil)
  frag := gpu.create_shader_module(gctx.device, SHADER_SPHERE_DEPTH_FRAG) or_return
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

shadow_sphere_render :: proc(
  self: ^System,
  command_buffer: vk.CommandBuffer,
  texture_manager: ^gpu.TextureManager,
  slot_state: ^d.ShadowSlotState,
  point_lights: ^[d.MAX_SHADOW_MAPS]d.PointShadowGPU,
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
    if !slot_state.slot_active[slot] || slot_state.slot_kind[slot] != .POINT do continue
    gpu.buffer_barrier(
      command_buffer,
      point_lights[slot].draw_commands[frame_index].buffer,
      vk.DeviceSize(point_lights[slot].draw_commands[frame_index].bytes_count),
      {.SHADER_WRITE},
      {.INDIRECT_COMMAND_READ},
      {.COMPUTE_SHADER},
      {.DRAW_INDIRECT},
    )
    gpu.buffer_barrier(
      command_buffer,
      point_lights[slot].draw_count[frame_index].buffer,
      vk.DeviceSize(point_lights[slot].draw_count[frame_index].bytes_count),
      {.SHADER_WRITE},
      {.INDIRECT_COMMAND_READ},
      {.COMPUTE_SHADER},
      {.DRAW_INDIRECT},
    )
    depth_cube := gpu.get_texture_cube(texture_manager, point_lights[slot].shadow_cube[frame_index])
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
    depth_attachment := gpu.create_cube_depth_attachment(depth_cube, .CLEAR, .STORE)
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
      shadow_data_descriptor_set,
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
      {.VERTEX, .GEOMETRY, .FRAGMENT},
      0,
      size_of(u32),
      &cam_idx,
    )
    gpu.bind_vertex_index_buffers(command_buffer, vertex_buffer, index_buffer)
    vk.CmdDrawIndexedIndirectCount(
      command_buffer,
      point_lights[slot].draw_commands[frame_index].buffer,
      0,
      point_lights[slot].draw_count[frame_index].buffer,
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

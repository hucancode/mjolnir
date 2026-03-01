package shadow_render

import "../../geometry"
import "../../gpu"
import d "../data"
import rg "../graph"
import "core:math"
import "core:math/linalg"
import vk "vendor:vulkan"

SHADER_SHADOW_DEPTH_VERT :: #load("../../shader/shadow/vert.spv")

ShadowDepthPushConstants :: struct {
  view_projection: matrix[4, 4]f32, // 64 bytes
}

System :: struct {
  max_draws:             u32,
  depth_pipeline_layout: vk.PipelineLayout,
  depth_pipeline:        vk.Pipeline,
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
      stageFlags = {.VERTEX},
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
  shader := gpu.create_shader_module(
    gctx.device,
    SHADER_SHADOW_DEPTH_VERT,
  ) or_return
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
  view_projection: matrix[4,4]f32,
  shadow_map: gpu.Texture2DHandle,
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
  depth_texture := gpu.get_texture_2d(texture_manager, shadow_map)
  if depth_texture == nil do return
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
    vk.Extent2D{d.SHADOW_MAP_SIZE, d.SHADOW_MAP_SIZE},
    &depth_attachment,
  )
  gpu.set_viewport_scissor(
    command_buffer,
    vk.Extent2D{d.SHADOW_MAP_SIZE, d.SHADOW_MAP_SIZE},
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
    view_projection = view_projection,
  }
  vk.CmdPushConstants(
    command_buffer,
    self.depth_pipeline_layout,
    {.VERTEX},
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

declare_resources :: proc(setup: ^rg.PassSetup, is_point_light: bool) {
  shadow_draw_cmds, _ := rg.find_buffer(setup, "shadow_draw_commands")
  shadow_draw_count, _ := rg.find_buffer(setup, "shadow_draw_count")
  rg.reads_buffers(setup, shadow_draw_cmds, shadow_draw_count)
  if is_point_light {
    shadow_map := rg.create_texture(setup, "shadow_map_cube", rg.TextureDesc{
      width = d.SHADOW_MAP_SIZE, height = d.SHADOW_MAP_SIZE,
      format = .D32_SFLOAT,
      usage = {.DEPTH_STENCIL_ATTACHMENT, .SAMPLED},
      aspect = {.DEPTH},
      is_cube = true,
    })
    rg.write_texture(setup, shadow_map, .CURRENT)
  } else {
    shadow_map := rg.create_texture(setup, "shadow_map_2d", rg.TextureDesc{
      width = d.SHADOW_MAP_SIZE, height = d.SHADOW_MAP_SIZE,
      format = .D32_SFLOAT,
      usage = {.DEPTH_STENCIL_ATTACHMENT, .SAMPLED},
      aspect = {.DEPTH},
    })
    rg.write_texture(setup, shadow_map, .CURRENT)
  }
}

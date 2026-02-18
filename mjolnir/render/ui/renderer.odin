package ui_render

import "../../gpu"
import cmd "../../gpu/ui"
import "core:log"
import "core:math/linalg"
import "core:mem"
import "core:slice"
import vk "vendor:vulkan"

UI_MAX_VERTICES :: 65536
UI_MAX_INDICES :: 98304
FRAMES_IN_FLIGHT :: 2

Vertex2D :: struct {
  pos:        [2]f32,
  uv:         [2]f32,
  color:      [4]u8,
  texture_id: u32,
}

Renderer :: struct {
  pipeline_layout: vk.PipelineLayout,
  pipeline:        vk.Pipeline,
  vertex_buffers:  [FRAMES_IN_FLIGHT]gpu.MutableBuffer(Vertex2D),
  index_buffers:   [FRAMES_IN_FLIGHT]gpu.MutableBuffer(u32),
  vertices:        [UI_MAX_VERTICES]Vertex2D,
  indices:         [UI_MAX_INDICES]u32,
  vertex_count:    u32,
  index_count:     u32,
}

DrawBatch :: struct {
  first_index: u32,
  index_count: u32,
}

CommandSortKey :: struct {
  z_order:    i32,
  texture_id: u32,
  cmd_index:  int,
}

init_renderer :: proc(
  self: ^Renderer,
  gctx: ^gpu.GPUContext,
  textures_set_layout: vk.DescriptorSetLayout,
  format: vk.Format,
) -> vk.Result {
  log.info("Initializing UI renderer pipeline...")
  self.pipeline_layout = gpu.create_pipeline_layout(
    gctx,
    vk.PushConstantRange{stageFlags = {.VERTEX}, size = size_of(matrix[4, 4]f32)},
    textures_set_layout,
  ) or_return
  create_pipeline(self, gctx, format) or_return
  log.info("UI renderer pipeline initialized successfully")
  return .SUCCESS
}

setup :: proc(self: ^Renderer, gctx: ^gpu.GPUContext) -> vk.Result {
  log.info("Setting up UI renderer buffers...")
  for i in 0 ..< FRAMES_IN_FLIGHT {
    self.vertex_buffers[i] = gpu.create_mutable_buffer(
      gctx,
      Vertex2D,
      UI_MAX_VERTICES,
      {.VERTEX_BUFFER},
    ) or_return
    self.index_buffers[i] = gpu.create_mutable_buffer(
      gctx,
      u32,
      UI_MAX_INDICES,
      {.INDEX_BUFFER},
    ) or_return
  }
  log.info("UI renderer buffers set up successfully")
  return .SUCCESS
}

teardown :: proc(self: ^Renderer, gctx: ^gpu.GPUContext) {
  for i in 0 ..< FRAMES_IN_FLIGHT {
    gpu.mutable_buffer_destroy(gctx.device, &self.vertex_buffers[i])
    gpu.mutable_buffer_destroy(gctx.device, &self.index_buffers[i])
  }
}

create_pipeline :: proc(
  self: ^Renderer,
  gctx: ^gpu.GPUContext,
  format: vk.Format,
) -> vk.Result {
  vert_code := #load("../../shader/ui/vert.spv")
  frag_code := #load("../../shader/ui/frag.spv")

  vert_module := gpu.create_shader_module(gctx.device, vert_code) or_return
  defer vk.DestroyShaderModule(gctx.device, vert_module, nil)

  frag_module := gpu.create_shader_module(gctx.device, frag_code) or_return
  defer vk.DestroyShaderModule(gctx.device, frag_module, nil)

  spec_entry := vk.SpecializationMapEntry {
    constantID = 1,
    offset     = 0,
    size       = size_of(u32),
  }
  sampler_id := u32(1) // LINEAR_CLAMP
  spec_info := vk.SpecializationInfo {
    mapEntryCount = 1,
    pMapEntries   = &spec_entry,
    dataSize      = size_of(u32),
    pData         = &sampler_id,
  }

  shader_stages := [2]vk.PipelineShaderStageCreateInfo {
    {
      sType  = .PIPELINE_SHADER_STAGE_CREATE_INFO,
      stage  = {.VERTEX},
      module = vert_module,
      pName  = "main",
    },
    {
      sType               = .PIPELINE_SHADER_STAGE_CREATE_INFO,
      stage               = {.FRAGMENT},
      module              = frag_module,
      pName               = "main",
      pSpecializationInfo = &spec_info,
    },
  }

  binding_desc := vk.VertexInputBindingDescription {
    binding   = 0,
    stride    = size_of(Vertex2D),
    inputRate = .VERTEX,
  }

  attribute_descs := [4]vk.VertexInputAttributeDescription {
    {location = 0, binding = 0, format = .R32G32_SFLOAT, offset = u32(offset_of(Vertex2D, pos))},
    {location = 1, binding = 0, format = .R32G32_SFLOAT, offset = u32(offset_of(Vertex2D, uv))},
    {location = 2, binding = 0, format = .R8G8B8A8_UNORM, offset = u32(offset_of(Vertex2D, color))},
    {location = 3, binding = 0, format = .R32_UINT, offset = u32(offset_of(Vertex2D, texture_id))},
  }

  vertex_input_info := vk.PipelineVertexInputStateCreateInfo {
    sType                           = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
    vertexBindingDescriptionCount   = 1,
    pVertexBindingDescriptions      = &binding_desc,
    vertexAttributeDescriptionCount = 4,
    pVertexAttributeDescriptions    = raw_data(&attribute_descs),
  }

  input_assembly := vk.PipelineInputAssemblyStateCreateInfo {
    sType    = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
    topology = .TRIANGLE_LIST,
  }

  viewport_state := vk.PipelineViewportStateCreateInfo {
    sType         = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
    viewportCount = 1,
    scissorCount  = 1,
  }

  rasterizer := vk.PipelineRasterizationStateCreateInfo {
    sType       = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
    polygonMode = .FILL,
    frontFace   = .COUNTER_CLOCKWISE,
    lineWidth   = 1.0,
  }

  multisampling := vk.PipelineMultisampleStateCreateInfo {
    sType                = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
    rasterizationSamples = {._1},
  }

  color_blend_attachment := vk.PipelineColorBlendAttachmentState {
    blendEnable         = true,
    srcColorBlendFactor = .SRC_ALPHA,
    dstColorBlendFactor = .ONE_MINUS_SRC_ALPHA,
    colorBlendOp        = .ADD,
    srcAlphaBlendFactor = .SRC_ALPHA,
    dstAlphaBlendFactor = .ONE_MINUS_SRC_ALPHA,
    alphaBlendOp        = .ADD,
    colorWriteMask      = {.R, .G, .B, .A},
  }

  color_blending := vk.PipelineColorBlendStateCreateInfo {
    sType           = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
    attachmentCount = 1,
    pAttachments    = &color_blend_attachment,
  }

  dynamic_states := [2]vk.DynamicState{.VIEWPORT, .SCISSOR}
  dynamic_state := vk.PipelineDynamicStateCreateInfo {
    sType             = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
    dynamicStateCount = 2,
    pDynamicStates    = raw_data(&dynamic_states),
  }

  color_formats := [1]vk.Format{format}
  rendering_info := vk.PipelineRenderingCreateInfo {
    sType                   = .PIPELINE_RENDERING_CREATE_INFO,
    colorAttachmentCount    = 1,
    pColorAttachmentFormats = raw_data(&color_formats),
  }

  pipeline_info := vk.GraphicsPipelineCreateInfo {
    sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
    pNext               = &rendering_info,
    stageCount          = 2,
    pStages             = raw_data(&shader_stages),
    pVertexInputState   = &vertex_input_info,
    pInputAssemblyState = &input_assembly,
    pViewportState      = &viewport_state,
    pRasterizationState = &rasterizer,
    pMultisampleState   = &multisampling,
    pColorBlendState    = &color_blending,
    pDynamicState       = &dynamic_state,
    layout              = self.pipeline_layout,
  }

  vk.CreateGraphicsPipelines(gctx.device, 0, 1, &pipeline_info, nil, &self.pipeline) or_return
  log.info("UI pipeline created successfully")
  return .SUCCESS
}

shutdown :: proc(self: ^Renderer, gctx: ^gpu.GPUContext) {
  vk.DestroyPipeline(gctx.device, self.pipeline, nil)
  vk.DestroyPipelineLayout(gctx.device, self.pipeline_layout, nil)
}

render :: proc(
  self: ^Renderer,
  commands: []cmd.RenderCommand,
  gctx: ^gpu.GPUContext,
  texture_manager: ^gpu.TextureManager,
  command_buffer: vk.CommandBuffer,
  width: u32,
  height: u32,
  frame_index: u32,
) {
  projection := linalg.matrix_ortho3d_f32(0, f32(width), f32(height), 0, -1, 1)
  vk.CmdPushConstants(
    command_buffer,
    self.pipeline_layout,
    {.VERTEX},
    0,
    size_of(matrix[4, 4]f32),
    &projection,
  )

  sort_keys := make([dynamic]CommandSortKey, 0, len(commands), context.temp_allocator)
  defer delete(sort_keys)

  for command, idx in commands {
    texture_id: u32
    z_order: i32
    switch c in command {
    case cmd.DrawQuadCommand:
      texture_id = c.texture_id
      z_order = c.z_order
    case cmd.DrawMeshCommand:
      texture_id = c.texture_id
      z_order = c.z_order
    case cmd.DrawTextCommand:
      texture_id = c.font_atlas_id
      z_order = c.z_order
    }
    append(&sort_keys, CommandSortKey{z_order = z_order, texture_id = texture_id, cmd_index = idx})
  }

  slice.sort_by(sort_keys[:], proc(a, b: CommandSortKey) -> bool {
      if a.z_order != b.z_order do return a.z_order < b.z_order
      return a.texture_id < b.texture_id
    })

  self.vertex_count = 0
  self.index_count = 0
  draw_batches := make([dynamic]DrawBatch, 0, 16, context.temp_allocator)
  defer delete(draw_batches)
  current_texture: u32 = max(u32)
  batch_start_index: u32 = 0

  for key in sort_keys {
    if key.texture_id != current_texture {
      if self.index_count > batch_start_index {
        append(
          &draw_batches,
          DrawBatch{first_index = batch_start_index, index_count = self.index_count - batch_start_index},
        )
      }
      current_texture = key.texture_id
      batch_start_index = self.index_count
    }
    add_command_to_batch(self, commands[key.cmd_index], key.texture_id)
  }

  if self.index_count > batch_start_index {
    append(
      &draw_batches,
      DrawBatch{first_index = batch_start_index, index_count = self.index_count - batch_start_index},
    )
  }

  if self.vertex_count > 0 {
    gpu.write(&self.vertex_buffers[frame_index], self.vertices[:self.vertex_count])
    gpu.write(&self.index_buffers[frame_index], self.indices[:self.index_count])
    offsets := [1]vk.DeviceSize{0}
    vk.CmdBindVertexBuffers(command_buffer, 0, 1, &self.vertex_buffers[frame_index].buffer, raw_data(&offsets))
    vk.CmdBindIndexBuffer(command_buffer, self.index_buffers[frame_index].buffer, 0, .UINT32)
    for batch in draw_batches {
      vk.CmdDrawIndexed(command_buffer, batch.index_count, 1, batch.first_index, 0, 0)
    }
  }
}

add_command_to_batch :: proc(self: ^Renderer, command: cmd.RenderCommand, texture_id: u32) {
  switch c in command {
  case cmd.DrawQuadCommand:
    add_quad_to_batch(self, c, texture_id)
  case cmd.DrawMeshCommand:
    add_mesh_to_batch(self, c, texture_id)
  case cmd.DrawTextCommand:
    add_text_to_batch(self, c, texture_id)
  }
}

add_quad_to_batch :: proc(self: ^Renderer, quad: cmd.DrawQuadCommand, texture_id: u32) {
  base_vertex := self.vertex_count
  color := quad.color
  self.vertices[self.vertex_count] = Vertex2D{{quad.position.x, quad.position.y}, {0, 0}, color, texture_id}
  self.vertex_count += 1
  self.vertices[self.vertex_count] = Vertex2D{{quad.position.x + quad.size.x, quad.position.y}, {1, 0}, color, texture_id}
  self.vertex_count += 1
  self.vertices[self.vertex_count] = Vertex2D{{quad.position.x + quad.size.x, quad.position.y + quad.size.y}, {1, 1}, color, texture_id}
  self.vertex_count += 1
  self.vertices[self.vertex_count] = Vertex2D{{quad.position.x, quad.position.y + quad.size.y}, {0, 1}, color, texture_id}
  self.vertex_count += 1
  self.indices[self.index_count] = base_vertex + 0; self.index_count += 1
  self.indices[self.index_count] = base_vertex + 1; self.index_count += 1
  self.indices[self.index_count] = base_vertex + 2; self.index_count += 1
  self.indices[self.index_count] = base_vertex + 0; self.index_count += 1
  self.indices[self.index_count] = base_vertex + 2; self.index_count += 1
  self.indices[self.index_count] = base_vertex + 3; self.index_count += 1
}

add_mesh_to_batch :: proc(self: ^Renderer, mesh: cmd.DrawMeshCommand, texture_id: u32) {
  base_vertex := self.vertex_count
  for v in mesh.vertices {
    self.vertices[self.vertex_count] = Vertex2D {
      pos        = mesh.position + v.pos,
      uv         = v.uv,
      color      = v.color,
      texture_id = texture_id,
    }
    self.vertex_count += 1
  }
  for idx in mesh.indices {
    self.indices[self.index_count] = base_vertex + idx
    self.index_count += 1
  }
}

add_text_to_batch :: proc(self: ^Renderer, text: cmd.DrawTextCommand, texture_id: u32) {
  for glyph in text.glyphs {
    base_vertex := self.vertex_count
    p0 := text.position + glyph.p0
    p1 := text.position + glyph.p1
    self.vertices[self.vertex_count] = Vertex2D{p0, glyph.uv0, glyph.color, texture_id}
    self.vertex_count += 1
    self.vertices[self.vertex_count] = Vertex2D{{p1.x, p0.y}, {glyph.uv1.x, glyph.uv0.y}, glyph.color, texture_id}
    self.vertex_count += 1
    self.vertices[self.vertex_count] = Vertex2D{p1, glyph.uv1, glyph.color, texture_id}
    self.vertex_count += 1
    self.vertices[self.vertex_count] = Vertex2D{{p0.x, p1.y}, {glyph.uv0.x, glyph.uv1.y}, glyph.color, texture_id}
    self.vertex_count += 1
    self.indices[self.index_count] = base_vertex + 0; self.index_count += 1
    self.indices[self.index_count] = base_vertex + 1; self.index_count += 1
    self.indices[self.index_count] = base_vertex + 2; self.index_count += 1
    self.indices[self.index_count] = base_vertex + 0; self.index_count += 1
    self.indices[self.index_count] = base_vertex + 2; self.index_count += 1
    self.indices[self.index_count] = base_vertex + 3; self.index_count += 1
  }
}

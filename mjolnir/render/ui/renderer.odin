package ui_render

import "../../geometry"
import "../../gpu"
import "../shared"
import cmd "../../gpu/ui"
import rg "../graph"
import "core:log"
import "core:math/linalg"
import "core:slice"
import vk "vendor:vulkan"

UI_MAX_VERTICES :: 65536
UI_MAX_INDICES :: 98304
FRAMES_IN_FLIGHT :: 2

Vertex2D :: geometry.Vertex2D

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
    vk.PushConstantRange {
      stageFlags = {.VERTEX},
      size = size_of(matrix[4, 4]f32),
    },
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
  shader_stages := gpu.create_vert_frag_stages(
    vert_module,
    frag_module,
    &shared.SHADER_SPEC_CONSTANTS,
  )
  vertex_input_info := vk.PipelineVertexInputStateCreateInfo {
    sType                           = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
    vertexBindingDescriptionCount   = 1,
    pVertexBindingDescriptions      = &geometry.VERTEX2D_BINDING_DESCRIPTION,
    vertexAttributeDescriptionCount = len(geometry.VERTEX2D_ATTRIBUTE_DESCRIPTIONS),
    pVertexAttributeDescriptions    = raw_data(geometry.VERTEX2D_ATTRIBUTE_DESCRIPTIONS[:]),
  }

  color_formats := [?]vk.Format{format}
  rendering_info := vk.PipelineRenderingCreateInfo {
    sType                   = .PIPELINE_RENDERING_CREATE_INFO,
    colorAttachmentCount    = len(color_formats),
    pColorAttachmentFormats = raw_data(&color_formats),
  }

  pipeline_info := vk.GraphicsPipelineCreateInfo {
    sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
    pNext               = &rendering_info,
    stageCount          = len(shader_stages),
    pStages             = raw_data(&shader_stages),
    pVertexInputState   = &vertex_input_info,
    pInputAssemblyState = &gpu.STANDARD_INPUT_ASSEMBLY,
    pViewportState      = &gpu.STANDARD_VIEWPORT_STATE,
    pRasterizationState = &gpu.DOUBLE_SIDED_RASTERIZER,
    pMultisampleState   = &gpu.STANDARD_MULTISAMPLING,
    pColorBlendState    = &gpu.COLOR_BLENDING_ADDITIVE,
    pDynamicState       = &gpu.STANDARD_DYNAMIC_STATES,
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

  sort_keys := make(
    [dynamic]CommandSortKey,
    0,
    len(commands),
    context.temp_allocator,
  )
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
    append(
      &sort_keys,
      CommandSortKey {
        z_order = z_order,
        texture_id = texture_id,
        cmd_index = idx,
      },
    )
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
          DrawBatch {
            first_index = batch_start_index,
            index_count = self.index_count - batch_start_index,
          },
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
      DrawBatch {
        first_index = batch_start_index,
        index_count = self.index_count - batch_start_index,
      },
    )
  }

  if self.vertex_count > 0 {
    gpu.write(
      &self.vertex_buffers[frame_index],
      self.vertices[:self.vertex_count],
    )
    gpu.write(
      &self.index_buffers[frame_index],
      self.indices[:self.index_count],
    )
    gpu.bind_vertex_index_buffers(
      command_buffer,
      self.vertex_buffers[frame_index].buffer,
      self.index_buffers[frame_index].buffer,
    )
    for batch in draw_batches {
      vk.CmdDrawIndexed(
        command_buffer,
        batch.index_count,
        1,
        batch.first_index,
        0,
        0,
      )
    }
  }
}

add_command_to_batch :: proc(
  self: ^Renderer,
  command: cmd.RenderCommand,
  texture_id: u32,
) {
  switch c in command {
  case cmd.DrawQuadCommand:
    add_quad_to_batch(self, c, texture_id)
  case cmd.DrawMeshCommand:
    add_mesh_to_batch(self, c, texture_id)
  case cmd.DrawTextCommand:
    add_text_to_batch(self, c, texture_id)
  }
}

add_quad_to_batch :: proc(
  self: ^Renderer,
  quad: cmd.DrawQuadCommand,
  texture_id: u32,
) {
  base_vertex := self.vertex_count
  color := quad.color
  self.vertices[self.vertex_count] = Vertex2D {
    {quad.position.x, quad.position.y},
    {0, 0},
    color,
    texture_id,
  }
  self.vertex_count += 1
  self.vertices[self.vertex_count] = Vertex2D {
    {quad.position.x + quad.size.x, quad.position.y},
    {1, 0},
    color,
    texture_id,
  }
  self.vertex_count += 1
  self.vertices[self.vertex_count] = Vertex2D {
    {quad.position.x + quad.size.x, quad.position.y + quad.size.y},
    {1, 1},
    color,
    texture_id,
  }
  self.vertex_count += 1
  self.vertices[self.vertex_count] = Vertex2D {
    {quad.position.x, quad.position.y + quad.size.y},
    {0, 1},
    color,
    texture_id,
  }
  self.vertex_count += 1
  self.indices[self.index_count] = base_vertex + 0;self.index_count += 1
  self.indices[self.index_count] = base_vertex + 1;self.index_count += 1
  self.indices[self.index_count] = base_vertex + 2;self.index_count += 1
  self.indices[self.index_count] = base_vertex + 0;self.index_count += 1
  self.indices[self.index_count] = base_vertex + 2;self.index_count += 1
  self.indices[self.index_count] = base_vertex + 3;self.index_count += 1
}

add_mesh_to_batch :: proc(
  self: ^Renderer,
  mesh: cmd.DrawMeshCommand,
  texture_id: u32,
) {
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

add_text_to_batch :: proc(
  self: ^Renderer,
  text: cmd.DrawTextCommand,
  texture_id: u32,
) {
  for glyph in text.glyphs {
    base_vertex := self.vertex_count
    p0 := text.position + glyph.p0
    p1 := text.position + glyph.p1
    self.vertices[self.vertex_count] = Vertex2D {
      p0,
      glyph.uv0,
      glyph.color,
      texture_id,
    }
    self.vertex_count += 1
    self.vertices[self.vertex_count] = Vertex2D {
      {p1.x, p0.y},
      {glyph.uv1.x, glyph.uv0.y},
      glyph.color,
      texture_id,
    }
    self.vertex_count += 1
    self.vertices[self.vertex_count] = Vertex2D {
      p1,
      glyph.uv1,
      glyph.color,
      texture_id,
    }
    self.vertex_count += 1
    self.vertices[self.vertex_count] = Vertex2D {
      {p0.x, p1.y},
      {glyph.uv0.x, glyph.uv1.y},
      glyph.color,
      texture_id,
    }
    self.vertex_count += 1
    self.indices[self.index_count] = base_vertex + 0;self.index_count += 1
    self.indices[self.index_count] = base_vertex + 1;self.index_count += 1
    self.indices[self.index_count] = base_vertex + 2;self.index_count += 1
    self.indices[self.index_count] = base_vertex + 0;self.index_count += 1
    self.indices[self.index_count] = base_vertex + 2;self.index_count += 1
    self.indices[self.index_count] = base_vertex + 3;self.index_count += 1
  }
}

// ============================================================================
// RENDER GRAPH INTEGRATION
// ============================================================================

// Context for graph-based UI rendering
UIPassGraphContext :: struct {
  renderer:         ^Renderer,
  texture_manager:  ^gpu.TextureManager,
  gctx:             ^gpu.GPUContext,
  commands:         []cmd.RenderCommand,
  swapchain_view:   vk.ImageView,
  swapchain_extent: vk.Extent2D,
}

// Setup phase: declare resource dependencies
ui_pass_setup :: proc(builder: ^rg.PassBuilder, user_data: rawptr) {
  // Read UI vertex/index buffers (per-frame)
  rg.builder_read(builder, "ui_vertex_buffer")
  rg.builder_read(builder, "ui_index_buffer")

  // Keep UI ordered after post-process in the graph.
  rg.builder_read(builder, "post_process_image_0")

  // Note: Swapchain image is NOT a graph resource - it's passed through context
  // UI pass writes to swapchain but doesn't declare it as a graph dependency
}

// Execute phase: render with resolved resources
ui_pass_execute :: proc(pass_ctx: ^rg.PassContext, user_data: rawptr) {
  ctx := cast(^UIPassGraphContext)user_data
  self := ctx.renderer
  cmd := pass_ctx.cmd

  // Resolve vertex buffer
  vb_id := rg.ResourceId("ui_vertex_buffer")
  if vb_id not_in pass_ctx.graph.resources do return
  vb_handle, _ := rg.resolve(rg.BufferHandle, pass_ctx, vb_id)

  // Resolve index buffer
  ib_id := rg.ResourceId("ui_index_buffer")
  if ib_id not_in pass_ctx.graph.resources do return
  ib_handle, _ := rg.resolve(rg.BufferHandle, pass_ctx, ib_id)

  // Use swapchain view/extent from context (passed from Engine, not a graph resource)
  swapchain_view := ctx.swapchain_view
  swapchain_extent := ctx.swapchain_extent

  // Begin rendering to swapchain
  rendering_attachment_info := vk.RenderingAttachmentInfo {
    sType       = .RENDERING_ATTACHMENT_INFO,
    imageView   = swapchain_view,
    imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
    loadOp      = .LOAD,  // Don't clear - render on top
    storeOp     = .STORE,
  }

  rendering_info := vk.RenderingInfo {
    sType = .RENDERING_INFO,
    renderArea = {extent = swapchain_extent},
    layerCount = 1,
    colorAttachmentCount = 1,
    pColorAttachments = &rendering_attachment_info,
  }

  vk.CmdBeginRendering(cmd, &rendering_info)

  // Set viewport and scissor
  viewport := vk.Viewport {
    x        = 0,
    y        = f32(swapchain_extent.height),
    width    = f32(swapchain_extent.width),
    height   = -f32(swapchain_extent.height),
    minDepth = 0.0,
    maxDepth = 1.0,
  }
  scissor := vk.Rect2D {
    offset = {0, 0},
    extent = swapchain_extent,
  }
  vk.CmdSetViewport(cmd, 0, 1, &viewport)
  vk.CmdSetScissor(cmd, 0, 1, &scissor)

  // Bind pipeline and descriptor sets
  vk.CmdBindPipeline(cmd, .GRAPHICS, self.pipeline)
  vk.CmdBindDescriptorSets(
    cmd,
    .GRAPHICS,
    self.pipeline_layout,
    0,
    1,
    &ctx.texture_manager.descriptor_set,
    0,
    nil,
  )

  // Render UI using staged commands
  render(
    self,
    ctx.commands,
    ctx.gctx,
    ctx.texture_manager,
    cmd,
    swapchain_extent.width,
    swapchain_extent.height,
    pass_ctx.frame_index,
  )

  vk.CmdEndRendering(cmd)
}

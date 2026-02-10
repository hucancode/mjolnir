package ui

import cont "../../containers"
import d "../../data"
import "../../gpu"
import "core:log"
import "core:math/linalg"
import "core:mem"
import "core:slice"
import fs "vendor:fontstash"
import vk "vendor:vulkan"

UI_MAX_VERTICES :: 65536
UI_MAX_INDICES :: 98304
FRAMES_IN_FLIGHT :: 2

Renderer :: struct {
  pipeline_layout:           vk.PipelineLayout,
  pipeline:                  vk.Pipeline,
  projection_layout:         vk.DescriptorSetLayout,
  projection_descriptor_set: vk.DescriptorSet,
  proj_buffer:               gpu.MutableBuffer(matrix[4, 4]f32),
  vertex_buffers:            [FRAMES_IN_FLIGHT]gpu.MutableBuffer(Vertex2D),
  index_buffers:             [FRAMES_IN_FLIGHT]gpu.MutableBuffer(u32),
  vertices:                  [UI_MAX_VERTICES]Vertex2D,
  indices:                   [UI_MAX_INDICES]u32,
  vertex_count:              u32,
  index_count:               u32,
  font_context:              ^fs.FontContext,
  font_atlas:                d.Image2DHandle,
  font_atlas_width:          i32,
  font_atlas_height:         i32,
  font_atlas_dirty:          bool,
  white_texture:             d.Image2DHandle,
}

DrawBatch :: struct {
  first_index: u32,
  index_count: u32,
}

SortKey :: struct {
  z_order:    i32,
  texture_id: u32,
  handle:     UIWidgetHandle,
}

init_renderer :: proc(
  self: ^Renderer,
  sys: ^System,
  gctx: ^gpu.GPUContext,
  texture_manager: ^gpu.TextureManager,
  textures_set_layout: vk.DescriptorSetLayout,
  width: u32,
  height: u32,
  format: vk.Format,
) -> vk.Result {
  log.info("Initializing UI renderer...")
  // Create projection buffer
  self.proj_buffer = gpu.create_mutable_buffer(
    gctx,
    matrix[4, 4]f32,
    1,
    {.UNIFORM_BUFFER},
  ) or_return
  // Create vertex and index buffers (one per frame in flight)
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
  // Create projection descriptor set layout
  projection_binding := vk.DescriptorSetLayoutBinding {
    binding         = 0,
    descriptorType  = .UNIFORM_BUFFER,
    descriptorCount = 1,
    stageFlags      = {.VERTEX},
  }
  projection_layout_info := vk.DescriptorSetLayoutCreateInfo {
    sType        = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
    bindingCount = 1,
    pBindings    = &projection_binding,
  }
  vk.CreateDescriptorSetLayout(
    gctx.device,
    &projection_layout_info,
    nil,
    &self.projection_layout,
  ) or_return
  // Allocate projection descriptor set
  alloc_info := vk.DescriptorSetAllocateInfo {
    sType              = .DESCRIPTOR_SET_ALLOCATE_INFO,
    descriptorPool     = gctx.descriptor_pool,
    descriptorSetCount = 1,
    pSetLayouts        = &self.projection_layout,
  }
  vk.AllocateDescriptorSets(
    gctx.device,
    &alloc_info,
    &self.projection_descriptor_set,
  ) or_return
  // Update projection descriptor set
  buffer_info := vk.DescriptorBufferInfo {
    buffer = self.proj_buffer.buffer,
    offset = 0,
    range  = size_of(matrix[4, 4]f32),
  }
  write := vk.WriteDescriptorSet {
    sType           = .WRITE_DESCRIPTOR_SET,
    dstSet          = self.projection_descriptor_set,
    dstBinding      = 0,
    dstArrayElement = 0,
    descriptorCount = 1,
    descriptorType  = .UNIFORM_BUFFER,
    pBufferInfo     = &buffer_info,
  }
  vk.UpdateDescriptorSets(gctx.device, 1, &write, 0, nil)
  // Create pipeline layout (set 0 = projection, set 1 = textures from resource manager)
  set_layouts := [2]vk.DescriptorSetLayout {
    self.projection_layout,
    textures_set_layout,
  }
  pipeline_layout_info := vk.PipelineLayoutCreateInfo {
    sType          = .PIPELINE_LAYOUT_CREATE_INFO,
    setLayoutCount = 2,
    pSetLayouts    = raw_data(&set_layouts),
  }
  vk.CreatePipelineLayout(
    gctx.device,
    &pipeline_layout_info,
    nil,
    &self.pipeline_layout,
  ) or_return

  // Create pipeline
  create_pipeline(self, gctx, format) or_return
  // Create default white texture (1x1 white pixel)
  white_pixel := [4]u8{255, 255, 255, 255}
  self.white_texture = gpu.allocate_texture_2d_with_data(
    texture_manager,
    gctx,
    raw_data(white_pixel[:]),
    vk.DeviceSize(len(white_pixel)),
    1,
    1,
    .R8G8B8A8_UNORM,
    {.SAMPLED},
  ) or_return
  // Set as default texture for UI widgets
  sys.default_texture = self.white_texture
  // Initialize fontstash
  self.font_atlas_width = 512
  self.font_atlas_height = 512
  self.font_context = new(fs.FontContext)
  fs.Init(
    self.font_context,
    int(self.font_atlas_width),
    int(self.font_atlas_height),
    .TOPLEFT,
  )
  // Set callbacks
  self.font_context.callbackResize = fs_render_create
  self.font_context.callbackUpdate = fs_render_update
  self.font_context.userData = self
  log.infof(
    "Fontstash initialized: textureData=%v, len=%d",
    self.font_context.textureData != nil,
    len(self.font_context.textureData),
  )
  log.infof(
    "Callbacks set: resize=%v, update=%v",
    self.font_context.callbackResize != nil,
    self.font_context.callbackUpdate != nil,
  )
  // Add default font
  default_font_path := "assets/Outfit-Regular.ttf"
  font_index := fs.AddFont(self.font_context, "default", default_font_path, 0)
  if font_index == fs.INVALID {
    log.errorf("Failed to load default font from %s", default_font_path)
    return .ERROR_INITIALIZATION_FAILED
  }
  log.infof(
    "Loaded default font from %s (index: %d)",
    default_font_path,
    font_index,
  )
  // Pre-rasterize common glyphs to populate the atlas
  log.info("Pre-rasterizing common glyphs...")
  fs.SetFont(self.font_context, font_index)
  fs.SetColor(self.font_context, {255, 255, 255, 255})
  test_string := " !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~"
  common_sizes := [?]f32{12, 14, 16, 18, 20, 24, 28, 32, 36, 48, 64, 72, 96}
  for size in common_sizes {
    fs.SetSize(self.font_context, size)
    iter := fs.TextIterInit(self.font_context, 0, 0, test_string)
    quad: fs.Quad
    for fs.TextIterNext(self.font_context, &iter, &quad) {}
  }
  log.info("Pre-rasterization complete")
  // Force initial font atlas creation
  self.font_atlas_dirty = true
  update_font_atlas(self, gctx, texture_manager)

  log.info("UI renderer initialized successfully")
  return .SUCCESS
}

create_pipeline :: proc(
  self: ^Renderer,
  gctx: ^gpu.GPUContext,
  format: vk.Format,
) -> vk.Result {
  // Load shaders
  vert_code := #load("../../shader/ui/vert.spv")
  frag_code := #load("../../shader/ui/frag.spv")

  vert_module := gpu.create_shader_module(gctx.device, vert_code) or_return
  defer vk.DestroyShaderModule(gctx.device, vert_module, nil)

  frag_module := gpu.create_shader_module(gctx.device, frag_code) or_return
  defer vk.DestroyShaderModule(gctx.device, frag_module, nil)

  // Shader stages
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
      sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
      stage = {.VERTEX},
      module = vert_module,
      pName = "main",
    },
    {
      sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
      stage = {.FRAGMENT},
      module = frag_module,
      pName = "main",
      pSpecializationInfo = &spec_info,
    },
  }

  // Vertex input
  binding_desc := vk.VertexInputBindingDescription {
    binding   = 0,
    stride    = size_of(Vertex2D),
    inputRate = .VERTEX,
  }

  attribute_descs := [4]vk.VertexInputAttributeDescription {
    {
      location = 0,
      binding = 0,
      format = .R32G32_SFLOAT,
      offset = u32(offset_of(Vertex2D, pos)),
    },
    {
      location = 1,
      binding = 0,
      format = .R32G32_SFLOAT,
      offset = u32(offset_of(Vertex2D, uv)),
    },
    {
      location = 2,
      binding = 0,
      format = .R8G8B8A8_UNORM,
      offset = u32(offset_of(Vertex2D, color)),
    },
    {
      location = 3,
      binding = 0,
      format = .R32_UINT,
      offset = u32(offset_of(Vertex2D, texture_id)),
    },
  }

  vertex_input_info := vk.PipelineVertexInputStateCreateInfo {
    sType                           = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
    vertexBindingDescriptionCount   = 1,
    pVertexBindingDescriptions      = &binding_desc,
    vertexAttributeDescriptionCount = 4,
    pVertexAttributeDescriptions    = raw_data(&attribute_descs),
  }

  // Input assembly
  input_assembly := vk.PipelineInputAssemblyStateCreateInfo {
    sType                  = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
    topology               = .TRIANGLE_LIST,
    primitiveRestartEnable = false,
  }

  // Viewport and scissor (dynamic)
  viewport_state := vk.PipelineViewportStateCreateInfo {
    sType         = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
    viewportCount = 1,
    scissorCount  = 1,
  }

  // Rasterization
  rasterizer := vk.PipelineRasterizationStateCreateInfo {
    sType                   = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
    depthClampEnable        = false,
    rasterizerDiscardEnable = false,
    polygonMode             = .FILL,
    cullMode                = {}, // No culling for UI
    frontFace               = .COUNTER_CLOCKWISE,
    depthBiasEnable         = false,
    lineWidth               = 1.0,
  }

  // Multisampling
  multisampling := vk.PipelineMultisampleStateCreateInfo {
    sType                = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
    rasterizationSamples = {._1},
    sampleShadingEnable  = false,
  }

  // Color blending (match old working system)
  color_blend_attachment := vk.PipelineColorBlendAttachmentState {
    blendEnable         = true,
    srcColorBlendFactor = .SRC_ALPHA,
    dstColorBlendFactor = .ONE_MINUS_SRC_ALPHA,
    colorBlendOp        = .ADD,
    srcAlphaBlendFactor = .SRC_ALPHA, // Changed from .ONE
    dstAlphaBlendFactor = .ONE_MINUS_SRC_ALPHA,
    alphaBlendOp        = .ADD,
    colorWriteMask      = {.R, .G, .B, .A},
  }

  color_blending := vk.PipelineColorBlendStateCreateInfo {
    sType           = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
    logicOpEnable   = false,
    attachmentCount = 1,
    pAttachments    = &color_blend_attachment,
  }

  // Dynamic state
  dynamic_states := [2]vk.DynamicState{.VIEWPORT, .SCISSOR}
  dynamic_state := vk.PipelineDynamicStateCreateInfo {
    sType             = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
    dynamicStateCount = 2,
    pDynamicStates    = raw_data(&dynamic_states),
  }

  // Rendering info (dynamic rendering)
  color_formats := [1]vk.Format{format}
  rendering_info := vk.PipelineRenderingCreateInfo {
    sType                   = .PIPELINE_RENDERING_CREATE_INFO,
    colorAttachmentCount    = 1,
    pColorAttachmentFormats = raw_data(&color_formats),
  }

  // Create pipeline
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
    renderPass          = 0,
    subpass             = 0,
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

shutdown :: proc(self: ^Renderer, gctx: ^gpu.GPUContext, texture_manager: ^gpu.TextureManager) {
  if self.font_context != nil {
    fs.Destroy(self.font_context)
    free(self.font_context)
  }

  // Clean up white texture
  if self.white_texture != (d.Image2DHandle{}) {
    gpu.free_texture_2d(texture_manager, gctx, self.white_texture)
  }

  // Clean up font atlas
  if self.font_atlas != (d.Image2DHandle{}) {
    gpu.free_texture_2d(texture_manager, gctx, self.font_atlas)
  }

  vk.DestroyPipeline(gctx.device, self.pipeline, nil)
  vk.DestroyPipelineLayout(gctx.device, self.pipeline_layout, nil)
  vk.DestroyDescriptorSetLayout(gctx.device, self.projection_layout, nil)

  gpu.mutable_buffer_destroy(gctx.device, &self.proj_buffer)
  for i in 0 ..< FRAMES_IN_FLIGHT {
    gpu.mutable_buffer_destroy(gctx.device, &self.vertex_buffers[i])
    gpu.mutable_buffer_destroy(gctx.device, &self.index_buffers[i])
  }
}

render :: proc(
  self: ^Renderer,
  sys: ^System,
  gctx: ^gpu.GPUContext,
  texture_manager: ^gpu.TextureManager,
  command_buffer: vk.CommandBuffer,
  width: u32,
  height: u32,
  frame_index: u32,
) {
  // Update projection matrix
  ortho := linalg.matrix_ortho3d_f32(0, f32(width), f32(height), 0, -1, 1)
  gpu.mutable_buffer_write(&self.proj_buffer, &ortho, 0)

  // Update font atlas if dirty
  if self.font_atlas_dirty {
    update_font_atlas(self, gctx, texture_manager)
    self.font_atlas_dirty = false
  }
  // Collect and sort widgets
  sort_keys := make([dynamic]SortKey, 0, len(sys.widget_pool.entries))
  defer delete(sort_keys)
  font_atlas_id := transmute(cont.Handle)self.font_atlas
  for &entry, i in sys.widget_pool.entries {
    if !entry.active do continue

    widget := &entry.item
    if widget == nil do continue
    if !get_widget_base(widget).visible do continue

    texture_id: u32 = 0
    switch w in widget {
    case Mesh2D:
      raw_handle := transmute(cont.Handle)w.texture
      texture_id = raw_handle.index
    case Quad2D:
      raw_handle := transmute(cont.Handle)w.texture
      texture_id = raw_handle.index
    case Text2D:
      texture_id = font_atlas_id.index
    case Box:
      continue
    }
    raw_handle: cont.Handle
    raw_handle.index = u32(i)
    raw_handle.generation = entry.generation
    handle := transmute(UIWidgetHandle)raw_handle
    append(
      &sort_keys,
      SortKey {
        z_order = get_widget_base(widget).z_order,
        texture_id = texture_id,
        handle = handle,
      },
    )
  }
  slice.sort_by(sort_keys[:], proc(a, b: SortKey) -> bool {
    if a.z_order != b.z_order do return a.z_order < b.z_order
    return a.texture_id < b.texture_id
  })
  self.vertex_count = 0
  self.index_count = 0
  draw_batches := make([dynamic]DrawBatch, 0, 16)
  defer delete(draw_batches)
  current_texture: u32 = max(u32)
  batch_start_index: u32 = 0
  for key in sort_keys {
    widget := get_widget(sys, key.handle)
    if widget == nil do continue
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
    add_widget_to_batch(self, widget, key.texture_id)
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
    offsets := [1]vk.DeviceSize{0}
    vk.CmdBindVertexBuffers(
      command_buffer,
      0,
      1,
      &self.vertex_buffers[frame_index].buffer,
      raw_data(&offsets),
    )
    vk.CmdBindIndexBuffer(
      command_buffer,
      self.index_buffers[frame_index].buffer,
      0,
      .UINT32,
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

add_widget_to_batch :: proc(
  self: ^Renderer,
  widget: ^Widget,
  texture_id: u32,
) {
  switch &w in widget {
  case Quad2D:
    add_quad_to_batch(self, &w, texture_id)
  case Mesh2D:
    add_mesh_to_batch(self, &w, texture_id)
  case Text2D:
    add_text_to_batch(self, &w, texture_id)
  case Box:
  // Boxes don't render
  }
}

add_quad_to_batch :: proc(self: ^Renderer, quad: ^Quad2D, texture_id: u32) {
  base_vertex := self.vertex_count
  color := quad.color
  self.vertices[self.vertex_count] = Vertex2D {
    {quad.world_position.x, quad.world_position.y},
    {0, 0},
    color,
    texture_id,
  }
  self.vertex_count += 1
  self.vertices[self.vertex_count] = Vertex2D {
    {quad.world_position.x + quad.size.x, quad.world_position.y},
    {1, 0},
    color,
    texture_id,
  }
  self.vertex_count += 1
  self.vertices[self.vertex_count] = Vertex2D {
    {quad.world_position.x + quad.size.x, quad.world_position.y + quad.size.y},
    {1, 1},
    color,
    texture_id,
  }
  self.vertex_count += 1
  self.vertices[self.vertex_count] = Vertex2D {
    {quad.world_position.x, quad.world_position.y + quad.size.y},
    {0, 1},
    color,
    texture_id,
  }
  self.vertex_count += 1

  // Add 6 indices (2 triangles)
  self.indices[self.index_count] = base_vertex + 0
  self.index_count += 1
  self.indices[self.index_count] = base_vertex + 1
  self.index_count += 1
  self.indices[self.index_count] = base_vertex + 2
  self.index_count += 1
  self.indices[self.index_count] = base_vertex + 0
  self.index_count += 1
  self.indices[self.index_count] = base_vertex + 2
  self.index_count += 1
  self.indices[self.index_count] = base_vertex + 3
  self.index_count += 1
}

add_mesh_to_batch :: proc(self: ^Renderer, mesh: ^Mesh2D, texture_id: u32) {
  base_vertex := self.vertex_count
  for v in mesh.vertices {
    self.vertices[self.vertex_count] = Vertex2D {
      pos        = mesh.world_position + v.pos,
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

add_text_to_batch :: proc(self: ^Renderer, text: ^Text2D, texture_id: u32) {
  color := text.color
  for glyph in text.glyphs {
    base_vertex := self.vertex_count
    // Use fontstash quad positions directly, offset by text world position
    x0 := text.world_position.x + glyph.x0
    y0 := text.world_position.y + glyph.y0
    x1 := text.world_position.x + glyph.x1
    y1 := text.world_position.y + glyph.y1
    self.vertices[self.vertex_count] = Vertex2D {
      {x0, y0},
      {glyph.s0, glyph.t0},
      color,
      texture_id,
    }
    self.vertex_count += 1
    self.vertices[self.vertex_count] = Vertex2D {
      {x1, y0},
      {glyph.s1, glyph.t0},
      color,
      texture_id,
    }
    self.vertex_count += 1
    self.vertices[self.vertex_count] = Vertex2D {
      {x1, y1},
      {glyph.s1, glyph.t1},
      color,
      texture_id,
    }
    self.vertex_count += 1
    self.vertices[self.vertex_count] = Vertex2D {
      {x0, y1},
      {glyph.s0, glyph.t1},
      color,
      texture_id,
    }
    self.vertex_count += 1
    self.indices[self.index_count] = base_vertex + 0
    self.index_count += 1
    self.indices[self.index_count] = base_vertex + 1
    self.index_count += 1
    self.indices[self.index_count] = base_vertex + 2
    self.index_count += 1
    self.indices[self.index_count] = base_vertex + 0
    self.index_count += 1
    self.indices[self.index_count] = base_vertex + 2
    self.index_count += 1
    self.indices[self.index_count] = base_vertex + 3
    self.index_count += 1
  }
}

fs_render_create :: proc(user_ptr: rawptr, width, height: int) {
  self := cast(^Renderer)user_ptr
  self.font_atlas_width = i32(width)
  self.font_atlas_height = i32(height)
  self.font_atlas_dirty = true
}

fs_render_update :: proc(user_ptr: rawptr, rect: [4]f32, data: rawptr) {
  self := cast(^Renderer)user_ptr
  self.font_atlas_dirty = true
}

update_font_atlas :: proc(
  self: ^Renderer,
  gctx: ^gpu.GPUContext,
  texture_manager: ^gpu.TextureManager,
) {
  if !self.font_atlas_dirty do return
  if self.font_context == nil do return

  // Force fontstash to rasterize any pending glyphs
  dirty_rect: [4]f32
  if fs.ValidateTexture(self.font_context, &dirty_rect) {
    log.debugf(
      "Fontstash texture validated, dirty rect: (%.0f,%.0f,%.0f,%.0f)",
      dirty_rect[0],
      dirty_rect[1],
      dirty_rect[2],
      dirty_rect[3],
    )
  }

  // Get atlas data from fontstash
  atlas_data := self.font_context.textureData
  width := u32(self.font_context.width)
  height := u32(self.font_context.height)
  if len(atlas_data) == 0 {
    log.warn("Font atlas data is empty, cannot create texture")
    return
  }
  log.debugf(
    "Updating font atlas: %dx%d, data size: %d bytes",
    width,
    height,
    len(atlas_data),
  )
  if self.font_atlas != (d.Image2DHandle{}) {
    gpu.free_texture_2d(texture_manager, gctx, self.font_atlas)
  }
  font_atlas_result: vk.Result
  self.font_atlas, font_atlas_result = gpu.allocate_texture_2d_with_data(
    texture_manager,
    gctx,
    raw_data(atlas_data),
    vk.DeviceSize(len(atlas_data)),
    u32(width),
    u32(height),
    .R8_UNORM,
    {.SAMPLED},
  )
  if font_atlas_result != .SUCCESS {
  	return
  }
  self.font_atlas_dirty = false
}

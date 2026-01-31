package retained_ui

import cont "../../containers"
import gpu "../../gpu"
import resources "../../resources"
import "core:log"
import "core:math/linalg"
import "core:os"
import "core:slice"
import fs "vendor:fontstash"
import vk "vendor:vulkan"

atlas_resize_callback :: proc(data: rawptr, w, h: int) {
  self := cast(^Manager)data
}

init :: proc(
  self: ^Manager,
  gctx: ^gpu.GPUContext,
  color_format: vk.Format,
  width, height: u32,
  dpi_scale: f32 = 1.0,
  rm: ^resources.Manager,
) -> (
  ret: vk.Result,
) {
  // Initialize pools
  cont.init(&self.elements, 1000)
  cont.init(&self.flexboxes, 200)
  self.root_flexboxes = make([dynamic]FlexBoxHandle, 0, 50)
  defer if ret != .SUCCESS do delete(self.root_flexboxes)
  self.event_handlers = make(map[ElementHandle][dynamic]EventHandler)
  defer if ret != .SUCCESS {
    for _, handlers in self.event_handlers {
      delete(handlers)
    }
    delete(self.event_handlers)
  }
  self.layout_dirty = true

  // Initialize draw lists
  for &v in self.draw_lists {
    v.commands = make([dynamic]DrawCommand, 0, 1000)
  }
  defer if ret != .SUCCESS {
    for &v in self.draw_lists do delete(v.commands)
  }

  self.frame_width = width
  self.frame_height = height
  self.dpi_scale = dpi_scale

  log.infof("init retained UI pipeline...")
  vert_shader_module := gpu.create_shader_module(
    gctx.device,
    SHADER_UI_VERT,
  ) or_return
  defer vk.DestroyShaderModule(gctx.device, vert_shader_module, nil)

  frag_shader_module := gpu.create_shader_module(
    gctx.device,
    SHADER_UI_FRAG,
  ) or_return
  defer vk.DestroyShaderModule(gctx.device, frag_shader_module, nil)

  shader_stages := gpu.create_vert_frag_stages(
    vert_shader_module,
    frag_shader_module,
  )

  vertex_binding := vk.VertexInputBindingDescription {
    binding   = 0,
    stride    = size_of(Vertex2D),
    inputRate = .VERTEX,
  }

  vertex_attributes := [?]vk.VertexInputAttributeDescription {
    {
      binding = 0,
      location = 0,
      format = .R32G32_SFLOAT,
      offset = u32(offset_of(Vertex2D, pos)),
    },
    {
      binding = 0,
      location = 1,
      format = .R32G32_SFLOAT,
      offset = u32(offset_of(Vertex2D, uv)),
    },
    {
      binding = 0,
      location = 2,
      format = .R8G8B8A8_UNORM,
      offset = u32(offset_of(Vertex2D, color)),
    },
    {
      binding = 0,
      location = 3,
      format = .R32_UINT,
      offset = u32(offset_of(Vertex2D, texture_id)),
    },
    {
      binding = 0,
      location = 4,
      format = .R32_SFLOAT,
      offset = u32(offset_of(Vertex2D, z)),
    },
  }

  vertex_input := vk.PipelineVertexInputStateCreateInfo {
    sType                           = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
    vertexBindingDescriptionCount   = 1,
    pVertexBindingDescriptions      = &vertex_binding,
    vertexAttributeDescriptionCount = len(vertex_attributes),
    pVertexAttributeDescriptions    = raw_data(vertex_attributes[:]),
  }

  self.projection_layout = gpu.create_descriptor_set_layout(
    gctx,
    {.UNIFORM_BUFFER, {.VERTEX}},
  ) or_return
  defer if ret != .SUCCESS {
    vk.DestroyDescriptorSetLayout(gctx.device, self.projection_layout, nil)
  }

  self.pipeline_layout = gpu.create_pipeline_layout(
    gctx,
    nil,
    self.projection_layout,
    rm.textures_set_layout,
  ) or_return
  defer if ret != .SUCCESS {
    vk.DestroyPipelineLayout(gctx.device, self.pipeline_layout, nil)
  }

  pipeline_info := vk.GraphicsPipelineCreateInfo {
    sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
    pNext               = &gpu.COLOR_ONLY_RENDERING_INFO,
    stageCount          = len(shader_stages),
    pStages             = raw_data(shader_stages[:]),
    pVertexInputState   = &vertex_input,
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
  defer if ret != .SUCCESS {
    vk.DestroyPipeline(gctx.device, self.pipeline, nil)
  }

  log.infof("init UI default texture...")
  white_pixel := WHITE
  self.atlas_handle = resources.create_texture_from_pixels(
    gctx,
    rm,
    white_pixel[:],
    1,
    1,
    .R8G8B8A8_UNORM,
  ) or_return
  defer if ret != .SUCCESS {
    resources.destroy_texture(gctx.device, rm, self.atlas_handle)
  }
  log.infof("UI atlas created at bindless index %d", self.atlas_handle.index)

  log.infof("init UI buffers...")
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
  defer if ret != .SUCCESS {
    for j in 0 ..< FRAMES_IN_FLIGHT {
      gpu.mutable_buffer_destroy(gctx.device, &self.vertex_buffers[j])
      gpu.mutable_buffer_destroy(gctx.device, &self.index_buffers[j])
    }
  }

  ortho :=
    linalg.matrix_ortho3d(0, f32(width), f32(height), 0, -1, 1) *
    linalg.matrix4_scale(dpi_scale)
  self.proj_buffer = gpu.create_mutable_buffer(
    gctx,
    matrix[4, 4]f32,
    1,
    {.UNIFORM_BUFFER},
    raw_data(&ortho),
  ) or_return
  defer if ret != .SUCCESS {
    gpu.mutable_buffer_destroy(gctx.device, &self.proj_buffer)
  }

  self.projection_descriptor_set = gpu.create_descriptor_set(
    gctx,
    &self.projection_layout,
    {type = .UNIFORM_BUFFER, info = gpu.buffer_info(&self.proj_buffer)},
  ) or_return

  log.infof("init text rendering system...")
  fs.Init(&self.font_ctx, ATLAS_WIDTH, ATLAS_HEIGHT, .TOPLEFT)
  self.font_ctx.callbackResize = atlas_resize_callback
  self.font_ctx.userData = self

  font_path := "assets/Outfit-Regular.ttf"
  font_data, font_ok := os.read_entire_file(font_path)
  if !font_ok {
    log.errorf("Failed to load font: %s", font_path)
    return .ERROR_INITIALIZATION_FAILED
  }

  self.default_font = fs.AddFontMem(&self.font_ctx, "default", font_data, true)
  if self.default_font == fs.INVALID {
    log.errorf("Failed to add font to fontstash")
    return .ERROR_INITIALIZATION_FAILED
  }

  log.infof("pre-rasterizing common glyphs...")
  fs.SetFont(&self.font_ctx, self.default_font)
  fs.SetColor(&self.font_ctx, {255, 255, 255, 255})

  test_string := " !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~"
  common_sizes := [?]f32{12, 14, 16, 18, 20, 24, 28, 32, 36, 48, 64, 72, 96}

  for size in common_sizes {
    fs.SetSize(&self.font_ctx, size)
    iter := fs.TextIterInit(&self.font_ctx, 0, 0, test_string)
    quad: fs.Quad
    for fs.TextIterNext(&self.font_ctx, &iter, &quad) {}
  }
  log.infof("pre-rasterization complete")

  log.infof("creating text atlas texture...")
  atlas_size := self.font_ctx.width * self.font_ctx.height
  rgba_data := make([]u8, atlas_size * 4)
  defer delete(rgba_data)

  for i in 0 ..< atlas_size {
    alpha := self.font_ctx.textureData[i]
    rgba_data[i * 4 + 0] = 255
    rgba_data[i * 4 + 1] = 255
    rgba_data[i * 4 + 2] = 255
    rgba_data[i * 4 + 3] = alpha
  }

  self.text_atlas_handle = resources.create_texture_from_pixels(
    gctx,
    rm,
    rgba_data[:],
    self.font_ctx.width,
    self.font_ctx.height,
    .R8G8B8A8_UNORM,
  ) or_return
  defer if ret != .SUCCESS {
    resources.destroy_texture(gctx.device, rm, self.text_atlas_handle)
  }
  self.atlas_initialized = true
  log.infof(
    "Text atlas created at bindless index %d",
    self.text_atlas_handle.index,
  )

  log.infof("creating text GPU buffers...")
  self.text_vertex_buffer = gpu.create_mutable_buffer(
    gctx,
    Vertex2D,
    TEXT_MAX_VERTICES,
    {.VERTEX_BUFFER},
  ) or_return
  defer if ret != .SUCCESS {
    gpu.mutable_buffer_destroy(gctx.device, &self.text_vertex_buffer)
  }

  self.text_index_buffer = gpu.create_mutable_buffer(
    gctx,
    u32,
    TEXT_MAX_INDICES,
    {.INDEX_BUFFER},
  ) or_return
  defer if ret != .SUCCESS {
    gpu.mutable_buffer_destroy(gctx.device, &self.text_index_buffer)
  }

  log.infof("retained UI initialized")
  return .SUCCESS
}

shutdown :: proc(self: ^Manager, gctx: ^gpu.GPUContext) {
  // Clean up GPU resources
  for i in 0 ..< FRAMES_IN_FLIGHT {
    gpu.mutable_buffer_destroy(gctx.device, &self.vertex_buffers[i])
    gpu.mutable_buffer_destroy(gctx.device, &self.index_buffers[i])
    delete(self.draw_lists[i].commands)
  }
  gpu.mutable_buffer_destroy(gctx.device, &self.proj_buffer)

  // Clean up element data (dynamic arrays in Mesh2D)
  for &entry in self.elements.entries {
    if entry.active {
      element_destroy(&entry.item)
    }
  }
  delete(self.elements.entries)
  delete(self.elements.free_indices)

  // Clean up flexbox children arrays
  for &entry in self.flexboxes.entries {
    if entry.active {
      delete(entry.item.children)
    }
  }
  delete(self.flexboxes.entries)
  delete(self.flexboxes.free_indices)
  delete(self.root_flexboxes)

  // Clean up event handlers
  for _, handlers in self.event_handlers {
    delete(handlers)
  }
  delete(self.event_handlers)

  // Clean up pipeline resources
  vk.DestroyPipeline(gctx.device, self.pipeline, nil)
  vk.DestroyPipelineLayout(gctx.device, self.pipeline_layout, nil)
  vk.DestroyDescriptorSetLayout(gctx.device, self.projection_layout, nil)

  // Clean up text resources
  fs.Destroy(&self.font_ctx)
  gpu.mutable_buffer_destroy(gctx.device, &self.text_vertex_buffer)
  gpu.mutable_buffer_destroy(gctx.device, &self.text_index_buffer)
}

element_destroy :: proc(element: ^Element) {
  switch &data in element.data {
  case Quad2D:
  // Nothing to clean up
  case Text2D:
  // Nothing to clean up (string is not owned)
  case Mesh2D:
    delete(data.vertices)
    delete(data.indices)
  }
}

// =============================================================================
// Update and Render
// =============================================================================

update :: proc(self: ^Manager, frame_index: u32) {
  self.current_frame = frame_index

  // Run layout if dirty
  run_layout(self)

  // Rebuild draw lists
  rebuild_draw_lists(self)
}

rebuild_draw_lists :: proc(self: ^Manager) {
  // Clear all draw lists
  for &dl in self.draw_lists {
    clear(&dl.commands)
  }

  // Build commands for all root flexboxes and their children
  for handle in self.root_flexboxes {
    build_flexbox_commands(self, handle)
  }
}

build_flexbox_commands :: proc(self: ^Manager, handle: FlexBoxHandle) {
  fb, found := cont.get(self.flexboxes, handle)
  if !found do return
  if !fb.visible do return

  // Add background rect if visible
  if fb.bg_color.a > 0 {
    for &dl in self.draw_lists {
      append(
        &dl.commands,
        DrawCommand {
          type = .RECT,
          rect = fb.computed_rect,
          color = fb.bg_color,
          uv = {0, 0, 1, 1},
          z = fb.z_order,
        },
      )
    }
  }

  // Add border if visible
  if fb.border_width > 0 && fb.border_color.a > 0 {
    build_border_commands(
      self,
      fb.computed_rect,
      fb.border_color,
      fb.border_width,
      fb.z_order,
    )
  }

  // Build commands for children
  for child in fb.children {
    switch c in child {
    case ElementHandle:
      build_element_commands(self, c)
    case FlexBoxHandle:
      build_flexbox_commands(self, c)
    }
  }
}

build_border_commands :: proc(
  self: ^Manager,
  rect: [4]f32,
  color: [4]u8,
  width: f32,
  z: f32,
) {
  // Top border
  for &dl in self.draw_lists {
    append(
      &dl.commands,
      DrawCommand {
        type = .RECT,
        rect = {rect.x, rect.y, rect.z, width},
        color = color,
        uv = {0, 0, 1, 1},
        z = z,
      },
    )
    // Bottom border
    append(
      &dl.commands,
      DrawCommand {
        type = .RECT,
        rect = {rect.x, rect.y + rect.w - width, rect.z, width},
        color = color,
        uv = {0, 0, 1, 1},
        z = z,
      },
    )
    // Left border
    append(
      &dl.commands,
      DrawCommand {
        type = .RECT,
        rect = {rect.x, rect.y, width, rect.w},
        color = color,
        uv = {0, 0, 1, 1},
        z = z,
      },
    )
    // Right border
    append(
      &dl.commands,
      DrawCommand {
        type = .RECT,
        rect = {rect.x + rect.z - width, rect.y, width, rect.w},
        color = color,
        uv = {0, 0, 1, 1},
        z = z,
      },
    )
  }
}

build_element_commands :: proc(self: ^Manager, handle: ElementHandle) {
  element, found := cont.get(self.elements, handle)
  if !found do return

  switch &data in element.data {
  case Quad2D:
    if !data.visible do return
    build_quad_commands(self, &data)
  case Text2D:
    if !data.visible do return
    build_text_commands(self, &data)
  case Mesh2D:
    if !data.visible do return
    build_mesh_commands(self, &data)
  }
}

build_quad_commands :: proc(self: ^Manager, quad: ^Quad2D) {
  texture_id := quad.texture.index
  if texture_id == 0 {
    texture_id = self.atlas_handle.index // Use white texture for solid color
  }

  for &dl in self.draw_lists {
    append(
      &dl.commands,
      DrawCommand {
        type = .IMAGE,
        rect = quad.computed_rect,
        color = quad.color,
        texture_id = texture_id,
        uv = quad.uv_rect,
        z = quad.z_order,
        transform = quad.world_transform.mat,
      },
    )
  }
}

build_text_commands :: proc(self: ^Manager, text: ^Text2D) {
  if len(text.text) == 0 do return

  for &dl in self.draw_lists {
    append(
      &dl.commands,
      DrawCommand {
        type = .TEXT,
        rect = {
          text.computed_rect.x,
          text.computed_rect.y,
          text.computed_rect.z,
          text.font_size,
        },
        color = text.color,
        text = text.text,
        text_align = text.alignment,
        z = text.z_order,
      },
    )
  }
}

build_mesh_commands :: proc(self: ^Manager, mesh: ^Mesh2D) {
  if len(mesh.vertices) == 0 do return

  texture_id := mesh.texture.index
  if texture_id == 0 {
    texture_id = self.atlas_handle.index
  }

  for &dl in self.draw_lists {
    append(
      &dl.commands,
      DrawCommand {
        type = .MESH,
        rect = mesh.computed_rect,
        color = WHITE,
        texture_id = texture_id,
        z = mesh.z_order,
        vertices = mesh.vertices[:],
        indices = mesh.indices[:],
        transform = mesh.world_transform.mat,
      },
    )
  }
}

begin_pass :: proc(
  self: ^Manager,
  command_buffer: vk.CommandBuffer,
  color_view: vk.ImageView,
  extent: vk.Extent2D,
) {
  gpu.begin_rendering(
    command_buffer,
    extent.width,
    extent.height,
    nil,
    gpu.create_color_attachment_view(color_view, .LOAD, .STORE),
  )
}

end_pass :: proc(command_buffer: vk.CommandBuffer) {
  vk.CmdEndRendering(command_buffer)
}

flush_ui_batch :: proc(
  self: ^Manager,
  command_buffer: vk.CommandBuffer,
  frame_index: u32,
  draw_list: ^DrawList,
  rm: ^resources.Manager,
) -> vk.Result {
  new_vertex_count := draw_list.vertex_count - draw_list.cumulative_vertices
  new_index_count := draw_list.index_count - draw_list.cumulative_indices

  if new_vertex_count == 0 {
    return .SUCCESS
  }

  gpu.write(
    &self.vertex_buffers[frame_index],
    draw_list.vertices[:draw_list.vertex_count],
  ) or_return
  gpu.write(
    &self.index_buffers[frame_index],
    draw_list.indices[:draw_list.index_count],
  ) or_return

  gpu.bind_graphics_pipeline(
    command_buffer,
    self.pipeline,
    self.pipeline_layout,
    self.projection_descriptor_set,
    rm.textures_descriptor_set,
  )

  gpu.set_viewport_scissor(command_buffer, self.frame_width, self.frame_height)

  offsets := [?]vk.DeviceSize{0}
  vk.CmdBindVertexBuffers(
    command_buffer,
    0,
    1,
    &self.vertex_buffers[frame_index].buffer,
    raw_data(offsets[:]),
  )
  vk.CmdBindIndexBuffer(
    command_buffer,
    self.index_buffers[frame_index].buffer,
    0,
    .UINT32,
  )

  first_index := draw_list.cumulative_indices
  vk.CmdDrawIndexed(command_buffer, new_index_count, 1, first_index, 0, 0)

  draw_list.cumulative_vertices = draw_list.vertex_count
  draw_list.cumulative_indices = draw_list.index_count

  return .SUCCESS
}

render :: proc(
  self: ^Manager,
  command_buffer: vk.CommandBuffer,
  frame_index: u32,
  rm: ^resources.Manager,
  gctx: ^gpu.GPUContext,
) -> vk.Result {
  draw_list := &self.draw_lists[frame_index]
  if len(draw_list.commands) == 0 do return .SUCCESS

  draw_list.vertex_count = 0
  draw_list.index_count = 0
  draw_list.cumulative_vertices = 0
  draw_list.cumulative_indices = 0
  self.text_vertex_count = 0
  self.text_index_count = 0
  self.text_cumulative_vertex_count = 0
  self.text_cumulative_index_count = 0

  // Sort by z (higher z = behind = render first)
  slice.stable_sort_by(draw_list.commands[:], proc(a, b: DrawCommand) -> bool {
    return a.z > b.z
  })

  current_z: f32 = 999.0
  for cmd in draw_list.commands {
    if cmd.z < current_z {
      flush_ui_batch(
        self,
        command_buffer,
        frame_index,
        draw_list,
        rm,
      ) or_return
      flush_text(self, command_buffer, rm) or_return
      current_z = cmd.z
    }

    switch cmd.type {
    case .RECT:
      push_quad(
        draw_list,
        {cmd.rect.x, cmd.rect.y, cmd.rect.z, cmd.rect.w},
        cmd.uv,
        cmd.color,
        self.atlas_handle.index,
        cmd.z,
      )
    case .IMAGE:
      push_quad(
        draw_list,
        {cmd.rect.x, cmd.rect.y, cmd.rect.z, cmd.rect.w},
        cmd.uv,
        cmd.color,
        cmd.texture_id,
        cmd.z,
      )
    case .TEXT:
      baseline_offset := cmd.rect.w * 0.75
      draw_text_internal(
        self,
        cmd.text,
        cmd.rect.x,
        cmd.rect.y + baseline_offset,
        cmd.rect.w,
        cmd.color,
        cmd.z,
        cmd.text_align,
        cmd.rect,
        cmd.text_suffix,
      )
    case .MESH:
      push_mesh(
        draw_list,
        cmd.vertices,
        cmd.indices,
        cmd.transform,
        cmd.texture_id,
        cmd.z,
      )
    case .CLIP:
    }
  }

  flush_ui_batch(self, command_buffer, frame_index, draw_list, rm) or_return
  flush_text(self, command_buffer, rm) or_return

  return .SUCCESS
}

push_quad :: proc(
  draw_list: ^DrawList,
  rect: [4]f32,
  uv: [4]f32,
  color: [4]u8,
  texture_id: u32 = 0,
  z: f32 = 0.0,
) {
  if draw_list.vertex_count + 4 > UI_MAX_VERTICES ||
     draw_list.index_count + 6 > UI_MAX_INDICES {
    log.warnf(
      "push_quad: buffer full! vertex_count=%d, index_count=%d",
      draw_list.vertex_count,
      draw_list.index_count,
    )
    return
  }

  x, y, w, h := rect.x, rect.y, rect.z, rect.w
  u0, v0, u1, v1 := uv.x, uv.y, uv.z, uv.w

  draw_list.vertices[draw_list.vertex_count + 0] = {
    pos        = {x, y},
    uv         = {u0, v0},
    color      = color,
    texture_id = texture_id,
    z          = z,
  }
  draw_list.vertices[draw_list.vertex_count + 1] = {
    pos        = {x + w, y},
    uv         = {u1, v0},
    color      = color,
    texture_id = texture_id,
    z          = z,
  }
  draw_list.vertices[draw_list.vertex_count + 2] = {
    pos        = {x + w, y + h},
    uv         = {u1, v1},
    color      = color,
    texture_id = texture_id,
    z          = z,
  }
  draw_list.vertices[draw_list.vertex_count + 3] = {
    pos        = {x, y + h},
    uv         = {u0, v1},
    color      = color,
    texture_id = texture_id,
    z          = z,
  }

  vertex_base := u32(draw_list.vertex_count)
  draw_list.indices[draw_list.index_count + 0] = vertex_base + 0
  draw_list.indices[draw_list.index_count + 1] = vertex_base + 1
  draw_list.indices[draw_list.index_count + 2] = vertex_base + 2
  draw_list.indices[draw_list.index_count + 3] = vertex_base + 2
  draw_list.indices[draw_list.index_count + 4] = vertex_base + 3
  draw_list.indices[draw_list.index_count + 5] = vertex_base + 0

  draw_list.index_count += 6
  draw_list.vertex_count += 4
}

push_mesh :: proc(
  draw_list: ^DrawList,
  vertices: []Mesh2DVertex,
  indices: []u32,
  transform: matrix[3, 3]f32,
  texture_id: u32,
  z: f32,
) {
  vertex_count := u32(len(vertices))
  index_count := u32(len(indices))

  if index_count == 0 {
    // If no indices, treat as triangle list
    index_count = vertex_count
  }

  if draw_list.vertex_count + vertex_count > UI_MAX_VERTICES ||
     draw_list.index_count + index_count > UI_MAX_INDICES {
    log.warnf("push_mesh: buffer full!")
    return
  }

  vertex_base := draw_list.vertex_count

  // Transform and add vertices
  for v in vertices {
    // Apply transform to position
    pos3 := transform * [3]f32{v.pos.x, v.pos.y, 1}
    transformed_pos := [2]f32{pos3.x, pos3.y}

    draw_list.vertices[draw_list.vertex_count] = {
      pos        = transformed_pos,
      uv         = v.uv,
      color      = v.color,
      texture_id = texture_id,
      z          = z,
    }
    draw_list.vertex_count += 1
  }

  // Add indices
  if len(indices) > 0 {
    for idx in indices {
      draw_list.indices[draw_list.index_count] = u32(vertex_base) + idx
      draw_list.index_count += 1
    }
  } else {
    // Generate indices for triangle list
    for i in 0 ..< vertex_count {
      draw_list.indices[draw_list.index_count] = u32(vertex_base) + u32(i)
      draw_list.index_count += 1
    }
  }
}

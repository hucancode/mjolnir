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
  cont.init(&self.widgets, 1000)
  self.root_widgets = make([dynamic]WidgetHandle, 0, 100)
  self.dirty_widgets = make([dynamic]WidgetHandle, 0, 100)
  for &v in self.draw_lists {
    v.commands = make([dynamic]DrawCommand, 0, 1000)
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
  shader_stages := [?]vk.PipelineShaderStageCreateInfo {
    {
      sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
      stage = {.VERTEX},
      module = vert_shader_module,
      pName = "main",
    },
    {
      sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
      stage = {.FRAGMENT},
      module = frag_shader_module,
      pName = "main",
    },
  }
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
    pNext               = &gpu.STANDARD_RENDERING_INFO,
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
  self.atlas_handle, self.atlas = resources.create_texture_from_pixels(
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
    {
      type = .UNIFORM_BUFFER,
      info = gpu.buffer_info(&self.proj_buffer),
    },
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
  self.text_atlas_handle, _ = resources.create_texture_from_pixels(
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
  for i in 0 ..< FRAMES_IN_FLIGHT {
    gpu.mutable_buffer_destroy(gctx.device, &self.vertex_buffers[i])
    gpu.mutable_buffer_destroy(gctx.device, &self.index_buffers[i])
    delete(self.draw_lists[i].commands)
  }
  gpu.mutable_buffer_destroy(gctx.device, &self.proj_buffer)
  delete(self.root_widgets)
  delete(self.dirty_widgets)
  cont.destroy(self.widgets, widget_destroy)
  vk.DestroyPipeline(gctx.device, self.pipeline, nil)
  vk.DestroyPipelineLayout(gctx.device, self.pipeline_layout, nil)
  vk.DestroyDescriptorSetLayout(gctx.device, self.projection_layout, nil)
  fs.Destroy(&self.font_ctx)
  gpu.mutable_buffer_destroy(gctx.device, &self.text_vertex_buffer)
  gpu.mutable_buffer_destroy(gctx.device, &self.text_index_buffer)
}

widget_destroy :: proc(widget: ^Widget) {
  switch &data in widget.data {
  case ButtonData:
  case LabelData:
  case ImageData:
  case TextBoxData:
    delete(data.text)
  case ComboBoxData:
  case CheckBoxData:
  case RadioButtonData:
  case WindowData:
  }
}

create_widget :: proc(
  self: ^Manager,
  type: WidgetType,
  parent: WidgetHandle = {},
) -> (
  handle: WidgetHandle,
  widget: ^Widget,
  ok: bool,
) {
  handle, widget, ok = cont.alloc(&self.widgets)
  if !ok do return
  widget.type = type
  widget.parent = parent
  widget.visible = true
  widget.enabled = true
  widget.dirty = false
  widget.bg_color = WIDGET_DEFAULT_BG
  widget.fg_color = WIDGET_DEFAULT_FG
  widget.border_color = WIDGET_DEFAULT_BORDER
  widget.border_width = 1.0
  if parent_widget, found := cont.get(self.widgets, parent); found {
    if parent_widget.last_child.index != 0 {
      last_child, _ := cont.get(self.widgets, parent_widget.last_child)
      last_child.next_sibling = handle
      widget.prev_sibling = parent_widget.last_child
    } else {
      parent_widget.first_child = handle
    }
    parent_widget.last_child = handle
  } else {
    append(&self.root_widgets, handle)
  }
  mark_dirty(self, handle)
  return
}

mark_dirty :: proc(self: ^Manager, handle: WidgetHandle) {
  widget, found := cont.get(self.widgets, handle)
  if !found do return
  if !widget.dirty {
    widget.dirty = true
    append(&self.dirty_widgets, handle)
  }
}

rebuild_draw_lists :: proc(self: ^Manager) {
  if len(self.dirty_widgets) == 0 do return
  when ODIN_DEBUG {
    log.debugf(
      "Rebuilding draw lists for %d dirty widget(s)",
      len(self.dirty_widgets),
    )
  }
  for dirty_handle in self.dirty_widgets {
    for &v in self.draw_lists {
      remove_widget_commands(&v, dirty_handle)
    }
  }
  for dirty_handle in self.dirty_widgets {
    widget, found := cont.get(self.widgets, dirty_handle)
    if !found do continue
    if widget.visible {
      build_widget_draw_commands(self, dirty_handle)
    } else {
      widget.dirty = false
    }
  }
  clear(&self.dirty_widgets)
}

remove_widget_commands :: proc(draw_list: ^DrawList, handle: WidgetHandle) {
  for i := len(draw_list.commands) - 1; i >= 0; i -= 1 {
    if draw_list.commands[i].widget == handle {
      ordered_remove(&draw_list.commands, i)
    }
  }
}

update :: proc(self: ^Manager, frame_index: u32) {
  self.current_frame = frame_index
  rebuild_draw_lists(self)
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

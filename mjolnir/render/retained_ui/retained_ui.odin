package retained_ui

import gpu "../../gpu"
import resources "../../resources"
import text "../text"
import "core:log"
import "core:math/linalg"
import vk "vendor:vulkan"

MAX_FRAMES_IN_FLIGHT :: resources.MAX_FRAMES_IN_FLIGHT
SHADER_UI_VERT :: #load("../../shader/microui/vert.spv")
SHADER_UI_FRAG :: #load("../../shader/microui/frag.spv")

UI_MAX_QUAD :: 2000
UI_MAX_VERTICES :: UI_MAX_QUAD * 4
UI_MAX_INDICES :: UI_MAX_QUAD * 6

// ============================================================================
// Core Types
// ============================================================================

WidgetType :: enum {
  BUTTON,
  LABEL,
  IMAGE,
  TEXT_BOX,
  COMBO_BOX,
  CHECK_BOX,
  RADIO_BUTTON,
  WINDOW,
}

WidgetHandle :: resources.Handle

// ============================================================================
// Widget Data Structures
// ============================================================================

ButtonData :: struct {
  text:      string,
  callback:  proc(ctx: rawptr),
  user_data: rawptr,
  hovered:   bool,
  pressed:   bool,
}

LabelData :: struct {
  text: string,
}

ImageData :: struct {
  texture_handle: resources.Handle,
  texture_id:     u32,
  uv:             [4]f32, // u0, v0, u1, v1 for sprite animation
  sprite_index:   u32,
  sprite_count:   u32,
}

TextBoxData :: struct {
  text:        string,
  max_length:  u32,
  placeholder: string,
  focused:     bool,
}

ComboBoxData :: struct {
  items:         []string,
  selected:      i32,
  expanded:      bool,
}

CheckBoxData :: struct {
  checked:  bool,
  label:    string,
}

RadioButtonData :: struct {
  group_id: u32,
  selected: bool,
  label:    string,
}

WindowData :: struct {
  title:       string,
  closeable:   bool,
  moveable:    bool,
  resizeable:  bool,
  minimized:   bool,
}

WidgetData :: union {
  ButtonData,
  LabelData,
  ImageData,
  TextBoxData,
  ComboBoxData,
  CheckBoxData,
  RadioButtonData,
  WindowData,
}

// ============================================================================
// Widget Structure
// ============================================================================

Widget :: struct {
  type:         WidgetType,

  // Tree structure
  parent:       WidgetHandle,
  first_child:  WidgetHandle,
  last_child:   WidgetHandle,
  next_sibling: WidgetHandle,
  prev_sibling: WidgetHandle,

  // Layout
  position:     [2]f32,  // absolute screen position
  size:         [2]f32,
  anchor:       [2]f32,  // 0-1 for alignment within parent

  // Visual state
  visible:      bool,
  enabled:      bool,
  dirty:        bool,    // needs draw list rebuild

  // Styling
  bg_color:     [4]u8,
  fg_color:     [4]u8,
  border_color: [4]u8,
  border_width: f32,

  // Widget-specific data
  data:         WidgetData,
}

// ============================================================================
// Draw Command System
// ============================================================================

DrawCommandType :: enum {
  RECT,
  TEXT,
  IMAGE,
  CLIP,
}

DrawCommand :: struct {
  type:       DrawCommandType,
  widget:     WidgetHandle,

  // Unified data for all command types
  rect:       [4]f32,  // x, y, w, h
  color:      [4]u8,
  texture_id: u32,
  uv:         [4]f32,  // texture coordinates
  text:       string,
  clip_rect:  [4]i32,  // scissor rectangle
}

Vertex2D :: struct {
  pos:   [2]f32,
  uv:    [2]f32,
  color: [4]u8,
}

DrawList :: struct {
  commands:     [dynamic]DrawCommand,
  vertices:     [UI_MAX_VERTICES]Vertex2D,
  indices:      [UI_MAX_INDICES]u32,
  vertex_count: u32,
  index_count:  u32,
}

// ============================================================================
// UI Manager
// ============================================================================

Manager :: struct {
  // Widget storage
  widgets:          resources.Pool(Widget),
  root_widgets:     [dynamic]WidgetHandle,

  // Draw lists (one per frame in flight)
  draw_lists:       [MAX_FRAMES_IN_FLIGHT]DrawList,
  current_frame:    u32,

  // Dirty tracking for incremental updates
  dirty_widgets:    [dynamic]WidgetHandle,

  // Input state
  mouse_pos:        [2]f32,
  mouse_down:       bool,
  mouse_clicked:    bool,
  mouse_released:   bool,

  // Text rendering
  text_renderer:    ^text.Renderer,

  // Rendering resources
  projection_layout:         vk.DescriptorSetLayout,
  projection_descriptor_set: vk.DescriptorSet,
  texture_layout:            vk.DescriptorSetLayout,
  texture_descriptor_set:    vk.DescriptorSet,
  pipeline_layout:           vk.PipelineLayout,
  pipeline:                  vk.Pipeline,
  atlas:                     ^gpu.Image,
  proj_buffer:               gpu.MutableBuffer(matrix[4, 4]f32),
  vertex_buffers:            [MAX_FRAMES_IN_FLIGHT]gpu.MutableBuffer(Vertex2D),
  index_buffers:             [MAX_FRAMES_IN_FLIGHT]gpu.MutableBuffer(u32),

  // Screen dimensions
  frame_width:      u32,
  frame_height:     u32,
  dpi_scale:        f32,
}

// ============================================================================
// Initialization
// ============================================================================

init :: proc(
  self: ^Manager,
  gctx: ^gpu.GPUContext,
  color_format: vk.Format,
  width, height: u32,
  dpi_scale: f32 = 1.0,
  rm: ^resources.Manager,
  text_renderer: ^text.Renderer,
) -> vk.Result {
  self.text_renderer = text_renderer
  resources.pool_init(&self.widgets, 1000)
  self.root_widgets = make([dynamic]WidgetHandle, 0, 100)
  self.dirty_widgets = make([dynamic]WidgetHandle, 0, 100)

  for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
    self.draw_lists[i].commands = make([dynamic]DrawCommand, 0, 1000)
  }

  self.frame_width = width
  self.frame_height = height
  self.dpi_scale = dpi_scale

  // Initialize rendering pipeline
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

  dynamic_states := [?]vk.DynamicState{.VIEWPORT, .SCISSOR}
  dynamic_state_info := vk.PipelineDynamicStateCreateInfo {
    sType             = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
    dynamicStateCount = len(dynamic_states),
    pDynamicStates    = raw_data(dynamic_states[:]),
  }

  vertex_binding := vk.VertexInputBindingDescription {
    binding   = 0,
    stride    = size_of(Vertex2D),
    inputRate = .VERTEX,
  }

  vertex_attributes := [?]vk.VertexInputAttributeDescription {
    {
      binding  = 0,
      location = 0,
      format   = .R32G32_SFLOAT,
      offset   = u32(offset_of(Vertex2D, pos)),
    },
    {
      binding  = 0,
      location = 1,
      format   = .R32G32_SFLOAT,
      offset   = u32(offset_of(Vertex2D, uv)),
    },
    {
      binding  = 0,
      location = 2,
      format   = .R8G8B8A8_UNORM,
      offset   = u32(offset_of(Vertex2D, color)),
    },
  }

  vertex_input := vk.PipelineVertexInputStateCreateInfo {
    sType                           = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
    vertexBindingDescriptionCount   = 1,
    pVertexBindingDescriptions      = &vertex_binding,
    vertexAttributeDescriptionCount = len(vertex_attributes),
    pVertexAttributeDescriptions    = raw_data(vertex_attributes[:]),
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

  // Descriptor sets for projection and texture
  projection_layout_info := vk.DescriptorSetLayoutCreateInfo {
    sType        = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
    bindingCount = 1,
    pBindings    = &vk.DescriptorSetLayoutBinding {
      binding = 0,
      descriptorType = .UNIFORM_BUFFER,
      descriptorCount = 1,
      stageFlags = {.VERTEX},
    },
  }

  vk.CreateDescriptorSetLayout(
    gctx.device,
    &projection_layout_info,
    nil,
    &self.projection_layout,
  ) or_return

  vk.AllocateDescriptorSets(
    gctx.device,
    &{
      sType = .DESCRIPTOR_SET_ALLOCATE_INFO,
      descriptorPool = gctx.descriptor_pool,
      descriptorSetCount = 1,
      pSetLayouts = &self.projection_layout,
    },
    &self.projection_descriptor_set,
  ) or_return

  vk.CreateDescriptorSetLayout(
    gctx.device,
    &vk.DescriptorSetLayoutCreateInfo {
      sType = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
      bindingCount = 1,
      pBindings = &vk.DescriptorSetLayoutBinding {
        binding = 0,
        descriptorType = .COMBINED_IMAGE_SAMPLER,
        descriptorCount = 1,
        stageFlags = {.FRAGMENT},
      },
    },
    nil,
    &self.texture_layout,
  ) or_return

  vk.AllocateDescriptorSets(
    gctx.device,
    &{
      sType = .DESCRIPTOR_SET_ALLOCATE_INFO,
      descriptorPool = gctx.descriptor_pool,
      descriptorSetCount = 1,
      pSetLayouts = &self.texture_layout,
    },
    &self.texture_descriptor_set,
  ) or_return

  set_layouts := [?]vk.DescriptorSetLayout {
    self.projection_layout,
    self.texture_layout,
  }

  vk.CreatePipelineLayout(
    gctx.device,
    &{
      sType = .PIPELINE_LAYOUT_CREATE_INFO,
      setLayoutCount = len(set_layouts),
      pSetLayouts = raw_data(set_layouts[:]),
    },
    nil,
    &self.pipeline_layout,
  ) or_return

  color_formats := [?]vk.Format{color_format}
  rendering_info_khr := vk.PipelineRenderingCreateInfoKHR {
    sType                   = .PIPELINE_RENDERING_CREATE_INFO,
    colorAttachmentCount    = len(color_formats),
    pColorAttachmentFormats = raw_data(color_formats[:]),
  }

  depth_stencil_state := vk.PipelineDepthStencilStateCreateInfo {
    sType = .PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
  }

  pipeline_info := vk.GraphicsPipelineCreateInfo {
    sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
    pNext               = &rendering_info_khr,
    stageCount          = len(shader_stages),
    pStages             = raw_data(shader_stages[:]),
    pVertexInputState   = &vertex_input,
    pInputAssemblyState = &input_assembly,
    pViewportState      = &viewport_state,
    pRasterizationState = &rasterizer,
    pMultisampleState   = &multisampling,
    pColorBlendState    = &color_blending,
    pDynamicState       = &dynamic_state_info,
    pDepthStencilState  = &depth_stencil_state,
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

  // Create white 1x1 texture as default
  log.infof("init UI default texture...")
  white_pixel := [4]u8{255, 255, 255, 255}
  _, self.atlas = resources.create_texture_from_pixels(
    gctx,
    rm,
    white_pixel[:],
    1,
    1,
    .R8G8B8A8_UNORM,
  ) or_return

  // Create buffers for each frame in flight
  log.infof("init UI buffers...")
  for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
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

  // Projection matrix
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

  // Update descriptor sets
  buffer_info := vk.DescriptorBufferInfo {
    buffer = self.proj_buffer.buffer,
    range  = size_of(matrix[4, 4]f32),
  }

  writes := [?]vk.WriteDescriptorSet {
    {
      sType = .WRITE_DESCRIPTOR_SET,
      dstSet = self.projection_descriptor_set,
      dstBinding = 0,
      descriptorCount = 1,
      descriptorType = .UNIFORM_BUFFER,
      pBufferInfo = &buffer_info,
    },
    {
      sType = .WRITE_DESCRIPTOR_SET,
      dstSet = self.texture_descriptor_set,
      dstBinding = 0,
      descriptorCount = 1,
      descriptorType = .COMBINED_IMAGE_SAMPLER,
      pImageInfo = &{
        sampler = rm.nearest_clamp_sampler,
        imageView = self.atlas.view,
        imageLayout = .SHADER_READ_ONLY_OPTIMAL,
      },
    },
  }

  vk.UpdateDescriptorSets(
    gctx.device,
    len(writes),
    raw_data(writes[:]),
    0,
    nil,
  )

  log.infof("retained UI initialized")
  return .SUCCESS
}

shutdown :: proc(self: ^Manager, device: vk.Device) {
  for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
    gpu.mutable_buffer_destroy(device, &self.vertex_buffers[i])
    gpu.mutable_buffer_destroy(device, &self.index_buffers[i])
    delete(self.draw_lists[i].commands)
  }

  gpu.mutable_buffer_destroy(device, &self.proj_buffer)

  delete(self.root_widgets)
  delete(self.dirty_widgets)

  resources.pool_destroy(self.widgets, widget_deinit)

  vk.DestroyPipeline(device, self.pipeline, nil)
  vk.DestroyPipelineLayout(device, self.pipeline_layout, nil)
  vk.DestroyDescriptorSetLayout(device, self.projection_layout, nil)
  vk.DestroyDescriptorSetLayout(device, self.texture_layout, nil)
}

widget_deinit :: proc(widget: ^Widget) {
  // Cleanup widget-specific data
  switch &data in widget.data {
  case ButtonData:
    // Button data cleanup if needed
  case LabelData:
    // Label data cleanup if needed
  case ImageData:
    // Image data cleanup if needed
  case TextBoxData:
    // TextBox data cleanup if needed
  case ComboBoxData:
    // ComboBox data cleanup if needed
  case CheckBoxData:
    // CheckBox data cleanup if needed
  case RadioButtonData:
    // RadioButton data cleanup if needed
  case WindowData:
    // Window data cleanup if needed
  }
}

// ============================================================================
// Widget Management
// ============================================================================

create_widget :: proc(
  self: ^Manager,
  type: WidgetType,
  parent: WidgetHandle = {},
) -> (
  handle: WidgetHandle,
  widget: ^Widget,
  ok: bool,
) {
  handle, widget, ok = resources.alloc(&self.widgets)
  if !ok do return

  widget.type = type
  widget.parent = parent
  widget.visible = true
  widget.enabled = true
  widget.dirty = false  // Start as clean, mark_dirty will set to true
  widget.bg_color = {200, 200, 200, 255}
  widget.fg_color = {0, 0, 0, 255}
  widget.border_color = {100, 100, 100, 255}
  widget.border_width = 1.0

  if parent_widget, found := resources.get(self.widgets, parent); found {
    if parent_widget.last_child.index != 0 {
      last_child, _ := resources.get(self.widgets, parent_widget.last_child)
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

destroy_widget :: proc(self: ^Manager, handle: WidgetHandle) {
  widget, found := resources.get(self.widgets, handle)
  if !found do return

  child := widget.first_child
  for child.index != 0 {
    next_child, _ := resources.get(self.widgets, child)
    next := next_child.next_sibling
    destroy_widget(self, child)
    child = next
  }

  if parent_widget, found := resources.get(self.widgets, widget.parent); found {
    if parent_widget.first_child == handle {
      parent_widget.first_child = widget.next_sibling
    }
    if parent_widget.last_child == handle {
      parent_widget.last_child = widget.prev_sibling
    }
  } else {
    for root_widget, i in self.root_widgets {
      if root_widget == handle {
        ordered_remove(&self.root_widgets, i)
        break
      }
    }
  }

  if prev, found := resources.get(self.widgets, widget.prev_sibling); found {
    prev.next_sibling = widget.next_sibling
  }
  if next, found := resources.get(self.widgets, widget.next_sibling); found {
    next.prev_sibling = widget.prev_sibling
  }

  resources.free(&self.widgets, handle)
}

mark_dirty :: proc(self: ^Manager, handle: WidgetHandle) {
  widget, found := resources.get(self.widgets, handle)
  if !found do return

  if !widget.dirty {
    widget.dirty = true
    append(&self.dirty_widgets, handle)
  }
}

set_position :: proc(self: ^Manager, handle: WidgetHandle, x, y: f32) {
  widget, found := resources.get(self.widgets, handle)
  if !found do return
  widget.position = {x, y}
  mark_dirty(self, handle)
}

set_size :: proc(self: ^Manager, handle: WidgetHandle, w, h: f32) {
  widget, found := resources.get(self.widgets, handle)
  if !found do return
  widget.size = {w, h}
  mark_dirty(self, handle)
}

set_visible :: proc(self: ^Manager, handle: WidgetHandle, visible: bool) {
  widget, found := resources.get(self.widgets, handle)
  if !found do return
  widget.visible = visible
  mark_dirty(self, handle)
}

// ============================================================================
// Draw List Management
// ============================================================================

rebuild_draw_lists :: proc(self: ^Manager) {
  if len(self.dirty_widgets) == 0 do return

  for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
    clear(&self.draw_lists[i].commands)
    self.draw_lists[i].vertex_count = 0
    self.draw_lists[i].index_count = 0
  }

  for root_handle in self.root_widgets {
    build_widget_draw_commands(self, root_handle)
  }

  clear(&self.dirty_widgets)
}

build_widget_draw_commands :: proc(self: ^Manager, handle: WidgetHandle) {
  widget, found := resources.get(self.widgets, handle)
  if !found || !widget.visible do return

  for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
    switch widget.type {
    case .BUTTON:
      build_button_commands(self, &self.draw_lists[i], handle, widget)
    case .LABEL:
      build_label_commands(self, &self.draw_lists[i], handle, widget)
    case .IMAGE:
      build_image_commands(self, &self.draw_lists[i], handle, widget)
    case .WINDOW:
      build_window_commands(self, &self.draw_lists[i], handle, widget)
    case .TEXT_BOX, .COMBO_BOX, .CHECK_BOX, .RADIO_BUTTON:
      // Not implemented in first version
    }
  }

  child := widget.first_child
  for child.index != 0 {
    build_widget_draw_commands(self, child)
    child_widget, _ := resources.get(self.widgets, child)
    child = child_widget.next_sibling
  }

  widget.dirty = false
}

build_button_commands :: proc(
  self: ^Manager,
  draw_list: ^DrawList,
  handle: WidgetHandle,
  widget: ^Widget,
) {
  data := widget.data.(ButtonData)

  bg_color := widget.bg_color
  if data.pressed {
    bg_color = {u8(widget.bg_color.r / 2), u8(widget.bg_color.g / 2), u8(widget.bg_color.b / 2), widget.bg_color.a}
  } else if data.hovered {
    bg_color = {min(widget.bg_color.r + 30, 255), min(widget.bg_color.g + 30, 255), min(widget.bg_color.b + 30, 255), widget.bg_color.a}
  }

  append(
    &draw_list.commands,
    DrawCommand {
      type = .RECT,
      widget = handle,
      rect = {widget.position.x, widget.position.y, widget.size.x, widget.size.y},
      color = bg_color,
      uv = {0, 0, 1, 1},
    },
  )

  append(
    &draw_list.commands,
    DrawCommand {
      type = .TEXT,
      widget = handle,
      rect = {widget.position.x + 10, widget.position.y + 10, widget.size.x - 20, widget.size.y - 20},
      color = widget.fg_color,
      text = data.text,
    },
  )
}

build_label_commands :: proc(
  self: ^Manager,
  draw_list: ^DrawList,
  handle: WidgetHandle,
  widget: ^Widget,
) {
  data := widget.data.(LabelData)

  append(
    &draw_list.commands,
    DrawCommand {
      type = .TEXT,
      widget = handle,
      rect = {widget.position.x, widget.position.y, widget.size.x, widget.size.y},
      color = widget.fg_color,
      text = data.text,
    },
  )
}

build_image_commands :: proc(
  self: ^Manager,
  draw_list: ^DrawList,
  handle: WidgetHandle,
  widget: ^Widget,
) {
  data := widget.data.(ImageData)

  append(
    &draw_list.commands,
    DrawCommand {
      type = .IMAGE,
      widget = handle,
      rect = {widget.position.x, widget.position.y, widget.size.x, widget.size.y},
      color = {255, 255, 255, 255},
      texture_id = data.texture_id,
      uv = data.uv,
    },
  )
}

build_window_commands :: proc(
  self: ^Manager,
  draw_list: ^DrawList,
  handle: WidgetHandle,
  widget: ^Widget,
) {
  data := widget.data.(WindowData)

  title_bar_height: f32 = 30

  append(
    &draw_list.commands,
    DrawCommand {
      type = .RECT,
      widget = handle,
      rect = {widget.position.x, widget.position.y, widget.size.x, title_bar_height},
      color = {80, 80, 120, 255},
      uv = {0, 0, 1, 1},
    },
  )

  append(
    &draw_list.commands,
    DrawCommand {
      type = .TEXT,
      widget = handle,
      rect = {widget.position.x + 10, widget.position.y + 5, widget.size.x - 20, title_bar_height - 10},
      color = {255, 255, 255, 255},
      text = data.title,
    },
  )

  if !data.minimized {
    append(
      &draw_list.commands,
      DrawCommand {
        type = .RECT,
        widget = handle,
        rect = {widget.position.x, widget.position.y + title_bar_height, widget.size.x, widget.size.y - title_bar_height},
        color = widget.bg_color,
        uv = {0, 0, 1, 1},
      },
    )
  }
}

// ============================================================================
// Input Handling
// ============================================================================

update_input :: proc(self: ^Manager, mouse_x, mouse_y: f32, mouse_down: bool) {
  self.mouse_pos = {mouse_x, mouse_y}

  mouse_clicked := !self.mouse_down && mouse_down
  mouse_released := self.mouse_down && !mouse_down
  self.mouse_clicked = mouse_clicked
  self.mouse_released = mouse_released
  self.mouse_down = mouse_down

  for root_handle in self.root_widgets {
    update_widget_input(self, root_handle)
  }
}

update_widget_input :: proc(self: ^Manager, handle: WidgetHandle) {
  widget, found := resources.get(self.widgets, handle)
  if !found || !widget.visible || !widget.enabled do return

  mx, my := self.mouse_pos.x, self.mouse_pos.y
  wx, wy := widget.position.x, widget.position.y
  ww, wh := widget.size.x, widget.size.y

  hovered := mx >= wx && mx <= wx + ww && my >= wy && my <= wy + wh

  switch widget.type {
  case .BUTTON:
    data := &widget.data.(ButtonData)
    old_hovered := data.hovered
    data.hovered = hovered

    if hovered && self.mouse_clicked {
      data.pressed = true
    }

    if data.pressed && self.mouse_released {
      data.pressed = false
      if hovered && data.callback != nil {
        data.callback(data.user_data)
      }
    }

    if old_hovered != data.hovered || data.pressed {
      mark_dirty(self, handle)
    }

  case .LABEL, .IMAGE, .TEXT_BOX, .COMBO_BOX, .CHECK_BOX, .RADIO_BUTTON, .WINDOW:
    // Input handling for other widgets
  }

  child := widget.first_child
  for child.index != 0 {
    update_widget_input(self, child)
    child_widget, _ := resources.get(self.widgets, child)
    child = child_widget.next_sibling
  }
}

// ============================================================================
// Rendering
// ============================================================================

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
  color_attachment := vk.RenderingAttachmentInfo {
    sType       = .RENDERING_ATTACHMENT_INFO,
    imageView   = color_view,
    imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
    loadOp      = .LOAD,
    storeOp     = .STORE,
  }

  render_info := vk.RenderingInfo {
    sType                = .RENDERING_INFO,
    renderArea           = {extent = extent},
    layerCount           = 1,
    colorAttachmentCount = 1,
    pColorAttachments    = &color_attachment,
  }

  vk.CmdBeginRendering(command_buffer, &render_info)
}

end_pass :: proc(command_buffer: vk.CommandBuffer) {
  vk.CmdEndRendering(command_buffer)
}

render :: proc(
  self: ^Manager,
  command_buffer: vk.CommandBuffer,
  frame_index: u32,
) -> vk.Result {
  draw_list := &self.draw_lists[frame_index]

  if len(draw_list.commands) == 0 do return .SUCCESS

  draw_list.vertex_count = 0
  draw_list.index_count = 0

  for cmd in draw_list.commands {
    switch cmd.type {
    case .RECT:
      push_quad(
        draw_list,
        {cmd.rect.x, cmd.rect.y, cmd.rect.z, cmd.rect.w},
        cmd.uv,
        cmd.color,
      )
    case .TEXT:
      // Flush current batch before drawing text
      if draw_list.vertex_count > 0 {
        gpu.write(&self.vertex_buffers[frame_index], draw_list.vertices[:draw_list.vertex_count]) or_return
        gpu.write(&self.index_buffers[frame_index], draw_list.indices[:draw_list.index_count]) or_return

        vk.CmdBindPipeline(command_buffer, .GRAPHICS, self.pipeline)

        descriptor_sets := [?]vk.DescriptorSet {
          self.projection_descriptor_set,
          self.texture_descriptor_set,
        }

        vk.CmdBindDescriptorSets(
          command_buffer,
          .GRAPHICS,
          self.pipeline_layout,
          0,
          2,
          raw_data(descriptor_sets[:]),
          0,
          nil,
        )

        viewport := vk.Viewport {
          x        = 0,
          y        = f32(self.frame_height),
          width    = f32(self.frame_width),
          height   = -f32(self.frame_height),
          minDepth = 0,
          maxDepth = 1,
        }
        vk.CmdSetViewport(command_buffer, 0, 1, &viewport)

        scissor := vk.Rect2D {
          extent = {self.frame_width, self.frame_height},
        }
        vk.CmdSetScissor(command_buffer, 0, 1, &scissor)

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

        vk.CmdDrawIndexed(command_buffer, draw_list.index_count, 1, 0, 0, 0)

        draw_list.vertex_count = 0
        draw_list.index_count = 0
      }

      // Draw text using the text renderer
      text.draw_text(
        self.text_renderer,
        cmd.text,
        cmd.rect.x,
        cmd.rect.y + 16,  // Baseline offset
        16,  // Font size
        cmd.color,
      )
    case .IMAGE:
      push_quad(
        draw_list,
        {cmd.rect.x, cmd.rect.y, cmd.rect.z, cmd.rect.w},
        cmd.uv,
        cmd.color,
      )
    case .CLIP:
      // Clip handling
    }
  }

  // Flush text renderer
  if self.text_renderer != nil {
    text.flush(self.text_renderer, command_buffer) or_return
  }

  if draw_list.vertex_count == 0 do return .SUCCESS

  gpu.write(&self.vertex_buffers[frame_index], draw_list.vertices[:draw_list.vertex_count]) or_return
  gpu.write(&self.index_buffers[frame_index], draw_list.indices[:draw_list.index_count]) or_return

  vk.CmdBindPipeline(command_buffer, .GRAPHICS, self.pipeline)

  descriptor_sets := [?]vk.DescriptorSet {
    self.projection_descriptor_set,
    self.texture_descriptor_set,
  }

  vk.CmdBindDescriptorSets(
    command_buffer,
    .GRAPHICS,
    self.pipeline_layout,
    0,
    2,
    raw_data(descriptor_sets[:]),
    0,
    nil,
  )

  viewport := vk.Viewport {
    x        = 0,
    y        = f32(self.frame_height),
    width    = f32(self.frame_width),
    height   = -f32(self.frame_height),
    minDepth = 0,
    maxDepth = 1,
  }
  vk.CmdSetViewport(command_buffer, 0, 1, &viewport)

  scissor := vk.Rect2D {
    extent = {self.frame_width, self.frame_height},
  }
  vk.CmdSetScissor(command_buffer, 0, 1, &scissor)

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

  vk.CmdDrawIndexed(command_buffer, draw_list.index_count, 1, 0, 0, 0)

  return .SUCCESS
}

push_quad :: proc(
  draw_list: ^DrawList,
  rect: [4]f32,
  uv: [4]f32,
  color: [4]u8,
) {
  if draw_list.vertex_count + 4 > UI_MAX_VERTICES ||
     draw_list.index_count + 6 > UI_MAX_INDICES {
    return
  }

  x, y, w, h := rect.x, rect.y, rect.z, rect.w
  u0, v0, u1, v1 := uv.x, uv.y, uv.z, uv.w

  draw_list.vertices[draw_list.vertex_count + 0] = {
    pos   = {x, y},
    uv    = {u0, v0},
    color = color,
  }
  draw_list.vertices[draw_list.vertex_count + 1] = {
    pos   = {x + w, y},
    uv    = {u1, v0},
    color = color,
  }
  draw_list.vertices[draw_list.vertex_count + 2] = {
    pos   = {x + w, y + h},
    uv    = {u1, v1},
    color = color,
  }
  draw_list.vertices[draw_list.vertex_count + 3] = {
    pos   = {x, y + h},
    uv    = {u0, v1},
    color = color,
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

// ============================================================================
// Widget Creation Helpers
// ============================================================================

create_button :: proc(
  self: ^Manager,
  text: string,
  x, y, w, h: f32,
  callback: proc(ctx: rawptr) = nil,
  user_data: rawptr = nil,
  parent: WidgetHandle = {},
) -> (
  handle: WidgetHandle,
  ok: bool,
) {
  widget: ^Widget
  handle, widget, ok = create_widget(self, .BUTTON, parent)
  if !ok do return

  widget.position = {x, y}
  widget.size = {w, h}
  widget.data = ButtonData {
    text      = text,
    callback  = callback,
    user_data = user_data,
  }

  return
}

create_label :: proc(
  self: ^Manager,
  text: string,
  x, y: f32,
  parent: WidgetHandle = {},
) -> (
  handle: WidgetHandle,
  ok: bool,
) {
  widget: ^Widget
  handle, widget, ok = create_widget(self, .LABEL, parent)
  if !ok do return

  widget.position = {x, y}
  widget.size = {100, 20}
  widget.fg_color = {255, 255, 255, 255}
  widget.data = LabelData {
    text = text,
  }

  return
}

create_image :: proc(
  self: ^Manager,
  texture_handle: resources.Handle,
  texture_id: u32,
  x, y, w, h: f32,
  uv: [4]f32 = {0, 0, 1, 1},
  parent: WidgetHandle = {},
) -> (
  handle: WidgetHandle,
  ok: bool,
) {
  widget: ^Widget
  handle, widget, ok = create_widget(self, .IMAGE, parent)
  if !ok do return

  widget.position = {x, y}
  widget.size = {w, h}
  widget.data = ImageData {
    texture_handle = texture_handle,
    texture_id     = texture_id,
    uv             = uv,
    sprite_index   = 0,
    sprite_count   = 1,
  }

  return
}

create_window :: proc(
  self: ^Manager,
  title: string,
  x, y, w, h: f32,
  parent: WidgetHandle = {},
) -> (
  handle: WidgetHandle,
  ok: bool,
) {
  widget: ^Widget
  handle, widget, ok = create_widget(self, .WINDOW, parent)
  if !ok do return

  widget.position = {x, y}
  widget.size = {w, h}
  widget.bg_color = {240, 240, 240, 255}
  widget.data = WindowData {
    title      = title,
    closeable  = true,
    moveable   = true,
    resizeable = true,
    minimized  = false,
  }

  return
}

// ============================================================================
// Widget Data Accessors
// ============================================================================

set_button_callback :: proc(
  self: ^Manager,
  handle: WidgetHandle,
  callback: proc(ctx: rawptr),
  user_data: rawptr = nil,
) {
  widget, found := resources.get(self.widgets, handle)
  if !found || widget.type != .BUTTON do return

  data := &widget.data.(ButtonData)
  data.callback = callback
  data.user_data = user_data
}

set_label_text :: proc(self: ^Manager, handle: WidgetHandle, text: string) {
  widget, found := resources.get(self.widgets, handle)
  if !found || widget.type != .LABEL do return

  data := &widget.data.(LabelData)
  data.text = text
  mark_dirty(self, handle)
}

set_button_text :: proc(self: ^Manager, handle: WidgetHandle, text: string) {
  widget, found := resources.get(self.widgets, handle)
  if !found || widget.type != .BUTTON do return

  data := &widget.data.(ButtonData)
  data.text = text
  mark_dirty(self, handle)
}

set_image_sprite :: proc(
  self: ^Manager,
  handle: WidgetHandle,
  sprite_index: u32,
  sprite_count: u32,
) {
  widget, found := resources.get(self.widgets, handle)
  if !found || widget.type != .IMAGE do return

  data := &widget.data.(ImageData)
  data.sprite_index = sprite_index
  data.sprite_count = sprite_count

  if sprite_count > 0 {
    sprite_width := 1.0 / f32(sprite_count)
    data.uv = {
      f32(sprite_index) * sprite_width,
      0,
      f32(sprite_index + 1) * sprite_width,
      1,
    }
  }

  mark_dirty(self, handle)
}

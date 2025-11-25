package retained_ui

import cont "../../containers"
import gpu "../../gpu"
import resources "../../resources"
import fs "vendor:fontstash"
import vk "vendor:vulkan"

FRAMES_IN_FLIGHT :: resources.FRAMES_IN_FLIGHT
SHADER_UI_VERT :: #load("../../shader/retained_ui/vert.spv")
SHADER_UI_FRAG :: #load("../../shader/retained_ui/frag.spv")

UI_MAX_QUAD :: 2000
UI_MAX_VERTICES :: UI_MAX_QUAD * 4
UI_MAX_INDICES :: UI_MAX_QUAD * 6

TEXT_MAX_QUADS :: 4096
TEXT_MAX_VERTICES :: TEXT_MAX_QUADS * 4
TEXT_MAX_INDICES :: TEXT_MAX_QUADS * 6
ATLAS_WIDTH :: 1024
ATLAS_HEIGHT :: 1024

DROPDOWN_HOVER_BG :: [4]u8{230, 230, 230, 255}
DROPDOWN_LIST_BG :: [4]u8{240, 245, 250, 255}
DROPDOWN_LIST_HOVER_BG :: [4]u8{100, 180, 255, 255}
DROPDOWN_OPEN_HINT_BG :: [4]u8{50, 150, 255, 255}
DROPDOWN_CLOSE_HINT_BG :: [4]u8{100, 100, 100, 255}

CHECKBOX_HOVER_BG :: [4]u8{230, 230, 230, 255}

RADIO_BUTTON_HOVER_BG :: [4]u8{230, 230, 230, 255}

WHITE :: [4]u8{255, 255, 255, 255}
BLACK :: [4]u8{0, 0, 0, 255}

WIDGET_DEFAULT_BG :: [4]u8{200, 200, 200, 255}
WIDGET_DEFAULT_FG :: [4]u8{0, 0, 0, 255}
WIDGET_DEFAULT_BORDER :: [4]u8{100, 100, 100, 255}

TEXTBOX_BG_FOCUSED :: [4]u8{255, 255, 255, 255}
TEXTBOX_BG_HOVERED :: [4]u8{245, 245, 245, 255}
TEXTBOX_BORDER_FOCUSED :: [4]u8{60, 120, 200, 255}
TEXTBOX_PLACEHOLDER_COLOR :: [4]u8{150, 150, 150, 255}

BUTTON_SHADOW_COLOR :: [4]u8{80, 80, 120, 255}

WidgetHandle :: distinct resources.Handle

ButtonData :: struct {
  text:      string,
  callback:  proc(ctx: rawptr),
  user_data: rawptr,
  hovered:   bool,
  pressed:   bool,
}

LabelData :: struct {
  text:     string,
  autosize: bool,
}

ImageData :: struct {
  texture_handle: resources.Handle,
  uv:             [4]f32, // u0, v0, u1, v1 for sprite animation
  sprite_index:   u32,
  sprite_count:   u32,
}

TextBoxData :: struct {
  text:            [dynamic]u8, // mutable text buffer
  text_as_string:  string, // view of text as string for rendering
  max_length:      u32,
  placeholder:     string,
  focused:         bool,
  hovered:         bool,
  cursor_pos:      u32, // cursor position in text
  selection_start: i32, // -1 if no selection
  selection_end:   i32,
  callback:        proc(ctx: rawptr), // called on text change
  user_data:       rawptr,
}

ComboBoxData :: struct {
  items:        []string,
  selected:     i32, // -1 if nothing selected
  expanded:     bool,
  hovered:      bool,
  hovered_item: i32, // which item in dropdown is hovered (-1 if none)
  callback:     proc(ctx: rawptr, selected_index: i32), // called when selection changes
  user_data:    rawptr,
}

CheckBoxData :: struct {
  checked:   bool,
  label:     string,
  hovered:   bool,
  callback:  proc(ctx: rawptr, checked: bool), // called when state changes
  user_data: rawptr,
}

RadioButtonData :: struct {
  group_id:  u32,
  selected:  bool,
  label:     string,
  hovered:   bool,
  callback:  proc(ctx: rawptr), // called when selected
  user_data: rawptr,
}

WindowData :: struct {
  title:      string,
  closeable:  bool,
  moveable:   bool,
  resizeable: bool,
  minimized:  bool,
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

Widget :: struct {
  // Tree structure
  parent:       WidgetHandle,
  first_child:  WidgetHandle,
  last_child:   WidgetHandle,
  next_sibling: WidgetHandle,
  prev_sibling: WidgetHandle,
  // Layout
  position:     [2]f32, // absolute screen position
  size:         [2]f32,
  anchor:       [2]f32, // 0-1 for alignment within parent
  // Visual state
  visible:      bool,
  enabled:      bool,
  dirty:        bool, // needs draw list rebuild
  // Styling
  bg_color:     [4]u8,
  fg_color:     [4]u8,
  border_color: [4]u8,
  border_width: f32,
  // Widget-specific data
  data:         WidgetData,
}

DrawCommandType :: enum {
  RECT,
  TEXT,
  IMAGE,
  CLIP,
}

TextAlign :: enum {
  LEFT,
  CENTER,
  RIGHT,
}

DrawCommand :: struct {
  type:        DrawCommandType,
  widget:      WidgetHandle,
  rect:        [4]f32, // x, y, w, h
  color:       [4]u8,
  texture_id:  u32,
  uv:          [4]f32, // texture coordinates
  text:        string,
  text_align:  TextAlign,
  text_suffix: bool, // Show suffix instead of prefix when text overflows
  clip_rect:   [4]i32, // scissor rectangle
  z:           f32,
}

Vertex2D :: struct {
  pos:        [2]f32,
  uv:         [2]f32,
  color:      [4]u8,
  texture_id: u32,
  z:          f32,
}

DrawList :: struct {
  commands:            [dynamic]DrawCommand,
  vertices:            [UI_MAX_VERTICES]Vertex2D,
  indices:             [UI_MAX_INDICES]u32,
  vertex_count:        u32,
  index_count:         u32,
  cumulative_vertices: u32,
  cumulative_indices:  u32,
}

Manager :: struct {
  // Widget storage
  widgets:                      cont.Pool(Widget),
  root_widgets:                 [dynamic]WidgetHandle,
  // Draw lists (one per frame in flight)
  draw_lists:                   [FRAMES_IN_FLIGHT]DrawList,
  current_frame:                u32,
  // Dirty tracking for incremental updates
  dirty_widgets:                [dynamic]WidgetHandle,
  // Input state
  mouse_pos:                    [2]f32,
  mouse_down:                   bool,
  mouse_clicked:                bool,
  mouse_released:               bool,
  focused_widget:               WidgetHandle, // Currently focused widget for keyboard input
  // UI rectangle rendering resources
  projection_layout:            vk.DescriptorSetLayout,
  projection_descriptor_set:    vk.DescriptorSet,
  pipeline_layout:              vk.PipelineLayout,
  pipeline:                     vk.Pipeline,
  atlas_handle:                 resources.Handle, // For bindless access
  proj_buffer:                  gpu.MutableBuffer(matrix[4, 4]f32),
  vertex_buffers:               [FRAMES_IN_FLIGHT]gpu.MutableBuffer(
    Vertex2D,
  ),
  index_buffers:                [FRAMES_IN_FLIGHT]gpu.MutableBuffer(u32),
  // Text rendering resources
  font_ctx:                     fs.FontContext,
  default_font:                 int,
  text_atlas_handle:            resources.Handle, // For bindless access
  text_vertices:                [TEXT_MAX_VERTICES]Vertex2D,
  text_indices:                 [TEXT_MAX_INDICES]u32,
  text_vertex_count:            u32,
  text_index_count:             u32,
  text_cumulative_vertex_count: u32, // Track what's been flushed
  text_cumulative_index_count:  u32, // Track what's been flushed
  text_vertex_buffer:           gpu.MutableBuffer(Vertex2D),
  text_index_buffer:            gpu.MutableBuffer(u32),
  atlas_initialized:            bool,
  // Screen dimensions
  frame_width:                  u32,
  frame_height:                 u32,
  dpi_scale:                    f32,
}

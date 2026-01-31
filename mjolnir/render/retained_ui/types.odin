package retained_ui

import cont "../../containers"
import gpu "../../gpu"
import resources "../../resources"
import fs "vendor:fontstash"
import vk "vendor:vulkan"

FRAMES_IN_FLIGHT :: #config(FRAMES_IN_FLIGHT, 2)
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

// Default colors
WHITE :: [4]u8{255, 255, 255, 255}
BLACK :: [4]u8{0, 0, 0, 255}
TRANSPARENT :: [4]u8{0, 0, 0, 0}

// Widget color constants (for compatibility and widgets)
DROPDOWN_HOVER_BG :: [4]u8{230, 230, 230, 255}
DROPDOWN_LIST_BG :: [4]u8{240, 245, 250, 255}
DROPDOWN_LIST_HOVER_BG :: [4]u8{100, 180, 255, 255}
DROPDOWN_OPEN_HINT_BG :: [4]u8{50, 150, 255, 255}
DROPDOWN_CLOSE_HINT_BG :: [4]u8{100, 100, 100, 255}
CHECKBOX_HOVER_BG :: [4]u8{230, 230, 230, 255}
WIDGET_DEFAULT_BG :: [4]u8{200, 200, 200, 255}
WIDGET_DEFAULT_FG :: [4]u8{0, 0, 0, 255}
WIDGET_DEFAULT_BORDER :: [4]u8{100, 100, 100, 255}
TEXTBOX_BG_FOCUSED :: [4]u8{255, 255, 255, 255}
TEXTBOX_BG_HOVERED :: [4]u8{245, 245, 245, 255}
TEXTBOX_BORDER_FOCUSED :: [4]u8{60, 120, 200, 255}
TEXTBOX_PLACEHOLDER_COLOR :: [4]u8{150, 150, 150, 255}
BUTTON_SHADOW_COLOR :: [4]u8{80, 80, 120, 255}
BUTTON_DEFAULT_BG :: [4]u8{60, 120, 200, 255}
BUTTON_HOVER_BG :: [4]u8{80, 140, 220, 255}
BUTTON_PRESS_BG :: [4]u8{40, 100, 180, 255}

// =============================================================================
// Handle Types
// =============================================================================

ElementHandle :: distinct resources.Handle
FlexBoxHandle :: distinct resources.Handle

// =============================================================================
// Sizing Modes
// =============================================================================

// Fixed pixel dimensions
SizeAbsolute :: struct {
  width, height: f32,
}

// Fill remaining space proportionally (0.0-1.0)
SizeFillRemaining :: struct {
  width_weight, height_weight: f32,
}

// Percentage of parent dimensions (0.0-1.0)
SizeRelativeParent :: struct {
  width_pct, height_pct: f32,
}

// Sizing modes for all entities
SizeMode :: union {
  SizeAbsolute,
  SizeFillRemaining,
  SizeRelativeParent,
}

// =============================================================================
// Positioning Modes
// =============================================================================

// Fixed pixel coordinates (relative to parent)
PosAbsolute :: struct {
  x, y: f32,
}

// Percentage within parent bounding rect (0.0-1.0)
PosRelative :: struct {
  x_pct, y_pct: f32,
}

// Positioning modes for all entities
PositionMode :: union {
  PosAbsolute,
  PosRelative,
}

// =============================================================================
// Transform
// =============================================================================

Transform2D :: struct {
  position: [2]f32, // Local position offset
  rotation: f32, // Radians
  scale:    [2]f32, // Local scale (default {1,1})
  pivot:    [2]f32, // Pivot point for rotation/scale (0-1, relative to size)
}

TRANSFORM2D_IDENTITY :: Transform2D {
  position = {0, 0},
  rotation = 0,
  scale    = {1, 1},
  pivot    = {0, 0},
}

// Computed world transform (cached after layout)
WorldTransform2D :: struct {
  mat:      matrix[3, 3]f32, // Combined 2D transform matrix
  position: [2]f32, // World position
  rotation: f32, // World rotation
  scale:    [2]f32, // World scale
}

// =============================================================================
// Edge Insets
// =============================================================================

EdgeInsets :: struct {
  top, right, bottom, left: f32,
}

// =============================================================================
// Text Alignment
// =============================================================================

TextAlign :: enum {
  LEFT,
  CENTER,
  RIGHT,
}

// =============================================================================
// Primitives
// =============================================================================

// User-defined mesh vertex
Mesh2DVertex :: struct {
  pos:   [2]f32,
  uv:    [2]f32,
  color: [4]u8,
}

// Custom 2D mesh
Mesh2D :: struct {
  vertices:        [dynamic]Mesh2DVertex,
  indices:         [dynamic]u32, // Optional, triangle list if empty
  texture:         resources.Image2DHandle,
  size_mode:       SizeMode,
  position_mode:   PositionMode,
  transform:       Transform2D,
  z_order:         f32,
  visible:         bool,
  // Cached after layout
  computed_rect:   [4]f32, // x, y, w, h in world space
  world_transform: WorldTransform2D,
}

// Simple quad with auto UV (0,0 -> 1,1)
Quad2D :: struct {
  color:           [4]u8,
  texture:         resources.Image2DHandle, // 0 = solid color (uses white atlas)
  uv_rect:         [4]f32, // u0, v0, u1, v1 (default {0,0,1,1})
  size_mode:       SizeMode,
  position_mode:   PositionMode,
  transform:       Transform2D,
  z_order:         f32,
  visible:         bool,
  // Cached after layout
  computed_rect:   [4]f32, // x, y, w, h in world space
  world_transform: WorldTransform2D,
}

// Text primitive
Text2D :: struct {
  text:            string,
  font_size:       f32,
  color:           [4]u8,
  alignment:       TextAlign,
  wrap:            bool,
  size_mode:       SizeMode, // Bounding box for wrap/alignment
  position_mode:   PositionMode,
  transform:       Transform2D,
  z_order:         f32,
  visible:         bool,
  // Cached after layout
  computed_rect:   [4]f32, // x, y, w, h in world space
  world_transform: WorldTransform2D,
}

// =============================================================================
// Element (wrapper for primitives in layout system)
// =============================================================================

ElementData :: union {
  Quad2D,
  Mesh2D,
  Text2D,
}

Element :: struct {
  data:        ElementData,
  parent:      FlexBoxHandle,
  // Flex item properties
  flex_grow:   f32,
  flex_shrink: f32,
  margin:      EdgeInsets,
  // Event handlers (stored separately in Manager for efficiency)
}

// =============================================================================
// GPU Vertex (for rendering)
// =============================================================================

Vertex2D :: struct {
  pos:        [2]f32,
  uv:         [2]f32,
  color:      [4]u8,
  texture_id: u32,
  z:          f32,
}

// =============================================================================
// Draw Commands (internal)
// =============================================================================

DrawCommandType :: enum {
  RECT,
  TEXT,
  IMAGE,
  MESH,
  CLIP,
}

DrawCommand :: struct {
  type:        DrawCommandType,
  rect:        [4]f32, // x, y, w, h
  color:       [4]u8,
  texture_id:  u32,
  uv:          [4]f32, // texture coordinates
  text:        string,
  text_align:  TextAlign,
  text_suffix: bool, // Show suffix instead of prefix when text overflows
  clip_rect:   [4]i32, // scissor rectangle
  z:           f32,
  // For mesh rendering
  vertices:    []Mesh2DVertex,
  indices:     []u32,
  // Transform matrix for mesh vertices
  transform:   matrix[3, 3]f32,
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

// =============================================================================
// Manager (forward declaration - full definition in manager.odin)
// =============================================================================

Manager :: struct {
  // Element storage
  elements:                     cont.Pool(Element),
  flexboxes:                    cont.Pool(FlexBox),
  root_flexboxes:               [dynamic]FlexBoxHandle,
  // Event handlers
  event_handlers:               map[ElementHandle][dynamic]EventHandler,
  // Layout state
  layout_dirty:                 bool,
  // Draw lists (one per frame in flight)
  draw_lists:                   [FRAMES_IN_FLIGHT]DrawList,
  current_frame:                u32,
  // Input state
  mouse_pos:                    [2]f32,
  mouse_down:                   bool,
  mouse_clicked:                bool,
  mouse_released:               bool,
  hovered_element:              ElementHandle, // Currently hovered element
  focused_element:              ElementHandle, // Currently focused element for keyboard input
  // UI rectangle rendering resources
  projection_layout:            vk.DescriptorSetLayout,
  projection_descriptor_set:    vk.DescriptorSet,
  pipeline_layout:              vk.PipelineLayout,
  pipeline:                     vk.Pipeline,
  atlas_handle:                 resources.Image2DHandle,
  proj_buffer:                  gpu.MutableBuffer(matrix[4, 4]f32),
  vertex_buffers:               [FRAMES_IN_FLIGHT]gpu.MutableBuffer(Vertex2D),
  index_buffers:                [FRAMES_IN_FLIGHT]gpu.MutableBuffer(u32),
  // Text rendering resources
  font_ctx:                     fs.FontContext,
  default_font:                 int,
  text_atlas_handle:            resources.Image2DHandle,
  text_vertices:                [TEXT_MAX_VERTICES]Vertex2D,
  text_indices:                 [TEXT_MAX_INDICES]u32,
  text_vertex_count:            u32,
  text_index_count:             u32,
  text_cumulative_vertex_count: u32,
  text_cumulative_index_count:  u32,
  text_vertex_buffer:           gpu.MutableBuffer(Vertex2D),
  text_index_buffer:            gpu.MutableBuffer(u32),
  atlas_initialized:            bool,
  // Screen dimensions
  frame_width:                  u32,
  frame_height:                 u32,
  dpi_scale:                    f32,
}

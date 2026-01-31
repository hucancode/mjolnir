package retained_ui

// =============================================================================
// FlexBox Layout Enums
// =============================================================================

FlexDirection :: enum {
  ROW,
  ROW_REVERSE,
  COLUMN,
  COLUMN_REVERSE,
}

JustifyContent :: enum {
  FLEX_START,
  FLEX_END,
  CENTER,
  SPACE_BETWEEN,
  SPACE_AROUND,
  SPACE_EVENLY,
}

AlignItems :: enum {
  FLEX_START,
  FLEX_END,
  CENTER,
  STRETCH,
}

// =============================================================================
// FlexBox Container
// =============================================================================

FlexChildRef :: union {
  ElementHandle,
  FlexBoxHandle,
}

FlexBox :: struct {
  // Layout properties
  direction:       FlexDirection,
  justify_content: JustifyContent,
  align_items:     AlignItems,
  gap:             [2]f32, // row_gap, col_gap
  padding:         EdgeInsets,
  // Sizing/positioning (FlexBox itself)
  size_mode:       SizeMode,
  position_mode:   PositionMode,
  transform:       Transform2D,
  // Visual properties
  bg_color:        [4]u8,
  border_color:    [4]u8,
  border_width:    f32,
  z_order:         f32,
  visible:         bool,
  clip_children:   bool,
  // Hierarchy
  parent:          FlexBoxHandle,
  children:        [dynamic]FlexChildRef, // Can contain elements or nested FlexBoxes
  // Cached after layout
  computed_rect:   [4]f32, // x, y, w, h in world space
  world_transform: WorldTransform2D,
  layout_dirty:    bool,
}

// =============================================================================
// FlexBox Helpers
// =============================================================================

// Check if direction is horizontal (ROW or ROW_REVERSE)
is_horizontal :: proc(dir: FlexDirection) -> bool {
  return dir == .ROW || dir == .ROW_REVERSE
}

// Check if direction is reversed
is_reversed :: proc(dir: FlexDirection) -> bool {
  return dir == .ROW_REVERSE || dir == .COLUMN_REVERSE
}

// Get main axis gap based on direction
get_main_gap :: proc(fb: ^FlexBox) -> f32 {
  return is_horizontal(fb.direction) ? fb.gap.x : fb.gap.y
}

// Get cross axis gap based on direction
get_cross_gap :: proc(fb: ^FlexBox) -> f32 {
  return is_horizontal(fb.direction) ? fb.gap.y : fb.gap.x
}

// Get content area (rect minus padding)
get_content_rect :: proc(fb: ^FlexBox) -> [4]f32 {
  return {
    fb.computed_rect.x + fb.padding.left,
    fb.computed_rect.y + fb.padding.top,
    fb.computed_rect.z - fb.padding.left - fb.padding.right,
    fb.computed_rect.w - fb.padding.top - fb.padding.bottom,
  }
}

// Default FlexBox configuration
default_flexbox :: proc() -> FlexBox {
  return FlexBox {
    direction = .ROW,
    justify_content = .FLEX_START,
    align_items = .STRETCH,
    gap = {0, 0},
    padding = {},
    size_mode = SizeAbsolute{100, 100},
    position_mode = PosAbsolute{0, 0},
    transform = TRANSFORM2D_IDENTITY,
    bg_color = TRANSPARENT,
    border_color = TRANSPARENT,
    border_width = 0,
    z_order = 0,
    visible = true,
    clip_children = false,
    parent = {},
    children = {},
    computed_rect = {0, 0, 100, 100},
    world_transform = {},
    layout_dirty = true,
  }
}

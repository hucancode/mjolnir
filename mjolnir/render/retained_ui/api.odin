package retained_ui

import cont "../../containers"
import resources "../../resources"
import "core:math/linalg"

// =============================================================================
// FlexBox Creation
// =============================================================================

create_flexbox :: proc(
  manager: ^Manager,
  parent: FlexBoxHandle = {},
) -> (
  handle: FlexBoxHandle,
  ok: bool,
) #optional_ok {
  fb: ^FlexBox
  handle, fb, ok = cont.alloc(&manager.flexboxes, FlexBoxHandle)
  if !ok do return

  fb^ = default_flexbox()
  fb.parent = parent
  fb.children = make([dynamic]FlexChildRef, 0, 16)

  if parent.index != 0 {
    // Add to parent's children
    parent_fb, found := cont.get(manager.flexboxes, parent)
    if !found do return
    append(&parent_fb.children, FlexChildRef(handle))
  } else {
    // Root flexbox
    append(&manager.root_flexboxes, handle)
  }

  mark_layout_dirty(manager)
  return handle, true
}

// =============================================================================
// Element Creation
// =============================================================================

create_quad :: proc(
  manager: ^Manager,
  parent: FlexBoxHandle,
  color: [4]u8 = WHITE,
  size: SizeMode = SizeAbsolute{100, 100},
) -> (
  handle: ElementHandle,
  ok: bool,
) #optional_ok {
  element: ^Element
  handle, element, ok = cont.alloc(&manager.elements, ElementHandle)
  if !ok do return

  element.parent = parent
  element.data = Quad2D {
    color           = color,
    texture         = {},
    uv_rect         = {0, 0, 1, 1},
    size_mode       = size,
    position_mode   = nil, // Positioned by layout
    transform       = TRANSFORM2D_IDENTITY,
    z_order         = 0,
    visible         = true,
    computed_rect   = {0, 0, 100, 100},
    world_transform = {},
  }

  // Add to parent
  if parent_fb := cont.get(manager.flexboxes, parent); parent_fb != nil {
    append(&parent_fb.children, FlexChildRef(handle))
  }

  mark_layout_dirty(manager)
  return handle, true
}

create_text :: proc(
  manager: ^Manager,
  parent: FlexBoxHandle,
  text: string,
  font_size: f32 = 16,
  color: [4]u8 = BLACK,
) -> (
  handle: ElementHandle,
  ok: bool,
) #optional_ok {
  element: ^Element
  handle, element, ok = cont.alloc(&manager.elements, ElementHandle)
  if !ok do return

  // Measure text to get intrinsic size
  text_size := measure_text_size(manager, text, font_size)

  element.parent = parent
  element.data = Text2D {
    text            = text,
    font_size       = font_size,
    color           = color,
    alignment       = .LEFT,
    wrap            = false,
    size_mode       = SizeAbsolute{text_size.x, text_size.y},
    position_mode   = nil,
    transform       = TRANSFORM2D_IDENTITY,
    z_order         = 0,
    visible         = true,
    computed_rect   = {0, 0, text_size.x, text_size.y},
    world_transform = {},
  }

  // Add to parent
  if parent_fb := cont.get(manager.flexboxes, parent); parent_fb != nil {
    append(&parent_fb.children, FlexChildRef(handle))
  }

  mark_layout_dirty(manager)
  return handle, true
}

create_mesh :: proc(
  manager: ^Manager,
  parent: FlexBoxHandle,
  vertices: []Mesh2DVertex,
  indices: []u32 = nil,
) -> (
  handle: ElementHandle,
  ok: bool,
) #optional_ok {
  element: ^Element
  handle, element, ok = cont.alloc(&manager.elements, ElementHandle)
  if !ok do return

  // Copy vertices
  vertex_copy := make([dynamic]Mesh2DVertex, len(vertices))
  for v, i in vertices {
    vertex_copy[i] = v
  }

  // Copy indices if provided
  index_copy: [dynamic]u32
  if len(indices) > 0 {
    index_copy = make([dynamic]u32, len(indices))
    for idx, i in indices {
      index_copy[i] = idx
    }
  }

  mesh := Mesh2D {
    vertices        = vertex_copy,
    indices         = index_copy,
    texture         = {},
    size_mode       = nil,
    position_mode   = nil,
    transform       = TRANSFORM2D_IDENTITY,
    z_order         = 0,
    visible         = true,
    computed_rect   = {0, 0, 100, 100},
    world_transform = {},
  }

  // Calculate bounds
  bounds := calculate_mesh_bounds(&mesh)
  mesh.size_mode = SizeAbsolute{bounds.x, bounds.y}

  element.parent = parent
  element.data = mesh

  // Add to parent
  if parent_fb := cont.get(manager.flexboxes, parent); parent_fb != nil {
    append(&parent_fb.children, FlexChildRef(handle))
  }

  mark_layout_dirty(manager)
  return handle, true
}

create_image :: proc(
  manager: ^Manager,
  parent: FlexBoxHandle,
  texture: resources.Image2DHandle,
  size: SizeMode = SizeAbsolute{100, 100},
  uv_rect: [4]f32 = {0, 0, 1, 1},
) -> (
  handle: ElementHandle,
  ok: bool,
) #optional_ok {
  element: ^Element
  handle, element, ok = cont.alloc(&manager.elements, ElementHandle)
  if !ok do return

  element.parent = parent
  element.data = Quad2D {
    color           = WHITE,
    texture         = texture,
    uv_rect         = uv_rect,
    size_mode       = size,
    position_mode   = nil,
    transform       = TRANSFORM2D_IDENTITY,
    z_order         = 0,
    visible         = true,
    computed_rect   = {0, 0, 100, 100},
    world_transform = {},
  }

  // Add to parent
  if parent_fb := cont.get(manager.flexboxes, parent); parent_fb != nil {
    append(&parent_fb.children, FlexChildRef(handle))
  }

  mark_layout_dirty(manager)
  return handle, true
}

// =============================================================================
// Common Manipulation
// =============================================================================

set_size :: proc(manager: ^Manager, handle: ElementHandle, mode: SizeMode) {
  element, found := cont.get(manager.elements, handle)
  if !found do return

  switch &data in element.data {
  case Quad2D:
    data.size_mode = mode
  case Text2D:
    data.size_mode = mode
  case Mesh2D:
    data.size_mode = mode
  }

  mark_layout_dirty(manager)
}

set_position :: proc(
  manager: ^Manager,
  handle: ElementHandle,
  mode: PositionMode,
) {
  element, found := cont.get(manager.elements, handle)
  if !found do return

  switch &data in element.data {
  case Quad2D:
    data.position_mode = mode
  case Text2D:
    data.position_mode = mode
  case Mesh2D:
    data.position_mode = mode
  }

  mark_layout_dirty(manager)
}

set_transform :: proc(
  manager: ^Manager,
  handle: ElementHandle,
  transform: Transform2D,
) {
  element, found := cont.get(manager.elements, handle)
  if !found do return

  switch &data in element.data {
  case Quad2D:
    data.transform = transform
  case Text2D:
    data.transform = transform
  case Mesh2D:
    data.transform = transform
  }

  mark_layout_dirty(manager)
}

set_rotation :: proc(manager: ^Manager, handle: ElementHandle, radians: f32) {
  element, found := cont.get(manager.elements, handle)
  if !found do return

  switch &data in element.data {
  case Quad2D:
    data.transform.rotation = radians
  case Text2D:
    data.transform.rotation = radians
  case Mesh2D:
    data.transform.rotation = radians
  }

  mark_layout_dirty(manager)
}

set_scale :: proc(manager: ^Manager, handle: ElementHandle, scale: [2]f32) {
  element, found := cont.get(manager.elements, handle)
  if !found do return

  switch &data in element.data {
  case Quad2D:
    data.transform.scale = scale
  case Text2D:
    data.transform.scale = scale
  case Mesh2D:
    data.transform.scale = scale
  }

  mark_layout_dirty(manager)
}

set_pivot :: proc(manager: ^Manager, handle: ElementHandle, pivot: [2]f32) {
  element, found := cont.get(manager.elements, handle)
  if !found do return

  switch &data in element.data {
  case Quad2D:
    data.transform.pivot = pivot
  case Text2D:
    data.transform.pivot = pivot
  case Mesh2D:
    data.transform.pivot = pivot
  }

  mark_layout_dirty(manager)
}

set_z_order :: proc(manager: ^Manager, handle: ElementHandle, z: f32) {
  element, found := cont.get(manager.elements, handle)
  if !found do return

  switch &data in element.data {
  case Quad2D:
    data.z_order = z
  case Text2D:
    data.z_order = z
  case Mesh2D:
    data.z_order = z
  }
}

set_visible :: proc(manager: ^Manager, handle: ElementHandle, visible: bool) {
  element, found := cont.get(manager.elements, handle)
  if !found do return

  switch &data in element.data {
  case Quad2D:
    data.visible = visible
  case Text2D:
    data.visible = visible
  case Mesh2D:
    data.visible = visible
  }
}

set_flex_grow :: proc(manager: ^Manager, handle: ElementHandle, grow: f32) {
  element, found := cont.get(manager.elements, handle)
  if !found do return
  element.flex_grow = grow
  mark_layout_dirty(manager)
}

set_flex_shrink :: proc(
  manager: ^Manager,
  handle: ElementHandle,
  shrink: f32,
) {
  element, found := cont.get(manager.elements, handle)
  if !found do return
  element.flex_shrink = shrink
  mark_layout_dirty(manager)
}

set_margin :: proc(
  manager: ^Manager,
  handle: ElementHandle,
  margin: EdgeInsets,
) {
  element, found := cont.get(manager.elements, handle)
  if !found do return
  element.margin = margin
  mark_layout_dirty(manager)
}

// =============================================================================
// Quad-specific
// =============================================================================

set_quad_color :: proc(
  manager: ^Manager,
  handle: ElementHandle,
  color: [4]u8,
) {
  element, found := cont.get(manager.elements, handle)
  if !found do return
  quad, ok := &element.data.(Quad2D)
  if !ok do return
  quad.color = color
}

set_quad_texture :: proc(
  manager: ^Manager,
  handle: ElementHandle,
  texture: resources.Image2DHandle,
  uv_rect: [4]f32 = {0, 0, 1, 1},
) {
  element, found := cont.get(manager.elements, handle)
  if !found do return
  quad, ok := &element.data.(Quad2D)
  if !ok do return
  quad.texture = texture
  quad.uv_rect = uv_rect
}

// =============================================================================
// Text-specific
// =============================================================================

set_text_content :: proc(
  manager: ^Manager,
  handle: ElementHandle,
  text: string,
) {
  element, found := cont.get(manager.elements, handle)
  if !found do return
  text2d, ok := &element.data.(Text2D)
  if !ok do return
  text2d.text = text

  // Update intrinsic size
  text_size := measure_text_size(manager, text, text2d.font_size)
  text2d.size_mode = SizeAbsolute{text_size.x, text_size.y}

  mark_layout_dirty(manager)
}

set_text_color :: proc(
  manager: ^Manager,
  handle: ElementHandle,
  color: [4]u8,
) {
  element, found := cont.get(manager.elements, handle)
  if !found do return
  text2d, ok := &element.data.(Text2D)
  if !ok do return
  text2d.color = color
}

set_text_font_size :: proc(
  manager: ^Manager,
  handle: ElementHandle,
  size: f32,
) {
  element, found := cont.get(manager.elements, handle)
  if !found do return
  text2d, ok := &element.data.(Text2D)
  if !ok do return
  text2d.font_size = size

  // Update intrinsic size
  text_size := measure_text_size(manager, text2d.text, size)
  text2d.size_mode = SizeAbsolute{text_size.x, text_size.y}

  mark_layout_dirty(manager)
}

set_text_alignment :: proc(
  manager: ^Manager,
  handle: ElementHandle,
  align: TextAlign,
) {
  element, found := cont.get(manager.elements, handle)
  if !found do return
  text2d, ok := &element.data.(Text2D)
  if !ok do return
  text2d.alignment = align
}

// =============================================================================
// FlexBox Manipulation
// =============================================================================

set_flexbox_size :: proc(
  manager: ^Manager,
  handle: FlexBoxHandle,
  mode: SizeMode,
) {
  fb, found := cont.get(manager.flexboxes, handle)
  if !found do return
  fb.size_mode = mode
  mark_layout_dirty(manager)
}

set_flexbox_position :: proc(
  manager: ^Manager,
  handle: FlexBoxHandle,
  mode: PositionMode,
) {
  fb, found := cont.get(manager.flexboxes, handle)
  if !found do return
  fb.position_mode = mode
  mark_layout_dirty(manager)
}

set_flexbox_direction :: proc(
  manager: ^Manager,
  handle: FlexBoxHandle,
  dir: FlexDirection,
) {
  fb, found := cont.get(manager.flexboxes, handle)
  if !found do return
  fb.direction = dir
  mark_layout_dirty(manager)
}

set_flexbox_justify :: proc(
  manager: ^Manager,
  handle: FlexBoxHandle,
  justify: JustifyContent,
) {
  fb, found := cont.get(manager.flexboxes, handle)
  if !found do return
  fb.justify_content = justify
  mark_layout_dirty(manager)
}

set_flexbox_align :: proc(
  manager: ^Manager,
  handle: FlexBoxHandle,
  align: AlignItems,
) {
  fb, found := cont.get(manager.flexboxes, handle)
  if !found do return
  fb.align_items = align
  mark_layout_dirty(manager)
}

set_flexbox_padding :: proc(
  manager: ^Manager,
  handle: FlexBoxHandle,
  padding: EdgeInsets,
) {
  fb, found := cont.get(manager.flexboxes, handle)
  if !found do return
  fb.padding = padding
  mark_layout_dirty(manager)
}

set_flexbox_gap :: proc(
  manager: ^Manager,
  handle: FlexBoxHandle,
  row_gap, col_gap: f32,
) {
  fb, found := cont.get(manager.flexboxes, handle)
  if !found do return
  fb.gap = {row_gap, col_gap}
  mark_layout_dirty(manager)
}

set_flexbox_background :: proc(
  manager: ^Manager,
  handle: FlexBoxHandle,
  color: [4]u8,
) {
  fb, found := cont.get(manager.flexboxes, handle)
  if !found do return
  fb.bg_color = color
}

set_flexbox_border :: proc(
  manager: ^Manager,
  handle: FlexBoxHandle,
  color: [4]u8,
  width: f32,
) {
  fb, found := cont.get(manager.flexboxes, handle)
  if !found do return
  fb.border_color = color
  fb.border_width = width
}

set_flexbox_z_order :: proc(manager: ^Manager, handle: FlexBoxHandle, z: f32) {
  fb, found := cont.get(manager.flexboxes, handle)
  if !found do return
  fb.z_order = z
}

set_flexbox_visible :: proc(
  manager: ^Manager,
  handle: FlexBoxHandle,
  visible: bool,
) {
  fb, found := cont.get(manager.flexboxes, handle)
  if !found do return
  fb.visible = visible
}

set_flexbox_clip :: proc(
  manager: ^Manager,
  handle: FlexBoxHandle,
  clip: bool,
) {
  fb, found := cont.get(manager.flexboxes, handle)
  if !found do return
  fb.clip_children = clip
}

// =============================================================================
// Destruction
// =============================================================================

destroy_element :: proc(manager: ^Manager, handle: ElementHandle) {
  element, found := cont.get(manager.elements, handle)
  if !found do return

  // Remove from parent
  if parent_fb := cont.get(manager.flexboxes, element.parent);
     parent_fb != nil {
    for child, i in parent_fb.children {
      if elem, ok := child.(ElementHandle); ok && elem == handle {
        ordered_remove(&parent_fb.children, i)
        break
      }
    }
  }

  // Clean up event handlers
  remove_all_events(manager, handle)

  // Clean up element data
  element_destroy(element)

  // Free from pool
  cont.free(&manager.elements, handle)

  mark_layout_dirty(manager)
}

destroy_flexbox :: proc(
  manager: ^Manager,
  handle: FlexBoxHandle,
  recursive: bool = true,
) {
  fb, found := cont.get(manager.flexboxes, handle)
  if !found do return

  // Destroy children first if recursive
  if recursive {
    // Copy children list to avoid modification during iteration
    children_copy := make([]FlexChildRef, len(fb.children))
    for c, i in fb.children {
      children_copy[i] = c
    }
    defer delete(children_copy)

    for child in children_copy {
      switch c in child {
      case ElementHandle:
        destroy_element(manager, c)
      case FlexBoxHandle:
        destroy_flexbox(manager, c, recursive)
      }
    }
  }

  // Remove from parent
  if fb.parent.index != 0 {
    if parent_fb := cont.get(manager.flexboxes, fb.parent); parent_fb != nil {
      for child, i in parent_fb.children {
        if fb_handle, ok := child.(FlexBoxHandle); ok && fb_handle == handle {
          ordered_remove(&parent_fb.children, i)
          break
        }
      }
    }
  } else {
    // Remove from root list
    for root, i in manager.root_flexboxes {
      if root == handle {
        ordered_remove(&manager.root_flexboxes, i)
        break
      }
    }
  }

  // Clean up children array
  delete(fb.children)

  // Free from pool
  cont.free(&manager.flexboxes, handle)

  mark_layout_dirty(manager)
}

// =============================================================================
// Utility
// =============================================================================

get_computed_rect :: proc(manager: ^Manager, handle: ElementHandle) -> [4]f32 {
  element, found := cont.get(manager.elements, handle)
  if !found do return {0, 0, 0, 0}

  switch &data in element.data {
  case Quad2D:
    return data.computed_rect
  case Text2D:
    return data.computed_rect
  case Mesh2D:
    return data.computed_rect
  }

  return {0, 0, 0, 0}
}

get_flexbox_rect :: proc(manager: ^Manager, handle: FlexBoxHandle) -> [4]f32 {
  fb, found := cont.get(manager.flexboxes, handle)
  if !found do return {0, 0, 0, 0}
  return fb.computed_rect
}

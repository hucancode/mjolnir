package retained_ui

import cont "../../containers"
import "core:math"
import "core:math/linalg"
import fs "vendor:fontstash"

// =============================================================================
// Layout System
// =============================================================================

// Run the full layout pass on all dirty elements
run_layout :: proc(manager: ^Manager) {
  if !manager.layout_dirty do return

  // Layout all root flexboxes
  for handle in manager.root_flexboxes {
    fb := cont.get(manager.flexboxes, handle) or_continue
    if !fb.visible do continue

    // Root flexboxes use screen rect as parent
    parent_rect := [4]f32 {
      0,
      0,
      f32(manager.frame_width),
      f32(manager.frame_height),
    }
    parent_transform := identity_world_transform()

    layout_flexbox(manager, handle, parent_rect, parent_transform, 0)
  }

  manager.layout_dirty = false
}

// =============================================================================
// Transform Computation
// =============================================================================

identity_world_transform :: proc() -> WorldTransform2D {
  return WorldTransform2D {
    mat = linalg.MATRIX3F32_IDENTITY,
    position = {0, 0},
    rotation = 0,
    scale = {1, 1},
  }
}

// Build a 2D transform matrix from Transform2D
// Order: Translate to position -> Translate to pivot -> Rotate -> Scale -> Translate back from pivot
build_transform_matrix :: proc(
  t: Transform2D,
  size: [2]f32,
) -> matrix[3, 3]f32 {
  pivot_offset := t.pivot * size

  // Build 2D transformation matrices manually (3x3 homogeneous)
  cos_r := math.cos(t.rotation)
  sin_r := math.sin(t.rotation)

  // Start with identity
  result := linalg.MATRIX3F32_IDENTITY

  // Apply in reverse order (matrix multiplication order):
  // 1. Translate back from pivot
  result[2, 0] -= pivot_offset.x
  result[2, 1] -= pivot_offset.y

  // 2. Scale
  scale_mat := linalg.MATRIX3F32_IDENTITY
  scale_mat[0, 0] = t.scale.x
  scale_mat[1, 1] = t.scale.y
  result = result * scale_mat

  // 3. Rotate
  rotate_mat := linalg.MATRIX3F32_IDENTITY
  rotate_mat[0, 0] = cos_r
  rotate_mat[0, 1] = sin_r
  rotate_mat[1, 0] = -sin_r
  rotate_mat[1, 1] = cos_r
  result = result * rotate_mat

  // 4. Translate to pivot
  result[2, 0] += pivot_offset.x
  result[2, 1] += pivot_offset.y

  // 5. Translate to position
  result[2, 0] += t.position.x
  result[2, 1] += t.position.y

  return result
}

// Compute world transform by combining with parent
compute_world_transform :: proc(
  local_transform: Transform2D,
  local_rect: [4]f32,
  parent_transform: WorldTransform2D,
) -> WorldTransform2D {
  size := [2]f32{local_rect.z, local_rect.w}
  local_matrix := build_transform_matrix(local_transform, size)

  // Position offset for rect (add translation)
  local_with_pos := local_matrix
  local_with_pos[2, 0] += local_rect.x
  local_with_pos[2, 1] += local_rect.y

  // Combine with parent
  world_matrix := parent_transform.mat * local_with_pos

  // Extract position from matrix
  world_pos := [2]f32{world_matrix[2, 0], world_matrix[2, 1]}

  // Combine rotation and scale
  world_rotation := parent_transform.rotation + local_transform.rotation
  world_scale := parent_transform.scale * local_transform.scale

  return WorldTransform2D {
    mat = world_matrix,
    position = world_pos,
    rotation = world_rotation,
    scale = world_scale,
  }
}

// =============================================================================
// Size Resolution
// =============================================================================

// Resolve size mode to actual pixel dimensions
resolve_size :: proc(
  mode: SizeMode,
  parent_size: [2]f32,
  intrinsic_size: [2]f32, // For content-based sizing
) -> [2]f32 {
  switch s in mode {
  case SizeAbsolute:
    return {s.width, s.height}
  case SizeRelativeParent:
    return {parent_size.x * s.width_pct, parent_size.y * s.height_pct}
  case SizeFillRemaining:
    // Fill remaining is resolved during flex distribution
    return intrinsic_size
  case:
    // Default: use intrinsic size
    return intrinsic_size
  }
}

// Resolve position mode to actual pixel coordinates
resolve_position :: proc(
  mode: PositionMode,
  parent_rect: [4]f32,
  size: [2]f32,
) -> [2]f32 {
  switch p in mode {
  case PosAbsolute:
    return {parent_rect.x + p.x, parent_rect.y + p.y}
  case PosRelative:
    return {
      parent_rect.x + parent_rect.z * p.x_pct,
      parent_rect.y + parent_rect.w * p.y_pct,
    }
  case:
    return {parent_rect.x, parent_rect.y}
  }
}

// =============================================================================
// FlexBox Layout
// =============================================================================

layout_flexbox :: proc(
  manager: ^Manager,
  handle: FlexBoxHandle,
  parent_rect: [4]f32,
  parent_transform: WorldTransform2D,
  parent_z: f32,
) {
  fb, found := cont.get(manager.flexboxes, handle)
  if !found do return
  if !fb.visible do return

  // Step 1: Resolve own size
  parent_size := [2]f32{parent_rect.z, parent_rect.w}
  size := resolve_size(fb.size_mode, parent_size, {100, 100})

  // Step 2: Resolve own position
  position := resolve_position(fb.position_mode, parent_rect, size)
  fb.computed_rect = {position.x, position.y, size.x, size.y}

  // Step 3: Compute world transform
  fb.world_transform = compute_world_transform(
    fb.transform,
    fb.computed_rect,
    parent_transform,
  )

  // Step 4: Get content area (rect minus padding)
  content_rect := get_content_rect(fb)

  // Step 5: Measure children to determine flex distribution
  child_sizes := measure_children(manager, fb, content_rect)

  // Step 6: Distribute space and position children
  distribute_and_position_children(
    manager,
    fb,
    content_rect,
    child_sizes,
    fb.world_transform,
    fb.z_order + parent_z,
  )

  fb.layout_dirty = false
}

// =============================================================================
// Child Measurement
// =============================================================================

ChildMeasurement :: struct {
  base_size:   [2]f32,
  flex_grow:   f32,
  flex_shrink: f32,
  margin:      EdgeInsets,
  is_flexbox:  bool,
}

measure_children :: proc(
  manager: ^Manager,
  fb: ^FlexBox,
  content_rect: [4]f32,
) -> []ChildMeasurement {
  if len(fb.children) == 0 do return nil

  measurements := make([]ChildMeasurement, len(fb.children))
  content_size := [2]f32{content_rect.z, content_rect.w}

  for child, i in fb.children {
    switch c in child {
    case ElementHandle:
      measurements[i] = measure_element(manager, c, content_size)
    case FlexBoxHandle:
      measurements[i] = measure_flexbox_child(manager, c, content_size)
    }
  }

  return measurements
}

measure_element :: proc(
  manager: ^Manager,
  handle: ElementHandle,
  parent_size: [2]f32,
) -> ChildMeasurement {
  element, found := cont.get(manager.elements, handle)
  if !found do return {}

  intrinsic := get_element_intrinsic_size(manager, element)

  size_mode: SizeMode
  switch &data in element.data {
  case Quad2D:
    size_mode = data.size_mode
  case Text2D:
    size_mode = data.size_mode
  case Mesh2D:
    size_mode = data.size_mode
  }

  return ChildMeasurement {
    base_size = resolve_size(size_mode, parent_size, intrinsic),
    flex_grow = element.flex_grow,
    flex_shrink = element.flex_shrink,
    margin = element.margin,
    is_flexbox = false,
  }
}

measure_flexbox_child :: proc(
  manager: ^Manager,
  handle: FlexBoxHandle,
  parent_size: [2]f32,
) -> ChildMeasurement {
  fb, found := cont.get(manager.flexboxes, handle)
  if !found do return {}

  return ChildMeasurement {
    base_size   = resolve_size(fb.size_mode, parent_size, {0, 0}),
    flex_grow   = 0, // FlexBoxes don't flex by default
    flex_shrink = 0,
    margin      = {},
    is_flexbox  = true,
  }
}

get_element_intrinsic_size :: proc(
  manager: ^Manager,
  element: ^Element,
) -> [2]f32 {
  switch &data in element.data {
  case Quad2D:
    // Quads don't have intrinsic size, use size_mode default
    if abs, ok := data.size_mode.(SizeAbsolute); ok {
      return {abs.width, abs.height}
    }
    return {0, 0}
  case Text2D:
    // Measure text bounds
    return measure_text_size(manager, data.text, data.font_size)
  case Mesh2D:
    // Calculate mesh bounds
    return calculate_mesh_bounds(&data)
  }
  return {0, 0}
}

measure_text_size :: proc(
  manager: ^Manager,
  text: string,
  font_size: f32,
) -> [2]f32 {
  if len(text) == 0 do return {0, font_size}

  fs.SetFont(&manager.font_ctx, manager.default_font)
  fs.SetSize(&manager.font_ctx, font_size)

  bounds: [4]f32
  fs.TextBounds(&manager.font_ctx, text, 0, 0, &bounds)

  return {bounds[2] - bounds[0], font_size}
}

calculate_mesh_bounds :: proc(mesh: ^Mesh2D) -> [2]f32 {
  if len(mesh.vertices) == 0 do return {0, 0}

  min_x, min_y: f32 = max(f32), max(f32)
  max_x, max_y: f32 = min(f32), min(f32)

  for v in mesh.vertices {
    min_x = min(min_x, v.pos.x)
    min_y = min(min_y, v.pos.y)
    max_x = max(max_x, v.pos.x)
    max_y = max(max_y, v.pos.y)
  }

  return {max_x - min_x, max_y - min_y}
}

// =============================================================================
// Flex Distribution and Positioning
// =============================================================================

distribute_and_position_children :: proc(
  manager: ^Manager,
  fb: ^FlexBox,
  content_rect: [4]f32,
  measurements: []ChildMeasurement,
  parent_transform: WorldTransform2D,
  base_z: f32,
) {
  if len(fb.children) == 0 {
    delete(measurements)
    return
  }
  defer delete(measurements)

  is_row := is_horizontal(fb.direction)
  reversed := is_reversed(fb.direction)
  main_size := is_row ? content_rect.z : content_rect.w
  cross_size := is_row ? content_rect.w : content_rect.z
  gap := get_main_gap(fb)

  // Calculate total base size and flex factors
  total_base: f32 = 0
  total_grow: f32 = 0
  total_shrink: f32 = 0

  for m in measurements {
    main := is_row ? m.base_size.x : m.base_size.y
    margin_main :=
      is_row ? (m.margin.left + m.margin.right) : (m.margin.top + m.margin.bottom)
    total_base += main + margin_main
    total_grow += m.flex_grow
    total_shrink += m.flex_shrink
  }

  // Add gaps between children
  if len(measurements) > 1 {
    total_base += gap * f32(len(measurements) - 1)
  }

  // Calculate remaining space
  remaining := main_size - total_base
  flex_unit: f32 = 0

  if remaining > 0 && total_grow > 0 {
    flex_unit = remaining / total_grow
  } else if remaining < 0 && total_shrink > 0 {
    flex_unit = remaining / total_shrink
  }

  // Calculate final sizes
  final_sizes := make([]f32, len(measurements))
  defer delete(final_sizes)

  for m, i in measurements {
    main := is_row ? m.base_size.x : m.base_size.y

    if remaining > 0 && m.flex_grow > 0 {
      main += flex_unit * m.flex_grow
    } else if remaining < 0 && m.flex_shrink > 0 {
      main += flex_unit * m.flex_shrink
    }

    final_sizes[i] = max(main, 0)
  }

  // Calculate starting position based on justify_content
  total_final: f32 = 0
  for s in final_sizes {
    total_final += s
  }
  if len(measurements) > 1 {
    total_final += gap * f32(len(final_sizes) - 1)
  }

  // Add margins to total
  for m in measurements {
    margin_main :=
      is_row ? (m.margin.left + m.margin.right) : (m.margin.top + m.margin.bottom)
    total_final += margin_main
  }

  start_offset: f32 = 0
  extra_gap: f32 = 0
  actual_gap := gap

  #partial switch fb.justify_content {
  case .FLEX_START:
    start_offset = 0
  case .FLEX_END:
    start_offset = main_size - total_final
  case .CENTER:
    start_offset = (main_size - total_final) / 2
  case .SPACE_BETWEEN:
    if len(measurements) > 1 {
      extra_gap =
        (main_size - total_final + gap * f32(len(measurements) - 1)) /
        f32(len(measurements) - 1)
      actual_gap = extra_gap
    }
  case .SPACE_AROUND:
    if len(measurements) > 0 {
      space :=
        (main_size - total_final + gap * f32(len(measurements) - 1)) /
        f32(len(measurements))
      start_offset = space / 2
      actual_gap = space
    }
  case .SPACE_EVENLY:
    if len(measurements) > 0 {
      space :=
        (main_size - total_final + gap * f32(len(measurements) - 1)) /
        f32(len(measurements) + 1)
      start_offset = space
      actual_gap = space
    }
  }

  // Position children
  current_pos := start_offset

  indices := make([]int, len(fb.children))
  defer delete(indices)
  for i in 0 ..< len(fb.children) {
    indices[i] = reversed ? len(fb.children) - 1 - i : i
  }

  for idx in indices {
    child := fb.children[idx]
    m := measurements[idx]
    final_main := final_sizes[idx]

    // Calculate cross-axis position and size based on align_items
    cross_pos: f32 = 0
    final_cross := is_row ? m.base_size.y : m.base_size.x
    margin_cross_start := is_row ? m.margin.top : m.margin.left
    margin_cross_end := is_row ? m.margin.bottom : m.margin.right

    #partial switch fb.align_items {
    case .FLEX_START:
      cross_pos = margin_cross_start
    case .FLEX_END:
      cross_pos = cross_size - final_cross - margin_cross_end
    case .CENTER:
      cross_pos = (cross_size - final_cross) / 2
    case .STRETCH:
      final_cross = cross_size - margin_cross_start - margin_cross_end
      cross_pos = margin_cross_start
    }

    // Apply margins on main axis
    margin_main_start := is_row ? m.margin.left : m.margin.top
    pos := current_pos + margin_main_start

    // Calculate child rect
    child_rect: [4]f32
    if is_row {
      child_rect = {
        content_rect.x + pos,
        content_rect.y + cross_pos,
        final_main,
        final_cross,
      }
    } else {
      child_rect = {
        content_rect.x + cross_pos,
        content_rect.y + pos,
        final_cross,
        final_main,
      }
    }

    // Apply to child
    switch c in child {
    case ElementHandle:
      apply_layout_to_element(manager, c, child_rect, parent_transform, base_z)
    case FlexBoxHandle:
      layout_flexbox(manager, c, child_rect, parent_transform, base_z)
    }

    // Move to next position
    margin_main_end := is_row ? m.margin.right : m.margin.bottom
    current_pos +=
      margin_main_start + final_main + margin_main_end + actual_gap
  }
}

apply_layout_to_element :: proc(
  manager: ^Manager,
  handle: ElementHandle,
  rect: [4]f32,
  parent_transform: WorldTransform2D,
  base_z: f32,
) {
  element, found := cont.get(manager.elements, handle)
  if !found do return

  switch &data in element.data {
  case Quad2D:
    data.computed_rect = rect
    data.world_transform = compute_world_transform(
      data.transform,
      rect,
      parent_transform,
    )
    data.z_order += base_z
  case Text2D:
    data.computed_rect = rect
    data.world_transform = compute_world_transform(
      data.transform,
      rect,
      parent_transform,
    )
    data.z_order += base_z
  case Mesh2D:
    data.computed_rect = rect
    data.world_transform = compute_world_transform(
      data.transform,
      rect,
      parent_transform,
    )
    data.z_order += base_z
  }
}

// =============================================================================
// Layout Invalidation
// =============================================================================

mark_layout_dirty :: proc(manager: ^Manager) {
  manager.layout_dirty = true
}

mark_flexbox_dirty :: proc(manager: ^Manager, handle: FlexBoxHandle) {
  fb, found := cont.get(manager.flexboxes, handle)
  if !found do return

  fb.layout_dirty = true
  manager.layout_dirty = true

  // Mark parent dirty too (layout changes propagate up)
  if fb.parent.index != 0 {
    mark_flexbox_dirty(manager, fb.parent)
  }
}

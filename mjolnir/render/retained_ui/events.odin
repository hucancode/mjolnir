package retained_ui

import cont "../../containers"
import "core:math"
import "core:math/linalg"

// =============================================================================
// Event Types
// =============================================================================

EventType :: enum {
  MOUSE_ENTER,
  MOUSE_LEAVE,
  MOUSE_DOWN,
  MOUSE_UP,
  CLICK,
}

Event :: struct {
  type:          EventType,
  target:        ElementHandle,
  mouse_pos:     [2]f32, // Relative to element
  mouse_pos_abs: [2]f32, // Absolute screen position
  mouse_button:  u8, // 0=left, 1=middle, 2=right
  consumed:      bool, // Set to true to stop propagation
}

EventCallback :: proc(event: ^Event, user_data: rawptr)

EventHandler :: struct {
  event_type: EventType,
  callback:   EventCallback,
  user_data:  rawptr,
}

// =============================================================================
// Event Registration
// =============================================================================

// Register a click handler
on_click :: proc(
  manager: ^Manager,
  handle: ElementHandle,
  callback: EventCallback,
  user_data: rawptr = nil,
) {
  on_event(manager, handle, .CLICK, callback, user_data)
}

// Register hover enter and leave handlers
on_hover :: proc(
  manager: ^Manager,
  handle: ElementHandle,
  enter_callback: EventCallback,
  leave_callback: EventCallback,
  user_data: rawptr = nil,
) {
  if enter_callback != nil {
    on_event(manager, handle, .MOUSE_ENTER, enter_callback, user_data)
  }
  if leave_callback != nil {
    on_event(manager, handle, .MOUSE_LEAVE, leave_callback, user_data)
  }
}

// Register any event type handler
on_event :: proc(
  manager: ^Manager,
  handle: ElementHandle,
  event_type: EventType,
  callback: EventCallback,
  user_data: rawptr = nil,
) {
  if callback == nil do return

  handler := EventHandler {
    event_type = event_type,
    callback   = callback,
    user_data  = user_data,
  }

  if handle not_in manager.event_handlers {
    manager.event_handlers[handle] = make([dynamic]EventHandler, 0, 4)
  }
  append(&manager.event_handlers[handle], handler)
}

// Remove all handlers for a specific event type
remove_event :: proc(
  manager: ^Manager,
  handle: ElementHandle,
  event_type: EventType,
) {
  handlers, found := &manager.event_handlers[handle]
  if !found do return

  // Remove matching handlers (iterate backwards to safely remove)
  for i := len(handlers) - 1; i >= 0; i -= 1 {
    if handlers[i].event_type == event_type {
      ordered_remove(handlers, i)
    }
  }

  // Clean up empty handler lists
  if len(handlers^) == 0 {
    delete(handlers^)
    delete_key(&manager.event_handlers, handle)
  }
}

// Remove all handlers for an element
remove_all_events :: proc(manager: ^Manager, handle: ElementHandle) {
  if handlers, found := &manager.event_handlers[handle]; found {
    delete(handlers^)
    delete_key(&manager.event_handlers, handle)
  }
}

// =============================================================================
// Event Dispatch
// =============================================================================

// Dispatch an event to all registered handlers for an element
dispatch_event :: proc(manager: ^Manager, event: ^Event) {
  handlers, found := manager.event_handlers[event.target]
  if !found do return

  for handler in handlers {
    if handler.event_type == event.type && handler.callback != nil {
      handler.callback(event, handler.user_data)
      if event.consumed do break
    }
  }
}

// =============================================================================
// Hit Testing
// =============================================================================

// Test if a point is inside an element's bounds (with transform)
hit_test_element :: proc(
  manager: ^Manager,
  handle: ElementHandle,
  point: [2]f32,
) -> bool {
  element, found := cont.get(manager.elements, handle)
  if !found do return false

  rect: [4]f32
  world_transform: WorldTransform2D

  switch &data in element.data {
  case Quad2D:
    if !data.visible do return false
    rect = data.computed_rect
    world_transform = data.world_transform
  case Text2D:
    if !data.visible do return false
    rect = data.computed_rect
    world_transform = data.world_transform
  case Mesh2D:
    if !data.visible do return false
    rect = data.computed_rect
    world_transform = data.world_transform
  }

  return hit_test_rect_with_transform(point, rect, world_transform)
}

// Test if a point is inside a FlexBox's bounds
hit_test_flexbox :: proc(
  manager: ^Manager,
  handle: FlexBoxHandle,
  point: [2]f32,
) -> bool {
  fb, found := cont.get(manager.flexboxes, handle)
  if !found || !fb.visible do return false

  return hit_test_rect_with_transform(
    point,
    fb.computed_rect,
    fb.world_transform,
  )
}

// Test if a point is inside a rectangle with transform applied
hit_test_rect_with_transform :: proc(
  point: [2]f32,
  rect: [4]f32,
  transform: WorldTransform2D,
) -> bool {
  // If no rotation/scale, use simple AABB test
  if transform.rotation == 0 && transform.scale == {1, 1} {
    return(
      point.x >= rect.x &&
      point.x <= rect.x + rect.z &&
      point.y >= rect.y &&
      point.y <= rect.y + rect.w \
    )
  }

  // Transform the point into local space
  local_point := transform_point_to_local(point, transform.mat)

  // Test against untransformed rect at origin
  return(
    local_point.x >= 0 &&
    local_point.x <= rect.z &&
    local_point.y >= 0 &&
    local_point.y <= rect.w \
  )
}

// Transform a world point into local space using the inverse transform matrix
transform_point_to_local :: proc(
  point: [2]f32,
  world_mat: matrix[3, 3]f32,
) -> [2]f32 {
  inv := linalg.matrix3_inverse(world_mat)
  local := inv * [3]f32{point.x, point.y, 1}
  return {local.x, local.y}
}

// Get local coordinates of a point relative to an element
get_local_point :: proc(
  manager: ^Manager,
  handle: ElementHandle,
  world_point: [2]f32,
) -> [2]f32 {
  element, found := cont.get(manager.elements, handle)
  if !found do return world_point

  world_mat: matrix[3, 3]f32
  switch &data in element.data {
  case Quad2D:
    world_mat = data.world_transform.mat
  case Text2D:
    world_mat = data.world_transform.mat
  case Mesh2D:
    world_mat = data.world_transform.mat
  }

  return transform_point_to_local(world_point, world_mat)
}

// =============================================================================
// Find Element at Point
// =============================================================================

// Find the topmost element at a given point (z-sorted)
find_element_at_point :: proc(
  manager: ^Manager,
  point: [2]f32,
) -> (
  ElementHandle,
  bool,
) {
  best_handle: ElementHandle
  best_z: f32 = -999999

  // Check all elements
  for &entry, i in manager.elements.entries {
    if !entry.active do continue

    handle := ElementHandle {
      index      = u32(i),
      generation = entry.generation,
    }
    element := &entry.item

    z_order: f32
    visible: bool

    switch &data in element.data {
    case Quad2D:
      z_order = data.z_order
      visible = data.visible
    case Text2D:
      z_order = data.z_order
      visible = data.visible
    case Mesh2D:
      z_order = data.z_order
      visible = data.visible
    }

    if !visible do continue

    if hit_test_element(manager, handle, point) {
      if z_order > best_z {
        best_z = z_order
        best_handle = handle
      }
    }
  }

  return best_handle, best_handle.index != 0 || best_handle.generation != 0
}

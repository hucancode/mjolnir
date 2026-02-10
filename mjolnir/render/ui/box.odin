package ui

import cont "../../containers"
import "core:log"

create_box :: proc(
  sys: ^System,
  position: [2]f32,
  size: [2]f32,
  background_color: [4]u8 = {0, 0, 0, 0},
  z_order: i32 = 0,
) -> (
  BoxHandle,
  bool,
) {
  handle, widget, ok := cont.alloc(&sys.widget_pool, UIWidgetHandle)
  if !ok {
    log.error("Failed to allocate UI widget handle for Box")
    return {}, false
  }

  widget^ = Box {
    type             = .Box,
    position         = position,
    world_position   = position,
    z_order          = z_order,
    visible          = true,
    size             = size,
    background_color = background_color,
    children         = make([dynamic]UIWidgetHandle, 0, 8),
  }

  return BoxHandle(handle), true
}

box_add_child :: proc(
  sys: ^System,
  parent_handle: BoxHandle,
  child_handle: UIWidgetHandle,
) {
  parent_widget := get_box(sys, parent_handle)
  if parent_widget == nil do return

  child_widget := get_widget(sys, child_handle)
  if child_widget == nil do return

  // Set parent reference
  child_base := get_widget_base(child_widget)
  if child_base != nil {
    child_base.parent = UIWidgetHandle(parent_handle)
  }

  // Add to children list
  append(&parent_widget.children, child_handle)
}

box_remove_child :: proc(
  sys: ^System,
  parent_handle: BoxHandle,
  child_handle: UIWidgetHandle,
) {
  parent_widget := get_box(sys, parent_handle)
  if parent_widget == nil do return

  // Find and remove child
  for i := 0; i < len(parent_widget.children); i += 1 {
    if parent_widget.children[i] == child_handle {
      ordered_remove(&parent_widget.children, i)

      // Clear parent reference
      child_widget := get_widget(sys, child_handle)
      if child_widget != nil {
        child_base := get_widget_base(child_widget)
        if child_base != nil {
          child_base.parent = nil
        }
      }
      break
    }
  }
}

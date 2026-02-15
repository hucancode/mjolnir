package ui

import cont "../../containers"
import "core:log"

compute_layout :: proc(sys: ^System, root: UIWidgetHandle) {
  widget := get_widget(sys, root)
  if widget == nil do return

  base := get_widget_base(widget)
  if base == nil do return

  // Compute world position from parent
  if parent_handle, has_parent := base.parent.?; has_parent {
    parent := get_widget(sys, parent_handle)
    if parent != nil {
      parent_base := get_widget_base(parent)
      if parent_base != nil {
        base.world_position = parent_base.world_position + base.position
      }
    }
  } else {
    base.world_position = base.position
  }

  // Recurse to children
  #partial switch w in widget {
  case Box:
    for child_handle in w.children {
      compute_layout(sys, child_handle)
    }
  }
}

compute_layout_all :: proc(sys: ^System) {
  // Compute layout for all root widgets (widgets without parents)
  for &entry, i in sys.widget_pool.entries {
    if !entry.active do continue

    widget := &entry.item
    if widget == nil do continue

    base := get_widget_base(widget)
    if base == nil do continue

    // Only process root widgets
    if _, has_parent := base.parent.?; !has_parent {
      // Construct handle from entry
      handle: UIWidgetHandle = {
        index      = u32(i),
        generation = entry.generation,
      }
      compute_layout(sys, handle)
    }
  }
}

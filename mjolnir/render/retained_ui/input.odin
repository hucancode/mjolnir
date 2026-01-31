package retained_ui

import cont "../../containers"

// =============================================================================
// Input Processing
// =============================================================================

update_input :: proc(
  manager: ^Manager,
  mouse_x, mouse_y: f32,
  mouse_down: bool,
) {
  manager.mouse_pos = {mouse_x, mouse_y}
  mouse_clicked := !manager.mouse_down && mouse_down
  mouse_released := manager.mouse_down && !mouse_down
  manager.mouse_clicked = mouse_clicked
  manager.mouse_released = mouse_released
  manager.mouse_down = mouse_down

  // Find element under cursor
  new_hovered, found := find_element_at_point(manager, manager.mouse_pos)

  // Handle hover enter/leave
  if new_hovered != manager.hovered_element {
    // Dispatch leave event to old element
    if manager.hovered_element.index != 0 ||
       manager.hovered_element.generation != 0 {
      leave_event := Event {
        type          = .MOUSE_LEAVE,
        target        = manager.hovered_element,
        mouse_pos_abs = manager.mouse_pos,
      }
      dispatch_event(manager, &leave_event)
    }

    // Dispatch enter event to new element
    if found {
      enter_event := Event {
        type          = .MOUSE_ENTER,
        target        = new_hovered,
        mouse_pos     = get_local_point(
          manager,
          new_hovered,
          manager.mouse_pos,
        ),
        mouse_pos_abs = manager.mouse_pos,
      }
      dispatch_event(manager, &enter_event)
    }

    manager.hovered_element = new_hovered
  }

  // Handle mouse down
  if mouse_clicked && found {
    down_event := Event {
      type          = .MOUSE_DOWN,
      target        = new_hovered,
      mouse_pos     = get_local_point(manager, new_hovered, manager.mouse_pos),
      mouse_pos_abs = manager.mouse_pos,
      mouse_button  = 0,
    }
    dispatch_event(manager, &down_event)

    // Update focus
    manager.focused_element = new_hovered
  }

  // Handle mouse up
  if mouse_released {
    if manager.hovered_element.index != 0 ||
       manager.hovered_element.generation != 0 {
      up_event := Event {
        type          = .MOUSE_UP,
        target        = manager.hovered_element,
        mouse_pos     = get_local_point(
          manager,
          manager.hovered_element,
          manager.mouse_pos,
        ),
        mouse_pos_abs = manager.mouse_pos,
        mouse_button  = 0,
      }
      dispatch_event(manager, &up_event)
    }
  }

  // Handle click (mouse up over same element that was clicked down on)
  if mouse_released && found && new_hovered == manager.hovered_element {
    click_event := Event {
      type          = .CLICK,
      target        = new_hovered,
      mouse_pos     = get_local_point(manager, new_hovered, manager.mouse_pos),
      mouse_pos_abs = manager.mouse_pos,
      mouse_button  = 0,
    }
    dispatch_event(manager, &click_event)
  }

  // Clear focus if clicked outside any element
  if mouse_clicked && !found {
    manager.focused_element = {}
  }
}

// Handle text input for focused TextInput widgets
input_text :: proc(manager: ^Manager, text: string) {
  if manager.focused_element.index == 0 &&
     manager.focused_element.generation == 0 {
    return
  }

  // This will be called from widget-level handlers
  // For now, just store the focused element
}

// Handle key input (backspace, etc)
input_key :: proc(manager: ^Manager, key: int, action: int) {
  if manager.focused_element.index == 0 &&
     manager.focused_element.generation == 0 {
    return
  }

  // Key codes (GLFW-style)
  KEY_BACKSPACE :: 259
  KEY_DELETE :: 261
  KEY_LEFT :: 263
  KEY_RIGHT :: 262

  // Action codes
  ACTION_PRESS :: 1
  ACTION_REPEAT :: 2

  if action != ACTION_PRESS && action != ACTION_REPEAT {
    return
  }

  // Handle key events at widget level
}

// =============================================================================
// Focus Management
// =============================================================================

set_focus :: proc(manager: ^Manager, handle: ElementHandle) {
  manager.focused_element = handle
}

clear_focus :: proc(manager: ^Manager) {
  manager.focused_element = {}
}

get_focused_element :: proc(manager: ^Manager) -> ElementHandle {
  return manager.focused_element
}

is_focused :: proc(manager: ^Manager, handle: ElementHandle) -> bool {
  return manager.focused_element == handle
}

// =============================================================================
// Hover State
// =============================================================================

get_hovered_element :: proc(manager: ^Manager) -> ElementHandle {
  return manager.hovered_element
}

is_hovered :: proc(manager: ^Manager, handle: ElementHandle) -> bool {
  return manager.hovered_element == handle
}

// =============================================================================
// Mouse State Queries
// =============================================================================

get_mouse_position :: proc(manager: ^Manager) -> [2]f32 {
  return manager.mouse_pos
}

is_mouse_down :: proc(manager: ^Manager) -> bool {
  return manager.mouse_down
}

was_mouse_clicked :: proc(manager: ^Manager) -> bool {
  return manager.mouse_clicked
}

was_mouse_released :: proc(manager: ^Manager) -> bool {
  return manager.mouse_released
}

package render

import cont "../containers"
import "../input"

MouseEventType :: enum {
  CLICK_DOWN,
  CLICK_UP,
  MOVE,
  HOVER_IN,
  HOVER_OUT,
}

KeyEventType :: enum {
  KEY_DOWN,
  KEY_UP,
}

MouseEvent :: struct {
  type:      MouseEventType,
  position:  [2]f32,
  button:    input.MouseButton, // CLICK_DOWN / CLICK_UP only
  widget:    UIWidgetHandle, // target; stays the same while bubbling
  user_data: rawptr, // of the widget whose handler runs
}

KeyEvent :: struct {
  type:      KeyEventType,
  key:       input.Key,
  repeat:    bool, // KEY_DOWN from OS auto-repeat
  widget:    UIWidgetHandle,
  user_data: rawptr,
}

TextEvent :: struct {
  text:      string, // UTF-8, valid only during the handler
  widget:    UIWidgetHandle,
  user_data: rawptr,
}

MouseEventProc :: #type proc(event: MouseEvent)
KeyEventProc :: #type proc(event: KeyEvent)
TextEventProc :: #type proc(event: TextEvent)

EventHandlers :: struct {
  on_mouse_down: MouseEventProc,
  on_mouse_up:   MouseEventProc,
  on_move:       MouseEventProc,
  on_hover_in:   MouseEventProc,
  on_hover_out:  MouseEventProc,
  on_key_down:   KeyEventProc,
  on_key_up:     KeyEventProc,
  on_text:       TextEventProc,
}

@(private)
point_in_widget :: proc(widget: ^Widget, point: [2]f32) -> bool {
  lo, hi: [2]f32
  switch w in widget {
  case Quad2D:
    lo, hi = w.world_position, w.world_position + w.size
  case Box:
    lo, hi = w.world_position, w.world_position + w.size
  case Text2D:
    if len(w.glyphs) == 0 do return false
    lo, hi = w.world_position + w.local_min, w.world_position + w.local_max
  case Mesh2D:
    if len(w.vertices) == 0 do return false
    lo, hi = w.world_position + w.local_min, w.world_position + w.local_max
  }
  return point.x >= lo.x && point.x <= hi.x && point.y >= lo.y && point.y <= hi.y
}

// Topmost visible widget containing `point`. With `interactive_only`, only
// widgets that handle mouse events (themselves or via an ancestor) count.
@(private)
pick_widget :: proc(
  sys: ^UISystem,
  point: [2]f32,
  interactive_only := false,
) -> Maybe(UIWidgetHandle) {
  best_widget: Maybe(UIWidgetHandle) = nil
  best_z: i32 = min(i32)
  it := cont.iterator(&sys.widget_pool)
  for widget, handle in cont.next(&it, UIWidgetHandle) {
    base := get_widget_base(widget)
    if !base.visible || base.z_order <= best_z && best_widget != nil do continue
    if !point_in_widget(widget, point) do continue
    if interactive_only && !handles_mouse(sys, handle) do continue
    best_z = base.z_order
    best_widget = handle
  }
  return best_widget
}

// Deliver `event` to the widget, then to each ancestor in turn. Each widget
// sees the event with its own user_data.
@(private)
dispatch_event :: proc(sys: ^UISystem, widget_handle: UIWidgetHandle, event: $E) {
  event := event
  h, ok := widget_handle, true
  for ok {
    widget := get_widget(sys, h)
    if widget == nil do return
    base := get_widget_base(widget)
    event.user_data = base.user_data
    if f := event_handler(&base.event_handlers, event); f != nil do f(event)
    h, ok = base.parent.?
  }
}

@(private = "file")
event_handler :: proc {
  mouse_event_handler,
  key_event_handler,
  text_event_handler,
}

@(private = "file")
mouse_event_handler :: proc(e: ^EventHandlers, event: MouseEvent) -> MouseEventProc {
  switch event.type {
  case .CLICK_DOWN: return e.on_mouse_down
  case .CLICK_UP:   return e.on_mouse_up
  case .MOVE:       return e.on_move
  case .HOVER_IN:   return e.on_hover_in
  case .HOVER_OUT:  return e.on_hover_out
  }
  return nil
}

@(private = "file")
key_event_handler :: proc(e: ^EventHandlers, event: KeyEvent) -> KeyEventProc {
  return e.on_key_down if event.type == .KEY_DOWN else e.on_key_up
}

@(private = "file")
text_event_handler :: proc(e: ^EventHandlers, _: TextEvent) -> TextEventProc {
  return e.on_text
}

// True when the mouse belongs to the UI: an interactive widget is hovered or
// holds a press.
@(private)
wants_mouse :: proc(sys: ^UISystem) -> bool {
  return sys.hovered != nil || sys.captured != nil
}

// True when the focused widget (or an ancestor) handles key or text events.
@(private)
wants_keyboard :: proc(sys: ^UISystem) -> bool {
  h, ok := sys.focused.?
  for ok {
    widget := get_widget(sys, h)
    if widget == nil do return false
    base := get_widget_base(widget)
    e := base.event_handlers
    if e.on_key_down != nil || e.on_key_up != nil || e.on_text != nil do return true
    h, ok = base.parent.?
  }
  return false
}

// Run one tick of input through the widget tree, then capture the mouse /
// keyboard the UI owns (see input.State). Skipped while another consumer
// (the debug UI) holds the mouse.
process_input :: proc(sys: ^UISystem, s: ^input.State) {
  if s.mouse_captured do return
  dispatch_input(sys, s)
  if wants_mouse(sys) do s.mouse_captured = true
  if wants_keyboard(sys) do s.keyboard_captured = true
}

// Run one tick of input through the widget tree. Hit testing considers only
// interactive widgets (see pick_widget). Dispatches HOVER_IN / HOVER_OUT when
// the hovered widget changes, MOVE to the captured or hovered widget,
// CLICK_DOWN to the hovered widget (capturing it and taking focus; a press
// over nothing clears focus), CLICK_UP to the captured widget, and key and
// text events to the focused widget. Every event bubbles to the parents.
@(private = "file")
dispatch_input :: proc(sys: ^UISystem, s: ^input.State) {
  pos := s.cursor
  current := pick_widget(sys, pos, interactive_only = true)
  if current != sys.hovered {
    if h, ok := sys.hovered.?; ok {
      dispatch_event(sys, h, MouseEvent{type = .HOVER_OUT, position = pos, widget = h})
    }
    if h, ok := current.?; ok {
      dispatch_event(sys, h, MouseEvent{type = .HOVER_IN, position = pos, widget = h})
    }
    sys.hovered = current
  }
  if s.mouse_delta != {} {
    target := sys.captured if sys.captured != nil else current
    if h, ok := target.?; ok {
      dispatch_event(sys, h, MouseEvent{type = .MOVE, position = pos, widget = h})
    }
  }
  for b in input.MouseButton {
    if input.mouse_pressed(s, b) {
      sys.focused = current
      if sys.captured == nil do sys.captured = current
      if h, ok := current.?; ok {
        dispatch_event(sys, h, MouseEvent{type = .CLICK_DOWN, position = pos, button = b, widget = h})
      }
    }
    if input.mouse_released(s, b) {
      target := sys.captured if sys.captured != nil else current
      if h, ok := target.?; ok {
        dispatch_event(sys, h, MouseEvent{type = .CLICK_UP, position = pos, button = b, widget = h})
      }
    }
  }
  if s.buttons == {} do sys.captured = nil
  h, has_focus := sys.focused.?
  if !has_focus do return
  if get_widget(sys, h) == nil {
    sys.focused = nil
    return
  }
  it := 0
  for key, pressed in input.next_key_edge(s, &it) {
    dispatch_event(sys, h, KeyEvent{type = .KEY_DOWN if pressed else .KEY_UP, key = key, widget = h})
  }
  for key in input.Key {
    if !input.key_repeated(s, key) do continue
    dispatch_event(sys, h, KeyEvent{type = .KEY_DOWN, key = key, repeat = true, widget = h})
  }
  if t := input.text(s); len(t) > 0 {
    dispatch_event(sys, h, TextEvent{text = t, widget = h})
  }
}

@(private)
handles_mouse :: proc(sys: ^UISystem, handle: UIWidgetHandle) -> bool {
  h, ok := handle, true
  for ok {
    widget := get_widget(sys, h)
    if widget == nil do return false
    base := get_widget_base(widget)
    e := base.event_handlers
    if e.on_mouse_down != nil || e.on_mouse_up != nil || e.on_move != nil ||
       e.on_hover_in != nil || e.on_hover_out != nil {
      return true
    }
    h, ok = base.parent.?
  }
  return false
}

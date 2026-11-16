#+build js
package main

import js "core:sys/wasm/js"
import "mjolnir/input"

events, state: input.State

main :: proc() {
  if !setup() do return
  js.add_event_listener("output", .Mouse_Down, nil, on_mouse)
  js.add_window_event_listener(.Mouse_Up, nil, on_mouse)
  js.add_window_event_listener(.Mouse_Move, nil, on_mouse)
  js.add_event_listener("output", .Wheel, nil, on_wheel)
}

on_mouse :: proc(e: js.Event) {
  r := js.get_bounding_client_rect("output")
  input.cursor_event(&events, {f32(f64(e.mouse.client.x) - r.x), f32(f64(e.mouse.client.y) - r.y)})
  if e.kind != .Mouse_Move && e.mouse.button == 0 do input.button_event(&events, .LEFT, .PRESS if e.kind == .Mouse_Down else .RELEASE)
}

on_wheel :: proc(e: js.Event) {
  input.scroll_event(&events, {0, f32(-e.wheel.delta.y / 100)})
}

@(export)
step :: proc(dt: f64) -> bool {
  defer free_all(context.temp_allocator)
  input.drain(&events, &state)
  r := js.get_bounding_client_rect("output")
  size := [2]f32{f32(max(r.width, 1)), f32(max(r.height, 1))}
  if tick(&state, size) do js.set_element_key_string("output", "innerHTML", svg(size))
  return true
}

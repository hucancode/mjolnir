#+build js
package main

import js "core:sys/wasm/js"

main :: proc() {
  if !setup() do return
  go_to({8, 0, -8})
  js.add_event_listener("output", .Click, nil, on_click)
}

on_click :: proc(e: js.Event) {
  r := js.get_bounding_client_rect("map")
  side := min(r.width, r.height)
  u := (f64(e.mouse.client.x) - r.x - (r.width - side) / 2) / side
  v := (f64(e.mouse.client.y) - r.y - (r.height - side) / 2) / side
  go_to({f32(u * 2 - 1) * HALF, 0, f32(v * 2 - 1) * HALF})
}

@(export)
step :: proc(dt: f64) -> bool {
  defer free_all(context.temp_allocator)
  walk()
  js.set_element_key_string("output", "innerHTML", svg())
  return true
}

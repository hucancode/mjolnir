#+build js
package main

import js "core:sys/wasm/js"

main :: proc() {
  setup()
}

@(export)
step :: proc(dt: f64) -> bool {
  defer free_all(context.temp_allocator)
  r := js.get_bounding_client_rect("output")
  size := [2]f32{f32(max(r.width, 1)), f32(max(r.height, 1))}
  draw(size, 0.7)
  js.set_element_key_string("output", "innerHTML", svg(size))
  return true
}

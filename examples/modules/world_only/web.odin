#+build js
package main

import js "core:sys/wasm/js"

main :: proc() {
  setup()
}

@(export)
step :: proc(dt: f64) -> bool {
  defer free_all(context.temp_allocator)
  tick()
  js.set_element_key_string("output", "innerHTML", svg())
  return true
}

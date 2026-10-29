#+build js
package main

import "core:strings"
import js "core:sys/wasm/js"

main :: proc() {
  setup()
}

@(export)
step :: proc(dt: f64) -> bool {
  defer free_all(context.temp_allocator)
  tick()
  done := ticks >= TICKS
  js.set_element_key_string("output", "innerHTML", strings.concatenate({svg(), "<pre>", summary(), "</pre>"} if done else {svg()}, context.temp_allocator))
  return !done
}

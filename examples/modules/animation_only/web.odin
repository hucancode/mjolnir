#+build js
package main

import "core:fmt"
import "core:strings"
import js "core:sys/wasm/js"

main :: proc() {
  setup()
}

@(export)
step :: proc(dt: f64) -> bool {
  defer free_all(context.temp_allocator)
  advance()
  b := strings.builder_make(context.temp_allocator)
  fmt.sbprintln(&b, `<svg xmlns="http://www.w3.org/2000/svg" viewBox="-100 0 400 500" style="background:#14161f">`)
  draw(&b, 60)
  fmt.sbprintln(&b, "</svg>")
  js.set_element_key_string("output", "innerHTML", strings.to_string(b))
  return true
}

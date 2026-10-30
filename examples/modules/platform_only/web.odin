#+build js
package main

import "core:strings"
import js "core:sys/wasm/js"

LINES :: 40

lines: [dynamic]string

report :: proc(line: string) {
  if len(lines) == LINES do delete(pop_front(&lines))
  append(&lines, strings.clone(line))
  js.set_element_style("output", "pointerEvents", "none")
  js.set_element_key_string("output", "textContent", strings.join(lines[:], "\n", context.temp_allocator))
}

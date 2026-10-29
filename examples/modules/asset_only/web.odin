#+build js
package main

import js "core:sys/wasm/js"

main :: proc() {
  report, _ := inspect(DEFAULT, #load("../../../" + DEFAULT))
  js.set_element_key_string("output", "textContent", report)
}

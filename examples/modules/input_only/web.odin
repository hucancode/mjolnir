#+build js
package main

import js "core:sys/wasm/js"

main :: proc() {
  js.set_element_key_string("output", "textContent", run())
}

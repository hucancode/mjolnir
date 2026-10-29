#+build js
package main

import "core:encoding/base64"
import "core:fmt"
import "core:strings"
import js "core:sys/wasm/js"
import "core:unicode/utf8"

typed: strings.Builder

main :: proc() {
  if !setup() do return
  js.add_window_event_listener(.Key_Down, nil, on_key)
  show()
}

on_key :: proc(e: js.Event) {
  if e.key.ctrl || e.key.meta do return
  if e.key.code == "Backspace" {
    strings.pop_rune(&typed)
  } else if utf8.rune_count(e.key.key) == 1 {
    strings.write_string(&typed, e.key.key)
  } else do return
  lines[2].text = strings.to_string(typed)
  show()
}

// show puts the text image, the atlas the glyphs came from and the layout report in the page.
show :: proc() {
  defer free_all(context.temp_allocator)
  image, report := text_png()
  b := strings.builder_make(context.temp_allocator)
  fmt.sbprintfln(&b, `<img src="data:image/png;base64,%s">`, base64.encode(image, allocator = context.temp_allocator))
  report, _ = strings.replace_all(report, "&", "&amp;", context.temp_allocator)
  report, _ = strings.replace_all(report, "<", "&lt;", context.temp_allocator)
  fmt.sbprintfln(&b, "<pre>%s</pre>", report)
  fmt.sbprintfln(&b, `<img src="data:image/png;base64,%s">`, base64.encode(atlas_png(), allocator = context.temp_allocator))
  js.set_element_key_string("output", "innerHTML", strings.to_string(b))
}

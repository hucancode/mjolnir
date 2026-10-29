#+build js
package main

import "core:encoding/base64"
import "core:fmt"
import "core:strings"
import js "core:sys/wasm/js"
import "mjolnir/geometry"

main :: proc() {
  scene := build_scene()
  defer geometry.destroy(scene)
  image, hits := trace(scene)
  svg, kept, total := cull()
  b := strings.builder_make(context.temp_allocator)
  fmt.sbprintfln(&b, "<p>%d vertices, %d triangles, %d of %d rays hit. <a download=\"shapes.obj\" href=\"data:text/plain;base64,%s\">shapes.obj</a></p>", len(scene.vertices), len(scene.indices) / 3, hits, WIDTH * HEIGHT, base64.encode(transmute([]u8)obj(scene), allocator = context.temp_allocator))
  fmt.sbprintfln(&b, `<img src="data:image/png;base64,%s">`, base64.encode(image, allocator = context.temp_allocator))
  fmt.sbprintfln(&b, "<p>%d of %d boxes in the frustum</p>%s", kept, total, svg)
  js.set_element_key_string("output", "innerHTML", strings.to_string(b))
}

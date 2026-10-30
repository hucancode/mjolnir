#+build js
package main

import "core:log"
import js "core:sys/wasm/js"
import "mjolnir/render"

frame := -1
logger: log.Logger

main :: proc() {
  logger = log.create_console_logger()
  context.logger = logger
  r = new(render.Renderer)
  if !render.init(r, "#canvas") do page_fail()
}

@(export)
step :: proc(dt: f64) -> bool {
  context.logger = logger
  if frame < 0 {
    if !render.ready(r) do return true
    if !setup() {
      page_fail()
      return false
    }
    page_ready()
  }
  frame += 1
  box := js.get_bounding_client_rect("canvas")
  ratio := js.device_pixel_ratio()
  size := [2]u32{u32(max(1, box.width * ratio)), u32(max(1, box.height * ratio))}
  if js.get_element_key_f64("canvas", "width") != f64(size.x) || js.get_element_key_f64("canvas", "height") != f64(size.y) {
    js.set_element_key_f64("canvas", "width", f64(size.x))
    js.set_element_key_f64("canvas", "height", f64(size.y))
  }
  draw(frame)
  return true
}

foreign import page "mjolnir"

@(default_calling_convention = "contextless")
foreign page {
  @(link_name = "ready")
  page_ready :: proc() ---
  @(link_name = "fail")
  page_fail :: proc() ---
}

package mjolnir

import "platform"
import "render"

// World-space ray from the main camera through a cursor position in window
// pixels (as reported by GLFW); the window DPI scale is applied here.
viewport_to_world_ray :: proc(
  engine: ^Engine,
  mouse_x, mouse_y: f32,
) -> (
  origin: [3]f32,
  dir: [3]f32,
  ok: bool,
) {
  cam := render.main_camera(&engine.render) or_return
  dpi := platform.dpi_scale(&engine.platform)
  origin, dir = render.camera_viewport_to_world_ray(cam, mouse_x * dpi, mouse_y * dpi)
  return origin, dir, true
}

// World-space ray through the current cursor position.
cursor_world_ray :: proc(engine: ^Engine) -> (origin: [3]f32, dir: [3]f32, ok: bool) {
  return viewport_to_world_ray(
    engine,
    f32(engine.platform.input.cur_mouse.x),
    f32(engine.platform.input.cur_mouse.y),
  )
}

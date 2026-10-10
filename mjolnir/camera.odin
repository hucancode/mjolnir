package mjolnir

import "platform"
import "render"

// World-space ray from the main camera through the cursor position of this
// tick's input snapshot. The cursor is in window pixels (as reported by GLFW);
// the window DPI scale is applied here.
cursor_world_ray :: proc(engine: ^Engine) -> (origin: [3]f32, dir: [3]f32, ok: bool) {
  cam := render.main_camera(&engine.render) or_return
  p := engine.input.cursor * platform.dpi_scale(&engine.platform)
  origin, dir = render.camera_viewport_to_world_ray(cam, p.x, p.y)
  return origin, dir, true
}

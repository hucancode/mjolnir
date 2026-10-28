package mjolnir

import "platform"
import "render"
import "world"

// frame is the usual Loop.frame body: poll the window's events, then render a frame at its size.
frame :: proc(p: ^platform.Platform, r: ^render.Renderer) -> bool {
  platform.poll_events(p)
  return render.frame(r, platform.framebuffer_size(p), platform.dpi_scale(p))
}

// update ends the usual Loop.update: world.update, its changes staged to render, then
// render.update.
update :: proc(w: ^world.World, r: ^render.Renderer, dt: f32) {
  world.update(w)
  render.stage_transforms(r, world.changes(w))
  render.update(r, dt)
}

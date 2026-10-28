package mjolnir

import "core:log"
import "platform"
import "render"
import "world"

@(private = "file")
MAX_CONSECUTIVE_RENDER_ERRORS :: 20

// Render failures in a row, reset by a good frame.
@(private = "file")
render_errors: int

// frame is the usual Loop.render body: poll the window's events, then render a frame at its
// size. false once the window should close or after too many render failures in a row.
frame :: proc(p: ^platform.Platform, r: ^render.Renderer) -> bool {
  if platform.should_close(p) do return false
  platform.poll_events(p)
  if render.frame(r, platform.framebuffer_size(p), platform.dpi_scale(p)) {
    render_errors = 0
    return true
  }
  render_errors += 1
  if render_errors < MAX_CONSECUTIVE_RENDER_ERRORS do return true
  log.error("Too many render errors, exiting...")
  platform.fail()
  return false
}

// update ends the usual Loop.update: world.update, its changes staged to render, then
// render.update.
update :: proc(w: ^world.World, r: ^render.Renderer, dt: f32) {
  world.update(w)
  render.stage_transforms(r, world.changes(w))
  render.update(r, dt)
}

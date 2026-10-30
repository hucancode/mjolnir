package mjolnir

import "core:log"
import "font"
import "input"
import "physics"
import "platform"
import "render"
import "ui"
import "world"

@(private = "file")
MAX_CONSECUTIVE_RENDER_ERRORS :: 20

// Render failures in a row, reset by a good frame.
@(private = "file")
render_errors: int

// frame is the usual Loop.render body: poll the window's events, then render a frame. false
// once the window should close or after too many render failures in a row.
frame :: proc(p: ^platform.Platform, r: ^render.Renderer) -> bool {
  if platform.should_close(p) do return false
  platform.poll_events(p)
  if render.frame(r) {
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

// sync_bodies moves every body's node (its user link) to where physics put it, and destroys the
// nodes of the bodies the last step killed for falling out of the world.
sync_bodies :: proc(w: ^world.World, p: ^physics.World) {
  for k in physics.killed(p) do world.destroy(w, world.NodeHandle(k.user))
  world.set_world_poses(w, physics.body_poses(p))
}

// orbit_drag steers the orbit from a tick of input and places camera on it (render.camera_orbit),
// unless a consumer captured the mouse (call it after the UIs that may, e.g. debugui.begin): it turns by the mouse movement times speed while a
// button of `rotate_with` is held ({} only zooms) and moves a step closer per scroll, keeping
// pitch short of the poles and distance in range.
orbit_drag :: proc(
  self: ^render.Orbit,
  camera: ^render.Camera,
  s: ^input.State,
  rotate_with: input.ButtonSet = {.LEFT},
  speed: f32 = 0.02,
  min_distance: f32 = 1,
  max_distance: f32 = 200,
) {
  if !s.mouse_captured {
    rotating := false
    for b in rotate_with do rotating ||= input.mouse_down(s, b)
    if rotating {
      self.yaw += s.mouse_delta.x * speed
      self.pitch = clamp(self.pitch + s.mouse_delta.y * speed, -1.5, 1.5)
    }
    self.distance = clamp(self.distance - s.scroll.y * 2, min_distance, max_distance)
  }
  render.camera_orbit(camera, self^)
}

// stage_ui brings gui up to date for r's window at p's DPI scale (ui.update) and stages its mesh over what is
// staged so far (render.stage_overlay_mesh), glyphs sampled from render.font_texture. Restaging
// an unchanged UI is a copy: layout and tessellation run only when it changed. It returns what
// the update redid.
stage_ui :: proc(r: ^render.Renderer, p: ^platform.Platform, gui: ^ui.UI, f: ^font.Font) -> (laid_out, painted: bool) {
  laid_out, painted = ui.update(gui, render.window_size(r), f, platform.dpi_scale(p))
  vertices, indices, batches := ui.mesh(gui)
  for b in batches {
    texture := render.font_texture(r, f) if b.texture == ui.FONT_TEXTURE else render.TextureHandle(b.texture)
    render.stage_overlay_mesh(r, vertices[b.first_vertex:][:b.vertex_count], indices[b.first_index:][:b.index_count], texture, b.clip)
  }
  return
}

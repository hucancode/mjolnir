package mjolnir

import "core:log"
import "font"
import "input"
import "physics"
import "platform"
import "render"
import "ui"
import "ux"
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

// orbit_drag steers the orbit from a tick of input and places camera on it (render.camera_orbit).
// It turns by the mouse movement times speed while a button of `rotate_with` is held ({} only
// zooms) and moves a step closer per scroll, keeping pitch short of the poles and distance in
// range. A captured mouse is left alone: call it after the UIs that capture it (debugui.begin).
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

// stage_ui brings gui up to date for r's window at p's DPI scale (ux.update) and stages its canvas
// with your `canvases` (render.stage_overlay), every batch sorted by z: the UI draws at z 0 and up,
// so draw under it at a negative z, over one of its nodes at ux.layer and over all of it at
// max(i32). Give your canvases p's DPI scale (ui.Canvas.dpi). Text draws in f. It returns what the
// update redid.
stage_ui :: proc(r: ^render.Renderer, p: ^platform.Platform, gui: ^ux.UI, f: ^font.Font, canvases: []^ui.Canvas = nil) -> (laid_out, painted: bool) {
  laid_out, painted = ux.update(gui, render.window_size(r), f, platform.dpi_scale(p))
  staged := make([dynamic]^ui.Canvas, 0, len(canvases) + 1, context.temp_allocator)
  append(&staged, ux.canvas(gui))
  append(&staged, ..canvases)
  render.stage_overlay(r, staged[:], f)
  return
}

// update_ui_input runs gui's input tick (ux.update_input) with p's clipboard: Ctrl or Cmd with V
// pastes it into the focused text, with C or X copies the selection onto it.
update_ui_input :: proc(p: ^platform.Platform, gui: ^ux.UI, s: ^input.State) {
  command := input.key_down(s, .LEFT_CONTROL) || input.key_down(s, .RIGHT_CONTROL) || input.key_down(s, .LEFT_SUPER) || input.key_down(s, .RIGHT_SUPER)
  clipboard := platform.clipboard(p, context.temp_allocator) if command && input.key_pressed(s, .V) else ""
  ux.update_input(gui, s, clipboard)
  if copied := ux.copied(gui); copied != "" do platform.set_clipboard(p, copied)
}

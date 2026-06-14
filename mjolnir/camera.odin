package mjolnir

import cont "containers"
import "gpu"
import "render"
import vk "vendor:vulkan"
import "world"

// Create a camera with explicit render-pass selection. World holds spatial
// state; render side stores enabled_passes + culling on its CameraTarget.
// Engine eagerly initialises both sides so per-frame sync only handles
// transform updates.
create_camera :: proc(
  engine: ^Engine,
  width, height: u32,
  enabled_passes: render.PassTypeSet = render.DEFAULT_ENABLED_PASSES,
  position: [3]f32 = {0, 0, 3},
  target: [3]f32 = {0, 0, 0},
  fov: f32 = 1.57079632679,
  near_plane: f32 = 0.1,
  far_plane: f32 = 100.0,
  enable_culling: bool = true,
) -> (
  handle: world.CameraHandle,
  ok: bool,
) #optional_ok {
  handle = world.create_camera(
    &engine.world,
    width,
    height,
    position,
    target,
    fov,
    near_plane,
    far_plane,
  ) or_return
  if render.init_camera_target(
    &engine.render,
    &engine.gctx,
    handle.index,
    vk.Extent2D{width, height},
    engine.swapchain.format.format,
    enabled_passes,
    enable_culling,
  ) != .SUCCESS {
    return {}, false
  }
  return handle, true
}

// Look up a camera's framebuffer attachment for the given pass type. Defaults
// to the engine's current frame_index so callers writing render-to-texture
// flows don't need to thread `engine.frame_index` through.
// Crosses the world (validity check) and render (attachment storage) boundaries.
get_camera_attachment :: proc(
  engine: ^Engine,
  camera_handle: world.CameraHandle,
  attachment_type: render.AttachmentType,
  frame_index: Maybe(u32) = nil,
) -> (
  handle: gpu.Texture2DHandle,
  ok: bool,
) #optional_ok {
  if !cont.is_valid(engine.world.cameras, camera_handle) do return {}, false
  fi := frame_index.? or_else engine.frame_index
  return engine.render.cameras[camera_handle.index].attachments[attachment_type][fi], true
}

// ---------- viewport / picking (window DPI + main camera) ----------

// Build a world-space ray from a logical cursor position (GLFW pixels).
// DPI is applied internally — callers pass raw cursor coordinates.
viewport_to_world_ray :: proc(
  engine: ^Engine,
  mouse_x, mouse_y: f32,
) -> (origin: [3]f32, dir: [3]f32, ok: bool) {
  cam, has := world.main_camera(&engine.world)
  if !has do return {}, {}, false
  dpi := get_window_dpi(engine.window)
  origin, dir = world.camera_viewport_to_world_ray(cam, mouse_x * dpi, mouse_y * dpi)
  return origin, dir, true
}

// World-space ray through the current cursor position.
cursor_world_ray :: proc(engine: ^Engine) -> (origin: [3]f32, dir: [3]f32, ok: bool) {
  return viewport_to_world_ray(engine, f32(engine.input.cur_mouse.x), f32(engine.input.cur_mouse.y))
}

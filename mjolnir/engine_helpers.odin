package mjolnir

import cont "containers"
import "core:c"
import nav "navigation"
import "navigation/recast"
import "core:time"
import "gpu"
import "physics"
import "render"
import "vendor:glfw"
import mu "vendor:microui"
import vk "vendor:vulkan"
import "world"

get_delta_time :: proc(self: ^Engine) -> f32 {
  return f32(time.duration_seconds(time.since(self.last_update_timestamp)))
}

time_since_start :: proc(self: ^Engine) -> f32 {
  return f32(time.duration_seconds(time.since(self.start_timestamp)))
}

load_gltf :: proc(
  engine: ^Engine,
  path: string,
) -> (
  nodes: [dynamic]world.NodeHandle,
  ok: bool,
) #optional_ok {
  create_texture_from_data_adapter := proc(
    pixel_data: []u8,
  ) -> (
    handle: gpu.Texture2DHandle,
    ok: bool,
  ) {
    engine_ctx := cast(^Engine)context.user_ptr
    if engine_ctx == nil {
      return {}, false
    }
    out_handle, ret := gpu.create_texture_2d_from_data(
      &engine_ctx.gctx,
      &engine_ctx.render.texture_manager,
      pixel_data,
      .R8G8B8A8_UNORM,
    )
    if ret != .SUCCESS {
      return {}, false
    }
    return out_handle, true
  }
  old_user_ptr := context.user_ptr
  context.user_ptr = engine
  defer context.user_ptr = old_user_ptr
  handles, result := world.load_gltf(
    &engine.world,
    create_texture_from_data_adapter,
    path,
  )
  return handles, result == .success
}

// MicroUI context for debug panels. Use inside `pre_render`.
ui_ctx :: proc(self: ^Engine) -> ^mu.Context {
  return &self.render.debug_ui.ctx
}

// True when GLFW key currently held.
is_key_down :: proc(self: ^Engine, key: c.int) -> bool {
  return glfw.GetKey(self.window, key) == glfw.PRESS
}

// True only on the frame `key` transitioned from up to down.
// Uses the engine's tracked input state — no manual prev-frame bookkeeping.
is_key_pressed :: proc(self: ^Engine, key: c.int) -> bool {
  if key < 0 || int(key) >= len(self.input.keys) do return false
  return self.input.keys[key] && !self.input.key_holding[key]
}

// True only on the frame `key` transitioned from down to up.
is_key_released :: proc(self: ^Engine, key: c.int) -> bool {
  if key < 0 || int(key) >= len(self.input.keys) do return false
  return !self.input.keys[key] && self.input.key_holding[key]
}

// True while mouse `button` is currently held.
is_mouse_down :: proc(self: ^Engine, button: c.int) -> bool {
  if button < 0 || int(button) >= len(self.input.mouse_buttons) do return false
  return self.input.mouse_buttons[button]
}

// True only on the frame mouse `button` transitioned from up to down.
is_mouse_pressed :: proc(self: ^Engine, button: c.int) -> bool {
  if button < 0 || int(button) >= len(self.input.mouse_buttons) do return false
  return self.input.mouse_buttons[button] && !self.input.mouse_holding[button]
}

// True only on the frame mouse `button` transitioned from down to up.
is_mouse_released :: proc(self: ^Engine, button: c.int) -> bool {
  if button < 0 || int(button) >= len(self.input.mouse_buttons) do return false
  return !self.input.mouse_buttons[button] && self.input.mouse_holding[button]
}

// Build a follow camera controller without exposing the GLFW window handle.
// The example pattern was `world.camera_controller_follow_init(engine.window, ...)`
// — leaking the window into gameplay code. Prefer this wrapper.
camera_controller_follow :: proc(
  engine: ^Engine,
  target: ^[3]f32,
  offset: [3]f32,
  follow_speed: f32 = 5.0,
) -> world.CameraController {
  return world.camera_controller_follow_init(engine.window, target, offset, follow_speed)
}

// Build an orbit controller. Same rationale as `camera_controller_follow`.
camera_controller_orbit :: proc(
  engine: ^Engine,
  target: [3]f32 = {0, 0, 0},
  distance: f32 = 5.0,
  yaw: f32 = 0,
  pitch: f32 = 0,
) -> world.CameraController {
  return world.camera_controller_orbit_init(engine.window, target, distance, yaw, pitch)
}

camera_controller_free :: proc(
  engine: ^Engine,
  move_speed: f32 = 5.0,
  rotation_speed: f32 = 2.0,
) -> world.CameraController {
  return world.camera_controller_free_init(engine.window, move_speed, rotation_speed)
}

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
  engine.render.cameras[handle.index] = {}
  cam := &engine.render.cameras[handle.index]
  if render.camera_init(
    &engine.gctx,
    cam,
    &engine.render.texture_manager,
    vk.Extent2D{width, height},
    engine.swapchain.format.format,
    vk.Format.D32_SFLOAT,
    enabled_passes,
    enable_culling,
    render.MAX_NODES_IN_SCENE,
  ) != .SUCCESS {
    return {}, false
  }
  if render.camera_allocate_descriptors(&engine.render, &engine.gctx, cam) != .SUCCESS {
    return {}, false
  }
  return handle, true
}

create_texture :: proc {
  create_texture_from_path,
  create_texture_from_data,
  create_texture_from_pixels,
  create_texture_empty,
}

create_texture_from_path :: proc(
  engine: ^Engine,
  path: string,
  format: vk.Format = .R8G8B8A8_SRGB,
  generate_mips := false,
  usage: vk.ImageUsageFlags = {.SAMPLED},
  is_hdr := false,
) -> (
  handle: gpu.Texture2DHandle,
  ok: bool,
) #optional_ok {
  ret: vk.Result
  handle, ret = gpu.create_texture_2d_from_path(
    &engine.gctx,
    &engine.render.texture_manager,
    path,
    format,
    generate_mips,
    usage,
    is_hdr,
  )
  return handle, ret == .SUCCESS
}

create_texture_from_data :: proc(
  engine: ^Engine,
  data: []u8,
  format: vk.Format = .R8G8B8A8_SRGB,
  generate_mips := false,
) -> (
  handle: gpu.Texture2DHandle,
  ok: bool,
) #optional_ok {
  ret: vk.Result
  handle, ret = gpu.create_texture_2d_from_data(
    &engine.gctx,
    &engine.render.texture_manager,
    data,
    format,
    generate_mips,
  )
  return handle, ret == .SUCCESS
}

create_texture_from_pixels :: proc(
  engine: ^Engine,
  pixels: []u8,
  extent: vk.Extent2D,
  format: vk.Format = .R8G8B8A8_SRGB,
  generate_mips := false,
) -> (
  handle: gpu.Texture2DHandle,
  ok: bool,
) #optional_ok {
  ret: vk.Result
  handle, ret = gpu.allocate_texture_2d_with_data(
    &engine.render.texture_manager,
    &engine.gctx,
    raw_data(pixels),
    vk.DeviceSize(len(pixels)),
    extent,
    format,
    {.SAMPLED},
    generate_mips,
  )
  return handle, ret == .SUCCESS
}

create_texture_empty :: proc(
  engine: ^Engine,
  extent: vk.Extent2D,
  format: vk.Format,
  usage: vk.ImageUsageFlags = {.COLOR_ATTACHMENT, .SAMPLED},
) -> (
  handle: gpu.Texture2DHandle,
  ok: bool,
) #optional_ok {
  ret: vk.Result
  handle, ret = gpu.allocate_texture_2d(
    &engine.render.texture_manager,
    &engine.gctx,
    extent,
    format,
    usage,
  )
  return handle, ret == .SUCCESS
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

setup_navmesh :: proc(
  engine: ^Engine,
  config: nav.NavMeshConfig = nav.DEFAULT_NAVMESH_CONFIG,
  include_filter: world.NodeTagSet = {},
  exclude_filter: world.NodeTagSet = {},
) -> bool {
  build_area_types_from_tags :: proc(node_infos: []world.BakedNodeInfo) -> []u8 {
    area_types := make([dynamic]u8, 0, len(node_infos) * 10)
    for info in node_infos {
      triangle_count := info.index_count / 3
      area_type :=
        .NAVMESH_OBSTACLE in info.tags ? u8(recast.RC_NULL_AREA) : u8(recast.RC_WALKABLE_AREA)
      for _ in 0 ..< triangle_count {
        append(&area_types, area_type)
      }
    }
    return area_types[:]
  }
  world.traverse(&engine.world)
  baked_geom, node_infos, bake_ok := world.bake_geometry(
    &engine.world,
    include_filter,
    exclude_filter,
    true,
  )
  if !bake_ok {
    return false
  }
  defer {
    delete(baked_geom.vertices)
    delete(baked_geom.indices)
    delete(node_infos)
  }
  nav_vertices, nav_indices := nav.convert_geometry_to_nav(
    baked_geom.vertices,
    baked_geom.indices,
  )
  defer {
    delete(nav_vertices)
    delete(nav_indices)
  }
  area_types := build_area_types_from_tags(node_infos)
  defer delete(area_types)
  recast_config := nav.config_to_recast(config)
  nav_geom := nav.NavigationGeometry {
    vertices   = nav_vertices,
    indices    = nav_indices,
    area_types = area_types,
  }
  if !nav.build_navmesh(&engine.nav.nav_mesh, nav_geom, recast_config) {
    return false
  }
  if !nav.init(&engine.nav) {
    return false
  }
  return true
}

@(private = "file")
_attach_visual_mesh :: proc(
  engine: ^Engine,
  parent: world.NodeHandle,
  collider: physics.Collider,
  mesh: world.MeshHandle,
  material: world.MaterialHandle,
  visual_scale: Maybe([3]f32),
  cast_shadow: bool,
) {
  if mesh.generation == 0 do return
  visual, _ := world.spawn_child(&engine.world, parent, attachment = world.MeshAttachment{handle = mesh, material = material, cast_shadow = cast_shadow})
  s := visual_scale.? or_else physics.collider_visual_scale(collider)
  world.scale_xyz(&engine.world, visual, s.x, s.y, s.z)
}

spawn_static :: proc(
  engine: ^Engine,
  position: [3]f32,
  collider: physics.Collider,
  mesh: world.MeshHandle = {},
  material: world.MaterialHandle = {},
  visual_scale: Maybe([3]f32) = nil,
  cast_shadow: bool = true,
) -> world.NodeHandle {
  parent, _ := world.spawn(&engine.world, position)
  n, _ := world.node(&engine.world, parent)
  physics.create_static_body(&engine.physics, n.transform.position, n.transform.rotation, collider)
  _attach_visual_mesh(engine, parent, collider, mesh, material, visual_scale, cast_shadow)
  return parent
}

spawn_dynamic :: proc(
  engine: ^Engine,
  position: [3]f32,
  mass: f32,
  collider: physics.Collider,
  mesh: world.MeshHandle = {},
  material: world.MaterialHandle = {},
  visual_scale: Maybe([3]f32) = nil,
  cast_shadow: bool = true,
) -> (parent: world.NodeHandle, body: physics.DynamicRigidBodyHandle) {
  parent, _ = world.spawn(&engine.world, position)
  n, _ := world.node(&engine.world, parent)
  body = physics.create_dynamic_body(&engine.physics, n.transform.position, n.transform.rotation, mass, collider)
  if b, ok := physics.get_dynamic_body(&engine.physics, body); ok {
    physics.set_inertia_from_collider(b, collider)
  }
  n.attachment = world.RigidBodyAttachment{body_handle = body}
  _attach_visual_mesh(engine, parent, collider, mesh, material, visual_scale, cast_shadow)
  return
}

spawn_trigger :: proc(
  engine: ^Engine,
  position: [3]f32,
  collider: physics.Collider,
  mesh: world.MeshHandle = {},
  material: world.MaterialHandle = {},
  visual_scale: Maybe([3]f32) = nil,
  cast_shadow: bool = true,
) -> (parent: world.NodeHandle, body: physics.TriggerHandle, ok: bool) {
  parent = world.spawn(&engine.world, position) or_return
  body = physics.create_trigger(&engine.physics, position = position, collider = collider) or_return
  _attach_visual_mesh(engine, parent, collider, mesh, material, visual_scale, cast_shadow)
  ok = true
  return
}

// ---------- viewport / picking (window DPI + main camera) ----------

// Build a world-space ray from a logical cursor position (GLFW pixels).
// DPI is applied internally — callers pass raw `engine.input.mouse_pos`.
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

cursor_world_ray :: proc(engine: ^Engine) -> (origin: [3]f32, dir: [3]f32, ok: bool) {
  return viewport_to_world_ray(engine, f32(engine.input.mouse_pos.x), f32(engine.input.mouse_pos.y))
}

// ---------- navigation (config translation + nav.init) ----------

// One-shot navmesh setup: builds the mesh on `engine.nav` and initialises
// the query/filter so nav queries work immediately. Translates engine-level
// NavMeshConfig to recast.Config and chains nav.init after build.
build_navmesh :: proc(
  engine: ^Engine,
  geom: nav.NavigationGeometry,
  config: nav.NavMeshConfig = nav.DEFAULT_NAVMESH_CONFIG,
) -> bool {
  if !nav.build_navmesh(&engine.nav.nav_mesh, geom, nav.config_to_recast(config)) do return false
  return nav.init(&engine.nav)
}

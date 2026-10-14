package render

import geom "../geometry"
import cont "../containers"
import "core:log"
import "core:math"
import "core:math/linalg"

// The aspect ratio follows the camera's extent.
PerspectiveProjection :: struct {
  fov: f32,
}

// OrthographicProjection is a parallel projection of the given view size.
OrthographicProjection :: struct {
  width:  f32,
  height: f32,
}

// CameraProjection is the projection of a Camera.
CameraProjection :: union {
  PerspectiveProjection,
  OrthographicProjection,
}

// Camera c's frame f takes pyramid and draw-list slot camera_slot(c) + f; the shadow views
// take one draw-list slot per frame after every camera's. A camera keeps one list per
// material type, the shadow views share one.
@(private)
camera_slot :: #force_inline proc "contextless" (camera: u32) -> u32 {
  return camera * FRAMES_IN_FLIGHT
}
@(private)
SHADOW_DRAW_SLOT_BASE :: MAX_ACTIVE_CAMERAS * FRAMES_IN_FLIGHT
#assert(SHADOW_DRAW_SLOT_BASE + FRAMES_IN_FLIGHT <= MAX_DRAW_LIST_SLOTS)
@(private)
CAMERA_LIST_CAPACITY :: MAX_NODES_IN_SCENE
@(private)
SHADOW_LIST_CAPACITY :: 4096 * MAX_SHADOW_VIEWS

// Camera is a view into the scene: pose and projection, plus the images it renders into.
// Its depth pyramids live in Renderer.pyramids at its slot (camera_slot).
Camera :: struct {
  position:                     [3]f32,
  rotation:                     quaternion128,
  projection:                   CameraProjection,
  // clip planes, shared by both projections
  near, far:                    f32,
  extent:                       [2]u32, // width, height
  attachments:                  [AttachmentType][FRAMES_IN_FLIGHT]TextureHandle,
  // first serial whose compute work may read depth and pyramids; until then no occlusion, no lists
  ready_serial:                 u64,
}

@(private)
camera_view_matrix :: proc(camera: ^Camera) -> matrix[4, 4]f32 {
  // the camera looks along its -Z axis, up its Y axis
  return linalg.matrix4_look_at(
    camera.position,
    camera.position - geom.qz(camera.rotation),
    geom.qy(camera.rotation),
  )
}

@(private)
camera_projection_matrix :: proc(camera: ^Camera) -> matrix[4, 4]f32 {
  switch proj in camera.projection {
  case PerspectiveProjection:
    return geom.make_perspective_matrix(
      proj.fov,
      f32(camera.extent[0]) / f32(max(camera.extent[1], 1)),
      camera.near,
      camera.far,
    )
  case OrthographicProjection:
    hw := proj.width / 2
    hh := proj.height / 2
    return geom.make_ortho_matrix(-hw, hw, -hh, hh, camera.near, camera.far)
  }
  return linalg.MATRIX4F32_IDENTITY
}

// camera_look_at aims the camera at to from from. Zero up auto-picks a gimbal-safe
// up, which snaps near the poles; pass a smooth view-orthogonal up when known.
camera_look_at :: proc(self: ^Camera, from, to: [3]f32, up: [3]f32 = {0, 0, 0}) {
  self.position = from
  forward := linalg.normalize(to - from)
  safe_up := up
  if linalg.length2(safe_up) < 1e-6 {
    safe_up = linalg.VECTOR3F32_Y_AXIS
    if math.abs(linalg.dot(forward, safe_up)) > 0.999 {
      safe_up = linalg.VECTOR3F32_Z_AXIS
      if math.abs(linalg.dot(forward, safe_up)) > 0.999 {
        safe_up = linalg.VECTOR3F32_X_AXIS
      }
    }
  }
  right := linalg.normalize(linalg.cross(forward, safe_up))
  recalc_up := linalg.cross(right, forward)
  rotation_matrix := matrix[3, 3]f32{
    right.x, recalc_up.x, -forward.x,
    right.y, recalc_up.y, -forward.y,
    right.z, recalc_up.z, -forward.z,
  }
  self.rotation = linalg.to_quaternion(rotation_matrix)
}

// camera_orbit places the camera on a sphere around target, looking at it. yaw turns
// around the Y axis (0 = +X); pitch is elevation above the XZ plane.
camera_orbit :: proc(self: ^Camera, yaw, pitch, distance: f32, target: [3]f32 = {0, 0, 0}) {
  cp, sp := math.cos(pitch), math.sin(pitch)
  cy, sy := math.cos(yaw), math.sin(yaw)
  position := target + distance * [3]f32{cp * cy, sp, cp * sy}
  camera_look_at(self, position, target, {-sp * cy, cp, -sp * sy})
}

// camera_orbit_state is the inverse of camera_orbit for the current pose.
camera_orbit_state :: proc(self: ^Camera, target: [3]f32 = {0, 0, 0}) -> (yaw, pitch, distance: f32) {
  offset := self.position - target
  distance = max(linalg.length(offset), 0.001)
  yaw = math.atan2(offset.z, offset.x)
  pitch = math.asin(clamp(offset.y / distance, -1, 1))
  return
}

// camera_pose returns the camera's world position and rotation.
camera_pose :: proc(self: ^Camera) -> (position: [3]f32, rotation: quaternion128) {
  return self.position, self.rotation
}

// camera_forward returns the camera's world-space forward (-Z) axis.
camera_forward :: proc(self: ^Camera) -> [3]f32 {
  return linalg.quaternion_mul_vector3(self.rotation, [3]f32{0, 0, -1})
}

// camera_right returns the camera's world-space right (+X) axis.
camera_right :: proc(self: ^Camera) -> [3]f32 {
  return linalg.quaternion_mul_vector3(self.rotation, [3]f32{1, 0, 0})
}

// camera_up returns the camera's world-space up (+Y) axis.
camera_up :: proc(self: ^Camera) -> [3]f32 {
  return linalg.quaternion_mul_vector3(self.rotation, [3]f32{0, 1, 0})
}

// camera_lerp blends the camera toward a pose: position lerps, rotation slerps the short arc.
// t = 1 snaps; pass 1 - exp(-speed * dt) every tick for frame-rate independent smoothing.
camera_lerp :: proc(self: ^Camera, position: [3]f32, rotation: quaternion128, t: f32) {
  self.position = linalg.lerp(self.position, position, t)
  self.rotation = linalg.quaternion_slerp(self.rotation, rotation, t)
}

// camera_lerp_look_at is camera_lerp toward a camera at from looking at to.
camera_lerp_look_at :: proc(self: ^Camera, from, to: [3]f32, t: f32, up: [3]f32 = {0, 0, 0}) {
  goal := Camera{}
  camera_look_at(&goal, from, to, up)
  camera_lerp(self, goal.position, goal.rotation, t)
}

// camera_lerp_transform is camera_lerp toward a world matrix (see camera_set_transform).
camera_lerp_transform :: proc(self: ^Camera, world_matrix: matrix[4, 4]f32, t: f32) {
  camera_lerp(self, world_matrix[3].xyz, linalg.quaternion_from_matrix4_f32(world_matrix), t)
}

// camera_set_transform places the camera with a world matrix; it looks down the matrix's -Z.
camera_set_transform :: proc(self: ^Camera, world_matrix: matrix[4, 4]f32) {
  self.position = world_matrix[3].xyz
  self.rotation = linalg.quaternion_from_matrix4_f32(world_matrix)
}

// camera_set_perspective switches the camera to a perspective projection.
camera_set_perspective :: proc(
  self: ^Camera,
  fov: f32 = math.PI / 3,
  near: f32 = 0.1,
  far: f32 = 1000.0,
) {
  self.projection = PerspectiveProjection{fov = fov}
  self.near = near
  self.far = far
}

// camera_set_orthographic switches the camera to an orthographic projection.
camera_set_orthographic :: proc(
  self: ^Camera,
  width, height: f32,
  near: f32 = 0.1,
  far: f32 = 100.0,
) {
  self.projection = OrthographicProjection {
    width  = width,
    height = height,
  }
  self.near = near
  self.far = far
}

// cursor_ray returns the world-space ray from the main camera through cursor, given in
// window coordinates as input.State reports them (the DPI scale is applied here).
cursor_ray :: proc(self: ^Renderer, cursor: [2]f32) -> (origin, dir: [3]f32, ok: bool) {
  cam := main_camera(self) or_return
  p := cursor * self.ui.dpi_scale
  ndc := 2 * p / [2]f32{f32(cam.extent[0]), f32(cam.extent[1])} - 1
  ray_eye := linalg.matrix4_inverse(camera_projection_matrix(cam)) * [4]f32{ndc.x, ndc.y, -1, 1}
  ray_eye = {ray_eye.x, ray_eye.y, -1, 0}
  dir = linalg.normalize((linalg.matrix4_inverse(camera_view_matrix(cam)) * ray_eye).xyz)
  return cam.position, dir, true
}

// camera returns the camera of handle, or false if it is not live.
camera :: proc(self: ^Renderer, handle: CameraHandle) -> (^Camera, bool) #optional_ok {
  if !cont.slots_live(&self.camera_slots, u32(handle)) do return nil, false
  return &self.cameras[handle], true
}

// main_camera returns the camera presented to the swapchain.
main_camera :: proc(self: ^Renderer) -> (^Camera, bool) #optional_ok {
  return camera(self, self.main_camera)
}

// create_camera creates a perspective camera with its own render targets; it lives until
// destroy_camera or teardown.
// Every camera is drawn each frame; the main camera is presented to the swapchain.
create_camera :: proc(
  self: ^Renderer,
  width, height: u32,
  position: [3]f32 = {0, 0, 3},
  target: [3]f32 = {0, 0, 0},
  fov: f32 = math.PI * 0.5,
  near_plane: f32 = 0.1,
  far_plane: f32 = 100.0,
) -> (
  handle: CameraHandle,
  ok: bool,
) #optional_ok {
  handle = CameraHandle(cont.slots_alloc(&self.camera_slots) or_return)
  cam := &self.cameras[handle]
  cam^ = {
    extent = {width, height},
  }
  camera_set_perspective(cam, fov, near_plane, far_plane)
  camera_look_at(cam, position, target)
  // the lists' size does not depend on the camera's extent
  for frame in 0 ..< u32(FRAMES_IN_FLIGHT) {
    if !backend_draw_list_create(&self.gpu, camera_slot(u32(handle)) + frame, len(MaterialType), CAMERA_LIST_CAPACITY) {
      destroy_camera(self, handle)
      return 0, false
    }
  }
  if !create_targets(self, u32(handle)) {
    destroy_camera(self, handle)
    return 0, false
  }
  return handle, true
}

// destroy_camera frees the camera; its slot is reused once no frame in flight reads it.
destroy_camera :: proc(self: ^Renderer, handle: CameraHandle) {
  cam := camera(self, handle)
  if cam == nil do return
  destroy_targets(self, u32(handle))
  for frame in 0 ..< u32(FRAMES_IN_FLIGHT) do backend_draw_list_destroy(&self.gpu, camera_slot(u32(handle)) + frame)
  cont.slots_free(&self.camera_slots, u32(handle))
  if handle == self.main_camera do self.main_camera = 0
}

// camera_attachment returns a camera's attachment texture for frame_index (default: the frame recorded next).
camera_attachment :: proc(
  self: ^Renderer,
  handle: CameraHandle,
  attachment_type: AttachmentType,
  frame_index: Maybe(u32) = nil,
) -> (
  texture: TextureHandle,
  ok: bool,
) #optional_ok {
  cam := camera(self, handle) or_return
  return cam.attachments[attachment_type][frame_index.? or_else write_frame(self)], true
}

// resize_camera resizes a camera's render targets; a perspective projection follows the new aspect ratio.
resize_camera :: proc(
  self: ^Renderer,
  handle: CameraHandle,
  width, height: u32,
) -> bool {
  cam := camera(self, handle) or_return
  if cam.extent == {width, height} do return true
  cam.extent = {width, height}
  destroy_targets(self, u32(handle))
  create_targets(self, u32(handle)) or_return
  log.infof("Camera resized to %dx%d", width, height)
  return true
}

// A camera or a shadow map face, as the views table holds it. A drawn node goes to list
// type * list_stride of `draw_list`: cameras keep one list per material type (stride 1);
// shadow views share one list (stride 0) and tell draws apart by instance_tag.
@(private)
ViewGPU :: struct {
  view:                matrix[4, 4]f32,
  projection:          matrix[4, 4]f32,
  view_projection:     matrix[4, 4]f32,
  // rebuilds world positions from depth
  inv_view_projection: matrix[4, 4]f32,
  planes:              [6][4]f32, // normalized, pointing inward
  position:            [4]f32,
  extent:              [2]f32,
  near, far:           f32,
  attachments:         [AttachmentType]u32,
  // bindless depth pyramid
  pyramid:         u32,
  // bit t: material type t is tested against the pyramid
  occlusion_mask:  u32,
  list_stride:     u32,
  // bit t: material type t is drawn
  type_mask:       u32,
  require_flags:   NodeFlagSet,
  // OR-ed into each draw's first_instance above the node index
  instance_tag:    u32,
  // render target layer
  layer:           u32,
  // bindless draw lists slot the view appends to
  draw_list:       u32,
  // draws per list
  list_capacity:   u32,
  _:               u32,
}
#assert(size_of(ViewGPU) == 448)

// A camera's attachments, depth pyramids and draw lists, one set per frame in flight: frame
// N's culling writes the lists frame N+1 draws. A depth pyramid is a max-depth texture at
// half the camera's resolution.
@(private)
create_targets :: proc(self: ^Renderer, index: u32) -> bool {
  camera := &self.cameras[index]
  attachments := ATTACHMENTS
  for a in AttachmentType {
    desc := attachments[a]
    desc.extent = camera.extent
    for frame in 0 ..< FRAMES_IN_FLIGHT {
      camera.attachments[a][frame] = allocate_texture(self, desc, target = true) or_return
    }
  }
  half := [2]u32{max(1, camera.extent.x / 2), max(1, camera.extent.y / 2)}
  pyramid := TextureDesc {
    extent     = half,
    format     = .R32F,
    usage      = {.SAMPLED, .STORAGE},
    mip_levels = calculate_mip_levels(half.x, half.y),
    shared     = true,
  }
  for frame in 0 ..< u32(FRAMES_IN_FLIGHT) {
    slot := camera_slot(index) + frame
    self.pyramids[slot] = allocate_texture(self, pyramid, target = true) or_return
    backend_pyramid_create(&self.gpu, slot, self.pyramids[slot]) or_return
  }
  camera.ready_serial = backend_frame_serial(&self.gpu) + 1
  return true
}

@(private)
destroy_targets :: proc(self: ^Renderer, index: u32) {
  camera := &self.cameras[index]
  for frames in camera.attachments do for handle in frames do destroy_texture(self, handle)
  camera.attachments = {}
  for frame in 0 ..< u32(FRAMES_IN_FLIGHT) {
    slot := camera_slot(index) + frame
    backend_pyramid_destroy(&self.gpu, slot)
    destroy_texture(self, self.pyramids[slot])
    self.pyramids[slot] = 0
  }
}

// main_camera_orbit is camera_orbit on the main camera. The controller owns yaw, pitch and
// distance and sets them each tick; camera_orbit_state adopts an existing pose.
main_camera_orbit :: proc(self: ^Renderer, yaw, pitch, distance: f32, target: [3]f32 = {0, 0, 0}) {
  cam := main_camera(self)
  if cam == nil do return
  camera_orbit(cam, yaw, pitch, distance, target)
}

// main_camera_look_at aims the main camera at to from from.
main_camera_look_at :: proc(self: ^Renderer, from, to: [3]f32) {
  cam := main_camera(self)
  if cam == nil do return
  camera_look_at(cam, from, to)
}

package render

import "../geometry"
import "../containers"
import "core:log"
import "core:math"
import "core:math/linalg"

// PerspectiveProjection is a perspective projection of vertical field of view `fov` (radians);
// the aspect ratio follows the camera's size.
PerspectiveProjection :: struct {
  fov: f32,
}

// OrthographicProjection is a parallel projection `height` units tall; the width follows the
// camera's aspect ratio.
OrthographicProjection :: struct {
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

// Frame f's cull of camera c writes the lists frame f + 1 draws.
@(private)
camera_next_slot :: #force_inline proc "contextless" (camera, f: u32) -> u32 {
  return camera_slot(camera) + (f + 1) % FRAMES_IN_FLIGHT
}

// Camera c's draw lists and pyramid hold data: until then the camera draws nothing.
@(private)
camera_ready :: proc(self: ^Renderer, c: u32) -> bool {
  return dev.frame_serial(&self.gpu) >= self.camera_targets[c].ready_serial
}
@(private)
SHADOW_DRAW_SLOT_BASE :: MAX_ACTIVE_CAMERAS * FRAMES_IN_FLIGHT
#assert(SHADOW_DRAW_SLOT_BASE + FRAMES_IN_FLIGHT <= MAX_DRAW_LIST_SLOTS)
@(private)
CAMERA_LIST_CAPACITY :: MAX_SLOTS
@(private)
SHADOW_LIST_CAPACITY :: 4096 * MAX_SHADOW_VIEWS

// Camera is a view into the scene: pose and projection. Its images are camera_image's.
Camera :: struct {
  position:   [3]f32,
  rotation:   quaternion128,
  projection: CameraProjection,
  // clip planes, shared by both projections
  near, far:  f32,
}

// What render keeps per camera beside the Camera: the images it renders into, at extent.
@(private)
CameraTargets :: struct {
  extent:        [2]u32, // width, height
  images:        [CameraImage][FRAMES_IN_FLIGHT]TextureHandle,
  // the depth pyramid of each frame, and whether its storage views are in the bindless array
  pyramid:       [FRAMES_IN_FLIGHT]TextureHandle,
  pyramid_bound: [FRAMES_IN_FLIGHT]bool,
  // first serial whose compute work may read depth and pyramids; until then no occlusion, no lists
  ready_serial:  u64,
}

@(private)
camera_view_matrix :: proc(camera: ^Camera) -> matrix[4, 4]f32 {
  // the camera looks along its -Z axis, up its Y axis
  return linalg.matrix4_look_at(
    camera.position,
    camera.position - geometry.qz(camera.rotation),
    geometry.qy(camera.rotation),
  )
}

@(private)
camera_projection_matrix :: proc(camera: ^Camera, extent: [2]u32) -> matrix[4, 4]f32 {
  switch proj in camera.projection {
  case PerspectiveProjection:
    return geometry.make_perspective_matrix(
      proj.fov,
      f32(extent[0]) / f32(max(extent[1], 1)),
      camera.near,
      camera.far,
    )
  case OrthographicProjection:
    hh := proj.height / 2
    hw := hh * f32(extent[0]) / f32(max(extent[1], 1))
    return geometry.make_ortho_matrix(-hw, hw, -hh, hh, camera.near, camera.far)
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

// Orbit is a camera pose on a sphere around target: yaw turns around the Y axis (0 = +X),
// pitch is elevation above the XZ plane. camera_orbit applies it.
Orbit :: struct {
  yaw, pitch, distance: f32,
  target:               [3]f32,
}

// make_orbit returns the Orbit around target that puts the camera at eye.
make_orbit :: proc(eye, target: [3]f32) -> Orbit {
  offset := eye - target
  distance := max(linalg.length(offset), 0.001)
  return {
    yaw = math.atan2(offset.z, offset.x),
    pitch = math.asin(clamp(offset.y / distance, -1, 1)),
    distance = distance,
    target = target,
  }
}

// camera_orbit places the camera at orbit, looking at its target.
camera_orbit :: proc(self: ^Camera, orbit: Orbit) {
  cp, sp := math.cos(orbit.pitch), math.sin(orbit.pitch)
  cy, sy := math.cos(orbit.yaw), math.sin(orbit.yaw)
  position := orbit.target + orbit.distance * [3]f32{cp * cy, sp, cp * sy}
  camera_look_at(self, position, orbit.target, {-sp * cy, cp, -sp * sy})
}

// camera_forward returns the camera's world-space forward (-Z) axis.
camera_forward :: proc(self: ^Camera) -> [3]f32 {
  return linalg.quaternion_mul_vector3(self.rotation, [3]f32{0, 0, -1})
}

// camera_right returns the camera's world-space right (+X) axis.
camera_right :: proc(self: ^Camera) -> [3]f32 {
  return linalg.quaternion_mul_vector3(self.rotation, [3]f32{1, 0, 0})
}

// camera_lerp_look_at blends the camera toward one at from looking at to: position lerps,
// rotation slerps the short arc. t = 1 snaps; pass 1 - exp(-speed * dt) every tick for
// frame-rate independent smoothing.
camera_lerp_look_at :: proc(self: ^Camera, from, to: [3]f32, t: f32, up: [3]f32 = {0, 0, 0}) {
  goal := Camera{}
  camera_look_at(&goal, from, to, up)
  self.position = linalg.lerp(self.position, goal.position, t)
  self.rotation = linalg.quaternion_slerp(self.rotation, goal.rotation, t)
}

// cursor_ray returns the world-space ray from the main camera's near plane through cursor,
// given in window coordinates as input.State reports them (the DPI scale is applied here).
cursor_ray :: proc(self: ^Renderer, cursor: [2]f32) -> (ray: geometry.Ray, ok: bool) #optional_ok {
  cam := main_camera(self) or_return
  extent := self.camera_targets[self.main_camera].extent
  p := cursor * self.dpi_scale
  ndc := 2 * p / [2]f32{f32(extent[0]), f32(extent[1])} - 1
  inv := linalg.matrix4_inverse(camera_projection_matrix(cam, extent) * camera_view_matrix(cam))
  near := inv * [4]f32{ndc.x, ndc.y, 0, 1}
  far := inv * [4]f32{ndc.x, ndc.y, 1, 1}
  origin := near.xyz / near.w
  return {origin = origin, direction = linalg.normalize(far.xyz / far.w - origin)}, true
}

// world_to_screen returns where position appears on screen through the main camera, in window
// coordinates (those of cursor_ray and the overlay); false when it is behind the camera.
world_to_screen :: proc(self: ^Renderer, position: [3]f32) -> (point: [2]f32, ok: bool) #optional_ok {
  cam := main_camera(self) or_return
  extent := self.camera_targets[self.main_camera].extent
  clip := camera_projection_matrix(cam, extent) * camera_view_matrix(cam) * [4]f32{position.x, position.y, position.z, 1}
  if clip.w <= 0 do return {}, false
  ndc := clip.xy / clip.w
  return (ndc + 1) * 0.5 * [2]f32{f32(extent[0]), f32(extent[1])} / self.dpi_scale, true
}

// camera returns the camera of handle, to edit in place, or false if it is not live. The
// pointer is valid for this tick.
camera :: proc(self: ^Renderer, handle: CameraHandle) -> (^Camera, bool) #optional_ok {
  if !containers.slots_live(&self.slots[.CAMERAS], u32(handle)) do return nil, false
  return &self.cameras[handle], true
}

// main_camera returns the camera presented to the swapchain.
main_camera :: proc(self: ^Renderer) -> (^Camera, bool) #optional_ok {
  return camera(self, self.main_camera)
}

// make_camera returns a perspective Camera at `position` looking at `target`, for camera_create.
make_camera :: proc(
  position: [3]f32 = {0, 0, 3},
  target: [3]f32 = {0, 0, 0},
  fov: f32 = math.PI * 0.5,
  near: f32 = 0.1,
  far: f32 = 1000.0,
) -> (
  c: Camera,
) {
  c = {projection = PerspectiveProjection{fov}, near = near, far = far}
  camera_look_at(&c, position, target)
  return
}

// camera_create stores `c` (make_camera fills one) as a camera with its own render targets of
// `size` pixels; it lives until camera_destroy or teardown. Every camera is drawn each frame;
// the main camera is presented to the swapchain.
camera_create :: proc(self: ^Renderer, size: [2]u32, c: Camera) -> (handle: CameraHandle, ok: bool) #optional_ok {
  guard(self)
  handle = CameraHandle(containers.slots_alloc(&self.slots[.CAMERAS]) or_return)
  self.cameras[handle] = c
  self.camera_targets[handle] = {extent = size}
  // the lists' size does not depend on the camera's extent
  for frame in 0 ..< u32(FRAMES_IN_FLIGHT) {
    if !draw_list_create(self, camera_slot(u32(handle)) + frame, shadow = false) {
      free_camera(self, handle)
      return 0, false
    }
  }
  if !create_targets(self, u32(handle)) {
    free_camera(self, handle)
    return 0, false
  }
  return handle, true
}

// camera_destroy frees the camera; its handle is stale at once. false for the main camera,
// which lives as long as the renderer, or a stale handle.
camera_destroy :: proc(self: ^Renderer, handle: CameraHandle) -> bool {
  guard(self)
  if handle == self.main_camera do return false
  camera(self, handle) or_return
  free_camera(self, handle)
  return true
}

@(private)
free_camera :: proc(self: ^Renderer, handle: CameraHandle) {
  destroy_targets(self, u32(handle))
  for frame in 0 ..< u32(FRAMES_IN_FLIGHT) do draw_list_destroy(self, camera_slot(u32(handle)) + frame)
  containers.slots_free(&self.slots[.CAMERAS], u32(handle))
}

// camera_image returns one of a camera's images as the next frame renders it. The camera
// renders into a new copy each frame, so the handle changes: fetch it again every frame.
// previous_frame returns the picture the last frame finished instead, the one to sample
// (render-to-texture): it never depends on the order cameras draw in.
camera_image :: proc(
  self: ^Renderer,
  handle: CameraHandle,
  image: CameraImage,
  previous_frame := false,
) -> (
  texture: TextureHandle,
  ok: bool,
) #optional_ok {
  guard(self)
  camera(self, handle) or_return
  f := current_frame(self)
  if previous_frame do f = (f + FRAMES_IN_FLIGHT - 1) % FRAMES_IN_FLIGHT
  return self.camera_targets[handle].images[image][f], true
}

// Resizes a camera's render targets; a perspective projection follows the new aspect ratio.
@(private)
camera_resize :: proc(
  self: ^Renderer,
  handle: CameraHandle,
  width, height: u32,
) -> bool {
  camera(self, handle) or_return
  targets := &self.camera_targets[handle]
  if targets.extent == {width, height} do return true
  targets.extent = {width, height}
  destroy_targets(self, u32(handle))
  create_targets(self, u32(handle)) or_return
  log.infof("Camera resized to %dx%d", width, height)
  return true
}

// A camera or a shadow map face, as the views table holds it. A drawn node goes to list
// type * list_stride of `draw_list`: cameras keep one list per material type (stride 1);
// shadow views share one list (stride 0) and tell draws apart by instance_tag.
@(private)
View :: struct {
  view:                matrix[4, 4]f32,
  projection:          matrix[4, 4]f32,
  view_projection:     matrix[4, 4]f32,
  // rebuilds world positions from depth
  inv_view_projection: matrix[4, 4]f32,
  planes:              [6][4]f32, // normalized, pointing inward
  position:            [4]f32,
  extent:              [2]f32,
  near, far:           f32,
  images:              [CameraImage]u32,
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
  // render's clock in seconds (render.update)
  time:            f32,
  // Renderer.sun as seen by every view: color * intensity (0 when off), and the direction
  // towards it
  sun_radiance:    [4]f32,
  sun_direction:   [4]f32,
}
#assert(size_of(View) == 480)

// A camera's images and depth pyramids, one set per frame in flight (pyramid_shape).
@(private)
create_targets :: proc(self: ^Renderer, index: u32) -> bool {
  targets := &self.camera_targets[index]
  images := CAMERA_IMAGES
  for a in CameraImage {
    desc := images[a]
    desc.extent = targets.extent
    for frame in 0 ..< FRAMES_IN_FLIGHT {
      targets.images[a][frame] = allocate_texture(self, desc, target = true) or_return
    }
  }
  half, mips := pyramid_shape(targets.extent)
  pyramid := TextureDesc {
    extent     = half,
    format     = .R32F,
    usage      = {.SAMPLED, .STORAGE},
    mip_levels = mips,
    shared     = true,
  }
  // its storage views enter the bindless array at the slot's next frame (pyramids_bind)
  targets.pyramid_bound = {}
  for &p in targets.pyramid do p = allocate_texture(self, pyramid, target = true) or_return
  targets.ready_serial = dev.frame_serial(&self.gpu) + 1
  return true
}

@(private)
destroy_targets :: proc(self: ^Renderer, index: u32) {
  targets := &self.camera_targets[index]
  for frames in targets.images do for handle in frames do texture_destroy(self, handle)
  for handle in targets.pyramid do texture_destroy(self, handle)
  targets.images, targets.pyramid, targets.pyramid_bound = {}, {}, {}
  groups_clear(self)
}


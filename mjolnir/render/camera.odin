package render

import "../containers"
import "../geometry"
import "core:log"
import "core:math"
import "core:math/linalg"
import "base:intrinsics"
import "core:reflect"
import "core:slice"

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

// Camera c's draw lists are slot c; the shadow views' are the slot after every camera's.
@(private)
SHADOW_DRAW_SLOT :: MAX_ACTIVE_CAMERAS

// Camera c's pyramid holds a depth: until then it tests nothing for occlusion.
@(private)
camera_ready :: proc(self: ^Renderer, c: u32) -> bool {
  return dev.frame_serial(&self.gpu) >= self.camera_targets[c].ready_serial
}

// Camera is a view into the scene: its pose and projection, which you edit freely. What it
// draws is its CameraFilter, fixed at camera_create; its techniques (ambient occlusion, effects)
// are camera_effect's. Its images are camera_image's.
Camera :: struct {
  position:      [3]f32,
  rotation:      quaternion128,
  projection:    CameraProjection,
  // clip planes, shared by both projections
  near, far:     f32,
  // the layers (MeshAttachment.layer) whose meshes it does not draw
  hidden_layers: Layers,
}

// MAX_EFFECTS is how many post shaders of yours a camera runs (camera_post_shaders).
MAX_EFFECTS :: 16

// Layers is a set of mesh layers, each below MAX_LAYERS.
Layers :: bit_set[0 ..< MAX_LAYERS; u32]

MAX_LAYERS :: 32

// AmbientOcclusion darkens the image-based light where nearby surfaces hide the sky: creases,
// contacts, corners. Estimated per pixel from the camera's depth and normals (screen space),
// so what is off screen occludes nothing. Direct lights are not affected. Needs the G-buffer.
AmbientOcclusion :: struct {
  // world units around a point searched for occluders
  radius:    f32,
  // exponent on the visibility: above 1 darkens, 0 turns it off
  intensity: f32,
}

// DEFAULT_AMBIENT_OCCLUSION is what a camera drawing a deferred type starts with.
DEFAULT_AMBIENT_OCCLUSION :: AmbientOcclusion {
  radius    = 0.5,
  intensity = 1.0,
}

// CameraEffect is one of a camera's techniques with its settings (camera_effect). The effects
// run over the camera's image in this order, after the lighting: outline, fog, depth of field,
// bloom, FXAA, blur, cross-hatch, grayscale, tone map, then your post shaders. Without a tone map
// the image stays HDR.
CameraEffect :: union {
  AmbientOcclusion,
  OutlineEffect,
  FogEffect,
  DoFEffect,
  BloomEffect,
  FXAAEffect,
  BlurEffect,
  CrossHatchEffect,
  GrayscaleEffect,
  ToneMapEffect,
}

@(private)
CAMERA_EFFECTS :: intrinsics.type_union_variant_count(CameraEffect)

// Whether a technique needs the G-buffer, which only a camera drawing a deferred type has; the
// rest need the camera's image and depth, which every camera has.
@(private)
effect_needs_gbuffer :: proc(effect: CameraEffect) -> bool {
  #partial switch _ in effect {
  case AmbientOcclusion, OutlineEffect:
    return true
  }
  return false
}

// camera_effect turns one of a camera's techniques on with `effect`'s settings, or changes them;
// `enabled` false turns that technique off. False, logging why and changing nothing, for a stale
// handle or when the camera lacks what the technique needs (effect_needs_gbuffer): its
// CameraFilter is fixed, so to give a view the G-buffer destroy the camera and create one that
// draws a deferred type.
camera_effect :: proc(self: ^Renderer, handle: CameraHandle, effect: CameraEffect, enabled := true) -> bool {
  lock(self)
  camera(self, handle) or_return
  if effect == nil do return false
  targets := &self.camera_targets[handle]
  if enabled && effect_needs_gbuffer(effect) && !filter_deferred(targets.filter) {
    log.errorf("Camera %d draws no deferred type, so it has no G-buffer for %v", handle, reflect.union_variant_typeid(effect))
    return false
  }
  targets.effects[reflect.get_union_variant_raw_tag(effect) - 1] = effect if enabled else nil
  return true
}

// camera_effect_get returns the camera's settings of technique T; false when it is off or the
// handle stale.
camera_effect_get :: proc(self: ^Renderer, handle: CameraHandle, $T: typeid) -> (effect: T, ok: bool) where intrinsics.type_is_variant_of(CameraEffect, T) {
  lock(self)
  camera(self, handle) or_return
  return camera_has(self, u32(handle), T)
}

// camera_post_shaders sets your post shaders the camera runs after its effects, in order
// (make_effect), replacing the previous ones. False, changing nothing, for a stale handle, more
// than MAX_EFFECTS, a shader that is not a post shader, or one made with normals on a camera
// without the G-buffer.
camera_post_shaders :: proc(self: ^Renderer, handle: CameraHandle, effects: ..Effect) -> bool {
  lock(self)
  camera(self, handle) or_return
  targets := &self.camera_targets[handle]
  if len(effects) > MAX_EFFECTS {
    log.errorf("A camera runs at most %d post shaders, not %d", MAX_EFFECTS, len(effects))
    return false
  }
  for e in effects {
    s, ok := shader_of(self, e.shader, .POST)
    if !ok {
      log.errorf("Shader %d is not a post shader", e.shader)
      return false
    }
    if s.normals && !filter_deferred(targets.filter) {
      log.errorf("Camera %d draws no deferred type, so it has no normals for post shader %d", handle, e.shader)
      return false
    }
  }
  targets.shaders = {}
  copy(targets.shaders[:], effects)
  return true
}

// Camera c's settings of technique T; false when it is off.
@(private)
camera_has :: proc(self: ^Renderer, c: u32, $T: typeid) -> (T, bool) {
  return self.camera_targets[c].effects[intrinsics.type_variant_index_of(CameraEffect, T)].(T)
}

// CameraFilter is what a camera draws, fixed when it is created (camera_create): what it has
// follows, so a camera that draws little costs little. Every camera has its image and depth.
//   types: the material types it draws (MaterialType, and the types of your material shaders).
//     With a deferred one (PBR) it has the G-buffer, lighting, ambient occlusion, a depth
//     pyramid and occlusion culling; without, it clears to `clear` and draws the forward types
//     over it (a 2D view of sprites, say). A camera's draw lists are one per type it draws.
// To change it, destroy the camera and create another.
CameraFilter :: struct {
  types: bit_set[0 ..< DRAW_LISTS;u32],
  // the color it starts from when it has no lighting pass
  clear: [4]f32,
}

// FILTER_ALL is what camera_create takes by default: every type.
#assert(DRAW_LISTS == 8)
FILTER_ALL :: CameraFilter {
  types = {0, 1, 2, 3, 4, 5, 6, 7},
  clear = {0, 0, 0, 1},
}

// Whether the camera has the deferred passes: the G-buffer, ambient occlusion and lighting.
@(private)
filter_deferred :: #force_inline proc "contextless" (filter: CameraFilter) -> bool {
  return transmute(u32)(filter.types) & GBUFFER_TYPES != 0
}

// Whether the camera draws forward types over its lit image.
@(private)
filter_forward :: #force_inline proc "contextless" (filter: CameraFilter) -> bool {
  return transmute(u32)(filter.types) &~ GBUFFER_TYPES != 0
}

// What render keeps per camera beside the Camera. Only what outlives a frame: its image of this
// frame and the one before (render-to-texture samples that one), depth (the next frame's
// pyramid reads it), the pyramid. Everything else a frame renders is the frame graph's.
@(private)
CameraTargets :: struct {
  extent:       [2]u32, // width, height
  filter:       CameraFilter,
  // final[history(self)] is this frame's image, the other the last frame's
  final:        [2]TextureHandle,
  depth:        TextureHandle,
  // the max-depth pyramid occlusion culling tests against (deferred cameras)
  pyramid:      TextureHandle,
  // first serial whose pyramid holds a depth: until then no occlusion
  ready_serial: u64,
  // camera_effect's, by CameraEffect variant, nil where off; camera_post_shaders'
  effects:      [CAMERA_EFFECTS]CameraEffect,
  shaders:      [MAX_EFFECTS]Effect,
}

// Which of a camera's two images this frame renders: they swap every frame.
@(private)
history :: proc(self: ^Renderer) -> u32 {
  return u32(dev.frame_serial(&self.gpu) & 1)
}

@(private)
camera_view_matrix :: proc(camera: ^Camera) -> matrix[4, 4]f32 {
  // the camera looks along its -Z axis, up its Y axis
  return linalg.matrix4_look_at(
    camera.position,
    camera.position - linalg.mul(camera.rotation, linalg.VECTOR3F32_Z_AXIS),
    linalg.mul(camera.rotation, linalg.VECTOR3F32_Y_AXIS),
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

// camera_lerp_look_at blends the camera toward one at from looking at to: position lerps,
// rotation slerps the short arc. t = 1 snaps; pass geometry.exp_smooth(speed, dt) every tick
// for frame-rate independent smoothing.
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
  extent := self.camera_targets[MAIN_CAMERA].extent
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
  extent := self.camera_targets[MAIN_CAMERA].extent
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

// MAIN_CAMERA is the camera presented to the swapchain: init makes it, and it lives as long as the
// renderer.
MAIN_CAMERA :: CameraHandle(1)

// main_camera returns the camera presented to the swapchain.
main_camera :: proc(self: ^Renderer) -> (^Camera, bool) #optional_ok {
  return camera(self, MAIN_CAMERA)
}

// Where init places the main camera, looking at the origin.
@(private)
MAIN_CAMERA_POSITION :: [3]f32{3, 4, 3}

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

// camera_create stores `c` (make_camera fills one) as a camera with its own images of `size`
// pixels; it lives until camera_destroy or teardown. Every camera is drawn each frame; the main
// camera is presented to the swapchain. `filter` says what it draws, and so what it has, for
// good (CameraFilter). One drawing a deferred type starts with DEFAULT_AMBIENT_OCCLUSION.
camera_create :: proc(self: ^Renderer, size: [2]u32, c: Camera, filter := FILTER_ALL) -> (handle: CameraHandle, ok: bool) #optional_ok {
  lock(self)
  if transmute(u32)(filter.types) == 0 {
    log.errorf("A camera must see at least one material type")
    return 0, false
  }
  handle = CameraHandle(pool_alloc(self, .CAMERAS) or_return)
  self.cameras[handle] = c
  self.camera_targets[handle] = {extent = size, filter = filter}
  camera_effects_default(self, u32(handle))
  // the lists' size does not depend on the camera's extent
  if !draw_list_reserve(self, u32(handle), shadow = false) {
    free_camera(self, handle)
    return 0, false
  }
  if !create_targets(self, u32(handle)) {
    free_camera(self, handle)
    return 0, false
  }
  return handle, true
}

// camera_destroy frees the camera; destroy each handle once. The main camera, which lives as
// long as the renderer, is ignored.
camera_destroy :: proc(self: ^Renderer, handle: CameraHandle) {
  lock(self)
  if handle == MAIN_CAMERA do return
  if _, live := camera(self, handle); live do free_camera(self, handle)
}

@(private)
free_camera :: proc(self: ^Renderer, handle: CameraHandle) {
  destroy_targets(self, u32(handle))
  draw_list_destroy(self, u32(handle))
  containers.slots_free(&self.slots[.CAMERAS], u32(handle))
}

// A camera's techniques as camera_create starts it: ambient occlusion where it has the G-buffer.
@(private)
camera_effects_default :: proc(self: ^Renderer, c: u32) {
  targets := &self.camera_targets[c]
  targets.effects, targets.shaders = {}, {}
  if filter_deferred(targets.filter) do targets.effects[intrinsics.type_variant_index_of(CameraEffect, AmbientOcclusion)] = DEFAULT_AMBIENT_OCCLUSION
}

// camera_image returns a camera's FINAL_IMAGE or DEPTH as the next frame renders it; false for
// the G-buffer images, which live only within a frame. FINAL_IMAGE alternates between two
// textures, so fetch it again every frame. previous_frame returns the picture the last frame
// finished instead, the one to sample (render-to-texture): it never depends on the order cameras
// draw in. DEPTH has one copy: previous_frame gives the same one.
camera_image :: proc(
  self: ^Renderer,
  handle: CameraHandle,
  image: CameraImage,
  previous_frame := false,
) -> (
  texture: TextureHandle,
  ok: bool,
) #optional_ok {
  lock(self)
  camera(self, handle) or_return
  targets := &self.camera_targets[handle]
  #partial switch image {
  case .FINAL_IMAGE:
    texture = targets.final[history(self) ~ u32(previous_frame)]
  case .DEPTH:
    texture = targets.depth
  }
  return texture, texture != 0
}

// camera_resize gives a camera render targets of `size` pixels; a perspective projection
// follows the new aspect ratio. Nothing happens when the size is unchanged, so a camera sized
// from the window can be resized every tick. Cameras the window's size are resized with it.
// false for a stale handle or when the targets could not be made.
camera_resize :: proc(self: ^Renderer, handle: CameraHandle, size: [2]u32) -> bool {
  lock(self)
  camera(self, handle) or_return
  targets := &self.camera_targets[handle]
  if targets.extent == size do return true
  targets.extent = size
  destroy_targets(self, u32(handle))
  create_targets(self, u32(handle)) or_return
  log.infof("Camera resized to %dx%d", size.x, size.y)
  return true
}

// A camera or a shadow map face, as the views table holds it. A drawn node goes to list
// rank(type) * list_stride of `draw_list`, rank the type's place among the types the view draws
// (type_mask): cameras keep one list per type they see (stride 1);
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
  // a node in one of these is not drawn (Camera.hidden_layers)
  hidden_layers:   Layers,
  _:               [5]u32,
}
#assert(size_of(View) == 448)

// The texture of a camera's image `a` at `extent`.
@(private)
camera_image_desc :: proc(a: CameraImage, extent: [2]u32) -> TextureDesc {
  descs := CAMERA_IMAGES
  desc := descs[a]
  desc.extent = extent
  return desc
}

// A camera's image pair, depth and (drawing a deferred type) depth pyramid.
@(private)
create_targets :: proc(self: ^Renderer, index: u32) -> bool {
  targets := &self.camera_targets[index]
  for &t in targets.final do t = allocate_texture(self, camera_image_desc(.FINAL_IMAGE, targets.extent), target = true) or_return
  targets.depth = allocate_texture(self, camera_image_desc(.DEPTH, targets.extent), target = true) or_return
  targets.ready_serial = dev.frame_serial(&self.gpu) + 1
  if !filter_deferred(targets.filter) do return true
  half, mips := pyramid_shape(targets.extent)
  pyramid := TextureDesc {
    extent     = half,
    format     = .R32F,
    usage      = {.SAMPLED, .STORAGE},
    mip_levels = mips,
  }
  targets.pyramid = allocate_texture(self, pyramid, target = true) or_return
  return true
}

@(private)
destroy_targets :: proc(self: ^Renderer, index: u32) {
  targets := &self.camera_targets[index]
  for t in ([3]TextureHandle{targets.final[0], targets.final[1], targets.depth}) do if t != 0 do texture_destroy(self, t)
  if targets.pyramid != 0 do texture_destroy(self, targets.pyramid)
  targets.final, targets.depth, targets.pyramid = {}, 0, 0
  groups_clear(self)
}

// Writes the camera views, in slot order, marking only the ones that changed. Each camera's
// draw lists first grow to hold every node.
@(private)
flush_cameras :: proc(self: ^Renderer) {
  for i in 0 ..< self.slots[.CAMERAS].high_water {
    // a slot without a camera keeps an empty view that draws no type
    if !containers.slots_live(&self.slots[.CAMERAS], i) {
      write_entry(self, .VIEWS, int(CAMERA_VIEW_BASE + i), View{})
      continue
    }
    // the cull fills its lists, from the pyramid of the last frame's depth
    if !draw_list_reserve(self, i, shadow = false) do log.errorf("Camera %d: cannot grow its draw lists", i)
    cam, targets := &self.cameras[i], &self.camera_targets[i]
    view := camera_view_matrix(cam)
    projection := camera_projection_matrix(cam, targets.extent)
    view_projection := projection * view
    v := View {
      view                = view,
      projection          = projection,
      view_projection     = view_projection,
      inv_view_projection = linalg.inverse(view_projection),
      planes              = geometry.make_frustum(view_projection).planes,
      position            = {cam.position.x, cam.position.y, cam.position.z, 1},
      extent              = {f32(targets.extent[0]), f32(targets.extent[1])},
      near                = cam.near,
      far                 = cam.far,
      pyramid             = u32(targets.pyramid),
      occlusion_mask      = GBUFFER_TYPES & transmute(u32)(targets.filter.types) if camera_ready(self, i) && filter_deferred(targets.filter) else 0,
      list_stride         = 1,
      type_mask           = transmute(u32)(targets.filter.types),
      require_flags       = {.VISIBLE},
      draw_list           = self.draw_lists[i].binding,
      list_capacity       = self.draw_lists[i].capacity,
      time                = f32(self.time),
      hidden_layers       = cam.hidden_layers,
    }
    write_entry(self, .VIEWS, int(CAMERA_VIEW_BASE + i), v)
  }
}

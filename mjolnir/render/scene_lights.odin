package render

import cont "../containers"
import geom "../geometry"
import "gpu"
import "core:log"
import "core:math/linalg"
import ba "core:container/bit_array"
import "core:slice"
import vk "vendor:vulkan"

// Shadow textures of one shadow map. Every frame the shadow casters seen by
// some camera are ranked by shadow_score; the top SHADOW_RANKED_CASTERS get a
// map, and the remaining maps stay with casters that ranked within the last
// SHADOW_GRACE_FRAMES frames. Any other caster has no map and lights
// unshadowed. A selected caster keeps the map it had; the others take a free
// map of their kind first, so maps rarely change kind. Textures are
// level-lifetime: a cube map for a point light, a 2D map otherwise,
// reallocated when the map goes to a light of the other kind.
@(private)
ShadowMap :: struct {
  // light slot + 1 of the light using this map; 0 when free
  owner:       u32,
  cube:        bool,
  textures:    [gpu.FRAMES_IN_FLIGHT]Handle,
  // frame serial when the owner last ranked in the top SHADOW_RANKED_CASTERS
  last_ranked: u64,
}

// Bounding radius of a light that reaches everywhere (directional).
@(private)
UNBOUNDED_LIGHT_RADIUS :: 1e18

// One light as the shadow depth and lighting passes consume it this frame.
@(private)
FrameLight :: struct {
  type:       LightType,
  params:     DirectLight,
  shadow_map: ^ShadowMap, // nil when the light casts no shadow
  info:       ShadowFrameInfo,
  bounds:     [4]f32, // bounding sphere: center xyz, radius w
}

@(private)
destroy_light_state :: proc(self: ^Manager, gctx: ^gpu.GPUContext) {
  delete(self.internal.frame_lights)
}

// A shadow-casting light this frame.
@(private)
Caster :: struct {
  light:       int, // index into frame_lights
  owner:       u32, // light slot + 1, as in ShadowMap.owner
  score:       f32,
  shadow_map:  int, // index of the map it holds, -1 for none
  last_ranked: u64, // ShadowMap.last_ranked once it holds a map
}

// How much of a camera's view a light's bounding sphere covers, weighted by
// intensity: r²/(d²−r²) grows like the sphere's projected area, and a camera
// inside the sphere (any unbounded light) scores highest.
@(private)
shadow_score :: proc(bounds: [4]f32, intensity: f32, camera_position: [3]f32) -> f32 {
  offset := bounds.xyz - camera_position
  r2 := bounds.w * bounds.w
  return intensity * r2 / max(linalg.dot(offset, offset) - r2, 1e-6)
}

// Pick the casters that get a shadow map: `casters` sorted by descending
// score, `maps` as left by the previous frame, `serial` this frame.
@(private)
select_shadow_casters :: proc(
  casters: []Caster,
  maps: ^[MAX_SHADOW_MAPS]ShadowMap,
  serial: u64,
) -> (
  selected: [MAX_SHADOW_MAPS]Caster,
  count: int,
) {
  for c, rank in casters {
    if count == MAX_SHADOW_MAPS do break
    c := c
    c.shadow_map = -1
    for sm, m in maps do if sm.owner == c.owner do c.shadow_map = m
    if rank < SHADOW_RANKED_CASTERS {
      c.last_ranked = serial
    } else if c.shadow_map >= 0 && serial - maps[c.shadow_map].last_ranked <= SHADOW_GRACE_FRAMES {
      c.last_ranked = maps[c.shadow_map].last_ranked
    } else {
      continue
    }
    selected[count] = c
    count += 1
  }
  return
}

// Rebuild frame_lights from the light slots: lights in slot order, truncated
// to MAX_LIGHTS, with shadow matrices derived once so both passes see the same
// lights in the same order, then hand the shadow maps out
// (select_shadow_casters). Caller holds the staging mutex.
@(private)
collect_lights :: proc(self: ^Manager, gctx: ^gpu.GPUContext) {
  clear(&self.internal.frame_lights)
  View :: struct {
    frustum:  geom.Frustum,
    position: [3]f32,
  }
  views: [MAX_ACTIVE_CAMERAS]View
  view_count := 0
  cam_it := cont.iterator(&self.cameras)
  for cam in cont.next(&cam_it, CameraHandle) {
    views[view_count] = {
      geom.make_frustum(camera_projection_matrix(cam) * camera_view_matrix(cam)),
      cam.position,
    }
    view_count += 1
  }
  casters: [MAX_LIGHTS]Caster
  caster_count := 0
  it := ba.make_iterator(&self.internal.staging.lights)
  for slot in ba.iterate_by_set(&it) {
    if len(self.internal.frame_lights) == MAX_LIGHTS do break
    inst := &self.instances[slot]
    fl, cast_shadow := frame_light(inst.attachment, inst.world_matrix) or_continue
    append(&self.internal.frame_lights, fl)
    if !cast_shadow do continue
    // -1: no camera sees the light
    score: f32 = -1
    for v in views[:view_count] {
      if !geom.frustum_test_sphere(v.frustum, fl.bounds.xyz, fl.bounds.w) do continue
      score = max(score, shadow_score(fl.bounds, fl.params.color.a, v.position))
    }
    if score < 0 do continue
    casters[caster_count] = {light = len(self.internal.frame_lights) - 1, owner = u32(slot) + 1, score = score}
    caster_count += 1
  }
  slice.sort_by(casters[:caster_count], proc(a, b: Caster) -> bool {return a.score > b.score})
  maps := &self.internal.shadow_maps
  selected, selected_count := select_shadow_casters(casters[:caster_count], maps, gctx.frame_serial)
  claimed: [MAX_SHADOW_MAPS]bool
  // Casters keep the map they had; the rest wait for a free one.
  waiting: [MAX_SHADOW_MAPS]Caster
  waiting_count := 0
  for c in selected[:selected_count] {
    if c.shadow_map >= 0 {
      claimed[c.shadow_map] = true
      give_shadow_map(self, gctx, c.shadow_map, c)
    } else {
      waiting[waiting_count] = c
      waiting_count += 1
    }
  }
  for &sm, m in maps do if !claimed[m] do sm.owner = 0
  // A free map of the caster's kind avoids reallocating its textures.
  for c in waiting[:waiting_count] {
    cube := self.internal.frame_lights[c.light].type == .POINT
    best := -1
    for sm, m in maps {
      if claimed[m] do continue
      if best < 0 || (sm.cube == cube && maps[best].cube != cube) do best = m
    }
    claimed[best] = true
    maps[best].owner = c.owner
    give_shadow_map(self, gctx, best, c)
  }
}

// Point a caster's frame light at shadow map `m`, giving the map the
// caster's kind.
@(private = "file")
give_shadow_map :: proc(self: ^Manager, gctx: ^gpu.GPUContext, m: int, c: Caster) {
  fl := &self.internal.frame_lights[c.light]
  sm := &self.internal.shadow_maps[m]
  if res := ensure_shadow_map(self, gctx, sm, fl.type == .POINT); res != .SUCCESS {
    log.warnf("Failed to allocate a shadow map for light %d: %v", c.owner - 1, res)
    return
  }
  sm.last_ranked = c.last_ranked
  fl.shadow_map = sm
}

// The light at a slot placed at `world_matrix`. ok=false when the attachment
// is not a light or the light is disabled.
@(private = "file")
frame_light :: proc(
  a: Attachment,
  world_matrix: matrix[4, 4]f32,
) -> (
  fl: FrameLight,
  cast_shadow: bool,
  ok: bool,
) {
  position := world_matrix[3].xyz
  direction := shadow_safe_normalize(world_matrix[2].xyz, {0, -1, 0})
  #partial switch att in a {
  case PointLightAttachment:
    if att.disabled do return
    fl.type = .POINT
    fl.params = {color = att.color, position = position, radius = att.radius}
    projection, near, far := shadow_projection_point(att.radius)
    fl.info = {{}, projection, near, far}
    fl.bounds = {position.x, position.y, position.z, att.radius}
    cast_shadow = att.cast_shadow
  case SpotLightAttachment:
    if att.disabled do return
    fl.type = .SPOT
    fl.params = {
      color       = att.color,
      position    = position,
      direction   = direction,
      radius      = att.radius,
      angle_inner = att.angle_inner,
      angle_outer = att.angle_outer,
    }
    view, projection, near, far := shadow_matrices_spot(
      position,
      direction,
      att.radius,
      att.angle_outer,
    )
    fl.info = {projection * view, projection, near, far}
    // the point-light sphere around the cone: loose, but shared
    fl.bounds = {position.x, position.y, position.z, att.radius}
    cast_shadow = att.cast_shadow
  case DirectionalLightAttachment:
    if att.disabled do return
    fl.type = .DIRECTIONAL
    fl.params = {color = att.color, direction = direction}
    view, projection, near, far := shadow_matrices_directional(
      position,
      direction,
      att.radius,
    )
    fl.info = {projection * view, projection, near, far}
    fl.bounds = {position.x, position.y, position.z, UNBOUNDED_LIGHT_RADIUS}
    cast_shadow = att.cast_shadow
  case:
    return
  }
  ok = true
  return
}

// Give the map textures of the requested kind.
@(private = "file")
ensure_shadow_map :: proc(
  self: ^Manager,
  gctx: ^gpu.GPUContext,
  sm: ^ShadowMap,
  cube: bool,
) -> (
  ret: vk.Result,
) {
  if sm.cube == cube && !slice.contains(sm.textures[:], Handle{}) do return .SUCCESS
  for &texture in sm.textures {
    if texture == {} do continue
    if sm.cube {
      free_texture_cube(&self.texture_manager, gctx, texture)
    } else {
      free_texture_2d(&self.texture_manager, gctx, texture)
    }
    texture = {}
  }
  sm.cube = cube
  for &texture in sm.textures {
    if cube {
      texture = Handle(
        allocate_texture_cube(
          &self.texture_manager,
          gctx,
          SHADOW_MAP_SIZE,
          .D32_SFLOAT,
          {.DEPTH_STENCIL_ATTACHMENT, .SAMPLED},
        ) or_return,
      )
    } else {
      texture = Handle(
        allocate_texture_2d(
          &self.texture_manager,
          gctx,
          vk.Extent2D{SHADOW_MAP_SIZE, SHADOW_MAP_SIZE},
          .D32_SFLOAT,
          {.DEPTH_STENCIL_ATTACHMENT, .SAMPLED},
        ) or_return,
      )
    }
  }
  return .SUCCESS
}

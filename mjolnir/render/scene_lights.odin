package render

import cont "../containers"
import geom "../geometry"
import "gpu"
import "core:math"
import "core:math/linalg"
import ba "core:container/bit_array"
import "core:slice"

// A caster holding a shadow map. Every frame the shadow casters seen by some
// camera are ranked by shadow_score; the top SHADOW_RANKED_CASTERS get a map,
// and the remaining maps go to casters that ranked within the last
// SHADOW_GRACE_FRAMES frames. Any other caster has no map and lights
// unshadowed. Maps own no textures: each frame packs the selected maps into
// the frame's shadow atlas (assign_shadow_layers).
@(private)
ShadowMap :: struct {
  // light slot + 1 of the light using this map; 0 when free
  owner:       u32,
  // frame serial when the owner last ranked in the top SHADOW_RANKED_CASTERS
  last_ranked: u64,
}

// The faces of a light type's shadow map, one shadow view and atlas layer
// each: the six cube faces around a point light, one face otherwise. A face
// is the (forward, up) of a rotation applied after the light's shadow view;
// forward -Z with up +Y is the identity.
@(private)
SHADOW_LAYERS := [LightType]u32 {
  .POINT       = 6,
  .SPOT        = 1,
  .DIRECTIONAL = 1,
  .AMBIENT     = 0,
}
@(private)
SHADOW_FACES := [LightType][6][2][3]f32 {
  .POINT       = {
    {{1, 0, 0}, {0, -1, 0}},
    {{-1, 0, 0}, {0, -1, 0}},
    {{0, 1, 0}, {0, 0, 1}},
    {{0, -1, 0}, {0, 0, -1}},
    {{0, 0, 1}, {0, -1, 0}},
    {{0, 0, -1}, {0, -1, 0}},
  },
  .SPOT        = {0 = {{0, 0, -1}, {0, 1, 0}}},
  .DIRECTIONAL = {0 = {{0, 0, -1}, {0, 1, 0}}},
  .AMBIENT     = {},
}

// One light as the shadow depth and lighting passes consume it this frame.
@(private)
FrameLight :: struct {
  type:              LightType,
  // light.shadow_map: first shadow view of its map, NO_SHADOW without one
  light:             LightGPU,
  // sphere the shadow map covers: center xyz, radius w
  shadow_bounds:     [4]f32,
  // face f's view-projection: projection * SHADOW_FACES[type][f] * view
  shadow_view:       matrix[4, 4]f32,
  shadow_projection: matrix[4, 4]f32,
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
  last_ranked: u64, // ShadowMap.last_ranked once it holds a map
}

// How much of a camera's view a light's shadow bounds cover, weighted by
// intensity: r²/(d²−r²) grows like the sphere's projected area, and a camera
// inside the sphere scores highest.
@(private)
shadow_score :: proc(bounds: [4]f32, intensity: f32, camera_position: [3]f32) -> f32 {
  offset := bounds.xyz - camera_position
  r2 := bounds.w * bounds.w
  return intensity * r2 / max(linalg.dot(offset, offset) - r2, 1e-6)
}

// Pick the casters that get a shadow map and record them in `maps`: `casters`
// sorted by descending score, `maps` as left by the previous frame, `serial`
// this frame.
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
    c.last_ranked = serial
    if rank >= SHADOW_RANKED_CASTERS {
      held := false
      for sm in maps do if sm.owner == c.owner {c.last_ranked = sm.last_ranked; held = true}
      if !held || serial - c.last_ranked > SHADOW_GRACE_FRAMES do continue
    }
    selected[count] = c
    count += 1
  }
  maps^ = {}
  for c, m in selected[:count] do maps[m] = {c.owner, c.last_ranked}
  return
}

// Rebuild frame_lights: the ambient light, then the light slots in slot
// order, truncated to MAX_LIGHTS, with shadow matrices derived once so both passes see the same
// lights, then hand the shadow maps out (select_shadow_casters) and group the
// lights by type (light_first, light_count). Caller holds the staging mutex.
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
  append(
    &self.internal.frame_lights,
    FrameLight {
      type = .AMBIENT,
      light = {color = {1, 1, 1, self.ambient.ibl_intensity}, shadow_map = NO_SHADOW},
    },
  )
  casters: [MAX_LIGHTS]Caster
  caster_count := 0
  it := ba.make_iterator(&self.internal.staging.lights)
  for slot in ba.iterate_by_set(&it) {
    if len(self.internal.frame_lights) == MAX_LIGHTS do break
    inst := &self.instances[slot]
    if !inst.visible do continue
    fl, cast_shadow := frame_light(inst.attachment, inst.world_matrix) or_continue
    fl.light.shadow_map = NO_SHADOW
    append(&self.internal.frame_lights, fl)
    if !cast_shadow do continue
    // -1: no camera sees the light
    score: f32 = -1
    for v in views[:view_count] {
      if !geom.frustum_test_sphere(v.frustum, fl.shadow_bounds.xyz, fl.shadow_bounds.w) do continue
      score = max(score, shadow_score(fl.shadow_bounds, fl.light.color.a, v.position))
    }
    if score < 0 do continue
    casters[caster_count] = {light = len(self.internal.frame_lights) - 1, owner = u32(slot) + 1, score = score}
    caster_count += 1
  }
  slice.sort_by(casters[:caster_count], proc(a, b: Caster) -> bool {return a.score > b.score})
  selected, selected_count := select_shadow_casters(casters[:caster_count], &self.internal.shadow_maps, gctx.frame_serial)
  // marks the light shadowed until assign_shadow_layers picks its layer
  for c in selected[:selected_count] do self.internal.frame_lights[c.light].light.shadow_map = 0
  sort_lights_by_type(self)
  assign_shadow_layers(self)
}

// Pack the maps of shadowed lights into the shadow views in frame_lights
// order, one view per face; shadow view i renders atlas layer i.
// shadow_view_count is the layers taken.
@(private)
assign_shadow_layers :: proc(self: ^Manager) {
  layers: u32
  for &fl in self.internal.frame_lights {
    if fl.light.shadow_map == NO_SHADOW do continue
    fl.light.shadow_map = SHADOW_VIEW_BASE + layers
    layers += SHADOW_LAYERS[fl.type]
  }
  self.internal.shadow_view_count = layers
}

// Counting sort of frame_lights by type, stable, so each type's lights are
// one instance range of the lighting draw.
@(private)
sort_lights_by_type :: proc(self: ^Manager) {
  lights := self.internal.frame_lights[:]
  count: [LightType]u32
  for &fl in lights do count[fl.type] += 1
  first: [LightType]u32
  next: u32
  for type in LightType {
    first[type] = next
    next += count[type]
  }
  self.internal.light_first = first
  self.internal.light_count = count
  sorted := make([]FrameLight, len(lights), context.temp_allocator)
  for &fl in lights {
    sorted[first[fl.type]] = fl
    first[fl.type] += 1
  }
  copy(lights, sorted)
}

// Write frame_lights into frame `frame_index`'s light buffer and every face
// of their shadow maps into its view table.
@(private)
upload_lights :: proc(self: ^Manager, frame_index: u32) {
  dst := frame_table(self, .LIGHTS, LightGPU, frame_index)
  views := frame_table(self, .VIEWS, ViewGPU, frame_index)
  draws := &self.internal.shadow.draws
  _, shadow_mask := material_masks()
  for &fl, i in self.internal.frame_lights {
    dst[i] = fl.light
    if fl.light.shadow_map == NO_SHADOW do continue
    for face, f in SHADOW_FACES[fl.type][:SHADOW_LAYERS[fl.type]] {
      v := fl.light.shadow_map + u32(f)
      rotation := linalg.matrix4_look_at([3]f32{}, face[0], face[1])
      view_projection := fl.shadow_projection * rotation * fl.shadow_view
      views[v] = {
        planes          = geom.make_frustum(view_projection).planes,
        view_projection = view_projection,
        type_mask       = shadow_mask,
        require_flags   = SHADOW_CASTER_FLAGS,
        instance_tag    = v << 16,
        layer           = v - SHADOW_VIEW_BASE,
        draw_list       = draws.slot + frame_index,
        list_capacity   = draws.capacity,
      }
    }
  }
}

// The light at a slot placed at `world_matrix`. ok=false when the attachment
// is not a light.
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
    fl.type = .POINT
    fl.light = {
      color       = att.color,
      position    = position,
      radius       = att.radius,
      shadow_texel = shadow_texel_perspective(f32(math.PI * 0.5)),
    }
    fl.shadow_view = linalg.matrix4_translate(-position)
    fl.shadow_projection = shadow_projection_perspective(f32(math.PI * 0.5), att.radius)
    fl.shadow_bounds = {position.x, position.y, position.z, att.radius}
    cast_shadow = att.cast_shadow
  case SpotLightAttachment:
    fl.type = .SPOT
    fl.light = {
      color       = att.color,
      position    = position,
      direction   = direction,
      radius      = att.radius,
      angle_inner = att.angle_inner,
      angle_outer  = att.angle_outer,
      shadow_texel = shadow_texel_perspective(att.angle_outer * 2),
    }
    fl.shadow_view = shadow_make_light_view(position, direction)
    fl.shadow_projection = shadow_projection_perspective(att.angle_outer * 2, att.radius)
    // the point-light sphere around the cone: loose, but shared
    fl.shadow_bounds = {position.x, position.y, position.z, att.radius}
    cast_shadow = att.cast_shadow
  case DirectionalLightAttachment:
    fl.type = .DIRECTIONAL
    r := shadow_radius_directional(att.shadow_radius)
    fl.light = {color = att.color, direction = direction, shadow_texel = 2 * r / SHADOW_MAP_SIZE}
    fl.shadow_view, fl.shadow_projection = shadow_matrices_directional(position, direction, r)
    // the sphere around the shadow box
    fl.shadow_bounds = {position.x, position.y, position.z, r * math.SQRT_THREE}
    cast_shadow = att.cast_shadow
  case:
    return
  }
  ok = true
  return
}

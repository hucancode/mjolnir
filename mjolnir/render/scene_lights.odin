package render

import geom "../geometry"
import "core:math"
import "core:math/linalg"
import ba "core:container/bit_array"
import "core:slice"

// The faces of a light type's shadow map, one shadow view and atlas layer
// each: the six cube faces around a point light, one face otherwise. A face
// is the (forward, up) of a rotation applied after the light's shadow view;
// forward -Z with up +Y is the identity.
@(private)
SHADOW_FACES := [LightType][][2][3]f32 {
  .POINT       = {
    {{1, 0, 0}, {0, -1, 0}},
    {{-1, 0, 0}, {0, -1, 0}},
    {{0, 1, 0}, {0, 0, 1}},
    {{0, -1, 0}, {0, 0, -1}},
    {{0, 0, 1}, {0, -1, 0}},
    {{0, 0, -1}, {0, -1, 0}},
  },
  .SPOT        = {{{0, 0, -1}, {0, 1, 0}}},
  .DIRECTIONAL = {{{0, 0, -1}, {0, 1, 0}}},
  .AMBIENT     = {},
}

// A shadow-casting light this frame, or the holder of a shadow map
// (shadow_casters). Every frame the shadow casters seen by some camera are
// ranked by shadow_score; the top SHADOW_RANKED_CASTERS get a map, and the
// remaining maps go to casters that ranked within the last
// SHADOW_GRACE_FRAMES frames. Any other caster has no map and lights
// unshadowed. Maps own no textures: each frame packs the selected maps into
// the frame's shadow atlas (pack_lights).
@(private)
Caster :: struct {
  light:       int, // index into the frame's lights
  owner:       u32, // light slot + 1; 0 for a free map
  score:       f32,
  // frame serial when the owner last ranked in the top SHADOW_RANKED_CASTERS
  last_ranked: u64,
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

// Pick the casters that get a shadow map: `casters` sorted by descending
// score, `maps` as left by the previous frame and rewritten with the
// selection, `serial` this frame.
@(private)
select_shadow_casters :: proc(casters: []Caster, maps: ^[MAX_SHADOW_MAPS]Caster, serial: u64) -> (count: int) {
  selected: [MAX_SHADOW_MAPS]Caster
  for c, rank in casters {
    if count == MAX_SHADOW_MAPS do break
    c := c
    c.last_ranked = serial
    if rank >= SHADOW_RANKED_CASTERS {
      held := false
      for m in maps do if m.owner == c.owner {c.last_ranked = m.last_ranked; held = true}
      if !held || serial - c.last_ranked > SHADOW_GRACE_FRAMES do continue
    }
    selected[count] = c
    count += 1
  }
  maps^ = selected
  return
}

// Light `l` placed at `world_matrix`. Its shadow_map is NO_SHADOW until a map
// is assigned.
@(private)
place_light :: proc(l: Light, world_matrix: matrix[4, 4]f32) -> Light {
  l := l
  forward := world_matrix[2].xyz
  l.position = world_matrix[3].xyz
  l.direction = linalg.normalize(forward) if linalg.dot(forward, forward) > 1e-6 else {0, -1, 0}
  l.shadow_map = NO_SHADOW
  // world size of a shadow texel, per unit of view depth for a perspective map
  perspective_texel :: proc(fovy: f32) -> f32 {return 2 * math.tan(0.5 * max(fovy, 0.001)) / SHADOW_MAP_SIZE}
  switch l.type {
  case .POINT:
    l.shadow_texel = perspective_texel(math.PI * 0.5)
  case .SPOT:
    l.shadow_texel = perspective_texel(l.angle_outer * 2)
  case .DIRECTIONAL:
    // radius: half extent of the shadow box centered on the light
    l.radius = max(l.radius, 0.5)
    l.shadow_texel = 2 * l.radius / SHADOW_MAP_SIZE
  case .AMBIENT:
  }
  return l
}

// Sphere a light's shadow map covers: center xyz, radius w. A spot light
// shares the point light's sphere, loose but simple; a directional light's
// surrounds its shadow box.
@(private)
shadow_bounds :: proc(l: Light) -> [4]f32 {
  r := l.radius * (math.SQRT_THREE if l.type == .DIRECTIONAL else 1)
  return {l.position.x, l.position.y, l.position.z, r}
}

// View and projection of face `face` of a light's shadow map. Perspective
// maps reach the light's radius; a directional light's orthographic map
// covers the box of half extent radius centered on it.
@(private)
shadow_face_matrices :: proc(l: Light, face: [2][3]f32) -> (view, projection: matrix[4, 4]f32) {
  look :: proc(position, direction: [3]f32) -> matrix[4, 4]f32 {
    up := [3]f32{0, 0, 1} if math.abs(direction.y) > 0.95 else {0, 1, 0}
    return linalg.matrix4_look_at(position, position + direction, up)
  }
  perspective :: proc(fovy, radius: f32) -> matrix[4, 4]f32 {
    near :: 0.1
    return geom.make_perspective_matrix(max(fovy, 0.001), 1.0, near, max(near + 0.1, radius))
  }
  rotation := linalg.matrix4_look_at([3]f32{}, face[0], face[1])
  switch l.type {
  case .POINT:
    return rotation * linalg.matrix4_translate(-l.position), perspective(math.PI * 0.5, l.radius)
  case .SPOT:
    return rotation * look(l.position, l.direction), perspective(l.angle_outer * 2, l.radius)
  case .DIRECTIONAL:
    r := l.radius
    return rotation * look(l.position - l.direction * r, l.direction), geom.make_ortho_matrix(-r, r, -r, r, 0, 2 * r)
  case .AMBIENT:
  }
  return
}

// Counting sort of `lights` by type into `dst`, stable, so each type's lights
// are one instance range of the lighting draw, then the maps of shadowed
// lights (shadow_map != NO_SHADOW) packed into the shadow views in `dst`
// order, one view per face: shadow view i renders atlas layer i.
@(private)
pack_lights :: proc(lights, dst: []Light) -> (count: [LightType]u32, layers: u32) {
  for &l in lights do count[l.type] += 1
  first: [LightType]u32
  next: u32
  for type in LightType {
    first[type] = next
    next += count[type]
  }
  for &l in lights {
    dst[first[l.type]] = l
    first[l.type] += 1
  }
  for &l in dst[:len(lights)] {
    if l.shadow_map == NO_SHADOW do continue
    l.shadow_map = SHADOW_VIEW_BASE + layers
    layers += u32(len(SHADOW_FACES[l.type]))
  }
  return
}

// Write this frame's lights into frame `frame_index`'s light table: the
// ambient light, then the light slots in slot order, truncated to MAX_LIGHTS,
// grouped by type (light_count). The shadow casters some camera view (written
// by flush_cameras) sees are ranked for the shadow maps (select_shadow_casters),
// and every face of the selected maps is written into the view table. Caller
// holds the render mutex.
@(private)
collect_lights :: proc(self: ^Manager, frame_index: u32) {
  lights: [MAX_LIGHTS]Light
  lights[0] = {type = .AMBIENT, color = {1, 1, 1, self.ambient.ibl_intensity}, shadow_map = NO_SHADOW}
  n := 1
  views := frame_table(self, .VIEWS, ViewGPU, frame_index)
  cameras := views[CAMERA_VIEW_BASE:][:self.camera_slots.high_water]
  casters: [MAX_LIGHTS]Caster
  caster_count := 0
  nodes := frame_table(self, .NODES, NodeData, frame_index)
  it := ba.make_iterator(&self.light_slots)
  for slot in ba.iterate_by_set(&it) {
    if n == MAX_LIGHTS do break
    if .VISIBLE not_in nodes[slot].flags do continue
    light := self.attachments[slot].(Light) or_continue
    lights[n] = place_light(light, nodes[slot].world_matrix)
    n += 1
    if !light.cast_shadow do continue
    bounds := shadow_bounds(lights[n - 1])
    // -1: no camera sees the light
    score: f32 = -1
    for &v in cameras {
      if v.type_mask == 0 do continue
      if !geom.frustum_test_sphere({v.planes}, bounds.xyz, bounds.w) do continue
      score = max(score, shadow_score(bounds, light.color.a, v.position.xyz))
    }
    if score < 0 do continue
    casters[caster_count] = {light = n - 1, owner = u32(slot) + 1, score = score}
    caster_count += 1
  }
  slice.sort_by(casters[:caster_count], proc(a, b: Caster) -> bool {return a.score > b.score})
  maps := &self.shadow_casters
  selected := select_shadow_casters(casters[:caster_count], maps, self.gctx.frame_serial)
  // marks the light shadowed until pack_lights picks its layers
  for c in maps[:selected] do lights[c.light].shadow_map = 0
  dst := frame_table(self, .LIGHTS, Light, frame_index)
  self.light_count, self.shadow_view_count = pack_lights(lights[:n], dst)
  _, shadow_mask := material_masks()
  draws := &self.shadow_draws
  for &l in dst[:n] {
    if l.shadow_map == NO_SHADOW do continue
    for face, f in SHADOW_FACES[l.type] {
      v := l.shadow_map + u32(f)
      view, projection := shadow_face_matrices(l, face)
      view_projection := projection * view
      views[v] = {
        view            = view,
        projection      = projection,
        view_projection = view_projection,
        planes          = geom.make_frustum(view_projection).planes,
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

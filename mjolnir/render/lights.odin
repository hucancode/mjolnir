package render

import "../geometry"
import "core:math"
import "core:math/linalg"
import "core:slice"

// Lights: the placed point, spot and directional lights, and which of them get a shadow map each
// frame.

// make_spot_light's ratio of the full-intensity cone to the falloff cone.
@(private = "file")
SPOT_LIGHT_INNER_RATIO :: f32(0.75)

// Light shines from every slot it is attached to, along the slot's -Z axis, as a glTF light does
// (make_*_light fill one; light_create stores it). Point lights ignore the angles. A directional
// light (a sun) reaches everywhere at the same strength; the first-ranked one that casts shadows
// gets cascaded shadows fitted to the main camera.
Light :: struct #align(16) {
  color:              [3]f32,
  // strength at 1 unit away, falling off by inverse square and fading smoothly to zero at radius;
  // a directional light's strength everywhere
  intensity:          f32,
  // range of the light; for a directional light, how far in front of the main camera its
  // shadow reaches
  radius:             f32,
  angle_inner:        f32, // spot cone angles
  angle_outer:        f32,
  type:               LightType,
  // the light competes for a shadow map
  cast_shadow:        b32,
}
#assert(size_of(Light) == 48)

// LightHandle identifies a light (light_create).
LightHandle :: distinct u32

// Where a light is attached. shadow_map is the view of the placement's first shadow face
// this frame, 0 when it got none (collect_lights).
@(private)
LightPlacement :: struct {
  light:      LightHandle,
  node:       u32,
  shadow_map: u32,
}

// light_create stores `l`; attach places it at slots. It lives until light_destroy or teardown.
light_create :: proc(self: ^Renderer, l: Light) -> (handle: LightHandle, ok: bool) #optional_ok {
  i := resource_create(self, .LIGHTS, l) or_return
  return LightHandle(i), true
}

// light returns the light of `handle`, to edit in place; every slot it is attached to follows.
// The pointer is valid for this tick: getting it marks the data for upload, so get it again
// next tick.
light :: proc(self: ^Renderer, handle: LightHandle) -> (^Light, bool) #optional_ok {
  return resource(self, .LIGHTS, Light, u32(handle))
}

// light_destroy frees the light; slots it stays attached to shine nothing.
light_destroy :: proc(self: ^Renderer, handle: LightHandle) {
  resource_destroy(self, .LIGHTS, u32(handle))
}

// Where a light at a node's transform sits and shines: its translation and normalized forward
// (-Z) axis. The lighting shaders read a placed light the same way.
@(private)
light_pose :: proc(world_matrix: matrix[4, 4]f32) -> (position, direction: [3]f32) {
  forward := -world_matrix[2].xyz
  return world_matrix[3].xyz, linalg.normalize(forward) if linalg.dot(forward, forward) > 1e-6 else {0, -1, 0}
}

// make_point_light returns an omnidirectional Light for light_create.
make_point_light :: proc(
  color: [3]f32 = {1, 1, 1},
  intensity: f32 = 1.0,
  radius: f32 = 10.0,
  cast_shadow: bool = true,
) -> Light {
  return {type = .POINT, color = color, intensity = intensity, radius = radius, cast_shadow = b32(cast_shadow)}
}

// make_spot_light returns a cone Light of the given half angle for light_create, at full
// intensity within 3/4 of it.
make_spot_light :: proc(
  color: [3]f32 = {1, 1, 1},
  intensity: f32 = 1.0,
  radius: f32 = 10.0,
  angle: f32 = math.PI * 0.2,
  cast_shadow: bool = true,
) -> Light {
  return {
    type        = .SPOT,
    color       = color,
    intensity   = intensity,
    radius      = radius,
    angle_inner = angle * SPOT_LIGHT_INNER_RATIO,
    angle_outer = angle,
    cast_shadow = b32(cast_shadow),
  }
}

// make_directional_light returns a sun for light_create: it shines along its slot's -Z axis
// (e.g. rotation = linalg.quaternion_from_forward_and_up(direction, up)), its shadow reaching
// shadow_distance in front of the main camera.
make_directional_light :: proc(
  color: [3]f32 = {1, 1, 1},
  intensity: f32 = 1.0,
  shadow_distance: f32 = 20.0,
  cast_shadow: bool = true,
) -> Light {
  return {type = .DIRECTIONAL, color = color, intensity = intensity, radius = shadow_distance, cast_shadow = b32(cast_shadow)}
}

// matches SHADOW_CASCADES in the lighting shader
@(private)
SHADOW_CASCADES :: 4
// 0 splits uniformly, 1 logarithmically
@(private)
SHADOW_CASCADE_LOG_WEIGHT :: 0.75

// One shadow view and atlas layer per face.
@(private)
SHADOW_FACE_COUNT := [LightType]u32 {
  .POINT       = len(CUBE_FACES),
  .SPOT        = 1,
  .DIRECTIONAL = SHADOW_CASCADES,
}

// (forward, up) per face, in the order the lighting shader's shadowFace picks them
@(private)
CUBE_FACES := [6][2][3]f32 {
  {{1, 0, 0}, {0, -1, 0}},
  {{-1, 0, 0}, {0, -1, 0}},
  {{0, 1, 0}, {0, 0, 1}},
  {{0, -1, 0}, {0, 0, -1}},
  {{0, 0, 1}, {0, -1, 0}},
  {{0, 0, -1}, {0, -1, 0}},
}

// A shadow-casting light this frame, or the holder of a shadow map.
@(private)
Caster :: struct {
  owner:       u32, // light placement row + 1; 0 for a free map
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

// `casters` is sorted by descending score; `maps` is the previous selection, rewritten.
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

@(private = "file")
light_look :: proc(position, direction: [3]f32) -> matrix[4, 4]f32 {
  up := [3]f32{0, 0, 1} if math.abs(direction.y) > 0.95 else {0, 1, 0}
  return linalg.matrix4_look_at(position, position + direction, up)
}

@(private)
shadow_face_matrices :: proc(l: Light, position, direction: [3]f32, face: int) -> (view, projection: matrix[4, 4]f32) {
  perspective :: proc(fovy, radius: f32) -> matrix[4, 4]f32 {
    near :: 0.1
    return geometry.make_perspective_matrix(max(fovy, 0.001), 1.0, near, max(near + 0.1, radius))
  }
  switch l.type {
  case .POINT:
    rotation := linalg.matrix4_look_at([3]f32{}, CUBE_FACES[face][0], CUBE_FACES[face][1])
    return rotation * linalg.matrix4_translate(-position), perspective(math.PI * 0.5, l.radius)
  case .SPOT:
    return light_look(position, direction), perspective(l.angle_outer * 2, l.radius)
  case .DIRECTIONAL:
  }
  return
}

// Orthographic box around the bounding sphere of the cascade's camera-frustum slice: the
// sphere keeps the size fixed as the camera turns, texel snapping holds edges still as it moves.
@(private)
cascade_matrices :: proc(shadow_distance: f32, direction: [3]f32, cascade: int, camera: ^View) -> (view, projection: matrix[4, 4]f32) {
  near := camera.near
  far := max(min(max(shadow_distance, 0.5), camera.far), near + 0.01)
  split :: proc(near, far: f32, i: int) -> f32 {
    t := f32(i) / SHADOW_CASCADES
    return math.lerp(near + (far - near) * t, near * math.pow(far / near, t), f32(SHADOW_CASCADE_LOG_WEIGHT))
  }
  depth_range := max(camera.far - camera.near, 1e-6)
  from := (split(near, far, cascade) - camera.near) / depth_range
  to := (split(near, far, cascade + 1) - camera.near) / depth_range
  corners: [8][3]f32
  center: [3]f32
  for i in 0 ..< 4 {
    ndc := [2]f32{f32(i & 1) * 2 - 1, f32(i >> 1) * 2 - 1}
    a := camera.inv_view_projection * [4]f32{ndc.x, ndc.y, 0, 1}
    b := camera.inv_view_projection * [4]f32{ndc.x, ndc.y, 1, 1}
    // view depth is linear along the corner ray, for both projections
    a_world, b_world := a.xyz / a.w, b.xyz / b.w
    corners[i] = linalg.lerp(a_world, b_world, from)
    corners[i + 4] = linalg.lerp(a_world, b_world, to)
    center += corners[i] + corners[i + 4]
  }
  center /= 8
  r: f32
  for c in corners do r = max(r, linalg.distance(c, center))
  // rounded up, so float noise can't change the texel size
  r = math.ceil(r * 16) / 16
  texel := 2 * r / SHADOW_MAP_SIZE
  rotation := light_look({}, direction)
  c := (rotation * [4]f32{center.x, center.y, center.z, 1}).xyz
  c.xy = linalg.floor(c.xy / texel) * texel
  // the eye sits r towards the light from the center, the box 2r deep
  view = linalg.matrix4_translate([3]f32{-c.x, -c.y, -(c.z + r)}) * rotation
  return view, geometry.make_ortho_matrix(-r, r, -r, r, 0, 2 * r)
}

// The picked placements get consecutive shadow views in table order (view i renders atlas layer
// i), the rest none. Returns the layer count.
@(private)
assign_shadow_views :: proc(placements: []LightPlacement, lights: []Light, picked: []bool) -> (layers: u32) {
  for &p, i in placements {
    p.shadow_map = 0
    if !picked[i] do continue
    p.shadow_map = SHADOW_VIEW_BASE + layers
    layers += SHADOW_FACE_COUNT[lights[p.light].type]
  }
  return
}

// Picks this frame's shadow casters among the visible placed lights and writes their shadow
// views. The brightest visible directional light is the sun custom materials see; the brightest
// that casts shadows gets the cascades, given a main camera to fit them to. Caller holds the
// render mutex.
@(private)
collect_lights :: proc(self: ^Renderer, frame_index: u32) {
  views := write_table(self, .VIEWS, View)
  cameras := views[CAMERA_VIEW_BASE:][:self.slots[.CAMERAS].high_water]
  casters: [MAX_LIGHTS]Caster
  caster_count := 0
  _, has_eye := main_camera(self)
  eye := &views[CAMERA_VIEW_BASE + u32(self.main_camera)]
  nodes := write_table(self, .NODES, Node)
  lights := write_table(self, .LIGHTS, Light)
  placements := write_table(self, .LIGHT_PLACEMENTS, LightPlacement)[:self.slots[.LIGHT_PLACEMENTS].high_water]
  sun, cascaded := -1, -1
  brighter :: proc(lights: []Light, placements: []LightPlacement, l: Light, than: int) -> bool {
    return than < 0 || l.intensity > lights[placements[than].light].intensity
  }
  for p, i in placements {
    if p.light == 0 || .VISIBLE not_in nodes[p.node].flags do continue
    light := lights[p.light]
    if light.type == .DIRECTIONAL {
      if light.intensity <= 0 do continue
      if brighter(lights, placements, light, sun) do sun = i
      if light.cast_shadow && has_eye && brighter(lights, placements, light, cascaded) do cascaded = i
      continue
    }
    if !light.cast_shadow do continue
    // a spot light reuses the point light's sphere: loose but simple
    position, _ := light_pose(nodes[p.node].world_matrix)
    bounds := [4]f32{position.x, position.y, position.z, light.radius}
    // -1: no camera sees the light
    score: f32 = -1
    for &v in cameras {
      if v.type_mask == 0 do continue
      if !geometry.frustum_test_sphere({v.planes}, bounds.xyz, bounds.w) do continue
      score = max(score, shadow_score(bounds, light.intensity, v.position.xyz))
    }
    if score < 0 do continue
    casters[caster_count] = {owner = u32(i) + 1, score = score}
    caster_count += 1
  }
  self.sun = u32(sun + 1)
  slice.sort_by(casters[:caster_count], proc(a, b: Caster) -> bool {return a.score > b.score})
  maps := &self.shadow_casters
  selected := select_shadow_casters(casters[:caster_count], maps, dev.frame_serial(&self.gpu))
  picked: [MAX_LIGHTS]bool
  for c in maps[:selected] do picked[c.owner - 1] = true
  if cascaded >= 0 do picked[cascaded] = true
  self.shadow_view_count = assign_shadow_views(placements, lights, picked[:len(placements)])
  mark_dirty(self, .LIGHT_PLACEMENTS, 0, len(placements))
  mark_dirty(self, .VIEWS, SHADOW_VIEW_BASE, int(self.shadow_view_count))
  for p in placements {
    if p.shadow_map == 0 do continue
    light := lights[p.light]
    position, direction := light_pose(nodes[p.node].world_matrix)
    for f in 0 ..< SHADOW_FACE_COUNT[light.type] {
      view, projection: matrix[4, 4]f32
      if light.type == .DIRECTIONAL {
        view, projection = cascade_matrices(light.radius, direction, int(f), eye)
      } else {
        view, projection = shadow_face_matrices(light, position, direction, int(f))
      }
      view_projection := projection * view
      planes := geometry.make_frustum(view_projection).planes
      // casters between a directional light and its cascade's box still shadow it (the shadow
      // pipeline clamps their depth)
      if light.type == .DIRECTIONAL do planes[4] = {0, 0, 0, 1}
      v := p.shadow_map + f
      views[v] = {
        view            = view,
        projection      = projection,
        view_projection = view_projection,
        planes          = planes,
        type_mask       = GBUFFER_TYPES,
        require_flags   = SHADOW_CASTER_FLAGS,
        instance_tag    = v << 16,
        layer           = v - SHADOW_VIEW_BASE,
        draw_list       = SHADOW_DRAW_SLOT_BASE + frame_index,
        list_capacity   = SHADOW_LIST_CAPACITY,
        time            = f32(self.time),
      }
    }
  }
}

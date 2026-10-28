// Dragon: a mech dragon bolted together from primitives, riding a loop. Ported from the mech playground on hucancode.com.
package main

import "core:fmt"
import "core:hash"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:math/rand"
import mu "vendor:microui"
import "mjolnir"
import "mjolnir/animation"
import "mjolnir/debugui"
import "mjolnir/geometry"
import "mjolnir/input"
import "mjolnir/platform"
import "mjolnir/render"
import "mjolnir/world"

DEG :: math.PI / 180
LAP_SECONDS :: 4
STROKES :: 4
SWING :: 22 * DEG
BEND :: 20 * DEG

LOOP := [?][3]f32{{7.8, 5.5, 0}, {5.5, 2.7, 5.5}, {0, 5.2, 7.7}, {-5.5, 2.5, 5.5}, {-7.8, 5.6, 0}, {-5.5, 2.6, -5.5}, {0, 5.0, -7.7}, {5.5, 2.8, -5.5}}

PALETTE := [?][3]f32 {
  {0.75, 0.22, 0.17},
  {0.9, 0.49, 0.13},
  {0.95, 0.77, 0.06},
  {0.49, 0.8, 0.18},
  {0.15, 0.68, 0.38},
  {0.1, 0.74, 0.61},
  {0.2, 0.6, 0.86},
  {0.17, 0.35, 0.63},
  {0.56, 0.27, 0.68},
  {0.83, 0.33, 0.64},
  {0.78, 0.63, 0.4},
  {0.55, 0.43, 0.39},
  {0.58, 0.65, 0.65},
  {0.36, 0.43, 0.49},
  {0.91, 0.89, 0.85},
  {0.22, 0.28, 0.31},
}

Pose :: struct {
  offset, jaw, arm_swing, elbow, leg_swing, knee: f32,
}

REST_POSE :: Pose{0, 12 * DEG, math.PI / 6, math.PI / 4, -25 * DEG, 35 * DEG}

Limb :: enum u8 {
  NONE,
  ARM,
  FOREARM,
  LEG,
  SHIN,
}

Axis :: enum u8 {
  X,
  Y,
  Z,
  FREE,
}

Bone :: struct {
  parent: int,
  offset: [3]f32,
  rest:   quaternion128,
  axis:   Axis,
  angle:  f32,
  aim:    quaternion128,
}

Link :: struct {
  part:   PartKind,
  params: Params,
  parent: int,
  at:     Slot,
  joint:  Maybe(Joint),
  spine:  bool,
  limb:   Limb,
  sign:   f32,
  phase:  f32,
  mount:  SlotDef,
  first:  int,
  bone:   int,
  seat_r: quaternion128,
  seat_t: [3]f32,
  depth:  int,
}

Piece :: struct {
  node:     world.NodeHandle,
  bone:     int,
  group:    int,
  index:    int,
  unit:     Unit,
  position: [3]f32,
  rotation: quaternion128,
  scale:    [3]f32,
  key:      u32,
}

Group :: struct {
  link, count, pieces: int,
}

Xform :: struct {
  position: [3]f32,
  rotation: quaternion128,
}

Snapshot :: struct {
  bones:   [dynamic]Xform,
  pieces:  [dynamic]Xform,
  centers: [dynamic][3]f32,
  normals: [dynamic][3]f32,
}

App :: struct {
  platform:  platform.Platform,
  scene:     world.World,
  renderer:  render.Renderer,
  debug:     debugui.Context,
  input:     input.State,
  orbit:     render.Orbit,
  loop:      animation.Spline([3]f32),
  total:     f32,
  meshes:    map[Unit]render.MeshHandle,
  materials: [len(PALETTE)]render.MaterialHandle,
  links:     [dynamic]Link,
  bones:     [dynamic]Bone,
  pieces:    [dynamic]Piece,
  groups:    [dynamic]Group,
  cursor:    struct {
    bone, group: int,
    seat_r:      quaternion128,
    seat_t:      [3]f32,
  },
  live:      Snapshot,
  build:     Build,
  pose:      Pose,
  seed:      u32,
  autoplay:  bool,
  spin:      f32,
}

main :: proc() {
  context.logger = log.create_console_logger()
  app := new(App)
  app.pose = REST_POSE
  app.autoplay = true
  app.spin = 0.3
  app.seed = rand.uint32()
  build_play(app)
  if !platform.init(&app.platform, 1280, 720, "Dragon") do return
  if !render.init(&app.renderer, app.platform.window) do return
  if !world.init(&app.scene) do return
  if !animation.spline_init_closed(&app.loop, LOOP[:], 2048) do return
  app.total = animation.spline_arc_length(app.loop)
  mjolnir.run(
    mjolnir.Loop(App) {
      app = app,
      setup = setup,
      shutdown = shutdown,
      should_close = should_close,
      update = update,
      frame = frame,
    },
  )
}

should_close :: proc(app: ^App) -> bool {
  return platform.should_close(&app.platform)
}

frame :: proc(app: ^App) -> bool {
  return mjolnir.frame(&app.platform, &app.renderer)
}

setup :: proc(app: ^App) -> mjolnir.Setup {
  r := &app.renderer
  if !render.ready(r) do return .WAIT
  if !debugui.init(&app.debug, r) do return .FAIL

  mjolnir.spawn_mesh(&app.scene, r, render.primitive(r, .CUBE, .GRAY), {0, -0.05, 0}, scale = {24, 0.05, 24})
  lamp := world.spawn(&app.scene, {0, 4, 0})
  render.attach(r, lamp, render.light_create(r, render.make_point_light(color = {1, 0.95, 0.85}, intensity = 40, radius = 20)))

  for color, i in PALETTE {
    app.materials[i] = render.material_create(r, render.make_material(base_color_factor = {color.r, color.g, color.b, 1}, metallic_value = 0.2, roughness_value = 0.45))
  }
  build(app)

  app.orbit = {yaw = 0.7, pitch = 0.25, distance = 20, target = {0, 3, 0}}
  render.camera_orbit(render.main_camera(r), app.orbit)
  return .READY
}

shutdown :: proc(app: ^App) {
  snapshot_destroy(&app.live)
  build_destroy(&app.build)
  delete(app.meshes)
  delete(app.groups)
  delete(app.pieces)
  delete(app.bones)
  delete(app.links)
  animation.spline_destroy(&app.loop)
  world.shutdown(&app.scene)
  debugui.shutdown(&app.debug)
  render.shutdown(&app.renderer)
  platform.shutdown(&app.platform)
  free(app)
}

update :: proc(app: ^App, dt: f32) {
  render.lock(&app.renderer)
  defer render.unlock(&app.renderer)
  platform.read_input(&app.platform, &app.input)
  debugui.feed(&app.debug, &app.input, &app.renderer)
  panel(app)
  render.stage_overlay(&app.renderer, debugui.end(&app.debug))
  dragging := !app.input.mouse_captured && input.mouse_down(&app.input, .LEFT)
  if !dragging do app.orbit.yaw += app.spin * dt * 0.5
  render.orbit_drag(&app.orbit, render.main_camera(&app.renderer), &app.input)

  if app.autoplay do app.pose.offset = math.mod(app.pose.offset + dt / LAP_SECONDS, 1)
  build_step(app, dt)
  place(app)
  mjolnir.update(&app.scene, &app.renderer, dt)
}

place :: proc(app: ^App) {
  snapshot(app, app.pose.offset, &app.live)
  if app.build.t < 1 {
    assemble(app)
    return
  }
  for p, i in app.pieces {
    x := app.live.pieces[i]
    world.set_local(&app.scene, p.node, x.position, x.rotation, p.scale)
    world.set_visible(&app.scene, p.node, true)
  }
}

panel :: proc(app: ^App) {
  ctx := debugui.begin(&app.debug)
  if debugui.window(&app.debug, "Dragon", {20, 20, 290, 180}, {}) {
    mu.layout_row(ctx, {-1}, 0)
    mu.checkbox(ctx, "Autoplay", &app.autoplay)
    mu.layout_row(ctx, {110, -1}, 0)
    mu.label(ctx, "loop offset")
    mu.slider(ctx, &app.pose.offset, 0, 1, 0, "%.2f")
    mu.label(ctx, "spin")
    mu.slider(ctx, &app.spin, 0, 3, 0, "%.1f")
    mu.layout_row(ctx, {-1}, 0)
    if .SUBMIT in mu.button(ctx, "New colors") {
      app.seed = rand.uint32()
      recolor(app)
    }
    mu.layout_row(ctx, {110, -1}, 0)
    if .SUBMIT in mu.button(ctx, "Assemble") do build_play(app)
    before := app.build.t
    if .CHANGE in mu.slider(ctx, &app.build.t, 0, 1, 0, "%.2f") do build_scrub(app, before)
  }
  if debugui.window(&app.debug, "Rig", {970, 20, 290, 200}, {.RIGHT, .TOP}) {
    mu.layout_row(ctx, {110, -1}, 0)
    angle_slider(ctx, "jaw open", &app.pose.jaw, 0, 45)
    angle_slider(ctx, "arm swing", &app.pose.arm_swing, -180, 180)
    angle_slider(ctx, "elbow bend", &app.pose.elbow, 0, 70)
    angle_slider(ctx, "leg swing", &app.pose.leg_swing, -60, 60)
    angle_slider(ctx, "knee bend", &app.pose.knee, 0, 60)
    mu.layout_row(ctx, {-1}, 0)
    if .SUBMIT in mu.button(ctx, "Reset") {
      offset := app.pose.offset
      app.pose = REST_POSE
      app.pose.offset = offset
    }
  }
}

angle_slider :: proc(ctx: ^mu.Context, label: string, value: ^f32, lo, hi: f32) {
  mu.label(ctx, label)
  degrees := value^ / DEG
  if .CHANGE in mu.slider(ctx, &degrees, lo, hi, 1, "%.0f") do value^ = degrees * DEG
}

mesh :: proc(app: ^App, unit: Unit) -> render.MeshHandle {
  if handle, ok := app.meshes[unit]; ok do return handle
  r := &app.renderer
  g: geometry.Mesh
  switch unit.kind {
  case .BOX:
    g = geometry.make_wedge(unit.param) if unit.param > 0 else geometry.make_cube()
  case .CYLINDER:
    g = geometry.make_cylinder(segments = 24, height = 1)
  case .HALF_CYLINDER:
    g = geometry.make_cylinder(segments = 16, height = 1, arc = math.PI)
  case .QUARTER_CYLINDER:
    g = geometry.make_cylinder(segments = 10, height = 1, arc = math.PI / 2)
  case .CONE:
    g = geometry.make_cone(segments = 24, height = 1, top_radius = unit.param)
  case .SPHERE:
    g = geometry.make_sphere()
  }
  handle := render.mesh_create(r, g)
  app.meshes[unit] = handle
  return handle
}

attach :: proc(app: ^App, p: Piece) {
  material := app.materials[(p.key ~ app.seed) % len(PALETTE)]
  render.attach(&app.renderer, p.node, render.MeshAttachment{mesh = mesh(app, p.unit), material = material, cast_shadow = true})
}

recolor :: proc(app: ^App) {
  for p in app.pieces do attach(app, p)
}

add :: proc(app: ^App, shape: Shape) {
  s := shape
  c := &app.cursor
  index := app.groups[c.group].count
  app.groups[c.group].count += 1
  app.groups[c.group].pieces += s.count
  for part in s.parts[:s.count] {
    key := fmt.tprintf("%v %.4f %.4f %.4f %.4f", part.unit.kind, part.unit.param, part.scale.x, part.scale.y, part.scale.z)
    p := Piece {
      node     = world.spawn(&app.scene),
      bone     = c.bone,
      group    = c.group,
      index    = index,
      unit     = part.unit,
      position = c.seat_t + linalg.quaternion128_mul_vector3(c.seat_r, part.position),
      rotation = c.seat_r * part.rotation,
      scale    = part.scale,
      key      = hash.fnv32a(transmute([]u8)key),
    }
    append(&app.pieces, p)
    attach(app, p)
  }
}

emit :: proc(app: ^App, bone: int, seat_r := linalg.QUATERNIONF32_IDENTITY, seat_t: [3]f32 = {}) {
  app.cursor = {bone, len(app.groups) - 1, seat_r, seat_t}
}

bone :: proc(app: ^App, parent: int, offset: [3]f32, rest: quaternion128, axis: Axis) -> int {
  append(&app.bones, Bone{parent = parent, offset = offset, rest = rest, axis = axis, aim = linalg.QUATERNIONF32_IDENTITY})
  return len(app.bones) - 1
}

link :: proc(app: ^App, part: PartKind, parent: int, at: Slot, params: Maybe(Params) = nil, spine := false) -> int {
  append(&app.links, Link{part = part, params = params.? or_else PARAMS[part], parent = parent, at = at, spine = spine})
  return len(app.links) - 1
}

limb :: proc(app: ^App, upper, lower: Limb, parent: int, at: Slot, joint: Joint, sign, phase: f32) {
  arm := upper == .ARM
  up := link(app, .UPPER_ARM if arm else .THIGH, parent, at)
  low := link(app, .FOREARM if arm else .SHIN, up, .ELBOW if arm else .KNEE)
  app.links[up].joint = joint
  app.links[up].limb, app.links[low].limb = upper, lower
  app.links[up].sign, app.links[low].sign = sign, sign
  app.links[up].phase, app.links[low].phase = phase, phase
}

build :: proc(app: ^App) {
  head := link(app, .HEAD, -1, .NECK)
  link(app, .JAW, head, .JAW)
  prev := link(app, .BODY_SEGMENT, head, .NECK, spine = true)
  shoulders, hips: int
  for i in 2 ..= 6 {
    prev = link(app, .BODY_SEGMENT, prev, .REAR, spine = true)
    if i == 2 do shoulders = prev
    if i == 5 do hips = prev
  }
  prev = link(app, .BODY_SEGMENT2, prev, .REAR, TAPER_START, true)
  for _ in 0 ..< 3 do prev = link(app, .BODY_SEGMENT2, prev, .REAR, spine = true)
  link(app, .TAIL, prev, .REAR, spine = true)
  limb(app, .ARM, .FOREARM, shoulders, .FLANK_L, SHOULDER, 1, 0)
  limb(app, .ARM, .FOREARM, shoulders, .FLANK_R, SHOULDER, -1, 0.5)
  limb(app, .LEG, .SHIN, hips, .FLANK_L, HIP, 1, 0.5)
  limb(app, .LEG, .SHIN, hips, .FLANK_R, HIP, -1, 0)

  for &l, i in app.links {
    l.mount = slots(l.part, l.params)[.MOUNT].? or_else {}
    if l.parent < 0 {
      l.mount = slots(l.part, l.params)[l.at].?
      l.first = bone(app, -1, {}, linalg.QUATERNIONF32_IDENTITY, .FREE)
      l.bone = l.first
      l.seat_r, l.seat_t = linalg.QUATERNIONF32_IDENTITY, -l.mount.face.position
    } else {
      parent := &app.links[l.parent]
      l.depth = parent.depth + 1
      slot := slots(parent.part, parent.params)[l.at].?
      j := l.joint.? or_else slot.joint.?
      a, b := mounts(j)
      origin, r0 := geometry.seat(slot.face, a)
      if slot.axis do origin = slot.face.position
      r := parent.seat_r * r0
      origin = parent.seat_t + linalg.quaternion128_mul_vector3(parent.seat_r, origin)
      append(&app.groups, Group{link = i})
      switch j.kind {
      case .HINGE:
        l.first = bone(app, parent.bone, origin, r, .X)
        l.bone = l.first
        emit(app, parent.bone, r, origin)
        hinge_female(app, j, false)
        emit(app, l.first)
        hinge_male(app, j, false, false)
      case .DISC_HINGE:
        l.first = bone(app, parent.bone, origin, r, .Y)
        swing := bone(app, l.first, {}, around(HPI, X), .X)
        l.bone = bone(app, swing, {}, linalg.QUATERNIONF32_IDENTITY, .Y)
        emit(app, l.first)
        hinge_female(app, j, true)
        emit(app, swing)
        hinge_male(app, j, true, true)
      case .BALL:
        l.first = bone(app, parent.bone, origin, r, .FREE)
        l.bone = l.first
        emit(app, parent.bone, r, origin)
        ball_female(app, j)
        emit(app, l.first)
        ball_male(app, j)
      }
      position: [3]f32
      position, l.seat_r = geometry.seat(b, l.mount.face)
      l.seat_t = -linalg.quaternion128_mul_vector3(l.seat_r, l.mount.face.position) if l.mount.axis else position
    }
    append(&app.groups, Group{link = i})
    emit(app, l.bone, l.seat_r, l.seat_t)
    build_part(app, l.part, l.params)
  }
}

ride :: proc(app: ^App, pose: Pose) {
  wrap :: proc(x: f32) -> f32 {
    return x - math.floor(x)
  }
  s := make([dynamic]f32, 0, 16, context.temp_allocator)
  append(&s, wrap(pose.offset) * app.total)
  for l in app.links do if l.spine do append(&s, march_back(app, s[len(s) - 1], linalg.length(app.bones[l.first].offset)))
  pivots := make([][3]f32, len(s), context.temp_allocator)
  for v, i in s do pivots[i] = position_at(app, v)
  tip := position_at(app, march_back(app, s[len(s) - 1], PARAMS[.TAIL].core_len))
  root := &app.bones[app.links[0].first]
  root.offset = pivots[0]
  root.aim = frame_from_z(tangent_at(app, s[0]))
  k := 1
  for l in app.links {
    if !l.spine do continue
    next := pivots[k + 1] if k + 1 < len(pivots) else tip
    app.bones[l.first].aim = frame_from_z(pivots[k] - next) * linalg.quaternion_inverse(l.seat_r)
    k += 1
  }
  for l in app.links {
    if l.part == .JAW do app.bones[l.first].angle = pose.jaw
    if l.limb == .NONE do continue
    phase := (wrap(pose.offset) * STROKES + l.phase) * 2 * math.PI
    angle: f32
    switch l.limb {
    case .NONE:
    case .ARM:
      angle = l.sign * (pose.arm_swing + SWING * math.sin(phase))
    case .LEG:
      angle = l.sign * (pose.leg_swing + SWING * math.sin(phase))
    case .FOREARM:
      angle = pose.elbow + BEND * math.sin(phase - HPI)
    case .SHIN:
      angle = pose.knee + BEND * math.sin(phase - HPI)
    }
    app.bones[l.first].angle = angle
  }
}

position_at :: proc(app: ^App, s: f32) -> [3]f32 {
  return animation.spline_sample_uniform(app.loop, s - math.floor(s / app.total) * app.total)
}

tangent_at :: proc(app: ^App, s: f32) -> [3]f32 {
  return linalg.normalize(position_at(app, s + app.total * 1e-3) - position_at(app, s))
}

march_back :: proc(app: ^App, s, dist: f32) -> f32 {
  if dist <= 1e-9 do return s
  anchor := position_at(app, s)
  chord :: proc(app: ^App, s, k: f32, anchor: [3]f32) -> f32 {
    return linalg.length(position_at(app, s - k) - anchor)
  }
  lo := dist
  if chord(app, s, lo, anchor) >= dist - 1e-9 do return s - lo
  limit := app.total * 0.5
  hi, step := lo, max(dist * 0.25, app.total / 1500)
  for hi < limit {
    hi = min(limit, hi + step)
    if chord(app, s, hi, anchor) >= dist do break
    step *= 2
  }
  for _ in 0 ..< 24 {
    m := (lo + hi) / 2
    if chord(app, s, m, anchor) < dist do lo = m
    else do hi = m
  }
  return s - (lo + hi) / 2
}

frame_from_z :: proc(z: [3]f32) -> quaternion128 {
  fz := linalg.normalize(z)
  fx := linalg.cross(Y, fz)
  if linalg.length(fx) < 1e-4 do fx = linalg.cross(X, fz)
  fx = linalg.normalize(fx)
  fy := linalg.cross(fz, fx)
  m := matrix[3, 3]f32{
    fx.x, fy.x, fz.x,
    fx.y, fy.y, fz.y,
    fx.z, fy.z, fz.z,
  }
  return linalg.normalize(linalg.quaternion_from_matrix3_f32(m))
}

snapshot :: proc(app: ^App, offset: f32, out: ^Snapshot) {
  pose := app.pose
  pose.offset = offset
  ride(app, pose)
  resize(&out.bones, len(app.bones))
  for b, i in app.bones {
    parent := Xform{rotation = linalg.QUATERNIONF32_IDENTITY}
    if b.parent >= 0 do parent = out.bones[b.parent]
    m: quaternion128
    switch b.axis {
    case .X:
      m = around(b.angle, X)
    case .Y:
      m = around(b.angle, Y)
    case .Z:
      m = around(b.angle, Z)
    case .FREE:
      m = linalg.quaternion_inverse(b.rest) * linalg.quaternion_inverse(parent.rotation) * b.aim
    }
    out.bones[i] = {parent.position + linalg.quaternion128_mul_vector3(parent.rotation, b.offset), linalg.normalize(parent.rotation * b.rest * m)}
  }
  resize(&out.pieces, len(app.pieces))
  resize(&out.centers, len(app.groups))
  resize(&out.normals, len(app.groups))
  for &c in out.centers do c = {}
  for p, i in app.pieces {
    w := out.bones[p.bone]
    out.pieces[i] = {w.position + linalg.quaternion128_mul_vector3(w.rotation, p.position), w.rotation * p.rotation}
    out.centers[p.group] += out.pieces[i].position
  }
  for g, i in app.groups {
    l := app.links[g.link]
    out.centers[i] /= f32(max(1, g.pieces))
    out.normals[i] = -linalg.normalize(linalg.quaternion128_mul_vector3(out.bones[l.bone].rotation * l.seat_r, l.mount.face.normal))
  }
}

snapshot_destroy :: proc(s: ^Snapshot) {
  delete(s.bones)
  delete(s.pieces)
  delete(s.centers)
  delete(s.normals)
}

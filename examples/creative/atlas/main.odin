// Atlas: a robot built from hinges and ball joints, driven by channels. Watch it dance, or pose it.
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
X :: [3]f32{1, 0, 0}
Y :: [3]f32{0, 1, 0}
Z :: [3]f32{0, 0, 1}
NEG_X :: [3]f32{-1, 0, 0}
NEG_Y :: [3]f32{0, -1, 0}

Side :: enum u8 {
  L,
  R,
}

Channel :: enum u8 {
  HIP_LEVEL,
  HEAD_YAW,
  HEAD_PITCH,
  TWIST,
  WAIST_BEND,
  WAIST_TILT,
  SHOULDER,
  ARM_OUT,
  ARM_TWIST,
  ELBOW,
  FORE_TWIST,
  WRIST_BEND,
  WRIST_TILT,
  WRIST_TWIST,
  CURL,
  HIP,
  KNEE,
  ANKLE,
  CURL_BASE,
  CURL_MID,
  CURL_TIP,
}

RIGHT :: len(Channel) - int(Channel.SHOULDER)
CHANNEL_COUNT :: len(Channel) + RIGHT
Pose :: [CHANNEL_COUNT]f32

Tier :: enum u8 {
  CORE,
  LIMB,
  TIP,
}

Control :: struct {
  name:       string,
  min, max:   f32,
  big, ratio: bool,
  tier:       Tier,
}

CONTROLS := [Channel]Control {
  .HIP_LEVEL   = {"hip level", -1.5, 0, true, true, .CORE},
  .HEAD_YAW    = {"head yaw", -math.PI, math.PI, true, false, .TIP},
  .HEAD_PITCH  = {"head pitch", -30 * DEG, 30 * DEG, true, false, .TIP},
  .TWIST       = {"waist twist", -math.PI, math.PI, true, false, .CORE},
  .WAIST_BEND  = {"waist bend", -45 * DEG, 45 * DEG, true, false, .CORE},
  .WAIST_TILT  = {"waist tilt", -45 * DEG, 45 * DEG, true, false, .CORE},
  .SHOULDER    = {"arm swing", -math.PI, math.PI, true, false, .LIMB},
  .ARM_OUT     = {"arm raise", -10 * DEG, math.PI, true, false, .LIMB},
  .ARM_TWIST   = {"arm twist", -math.PI, math.PI, true, false, .LIMB},
  .ELBOW       = {"elbow bend", -math.PI / 2, math.PI / 2, false, false, .LIMB},
  .FORE_TWIST  = {"forearm twist", -math.PI, math.PI, false, false, .LIMB},
  .WRIST_BEND  = {"wrist bend", -100 * DEG, 100 * DEG, false, false, .TIP},
  .WRIST_TILT  = {"wrist tilt", -100 * DEG, 100 * DEG, false, false, .TIP},
  .WRIST_TWIST = {"wrist twist", -math.PI, math.PI, false, false, .TIP},
  .CURL        = {"finger curl", 0, 1, false, true, .TIP},
  .HIP         = {"leg swing", -45 * DEG, 45 * DEG, true, false, .CORE},
  .KNEE        = {"knee bend", -math.PI / 3, 0, true, false, .LIMB},
  .ANKLE       = {"ankle bend", -30 * DEG, 30 * DEG, false, false, .TIP},
  .CURL_BASE   = {},
  .CURL_MID    = {},
  .CURL_TIP    = {},
}

HOME := Pose {
  int(Channel.ARM_OUT)            = math.PI / 6,
  int(Channel.ARM_OUT) + RIGHT    = math.PI / 6,
  int(Channel.ELBOW)              = math.PI / 3,
  int(Channel.ELBOW) + RIGHT      = math.PI / 3,
  int(Channel.WRIST_TILT)         = math.PI / 6,
  int(Channel.WRIST_TILT) + RIGHT = math.PI / 6,
  int(Channel.CURL)               = 0.35,
  int(Channel.CURL) + RIGHT       = 0.35,
}

CURL_RANGES := [3]struct {
  from, to: [2]f32,
} {
  {{0, 0.5}, {0, -math.PI / 6}},
  {{0.2, 0.8}, {0, math.PI / 4}},
  {{0.5, 1}, {0, math.PI / 4}},
}

PALETTE := [?][3]f32 {
  {0.65, 0.12, 0.14},
  {0.95, 0.45, 0.15},
  {0.98, 0.82, 0.25},
  {0.75, 0.88, 0.35},
  {0.2, 0.55, 0.25},
  {0.1, 0.35, 0.3},
  {0.3, 0.8, 0.75},
  {0.55, 0.82, 0.95},
  {0.15, 0.35, 0.7},
  {0.12, 0.15, 0.4},
  {0.45, 0.25, 0.65},
  {0.85, 0.55, 0.9},
  {0.92, 0.3, 0.55},
  {0.96, 0.94, 0.88},
  {0.5, 0.55, 0.6},
  {0.12, 0.14, 0.17},
}

HEAD_R :: 0.28
HEAD_D :: 0.56
INNER_R :: 0.24
CHEST_W :: 1.15
CHEST_H :: 0.95
CHEST_D :: 0.68
TAPER_H :: 0.13
CHEST_Y :: TAPER_H - 0.04
CHEST_TOP :: CHEST_Y + CHEST_H
FLANK_R :: CHEST_D / 2
NECK_Y :: CHEST_TOP + 0.1
SHOULDER_Y :: CHEST_TOP - 0.3
CONE_LEN :: 0.14
HIP_W :: 0.72
HIP_H :: 0.25
DISC_T :: 0.14
DOME_W :: HIP_W * 0.6
HIP_Y :: -0.14 - HIP_H * 0.45
ARM_LEN :: 0.3
ARM_W :: 0.3
FORE_LEN :: 0.24
FORE_W :: 0.26
PALM_W :: 0.26
PALM_H :: 0.26
PALM_D :: 0.24
DIGIT_LEN :: 0.12
DIGIT_W :: 0.1
THIGH_LEN :: 0.56
THIGH_W :: 0.38
SHIN_LEN :: 0.6
SHIN_W :: 0.32
FOOT_LEN :: 0.62
FOOT_W :: 0.32
HEEL_D :: 0.14
HEEL_CAP_D :: 0.14
FOOT_H :: 0.2
TOE_D :: 0.2
ANKLE_D :: 0.24
SOLE_Y :: -0.02
SHANK :: 0.12
FLANGE_T :: 0.16
REACH :: SHANK + FLANGE_T
WRIST_DROP :: -(2 * SHANK + FLANGE_T)
STUD_R :: 0.11

Kind :: enum {
  HINGE,
  HINGE_TWIST,
  PIN,
  DISC_HINGE,
  WRIST,
  BALL,
}

Joint :: struct {
  name:                  string,
  kind:                  Kind,
  jaw, lug_t, lug_d:     f32,
  pin_r, clr, pin_out:   f32,
  tang, disc_f, disc_m:  bool,
  ball_r, socket_t:      f32,
  stud_len, flange_w:    f32,
  flange_t:              f32,
}

WAIST :: Joint{name = "waist", kind = .BALL, ball_r = 0.17, socket_t = 0.07, stud_len = 0.05, flange_w = 0.44, flange_t = 0.06}
NECK :: Joint{name = "neck", kind = .BALL, ball_r = 0.12, socket_t = 0.06, stud_len = 0.04, flange_w = 0.34, flange_t = 0.05}
SHOULDER :: Joint{name = "shoulder", kind = .DISC_HINGE, jaw = 0.1, lug_t = 0.06, lug_d = 0.22, pin_r = 0.05, clr = 0.03}
HIP :: Joint{name = "hip", kind = .DISC_HINGE, jaw = 0.09, lug_t = 0.055, lug_d = 0.2, pin_r = 0.045, clr = 0.03}
ELBOW :: Joint{name = "elbow", kind = .HINGE_TWIST, jaw = 0.14, lug_t = 0.06, lug_d = 0.24, pin_r = 0.05, clr = 0.008, tang = true, disc_m = true}
WRIST :: Joint{name = "wrist", kind = .WRIST, jaw = 0.1, lug_t = 0.05, lug_d = 0.2, pin_r = 0.04, clr = 0.008, tang = true}
KNEE :: Joint{name = "knee", kind = .HINGE, jaw = 0.15, lug_t = 0.07, lug_d = 0.3, pin_r = 0.06, clr = 0.03, tang = true, disc_f = true, disc_m = true}
ANKLE :: Joint{name = "ankle", kind = .HINGE, jaw = 0.14, lug_t = 0.065, lug_d = 0.26, pin_r = 0.055, clr = 0.03, tang = true, disc_f = true, disc_m = true}
KNUCKLE :: Joint{name = "knuckle", kind = .PIN, jaw = 0.06, lug_t = 0.01, pin_r = 0.035, clr = 0.005, pin_out = 0.01}

Bind :: struct {
  channel: int,
  sign:    f32,
}

Axis :: enum u8 {
  X,
  Y,
  Z,
}

Bone :: struct {
  parent:  int,
  offset:  [3]f32,
  rest:    quaternion128,
  axis:    Axis,
  channel: int,
  sign:    f32,
  node:    world.NodeHandle,
}

BonePose :: struct {
  user:     world.NodeHandle,
  position: [3]f32,
  rotation: quaternion128,
}

Frame :: struct {
  bone:     int,
  position: [3]f32,
  rotation: quaternion128,
}

Mesh :: enum {
  BOX,
  CYLINDER,
  HALF_CYLINDER,
  SHOULDER_CONE,
  SPHERE,
  FOOT_SLOPE,
  HEEL_SLOPE,
}

Piece :: struct {
  node: world.NodeHandle,
  mesh: Mesh,
  key:  u32,
}

Leg :: struct {
  hip, knee, ankle: int,
}

Orb :: struct {
  node:                 world.NodeHandle,
  radius, height, tilt: f32,
  speed, phase:         f32,
}

ORB_COLORS := [?][3]f32{{1, 0.35, 0.4}, {1, 0.65, 0.3}, {0.45, 1, 0.55}, {0.35, 0.75, 1}, {0.75, 0.45, 1}}
ORB_SIZE :: 0.1

App :: struct {
  orbs:      [len(ORB_COLORS)]Orb,
  elapsed:   f32,
  platform:  platform.Platform,
  scene:     world.World,
  renderer:  render.Renderer,
  debug:     debugui.Context,
  input:     input.State,
  orbit:     render.Orbit,
  bones:     [dynamic]Bone,
  poses:     [dynamic]BonePose,
  origin:    [3]f32,
  meshes:    [Mesh]render.MeshHandle,
  materials: [len(PALETTE)]render.MaterialHandle,
  pieces:    [dynamic]Piece,
  part:      string,
  count:     int,
  seed:      u32,
  legs:      [Side]Leg,
  thigh:     f32,
  shin:      f32,
  hip_y:     f32,
  ankle_y:   f32,
  root_y:    f32,
  pose:      Pose,
  choreo:    Choreo,
  dancing:   bool,
  tempo:     f32,
}

chan :: proc(c: Channel, side := Side.L) -> int {
  return int(c) if c < .SHOULDER || side == .L else int(c) + RIGHT
}

channel_of :: proc(key: int) -> (Channel, Side) {
  if key < len(Channel) do return Channel(key), .L
  return Channel(key - RIGHT), .R
}

is_limb :: proc(c: Channel) -> bool {
  return c >= .SHOULDER
}

is_leg :: proc(c: Channel) -> bool {
  return c == .HIP || c == .KNEE || c == .ANKLE
}

main :: proc() {
  context.logger = log.create_console_logger()
  app := new(App)
  app.pose = HOME
  app.dancing = true
  app.tempo = 60 / PERIOD
  app.seed = rand.uint32()
  if !platform.init(&app.platform, 1024, 720, "Atlas") do return
  if !render.init(&app.renderer, app.platform.window) do return
  if !world.init(&app.scene) do return
  choreo_init(&app.choreo, rand.uint32(), true)
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
  platform.poll_events(&app.platform)
  return render.frame(&app.renderer)
}

setup :: proc(app: ^App) -> mjolnir.Setup {
  r := &app.renderer
  if !render.ready(r) do return .WAIT
  if !debugui.init(&app.debug, r, {1024, 720}) do return .FAIL

  ground := world.spawn(&app.scene, {0, -0.05, 0})
  render.attach(r, render.SlotHandle(ground.index), render.primitive(r, .CUBE, .GRAY))
  world.scale(&app.scene, ground, [3]f32{20, 0.05, 20})

  disc_r := math.hypot(jaw_width(SHOULDER) + 2 * SHOULDER.lug_t, SHOULDER.lug_d) / 2
  app.meshes = {
    .BOX           = render.mesh_create(r, render.make_cube()),
    .CYLINDER      = render.mesh_create(r, render.make_cylinder(segments = 24, height = 1)),
    .HALF_CYLINDER = render.mesh_create(r, render.make_cylinder(segments = 16, height = 1, arc = math.PI)),
    .SHOULDER_CONE = render.mesh_create(r, render.make_cone(segments = 24, height = 1, top_radius = disc_r / (disc_r + 0.07))),
    .SPHERE        = render.mesh_create(r, render.make_sphere()),
    .FOOT_SLOPE    = render.mesh_create(r, render.make_wedge(0.55)),
    .HEEL_SLOPE    = render.mesh_create(r, render.make_wedge(0.7)),
  }
  for color, i in PALETTE {
    app.materials[i] = render.material_create(r, render.make_material(base_color_factor = {color.r, color.g, color.b, 1}, metallic_value = 0.2, roughness_value = 0.45))
  }
  build(app)
  stand(app)
  for color, i in ORB_COLORS {
    light, ok := render.light_create(r, render.make_point_light(color, 30, 12))
    if !ok do continue
    f := f32(i)
    orb := &app.orbs[i]
    orb^ = {
      radius = 2.4 + 0.3 * f,
      height = 1 + 0.9 * f,
      tilt   = 0.5 * math.sin(f * 2.1),
      speed  = (0.6 + 0.2 * f) * (1 if i % 2 == 0 else -1),
      phase  = f * math.TAU / len(ORB_COLORS),
    }
    orb.node = world.spawn(&app.scene, orb_position(orb^, 0))
    render.attach(r, render.SlotHandle(orb.node.index), light)
    marker := world.spawn(&app.scene, parent = orb.node)
    material := render.material_create(r, render.make_material(base_color_factor = {color.r, color.g, color.b, 1}, emissive_value = 5))
    render.attach(r, render.SlotHandle(marker.index), render.MeshAttachment{mesh = app.meshes[.SPHERE], material = material})
    world.scale(&app.scene, marker, ORB_SIZE)
  }

  app.orbit = {yaw = 0.7, pitch = 0.25, distance = 7, target = {0, 2.6, 0}}
  render.camera_orbit(render.main_camera(r), app.orbit)
  return .READY
}

shutdown :: proc(app: ^App) {
  delete(app.pieces)
  choreo_destroy(&app.choreo)
  delete(app.bones)
  delete(app.poses)
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
  render.orbit_drag(&app.orbit, &app.input)
  render.camera_orbit(render.main_camera(&app.renderer), app.orbit)

  if app.dancing do choreo_step(&app.choreo, dt * app.tempo * PERIOD / 60, &app.pose)
  pose(app)
  app.elapsed += dt
  for orb in app.orbs do world.translate(&app.scene, orb.node, orb_position(orb, app.elapsed))
  world.update(&app.scene)
  render.stage_transforms(&app.renderer, world.changes(&app.scene))
  render.update(&app.renderer, dt)
}

orb_position :: proc(o: Orb, t: f32) -> [3]f32 {
  a := o.phase + o.speed * t
  return {o.radius * math.cos(a), o.height + o.radius * o.tilt * math.sin(a), o.radius * math.sin(a)}
}

pose :: proc(app: ^App) {
  solved := app.pose
  drop := hip_drop(app, solved[Channel.HIP_LEVEL])
  for side in Side {
    curl := solved[chan(.CURL, side)]
    for c, i in CURL_RANGES {
      t := clamp((curl - c.from[0]) / (c.from[1] - c.from[0]), 0, 1)
      solved[chan(Channel(int(Channel.CURL_BASE) + i), side)] = math.lerp(c.to[0], c.to[1], t)
    }
    hip, knee, ankle := chan(.HIP, side), chan(.KNEE, side), chan(.ANKLE, side)
    z := app.thigh * math.sin(solved[hip]) + app.shin * math.sin(solved[hip] + solved[knee])
    y := app.thigh * math.cos(solved[hip]) + app.shin * math.cos(solved[hip] + solved[knee])
    floor := app.hip_y - drop - app.ankle_y
    a, b, _ := animation.two_link(app.thigh, app.shin, {min(y, floor), z})
    solved[hip], solved[knee] = a, b
    if y >= floor - 1e-6 do solved[ankle] = -(a + b)
  }
  app.origin = {0, app.root_y - drop, 0}
  world.set_world_poses(&app.scene, solve(app, solved[:]))
}

hip_drop :: proc(app: ^App, level: f32) -> f32 {
  t, s := app.thigh, app.shin
  per_level := t + s - math.sqrt(t * t + s * s + 2 * t * s * math.cos(f32(-math.PI / 3)))
  return clamp(-min(level, 0) * per_level, 0, t + s - abs(t - s) - 0.02)
}

stand :: proc(app: ^App) {
  rest: Pose
  poses := solve(app, rest[:])
  leg := app.legs[.L]
  hip, knee, ankle := poses[leg.hip].position, poses[leg.knee].position, poses[leg.ankle].position
  app.thigh, app.shin = linalg.length(hip - knee), linalg.length(knee - ankle)
  app.hip_y, app.ankle_y = hip.y, ankle.y
  app.root_y = -(ankle.y - REACH + SOLE_Y - FOOT_H)
}

recolor :: proc(app: ^App) {
  for p in app.pieces {
    material := app.materials[(p.key ~ app.seed) % len(PALETTE)]
    render.attach(&app.renderer, render.SlotHandle(p.node.index), render.MeshAttachment{mesh = app.meshes[p.mesh], material = material, cast_shadow = true})
  }
}

panel :: proc(app: ^App) {
  ctx := debugui.begin(&app.debug)
  if debugui.window(&app.debug, "Settings", {724, 10, 290, 245}, {.RIGHT, .TOP}, {.NO_CLOSE}) {
    mu.layout_row(ctx, {90, -1}, 0)
    mu.checkbox(ctx, "Dance", &app.dancing)
    if .CHANGE in mu.checkbox(ctx, "Mirror", &app.choreo.mirror) do choreo_rewire(&app.choreo)
    mu.layout_row(ctx, {-1}, 0)
    if .SUBMIT in mu.button(ctx, "New colors") {
      app.seed = rand.uint32()
      recolor(app)
    }
    mu.layout_row(ctx, {110, -1}, 0)
    mu.label(ctx, "tempo")
    mu.slider(ctx, &app.tempo, 20, 160, 1, "%.0f bpm")
    mu.label(ctx, "antic")
    mu.slider(ctx, &app.choreo.weights[.ANTIC], 0.05, 1, 0, "%.2f")
    mu.label(ctx, "move")
    mu.slider(ctx, &app.choreo.weights[.MOVE], 0.05, 1, 0, "%.2f")
    mu.label(ctx, "bounce")
    mu.slider(ctx, &app.choreo.weights[.BOUNCE], 0, 0.5, 0, "%.2f")
    mu.label(ctx, "rest")
    mu.slider(ctx, &app.choreo.weights[.REST], 0, 1, 0, "%.2f")
    mu.label(ctx, "bounce power")
    mu.slider(ctx, &app.choreo.power, 0, 0.5, 0, "%.2f")
  }
  if debugui.window(&app.debug, "Rig", {724, 280, 290, 430}, {.RIGHT, .TOP}, {.NO_CLOSE}) {
    for c in Channel {
      ctl := CONTROLS[c]
      if ctl.max <= ctl.min do continue
      if is_limb(c) do mu.layout_row(ctx, {110, 75, -1}, 0)
      else do mu.layout_row(ctx, {110, -1}, 0)
      mu.label(ctx, ctl.name)
      scale: f32 = 1 if ctl.ratio else DEG
      for side in Side {
        if side == .R && !is_limb(c) do continue
        key := chan(c, side)
        value := app.pose[key] / scale
        mu.push_id(ctx, uintptr(key))
        changed := .CHANGE in mu.slider(ctx, &value, ctl.min / scale, ctl.max / scale, 0 if ctl.ratio else 1, "%.2f" if ctl.ratio else "%.0f")
        mu.pop_id(ctx)
        if !changed do continue
        app.pose[key] = value * scale
        if is_limb(c) && app.choreo.mirror do app.pose[chan(c, .R if side == .L else .L)] = app.pose[key]
      }
    }
  }
}

turn :: proc(angle: f32, axis: [3]f32) -> quaternion128 {
  return linalg.quaternion_angle_axis_f32(angle, axis)
}

at :: proc(f: Frame, position: [3]f32, rotation := linalg.QUATERNIONF32_IDENTITY) -> Frame {
  return {f.bone, f.position + linalg.quaternion128_mul_vector3(f.rotation, position), f.rotation * rotation}
}

part :: proc(app: ^App, name: string) {
  app.part, app.count = name, 0
}

piece :: proc(app: ^App, f: Frame, mesh: Mesh, scale: [3]f32, position: [3]f32 = {}, rotation := linalg.QUATERNIONF32_IDENTITY, next := true) {
  node := world.spawn(&app.scene, parent = app.bones[f.bone].node)
  placed := at(f, position, rotation)
  world.set_local(&app.scene, node, placed.position, placed.rotation, scale)
  key := fmt.tprintf("%s %d", app.part, app.count)
  append(&app.pieces, Piece{node, mesh, hash.fnv32a(transmute([]u8)key)})
  if next do app.count += 1
  material := app.materials[(app.pieces[len(app.pieces) - 1].key ~ app.seed) % len(PALETTE)]
  render.attach(&app.renderer, render.SlotHandle(node.index), render.MeshAttachment{mesh = app.meshes[mesh], material = material, cast_shadow = true})
}

box :: proc(app: ^App, f: Frame, size, position: [3]f32, rotation := linalg.QUATERNIONF32_IDENTITY, mesh := Mesh.BOX) {
  piece(app, f, mesh, size / 2, position, rotation)
}

cylinder :: proc(app: ^App, f: Frame, radius, height: f32, position: [3]f32 = {}, rotation := linalg.QUATERNIONF32_IDENTITY, mesh := Mesh.CYLINDER, next := true) {
  center := position + linalg.quaternion128_mul_vector3(rotation, [3]f32{0, height / 2, 0})
  piece(app, f, mesh, {radius, height, radius}, center, rotation, next)
}

bone :: proc(app: ^App, parent: int, offset: [3]f32 = {}, rest := linalg.QUATERNIONF32_IDENTITY, axis := Axis.X, bind := Bind{}) -> int {
  append(&app.bones, Bone{parent, offset, rest, axis, bind.channel, bind.sign, world.spawn(&app.scene)})
  return len(app.bones) - 1
}

solve :: proc(app: ^App, channels: []f32) -> []BonePose {
  resize(&app.poses, len(app.bones))
  for b, i in app.bones {
    position, rotation := app.origin, linalg.QUATERNIONF32_IDENTITY
    if b.parent >= 0 do position, rotation = app.poses[b.parent].position, app.poses[b.parent].rotation
    position += linalg.quaternion128_mul_vector3(rotation, b.offset)
    axis: [3]f32
    axis[b.axis] = 1
    rotation *= b.rest * linalg.quaternion_angle_axis_f32(b.sign * channels[b.channel], axis)
    app.poses[i] = {b.node, position, linalg.normalize(rotation)}
  }
  return app.poses[:]
}

mounts :: proc(j: Joint) -> (a, b: geometry.Face) {
  switch j.kind {
  case .BALL:
    return {{0, -(j.ball_r * 0.55 + j.flange_t), 0}, NEG_Y, Z}, {{0, j.ball_r + j.stud_len + j.flange_t, 0}, Y, Z}
  case .PIN:
    return {{}, Y, X}, {{}, NEG_Y, X}
  case .HINGE, .HINGE_TWIST, .DISC_HINGE, .WRIST:
  }
  return {{0, REACH, 0}, Y, X}, {{0, -REACH, 0}, NEG_Y, X}
}

joint :: proc(app: ^App, parent: Frame, slot: geometry.Face, j: Joint, binds: [3]Bind, child: geometry.Face) -> (Frame, int) {
  a, b := mounts(j)
  origin, rotation := geometry.seat(slot, a)
  frame := at(parent, origin, rotation)
  part(app, j.name)
  #partial switch j.kind {
  case .HINGE, .HINGE_TWIST, .WRIST:
    hinge_female(app, frame, j, j.disc_f)
  case .PIN:
    hinge_pin(app, frame, j)
  case .BALL:
    ball_female(app, frame, j)
  }
  dofs: [3]struct {
    axis:     Axis,
    offset:   [3]f32,
    rest:     quaternion128,
  }
  for &d in dofs do d.rest = linalg.QUATERNIONF32_IDENTITY
  count := 1
  switch j.kind {
  case .HINGE, .PIN:
  case .HINGE_TWIST:
    dofs[1].axis, count = .Y, 2
  case .DISC_HINGE:
    dofs[0].axis, dofs[2].axis, count = .Y, .Y, 3
    dofs[1].rest = turn(math.PI / 2, X)
  case .WRIST:
    dofs[1].offset, dofs[1].rest = {0, WRIST_DROP, 0}, turn(-math.PI / 2, Y)
    dofs[2].axis, count = .Y, 3
  case .BALL:
    dofs[1].axis, dofs[2].axis, count = .Y, .Z, 3
  }
  bones: [3]int
  for d, i in dofs[:count] {
    if i == 0 do bones[i] = bone(app, frame.bone, at(frame, d.offset).position, frame.rotation * d.rest, d.axis, binds[i])
    else do bones[i] = bone(app, bones[i - 1], d.offset, d.rest, d.axis, binds[i])
  }
  ride :: proc(bone: int) -> Frame {
    return {bone, {}, linalg.QUATERNIONF32_IDENTITY}
  }
  #partial switch j.kind {
  case .HINGE, .HINGE_TWIST:
    hinge_male(app, ride(bones[0]), j, true, j.disc_m, j.tang)
  case .DISC_HINGE:
    hinge_female(app, ride(bones[0]), j, true)
    hinge_male(app, ride(bones[1]), j, true, true, true)
  case .WRIST:
    hinge_male(app, ride(bones[0]), j, false, false, true)
    hinge_female(app, at(ride(bones[0]), {0, WRIST_DROP, 0}, turn(-math.PI / 2, Y)), j, true)
    hinge_male(app, ride(bones[1]), j, true, true, true)
  case .BALL:
    ball_male(app, ride(bones[2]), j)
  }
  position, seated := geometry.seat(b, child)
  return {bones[count - 1], position, seated}, bones[0]
}

jaw_width :: proc(j: Joint) -> f32 {
  return j.jaw + 2 * j.lug_t + 2 * j.clr
}

lug :: proc(app: ^App, f: Frame, j: Joint, thickness, x, up: f32) {
  piece(app, f, .CYLINDER, {j.lug_d / 2, thickness - 0.002, j.lug_d / 2}, {x, 0, 0}, turn(-math.PI / 2, Z), false)
  box(app, f, {thickness, SHANK, j.lug_d}, {x, up * SHANK / 2, 0})
}

fork :: proc(app: ^App, f: Frame, j: Joint, jaw, up: f32, tang: bool) {
  if tang {
    lug(app, f, j, jaw + 2 * j.lug_t, 0, up)
    return
  }
  x := jaw / 2 + j.lug_t / 2
  lug(app, f, j, j.lug_t, -x, up)
  lug(app, f, j, j.lug_t, x, up)
}

hinge_base :: proc(app: ^App, f: Frame, j: Joint, up: f32, disc: bool) {
  width := (jaw_width(j) if up > 0 else j.jaw) + 2 * j.lug_t
  y := up * (SHANK + FLANGE_T / 2)
  if disc do cylinder(app, f, math.hypot(width, j.lug_d) / 2, FLANGE_T, {0, y - FLANGE_T / 2, 0})
  else do box(app, f, {width, FLANGE_T, j.lug_d}, {0, y, 0})
}

hinge_pin :: proc(app: ^App, f: Frame, j: Joint) {
  half := jaw_width(j) / 2 + j.lug_t + max(0.005, j.pin_out)
  piece(app, f, .CYLINDER, {j.pin_r, 2 * half, j.pin_r}, {}, turn(-math.PI / 2, Z))
}

hinge_female :: proc(app: ^App, f: Frame, j: Joint, disc: bool) {
  fork(app, f, j, jaw_width(j), 1, false)
  hinge_base(app, f, j, 1, disc)
  hinge_pin(app, f, j)
}

hinge_male :: proc(app: ^App, f: Frame, j: Joint, base, disc, tang: bool) {
  fork(app, f, j, j.jaw, -1, tang)
  if base do hinge_base(app, f, j, -1, disc)
}

ball_female :: proc(app: ^App, f: Frame, j: Joint) {
  drop := j.ball_r * 0.55
  cylinder(app, f, j.flange_w / 2, j.flange_t, {0, -drop - j.flange_t, 0})
  cylinder(app, f, j.ball_r + 0.02 + j.socket_t, drop, {0, -drop, 0})
}

ball_male :: proc(app: ^App, f: Frame, j: Joint) {
  top := j.ball_r + j.stud_len
  piece(app, f, .SPHERE, {j.ball_r, j.ball_r, j.ball_r})
  cylinder(app, f, STUD_R, top)
  cylinder(app, f, j.flange_w * 0.375, j.flange_t, {0, top, 0})
}

build :: proc(app: ^App) {
  pelvis := Frame{bone(app, -1), {}, linalg.QUATERNIONF32_IDENTITY}
  part(app, "pelvis")
  cylinder(app, pelvis, HIP_W / 2, DISC_T, {0, -DISC_T, 0})
  cylinder(app, pelvis, HIP_H, DOME_W, {-DOME_W / 2, -DISC_T, 0}, turn(math.PI / 2, Y) * turn(math.PI / 2, X), .HALF_CYLINDER)

  torso, _ := joint(app, pelvis, {{}, Y, Z}, WAIST, {{chan(.WAIST_BEND), 1}, {chan(.TWIST), 1}, {chan(.WAIST_TILT), 1}}, {{}, NEG_Y, Z})
  part(app, "torso")
  cw: f32 = CHEST_W - 2 * FLANK_R
  box(app, torso, {CHEST_W * 0.55, TAPER_H + 0.06, CHEST_D * 0.75}, {0, TAPER_H / 2, 0})
  box(app, torso, {cw, CHEST_H, 2 * FLANK_R}, {0, CHEST_Y + CHEST_H / 2, 0})
  for s in ([2]f32{1, -1}) do cylinder(app, torso, FLANK_R, CHEST_H - 0.002, {s * cw / 2, CHEST_Y + 0.001, 0}, turn(s * math.PI / 2, Y), .HALF_CYLINDER)
  box(app, torso, {cw * 0.85, CHEST_H * 0.72, 0.06}, {0, CHEST_Y + CHEST_H * 0.56, FLANK_R + 0.01})
  cylinder(app, torso, 0.17, 0.1, {0, CHEST_TOP, 0})
  disc_r := math.hypot(jaw_width(SHOULDER) + 2 * SHOULDER.lug_t, SHOULDER.lug_d) / 2
  for s in ([2]f32{1, -1}) do cylinder(app, torso, disc_r + 0.07, CONE_LEN, {s * (CHEST_W / 2 - CONE_LEN), SHOULDER_Y, 0}, turn(-s * math.PI / 2, Z), .SHOULDER_CONE)

  head, _ := joint(app, torso, {{0, NECK_Y, 0}, Y, Z}, NECK, {{chan(.HEAD_PITCH), 1}, {chan(.HEAD_YAW), 1}, {}}, {{}, NEG_Y, Z})
  part(app, "head")
  cy: f32 = HEAD_R + 0.04
  cylinder(app, head, 0.14, 0.05)
  cylinder(app, head, HEAD_R, HEAD_D, {0, cy, -HEAD_D / 2}, turn(math.PI / 2, X))
  cylinder(app, head, HEAD_R + 0.03, 0.06, {0, cy, HEAD_D / 2}, turn(math.PI / 2, X))
  cylinder(app, head, INNER_R, 0.05, {0, cy, HEAD_D / 2 + 0.06}, turn(math.PI / 2, X))
  for s in ([2]f32{1, -1}) do cylinder(app, head, 0.09, 0.06, {s * (HEAD_R + 0.06), cy, 0}, turn(s * math.PI / 2, Z))

  for side in Side do limbs(app, pelvis, torso, side)
}

limbs :: proc(app: ^App, pelvis, torso: Frame, side: Side) {
  sgn: f32 = 1 if side == .L else -1
  bind :: proc(c: Channel, side: Side, sign: f32) -> Bind {
    return {chan(c, side), sign}
  }
  flip :: proc(f: [3]f32, side: Side) -> [3]f32 {
    return f if side == .L else -f
  }

  arm, _ := joint(app, torso, {{-sgn * CHEST_W / 2, SHOULDER_Y, 0}, -sgn * X, sgn * Z}, SHOULDER, {bind(.SHOULDER, side, -sgn), bind(.ARM_OUT, side, -1), bind(.ARM_TWIST, side, sgn)}, {{}, Y, Z})
  part(app, "upper arm")
  cylinder(app, arm, ARM_W / 2, ARM_LEN + 0.08, {0, -ARM_LEN - 0.02, 0})
  cylinder(app, arm, ARM_W * 0.4, ARM_W + 0.14, {-(ARM_W + 0.14) / 2, -ARM_LEN, 0}, turn(-math.PI / 2, Z))

  fore, _ := joint(app, arm, {{0, -ARM_LEN, 0}, NEG_Y, X}, ELBOW, {bind(.ELBOW, side, -sgn), bind(.FORE_TWIST, side, sgn), {}}, {{}, Y, X})
  part(app, "forearm")
  box(app, fore, {FORE_W, FORE_LEN + 0.02, FORE_W * 0.9}, {0, -(FORE_LEN + 0.02) / 2, 0})

  palm, _ := joint(app, fore, {{0, -FORE_LEN - 0.02, 0}, NEG_Y, X}, WRIST, {bind(.WRIST_BEND, side, -sgn), bind(.WRIST_TILT, side, 1), bind(.WRIST_TWIST, side, sgn)}, {{}, Y, flip(Z, side)})
  part(app, "palm")
  box(app, palm, {PALM_W, PALM_H, PALM_D}, {0, -PALM_H / 2 + 0.02, 0})

  knuckle_y: f32 = -PALM_H + 0.08
  knuckle_z: f32 = PALM_D / 2 + DIGIT_W / 2
  fingers := [3]geometry.Face{{{0, knuckle_y, -knuckle_z}, NEG_Y, NEG_X}, {{-PALM_W * 0.27, knuckle_y, knuckle_z}, NEG_Y, X}, {{PALM_W * 0.27, knuckle_y, knuckle_z}, NEG_Y, X}}
  for slot in fingers {
    parent, at_slot := palm, slot
    for i in 0 ..< 3 {
      w := DIGIT_W * (1 - f32(i) * 0.12)
      digit, _ := joint(app, parent, at_slot, KNUCKLE, {bind(Channel(int(Channel.CURL_BASE) + i), side, 1), {}, {}}, {{}, Y, X})
      part(app, fmt.tprintf("digit %d", i))
      box(app, digit, {w, DIGIT_LEN + 0.05, w}, {0, -(DIGIT_LEN + 0.05) / 2 + 0.02, 0})
      parent, at_slot = digit, {{0, -DIGIT_LEN, 0}, NEG_Y, X}
    }
  }

  leg := &app.legs[side]
  thigh: Frame
  thigh, leg.hip = joint(app, pelvis, {{-sgn * DOME_W / 2, HIP_Y, 0}, -sgn * X, sgn * Z}, HIP, {bind(.HIP, side, -sgn), {}, {}}, {{}, Y, Z})
  part(app, "thigh")
  box(app, thigh, {THIGH_W, THIGH_LEN + 0.1, THIGH_W + 0.04}, {0, -(THIGH_LEN + 0.1) / 2 + 0.07, 0})
  cylinder(app, thigh, THIGH_W * 0.38, THIGH_W + 0.16, {-(THIGH_W + 0.16) / 2, -THIGH_LEN, 0}, turn(-math.PI / 2, Z))

  shin: Frame
  shin, leg.knee = joint(app, thigh, {{0, -THIGH_LEN, 0}, NEG_Y, X}, KNEE, {bind(.KNEE, side, -sgn), {}, {}}, {{}, Y, X})
  part(app, "shin")
  cylinder(app, shin, SHIN_W / 2, SHIN_LEN + 0.06, {0, -SHIN_LEN - 0.02, 0})

  foot: Frame
  foot, leg.ankle = joint(app, shin, {{0, -SHIN_LEN, 0}, NEG_Y, X}, ANKLE, {bind(.ANKLE, side, -sgn), {}, {}}, {{}, Y, flip(X, side)})
  part(app, "foot")
  z0: f32 = ANKLE_D / 2
  run: f32 = FOOT_LEN - z0 - TOE_D
  mid: f32 = SOLE_Y - FOOT_H / 2
  toe_h: f32 = FOOT_H * 0.45
  box(app, foot, {FOOT_W, FOOT_H, ANKLE_D}, {0, mid, 0})
  box(app, foot, {FOOT_W, FOOT_H, run}, {0, mid, z0 + run / 2}, mesh = .FOOT_SLOPE)
  box(app, foot, {FOOT_W * 0.92, toe_h, TOE_D}, {0, SOLE_Y - FOOT_H + toe_h / 2, z0 + run + TOE_D / 2})
  box(app, foot, {FOOT_W, FOOT_H, HEEL_D}, {0, mid, -z0 - HEEL_D / 2})
  box(app, foot, {FOOT_W, FOOT_H, HEEL_CAP_D}, {0, mid, -z0 - HEEL_D - HEEL_CAP_D / 2}, turn(math.PI, Y), .HEEL_SLOPE)
}

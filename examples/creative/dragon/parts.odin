package main

import "core:math"
import "core:math/linalg"
import "mjolnir/geometry"

HPI :: math.PI / 2
X :: [3]f32{1, 0, 0}
Y :: [3]f32{0, 1, 0}
Z :: [3]f32{0, 0, 1}
NEG_X :: [3]f32{-1, 0, 0}
NEG_Y :: [3]f32{0, -1, 0}
NEG_Z :: [3]f32{0, 0, -1}
SIDES := [2]f32{1, -1}

UnitKind :: enum u8 {
  BOX,
  CYLINDER,
  HALF_CYLINDER,
  QUARTER_CYLINDER,
  CONE,
  SPHERE,
}

Unit :: struct {
  kind:  UnitKind,
  param: f32,
}

Part :: struct {
  unit:  Unit,
  place: geometry.Transform,
}

Shape :: struct {
  parts: [2]Part,
  count: int,
}

shape :: proc(unit: Unit, scale: [3]f32, position: [3]f32 = {}) -> Shape {
  return {parts = {0 = {unit, {position, linalg.QUATERNIONF32_IDENTITY, scale}}}, count = 1}
}

box :: proc(w, h, d: f32, slope: f32 = 0) -> Shape {
  return shape({.BOX, slope}, {w, h, d} / 2)
}

cylinder :: proc(r, h: f32) -> Shape {
  return shape({.CYLINDER, 0}, {r, h, r}, {0, h / 2, 0})
}

half_cylinder :: proc(r, h: f32) -> Shape {
  return shape({.HALF_CYLINDER, 0}, {r, h, r}, {0, h / 2, 0})
}

quarter_cylinder :: proc(r, h: f32) -> Shape {
  return shape({.QUARTER_CYLINDER, 0}, {r, h, r}, {0, h / 2, 0})
}

cone_cut :: proc(r0, r1, h: f32) -> Shape {
  return shape({.CONE, r1 / r0}, {r0, h, r0}, {0, h / 2, 0})
}

cone :: proc(r, h: f32) -> Shape {
  return cone_cut(r, 0, h)
}

sphere :: proc(r: f32) -> Shape {
  return shape({.SPHERE, 0}, {r, r, r})
}

half_cylinder_box :: proc(r, h, depth: f32) -> Shape {
  s := half_cylinder(r, h)
  s.parts[1] = box(2 * r, h, depth).parts[0]
  s.parts[1].place.position = {0, h / 2, -depth / 2}
  s.count = 2
  return s
}

around :: proc(angle: f32, axis: [3]f32) -> quaternion128 {
  return linalg.quaternion_angle_axis_f32(angle, axis)
}

spin :: proc(s: Shape, q: quaternion128) -> Shape {
  s := s
  for &p in s.parts[:s.count] do p.place = geometry.transform_mul({rotation = q, scale = 1}, p.place)
  return s
}

rot_x :: proc(s: Shape, angle: f32) -> Shape {
  return spin(s, around(angle, X))
}

rot_y :: proc(s: Shape, angle: f32) -> Shape {
  return spin(s, around(angle, Y))
}

rot_z :: proc(s: Shape, angle: f32) -> Shape {
  return spin(s, around(angle, Z))
}

move :: proc(s: Shape, x, y, z: f32) -> Shape {
  s := s
  for &p in s.parts[:s.count] do p.place.position += {x, y, z}
  return s
}

JointKind :: enum u8 {
  BALL,
  HINGE,
  DISC_HINGE,
}

Joint :: struct {
  kind:                         JointKind,
  jaw, lug_t, lug_l, lug_d:     f32,
  pin_r:                        f32,
  ball_r, socket_t, stud_len:   f32,
  flange_w, flange_t:           f32,
}

CLR :: 0.03
PIN_OUT :: 0.05
STUD_R :: 0.11
SOCKET_CUT :: 0.75

SPINE :: Joint{kind = .BALL, ball_r = 0.26, socket_t = 0.09, stud_len = 0.14, flange_t = 0.12, flange_w = 0.8}
SPINE2 :: Joint{kind = .BALL, ball_r = 0.24, socket_t = 0.08, stud_len = 0.13, flange_t = 0.12, flange_w = 0.7}
JAW :: Joint{kind = .HINGE, jaw = 0.4, lug_t = 0.1, lug_l = 0.36, lug_d = 0.32, pin_r = 0.09, flange_t = 0.16}
SHOULDER :: Joint{kind = .DISC_HINGE, jaw = 0.1, lug_t = 0.055, lug_l = 0.34, lug_d = 0.22, pin_r = 0.045, flange_t = 0.16}
HIP :: Joint{kind = .DISC_HINGE, jaw = 0.12, lug_t = 0.065, lug_l = 0.38, lug_d = 0.26, pin_r = 0.055, flange_t = 0.16}
ELBOW :: Joint{kind = .HINGE, jaw = 0.14, lug_t = 0.07, lug_l = 0.3, lug_d = 0.28, pin_r = 0.06, flange_t = 0.16}
KNEE :: Joint{kind = .HINGE, jaw = 0.16, lug_t = 0.075, lug_l = 0.32, lug_d = 0.3, pin_r = 0.07, flange_t = 0.16}

Clevis :: struct {
  shank, jaw_w, knuckle_r, reach, pin_half: f32,
}

clevis :: proc(j: Joint) -> Clevis {
  shank := max(0.05, j.lug_l - min(0.2, j.lug_l * 0.4))
  jaw_w := j.jaw + 2 * j.lug_t + 2 * CLR
  return {shank, jaw_w, j.lug_d / 2, shank + j.flange_t, jaw_w / 2 + j.lug_t + PIN_OUT}
}

mounts :: proc(j: Joint) -> (a, b: geometry.Face) {
  if j.kind == .BALL {
    drop, top := j.ball_r * 0.55, j.ball_r + j.stud_len
    return {{0, -(drop + j.flange_t), 0}, NEG_Y, Z}, {{0, top + j.flange_t, 0}, Y, Z}
  }
  r := clevis(j).reach
  return {{0, r, 0}, Y, X}, {{0, -r, 0}, NEG_Y, X}
}

lug :: proc(app: ^App, c: Clevis, thickness, x: f32, up: bool) {
  g := rot_y(rot_x(half_cylinder_box(c.knuckle_r, thickness, c.shank), -HPI), HPI)
  if up do g = rot_z(g, math.PI)
  add(app, move(g, x + (-thickness / 2 if up else thickness / 2), 0, 0))
}

fork :: proc(app: ^App, j: Joint, c: Clevis, jaw: f32, up, tang: bool) {
  if tang {
    lug(app, c, jaw + 2 * j.lug_t, 0, up)
    return
  }
  x := jaw / 2 + j.lug_t / 2
  lug(app, c, j.lug_t, -x, up)
  lug(app, c, j.lug_t, x, up)
}

hinge_base :: proc(app: ^App, j: Joint, c: Clevis, female, disc: bool) {
  width := (c.jaw_w if female else j.jaw) + 2 * j.lug_t
  y := (1 if female else -1) * (c.shank + j.flange_t / 2)
  if disc do add(app, move(cylinder(math.hypot(width, j.lug_d) / 2, j.flange_t), 0, y - j.flange_t / 2, 0))
  else do add(app, move(box(width, j.flange_t, j.lug_d), 0, y, 0))
}

hinge_female :: proc(app: ^App, j: Joint, disc: bool) {
  c := clevis(j)
  fork(app, j, c, c.jaw_w, true, false)
  hinge_base(app, j, c, true, disc)
  add(app, move(rot_z(cylinder(j.pin_r, 2 * c.pin_half), -HPI), -c.pin_half, 0, 0))
}

hinge_male :: proc(app: ^App, j: Joint, disc, tang: bool) {
  c := clevis(j)
  fork(app, j, c, j.jaw, false, tang)
  hinge_base(app, j, c, false, disc)
}

ball_female :: proc(app: ^App, j: Joint) {
  drop := j.ball_r * 0.55
  outer := j.ball_r + 0.02 + j.socket_t
  add(app, move(cylinder(j.flange_w / 2, j.flange_t), 0, -drop - j.flange_t / 2, 0))
  add(app, move(cone_cut(outer, outer * math.sqrt(f32(1 - SOCKET_CUT * SOCKET_CUT)), outer * SOCKET_CUT), 0, -drop, 0))
}

ball_male :: proc(app: ^App, j: Joint) {
  top := j.ball_r + j.stud_len
  add(app, sphere(j.ball_r))
  add(app, cylinder(STUD_R, top))
  add(app, move(cylinder(j.flange_w * 0.375, j.flange_t), 0, top + j.flange_t / 2, 0))
}

PartKind :: enum u8 {
  HEAD,
  JAW,
  BODY_SEGMENT,
  BODY_SEGMENT2,
  UPPER_ARM,
  FOREARM,
  THIGH,
  SHIN,
  TAIL,
}

Params :: struct {
  head_w, snout_len, eye_r, horn_len: f32,
  jaw_w, jaw_len:                     f32,
  body_r, seg_len, discs, fin_r:      f32,
  r_front, r_rear:                    f32,
  len, w, claw_r, foot_len:           f32,
  core_len, tip_len:                  f32,
}

PARAMS := [PartKind]Params {
  .HEAD          = {head_w = 1.2, snout_len = 1.1, eye_r = 0.17, horn_len = 0.9},
  .JAW           = {jaw_w = 0.66, jaw_len = 1.55},
  .BODY_SEGMENT  = {body_r = 0.5, seg_len = 1.35, discs = 3, fin_r = 0.38},
  .BODY_SEGMENT2 = {r_front = 0.42, r_rear = 0.34, seg_len = 1.15, fin_r = 0.3},
  .UPPER_ARM     = {len = 0.45, w = 0.38},
  .FOREARM       = {len = 0.4, claw_r = 0.3},
  .THIGH         = {len = 0.5, w = 0.46},
  .SHIN          = {len = 0.45, foot_len = 0.35, claw_r = 0.28},
  .TAIL          = {core_len = 1.3, body_r = 0.34, tip_len = 1.4},
}

TAPER_START :: Params{r_front = 0.5, r_rear = 0.42, seg_len = 1.15, fin_r = 0.34}

HEAD_NECK_Z :: -1.18
CLAW_CURL :: 0.45

build_part :: proc(app: ^App, kind: PartKind, p: Params) {
  switch kind {
  case .HEAD:
    head(app, p)
  case .JAW:
    jaw(app, p)
  case .BODY_SEGMENT:
    body_segment(app, p)
  case .BODY_SEGMENT2:
    body_segment2(app, p)
  case .UPPER_ARM:
    add(app, move(box(p.w, p.len, 0.42), 0, -p.len / 2, 0))
    add(app, move(box(p.w * 0.84, p.len * 0.6, 0.08, 0.5), 0, -p.len * 0.4, 0.24))
  case .FOREARM:
    forearm(app, p)
  case .THIGH:
    add(app, move(box(p.w, p.len, 0.54), 0, -p.len / 2, 0))
  case .SHIN:
    shin(app, p)
  case .TAIL:
    tail(app, p)
  }
}

head :: proc(app: ^App, p: Params) {
  W := p.head_w
  add(app, move(box(W, 0.7, 1.0), 0, 0.55, -0.4))
  add(app, move(box(W, 0.18, 0.4), 0, 0.81, 0.3))
  add(app, move(box(W, 0.18, 0.4), 0, 0.29, 0.3))
  add(app, move(box(W * 0.42, 0.34, 0.4), 0, 0.55, 0.3))
  for s in SIDES {
    R := p.eye_r
    xc := s * (W * 0.21 + R * 0.55)
    add(app, move(sphere(R), xc, 0.55, 0.3))
    add(app, move(rot_z(cylinder(R * 0.8, 0.08), s * -HPI), xc + s * R * 0.8, 0.55, 0.3))
    add(app, move(rot_z(cylinder(R * 0.45, 0.07), s * -HPI), xc + s * R * 1.02, 0.55, 0.3))
  }
  add(app, move(box(W, 0.26, 0.5, 0.62), 0, 1.03, 0.15))
  for s in SIDES do add(app, move(box(W * 0.3, 0.13, 0.3, 0.55), s * W * 0.32, 0.95, 0.48))
  add(app, move(box(W * 0.65, 0.5, p.snout_len, 0.44), 0, 0.62, 0.5 + p.snout_len / 2))
  add(app, move(box(0.12, 0.16, p.snout_len * 0.65, 0.5), 0, 0.86, 0.5 + p.snout_len * 0.38))
  add(app, move(box(W * 0.45, 0.24, 0.18, 0.5), 0, 0.49, 0.5 + p.snout_len + 0.09))
  for s in SIDES do add(app, move(rot_x(cylinder(0.06, 0.08), HPI), s * W * 0.12, 0.5, 0.5 + p.snout_len + 0.12))
  for s in SIDES {
    for h, i in ([2]f32{0.18, 0.12}) do add(app, move(box(0.08, h, 0.08), s * W * 0.22, 0.37 - h / 2, 0.5 + p.snout_len - 0.1 - f32(i) * 0.35))
  }
  for s in SIDES {
    add(app, move(box(0.12, 0.52, 0.78, 0.55), s * (W / 2 + 0.06), 0.5, -0.38))
    for y in ([2]f32{0.36, 0.5}) do add(app, move(box(0.05, 0.07, 0.44), s * (W / 2 + 0.13), y, -0.42))
  }
  for s in SIDES {
    x := s * W * 0.32
    ax := x + s * 0.21
    l1, l2 := p.horn_len * 0.6, p.horn_len * 0.45
    kz := -0.55 - l1
    add(app, move(box(0.3, 0.3, 0.36), x, 1.05, -0.64))
    add(app, move(box(0.2, 0.24, l1), ax, 1.05, -0.55 - l1 / 2))
    add(app, move(box(0.24, 0.36, 0.28), ax, 1.17, kz + 0.05))
    add(app, move(box(0.18, 0.2, l2), ax, 1.25, kz + 0.05 - l2 / 2))
    add(app, move(rot_y(box(0.18, 0.2, 0.5, 0.96), math.PI), ax, 1.25, kz - l2 - 0.13))
  }
  add(app, move(rot_y(rot_x(half_cylinder_box(0.32, 0.09, 0.35), -HPI), HPI), 0.045, 0.92, -0.5))
  add(app, move(rot_x(move(box(0.5, 0.16, 0.5), 0, -0.08, 0), -HPI), 0, 0.55, -0.9))
  add(app, move(rot_x(cylinder(0.25, 0.28), -HPI), 0, 0.55, -0.9))
}

jaw :: proc(app: ^App, p: Params) {
  w, l := p.jaw_w, p.jaw_len
  add(app, move(box(w, 0.22, l), 0, -0.24, l / 2 - 0.15))
  for x in ([3]f32{-w * 0.33, 0, w * 0.33}) do add(app, move(box(0.07, 0.14, 0.07), x, -0.06, l - 0.4))
  for s in SIDES do add(app, move(box(0.08, 0.2, l * 0.6, 0.5), s * (w / 2 + 0.04), -0.2, l * 0.4))
}

spine_fin :: proc(app: ^App, r, y, z: f32) {
  add(app, move(rot_z(quarter_cylinder(r, 0.12), HPI), 0.06, y - 0.05, z))
}

body_segment :: proc(app: ^App, p: Params) {
  R, l := p.body_r, p.seg_len
  add(app, move(rot_x(half_cylinder(R, l), -HPI), 0, R, l))
  n := max(1, math.round(p.discs))
  pitch := l / n
  for i in 0 ..< int(n) do add(app, move(rot_x(half_cylinder(R * 0.94, pitch - 0.07), HPI), 0, R, f32(i) * pitch + 0.035))
  for s in SIDES do add(app, move(box(0.1, R * 0.95, l * 0.86), s * (R + 0.05), R, l / 2))
  for f in ([2]f32{0.3, 0.7}) do spine_fin(app, p.fin_r, 2 * R, f * l)
}

body_segment2 :: proc(app: ^App, p: Params) {
  l, r0, r1 := p.seg_len, p.r_rear, p.r_front
  add(app, move(rot_x(cone_cut(r0, r1, l), HPI), 0, r1, 0))
  for f in ([2]f32{0.3, 0.7}) do spine_fin(app, p.fin_r, r1 + r0 + (r1 - r0) * f, f * l)
}

forearm :: proc(app: ^App, p: Params) {
  L := p.len
  add(app, move(box(0.3, L, 0.34), 0, -L / 2, 0))
  add(app, move(box(0.24, L * 0.65, 0.08, 0.5), 0, -L * 0.45, 0.19))
  wy := -(L + 0.05)
  add(app, move(rot_z(cylinder(0.12, 0.36), -HPI), -0.18, wy, 0))
  py := wy - 0.17
  add(app, move(box(0.34, 0.24, 0.3), 0, py, 0.02))
  jy, jz: f32 = py - 0.26, 0.06
  for fx in ([3]f32{-0.14, 0, 0.14}) {
    add(app, move(box(0.09, 0.16, 0.11), fx, py - 0.18, jz))
    add(app, move(rot_x(move(box(0.08, 0.14, 0.1), 0, -0.07, 0), -CLAW_CURL), fx, jy, jz))
    add(app, move(rot_x(move(rot_z(quarter_cylinder(p.claw_r, 0.08), -HPI), -0.04, -0.12, -0.05), -CLAW_CURL), fx, jy, jz))
  }
  add(app, move(rot_z(quarter_cylinder(p.claw_r * 0.7, 0.08), -HPI), 0.21, py - 0.08, -0.06))
}

shin :: proc(app: ^App, p: Params) {
  L := p.len
  add(app, move(box(0.34, L, 0.4), 0, -L / 2, 0))
  ay := -(L + 0.05)
  add(app, move(rot_z(cylinder(0.13, 0.4), -HPI), -0.2, ay, 0))
  add(app, move(box(0.46, 0.2, p.foot_len), 0, ay - 0.05, p.foot_len / 2 - 0.12))
  for x in ([3]f32{-0.18, -0.04, 0.1}) do add(app, move(rot_z(quarter_cylinder(p.claw_r, 0.08), HPI), x + 0.08, ay - 0.15, p.foot_len - 0.15))
}

tail :: proc(app: ^App, p: Params) {
  R, l := p.body_r, p.core_len
  n := max(3, math.round(l / 0.28))
  pitch := l / n
  for i in 0 ..< int(n) {
    f := (f32(i) + 0.5) / n
    add(app, move(rot_x(cylinder(R * (0.5 + 0.5 * f), pitch - 0.06), HPI), 0, R, f32(i) * pitch + 0.03))
  }
  add(app, move(rot_x(cone(R * 0.5, p.tip_len), -HPI), 0, R, 0.03))
}

Slot :: enum u8 {
  MOUNT,
  NECK,
  JAW,
  REAR,
  FLANK_L,
  FLANK_R,
  ELBOW,
  KNEE,
}

SlotDef :: struct {
  face:  geometry.Face,
  joint: Maybe(Joint),
  axis:  bool,
}

slots :: proc(kind: PartKind, p: Params) -> (s: [Slot]Maybe(SlotDef)) {
  switch kind {
  case .HEAD:
    s[.NECK] = SlotDef{{{0, 0.55, HEAD_NECK_Z}, NEG_Z, Y}, SPINE, false}
    s[.JAW] = SlotDef{{{0, 0.02, -0.12}, NEG_Y, X}, JAW, true}
  case .JAW:
    s[.MOUNT] = SlotDef{{{}, Y, X}, nil, true}
  case .BODY_SEGMENT:
    cy, x := p.body_r, p.body_r + 0.1
    s[.MOUNT] = SlotDef{{{0, cy, p.seg_len}, Z, Y}, nil, false}
    s[.REAR] = SlotDef{{{0, cy, 0}, NEG_Z, Y}, SPINE, false}
    s[.FLANK_L] = SlotDef{{{-x, cy, p.seg_len / 2}, NEG_X, Z}, nil, false}
    s[.FLANK_R] = SlotDef{{{x, cy, p.seg_len / 2}, X, NEG_Z}, nil, false}
  case .BODY_SEGMENT2:
    s[.MOUNT] = SlotDef{{{0, p.r_front, p.seg_len}, Z, Y}, nil, false}
    s[.REAR] = SlotDef{{{0, p.r_front, 0}, NEG_Z, Y}, SPINE2, false}
  case .TAIL:
    s[.MOUNT] = SlotDef{{{0, p.body_r, p.core_len}, Z, Y}, nil, false}
  case .UPPER_ARM:
    s[.MOUNT] = SlotDef{{{}, Y, Z}, nil, false}
    s[.ELBOW] = SlotDef{{{0, -p.len, 0}, NEG_Y, X}, ELBOW, false}
  case .THIGH:
    s[.MOUNT] = SlotDef{{{}, Y, Z}, nil, false}
    s[.KNEE] = SlotDef{{{0, -p.len, 0}, NEG_Y, X}, KNEE, false}
  case .FOREARM, .SHIN:
    s[.MOUNT] = SlotDef{{{}, Y, X}, nil, false}
  }
  return
}

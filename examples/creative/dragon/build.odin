package main

import "core:math"
import "core:math/ease"
import "core:math/linalg"
import "mjolnir/input"
import "mjolnir/world"

BUILD_SECONDS :: 6
G_SPAN :: 0.7
P_SPAN :: 0.08
P_JIT :: 0.03
FLY :: 0.15
SNAP :: 0.1
TRAVEL :: 0.4
APPROACH :: 0.72
ALIGN :: 0.8
CAPTURE :: 0.18
STEPS :: 96
SPEED_RAMP :: 0.4
SCATTER :: [2]f32{12, 24}
STANDOFF :: [2]f32{0.5, 1}
PARK :: [2]f32{3.6, 8.4}
REVS :: [2]f32{0.75, 1.75}
DOCK :: [2]f32{2.4, 5.6}
SPEED :: [2]f32{1.6, 2.2}
TURN :: [2]f32{8, 12}
KICK :: [2]f32{0.35, 0.8}
SPAN :: G_SPAN + P_SPAN + P_JIT + FLY + SNAP + TRAVEL

Build :: struct {
  t:         f32,
  playing:   bool,
  scrubbing: bool,
  start:     f32,
  refs:      [dynamic]Snapshot,
  keys:      [dynamic]f32,
  used:      int,
}

Homing :: struct {
  speed, turn, dock, kick_az, kick_mix: f32,
}

Flight :: struct {
  active:   bool,
  seated:   bool,
  position: [3]f32,
  bank:     quaternion128,
  settle:   f32,
}

build_play :: proc(app: ^App) {
  app.build.start = app.pose.offset
  app.build.t = 0
  app.build.playing = true
}

build_scrub :: proc(app: ^App, before: f32) {
  app.build.playing = false
  if app.build.scrubbing do return
  app.build.scrubbing = true
  app.build.start = app.pose.offset - before * drift(app)
}

build_step :: proc(app: ^App, dt: f32) {
  if !input.mouse_down(&app.input, .LEFT) do app.build.scrubbing = false
  if !app.build.playing do return
  app.build.t = min(1, app.build.t + dt / BUILD_SECONDS)
  if app.build.t >= 1 do app.build.playing = false
}

build_destroy :: proc(b: ^Build) {
  for &s in b.refs do snapshot_destroy(&s)
  delete(b.refs)
  delete(b.keys)
}

drift :: proc(app: ^App) -> f32 {
  return f32(BUILD_SECONDS) / LAP_SECONDS if app.autoplay else 0
}

reference :: proc(app: ^App, u: f32) -> int {
  b := &app.build
  for k, i in b.keys[:b.used] do if k == u do return i
  if b.used == len(b.refs) {
    append(&b.refs, Snapshot{})
    append(&b.keys, 0)
  }
  b.keys[b.used] = u
  b.used += 1
  snapshot(app, b.start + u * drift(app), &b.refs[b.used - 1])
  return b.used - 1
}

hash01 :: proc(i, salt: int) -> f32 {
  h := u32(i) * 374761393 + u32(salt) * 668265263
  h = (h ~ (h >> 13)) * 1274126177
  return f32(f64(h ~ (h >> 16)) / 4294967296)
}

pick :: proc(r: [2]f32, i, salt: int) -> f32 {
  return r[0] + (r[1] - r[0]) * hash01(i, salt)
}

smooth :: proc(x: f32) -> f32 {
  return x * x * (3 - 2 * x)
}

rotate :: proc(q: quaternion128, v: [3]f32) -> [3]f32 {
  return linalg.quaternion128_mul_vector3(q, v)
}

lateral :: proc(n: [3]f32, az: f32) -> [3]f32 {
  ref := Y if abs(n.y) < 0.9 else X
  u := linalg.normalize(linalg.cross(ref, n))
  v := linalg.cross(n, u)
  return u * math.cos(az) + v * math.sin(az)
}

homing :: proc(g: int, far: f32) -> Homing {
  return {far * pick(SPEED, g, 40), pick(TURN, g, 41), pick(DOCK, g, 25), 2 * math.PI * hash01(g, 27), pick(KICK, g, 42)}
}

quantise :: proc(u: f32) -> f32 {
  return math.round(u * 64) / 64
}

simulate :: proc(app: ^App, g: int, from, n0: [3]f32, tau: f32, h: Homing, done: f32) -> (pos, dir: [3]f32) {
  pos = from
  dir = linalg.normalize(lateral(n0, h.kick_az) * h.kick_mix + n0 * (1 - h.kick_mix))
  k_end := clamp(tau / APPROACH, 0, 1) * STEPS
  for k := 0; f32(k) < k_end; k += 1 {
    step := min(1, k_end - f32(k)) / STEPS
    tk := f32(k) / STEPS
    ref := &app.build.refs[reference(app, quantise((done + tk * APPROACH * TRAVEL) / SPAN))]
    aim := ref.centers[g] + ref.normals[g] * h.dock
    to := aim - pos
    d := linalg.length(to)
    if d > 1e-6 {
      want := to / d
      angle := math.acos(clamp(linalg.dot(dir, want), -1, 1))
      if angle > 1e-6 {
        axis := linalg.cross(dir, want)
        l := linalg.length(axis)
        axis = axis / l if l > 1e-6 else lateral(dir, 0)
        dir = linalg.normalize(rotate(around(min(angle, h.turn * step), axis), dir))
      }
    }
    arrive := 0.35 + 0.65 * min(1, d / (2 * h.dock))
    pos += dir * h.speed * smooth(clamp(tk / SPEED_RAMP, 0, 1)) * arrive * step
  }
  return
}

assemble :: proc(app: ^App) {
  app.build.used = 0
  u := app.build.t * SPAN
  live := &app.live
  max_depth := 1
  for g in app.groups do max_depth = max(max_depth, app.links[g.link].depth)
  n := len(app.groups)
  starts := make([]f32, n, context.temp_allocator)
  refs := make([]int, n, context.temp_allocator)
  parks := make([]f32, n, context.temp_allocator)
  flights := make([]Flight, n, context.temp_allocator)
  for g, gi in app.groups {
    starts[gi] = f32(app.links[g.link].depth) / f32(max_depth) * G_SPAN
    refs[gi] = reference(app, starts[gi] / SPAN)
    parks[gi] = pick(PARK, gi, 22)
    done := starts[gi] + P_SPAN + P_JIT + FLY + SNAP
    ref := &app.build.refs[refs[gi]]
    p3 := (u - done) / TRAVEL
    f := &flights[gi]
    f.seated = p3 >= 1
    if p3 <= 0 || p3 >= 1 do continue
    f.active = true
    h := homing(gi, parks[gi])
    seat, normal := live.centers[gi], live.normals[gi]
    dir: [3]f32
    if p3 < APPROACH {
      from := ref.centers[gi] + ref.normals[gi] * parks[gi]
      n0 := ref.normals[gi]
      f.position, dir = simulate(app, gi, from, n0, p3, h, done)
      x := clamp((min(1, p3 / APPROACH) - (1 - CAPTURE)) / CAPTURE, 0, 1)
      if x > 0 {
        w := smooth(x)
        f.position = linalg.lerp(f.position, seat + normal * h.dock, w)
        blend := dir * (1 - w) - normal * w
        dir = linalg.normalize(blend) if linalg.length(blend) > 1e-6 else -normal
      }
    } else {
      x := clamp((p3 - APPROACH) / (1 - APPROACH), 0, 1)
      f.position = seat + normal * h.dock * (1 - ease.cubic_in_out(x))
      dir = -normal
    }
    f.settle = ease.cubic_in_out(min(1, p3 / (ALIGN * APPROACH)))
    f.bank = linalg.QUATERNIONF32_IDENTITY
    axis := linalg.cross(-normal, dir)
    if l := linalg.length(axis); l > 1e-4 do f.bank = around(math.atan2(l, -linalg.dot(normal, dir)) * f.settle, axis / l)
  }

  for p, i in app.pieces {
    gi := p.group
    f := flights[gi]
    target := live.pieces[i]
    if f.seated {
      show(app, p, target)
      continue
    }
    count := app.groups[gi].count
    order := f32(p.index) / f32(count - 1) if count > 1 else 0
    item := p.index + gi * 1024
    pt := u - starts[gi] - order * P_SPAN - hash01(item, 1) * P_JIT
    if pt <= 0 {
      world.set_visible(&app.scene, p.node, false)
      continue
    }
    ref := &app.build.refs[refs[gi]]
    base := ref.pieces[i]
    x := Xform{rotation = base.rotation}
    if f.active {
      parked := base.position - ref.centers[gi]
      offset := linalg.lerp(parked, target.position - live.centers[gi], f.settle)
      x.position = f.position + rotate(f.bank, offset)
    } else {
      x.position = base.position + ref.normals[gi] * parks[gi]
    }
    dist: f32
    if pt < FLY {
      fp := ease.cubic_in_out(pt / FLY)
      standoff := pick(STANDOFF, item, 5)
      dist = standoff + (pick(SCATTER, item, 4) - standoff) * (1 - fp)
      revs := (-1 if hash01(item, 6) < 0.5 else 1) * pick(REVS, item, 7)
      ay := 2 * hash01(item, 8) - 1
      ring := math.sqrt(max(0, 1 - ay * ay))
      aa := 2 * math.PI * hash01(item, 9)
      x.rotation = around(revs * 2 * math.PI * (1 - fp), {math.cos(aa) * ring, ay, math.sin(aa) * ring}) * x.rotation
    } else if pt < FLY + SNAP {
      dist = pick(STANDOFF, item, 5) * (1 - ease.back_out((pt - FLY) / SNAP))
    }
    if dist != 0 {
      az := 2 * math.PI * hash01(item, 2)
      dy := 0.25 + 0.7 * hash01(item, 3)
      s := math.sqrt(max(0, 1 - dy * dy))
      x.position += [3]f32{math.cos(az) * s, dy, math.sin(az) * s} * dist
    }
    if f.active {
      delta := target.rotation * linalg.quaternion_inverse(x.rotation)
      x.rotation = linalg.quaternion_slerp(linalg.QUATERNIONF32_IDENTITY, delta, f.settle) * x.rotation
      x.rotation = f.bank * x.rotation
    }
    show(app, p, x)
  }
}

show :: proc(app: ^App, p: Piece, x: Xform) {
  world.set_local(&app.scene, p.node, x.position, x.rotation, p.scale)
  world.set_visible(&app.scene, p.node, true)
}

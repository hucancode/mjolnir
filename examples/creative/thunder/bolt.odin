package main

import "core:math"
import "core:math/linalg"
import "core:math/noise"
import "core:math/rand"

SKY_Y :: f32(18)
MAX_BOLTS :: 256
MAX_LIGHTS :: 8
LIGHT_GAIN :: f32(30)
RAGE_EVERY :: f32(5)
RAGE_LENGTH :: f32(2)
RAGE_RESTRIKE_FACTOR :: f32(2)
RAGE_THIN_FACTOR :: f32(1.5)
RAGE_THICK_FACTOR :: f32(1.5)
HAMMER_TIP :: [3]f32{0, 2.24, 0}

JOINTS :: TRUNK_SEGMENTS + 1
SMOOTH_FREQUENCY :: f32(1.5)
SMOOTH_AMPLITUDE :: f32(0.5)
JAGGED_CELLS :: 12
JAGGED_AMPLITUDE :: f32(0.08)
SHARP_TURN :: f32(math.PI / 4)
WIDTH_NOISE :: f32(0.2)
WIDTH_NOISE_FREQUENCY :: 0.4

Pass :: struct {
  thickness:  f32,
  jaggedness: f32,
  deviation:  f32,
  opacity:    f32,
  shortest:   f32,
  longest:    f32,
}

PRIMARY :: Pass{1, 1, 0, 1, 1, 1}
SECONDARY :: Pass{0.3, 1, 0.08, 0.5, 0.3, 0.6}
TERTIARY :: Pass{0.1, 1, 0.06, 0.25, 0.3, 0.7}
SECONDARIES :: 1
TERTIARIES :: 2
RODS :: 1 + SECONDARIES + TERTIARIES

Rod :: struct {
  joints:    [JOINTS]Joint,
  thickness: f32,
  opacity:   f32,
}

Joint :: struct {
  position: [3]f32,
  width:    f32,
}

BoltInstance :: struct {
  base:   [3]f32,
  radius: f32,
  top:    [3]f32,
  opacity: f32,
  right:  [3]f32,
  age:    f32,
  leader: f32,
  trunk:  f32,
  thin:   f32,
  thick:  f32,
  halo:   f32,
  tones:  f32,
  _:      [2]f32,
  color:  [3]f32,
  _:      f32,
  joints: [JOINTS]Joint,
}

Stroke :: struct {
  t, amp: f32,
}

Bolt :: struct {
  born:      f32,
  base:      [3]f32,
  top:       [3]f32,
  right:     [3]f32,
  radius:    f32,
  color:     [3]f32,
  rods:      [RODS]Rod,
  strokes:   [dynamic]Stroke,
  leader:    f32,
  power:     f32,
  end:       f32,
  to_hammer: bool,
  struck:    bool,
  furious:   bool,
}

LightSample :: struct {
  position:  [3]f32,
  intensity: f32,
  color:     [3]f32,
}

Storm :: struct {
  bolts:       [dynamic]Bolt,
  eye:         [3]f32,
  time:        f32,
  flash:       f32,
  last_flash:  f32,
  hammer_glow: f32,
  tint:        [3]f32,
  next_auto:   f32,
  next_rage:   f32,
  rage_end:    f32,
}

rate: f32 = 0.8
rage: f32 = 0.4
jag: f32 = 0.3
restrikes: f32 = 4
thickness_min: f32 = 0.1
thickness_max: f32 = 5.0
tones: f32 = 3
halo: f32 = 0.4
color_a := [3]f32{0.5, 0.5, 1}
color_b := [3]f32{1, 1, 1}

gauss :: proc() -> f32 {
  return rand.float32() + rand.float32() + rand.float32() - 1.5
}

shape :: proc() -> (joints: [JOINTS]Joint) {
  seed := i64(rand.uint32())
  knots: [JAGGED_CELLS + 1][3]f32
  for &k in knots do k = {rand.float32() * 2 - 1, rand.float32() * 2 - 1, rand.float32() * 2 - 1}
  for &j, i in joints {
    y := f32(i) / TRUNK_SEGMENTS
    ends := math.smoothstep(f32(0), 0.12, min(y, 1 - y))
    cell := y * JAGGED_CELLS
    k := min(int(cell), JAGGED_CELLS - 1)
    jagged := linalg.lerp(knots[k], knots[k + 1], cell - f32(k))
    smooth_layers := [3]f32 {
      noise.noise_2d(seed, {f64(y * SMOOTH_FREQUENCY), 0.37}),
      0.3 * noise.noise_2d(seed + 1, {f64(y * SMOOTH_FREQUENCY), 0.37}),
      noise.noise_2d(seed + 2, {f64(y * SMOOTH_FREQUENCY), 0.37}),
    }
    jagged.y *= 0.3
    j.position = [3]f32{0, y, 0} + (smooth_layers * SMOOTH_AMPLITUDE + jagged * JAGGED_AMPLITUDE) * jag * ends
  }
  brush(&joints)
  return
}

branch :: proc(parent: [JOINTS]Joint, pass: Pass) -> (joints: [JOINTS]Joint) {
  from := rand.float32() * 0.5
  to := min(from + pass.shortest + rand.float32() * (pass.longest - pass.shortest), 1)
  cells := int(JAGGED_CELLS * pass.jaggedness)
  knots := make([][3]f32, cells + 1, context.temp_allocator)
  for &k in knots do k = {rand.float32() * 2 - 1, (rand.float32() * 2 - 1) * 0.3, rand.float32() * 2 - 1}
  for &j, i in joints {
    y := f32(i) / TRUNK_SEGMENTS
    ends := math.smoothstep(f32(0), 0.2, min(y, 1 - y))
    at := linalg.lerp(from, to, y) * TRUNK_SEGMENTS
    k := min(int(at), TRUNK_SEGMENTS - 1)
    cell := y * f32(cells)
    c := min(int(cell), cells - 1)
    j.position = linalg.lerp(parent[k].position, parent[k + 1].position, at - f32(k)) + linalg.lerp(knots[c], knots[c + 1], cell - f32(c)) * pass.deviation * jag * ends
  }
  brush(&joints)
  return
}

brush :: proc(joints: ^[JOINTS]Joint) {
  seed := i64(rand.uint32())
  for &j in joints do j.width = 1
  start := JOINTS - 1
  from := rand.float32()
  for i := JOINTS - 2; i >= 0; i -= 1 {
    into := linalg.normalize0((joints[i].position - joints[i + 1].position).xy)
    out_of := linalg.normalize0((joints[max(i - 1, 0)].position - joints[i].position).xy)
    turn := math.acos(clamp(linalg.dot(into, out_of), -1, 1))
    if i > 0 && turn <= SHARP_TURN do continue
    to := rand.float32()
    for k := start; k >= i; k -= 1 {
      t := f32(start - k) / f32(start - i)
      width := linalg.lerp(from, to, math.smoothstep(f32(0), 1, t))
      width += noise.noise_2d(seed + 3, {f64(k) * WIDTH_NOISE_FREQUENCY, 5.1}) * WIDTH_NOISE
      joints[k].width = clamp(width, 0, 1)
    }
    start = i
    from = to
  }
}

raging :: proc(s: ^Storm) -> bool {
  return s.time < s.rage_end
}

strike :: proc(s: ^Storm, to: [3]f32, power: f32, to_hammer: bool, furious := false) {
  end := HAMMER_TIP if to_hammer else to
  start := [3]f32{end.x + gauss() * 6, SKY_Y - rand.float32() * 1.5, end.z + gauss() * 6}
  axis := linalg.normalize0(start - end)
  right := linalg.normalize0(linalg.cross(axis, linalg.normalize0(s.eye - end)))
  if right == {} do right = {1, 0, 0}
  bolt := Bolt {
    born      = s.time,
    base      = end,
    top       = start,
    right     = right,
    radius    = 0.035 * (0.7 + power * 0.3),
    color     = linalg.lerp(color_a, color_b, rand.float32()),
    leader    = 0.12 + rand.float32() * 0.1,
    power     = power,
    to_hammer = to_hammer,
    furious   = furious,
  }
  bolt.rods[0] = Rod{shape(), PRIMARY.thickness, PRIMARY.opacity}
  for i in 1 ..< rod_count(&bolt) {
    pass := SECONDARY if i <= SECONDARIES else TERTIARY
    bolt.rods[i] = Rod{branch(bolt.rods[0].joints, pass), pass.thickness, pass.opacity}
  }
  append(&bolt.strokes, Stroke{bolt.leader, 1})
  count := min(int(restrikes * (RAGE_RESTRIKE_FACTOR if furious else 1)), 120)
  for i in 0 ..< count {
    append(&bolt.strokes, Stroke{bolt.strokes[i].t + 0.05 + rand.float32() * 0.09, max(0.75 - f32(i) * 0.12, 0.06)})
  }
  bolt.end = bolt.strokes[len(bolt.strokes) - 1].t + 1.2
  append(&s.bolts, bolt)
}

rod_count :: proc(b: ^Bolt) -> int {
  return 1 if b.furious else RODS
}

bolt_destroy :: proc(b: ^Bolt) {
  delete(b.strokes)
}

storm_destroy :: proc(s: ^Storm) {
  for &b in s.bolts do bolt_destroy(&b)
  delete(s.bolts)
}

envelope :: proc(b: ^Bolt, age, tau: f32) -> (e: f32) {
  for s in b.strokes do if age >= s.t do e += s.amp * math.exp(-(age - s.t) / tau)
  if age >= b.leader do e += 0.12 * math.exp(-(age - b.leader) / 0.4)
  return
}

instance :: proc(b: ^Bolt, rod: int, age: f32) -> BoltInstance {
  inst := BoltInstance {
    base   = b.base,
    top    = b.top,
    right  = b.right,
    radius = b.radius * b.rods[rod].thickness,
    joints = b.rods[rod].joints,
    color  = b.color,
    opacity = b.rods[rod].opacity,
    thin   = min(thickness_min, thickness_max) * (RAGE_THIN_FACTOR if b.furious else 1),
    thick  = max(thickness_min, thickness_max) * (RAGE_THICK_FACTOR if b.furious else 1),
    tones  = tones,
    halo   = halo,
    age    = age,
    leader = b.leader,
  }
  if age >= b.leader {
    inst.trunk = envelope(b, age, 0.045) * 1.6 * b.power
  }
  return inst
}

advance :: proc(s: ^Storm, dt: f32, eye: [3]f32) -> (lights: [MAX_LIGHTS]LightSample) {
  s.time += dt
  s.eye = eye
  if s.time >= s.next_rage {
    s.next_rage = s.time + RAGE_EVERY
    if rand.float32() < rage {
      s.rage_end = s.time + RAGE_LENGTH
      a := rand.float32() * math.TAU
      strike(s, {math.sin(a) * 2, 0, math.cos(a) * 2}, 1.4, true, true)
    }
  }
  hot := raging(s)
  if !hot && rate > 0 && s.time >= s.next_auto {
    a := rand.float32() * math.TAU
    d := 4 + rand.float32() * 40
    to_hammer := rand.float32() < 0.25
    strike(s, {math.sin(a) * d, 0, math.cos(a) * d}, 0.7 + rand.float32() * 0.7, to_hammer)
    s.next_auto = s.time + (0.4 + rand.float32() * 1.6) / max(rate, 0.05)
  }

  n := 0
  light :: proc(lights: ^[MAX_LIGHTS]LightSample, n: ^int, position: [3]f32, i: f32, color: [3]f32) {
    if n^ < MAX_LIGHTS && i > 0.01 {
      lights[n^] = {position, i * LIGHT_GAIN, color}
      n^ += 1
    }
  }
  for i := len(s.bolts) - 1; i >= 0; i -= 1 {
    b := &s.bolts[i]
    age := s.time - b.born
    if age > b.end {
      bolt_destroy(b)
      unordered_remove(&s.bolts, i)
      continue
    }
    if age < b.leader {
      light(&lights, &n, linalg.lerp(b.top, b.base, age / b.leader), 0.2, b.color)
      continue
    }
    if !b.struck {
      b.struck = true
      s.tint = b.color
      if s.time - s.last_flash > 0.45 {
        s.flash = max(s.flash, b.power * clamp(1.4 - linalg.length(b.base - eye) / 60, 0.3, 1))
        s.last_flash = s.time
      }
      if b.to_hammer do s.hammer_glow = 1
    }
    e := envelope(b, age, 0.06) * b.power
    light(&lights, &n, b.base, e * 1.2, b.color)
    light(&lights, &n, linalg.lerp(b.base, b.top, 0.5), e * 0.8, b.color)
    light(&lights, &n, b.top, e * 0.8, b.color)
  }
  s.hammer_glow *= math.exp(-dt / 1.5)
  if s.hammer_glow > 0.02 do light(&lights, &n, HAMMER_TIP - {0, 1, 0}, s.hammer_glow * 0.4, s.tint)
  s.flash *= math.exp(-dt / 0.25)
  return
}

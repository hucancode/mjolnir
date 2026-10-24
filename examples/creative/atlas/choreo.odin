package main

import "core:math"
import "core:math/ease"

PERIOD :: 1.5
ANTIC_RATIO :: 0.18
REST_RATIO :: 0.1
BOUNCE_TIME :: 0.2
BOUNCE_POWER :: 0.1
STYLE_BEATS :: 10
PULSE_CHANCE :: 0.25
SPLIT_CHANCE :: 0.1
MERGE_CHANCE :: 0.3
NEAR_END :: 0.05
HOME_CHANCE :: 0.05
MONTAGE_CHANCE :: 0.1
SETUP_RATIO :: 0.8
GRID :: math.PI / 4
NEAR_CHANCE :: 0.35
MIN_TRAVEL :: 0.15
MAIN_AT :: REST_RATIO * PERIOD
MAIN_DUR :: PERIOD - MAIN_AT

Step :: enum {
  ANTIC,
  MOVE,
  BOUNCE,
  REST,
}

STYLES := [?][]Step{{.ANTIC, .MOVE, .BOUNCE, .REST}, {.ANTIC, .ANTIC, .MOVE, .BOUNCE}, {.ANTIC, .ANTIC, .ANTIC, .REST}}

STEP_SHARE := [Step]f32 {
  .ANTIC  = ANTIC_RATIO,
  .MOVE   = (1 - REST_RATIO - ANTIC_RATIO) * (1 - BOUNCE_TIME),
  .BOUNCE = (1 - REST_RATIO - ANTIC_RATIO) * BOUNCE_TIME,
  .REST   = REST_RATIO,
}

Track :: struct {
  key:          int,
  from, to:     f32,
  t0, dur:      f32,
  ease:         ease.Ease,
  hit:          bool,
}

Slider :: struct {
  key:      int,
  min, max: f32,
  big:      bool,
  grid:     f32,
}

Partial :: struct {
  value: Pose,
  set:   bit_set[0 ..< CHANNEL_COUNT],
}

Key :: struct {
  hold: f32,
  pose: Partial,
}

Montage :: struct {
  setup: Partial,
  keys:  [5]Key,
  loops: int,
}

Choreo :: struct {
  rng:        u32,
  mirror:     bool,
  sliders:    [dynamic]Slider,
  montages:   [dynamic]Montage,
  tracks:     [dynamic]Track,
  clock:      f32,
  span:       f32,
  style:      int,
  style_left: int,
  played:     [CHANNEL_COUNT][2]f32,
  plays:      [CHANNEL_COUNT]int,
  busy:       bit_set[0 ..< CHANNEL_COUNT],
  was, cur:   Pose,
  stirred:    bit_set[0 ..< CHANNEL_COUNT],
}

choreo_init :: proc(self: ^Choreo, seed: u32, mirror: bool) {
  self.rng = seed
  self.mirror = mirror
  choreo_rewire(self)
}

choreo_destroy :: proc(self: ^Choreo) {
  delete(self.sliders)
  delete(self.montages)
  delete(self.tracks)
}

choreo_rewire :: proc(self: ^Choreo) {
  clear(&self.sliders)
  clear(&self.montages)
  clear(&self.tracks)
  self.clock, self.span, self.style, self.style_left = 0, 0, -1, 0
  self.plays = {}
  self.busy = {}
  for c in Channel {
    ctl := CONTROLS[c]
    if ctl.max <= ctl.min do continue
    if self.mirror && is_leg(c) do continue
    for side in Side {
      if side == .R && (!is_limb(c) || self.mirror) do continue
      append(&self.sliders, Slider{chan(c, side), ctl.min, ctl.max, ctl.big, 0 if ctl.ratio else GRID})
    }
  }
  append(&self.montages, montage(.SIDE_OUT, .SIDE_OUT), montage(.FRONT, .FRONT))
  if !self.mirror do append(&self.montages, montage(.FRONT, .BACK))
}

choreo_step :: proc(self: ^Choreo, dt: f32, pose: ^Pose) {
  self.clock += dt
  if self.clock >= self.span {
    write(self, pose, self.span)
    self.clock -= self.span
    self.span = plan(self, pose)
  }
  write(self, pose, self.clock)
}

@(private = "file")
random :: proc(self: ^Choreo) -> f32 {
  self.rng += 0x6d2b79f5
  t := self.rng
  t = (t ~ (t >> 15)) * (t | 1)
  t ~= t + (t ~ (t >> 7)) * (t | 61)
  return f32(t ~ (t >> 14)) / 4294967296.0
}

@(private = "file")
pick :: proc(self: ^Choreo, n: int) -> int {
  return min(int(random(self) * f32(n)), n - 1)
}

@(private = "file")
curve :: proc(t: Track, u: f32) -> f32 {
  if !t.hit do return ease.ease(t.ease, u)
  if u < 1 - BOUNCE_TIME do return (1 + BOUNCE_POWER) * u / (1 - BOUNCE_TIME)
  return math.lerp(f32(1 + BOUNCE_POWER), 1, ease.bounce_out((u - (1 - BOUNCE_TIME)) / BOUNCE_TIME))
}

@(private = "file")
write :: proc(self: ^Choreo, pose: ^Pose, at: f32) {
  for t in self.tracks {
    u := (at - t.t0) / t.dur if t.dur > 0 else 1
    if u <= 0 do continue
    pose[t.key] = t.to if u >= 1 else math.lerp(t.from, t.to, curve(t, u))
  }
}

@(private = "file")
rest :: proc(key: int) -> f32 {
  return HOME[key]
}

@(private = "file")
rivals :: proc(key: int) -> []int {
  @(static) waist := [3]int{int(Channel.TWIST), int(Channel.WAIST_BEND), int(Channel.WAIST_TILT)}
  for w in waist do if w == key do return waist[:]
  return nil
}

@(private = "file")
twin :: proc(self: ^Choreo, key: int) -> int {
  c, side := channel_of(key)
  return chan(c, .R) if self.mirror && is_limb(c) && side == .L else -1
}

@(private = "file")
allowed :: proc(self: ^Choreo, key: int) -> bool {
  c, side := channel_of(key)
  if !is_leg(c) do return true
  other := Side.R if side == .L else Side.L
  for leg in ([3]Channel{.HIP, .KNEE, .ANKLE}) {
    k := chan(leg, other)
    if self.was[k] != rest(k) || k in self.stirred do return false
  }
  return true
}

@(private = "file")
push :: proc(self: ^Choreo, key: int, to, t0, dur: f32, e: ease.Ease, hit: bool) {
  laid := false
  for &t in self.tracks {
    if t.key != key || t.t0 != t0 do continue
    t.to, t.dur, t.ease, t.hit = to, dur, e, hit
    laid = true
  }
  if !laid do append(&self.tracks, Track{key, self.cur[key], to, t0, dur, e, hit})
  if to != rest(key) do self.stirred += {key}
  self.cur[key] = to
}

@(private = "file")
cut :: proc(self: ^Choreo, key: int, to, t0, dur: f32, e: ease.Ease, hit := false) {
  push(self, key, to, t0, dur, e, hit)
  if t := twin(self, key); t >= 0 do push(self, t, to, t0, dur, e, hit)
  if to == rest(key) do return
  for r in rivals(key) do if r != key && self.cur[r] != rest(r) do push(self, r, rest(r), t0, dur, e, hit)
}

@(private = "file")
target :: proc(self: ^Choreo, s: Slider) -> f32 {
  from, lo, hi := self.cur[s.key], s.min, s.max
  mid := (lo + hi) / 2
  flo, fhi := lo, mid
  if from < mid do flo, fhi = mid, hi
  if random(self) >= NEAR_CHANCE do lo, hi = flo, fhi
  reach := MIN_TRAVEL * (s.max - s.min)
  grid, fresh: [32]f32
  grids, freshes := 0, 0
  if s.grid > 0 {
    for g := math.ceil(lo / s.grid) * s.grid; g <= hi + 1e-6 && grids < len(grid); g += s.grid {
      if abs(g - from) < reach do continue
      grid[grids] = g
      grids += 1
      stale := false
      for p in self.played[s.key][:min(self.plays[s.key], 2)] do stale ||= abs(p - g) < 1e-5
      if !stale {
        fresh[freshes] = g
        freshes += 1
      }
    }
  }
  if freshes > 0 do return fresh[pick(self, freshes)]
  if grids > 0 do return grid[pick(self, grids)]
  below, above := max(from - reach - s.min, 0), max(s.max - from - reach, 0)
  if below + above <= 0 do return math.lerp(flo, fhi, random(self))
  at := random(self) * (below + above)
  return s.min + at if at < below else from + reach + at - below
}

@(private = "file")
aim :: proc(self: ^Choreo, s: Slider) -> f32 {
  to := target(self, s)
  n := self.plays[s.key]
  if n < 2 do self.played[s.key][n] = to
  else do self.played[s.key] = {self.played[s.key][1], to}
  self.plays[s.key] = min(n + 1, 2)
  return to
}

@(private = "file")
draw :: proc(self: ^Choreo, pool: []Slider, n: int) -> []Slider {
  @(static) buffer: [CHANNEL_COUNT]Slider
  rested := 0
  for s in pool do if s.key not_in self.busy {
    buffer[rested] = s
    rested += 1
  }
  count := rested
  if rested < n {
    copy(buffer[:], pool)
    count = len(pool)
  }
  for i in 0 ..< min(n, count) {
    j := i + pick(self, count - i)
    buffer[i], buffer[j] = buffer[j], buffer[i]
  }
  return buffer[:min(n, count)]
}

@(private = "file")
plan :: proc(self: ^Choreo, pose: ^Pose) -> f32 {
  self.was, self.cur = pose^, pose^
  self.stirred = {}
  clear(&self.tracks)
  if self.mirror {
    for side in Side do for leg in ([3]Channel{.HIP, .KNEE, .ANKLE}) {
      k := chan(leg, side)
      if self.cur[k] != rest(k) do cut(self, k, rest(k), MAIN_AT, MAIN_DUR, .Sine_In_Out)
    }
  }
  roll := random(self)
  if roll < HOME_CHANCE {
    for s in self.sliders do cut(self, s.key, rest(s.key), MAIN_AT, MAIN_DUR, .Linear, true)
    return PERIOD
  }
  if roll < HOME_CHANCE + MONTAGE_CHANCE do return play(self, self.montages[pick(self, len(self.montages))])
  if roll < HOME_CHANCE + MONTAGE_CHANCE + (SPLIT_CHANCE if self.mirror else MERGE_CHANCE) {
    self.mirror = !self.mirror
    choreo_rewire(self)
    return plan(self, pose)
  }
  return improvise(self)
}

@(private = "file")
play :: proc(self: ^Choreo, m: Montage) -> f32 {
  held: f32
  for k in m.keys do held += k.hold
  held *= f32(m.loops)
  beats := max(1, math.round(SETUP_RATIO + held))
  fit := (beats - SETUP_RATIO) / held
  at: f32 = SETUP_RATIO * PERIOD
  for key in m.setup.set do cut(self, key, m.setup.value[key], 0, at, .Linear, true)
  t := at
  for _ in 0 ..< m.loops {
    for k in m.keys {
      dur := k.hold * fit * PERIOD
      for key in k.pose.set do cut(self, key, k.pose.value[key], t, dur, .Sine_In_Out)
      t += dur
    }
  }
  return beats * PERIOD
}

@(private = "file")
improvise :: proc(self: ^Choreo) -> f32 {
  if self.style_left <= 0 {
    next := pick(self, len(STYLES) - 1)
    if self.style >= 0 && next >= self.style do next += 1
    self.style, self.style_left = next, STYLE_BEATS
  }
  self.style_left -= 1
  style := STYLES[self.style]
  moved: bit_set[0 ..< CHANNEL_COUNT]
  small, big: [CHANNEL_COUNT]Slider
  smalls, bigs := 0, 0
  has_move := false
  for step in style do has_move ||= step == .MOVE
  for s in self.sliders {
    if s.key == int(Channel.HIP_LEVEL) {
      if random(self) < PULSE_CHANCE && allowed(self, s.key) {
        cut(self, s.key, aim(self, s), 0, PERIOD, .Sine_In_Out)
        moved += {s.key}
      }
      continue
    }
    if s.key == int(Channel.TWIST) && !has_move && allowed(self, s.key) {
      cut(self, s.key, aim(self, s), 0, PERIOD, .Linear)
      moved += {s.key}
    }
    if s.big {
      big[bigs] = s
      bigs += 1
    } else {
      small[smalls] = s
      smalls += 1
    }
  }
  steps: [4]Step
  copy(steps[:], style)
  if steps[len(style) - 1] == .REST {
    copy(steps[1:len(style)], style[:len(style) - 1])
    steps[0] = .REST
  }
  share: f32
  for step in steps[:len(style)] do share += STEP_SHARE[step]
  scale := PERIOD / share
  t: f32
  reel_key, reel_to := -1, f32(0)
  for step in steps[:len(style)] {
    dur := STEP_SHARE[step] * scale
    switch step {
    case .ANTIC:
      n := 1 + pick(self, min(3, smalls))
      for s in draw(self, small[:smalls], n) do if allowed(self, s.key) {
        cut(self, s.key, aim(self, s), t, dur, .Linear)
        moved += {s.key}
      }
    case .MOVE:
      open: [CHANNEL_COUNT]Slider
      opens := 0
      for s in big[:bigs] do if allowed(self, s.key) {
        open[opens] = s
        opens += 1
      }
      if opens > 0 {
        s := draw(self, open[:opens], 1)[0]
        to := aim(self, s)
        cut(self, s.key, to + BOUNCE_POWER * (to - self.cur[s.key]), t, dur, .Linear)
        reel_key, reel_to = s.key, to
        moved += {s.key}
      }
    case .BOUNCE:
      if reel_key >= 0 do cut(self, reel_key, reel_to, t, dur, .Bounce_Out)
      reel_key = -1
    case .REST:
    }
    t += dur
  }
  self.busy = moved
  return PERIOD
}

Wave :: enum {
  SIDE_OUT,
  FRONT,
  BACK,
}

@(private = "file")
montage :: proc(left, right: Wave) -> (m: Montage) {
  m.loops = 2
  for c in Channel do if c != .HIP_LEVEL && CONTROLS[c].max > CONTROLS[c].min {
    for side in Side do set(&m.setup, c, side, 0)
  }
  for wave, i in ([2]Wave{left, right}) {
    side := Side(i)
    level, n: f32 = math.PI / 2, 35 * DEG
    lead_channel := Channel.SHOULDER
    switch wave {
    case .SIDE_OUT:
      lead_channel = .ARM_OUT
      set(&m.setup, .ARM_OUT, side, level)
      set(&m.setup, .ARM_TWIST, side, -math.PI / 2)
    case .FRONT:
      set(&m.setup, .SHOULDER, side, level)
    case .BACK:
      level, n = -level, -n
      set(&m.setup, .SHOULDER, side, level)
    }
    holds := [5]f32{0.15, 0.12, 0.12, 0.12, 0.15}
    for h, k in holds do m.keys[k].hold = h
    set(&m.keys[0].pose, lead_channel, side, level + n)
    set(&m.keys[0].pose, .ELBOW, side, -2 * n)
    set(&m.keys[0].pose, .WRIST_BEND, side, n)
    set(&m.keys[1].pose, lead_channel, side, level)
    set(&m.keys[1].pose, .ELBOW, side, n)
    set(&m.keys[1].pose, .WRIST_BEND, side, -2 * n)
    set(&m.keys[2].pose, .ELBOW, side, 0)
    set(&m.keys[2].pose, .WRIST_BEND, side, n)
    set(&m.keys[3].pose, .WRIST_BEND, side, 0)
    set(&m.keys[3].pose, .CURL, side, abs(n) / (math.PI / 2))
    set(&m.keys[4].pose, .CURL, side, 0)
  }
  return
}

@(private = "file")
set :: proc(p: ^Partial, c: Channel, side: Side, v: f32) {
  k := chan(c, side)
  p.value[k] = v
  p.set += {k}
}

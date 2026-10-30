package main

import "core:math"
import "core:math/ease"
import "core:math/rand"

PERIOD :: 1.5
BOUNCE_POWER :: 0.2
STYLE_BEATS :: 10
PULSE_CHANCE :: 0.25
SPLIT_CHANCE :: 0.1
MERGE_CHANCE :: 0.3
GRID :: math.PI / 4
NEAR_CHANCE :: 0.35
MIN_TRAVEL :: 0.15
MAX_BEATS :: 4
BEAT_TRAVEL := [Tier]f32 {
  .CORE = 0.35,
  .LIMB = 0.7,
  .TIP  = 1,
}

Step :: enum {
  ANTIC,
  MOVE,
  BOUNCE,
  REST,
}

STYLES := [?][]Step{{.ANTIC, .MOVE, .BOUNCE, .REST}, {.ANTIC, .ANTIC, .MOVE, .BOUNCE}, {.ANTIC, .ANTIC, .ANTIC, .REST}}

STEP_WEIGHT := [Step]f32 {
  .ANTIC  = 0.2,
  .MOVE   = 0.5,
  .BOUNCE = 0.2,
  .REST   = 0.1,
}

Track :: struct {
  key:          int,
  from, to:     f32,
  t0, dur:      f32,
  ease:         ease.Ease,
  settle:       f32,
  power:        f32,
}

Slider :: struct {
  key:      int,
  min, max: f32,
  big:      bool,
  grid:     f32,
}

Choreo :: struct {
  rng:        rand.Default_Random_State,
  mirror:     bool,
  sliders:    [dynamic]Slider,
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
  locked:     bit_set[0 ..< CHANNEL_COUNT],
  weights:    [Step]f32,
  power:      f32,
}

choreo_init :: proc(self: ^Choreo, seed: u32, mirror: bool) {
  self.rng = rand.create(u64(seed))
  self.mirror = mirror
  self.weights = STEP_WEIGHT
  self.power = BOUNCE_POWER
  choreo_rewire(self)
}

choreo_destroy :: proc(self: ^Choreo) {
  delete(self.sliders)
  delete(self.tracks)
}

choreo_rewire :: proc(self: ^Choreo) {
  clear(&self.sliders)
  clear(&self.tracks)
  self.clock, self.span, self.style, self.style_left = 0, 0, -1, 0
  self.plays = {}
  self.busy = {}
  self.locked = {}
  for c in Channel {
    ctl := CONTROLS[c]
    if ctl.max <= ctl.min do continue
    if self.mirror && is_leg(c) do continue
    for side in Side {
      if side == .R && (!is_limb(c) || self.mirror) do continue
      append(&self.sliders, Slider{chan(c, side), ctl.min, ctl.max, ctl.big, 0 if ctl.ratio else GRID})
    }
  }
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
  return rand.float32(rand.default_random_generator(&self.rng))
}

@(private = "file")
pick :: proc(self: ^Choreo, n: int) -> int {
  return min(int(random(self) * f32(n)), n - 1)
}

@(private = "file")
pace :: proc(key: int) -> f32 {
  c, _ := channel_of(key)
  ctl := CONTROLS[c]
  return BEAT_TRAVEL[ctl.tier] * (ctl.max - ctl.min)
}

@(private = "file")
beats :: proc(key: int, from, to: f32) -> f32 {
  return clamp(math.ceil(abs(to - from) / pace(key)), 1, MAX_BEATS)
}

@(private = "file")
lock :: proc(self: ^Choreo, key: int) {
  self.locked += {key}
  if t := twin(self, key); t >= 0 do self.locked += {t}
  for r in rivals(key) do self.locked += {r}
}

@(private = "file")
curve :: proc(t: Track, u: f32) -> f32 {
  if t.settle <= 0 do return ease.ease(t.ease, u)
  bounce := t.settle / t.dur
  if u < 1 - bounce do return (1 + t.power) * u / (1 - bounce)
  return math.lerp(1 + t.power, 1, ease.bounce_out((u - (1 - bounce)) / bounce))
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
  if key in self.locked do return false
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
push :: proc(self: ^Choreo, key: int, to, t0, dur: f32, e: ease.Ease, settle: f32) {
  laid := false
  for &t in self.tracks {
    if t.key != key || t.t0 != t0 do continue
    t.to, t.dur, t.ease, t.settle, t.power = to, dur, e, settle, self.power
    laid = true
  }
  if !laid do append(&self.tracks, Track{key, self.cur[key], to, t0, dur, e, settle, self.power})
  if to != rest(key) do self.stirred += {key}
  self.cur[key] = to
}

@(private = "file")
cut :: proc(self: ^Choreo, key: int, to, t0, dur: f32, e: ease.Ease, settle: f32 = 0) {
  push(self, key, to, t0, dur, e, settle)
  if t := twin(self, key); t >= 0 do push(self, t, to, t0, dur, e, settle)
  if to == rest(key) do return
  for r in rivals(key) do if r != key && self.cur[r] != rest(r) do push(self, r, rest(r), t0, dur, e, settle)
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
  reach := MAX_BEATS * pace(s.key)
  to := clamp(target(self, s), self.cur[s.key] - reach, self.cur[s.key] + reach)
  n := self.plays[s.key]
  if n < 2 do self.played[s.key][n] = to
  else do self.played[s.key] = {self.played[s.key][1], to}
  self.plays[s.key] = min(n + 1, 2)
  return to
}

@(private = "file")
deal :: proc(self: ^Choreo, pool: []Slider, n: int) -> []Slider {
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
  self.stirred, self.locked = {}, {}
  carried := 0
  for t in self.tracks do if t.t0 + t.dur > self.span + 1e-4 {
    self.tracks[carried] = t
    self.tracks[carried].t0 -= self.span
    carried += 1
    self.cur[t.key] = t.to
    lock(self, t.key)
  }
  resize(&self.tracks, carried)
  if self.mirror {
    for side in Side do for leg in ([3]Channel{.HIP, .KNEE, .ANKLE}) {
      k := chan(leg, side)
      if k not_in self.locked && self.cur[k] != rest(k) do cut(self, k, rest(k), 0, PERIOD, .Sine_In_Out)
    }
  }
  if self.locked != {} do return improvise(self)
  if random(self) < (SPLIT_CHANCE if self.mirror else MERGE_CHANCE) {
    self.mirror = !self.mirror
    choreo_rewire(self)
    return plan(self, pose)
  }
  return improvise(self)
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
        from := self.cur[s.key]
        to := aim(self, s)
        cut(self, s.key, to, 0, beats(s.key, from, to) * PERIOD, .Sine_In_Out)
        moved += {s.key}
      }
      continue
    }
    if s.key == int(Channel.TWIST) && !has_move && allowed(self, s.key) {
      from := self.cur[s.key]
      to := aim(self, s)
      n := beats(s.key, from, to)
      cut(self, s.key, to, 0, n * PERIOD, .Linear if n == 1 else .Sine_In_Out)
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
  weight: f32
  for step in steps[:len(style)] do weight += self.weights[step]
  durs: [4]f32
  for step, i in steps[:len(style)] do durs[i] = self.weights[step] / weight * PERIOD
  t: f32
  for step, i in steps[:len(style)] {
    dur := durs[i]
    switch step {
    case .ANTIC:
      n := 1 + pick(self, min(3, smalls))
      for s in deal(self, small[:smalls], n) do if allowed(self, s.key) {
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
        s := deal(self, open[:opens], 1)[0]
        from := self.cur[s.key]
        to := aim(self, s)
        settle := durs[i + 1] if i + 1 < len(style) && steps[i + 1] == .BOUNCE else 0
        cut(self, s.key, to, t, (beats(s.key, from, to) - 1) * PERIOD + dur + settle, .Linear, settle)
        moved += {s.key}
      }
    case .BOUNCE, .REST:
    }
    t += dur
  }
  self.busy = moved
  return PERIOD
}

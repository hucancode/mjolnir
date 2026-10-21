package animation

import "core:math"
import "core:math/linalg"

// Chain is what trails a moving point (a snake's body, a ribbon, a tow rope, a dragon, a whisker):
// points newest first, one every `step`, behind `head`. Move the head one of three ways, then
// sample or read `points`: chain_move records the path it travelled, chain_follow drags the points
// after it like a rope, chain_swing lets them hang from it and swing with momentum.
Chain :: struct($T: typeid) {
  points:   []T, // newest first, points[0] is nearest the head
  previous: []T, // where each point was a step ago, for chain_swing
  head:     T, // where the point is now
  step:     f32, // distance between points
  lag:      f32, // travel since points[0] was recorded
}

// chain_init starts a chain at `head` with `length` of chain behind it, running toward
// head + direction (unit length), a point every `step`. Free with chain_destroy.
chain_init :: proc(self: ^Chain($T), head, direction: T, length, step: f32) {
  count := int(length / step) + 2
  self^ = {points = make([]T, count), previous = make([]T, count), head = head, step = step}
  for &p, i in self.points do p = head + direction * (f32(i) * step)
  copy(self.previous, self.points)
}

// chain_hang lays the points straight from `head` along `direction` (unit length), a `step` apart
// with the first one a step from the head, and stops them; the start for chain_follow and
// chain_swing.
chain_hang :: proc(self: ^Chain($T), head, direction: T) {
  self.head = head
  self.lag = 0
  for &p, i in self.points do p = head + direction * (f32(i + 1) * self.step)
  copy(self.previous, self.points)
}

// chain_destroy frees the chain's points.
chain_destroy :: proc(self: ^Chain($T)) {
  delete(self.points)
  delete(self.previous)
}

// chain_move carries the head to `to` in a straight line, recording a point at every `step` of
// travel on the way.
chain_move :: proc(self: ^Chain($T), to: T) {
  moved := linalg.distance(self.head, to)
  self.lag += moved
  for self.lag >= self.step {
    self.lag -= self.step
    copy(self.points[1:], self.points[:])
    self.points[0] = linalg.lerp(self.head, to, (moved - self.lag) / moved)
  }
  self.head = to
}

// chain_sample returns where the head was `back` of travel ago, blending between recorded points;
// past the end of the chain it stays at the oldest point.
chain_sample :: proc(self: Chain($T), back: f32) -> T {
  if back <= self.lag do return linalg.lerp(self.head, self.points[0], back / max(self.lag, 1e-6))
  at := (back - self.lag) / self.step
  i := min(int(at), len(self.points) - 2)
  return linalg.lerp(self.points[i], self.points[i + 1], min(at - f32(i), 1))
}

// chain_follow pins the head to `to` and drags the points after it like a rope: each point closes
// `propagation` (0..1) of its gap beyond `step` to the point before it, and no joint bends more
// than `max_bend` radians off straight. Low propagation trails lazily, 1 is nearly rigid. It does
// not use time, so call it at a steady rate; do not mix with chain_move.
chain_follow :: proc(self: ^Chain($T), to: T, propagation, max_bend: f32) {
  self.head = to
  chain_pull(self, propagation)
  chain_bend(self, propagation, max_bend)
  chain_pull(self, propagation)
}

@(private = "file")
chain_pull :: proc(self: ^Chain($T), propagation: f32) {
  leader := self.head
  for &p in self.points {
    gap := linalg.distance(leader, p)
    if gap > self.step do p += (leader - p) * ((gap - self.step) * propagation / gap)
    leader = p
  }
}

@(private = "file")
chain_bend :: proc(self: ^Chain($T), propagation, max_bend: f32) {
  leader := self.head
  for i in 0 ..< len(self.points) - 1 {
    joint := self.points[i]
    ahead := joint - leader
    if linalg.length(ahead) > 1e-6 {
      next := self.points[i + 1] - joint
      reach := linalg.length(next)
      if reach > 1e-6 {
        want := cone_clamp(linalg.normalize(ahead), next / reach, max_bend)
        self.points[i + 1] = joint + linalg.normalize(linalg.lerp(next / reach, want, propagation)) * reach
      }
    }
    leader = joint
  }
}

// cone_clamp turns unit `dir` toward unit `axis` until it is within `angle` radians of it.
@(private = "file")
cone_clamp :: proc(axis, dir: $T, angle: f32) -> T {
  c := linalg.dot(axis, dir)
  if c >= math.cos(angle) do return dir
  side := dir - axis * c
  s := linalg.length(side)
  if s < 1e-6 do return axis
  return axis * math.cos(angle) + side * (math.sin(angle) / s)
}

// chain_swing moves the head to `to` and lets the points hang from it and swing for one step, like
// a moustache, a feeler or a strand of hair: each keeps `damping` (0..1, 0.88 swings loosely) of
// its velocity (at most a `step` per call), stays `step` from its neighbours, and the first link stays within `root_bend`
// radians of the unit direction `root`, each next link within the angle off the one before it,
// growing to `tip_bend` at the end. Moving the head more than half the chain's length straightens
// it along `root` instead of stretching it. It does not use time, so call it at a steady rate; do
// not mix with chain_move or chain_follow.
chain_swing :: proc(self: ^Chain($T), to: T, root: T, damping, root_bend, tip_bend: f32, iterations := 6) {
  count := len(self.points)
  if linalg.distance(to, self.head) > self.step * f32(count) * 0.5 {
    chain_hang(self, to, root)
    return
  }
  for i in 0 ..< count {
    at := self.points[i]
    velocity := (at - self.previous[i]) * damping
    if speed := linalg.length(velocity); speed > self.step do velocity *= self.step / speed
    self.points[i] += velocity
    self.previous[i] = at
  }
  self.head = to
  for _ in 0 ..< iterations {
    for i in 0 ..< count {
      leader := &self.head if i == 0 else &self.points[i - 1]
      gap := linalg.distance(leader^, self.points[i])
      if gap < 1e-6 do continue
      off := (self.points[i] - leader^) * ((gap - self.step) / gap)
      if i == 0 {
        self.points[i] -= off
      } else {
        leader^ += off * 0.5
        self.points[i] -= off * 0.5
      }
    }
    for i in 0 ..< count {
      leader := self.head if i == 0 else self.points[i - 1]
      axis := root
      if i > 0 do axis = linalg.normalize0(leader - (self.head if i == 1 else self.points[i - 2]))
      bend := root_bend + (tip_bend - root_bend) * f32(i) / f32(max(count - 1, 1))
      reach := self.points[i] - leader
      length := linalg.length(reach)
      if length < 1e-6 do continue
      self.points[i] = leader + cone_clamp(axis, reach / length, bend) * self.step
    }
  }
}

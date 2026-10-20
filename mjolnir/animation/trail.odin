package animation

import "core:math/linalg"

// Trail remembers the path a moving point took, a point every `step` of travel, newest first,
// so what trails behind it (a snake's body, a ribbon, a tow rope) can be sampled by distance.
Trail :: struct($T: typeid) {
  points: []T, // recorded path, newest first
  head:   T, // where the point is now
  step:   f32,
  lag:    f32, // travel since points[0] was recorded
}

// trail_init starts a trail at `head` with `length` of path behind it, running toward
// head + direction (unit length), a point every `step`. Free with trail_destroy.
trail_init :: proc(self: ^Trail($T), head, direction: T, length, step: f32) {
  self^ = {points = make([]T, int(length / step) + 2), head = head, step = step}
  for &p, i in self.points do p = head + direction * (f32(i) * step)
}

// trail_destroy frees the trail's points.
trail_destroy :: proc(self: ^Trail($T)) {
  delete(self.points)
}

// trail_move carries the point to `to` in a straight line, recording a point at every `step` of
// travel on the way.
trail_move :: proc(self: ^Trail($T), to: T) {
  moved := linalg.distance(self.head, to)
  self.lag += moved
  for self.lag >= self.step {
    self.lag -= self.step
    copy(self.points[1:], self.points[:])
    self.points[0] = linalg.lerp(self.head, to, (moved - self.lag) / moved)
  }
  self.head = to
}

// trail_sample returns where the point was `back` of travel ago, blending between recorded points;
// past the end of the trail it stays at the oldest point.
trail_sample :: proc(self: Trail($T), back: f32) -> T {
  if back <= self.lag do return linalg.lerp(self.head, self.points[0], back / max(self.lag, 1e-6))
  at := (back - self.lag) / self.step
  i := min(int(at), len(self.points) - 2)
  return linalg.lerp(self.points[i], self.points[i + 1], min(at - f32(i), 1))
}

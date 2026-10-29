// Physics on its own: a box tower, a ball dropped on it then knocked off, and a stray ball rolling off the floor, drawn from the side with each body's height plotted. The command line simulates ten seconds headless and writes artifacts/modules/physics_only/heights.svg; the web page plays it live.
package main

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:strings"
import "mjolnir/geometry"
import "mjolnir/physics"

TICKS :: 600
DT :: 1.0 / 60

Track :: struct {
  body:    physics.BodyHandle,
  label:   string,
  color:   string,
  heights: [dynamic]f32,
}

w: physics.World
tracks: [dynamic]Track
ball: physics.BodyHandle
ticks, killed: int

setup :: proc() -> bool {
  physics.init(&w) or_return
  physics.body_create(&w, {0, -0.5, 0}, collider = physics.BoxCollider{{6, 0.5, 6}})
  labels := [?]string{"box 0", "box 1", "box 2", "box 3", "box 4"}
  colors := [?]string{"#4ea8de", "#56cfe1", "#72efdd", "#80ffdb", "#64dfdf"}
  for level in 0 ..< 5 {
    box, _ := physics.body_create(&w, {0, 0.5 + f32(level), 0}, collider = physics.BoxCollider{{0.5, 0.5, 0.5}}, mass = 1)
    append(&tracks, Track{body = box, label = labels[level], color = colors[level]})
  }
  ball, _ = physics.body_create(&w, {0.3, 9, 0.2}, collider = physics.SphereCollider{0.4}, mass = 4)
  append(&tracks, Track{body = ball, label = "ball", color = "#ffd166"})
  stray, _ := physics.body_create(&w, {5, 1, 0}, collider = physics.SphereCollider{0.3}, mass = 1)
  physics.set_velocity(&w, stray, {4, 0, 0})
  append(&tracks, Track{body = stray, label = "stray", color = "#e76f51"})
  return true
}

teardown :: proc() {
  for t in tracks do delete(t.heights)
  delete(tracks)
  physics.shutdown(&w)
}

tick :: proc() {
  if ticks == 240 do physics.apply_impulse(&w, ball, {-12, 0, 0})
  physics.step(&w, DT)
  killed += len(physics.killed(&w))
  for &t in tracks do if b, alive := physics.body(&w, t.body); alive do append(&t.heights, b.position.y)
  ticks += 1
}

summary :: proc() -> string {
  b := strings.builder_make(context.temp_allocator)
  for t in tracks {
    last := t.heights[len(t.heights) - 1] if len(t.heights) > 0 else 0
    fmt.sbprintfln(&b, "%-6s %3d ticks alive, last height %.2f", t.label, len(t.heights), last)
  }
  hit := physics.raycast(&w, geometry.Ray{{0, 20, 0}, {0, -1, 0}})
  fmt.sbprintfln(&b, "%d bodies killed below the floor", killed)
  fmt.sbprintfln(&b, "a ray down the tower's axis hits at height %.2f", hit.point.y)
  return strings.to_string(b)
}

svg :: proc() -> string {
  W, H, S :: 1000, 400, 30
  y :: proc(height: f32) -> f32 {return H - 40 - (height + 2) * S}
  b := strings.builder_make(context.temp_allocator)
  fmt.sbprintfln(&b, `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 %d %d" style="background:#14161f">`, W, H)
  fmt.sbprintfln(&b, `<rect x="%d" y="%f" width="%d" height="%d" fill="#3a3f4b"/>`, 200 - 6 * S, y(0), 12 * S, S)
  for t in tracks {
    body := physics.body(&w, t.body) or_continue
    cx, cy := 200 + body.position.x * S, y(body.position.y)
    switch c in body.collider {
    case physics.SphereCollider:
      fmt.sbprintfln(&b, `<circle cx="%.1f" cy="%.1f" r="%.1f" fill="%s"/>`, cx, cy, c.radius * S, t.color)
    case physics.BoxCollider:
      side := linalg.mul(body.rotation, [3]f32{1, 0, 0})
      angle := -math.to_degrees(math.atan2(side.y, side.x))
      fmt.sbprintfln(&b, `<rect x="%.1f" y="%.1f" width="%.1f" height="%.1f" fill="%s" transform="rotate(%.1f %.1f %.1f)"/>`, cx - c.half_extents.x * S, cy - c.half_extents.y * S, 2 * c.half_extents.x * S, 2 * c.half_extents.y * S, t.color, angle, cx, cy)
    case physics.CylinderCollider:
    }
  }
  fmt.sbprintfln(&b, `<line x1="420" x2="%d" y1="%f" y2="%f" stroke="#555"/>`, W, y(0), y(0))
  for t, i in tracks {
    fmt.sbprintf(&b, `<polyline fill="none" stroke="%s" stroke-width="2" points="`, t.color)
    for h, k in t.heights do fmt.sbprintf(&b, "%.1f,%.1f ", 420 + f32(k) * (W - 420) / TICKS, y(max(h, -2)))
    fmt.sbprintln(&b, `"/>`)
    fmt.sbprintfln(&b, `<text x="430" y="%d" fill="%s" font-size="12" font-family="sans-serif">%s</text>`, 16 + i * 14, t.color, t.label)
  }
  fmt.sbprintln(&b, "</svg>")
  return strings.to_string(b)
}

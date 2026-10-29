// World on its own: a solar system as a scene graph, each moon parented to its planet, its orbits traced from the change feed. The command line spins it for two years of ticks and writes artifacts/modules/world_only/orbits.svg; the web page spins it live.
package main

import "core:fmt"
import "core:strings"
import "mjolnir/world"

TICKS :: 720

Body :: struct {
  name:     string,
  parent:   string,
  distance: f32,
  period:   f32,
  color:    string,
}

BODIES := [?]Body {
  {"sun", "", 0, 0, "#ffd166"},
  {"mercury", "sun", 60, 88, "#b0a9a0"},
  {"venus", "sun", 100, 225, "#e9c46a"},
  {"earth", "sun", 150, 365, "#4ea8de"},
  {"moon", "earth", 22, 27, "#dddddd"},
  {"mars", "sun", 210, 687, "#e76f51"},
  {"phobos", "mars", 14, 8, "#a08070"},
  {"deimos", "mars", 24, 30, "#c0a090"},
}

w: world.World
pivots, nodes: [len(BODIES)]world.NodeHandle
trails: [len(BODIES)][dynamic][3]f32
ticks, removed: int

setup :: proc() -> bool {
  world.init(&w, 64) or_return
  for b, i in BODIES {
    parent := world.find(&w, b.parent) if b.parent != "" else {}
    pivots[i] = world.spawn(&w, parent = parent)
    nodes[i] = world.spawn(&w, {b.distance, 0, 0}, b.name, pivots[i])
  }
  return true
}

teardown :: proc() {
  for t in trails do delete(t)
  world.shutdown(&w)
}

tick :: proc() {
  for b, i in BODIES do if b.period > 0 do world.rotate_by(&w, pivots[i], 2 * 3.14159265 / b.period)
  if ticks == TICKS / 2 do world.destroy(&w, world.find(&w, "deimos"))
  world.update(&w)
  for c in world.changes(&w) {
    if c.removed {
      removed += 1
      continue
    }
    for n, i in nodes do if n.index == c.index {
      if len(trails[i]) == TICKS do ordered_remove(&trails[i], 0)
      append(&trails[i], c.world_matrix[3].xyz)
    }
  }
  ticks += 1
}

svg :: proc() -> string {
  b := strings.builder_make(context.temp_allocator)
  fmt.sbprintln(&b, `<svg xmlns="http://www.w3.org/2000/svg" viewBox="-260 -260 520 520" style="background:#0b0d17">`)
  for trail, i in trails {
    if len(trail) == 0 do continue
    fmt.sbprintf(&b, `<polyline fill="none" stroke="%s" stroke-width="1" points="`, BODIES[i].color)
    for p in trail do fmt.sbprintf(&b, "%.1f,%.1f ", p.x, p.z)
    fmt.sbprintln(&b, `"/>`)
    last := trail[len(trail) - 1]
    fmt.sbprintfln(&b, `<circle cx="%.1f" cy="%.1f" r="%d" fill="%s"/>`, last.x, last.z, 8 if i == 0 else 3, BODIES[i].color)
    fmt.sbprintfln(&b, `<text x="%.1f" y="%.1f" fill="%s" font-size="9" font-family="sans-serif">%s</text>`, last.x + 5, last.z - 5, BODIES[i].color, BODIES[i].name)
  }
  fmt.sbprintln(&b, "</svg>")
  return strings.to_string(b)
}

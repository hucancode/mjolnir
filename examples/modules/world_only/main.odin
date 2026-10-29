// World on its own: a solar system as a scene graph, spun for a year of ticks, its orbits traced from the change feed. Writes artifacts/modules/world_only/orbits.svg.
package main

import "core:fmt"
import "core:os"
import "core:strings"
import "mjolnir/world"

OUT :: "artifacts/modules/world_only/"
TICKS :: 720

Body :: struct {
  name:      string,
  parent:    string,
  distance:  f32,
  period:    f32,
  color:     string,
}

BODIES :: [?]Body {
  {"sun", "", 0, 0, "#ffd166"},
  {"mercury", "sun", 60, 88, "#b0a9a0"},
  {"venus", "sun", 100, 225, "#e9c46a"},
  {"earth", "sun", 150, 365, "#4ea8de"},
  {"moon", "earth", 22, 27, "#dddddd"},
  {"mars", "sun", 210, 687, "#e76f51"},
  {"phobos", "mars", 14, 8, "#a08070"},
  {"deimos", "mars", 24, 30, "#c0a090"},
}

main :: proc() {
  w: world.World
  if !world.init(&w, 64) do return
  defer world.shutdown(&w)
  bodies := BODIES
  pivots: [len(BODIES)]world.NodeHandle
  nodes: [len(BODIES)]world.NodeHandle
  for b, i in bodies {
    parent := world.find(&w, b.parent) if b.parent != "" else {}
    pivots[i] = world.spawn(&w, parent = parent)
    nodes[i] = world.spawn(&w, {b.distance, 0, 0}, b.name, pivots[i])
  }
  trails: [len(BODIES)][dynamic][3]f32
  defer for t in trails do delete(t)
  removed := 0
  for tick in 0 ..< TICKS {
    for b, i in bodies do if b.period > 0 do world.rotate_by(&w, pivots[i], 2 * 3.14159265 / b.period)
    if tick == TICKS / 2 do world.destroy(&w, world.find(&w, "deimos"))
    world.update(&w)
    for c in world.changes(&w) {
      if c.removed {
        removed += 1
        continue
      }
      for n, i in nodes do if n.index == c.index do append(&trails[i], c.world_matrix[3].xyz)
    }
  }
  write_svg(OUT + "orbits.svg", bodies[:], trails[:])
  fmt.printfln("%d ticks, %d node removed", TICKS, removed)
  for b, i in bodies do fmt.printfln("%-8s %d positions traced", b.name, len(trails[i]))
  for c in world.children(&w, w.root) do print_tree(&w, c, 0)
  fmt.printfln("wrote %sorbits.svg", OUT)
}

print_tree :: proc(w: ^world.World, h: world.NodeHandle, depth: int) {
  n := world.node(w, h)
  if n.name != "" do fmt.printfln("%*s%s at %v", depth * 2, "", n.name, world.world_matrix(w, h)[3].xyz)
  for c in world.children(w, h) do print_tree(w, c, depth + 1 if n.name != "" else depth)
}

write_svg :: proc(path: string, bodies: []Body, trails: [][dynamic][3]f32) {
  b := strings.builder_make(context.temp_allocator)
  fmt.sbprintln(&b, `<svg xmlns="http://www.w3.org/2000/svg" viewBox="-260 -260 520 520" style="background:#0b0d17">`)
  for trail, i in trails {
    if len(trail) == 0 do continue
    fmt.sbprintf(&b, `<polyline fill="none" stroke="%s" stroke-width="1" points="`, bodies[i].color)
    for p in trail do fmt.sbprintf(&b, "%.1f,%.1f ", p.x, p.z)
    fmt.sbprintln(&b, `"/>`)
    last := trail[len(trail) - 1]
    fmt.sbprintfln(&b, `<circle cx="%.1f" cy="%.1f" r="%d" fill="%s"/>`, last.x, last.z, 8 if i == 0 else 3, bodies[i].color)
    fmt.sbprintfln(&b, `<text x="%.1f" y="%.1f" fill="%s" font-size="9" font-family="sans-serif">%s</text>`, last.x + 5, last.z - 5, bodies[i].color, bodies[i].name)
  }
  fmt.sbprintln(&b, "</svg>")
  os.make_directory_all(OUT)
  _ = os.write_entire_file(path, strings.to_string(b))
}

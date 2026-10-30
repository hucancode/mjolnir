// Navigation on its own: bake a navmesh around walls, save and reload it, find a path through the maze and walk it. The command line writes artifacts/modules/navigation_only/{level.navmesh,navmesh.svg}; on the web page the walker heads wherever you click.
package main

import "core:fmt"
import "core:strings"
import nav "mjolnir/navigation"
import "mjolnir/navigation/bake"

HALF :: 10
S :: 20
SPEED :: 3.0 / 60

Box :: struct {
  center, half_extents: [3]f32,
}

WALLS :: [?]Box {
  {{-3, 1, -3}, {0.5, 1, 7}},
  {{3, 1, 3}, {0.5, 1, 7}},
}

mesh: nav.NavMesh
saved: []u8
path: [][3]f32
partial: bool
walker := [3]f32{-8, 0, 8}
next: int
trail: [dynamic][3]f32

setup :: proc() -> bool {
  builder: bake.NavGeometryBuilder
  defer bake.destroy(&builder)
  bake.append_box(&builder, {0, -0.5, 0}, {HALF, 0.5, HALF})
  for w in WALLS do bake.append_box(&builder, w.center, w.half_extents, area = bake.AREA_BLOCKED)
  data := bake.build(&builder) or_return
  defer delete(data)
  first: nav.NavMesh
  nav.navmesh_init(&first, data) or_return
  saved = nav.save(&first)
  nav.destroy(&first)
  return nav.navmesh_init(&mesh, saved)
}

teardown :: proc() {
  delete(path)
  delete(trail)
  delete(saved)
  nav.destroy(&mesh)
}

go_to :: proc(goal: [3]f32) {
  delete(path)
  path, partial = nav.find_path(&mesh, walker, goal)
  next = 0
  clear(&trail)
}

walk :: proc() -> (moving: bool) {
  nav.follow(path, &next, &walker, SPEED) or_return
  append(&trail, walker)
  return true
}

svg :: proc() -> string {
  b := strings.builder_make(context.temp_allocator)
  fmt.sbprintfln(&b, `<svg id="map" xmlns="http://www.w3.org/2000/svg" viewBox="%d %d %d %d" style="background:#14161f">`, -HALF * S, -HALF * S, 2 * HALF * S, 2 * HALF * S)
  positions, indices := nav.debug_triangles(&mesh, context.temp_allocator)
  for i := 0; i + 2 < len(indices); i += 3 {
    a, c, d := positions[indices[i]], positions[indices[i + 1]], positions[indices[i + 2]]
    fmt.sbprintfln(&b, `<polygon points="%f,%f %f,%f %f,%f" fill="#2a9d8f55" stroke="#2a9d8f" stroke-width="0.5"/>`, a.x * S, a.z * S, c.x * S, c.z * S, d.x * S, d.z * S)
  }
  for w in WALLS {
    lo, hi := w.center - w.half_extents, w.center + w.half_extents
    fmt.sbprintfln(&b, `<rect x="%f" y="%f" width="%f" height="%f" fill="#e76f51"/>`, lo.x * S, lo.z * S, (hi.x - lo.x) * S, (hi.z - lo.z) * S)
  }
  for p, i in trail do if i % 20 == 0 do fmt.sbprintfln(&b, `<circle cx="%.1f" cy="%.1f" r="3" fill="#a8dadc"/>`, p.x * S, p.z * S)
  fmt.sbprint(&b, `<polyline fill="none" stroke="#ffd166" stroke-width="3" points="`)
  for p in path do fmt.sbprintf(&b, "%.1f,%.1f ", p.x * S, p.z * S)
  fmt.sbprintln(&b, `"/>`)
  fmt.sbprintfln(&b, `<circle cx="%.1f" cy="%.1f" r="6" fill="#ffffff"/>`, walker.x * S, walker.z * S)
  fmt.sbprintln(&b, "</svg>")
  return strings.to_string(b)
}

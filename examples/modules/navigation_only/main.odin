// Navigation on its own: bake a navmesh around walls, save and reload it, find a path through the maze and walk it. Writes artifacts/modules/navigation_only/{level.navmesh,navmesh.svg}.
package main

import "core:fmt"
import "core:math/linalg"
import "core:os"
import "core:strings"
import nav "mjolnir/navigation"
import "mjolnir/navigation/bake"

OUT :: "artifacts/modules/navigation_only/"
HALF :: 10

Box :: struct {
  center, half_extents: [3]f32,
}

WALLS :: [?]Box {
  {{-3, 1, -3}, {0.5, 1, 7}},
  {{3, 1, 3}, {0.5, 1, 7}},
}

main :: proc() {
  builder: bake.NavGeometryBuilder
  defer bake.destroy(&builder)
  bake.append_box(&builder, {0, -0.5, 0}, {HALF, 0.5, HALF})
  for w in WALLS do bake.append_box(&builder, w.center, w.half_extents, area = bake.AREA_BLOCKED)
  data, baked := bake.build(&builder)
  if !baked do return
  defer delete(data)

  os.make_directory_all(OUT)
  first: nav.NavMesh
  if !nav.navmesh_init(&first, data) do return
  saved := nav.save(&first)
  defer delete(saved)
  _ = os.write_entire_file(OUT + "level.navmesh", saved)
  nav.destroy(&first)
  mesh: nav.NavMesh
  if !nav.navmesh_init(&mesh, saved) do return
  defer nav.destroy(&mesh)

  start, goal := [3]f32{-8, 0, 8}, [3]f32{8, 0, -8}
  path, partial := nav.find_path(&mesh, start, goal)
  defer delete(path)

  walker := start
  next := 0
  trail := make([dynamic][3]f32, context.temp_allocator)
  for nav.follow(path, &next, &walker, 3.0 / 60) do append(&trail, walker)
  arrived := linalg.distance(walker, path[len(path) - 1]) < 0.3

  positions, indices := nav.debug_triangles(&mesh, context.temp_allocator)
  write_svg(OUT + "navmesh.svg", positions, indices, path, trail[:])
  fmt.printfln("navmesh: %d bytes, %d triangles", len(saved), len(indices) / 3)
  fmt.printfln("path: %d points%s", len(path), " (partial)" if partial else "")
  fmt.printfln("walker: %d steps, arrived %v", len(trail), arrived)
  fmt.printfln("wrote %slevel.navmesh, %snavmesh.svg", OUT, OUT)
}

write_svg :: proc(path: string, positions: [][3]f32, indices: []u32, route: [][3]f32, trail: [][3]f32) {
  S :: 20
  b := strings.builder_make(context.temp_allocator)
  fmt.sbprintfln(&b, `<svg xmlns="http://www.w3.org/2000/svg" viewBox="%d %d %d %d" style="background:#14161f">`, -HALF * S, -HALF * S, 2 * HALF * S, 2 * HALF * S)
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
  for p in route do fmt.sbprintf(&b, "%.1f,%.1f ", p.x * S, p.z * S)
  fmt.sbprintln(&b, `"/>`)
  fmt.sbprintln(&b, "</svg>")
  _ = os.write_entire_file(path, strings.to_string(b))
}

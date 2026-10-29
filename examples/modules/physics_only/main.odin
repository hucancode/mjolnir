// Physics on its own: a box tower, a ball dropped on it then knocked off, and a stray ball rolling off the floor, simulated headless for ten seconds and plotted. Writes artifacts/modules/physics_only/heights.svg.
package main

import "core:fmt"
import "core:os"
import "core:strings"
import "mjolnir/geometry"
import "mjolnir/physics"

OUT :: "artifacts/modules/physics_only/"
TICKS :: 600
DT :: 1.0 / 60

Track :: struct {
  body:    physics.BodyHandle,
  label:   string,
  color:   string,
  heights: [dynamic]f32,
}

main :: proc() {
  w: physics.World
  if !physics.init(&w) do return
  defer physics.shutdown(&w)
  physics.body_create(&w, {0, -0.5, 0}, collider = physics.BoxCollider{{6, 0.5, 6}})
  tracks := make([dynamic]Track, context.temp_allocator)
  colors := [?]string{"#4ea8de", "#56cfe1", "#72efdd", "#80ffdb", "#64dfdf"}
  for level in 0 ..< 5 {
    box, _ := physics.body_create(&w, {0, 0.5 + f32(level), 0}, collider = physics.BoxCollider{{0.5, 0.5, 0.5}}, mass = 1)
    append(&tracks, Track{body = box, label = fmt.tprintf("box %d", level), color = colors[level]})
  }
  ball, _ := physics.body_create(&w, {0.3, 9, 0.2}, collider = physics.SphereCollider{0.4}, mass = 4)
  append(&tracks, Track{body = ball, label = "ball", color = "#ffd166"})
  stray, _ := physics.body_create(&w, {5, 1, 0}, collider = physics.SphereCollider{0.3}, mass = 1)
  physics.set_velocity(&w, stray, {4, 0, 0})
  append(&tracks, Track{body = stray, label = "stray", color = "#e76f51"})

  killed := 0
  for tick in 0 ..< TICKS {
    if tick == 240 do physics.apply_impulse(&w, ball, {0, 0, 12})
    physics.step(&w, DT)
    killed += len(physics.killed(&w))
    for &t in tracks {
      b, alive := physics.body(&w, t.body)
      if alive do append(&t.heights, b.position.y)
    }
  }
  hit := physics.raycast(&w, geometry.Ray{{0, 20, 0}, {0, -1, 0}})
  write_svg(OUT + "heights.svg", tracks[:])
  for t in tracks {
    last := t.heights[len(t.heights) - 1] if len(t.heights) > 0 else 0
    fmt.printfln("%-6s %3d ticks alive, last height %.2f", t.label, len(t.heights), last)
  }
  fmt.printfln("%d bodies killed below the floor", killed)
  fmt.printfln("a ray down the tower's axis hits at height %.2f", hit.point.y)
  fmt.printfln("wrote %sheights.svg", OUT)
}

write_svg :: proc(path: string, tracks: []Track) {
  W, H :: 800, 400
  b := strings.builder_make(context.temp_allocator)
  fmt.sbprintfln(&b, `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 %d %d" style="background:#14161f">`, W, H)
  y :: proc(height: f32) -> f32 {return H - 40 - (height + 2) * 30}
  fmt.sbprintfln(&b, `<line x1="0" x2="%d" y1="%f" y2="%f" stroke="#555"/>`, W, y(0), y(0))
  for t, i in tracks {
    fmt.sbprintf(&b, `<polyline fill="none" stroke="%s" stroke-width="2" points="`, t.color)
    for h, k in t.heights do fmt.sbprintf(&b, "%.1f,%.1f ", f32(k) * W / TICKS, y(max(h, -2)))
    fmt.sbprintln(&b, `"/>`)
    fmt.sbprintfln(&b, `<text x="10" y="%d" fill="%s" font-size="12" font-family="sans-serif">%s</text>`, 16 + i * 14, t.color, t.label)
  }
  fmt.sbprintln(&b, "</svg>")
  os.make_directory_all(OUT)
  _ = os.write_entire_file(path, strings.to_string(b))
}

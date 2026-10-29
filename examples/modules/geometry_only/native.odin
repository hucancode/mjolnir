#+build !js
package main

import "core:fmt"
import "core:os"
import "mjolnir/geometry"

OUT :: "artifacts/modules/geometry_only/"

main :: proc() {
  scene := build_scene()
  defer geometry.destroy(scene)
  image, hits := trace(scene)
  svg, kept, total := cull()
  os.make_directory_all(OUT)
  _ = os.write_entire_file(OUT + "shapes.obj", obj(scene))
  _ = os.write_entire_file(OUT + "render.png", image)
  _ = os.write_entire_file(OUT + "cull.svg", svg)
  fmt.printfln("%d vertices, %d triangles", len(scene.vertices), len(scene.indices) / 3)
  fmt.printfln("%d of %d rays hit", hits, WIDTH * HEIGHT)
  fmt.printfln("%d of %d boxes in the frustum", kept, total)
  fmt.printfln("wrote %sshapes.obj, %srender.png, %scull.svg", OUT, OUT, OUT)
}

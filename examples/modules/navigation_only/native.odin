#+build !js
package main

import "core:fmt"
import "core:math/linalg"
import "core:os"

OUT :: "artifacts/modules/navigation_only/"

main :: proc() {
  if !setup() do return
  defer teardown()
  go_to({8, 0, -8})
  for walk() {}
  arrived := linalg.distance(walker, path[len(path) - 1]) < 0.3
  os.make_directory_all(OUT)
  _ = os.write_entire_file(OUT + "level.navmesh", saved)
  _ = os.write_entire_file(OUT + "navmesh.svg", svg())
  fmt.printfln("navmesh: %d bytes", len(saved))
  fmt.printfln("path: %d points%s", len(path), " (partial)" if partial else "")
  fmt.printfln("walker: %d steps, arrived %v", len(trail), arrived)
  fmt.printfln("wrote %slevel.navmesh, %snavmesh.svg", OUT, OUT)
}

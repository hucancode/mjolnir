#+build !js
package main

import "core:fmt"
import "core:os"

OUT :: "artifacts/modules/physics_only/"

main :: proc() {
  if !setup() do return
  defer teardown()
  for ticks < TICKS do tick()
  os.make_directory_all(OUT)
  _ = os.write_entire_file(OUT + "heights.svg", svg())
  fmt.print(summary())
  fmt.printfln("wrote %sheights.svg", OUT)
}

#+build !js
package main

import "core:fmt"
import "core:os"
import "mjolnir/ui"

OUT :: "artifacts/modules/ui_only/"
SIZES :: [?][2]f32{{800, 600}, {1400, 700}}

main :: proc() {
  if !setup() do return
  defer teardown()
  os.make_directory_all(OUT)
  for size in SIZES {
    draw(size, 0.7)
    _, _, batches := ui.mesh(&canvas)
    path := fmt.tprintf("%scanvas_%dx%d.svg", OUT, int(size.x), int(size.y))
    _ = os.write_entire_file(path, svg(size))
    fmt.printfln("%v: %d batches, wrote %s", size, len(batches), path)
  }
}

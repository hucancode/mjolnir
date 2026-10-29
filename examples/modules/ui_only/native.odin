#+build !js
package main

import "core:fmt"
import "core:os"
import "mjolnir/input"
import "mjolnir/ui"

OUT :: "artifacts/modules/ui_only/"
SIZES :: [?][2]f32{{1024, 768}, {1600, 800}}

main :: proc() {
  if !setup() do return
  defer teardown()
  os.make_directory_all(OUT)
  for size in SIZES {
    idle: input.State
    tick(&idle, size)
    r := ui.rect(&gui, button)
    for action in ([]input.Action{.PRESS, .RELEASE}) {
      acc, s: input.State
      input.cursor_event(&acc, r.pos + r.size / 2)
      input.button_event(&acc, .LEFT, action)
      input.drain(&acc, &s)
      tick(&s, size)
    }
    path := fmt.tprintf("%slayout_%dx%d.svg", OUT, int(size.x), int(size.y))
    _ = os.write_entire_file(path, svg(size))
    fmt.printfln("%v: button at %v size %v, clicks %d, wrote %s", size, r.pos, r.size, clicks, path)
  }
}

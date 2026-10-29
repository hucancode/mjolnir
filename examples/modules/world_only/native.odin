#+build !js
package main

import "core:fmt"
import "core:os"
import "mjolnir/world"

OUT :: "artifacts/modules/world_only/"

main :: proc() {
  if !setup() do return
  defer teardown()
  for ticks < TICKS do tick()
  os.make_directory_all(OUT)
  _ = os.write_entire_file(OUT + "orbits.svg", svg())
  fmt.printfln("%d ticks, %d node removed", TICKS, removed)
  for b, i in BODIES do fmt.printfln("%-8s %d positions traced", b.name, len(trails[i]))
  for c in world.children(&w, w.root) do print_tree(c, 0)
  fmt.printfln("wrote %sorbits.svg", OUT)
}

print_tree :: proc(h: world.NodeHandle, depth: int) {
  n := world.node(&w, h)
  if n.name != "" do fmt.printfln("%*s%s at %v", depth * 2, "", n.name, world.world_matrix(&w, h)[3].xyz)
  for c in world.children(&w, h) do print_tree(c, depth + 1 if n.name != "" else depth)
}

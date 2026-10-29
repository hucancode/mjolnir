#+build !js
package main

import "core:fmt"
import "core:math/linalg"
import "core:os"
import "core:strings"
import "mjolnir/animation"

OUT :: "artifacts/modules/animation_only/"
FRAMES :: 12

main :: proc() {
  if !setup() do return
  defer teardown()
  b := strings.builder_make(context.temp_allocator)
  fmt.sbprintfln(&b, `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 %d 500" style="background:#14161f">`, FRAMES * 120)
  for frame in 0 ..< FRAMES {
    for _ in 0 ..< 10 do advance()
    draw(&b, f32(frame) * 120 + 60)
  }
  fmt.sbprintln(&b, "</svg>")
  os.make_directory_all(OUT)
  _ = os.write_entire_file(OUT + "poses.svg", strings.to_string(b))
  end := animation.bone_matrix(&arm.animator, 5)[3].xyz
  fmt.printfln("%d frames of %d bones; the hand ends %.2f from its target", FRAMES, BONES, linalg.distance(end, target()))
  fmt.printfln("wrote %sposes.svg", OUT)
}

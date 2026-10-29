#+build !js
package main

import "core:fmt"
import "core:os"
import "mjolnir/font"

OUT :: "artifacts/modules/font_only/"

main :: proc() {
  if !setup() do return
  defer teardown()
  image, report := text_png()
  os.make_directory_all(OUT)
  _ = os.write_entire_file(OUT + "text.png", image)
  _ = os.write_entire_file(OUT + "atlas.png", atlas_png())
  _, size, _ := font.atlas(&outfit)
  fmt.print(report)
  fmt.printfln("atlas %dx%d; wrote %stext.png, %satlas.png", size.x, size.y, OUT, OUT)
}

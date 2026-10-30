#+build !js
package main

import "core:fmt"
import "core:time"

main :: proc() {
  fmt.print(run(proc(seconds: f32) {time.sleep(time.Duration(seconds * f32(time.Second)))}))
}

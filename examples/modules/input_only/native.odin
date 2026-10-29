#+build !js
package main

import "core:fmt"

report :: proc(line: string) {
  fmt.println(line)
}

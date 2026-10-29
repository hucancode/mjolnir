#+build !js
package main

import "core:fmt"
import "core:os"

main :: proc() {
  path := os.args[1] if len(os.args) > 1 else DEFAULT
  data, err := os.read_entire_file(path, context.allocator)
  if err != nil {
    fmt.eprintfln("cannot read %s: %v", path, err)
    os.exit(1)
  }
  defer delete(data)
  report, ok := inspect(path, data)
  if !ok {
    fmt.eprintfln("%s is not a self-contained glTF", path)
    os.exit(1)
  }
  fmt.print(report)
}

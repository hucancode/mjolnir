#+build !js
package render

import "core:os"
import "core:strings"
import stbi "vendor:stb/image"

@(private)
capture_mkdir :: proc(path: string) {
  os.make_directory_all(path)
}

// Writes tightly packed rgb as a PNG.
@(private)
capture_write :: proc(path: string, width, height: int, rgb: []u8) -> bool {
  name := strings.clone_to_cstring(path, context.temp_allocator)
  return stbi.write_png(name, i32(width), i32(height), 3, raw_data(rgb), i32(width * 3)) != 0
}

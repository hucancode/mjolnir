#+build !js
package render

import "core:log"
import "core:os"

// create_texture_from_path loads an image file (png, jpg, hdr, ...) into a bindless 2D texture.
create_texture_from_path :: proc(
  r: ^Renderer,
  path: string,
  format: TextureFormat = .RGBA8_SRGB,
  generate_mips: bool = false,
) -> (
  handle: TextureHandle,
  ok: bool,
) #optional_ok {
  data, err := os.read_entire_file(path, context.allocator)
  if err != nil {
    log.errorf("Failed to read texture '%s': %v", path, err)
    return 0, false
  }
  defer delete(data)
  return create_texture_from_data(r, data, format, generate_mips)
}

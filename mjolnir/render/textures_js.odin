#+build js
package render

import "core:log"

// create_texture_from_path fails on the web: there is no file system to load from. Load the
// bytes some other way (#load) and use create_texture_from_data.
create_texture_from_path :: proc(
  r: ^Renderer,
  path: string,
  format: TextureFormat = .RGBA8_SRGB,
  generate_mips: bool = false,
) -> (
  handle: TextureHandle,
  ok: bool,
) #optional_ok {
  log.errorf("Texture '%s': no file system on the web", path)
  return 0, false
}

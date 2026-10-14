#+build js
package gltf_render

import path "core:path/slashpath"

// The path of `uri` relative to the glTF file at gltf_path, in the temp allocator.
@(private)
sibling_path :: proc(gltf_path, uri: string) -> (string, bool) {
  return path.join({path.dir(gltf_path, context.temp_allocator), uri}, context.temp_allocator), true
}

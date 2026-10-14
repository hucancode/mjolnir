#+build !js
package gltf_render

import path "core:path/filepath"

// The path of `uri` relative to the glTF file at gltf_path, in the temp allocator.
@(private)
sibling_path :: proc(gltf_path, uri: string) -> (string, bool) {
  joined, err := path.join({path.dir(gltf_path), uri}, context.temp_allocator)
  return joined, err == nil
}

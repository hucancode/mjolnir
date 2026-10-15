package render

import "core:strings"

// Shaders ship per backend: SPIR-V (shader/vulkan) or WGSL (shader/wgpu). A pass names both and
// each build embeds only its own backend's.
@(private)
spirv :: proc($path: string) -> []u8 {
  when RENDER_BACKEND == "vulkan" do return #load(path)
  else do return nil
}

@(private)
wgsl :: proc($path: string) -> string {
  when RENDER_BACKEND == "wgpu" do return #load(path, string)
  else do return ""
}

// Concatenates WGSL files into one module.
@(private)
wgsl_join :: proc(parts: ..string) -> string {
  return strings.concatenate(parts, context.temp_allocator)
}

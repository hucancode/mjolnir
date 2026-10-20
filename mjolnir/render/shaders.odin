package render

import "./rhi"

// Shaders are compiled from one Slang source per shader (shader/*.slang) to the backend's form:
// shader/<name>.spv (Vulkan) or shader/<name>.wgsl (wgpu); a build embeds only its own.
SHADER_EXT :: "spv" when RENDER_BACKEND == "vulkan" else "wgsl"

// The compiled shader of an engine pass, by its source's name under shader/.
@(private)
shader_source :: proc($name: string) -> rhi.ShaderSource {
  return #load("shader/" + name + "." + SHADER_EXT)
}

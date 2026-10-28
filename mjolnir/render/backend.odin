package render

import "rhi"
import vulkan "vulkan"
import wgpu "wgpu"

// RENDER_BACKEND picks the GPU backend at compile time (-define:RENDER_BACKEND=...): vulkan, the
// default, or wgpu, which also runs on the web.
RENDER_BACKEND :: #config(RENDER_BACKEND, "vulkan")
#assert(RENDER_BACKEND == "vulkan" || RENDER_BACKEND == "wgpu", "unknown RENDER_BACKEND")
#assert(RENDER_BACKEND == "wgpu" || ODIN_OS != .JS, "the web takes RENDER_BACKEND=wgpu")

// The backend is chosen at build time, and render calls its procs directly (backend_glue.odin).
when RENDER_BACKEND == "vulkan" {
  @(private)
  FRAMES_IN_FLIGHT :: vulkan.FRAMES_IN_FLIGHT
  // WindowHandle is the window render draws into: a GLFW window made after glfw.Init with
  // CLIENT_API = NO_API; you poll its events.
  WindowHandle :: vulkan.WindowHandle
} else when RENDER_BACKEND == "wgpu" {
  @(private)
  FRAMES_IN_FLIGHT :: wgpu.FRAMES_IN_FLIGHT
  // WindowHandle is the window render draws into: a GLFW window made after glfw.Init with
  // CLIENT_API = NO_API, or on the web the CSS selector of a canvas; you poll its events.
  WindowHandle :: wgpu.WindowHandle
}

// TextureHandle identifies a texture; NO_TEXTURE is none.
TextureHandle :: rhi.TextureHandle
TextureFormat :: rhi.TextureFormat
// BlendMode and CullMode configure a material shader (material_shader_create).
BlendMode :: rhi.BlendMode
CullMode :: rhi.CullMode
// Topology is how a draw shader's vertices make primitives.
Topology :: rhi.Topology
// Timing is one pass's GPU time (gpu_timings).
Timing :: rhi.Timing

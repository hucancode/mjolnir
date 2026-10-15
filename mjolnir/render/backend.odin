package render

import "rhi"
import vulkan "vulkan"
import wgpu "wgpu"

RENDER_BACKEND :: #config(RENDER_BACKEND, "vulkan")
#assert(RENDER_BACKEND == "vulkan" || RENDER_BACKEND == "wgpu", "unknown RENDER_BACKEND")
#assert(RENDER_BACKEND == "wgpu" || ODIN_OS != .JS, "the web takes RENDER_BACKEND=wgpu")

// The backend is chosen at build time, and render calls its procs directly (backend_glue.odin).
when RENDER_BACKEND == "vulkan" {
  FRAMES_IN_FLIGHT :: vulkan.FRAMES_IN_FLIGHT
  // WindowHandle is the window render draws into (platform.Platform.window).
  WindowHandle :: vulkan.WindowHandle
} else when RENDER_BACKEND == "wgpu" {
  FRAMES_IN_FLIGHT :: wgpu.FRAMES_IN_FLIGHT
  // WindowHandle is the window render draws into (platform.Platform.window).
  WindowHandle :: wgpu.WindowHandle
}

// What render takes from rhi's vocabulary. TextureHandle identifies a bindless texture;
// NO_TEXTURE is none.
TextureHandle :: rhi.TextureHandle
TextureFormat :: rhi.TextureFormat

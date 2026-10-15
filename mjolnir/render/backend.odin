package render

import "rhi"
import vulkan "vulkan"
import wgpu "wgpu"

RENDER_BACKEND :: #config(RENDER_BACKEND, "vulkan")
#assert(RENDER_BACKEND == "vulkan" || RENDER_BACKEND == "wgpu", "unknown RENDER_BACKEND")
#assert(RENDER_BACKEND == "wgpu" || ODIN_OS != .JS, "the web takes RENDER_BACKEND=wgpu")

when RENDER_BACKEND == "vulkan" {
  FRAMES_IN_FLIGHT :: vulkan.FRAMES_IN_FLIGHT
  // WindowHandle is the window render draws into (platform.Platform.window).
  WindowHandle :: vulkan.WindowHandle

} else when RENDER_BACKEND == "wgpu" {
  FRAMES_IN_FLIGHT :: wgpu.FRAMES_IN_FLIGHT
  // WindowHandle is the window render draws into (platform.Platform.window).
  WindowHandle :: wgpu.WindowHandle

}

// The contract types, declared once in rhi: render's API names them.
// TextureHandle identifies a bindless texture; NO_TEXTURE is none.
TextureHandle :: rhi.TextureHandle
TextureFormat :: rhi.TextureFormat
AttachmentType :: rhi.AttachmentType
MaterialType :: rhi.MaterialType
LightType :: rhi.LightType
Vertex :: rhi.Vertex
Vertex2D :: rhi.Vertex2D
GrayscaleEffect :: rhi.GrayscaleEffect
ToneMapEffect :: rhi.ToneMapEffect
BlurEffect :: rhi.BlurEffect
BloomEffect :: rhi.BloomEffect
OutlineEffect :: rhi.OutlineEffect
FogEffect :: rhi.FogEffect
CrossHatchEffect :: rhi.CrossHatchEffect
DoFEffect :: rhi.DoFEffect
PostprocessEffect :: rhi.PostprocessEffect

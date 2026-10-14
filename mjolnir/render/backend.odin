package render

import vulkan "vulkan"
import wgpu "wgpu"

// RENDER_BACKEND picks the GPU backend at compile time (-define:RENDER_BACKEND=vulkan|wgpu).
// backend.odin and backend_glue.odin are the only files naming a backend package: the
// types, constants and procs aliased there are the whole boundary, and a backend exports
// every one of them under the same names. This file holds the ones in render's API.
RENDER_BACKEND :: #config(RENDER_BACKEND, "vulkan")
#assert(RENDER_BACKEND == "vulkan" || RENDER_BACKEND == "wgpu", "unknown RENDER_BACKEND")
#assert(RENDER_BACKEND == "wgpu" || ODIN_OS != .JS, "the web takes RENDER_BACKEND=wgpu")

when RENDER_BACKEND == "vulkan" {
  FRAMES_IN_FLIGHT :: vulkan.FRAMES_IN_FLIGHT
  // WindowHandle is the window render draws into (platform.Platform.window).
  WindowHandle :: vulkan.WindowHandle

  // TextureHandle identifies a bindless texture; NO_TEXTURE is none.
  TextureHandle :: vulkan.TextureHandle
  TextureFormat :: vulkan.TextureFormat
  AttachmentType :: vulkan.AttachmentType
  MaterialType :: vulkan.MaterialType
  LightType :: vulkan.LightType
  Vertex :: vulkan.Vertex
  Vertex2D :: vulkan.Vertex2D
  GrayscaleEffect :: vulkan.GrayscaleEffect
  ToneMapEffect :: vulkan.ToneMapEffect
  BlurEffect :: vulkan.BlurEffect
  BloomEffect :: vulkan.BloomEffect
  OutlineEffect :: vulkan.OutlineEffect
  FogEffect :: vulkan.FogEffect
  CrossHatchEffect :: vulkan.CrossHatchEffect
  DoFEffect :: vulkan.DoFEffect
  PostprocessEffect :: vulkan.PostprocessEffect
} else when RENDER_BACKEND == "wgpu" {
  FRAMES_IN_FLIGHT :: wgpu.FRAMES_IN_FLIGHT
  // WindowHandle is the window render draws into (platform.Platform.window).
  WindowHandle :: wgpu.WindowHandle

  // TextureHandle identifies a bindless texture; NO_TEXTURE is none.
  TextureHandle :: wgpu.TextureHandle
  TextureFormat :: wgpu.TextureFormat
  AttachmentType :: wgpu.AttachmentType
  MaterialType :: wgpu.MaterialType
  LightType :: wgpu.LightType
  Vertex :: wgpu.Vertex
  Vertex2D :: wgpu.Vertex2D
  GrayscaleEffect :: wgpu.GrayscaleEffect
  ToneMapEffect :: wgpu.ToneMapEffect
  BlurEffect :: wgpu.BlurEffect
  BloomEffect :: wgpu.BloomEffect
  OutlineEffect :: wgpu.OutlineEffect
  FogEffect :: wgpu.FogEffect
  CrossHatchEffect :: wgpu.CrossHatchEffect
  DoFEffect :: wgpu.DoFEffect
  PostprocessEffect :: wgpu.PostprocessEffect
}

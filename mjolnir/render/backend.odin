package render

import vulkan "vulkan"

// RENDER_BACKEND picks the GPU backend at compile time (-define:RENDER_BACKEND=vulkan).
// backend.odin and backend_private.odin are the only files naming a backend package: the
// types, constants and procs aliased there are the whole boundary, and a backend exports
// every one of them under the same names. This file holds the ones in render's API.
RENDER_BACKEND :: #config(RENDER_BACKEND, "vulkan")
#assert(RENDER_BACKEND == "vulkan", "unknown RENDER_BACKEND")

when RENDER_BACKEND == "vulkan" {
  FRAMES_IN_FLIGHT :: vulkan.FRAMES_IN_FLIGHT

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
}

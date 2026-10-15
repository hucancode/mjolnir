#+private
package render

import "rhi"
import vulkan "vulkan"
import wgpu "wgpu"

// What render takes of the chosen backend: `dev` is its rhi.Procs (lifecycle included), a
// constant, so calls through it cost no dispatch; the rest are the sizes that follow from its
// config.
when RENDER_BACKEND == "vulkan" {
  Backend :: vulkan.Backend
  RETIRE_GRACE :: vulkan.RETIRE_GRACE
  MAX_PYRAMID_SLOTS :: vulkan.MAX_PYRAMID_SLOTS
  MAX_DRAW_LIST_SLOTS :: vulkan.MAX_DRAW_LIST_SLOTS
  dev :: vulkan.PROCS
} else when RENDER_BACKEND == "wgpu" {
  Backend :: wgpu.Backend
  RETIRE_GRACE :: wgpu.RETIRE_GRACE
  MAX_PYRAMID_SLOTS :: wgpu.MAX_PYRAMID_SLOTS
  MAX_DRAW_LIST_SLOTS :: wgpu.MAX_DRAW_LIST_SLOTS
  dev :: wgpu.PROCS
}


TextureDesc :: rhi.TextureDesc
MAX_TEXTURES :: rhi.MAX_TEXTURES
MAX_ACTIVE_CAMERAS :: rhi.MAX_ACTIVE_CAMERAS
PREFILTER_MIPS :: rhi.PREFILTER_MIPS
BACKBUFFER :: rhi.BACKBUFFER

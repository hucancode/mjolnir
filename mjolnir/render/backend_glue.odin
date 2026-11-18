#+private
package render

import "rhi"
@(require) import vulkan "vulkan"
@(require) import wgpu "wgpu"

// What render takes of the chosen backend: `dev` is its rhi.Procs (lifecycle included), a
// constant, so calls through it cost no dispatch; the rest are its compile-time features
// (BINDLESS).
when RENDER_BACKEND == "vulkan" {
  Backend :: vulkan.Backend
  RETIRE_GRACE :: vulkan.RETIRE_GRACE
  BINDLESS :: vulkan.BINDLESS
  dev :: vulkan.PROCS
} else when RENDER_BACKEND == "wgpu" {
  Backend :: wgpu.Backend
  RETIRE_GRACE :: wgpu.RETIRE_GRACE
  BINDLESS :: wgpu.BINDLESS
  dev :: wgpu.PROCS
}


TextureDesc :: rhi.TextureDesc
// The most cameras at once. A camera costs memory only once created (its images and draw
// lists); this sizes the bindless arrays, a few bytes per entry.
MAX_ACTIVE_CAMERAS :: 512
// mips of the prefiltered environment cube
PREFILTER_MIPS :: 5
// the IBL precompute's storage targets: the irradiance cube, then each prefilter mip
PRECOMPUTE_TARGETS :: 1 + PREFILTER_MIPS
// mips a depth pyramid may have (shader/depth_reduce.slang MAX_MIPS)
MAX_DEPTH_MIPS :: 16
// Depth pyramids and draw lists live in slots render assigns: a pyramid and a draw-list slot
// per camera and frame in flight, plus a draw-list slot per frame for the shadow views.
MAX_PYRAMID_SLOTS :: MAX_ACTIVE_CAMERAS * FRAMES_IN_FLIGHT
MAX_DRAW_LIST_SLOTS :: (MAX_ACTIVE_CAMERAS + 1) * FRAMES_IN_FLIGHT
// The bindless storage-buffer indices draw lists take (Pool.DRAW_LISTS): a replaced list takes a
// new one while frames in flight still read the old.
DRAW_LIST_BINDINGS :: 4096
#assert(DRAW_LIST_BINDINGS >= 2 * MAX_DRAW_LIST_SLOTS)
// The bindless arrays: storage images hold the pyramids' mips, then the IBL precompute targets,
// then the cameras' lit images and their ambient occlusion images, one each per pyramid slot;
// storage buffers the draw lists; the extra buffer the pyramid counters, one u32 per pyramid slot.
BINDLESS_SIZES :: [rhi.BindlessArray]u32 {
  .STORAGE_IMAGES  = MAX_PYRAMID_SLOTS * MAX_DEPTH_MIPS + PRECOMPUTE_TARGETS + 2 * MAX_PYRAMID_SLOTS,
  .STORAGE_BUFFERS = DRAW_LIST_BINDINGS,
  .EXTRA_BUFFERS   = 1,
}
BACKBUFFER :: rhi.BACKBUFFER

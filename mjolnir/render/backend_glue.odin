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
// mips a depth pyramid may have
MAX_DEPTH_MIPS :: 16
// Draw lists live in slots: camera c's is slot c, the shadow views' the one after the cameras'.
// One copy each: only the GPU writes them, ordered by the frame graph.
MAX_DRAW_LIST_SLOTS :: MAX_ACTIVE_CAMERAS + 1
// The bindless storage-buffer indices draw lists take (Pool.DRAW_LISTS): a replaced list takes a
// new one while frames in flight still read the old.
DRAW_LIST_BINDINGS :: 4096
#assert(DRAW_LIST_BINDINGS >= 2 * MAX_DRAW_LIST_SLOTS)
// The storage image views of every storage texture render holds, one per mip (texture_views).
MAX_STORAGE_VIEWS :: 1 << 14
// The bindless arrays: storage images the storage textures' views; storage buffers the draw
// lists; the extra buffer the pyramid counters, one u32 per camera.
BINDLESS_SIZES :: [rhi.BindlessArray]u32 {
  .STORAGE_IMAGES  = MAX_STORAGE_VIEWS,
  .STORAGE_BUFFERS = DRAW_LIST_BINDINGS,
  .EXTRA_BUFFERS   = 1,
}
BACKBUFFER :: rhi.BACKBUFFER

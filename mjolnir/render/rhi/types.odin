package rhi

// The vocabulary of textures and the few budgets a device sizes itself by.

MAX_ACTIVE_CAMERAS :: 128

// mips of the prefiltered environment cube
PREFILTER_MIPS :: 5

MAX_TEXTURES :: 1000

// SamplerType names the samplers every device makes; shaders index them with these values as
// literals (shader/common.slang).
SamplerType :: enum u32 {
  NEAREST_CLAMP,
  LINEAR_CLAMP,
  NEAREST_REPEAT,
  LINEAR_REPEAT,
  // bilinear depth comparison (2x2 PCF) for shadow maps: lit where the reference depth is at or
  // in front of the stored one
  SHADOW_COMPARE,
}

// A handle is the index of its texture in the bindless texture array; 0 is none.
TextureHandle :: distinct u32

// TextureFormat is the texel format of a texture. A8 is coverage, sampled as white with
// alpha = coverage.
TextureFormat :: enum {
  RGBA8_SRGB,
  RGBA8_UNORM,
  RGBA16F,
  RGBA32F,
  R32F,
  A8,
  D32F,
  // only as a pipeline's color format: the swapchain's (the image BACKBUFFER names)
  BACKBUFFER,
}

TextureUsage :: enum {
  SAMPLED,
  COLOR_TARGET,
  DEPTH_TARGET,
  STORAGE,
}

// TextureDesc describes a texture: `mip_levels` levels, six layers when `cube`, a 2D array of
// `layers` when that is above 1 (0 and 1 are one plain 2D layer). `shared`
// textures are also accessed by the async compute queue.
TextureDesc :: struct {
  extent:     [2]u32,
  format:     TextureFormat,
  usage:      bit_set[TextureUsage],
  mip_levels: u32,
  cube:       bool,
  layers:     u32,
  shared:     bool,
}

// FrameStatus is how frame went: RESIZE asks for resize at the new framebuffer size.
FrameStatus :: enum {
  OK,
  RESIZE,
  ERROR,
}

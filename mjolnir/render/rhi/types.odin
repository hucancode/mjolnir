package rhi

// The vocabulary of textures and the few budgets a device sizes itself by.

// MAX_TEXTURES is the ceiling of texture handles: the declared size of the bindless texture
// array. Devices keep per-texture storage only for the handles used; a device whose limits are
// lower binds fewer (handles past them are not sampled through the array).
MAX_TEXTURES :: 1 << 16

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
  // one 8-bit channel sampled as is (red, 0, 0, 1): palette indices of an indexed sprite (MaterialType.SPRITE_INDEXED)
  R8_UNORM,
  // two 8-bit channels, and 11, 11 and 10-bit floats in 32 bits (HDR color without alpha): render
  // targets only, which render keeps its G-buffer in
  RG8_UNORM,
  RG11B10F,
  A8,
  D32F,
  // only as a pipeline's color format: the swapchain's (the image BACKBUFFER names)
  BACKBUFFER,
}

// TextureUsage is what a texture may be used as.
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

// MemoryStats is the GPU memory the device holds for its resources, in bytes: `reserved` is
// what it took from the GPU, `used` the part resources occupy. `exact` is false where the
// backend can only add up its resources' sizes (an estimate that leaves out driver overhead,
// padding and the swapchain).
MemoryStats :: struct {
  reserved, used: u64,
  exact:          bool,
}

// FrameStatus is how frame went: RESIZE asks for resize at the new framebuffer size.
FrameStatus :: enum {
  OK,
  RESIZE,
  ERROR,
}

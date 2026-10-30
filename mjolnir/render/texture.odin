package render

import "../containers"
import "core:c"
import "core:log"
import "core:math"
import stbi "vendor:stb/image"

// Textures below MAX_RENDER_TARGETS are render targets (slots[.TARGETS]): camera attachments,
// depth pyramids and the post-process ring, which the renderer reallocates on resize. The
// rest are slots[.TEXTURES]: the renderer's own from init, then the map's.

// The pool handing out handle's index.
@(private)
MAX_RENDER_TARGETS :: 256

@(private)
texture_pool :: proc(self: ^Renderer, handle: TextureHandle) -> ^containers.Slots {
  return &self.slots[.TARGETS] if handle < MAX_RENDER_TARGETS else &self.slots[.TEXTURES]
}

@(private)
calculate_mip_levels :: proc(width, height: u32) -> u32 {
  return u32(math.floor(math.log2(f32(max(width, height))))) + 1
}

// `data` fills level 0; the other levels are blitted down. `target` takes the handle from
// the render target range.
@(private)
allocate_texture :: proc(self: ^Renderer, desc: TextureDesc, data: []u8 = nil, target := false) -> (handle: TextureHandle, ok: bool) {
  lock(self)
  pool := &self.slots[.TARGETS] if target else &self.slots[.TEXTURES]
  h := containers.slots_alloc(pool) or_return
  if !dev.texture_create(&self.gpu, TextureHandle(h), desc, data) {
    containers.slots_free(pool, h)
    return 0, false
  }
  return TextureHandle(h), true
}

// texture_destroy frees the texture; its handle is stale at once, and frames already
// submitted still sample it.
texture_destroy :: proc(self: ^Renderer, handle: TextureHandle) {
  lock(self)
  containers.slots_free(texture_pool(self, handle), u32(handle))
  if handle < MAX_TEXTURES do self.storage_formats[handle] = {}
}

// NO_TEXTURE is the TextureHandle of none, as materials, emitters and draw2d commands hold it.
NO_TEXTURE :: 0

// texture_create makes a 2D texture that lives until texture_destroy or teardown, from either
//   raw pixels, size.x by size.y texels of format (A8 samples as white with alpha = the pixel);
//   `storage` lets a compute shader write it too (StorageImage), its pixels nil or not, in
//   .RGBA8_UNORM, .RGBA16F or .R32F:
//     texture_create(r, pixels: []u8, size: [2]u32, format = .RGBA8_SRGB, storage = false) -> (TextureHandle, ok)
//   an encoded image (png, jpg, hdr, ...) held in memory; RGBA32F decodes it as linear HDR:
//     texture_create(r, data: []u8, format = .RGBA8_SRGB, generate_mips = false) -> (TextureHandle, ok)
texture_create :: proc {
  texture_create_pixels,
  texture_create_encoded,
}

@(private = "file")
texture_create_pixels :: proc(
  self: ^Renderer,
  pixels: []u8,
  size: [2]u32,
  format: TextureFormat = .RGBA8_SRGB,
  storage := false,
) -> (
  handle: TextureHandle,
  ok: bool,
) #optional_ok {
  if !storage do return allocate_texture(self, {extent = size, format = format, usage = {.SAMPLED}}, pixels)
  if format != .RGBA8_UNORM && format != .RGBA16F && format != .R32F {
    log.errorf("A storage texture is RGBA8_UNORM, RGBA16F or R32F, not %v", format)
    return 0, false
  }
  lock(self)
  handle = allocate_texture(self, {extent = size, format = format, usage = {.SAMPLED, .STORAGE}}, pixels) or_return
  self.storage_formats[handle] = format
  return handle, true
}

@(private = "file")
texture_create_encoded :: proc(
  self: ^Renderer,
  data: []u8,
  format: TextureFormat = .RGBA8_SRGB,
  generate_mips: bool = false,
) -> (
  handle: TextureHandle,
  ok: bool,
) #optional_ok {
  width, height, channels: c.int
  pixels: rawptr
  texel_size: c.int = 4
  if format == .RGBA32F {
    pixels = stbi.loadf_from_memory(raw_data(data), c.int(len(data)), &width, &height, &channels, 4)
    texel_size *= size_of(f32)
  } else {
    pixels = stbi.load_from_memory(raw_data(data), c.int(len(data)), &width, &height, &channels, 4)
  }
  if pixels == nil {
    log.errorf("Failed to decode texture: %s", stbi.failure_reason())
    return 0, false
  }
  defer stbi.image_free(pixels)
  extent := [2]u32{u32(width), u32(height)}
  desc := TextureDesc {
    extent     = extent,
    format     = format,
    usage      = {.SAMPLED},
    mip_levels = calculate_mip_levels(extent.x, extent.y) if generate_mips else 1,
  }
  return allocate_texture(self, desc, ([^]u8)(pixels)[:width * height * texel_size])
}


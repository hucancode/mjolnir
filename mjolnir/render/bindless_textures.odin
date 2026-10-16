package render

import cont "../containers"
import "core:c"
import "core:log"
import "core:math"
import stbi "vendor:stb/image"

// Textures below MAX_RENDER_TARGETS are render targets (target_slots): camera attachments,
// depth pyramids and the post-process ring, which the renderer reallocates on resize. The
// rest are texture_slots: the renderer's own from init, then the map's.

// The pool handing out handle's index.
@(private)
MAX_RENDER_TARGETS :: 256

@(private)
texture_pool :: proc(r: ^Renderer, handle: TextureHandle) -> ^cont.Slots {
  return &r.target_slots if handle < MAX_RENDER_TARGETS else &r.texture_slots
}

@(private)
calculate_mip_levels :: proc(width, height: u32) -> u32 {
  return u32(math.floor(math.log2(f32(max(width, height))))) + 1
}

// `data` fills level 0; the other levels are blitted down. `target` takes the handle from
// the render target range.
@(private)
allocate_texture :: proc(r: ^Renderer, desc: TextureDesc, data: []u8 = nil, target := false) -> (handle: TextureHandle, ok: bool) {
  guard(r)
  pool := &r.target_slots if target else &r.texture_slots
  h := cont.slots_alloc(pool) or_return
  if !dev.texture_create(&r.gpu, TextureHandle(h), desc, data) {
    cont.slots_free(pool, h)
    return 0, false
  }
  return TextureHandle(h), true
}

// destroy_texture invalidates handle at once; its slot and image are released once no
// frame in flight samples them. teardown frees every texture made since init.
destroy_texture :: proc(r: ^Renderer, handle: TextureHandle) {
  guard(r)
  cont.slots_free(texture_pool(r, handle), u32(handle))
}

// NO_TEXTURE is the TextureHandle of none, as materials, emitters and draw2d commands hold it.
NO_TEXTURE :: 0

// create_texture_from_data decodes an encoded image (png, jpg, hdr, ...) held in memory
// into a bindless 2D texture. RGBA32F decodes it as linear HDR.
create_texture_from_data :: proc(
  r: ^Renderer,
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
  return allocate_texture(r, desc, ([^]u8)(pixels)[:width * height * texel_size])
}


package shared

import cont "../../containers"
import d "../../data"
import "../../gpu"
import "core:c"
import "core:log"
import "core:strings"
import stbi "vendor:stb/image"
import vk "vendor:vulkan"

create_texture_2d_empty :: proc(
  gctx: ^gpu.GPUContext,
  texture_manager: ^gpu.TextureManager,
  width, height: u32,
  format: vk.Format,
  usage: vk.ImageUsageFlags = {.COLOR_ATTACHMENT, .SAMPLED},
  auto_purge: bool = false,
) -> (
  handle: d.Image2DHandle,
  ret: vk.Result,
) {
  return gpu.allocate_texture_2d(texture_manager, gctx, width, height, format, usage)
}

create_texture_2d_from_pixels :: proc(
  gctx: ^gpu.GPUContext,
  texture_manager: ^gpu.TextureManager,
  pixels: []u8,
  width, height: int,
  format: vk.Format = .R8G8B8A8_SRGB,
  generate_mips: bool = false,
  auto_purge: bool = false,
) -> (
  handle: d.Image2DHandle,
  ret: vk.Result,
) {
  return gpu.allocate_texture_2d_with_data(
    texture_manager,
    gctx,
    raw_data(pixels),
    vk.DeviceSize(len(pixels)),
    u32(width),
    u32(height),
    format,
    {.SAMPLED},
    generate_mips,
  )
}

create_texture_2d_from_data :: proc(
  gctx: ^gpu.GPUContext,
  texture_manager: ^gpu.TextureManager,
  data: []u8,
  format: vk.Format = .R8G8B8A8_SRGB,
  generate_mips: bool = false,
  auto_purge: bool = false,
) -> (
  handle: d.Image2DHandle,
  ret: vk.Result,
) {
  width, height, channels: c.int
  pixels := stbi.load_from_memory(raw_data(data), c.int(len(data)), &width, &height, &channels, 4)
  if pixels == nil {
    log.errorf("Failed to decode texture data: %s", stbi.failure_reason())
    return {}, .ERROR_UNKNOWN
  }
  defer stbi.image_free(pixels)
  pixel_size := vk.DeviceSize(width * height * 4)
  return gpu.allocate_texture_2d_with_data(
    texture_manager,
    gctx,
    pixels,
    pixel_size,
    u32(width),
    u32(height),
    format,
    {.SAMPLED},
    generate_mips,
  )
}

create_texture_2d_from_path :: proc(
  gctx: ^gpu.GPUContext,
  texture_manager: ^gpu.TextureManager,
  path: string,
  format: vk.Format = .R8G8B8A8_SRGB,
  generate_mips: bool = false,
  usage: vk.ImageUsageFlags = {.SAMPLED},
  is_hdr: bool = false,
  auto_purge: bool = false,
) -> (
  handle: d.Image2DHandle,
  ret: vk.Result,
) {
  path_cstr := strings.clone_to_cstring(path)
  defer delete(path_cstr)
  width, height, channels: c.int
  pixel_data: rawptr
  data_size: vk.DeviceSize
  if is_hdr {
    pixels := stbi.loadf(path_cstr, &width, &height, &channels, 4)
    if pixels == nil {
      log.errorf("Failed to load HDR texture '%s': %s", path, stbi.failure_reason())
      return {}, .ERROR_UNKNOWN
    }
    pixel_data = pixels
    data_size = vk.DeviceSize(width * height * 4 * size_of(f32))
  } else {
    pixels := stbi.load(path_cstr, &width, &height, &channels, 4)
    if pixels == nil {
      log.errorf("Failed to load texture '%s': %s", path, stbi.failure_reason())
      return {}, .ERROR_UNKNOWN
    }
    pixel_data = pixels
    data_size = vk.DeviceSize(width * height * 4)
  }
  defer stbi.image_free(pixel_data)
  return gpu.allocate_texture_2d_with_data(
    texture_manager,
    gctx,
    pixel_data,
    data_size,
    u32(width),
    u32(height),
    format,
    usage,
    generate_mips,
  )
}

destroy_texture_2d :: proc(
  gctx: ^gpu.GPUContext,
  texture_manager: ^gpu.TextureManager,
  handle: d.Image2DHandle,
) {
  gpu.free_texture_2d(texture_manager, gctx, handle)
}

destroy_texture_cube :: proc(
  gctx: ^gpu.GPUContext,
  texture_manager: ^gpu.TextureManager,
  handle: d.ImageCubeHandle,
) {
  gpu.free_texture_cube(texture_manager, gctx, handle)
}

get_texture_2d :: proc(
  texture_manager: ^gpu.TextureManager,
  handle: d.Image2DHandle,
) -> ^gpu.Image {
  return gpu.get_texture_2d(texture_manager, handle)
}

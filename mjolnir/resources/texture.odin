package resources

import "core:c"
import "core:strings"
import "core:log"
import "core:math/linalg"
import vk "vendor:vulkan"
import stbi "vendor:stb/image"
import "../gpu"

create_empty_texture_2d :: proc(
  gpu_context: ^gpu.GPUContext,
  manager: ^Manager,
  width, height: u32,
  format: vk.Format,
  usage: vk.ImageUsageFlags = {.COLOR_ATTACHMENT, .SAMPLED},
) -> (
  handle: Handle,
  texture: ^gpu.ImageBuffer,
  ret: vk.Result,
) {
  handle, texture = alloc(&manager.image_2d_buffers)
  texture^ = gpu.malloc_image_buffer(
    gpu_context,
    width,
    height,
    format,
    .OPTIMAL,
    usage,
    {.DEVICE_LOCAL},
  ) or_return

  // Determine aspect mask based on format
  aspect_mask := vk.ImageAspectFlags{.COLOR}
  if format == .D32_SFLOAT ||
     format == .D24_UNORM_S8_UINT ||
     format == .D16_UNORM {
    aspect_mask = {.DEPTH}
  }

  texture.view = gpu.create_image_view(
    gpu_context.device,
    texture.image,
    format,
    aspect_mask,
  ) or_return
  set_texture_2d_descriptor(gpu_context, manager, handle.index, texture.view)
  ret = .SUCCESS
  log.debugf(
    "created empty texture %d x %d %v 0x%x",
    width,
    height,
    format,
    texture.image,
  )
  return
}

create_empty_texture_cube :: proc(
  gpu_context: ^gpu.GPUContext,
  manager: ^Manager,
  size: u32,
  format: vk.Format = .D32_SFLOAT,
  usage: vk.ImageUsageFlags = {.DEPTH_STENCIL_ATTACHMENT, .SAMPLED},
) -> (
  handle: Handle,
  texture: ^gpu.CubeImageBuffer,
  ret: vk.Result,
) {
  handle, texture = alloc(&manager.image_cube_buffers)
  gpu.cube_depth_texture_init(
    gpu_context,
    texture,
    size,
    format,
    usage,
  ) or_return
  set_texture_cube_descriptor(
    gpu_context,
    manager,
    handle.index,
    texture.view,
  )
  ret = .SUCCESS
  return
}

create_texture :: proc {
  create_empty_texture_2d,
  create_texture_from_path,
  create_texture_from_data,
  create_texture_from_pixels,
}

// Grouped cube texture creation procedures
create_cube_texture :: proc {
  create_empty_texture_cube,
}

create_texture_from_path :: proc(
  gpu_context: ^gpu.GPUContext,
  manager: ^Manager,
  path: string,
) -> (
  handle: Handle,
  texture: ^gpu.ImageBuffer,
  ret: vk.Result,
) {
  handle, texture = alloc(&manager.image_2d_buffers)
  width, height, c_in_file: c.int
  path_cstr := strings.clone_to_cstring(path)
  pixels := stbi.load(path_cstr, &width, &height, &c_in_file, 4)
  if pixels == nil {
    log.errorf(
      "Failed to load texture from path '%s': %s\n",
      path,
      stbi.failure_reason(),
    )
    ret = .ERROR_UNKNOWN
    return handle, texture, ret
  }
  defer stbi.image_free(pixels)
  num_pixels := int(width * height * 4)
  texture^ = gpu.create_image_buffer(
    gpu_context,
    pixels,
    size_of(u8) * vk.DeviceSize(num_pixels),
    .R8G8B8A8_SRGB,
    u32(width),
    u32(height),
  ) or_return
  set_texture_2d_descriptor(gpu_context, manager, handle.index, texture.view)
  ret = .SUCCESS
  return handle, texture, ret
}

create_hdr_texture_from_path :: proc(
  gpu_context: ^gpu.GPUContext,
  manager: ^Manager,
  path: string,
) -> (
  handle: Handle,
  texture: ^gpu.ImageBuffer,
  ret: vk.Result,
) {
  handle, texture = alloc(&manager.image_2d_buffers)
  path_cstr := strings.clone_to_cstring(path)
  width, height, c_in_file: c.int
  actual_channels: c.int = 4 // we always want RGBA for HDR
  float_pixels := stbi.loadf(
    path_cstr,
    &width,
    &height,
    &c_in_file,
    actual_channels,
  )
  if float_pixels == nil {
    log.errorf(
      "Failed to load HDR texture from path '%s': %s\n",
      path,
      stbi.failure_reason(),
    )
    ret = .ERROR_UNKNOWN
    return handle, texture, ret
  }
  defer stbi.image_free(float_pixels)
  num_floats := int(width * height * actual_channels)
  texture^ = gpu.create_image_buffer(
    gpu_context,
    float_pixels,
    size_of(f32) * vk.DeviceSize(num_floats),
    .R32G32B32A32_SFLOAT,
    u32(width),
    u32(height),
  ) or_return
  set_texture_2d_descriptor(gpu_context, manager, handle.index, texture.view)
  ret = .SUCCESS
  return handle, texture, ret
}

create_texture_from_pixels :: proc(
  gpu_context: ^gpu.GPUContext,
  manager: ^Manager,
  pixels: []u8,
  width: int,
  height: int,
  channel: int,
  format: vk.Format = .R8G8B8A8_SRGB,
) -> (
  handle: Handle,
  texture: ^gpu.ImageBuffer,
  ret: vk.Result,
) {
  handle, texture = alloc(&manager.image_2d_buffers)
  texture^ = gpu.create_image_buffer(
    gpu_context,
    raw_data(pixels),
    size_of(u8) * vk.DeviceSize(len(pixels)),
    format,
    u32(width),
    u32(height),
  ) or_return
  log.infof(
    "created texture %d x %d -> id %d",
    texture.width,
    texture.height,
    texture.image,
  )
  set_texture_2d_descriptor(gpu_context, manager, handle.index, texture.view)
  ret = .SUCCESS
  return
}

create_texture_from_data :: proc(
  gpu_context: ^gpu.GPUContext,
  manager: ^Manager,
  data: []u8,
) -> (
  handle: Handle,
  texture: ^gpu.ImageBuffer,
  ret: vk.Result,
) {
  handle, texture = alloc(&manager.image_2d_buffers)
  width, height, ch: c.int
  actual_channels: c.int = 4
  pixels := stbi.load_from_memory(
    raw_data(data),
    c.int(len(data)),
    &width,
    &height,
    &ch,
    actual_channels,
  )
  if pixels == nil {
    log.errorf("Failed to load texture from data: %s\n", stbi.failure_reason())
    ret = .ERROR_UNKNOWN
    return
  }
  bytes_count := int(width * height * actual_channels)
  format: vk.Format
  // for simplicity, we assume the data is in sRGB format
  if actual_channels == 4 {
    format = vk.Format.R8G8B8A8_SRGB
  } else if actual_channels == 3 {
    format = vk.Format.R8G8B8_SRGB
  } else if actual_channels == 1 {
    format = vk.Format.R8_SRGB
  }
  texture^ = gpu.create_image_buffer(
    gpu_context,
    pixels,
    size_of(u8) * vk.DeviceSize(bytes_count),
    format,
    u32(width),
    u32(height),
  ) or_return
  log.infof(
    "created texture %d x %d -> id %d",
    texture.width,
    texture.height,
    texture.image,
  )
  set_texture_2d_descriptor(gpu_context, manager, handle.index, texture.view)
  ret = .SUCCESS
  return
}

// Calculate number of mip levels for a given texture size
calculate_mip_levels :: proc(width, height: u32) -> f32 {
  return linalg.floor(linalg.log2(f32(max(width, height)))) + 1
}

// Create image buffer with mip maps
create_image_buffer_with_mips :: proc(
  gpu_context: ^gpu.GPUContext,
  data: rawptr,
  size: vk.DeviceSize,
  format: vk.Format,
  width, height: u32,
) -> (
  img: gpu.ImageBuffer,
  ret: vk.Result,
) {
  mip_levels := u32(calculate_mip_levels(width, height))
  staging := gpu.create_host_visible_buffer(
    gpu_context,
    u8,
    int(size),
    {.TRANSFER_SRC},
    data,
  ) or_return
  defer gpu.data_buffer_destroy(gpu_context.device, &staging)

  img = gpu.malloc_image_buffer_with_mips(
    gpu_context,
    width,
    height,
    format,
    .OPTIMAL,
    {.TRANSFER_DST, .SAMPLED, .TRANSFER_SRC},
    {.DEVICE_LOCAL},
    mip_levels,
  ) or_return

  gpu.copy_image_for_mips(gpu_context, img, staging) or_return
  gpu.generate_mipmaps(
    gpu_context,
    img,
    format,
    width,
    height,
    mip_levels,
  ) or_return

  aspect_mask := vk.ImageAspectFlags{.COLOR}
  img.view = gpu.create_image_view_with_mips(
    gpu_context.device,
    img.image,
    format,
    aspect_mask,
    mip_levels,
  ) or_return
  ret = .SUCCESS
  return
}

// Create HDR texture with mip maps
create_hdr_texture_from_path_with_mips :: proc(
  gpu_context: ^gpu.GPUContext,
  manager: ^Manager,
  path: string,
) -> (
  handle: Handle,
  texture: ^gpu.ImageBuffer,
  ret: vk.Result,
) {
  handle, texture = alloc(&manager.image_2d_buffers)
  path_cstr := strings.clone_to_cstring(path)
  width, height, c_in_file: c.int
  actual_channels: c.int = 4 // we always want RGBA for HDR
  float_pixels := stbi.loadf(
    path_cstr,
    &width,
    &height,
    &c_in_file,
    actual_channels,
  )
  if float_pixels == nil {
    log.errorf(
      "Failed to load HDR texture from path '%s': %s\n",
      path,
      stbi.failure_reason(),
    )
    ret = .ERROR_UNKNOWN
    return handle, texture, ret
  }
  defer stbi.image_free(float_pixels)
  num_floats := int(width * height * actual_channels)
  texture^ = create_image_buffer_with_mips(
    gpu_context,
    float_pixels,
    size_of(f32) * vk.DeviceSize(num_floats),
    .R32G32B32A32_SFLOAT,
    u32(width),
    u32(height),
  ) or_return
  set_texture_2d_descriptor(gpu_context, manager, handle.index, texture.view)
  ret = .SUCCESS
  return handle, texture, ret
}

// Handle-only variants for texture creation procedures
create_texture_handle :: proc {
  create_empty_texture_2d_handle,
  create_texture_from_path_handle,
  create_texture_from_data_handle,
  create_texture_from_pixels_handle,
}

create_empty_texture_2d_handle :: proc(
  gpu_context: ^gpu.GPUContext,
  manager: ^Manager,
  width, height: u32,
  format: vk.Format,
  usage: vk.ImageUsageFlags = {.COLOR_ATTACHMENT, .SAMPLED},
) -> (
  handle: Handle,
  ok: bool,
) #optional_ok {
  h, _, ret := create_empty_texture_2d(
    gpu_context,
    manager,
    width,
    height,
    format,
    usage,
  )
  return h, ret == .SUCCESS
}

create_texture_from_path_handle :: proc(
  gpu_context: ^gpu.GPUContext,
  manager: ^Manager,
  path: string,
) -> (
  handle: Handle,
  ok: bool,
) #optional_ok {
  h, _, ret := create_texture_from_path(gpu_context, manager, path)
  return h, ret == .SUCCESS
}

create_texture_from_data_handle :: proc(
  gpu_context: ^gpu.GPUContext,
  manager: ^Manager,
  data: []u8,
) -> (
  handle: Handle,
  ok: bool,
) #optional_ok {
  h, _, ret := create_texture_from_data(gpu_context, manager, data)
  return h, ret == .SUCCESS
}

create_texture_from_pixels_handle :: proc(
  gpu_context: ^gpu.GPUContext,
  manager: ^Manager,
  pixels: []u8,
  width: int,
  height: int,
  channel: int,
  format: vk.Format = .R8G8B8A8_SRGB,
) -> (
  handle: Handle,
  ok: bool,
) #optional_ok {
  h, _, ret := create_texture_from_pixels(
    gpu_context,
    manager,
    pixels,
    width,
    height,
    channel,
    format,
  )
  return h, ret == .SUCCESS
}

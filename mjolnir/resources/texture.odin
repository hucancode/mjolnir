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
  ok: bool
  handle, texture, ok = alloc(&manager.image_2d_buffers)
  if !ok {
    log.error("Failed to allocate 2D texture: pool capacity reached")
    return Handle{}, nil, .ERROR_OUT_OF_DEVICE_MEMORY
  }
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
  ok: bool
  handle, texture, ok = alloc(&manager.image_cube_buffers)
  if !ok {
    log.error("Failed to allocate cube texture: pool capacity reached")
    return Handle{}, nil, .ERROR_OUT_OF_DEVICE_MEMORY
  }
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
  format: vk.Format = .R8G8B8A8_SRGB,
  generate_mips := false,
  usage: vk.ImageUsageFlags = {.SAMPLED},
  is_hdr := false,
) -> (
  handle: Handle,
  texture: ^gpu.ImageBuffer,
  ret: vk.Result,
) {
  ok: bool
  handle, texture, ok = alloc(&manager.image_2d_buffers)
  if !ok {
    log.error("Failed to allocate texture from path: pool capacity reached")
    return Handle{}, nil, .ERROR_OUT_OF_DEVICE_MEMORY
  }
  path_cstr := strings.clone_to_cstring(path)
  width, height, c_in_file: c.int

  if is_hdr {
    actual_channels: c.int = 4
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

    if generate_mips {
      texture^ = create_image_buffer_with_mips(
        gpu_context,
        float_pixels,
        size_of(f32) * vk.DeviceSize(num_floats),
        format,
        u32(width),
        u32(height),
      ) or_return
    } else {
      texture^ = gpu.create_image_buffer(
        gpu_context,
        float_pixels,
        size_of(f32) * vk.DeviceSize(num_floats),
        format,
        u32(width),
        u32(height),
      ) or_return
    }
  } else {
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

    if generate_mips {
      texture^ = create_image_buffer_with_mips(
        gpu_context,
        pixels,
        size_of(u8) * vk.DeviceSize(num_pixels),
        format,
        u32(width),
        u32(height),
      ) or_return
    } else {
      texture^ = gpu.create_image_buffer(
        gpu_context,
        pixels,
        size_of(u8) * vk.DeviceSize(num_pixels),
        format,
        u32(width),
        u32(height),
      ) or_return
    }
  }

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
  format: vk.Format = .R8G8B8A8_SRGB,
  generate_mips := false,
) -> (
  handle: Handle,
  texture: ^gpu.ImageBuffer,
  ret: vk.Result,
) {
  ok: bool
  handle, texture, ok = alloc(&manager.image_2d_buffers)
  if !ok {
    log.error("Failed to allocate texture from pixels: pool capacity reached")
    return Handle{}, nil, .ERROR_OUT_OF_DEVICE_MEMORY
  }

  if generate_mips {
    texture^ = create_image_buffer_with_mips(
      gpu_context,
      raw_data(pixels),
      size_of(u8) * vk.DeviceSize(len(pixels)),
      format,
      u32(width),
      u32(height),
    ) or_return
  } else {
    texture^ = gpu.create_image_buffer(
      gpu_context,
      raw_data(pixels),
      size_of(u8) * vk.DeviceSize(len(pixels)),
      format,
      u32(width),
      u32(height),
    ) or_return
  }

  log.debugf(
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
  format: vk.Format = .R8G8B8A8_SRGB,
  generate_mips := false,
) -> (
  handle: Handle,
  texture: ^gpu.ImageBuffer,
  ret: vk.Result,
) {
  ok: bool
  handle, texture, ok = alloc(&manager.image_2d_buffers)
  if !ok {
    log.error("Failed to allocate texture from data: pool capacity reached")
    return Handle{}, nil, .ERROR_OUT_OF_DEVICE_MEMORY
  }
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
  defer stbi.image_free(pixels)
  bytes_count := int(width * height * actual_channels)

  if generate_mips {
    texture^ = create_image_buffer_with_mips(
      gpu_context,
      pixels,
      size_of(u8) * vk.DeviceSize(bytes_count),
      format,
      u32(width),
      u32(height),
    ) or_return
  } else {
    texture^ = gpu.create_image_buffer(
      gpu_context,
      pixels,
      size_of(u8) * vk.DeviceSize(bytes_count),
      format,
      u32(width),
      u32(height),
    ) or_return
  }

  log.debugf(
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
  staging := gpu.create_mutable_buffer(
    gpu_context,
    u8,
    int(size),
    {.TRANSFER_SRC},
    data,
  ) or_return
  defer gpu.mutable_buffer_destroy(gpu_context.device, &staging)

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
  format: vk.Format = .R8G8B8A8_SRGB,
  generate_mips := false,
  usage: vk.ImageUsageFlags = {.SAMPLED},
  is_hdr := false,
) -> (
  handle: Handle,
  ok: bool,
) #optional_ok {
  h, _, ret := create_texture_from_path(gpu_context, manager, path, format, generate_mips, usage, is_hdr)
  return h, ret == .SUCCESS
}

create_texture_from_data_handle :: proc(
  gpu_context: ^gpu.GPUContext,
  manager: ^Manager,
  data: []u8,
  format: vk.Format = .R8G8B8A8_SRGB,
  generate_mips := false,
) -> (
  handle: Handle,
  ok: bool,
) #optional_ok {
  h, _, ret := create_texture_from_data(gpu_context, manager, data, format, generate_mips)
  return h, ret == .SUCCESS
}

create_texture_from_pixels_handle :: proc(
  gpu_context: ^gpu.GPUContext,
  manager: ^Manager,
  pixels: []u8,
  width: int,
  height: int,
  format: vk.Format = .R8G8B8A8_SRGB,
  generate_mips := false,
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
    format,
    generate_mips,
  )
  return h, ret == .SUCCESS
}

// Texture update operations
update_texture :: proc(
  gpu_context: ^gpu.GPUContext,
  texture: ^gpu.ImageBuffer,
  pixels: rawptr,
  size: vk.DeviceSize,
  x: u32 = 0,
  y: u32 = 0,
  width: u32 = 0,
  height: u32 = 0,
  old_layout: vk.ImageLayout = .SHADER_READ_ONLY_OPTIMAL,
  new_layout: vk.ImageLayout = .SHADER_READ_ONLY_OPTIMAL,
) -> vk.Result {
  w := width if width > 0 else texture.width
  h := height if height > 0 else texture.height

  staging := gpu.create_mutable_buffer(
    gpu_context,
    u8,
    int(size),
    {.TRANSFER_SRC},
    pixels,
  ) or_return
  defer gpu.mutable_buffer_destroy(gpu_context.device, &staging)

  cmd_buffer := gpu.begin_single_time_command(gpu_context) or_return

  gpu.transition_image(
    cmd_buffer,
    texture.image,
    old_layout,
    .TRANSFER_DST_OPTIMAL,
    {.COLOR},
    {.FRAGMENT_SHADER},
    {.TRANSFER},
    {.SHADER_READ},
    {.TRANSFER_WRITE},
  )

  region := vk.BufferImageCopy {
    bufferOffset = 0,
    bufferRowLength = 0,
    bufferImageHeight = 0,
    imageSubresource = {
      aspectMask = {.COLOR},
      mipLevel = 0,
      baseArrayLayer = 0,
      layerCount = 1,
    },
    imageOffset = {i32(x), i32(y), 0},
    imageExtent = {w, h, 1},
  }

  vk.CmdCopyBufferToImage(
    cmd_buffer,
    staging.buffer,
    texture.image,
    .TRANSFER_DST_OPTIMAL,
    1,
    &region,
  )

  gpu.transition_image(
    cmd_buffer,
    texture.image,
    .TRANSFER_DST_OPTIMAL,
    new_layout,
    {.COLOR},
    {.TRANSFER},
    {.FRAGMENT_SHADER},
    {.TRANSFER_WRITE},
    {.SHADER_READ},
  )

  return gpu.end_single_time_command(gpu_context, &cmd_buffer)
}

copy_texture :: proc(
  gpu_context: ^gpu.GPUContext,
  src, dst: ^gpu.ImageBuffer,
  src_x: u32 = 0,
  src_y: u32 = 0,
  dst_x: u32 = 0,
  dst_y: u32 = 0,
  width: u32 = 0,
  height: u32 = 0,
  src_old_layout: vk.ImageLayout = .SHADER_READ_ONLY_OPTIMAL,
  src_new_layout: vk.ImageLayout = .SHADER_READ_ONLY_OPTIMAL,
  dst_old_layout: vk.ImageLayout = .SHADER_READ_ONLY_OPTIMAL,
  dst_new_layout: vk.ImageLayout = .SHADER_READ_ONLY_OPTIMAL,
) -> vk.Result {
  w := width if width > 0 else min(src.width, dst.width)
  h := height if height > 0 else min(src.height, dst.height)

  cmd_buffer := gpu.begin_single_time_command(gpu_context) or_return

  gpu.transition_image(
    cmd_buffer,
    src.image,
    src_old_layout,
    .TRANSFER_SRC_OPTIMAL,
    {.COLOR},
    {.FRAGMENT_SHADER},
    {.TRANSFER},
    {.SHADER_READ},
    {.TRANSFER_READ},
  )

  gpu.transition_image(
    cmd_buffer,
    dst.image,
    dst_old_layout,
    .TRANSFER_DST_OPTIMAL,
    {.COLOR},
    {.FRAGMENT_SHADER},
    {.TRANSFER},
    {.SHADER_READ},
    {.TRANSFER_WRITE},
  )

  region := vk.ImageCopy {
    srcSubresource = {
      aspectMask = {.COLOR},
      mipLevel = 0,
      baseArrayLayer = 0,
      layerCount = 1,
    },
    srcOffset = {i32(src_x), i32(src_y), 0},
    dstSubresource = {
      aspectMask = {.COLOR},
      mipLevel = 0,
      baseArrayLayer = 0,
      layerCount = 1,
    },
    dstOffset = {i32(dst_x), i32(dst_y), 0},
    extent = {w, h, 1},
  }

  vk.CmdCopyImage(
    cmd_buffer,
    src.image,
    .TRANSFER_SRC_OPTIMAL,
    dst.image,
    .TRANSFER_DST_OPTIMAL,
    1,
    &region,
  )

  gpu.transition_image(
    cmd_buffer,
    src.image,
    .TRANSFER_SRC_OPTIMAL,
    src_new_layout,
    {.COLOR},
    {.TRANSFER},
    {.FRAGMENT_SHADER},
    {.TRANSFER_READ},
    {.SHADER_READ},
  )

  gpu.transition_image(
    cmd_buffer,
    dst.image,
    .TRANSFER_DST_OPTIMAL,
    dst_new_layout,
    {.COLOR},
    {.TRANSFER},
    {.FRAGMENT_SHADER},
    {.TRANSFER_WRITE},
    {.SHADER_READ},
  )

  return gpu.end_single_time_command(gpu_context, &cmd_buffer)
}

// Convenience texture generators
create_solid_color_texture :: proc(
  gpu_context: ^gpu.GPUContext,
  manager: ^Manager,
  color: [4]u8,
  width: u32 = 1,
  height: u32 = 1,
) -> (
  handle: Handle,
  texture: ^gpu.ImageBuffer,
  ret: vk.Result,
) {
  pixel_count := int(width * height)
  pixels := make([]u8, pixel_count * 4)
  defer delete(pixels)

  for i in 0..<pixel_count {
    pixels[i*4+0] = color[0]
    pixels[i*4+1] = color[1]
    pixels[i*4+2] = color[2]
    pixels[i*4+3] = color[3]
  }

  return create_texture_from_pixels(
    gpu_context,
    manager,
    pixels,
    int(width),
    int(height),
  )
}

create_checkerboard_texture :: proc(
  gpu_context: ^gpu.GPUContext,
  manager: ^Manager,
  color_a: [4]u8 = {255, 255, 255, 255},
  color_b: [4]u8 = {0, 0, 0, 255},
  size: u32 = 64,
  checker_size: u32 = 8,
) -> (
  handle: Handle,
  texture: ^gpu.ImageBuffer,
  ret: vk.Result,
) {
  pixel_count := int(size * size)
  pixels := make([]u8, pixel_count * 4)
  defer delete(pixels)

  for y in 0..<size {
    for x in 0..<size {
      checker_x := (x / checker_size) % 2
      checker_y := (y / checker_size) % 2
      use_a := (checker_x == checker_y)
      color := color_a if use_a else color_b

      idx := int(y * size + x) * 4
      pixels[idx+0] = color[0]
      pixels[idx+1] = color[1]
      pixels[idx+2] = color[2]
      pixels[idx+3] = color[3]
    }
  }

  return create_texture_from_pixels(
    gpu_context,
    manager,
    pixels,
    int(size),
    int(size),
  )
}

// Texture metadata queries
get_texture_size :: proc(texture: ^gpu.ImageBuffer) -> (width: u32, height: u32) {
  return texture.width, texture.height
}

get_texture_format :: proc(texture: ^gpu.ImageBuffer) -> vk.Format {
  return texture.format
}

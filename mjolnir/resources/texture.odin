package resources

import cont "../containers"
import "../gpu"
import "core:c"
import "core:log"
import "core:strings"
import stbi "vendor:stb/image"
import vk "vendor:vulkan"

create_empty_texture_2d :: proc(
  gctx: ^gpu.GPUContext,
  rm: ^Manager,
  width, height: u32,
  format: vk.Format,
  usage: vk.ImageUsageFlags = {.COLOR_ATTACHMENT, .SAMPLED},
  auto_purge := false,
) -> (
  handle: Image2DHandle,
  ret: vk.Result,
) {
  ok: bool
  texture: ^gpu.Image
  handle, texture, ok = cont.alloc(&rm.images_2d, Image2DHandle)
  if !ok {
    log.error("Failed to allocate 2D texture: pool capacity reached")
    return Image2DHandle{}, .ERROR_OUT_OF_DEVICE_MEMORY
  }
  spec := gpu.image_spec_2d(width, height, format, usage)
  texture^ = gpu.image_create(gctx, spec) or_return
  texture.auto_purge = auto_purge
  set_texture_2d_descriptor(gctx, rm, handle.index, texture.view)
  log.debugf("Created empty texture %dx%d %v", width, height, format)
  return handle, .SUCCESS
}

create_empty_texture_cube :: proc(
  gctx: ^gpu.GPUContext,
  rm: ^Manager,
  size: u32,
  format: vk.Format = .D32_SFLOAT,
  usage: vk.ImageUsageFlags = {.DEPTH_STENCIL_ATTACHMENT, .SAMPLED},
  auto_purge := false,
) -> (
  handle: ImageCubeHandle,
  ret: vk.Result,
) {
  ok: bool
  texture: ^gpu.CubeImage
  handle, texture, ok = cont.alloc(&rm.images_cube, ImageCubeHandle)
  if !ok {
    log.error("Failed to allocate cube texture: pool capacity reached")
    return ImageCubeHandle{}, .ERROR_OUT_OF_DEVICE_MEMORY
  }
  spec := gpu.image_spec_cube(size, format, usage)
  texture.base = gpu.image_create(gctx, spec) or_return
  texture.base.auto_purge = auto_purge
  // Create 6 face views for rendering
  for i in 0 ..< 6 {
    texture.face_views[i] = gpu.image_create_view(
      gctx.device,
      &texture.base,
      .D2,
      0, // base_mip
      1, // mip_count
      u32(i), // base_layer (face index)
      1, // layer_count
    ) or_return
  }
  set_texture_cube_descriptor(gctx, rm, handle.index, texture.view)
  log.debugf("Created cube texture %dx%d", size, size)
  return handle, .SUCCESS
}

create_texture_from_path :: proc(
  gctx: ^gpu.GPUContext,
  rm: ^Manager,
  path: string,
  format: vk.Format = .R8G8B8A8_SRGB,
  generate_mips := false,
  usage: vk.ImageUsageFlags = {.SAMPLED},
  is_hdr := false,
) -> (
  handle: Image2DHandle,
  ret: vk.Result,
) {
  ok: bool
  texture: ^gpu.Image
  handle, texture, ok = cont.alloc(&rm.images_2d, Image2DHandle)
  if !ok {
    log.error("Failed to allocate texture from path: pool capacity reached")
    return Image2DHandle{}, .ERROR_OUT_OF_DEVICE_MEMORY
  }
  path_cstr := strings.clone_to_cstring(path)
  defer delete(path_cstr)
  width, height, channels: c.int
  pixel_data: rawptr
  data_size: vk.DeviceSize
  if is_hdr {
    pixels := stbi.loadf(path_cstr, &width, &height, &channels, 4)
    if pixels == nil {
      log.errorf(
        "Failed to load HDR texture '%s': %s",
        path,
        stbi.failure_reason(),
      )
      return handle, .ERROR_UNKNOWN
    }
    pixel_data = pixels
    data_size = vk.DeviceSize(width * height * 4 * size_of(f32))
  } else {
    pixels := stbi.load(path_cstr, &width, &height, &channels, 4)
    if pixels == nil {
      log.errorf(
        "Failed to load texture '%s': %s",
        path,
        stbi.failure_reason(),
      )
      return handle, .ERROR_UNKNOWN
    }
    pixel_data = pixels
    data_size = vk.DeviceSize(width * height * 4)
  }
  defer stbi.image_free(pixel_data)
  spec := gpu.image_spec_2d(
    u32(width),
    u32(height),
    format,
    usage,
    generate_mips,
  )
  if generate_mips {
    texture^ = gpu.image_create_with_mipmaps(
      gctx,
      spec,
      pixel_data,
      data_size,
    ) or_return
  } else {
    texture^ = gpu.image_create_with_data(
      gctx,
      spec,
      pixel_data,
      data_size,
    ) or_return
  }
  set_texture_2d_descriptor(gctx, rm, handle.index, texture.view)
  log.debugf("Created texture from path: %s (%dx%d)", path, width, height)
  return handle, .SUCCESS
}

create_texture_from_pixels :: proc(
  gctx: ^gpu.GPUContext,
  rm: ^Manager,
  pixels: []u8,
  width, height: int,
  format: vk.Format = .R8G8B8A8_SRGB,
  generate_mips := false,
) -> (
  handle: Image2DHandle,
  ret: vk.Result,
) {
  ok: bool
  texture: ^gpu.Image
  handle, texture, ok = cont.alloc(&rm.images_2d, Image2DHandle)
  if !ok {
    log.error("Failed to allocate texture from pixels: pool capacity reached")
    return Image2DHandle{}, .ERROR_OUT_OF_DEVICE_MEMORY
  }
  spec := gpu.image_spec_2d(
    u32(width),
    u32(height),
    format,
    {.SAMPLED},
    generate_mips,
  )
  if generate_mips {
    texture^ = gpu.image_create_with_mipmaps(
      gctx,
      spec,
      raw_data(pixels),
      vk.DeviceSize(len(pixels)),
    ) or_return
  } else {
    texture^ = gpu.image_create_with_data(
      gctx,
      spec,
      raw_data(pixels),
      vk.DeviceSize(len(pixels)),
    ) or_return
  }
  set_texture_2d_descriptor(gctx, rm, handle.index, texture.view)
  log.debugf("Created texture from pixels (%dx%d)", width, height)
  return handle, .SUCCESS
}

// Create texture from compressed data (PNG, JPG, etc.)
create_texture_from_data :: proc(
  gctx: ^gpu.GPUContext,
  rm: ^Manager,
  data: []u8,
  format: vk.Format = .R8G8B8A8_SRGB,
  generate_mips := false,
) -> (
  handle: Image2DHandle,
  ret: vk.Result,
) {
  ok: bool
  texture: ^gpu.Image
  handle, texture, ok = cont.alloc(&rm.images_2d, Image2DHandle)
  if !ok {
    log.error("Failed to allocate texture from data: pool capacity reached")
    return Image2DHandle{}, .ERROR_OUT_OF_DEVICE_MEMORY
  }
  width, height, channels: c.int
  pixels := stbi.load_from_memory(
    raw_data(data),
    c.int(len(data)),
    &width,
    &height,
    &channels,
    4,
  )
  if pixels == nil {
    log.errorf("Failed to decode texture data: %s", stbi.failure_reason())
    return handle, .ERROR_UNKNOWN
  }
  pixel_size := vk.DeviceSize(width * height * 4)
  spec := gpu.image_spec_2d(
    u32(width),
    u32(height),
    format,
    {.SAMPLED},
    generate_mips,
  )
  if generate_mips {
    texture^ = gpu.image_create_with_mipmaps(
      gctx,
      spec,
      pixels,
      pixel_size,
    ) or_return
  } else {
    texture^ = gpu.image_create_with_data(
      gctx,
      spec,
      pixels,
      pixel_size,
    ) or_return
  }
  stbi.image_free(pixels)
  set_texture_2d_descriptor(gctx, rm, handle.index, texture.view)
  log.debugf("Created texture from data (%dx%d)", width, height)
  return handle, .SUCCESS
}

create_texture :: proc {
  create_empty_texture_2d,
  create_texture_from_path,
  create_texture_from_data,
  create_texture_from_pixels,
}

create_cube_texture :: proc {
  create_empty_texture_cube,
}

create_texture_handle :: proc {
  create_empty_texture_2d_handle,
  create_texture_from_path_handle,
  create_texture_from_data_handle,
  create_texture_from_pixels_handle,
}

create_empty_texture_2d_handle :: proc(
  gctx: ^gpu.GPUContext,
  rm: ^Manager,
  width, height: u32,
  format: vk.Format,
  usage: vk.ImageUsageFlags = {.COLOR_ATTACHMENT, .SAMPLED},
) -> (
  handle: Image2DHandle,
  ok: bool,
) #optional_ok {
  h, ret := create_empty_texture_2d(gctx, rm, width, height, format, usage)
  return h, ret == .SUCCESS
}

create_texture_from_path_handle :: proc(
  gctx: ^gpu.GPUContext,
  rm: ^Manager,
  path: string,
  format: vk.Format = .R8G8B8A8_SRGB,
  generate_mips := false,
  usage: vk.ImageUsageFlags = {.SAMPLED},
  is_hdr := false,
) -> (
  handle: Image2DHandle,
  ok: bool,
) #optional_ok {
  h, ret := create_texture_from_path(
    gctx,
    rm,
    path,
    format,
    generate_mips,
    usage,
    is_hdr,
  )
  return h, ret == .SUCCESS
}

create_texture_from_data_handle :: proc(
  gctx: ^gpu.GPUContext,
  rm: ^Manager,
  data: []u8,
  format: vk.Format = .R8G8B8A8_SRGB,
  generate_mips := false,
) -> (
  handle: Image2DHandle,
  ok: bool,
) #optional_ok {
  h, ret := create_texture_from_data(gctx, rm, data, format, generate_mips)
  return h, ret == .SUCCESS
}

create_texture_from_pixels_handle :: proc(
  gctx: ^gpu.GPUContext,
  rm: ^Manager,
  pixels: []u8,
  width, height: int,
  format: vk.Format = .R8G8B8A8_SRGB,
  generate_mips := false,
) -> (
  handle: Image2DHandle,
  ok: bool,
) #optional_ok {
  h, ret := create_texture_from_pixels(
    gctx,
    rm,
    pixels,
    width,
    height,
    format,
    generate_mips,
  )
  return h, ret == .SUCCESS
}

create_solid_color_texture :: proc(
  gctx: ^gpu.GPUContext,
  rm: ^Manager,
  color: [4]u8,
  width: u32 = 1,
  height: u32 = 1,
) -> (
  handle: Image2DHandle,
  ret: vk.Result,
) {
  pixel_count := int(width * height)
  pixels := make([]u8, pixel_count * 4)
  defer delete(pixels)
  for i in 0 ..< pixel_count {
    pixels[i * 4 + 0] = color[0]
    pixels[i * 4 + 1] = color[1]
    pixels[i * 4 + 2] = color[2]
    pixels[i * 4 + 3] = color[3]
  }
  return create_texture_from_pixels(gctx, rm, pixels, int(width), int(height))
}

create_checkerboard_texture :: proc(
  gctx: ^gpu.GPUContext,
  rm: ^Manager,
  color_a: [4]u8 = {255, 255, 255, 255},
  color_b: [4]u8 = {0, 0, 0, 255},
  size: u32 = 64,
  checker_size: u32 = 8,
) -> (
  handle: Image2DHandle,
  ret: vk.Result,
) {
  pixel_count := int(size * size)
  pixels := make([]u8, pixel_count * 4)
  defer delete(pixels)
  for y in 0 ..< size {
    for x in 0 ..< size {
      checker_x := (x / checker_size) % 2
      checker_y := (y / checker_size) % 2
      use_a := (checker_x == checker_y)
      color := color_a if use_a else color_b
      idx := int(y * size + x) * 4
      pixels[idx + 0] = color[0]
      pixels[idx + 1] = color[1]
      pixels[idx + 2] = color[2]
      pixels[idx + 3] = color[3]
    }
  }
  return create_texture_from_pixels(gctx, rm, pixels, int(size), int(size))
}

texture_2d_destroy :: proc(self: ^gpu.Image, device: vk.Device) {
  gpu.image_destroy(device, self)
}

texture_cube_destroy :: proc(self: ^gpu.CubeImage, device: vk.Device) {
  gpu.cube_depth_texture_destroy(device, self)
}

destroy_texture :: proc(device: vk.Device, rm: ^Manager, handle: Image2DHandle) {
  if texture := cont.get(rm.images_2d, handle); texture != nil {
    texture_2d_destroy(texture, device)
    cont.free(&rm.images_2d, handle)
  } else if cube_texture := cont.get(rm.images_cube, handle);
     cube_texture != nil {
    texture_cube_destroy(cube_texture, device)
    cont.free(&rm.images_cube, handle)
  }
}

set_texture_2d_descriptor :: proc(
  gctx: ^gpu.GPUContext,
  rm: ^Manager,
  index: u32,
  image_view: vk.ImageView,
) {
  if index >= MAX_TEXTURES {
    log.warnf("Index %d out of bounds for bindless textures", index)
    return
  }
  gpu.update_descriptor_set_array_offset(
    gctx,
    rm.textures_descriptor_set,
    0,
    index,
    {
      .SAMPLED_IMAGE,
      vk.DescriptorImageInfo {
        imageView = image_view,
        imageLayout = .SHADER_READ_ONLY_OPTIMAL,
      },
    },
  )
}

set_texture_cube_descriptor :: proc(
  gctx: ^gpu.GPUContext,
  rm: ^Manager,
  index: u32,
  image_view: vk.ImageView,
) {
  if index >= MAX_CUBE_TEXTURES {
    log.warnf("Index %d out of bounds for bindless cube textures", index)
    return
  }
  gpu.update_descriptor_set_array_offset(
    gctx,
    rm.textures_descriptor_set,
    2,
    index,
    {
      .SAMPLED_IMAGE,
      vk.DescriptorImageInfo {
        imageView = image_view,
        imageLayout = .SHADER_READ_ONLY_OPTIMAL,
      },
    },
  )
}

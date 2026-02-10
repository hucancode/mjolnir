package gpu

import d "../data"
import "core:log"
import vk "vendor:vulkan"
import stbi "vendor:stb/image"
import "core:c"
import "core:strings"

// TextureManager manages textures using simple dynamic arrays for bindless rendering.
// Handles are array indices, mapping directly to descriptor array indices.
TextureManager :: struct {
	images_2d:              [dynamic]Image,
	images_cube:            [dynamic]CubeImage,
	textures_descriptor_set: vk.DescriptorSet,
}

// Initialize the texture manager
texture_manager_init :: proc(
	tm: ^TextureManager,
	descriptor_set: vk.DescriptorSet,
	allocator := context.allocator,
) -> vk.Result {
	tm.textures_descriptor_set = descriptor_set
	tm.images_2d = make([dynamic]Image, 0, 256, allocator)
	tm.images_cube = make([dynamic]CubeImage, 0, 64, allocator)
	return .SUCCESS
}

// Shutdown and cleanup all resources
texture_manager_shutdown :: proc(tm: ^TextureManager, gctx: ^GPUContext) {
	// Free all 2D textures
	for &img, i in tm.images_2d {
		if img.image != 0 {
			image_destroy(gctx.device, &img)
		}
	}
	delete(tm.images_2d)
	// Free all cube textures
	for &img, i in tm.images_cube {
		if img.image != 0 {
			cube_depth_texture_destroy(gctx.device, &img)
		}
	}
	delete(tm.images_cube)
}

// Allocate a 2D texture with the given parameters
allocate_texture_2d :: proc(
	tm: ^TextureManager,
	gctx: ^GPUContext,
	width, height: u32,
	format: vk.Format,
	usage: vk.ImageUsageFlags,
	generate_mips: bool = false,
) -> (
	handle: d.Image2DHandle,
	ret: vk.Result,
) {
	spec := image_spec_2d(width, height, format, usage, generate_mips)
	img := image_create(gctx, spec) or_return
	// Find free slot or append
	index := u32(len(tm.images_2d))
	for &slot, i in tm.images_2d {
		if slot.image == 0 {
			index = u32(i)
			slot = img
			break
		}
	}
	if index == u32(len(tm.images_2d)) {
		append(&tm.images_2d, img)
	}
	// Update descriptor set
	set_texture_2d_descriptor(gctx, tm.textures_descriptor_set, index, img.view)
	handle = d.Image2DHandle{index = index}
	return handle, .SUCCESS
}

// Allocate a 2D texture with initial data
allocate_texture_2d_with_data :: proc(
	tm: ^TextureManager,
	gctx: ^GPUContext,
	pixel_data: rawptr,
	data_size: vk.DeviceSize,
	width, height: u32,
	format: vk.Format,
	usage: vk.ImageUsageFlags,
	generate_mips: bool = false,
) -> (
	handle: d.Image2DHandle,
	ret: vk.Result,
) {
	spec := image_spec_2d(width, height, format, usage, generate_mips)
	img: Image
	if generate_mips {
		img = image_create_with_mipmaps(gctx, spec, pixel_data, data_size) or_return
	} else {
		img = image_create_with_data(gctx, spec, pixel_data, data_size) or_return
	}
	// Find free slot or append
	index := u32(len(tm.images_2d))
	for &slot, i in tm.images_2d {
		if slot.image == 0 {
			index = u32(i)
			slot = img
			break
		}
	}
	if index == u32(len(tm.images_2d)) {
		append(&tm.images_2d, img)
	}
	// Update descriptor set
	set_texture_2d_descriptor(gctx, tm.textures_descriptor_set, index, img.view)
	handle = d.Image2DHandle{index = index}
	return handle, .SUCCESS
}

// Free a 2D texture
free_texture_2d :: proc(tm: ^TextureManager, gctx: ^GPUContext, handle: d.Image2DHandle) {
	if handle.index >= u32(len(tm.images_2d)) do return
	img := &tm.images_2d[handle.index]
	if img.image == 0 do return
	image_destroy(gctx.device, img)
	// Mark slot as free (zero out the image handle)
	img^ = {}
}

// Get a pointer to a 2D texture
get_texture_2d :: proc(tm: ^TextureManager, handle: d.Image2DHandle) -> ^Image {
	if handle.index >= u32(len(tm.images_2d)) do return nil
	img := &tm.images_2d[handle.index]
	if img.image == 0 do return nil
	return img
}

// Allocate a cube texture (typically used for depth cube maps)
allocate_texture_cube :: proc(
	tm: ^TextureManager,
	gctx: ^GPUContext,
	size: u32,
	format: vk.Format,
	usage: vk.ImageUsageFlags,
) -> (
	handle: d.ImageCubeHandle,
	ret: vk.Result,
) {
	// Find free slot or allocate new
	index := u32(len(tm.images_cube))
	img: ^CubeImage
	for &slot, i in tm.images_cube {
		if slot.image == 0 {
			index = u32(i)
			img = &slot
			break
		}
	}
	if img == nil {
		append(&tm.images_cube, CubeImage{})
		img = &tm.images_cube[len(tm.images_cube) - 1]
	}
	// Initialize the cube image
	cube_depth_texture_init(gctx, img, size, format, usage) or_return
	// Update descriptor set
	set_texture_cube_descriptor(gctx, tm.textures_descriptor_set, index, img.view)
	handle = d.ImageCubeHandle{index = index}
	return handle, .SUCCESS
}

// Free a cube texture
free_texture_cube :: proc(tm: ^TextureManager, gctx: ^GPUContext, handle: d.ImageCubeHandle) {
	if handle.index >= u32(len(tm.images_cube)) do return
	img := &tm.images_cube[handle.index]
	if img.image == 0 do return
	cube_depth_texture_destroy(gctx.device, img)
	// Mark slot as free
	img^ = {}
}

// Get a pointer to a cube texture
get_texture_cube :: proc(tm: ^TextureManager, handle: d.ImageCubeHandle) -> ^CubeImage {
	if handle.index >= u32(len(tm.images_cube)) do return nil
	img := &tm.images_cube[handle.index]
	if img.image == 0 do return nil
	return img
}

// Internal helper to update 2D texture descriptor
@(private)
set_texture_2d_descriptor :: proc(
	gctx: ^GPUContext,
	textures_descriptor_set: vk.DescriptorSet,
	index: u32,
	image_view: vk.ImageView,
) {
	if index >= d.MAX_TEXTURES do return
	if textures_descriptor_set == 0 do return
	update_descriptor_set_array_offset(
		gctx,
		textures_descriptor_set,
		0,
		index,
		{
			.SAMPLED_IMAGE,
			vk.DescriptorImageInfo{
				imageView = image_view,
				imageLayout = .SHADER_READ_ONLY_OPTIMAL,
			},
		},
	)
}

// Internal helper to update cube texture descriptor
@(private)
set_texture_cube_descriptor :: proc(
	gctx: ^GPUContext,
	textures_descriptor_set: vk.DescriptorSet,
	index: u32,
	image_view: vk.ImageView,
) {
	if index >= d.MAX_CUBE_TEXTURES do return
	if textures_descriptor_set == 0 do return
	update_descriptor_set_array_offset(
		gctx,
		textures_descriptor_set,
		2,
		index,
		{
			.SAMPLED_IMAGE,
			vk.DescriptorImageInfo{
				imageView = image_view,
				imageLayout = .SHADER_READ_ONLY_OPTIMAL,
			},
		},
	)
}

create_texture_2d_from_data :: proc(
  gctx: ^GPUContext,
  texture_manager: ^TextureManager,
  data: []u8,
  format: vk.Format = .R8G8B8A8_SRGB,
  generate_mips: bool = false,
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
  return allocate_texture_2d_with_data(
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
  gctx: ^GPUContext,
  texture_manager: ^TextureManager,
  path: string,
  format: vk.Format = .R8G8B8A8_SRGB,
  generate_mips: bool = false,
  usage: vk.ImageUsageFlags = {.SAMPLED},
  is_hdr: bool = false,
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
  return allocate_texture_2d_with_data(
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

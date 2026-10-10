package bindless

import cont "../../containers"
import "../gpu"
import "core:c"
import "core:log"
import "core:strings"
import stbi "vendor:stb/image"
import vk "vendor:vulkan"

MAX_TEXTURES :: 1000
MAX_CUBE_TEXTURES :: 200

// Bindings of the bindless set.
BINDING_TEXTURES :: 0 // [MAX_TEXTURES] 2D sampled images
BINDING_SAMPLERS :: 1 // one sampler per SamplerType
BINDING_CUBE_TEXTURES :: 2 // [MAX_CUBE_TEXTURES] cube sampled images
Texture2DHandle :: distinct cont.Handle
TextureCubeHandle :: distinct cont.Handle

// TextureManager manages textures with handle pools.
// Handle.index maps directly to descriptor array indices.
TextureManager :: struct {
  images_2d:               cont.Pool(gpu.Image),
  images_cube:             cont.Pool(gpu.CubeImage),
  set_layout:              vk.DescriptorSetLayout,
  descriptor_set: vk.DescriptorSet,
}

// Initialize the texture manager: creates the descriptor set layout.
// Must be called once at startup, before pipeline layouts are built.
texture_manager_init :: proc(self: ^TextureManager, gctx: ^gpu.GPUContext) -> vk.Result {
  self.set_layout = gpu.create_descriptor_array_layout(
    gctx,
    {.SAMPLED_IMAGE, MAX_TEXTURES, {.FRAGMENT}},
    {.SAMPLER, len(SamplerType), {.FRAGMENT}},
    {.SAMPLED_IMAGE, MAX_CUBE_TEXTURES, {.FRAGMENT}},
  ) or_return
  return .SUCCESS
}

// Setup the texture manager: allocates the descriptor set and writes sampler descriptors.
// Must be called each time the descriptor pool is (re)created.
texture_manager_setup :: proc(
  self: ^TextureManager,
  gctx: ^gpu.GPUContext,
  samplers: [SamplerType]vk.Sampler,
) -> vk.Result {
  // GPU images back descriptor slots the GPU samples for up to gpu.FRAMES_IN_FLIGHT
  // frames, so a freed slot/image must be retired, not reclaimed inline.
  cont.init(&self.images_2d, MAX_TEXTURES, gpu.FRAMES_IN_FLIGHT)
  cont.init(&self.images_cube, MAX_CUBE_TEXTURES, gpu.FRAMES_IN_FLIGHT)
  gpu.allocate_descriptor_set(gctx, &self.descriptor_set, &self.set_layout) or_return
  for sampler, type in samplers {
    gpu.write_descriptor_array_element(gctx, self.descriptor_set, BINDING_SAMPLERS, u32(type), .SAMPLER, {sampler = sampler})
  }
  return .SUCCESS
}

// Teardown the texture manager: destroys all GPU images and frees pool memory.
// The descriptor set handle is zeroed (bulk-freed by the caller via ResetDescriptorPool).
// Must be paired with texture_manager_setup.
@(private = "file")
retire_image_2d :: proc(img: ^gpu.Image, user: rawptr) {
  if img.image != 0 do gpu.image_destroy((^gpu.GPUContext)(user).device, img)
}

@(private = "file")
retire_image_cube :: proc(img: ^gpu.CubeImage, user: rawptr) {
  if img.image != 0 do gpu.cube_depth_texture_destroy((^gpu.GPUContext)(user).device, img)
}

// texture_manager_tick reclaims retired texture slots and destroys their vk
// images once no in-flight frame can still sample them. Call once per presented
// frame.
texture_manager_tick :: proc(self: ^TextureManager, gctx: ^gpu.GPUContext) {
  cont.tick(&self.images_2d, gctx, retire_image_2d)
  cont.tick(&self.images_cube, gctx, retire_image_cube)
}

texture_manager_teardown :: proc(self: ^TextureManager, gctx: ^gpu.GPUContext) {
  // Destroy any retired-but-not-yet-reclaimed images first; the caller has
  // already waited for the GPU to go idle, so grace no longer matters.
  cont.flush(&self.images_2d, gctx, retire_image_2d)
  cont.flush(&self.images_cube, gctx, retire_image_cube)
  for &entry in self.images_2d.entries do if entry.active {
    if entry.item.image != 0 do gpu.image_destroy(gctx.device, &entry.item)
  }
  for &entry in self.images_cube.entries do if entry.active {
    if entry.item.image != 0 do gpu.cube_depth_texture_destroy(gctx.device, &entry.item)
  }
  cont.destroy(&self.images_2d, proc(_: ^gpu.Image) {})
  cont.destroy(&self.images_cube, proc(_: ^gpu.CubeImage) {})
  self.images_2d = {}
  self.images_cube = {}
  self.descriptor_set = 0
}

// Shutdown the texture manager: destroys the descriptor set layout.
// Must be called once at gpu.shutdown, paired with texture_manager_init.
texture_manager_shutdown :: proc(self: ^TextureManager, gctx: ^gpu.GPUContext) {
  vk.DestroyDescriptorSetLayout(gctx.device, self.set_layout, nil)
  self.set_layout = 0
}

// Allocate a 2D texture with the given parameters
allocate_texture_2d :: proc(
  self: ^TextureManager,
  gctx: ^gpu.GPUContext,
  extent: vk.Extent2D,
  format: vk.Format,
  usage: vk.ImageUsageFlags,
  generate_mips: bool = false,
) -> (
  handle: Texture2DHandle,
  ret: vk.Result,
) {
  spec := gpu.image_spec_2d(extent, format, usage, generate_mips)
  img := gpu.image_create(gctx, spec) or_return
  gpu_handle, slot, ok := cont.alloc(&self.images_2d, Texture2DHandle)
  if !ok {
    gpu.image_destroy(gctx.device, &img)
    return {}, .ERROR_OUT_OF_DEVICE_MEMORY
  }
  slot^ = img
  // Update descriptor set
  write_texture_descriptor(gctx, self.descriptor_set, BINDING_TEXTURES, gpu_handle.index, img.view)
  return gpu_handle, .SUCCESS
}

// Allocate a 2D texture with initial data
allocate_texture_2d_with_data :: proc(
  tm: ^TextureManager,
  gctx: ^gpu.GPUContext,
  pixel_data: rawptr,
  data_size: vk.DeviceSize,
  extent: vk.Extent2D,
  format: vk.Format,
  usage: vk.ImageUsageFlags,
  generate_mips: bool = false,
) -> (
  handle: Texture2DHandle,
  ret: vk.Result,
) {
  spec := gpu.image_spec_2d(extent, format, usage, generate_mips)
  img: gpu.Image
  if generate_mips {
    img = gpu.image_create_with_mipmaps(
      gctx,
      spec,
      pixel_data,
      data_size,
    ) or_return
  } else {
    img = gpu.image_create_with_data(gctx, spec, pixel_data, data_size) or_return
  }
  gpu_handle, slot, ok := cont.alloc(&tm.images_2d, Texture2DHandle)
  if !ok {
    gpu.image_destroy(gctx.device, &img)
    return {}, .ERROR_OUT_OF_DEVICE_MEMORY
  }
  slot^ = img
  // Update descriptor set
  write_texture_descriptor(gctx, tm.descriptor_set, BINDING_TEXTURES, gpu_handle.index, img.view)
  return gpu_handle, .SUCCESS
}

// Free a 2D texture. The handle is invalidated immediately, but the slot and the
// underlying vk image are retired and destroyed by texture_manager_tick once no
// in-flight frame can still sample them.
free_texture_2d :: proc(tm: ^TextureManager, gctx: ^gpu.GPUContext, handle: $H) {
  gpu_handle := transmute(Texture2DHandle)handle
  cont.free_deferred(&tm.images_2d, gpu_handle)
}

// Get a pointer to a 2D texture
get_texture_2d :: proc(tm: ^TextureManager, handle: $H) -> ^gpu.Image {
  gpu_handle := transmute(Texture2DHandle)handle
  img, _ := cont.get(tm.images_2d, gpu_handle)
  return img
}

// Allocate a cube texture (typically used for depth cube maps)
allocate_texture_cube :: proc(
  tm: ^TextureManager,
  gctx: ^gpu.GPUContext,
  size: u32,
  format: vk.Format,
  usage: vk.ImageUsageFlags,
) -> (
  handle: TextureCubeHandle,
  ret: vk.Result,
) {
  h, img, ok := cont.alloc(&tm.images_cube, TextureCubeHandle)
  if !ok do return {}, .ERROR_OUT_OF_DEVICE_MEMORY
  // Initialize the cube image
  init_ret := gpu.cube_depth_texture_init(gctx, img, size, format, usage)
  if init_ret != .SUCCESS {
    cont.free(&tm.images_cube, h)
    return {}, init_ret
  }
  // Update descriptor set
  write_texture_descriptor(gctx, tm.descriptor_set, BINDING_CUBE_TEXTURES, h.index, img.view)
  return h, .SUCCESS
}

// Allocate a color cube texture (for IBL precompute outputs).
// Optionally creates mip chain and STORAGE usage for compute writes.
allocate_texture_cube_color :: proc(
  tm: ^TextureManager,
  gctx: ^gpu.GPUContext,
  size: u32,
  format: vk.Format,
  mip_levels: u32 = 1,
  usage: vk.ImageUsageFlags = {.SAMPLED, .STORAGE, .TRANSFER_DST},
) -> (
  handle: TextureCubeHandle,
  ret: vk.Result,
) {
  h, img, ok := cont.alloc(&tm.images_cube, TextureCubeHandle)
  if !ok do return {}, .ERROR_OUT_OF_DEVICE_MEMORY
  init_ret := gpu.cube_color_texture_init(gctx, img, size, format, mip_levels, usage)
  if init_ret != .SUCCESS {
    cont.free(&tm.images_cube, h)
    return {}, init_ret
  }
  write_texture_descriptor(gctx, tm.descriptor_set, BINDING_CUBE_TEXTURES, h.index, img.view)
  return h, .SUCCESS
}

// Free a cube texture. Retired and destroyed by texture_manager_tick — see
// free_texture_2d.
free_texture_cube :: proc(tm: ^TextureManager, gctx: ^gpu.GPUContext, handle: $H) {
  gpu_handle := transmute(TextureCubeHandle)handle
  cont.free_deferred(&tm.images_cube, gpu_handle)
}

// Get a pointer to a cube texture
get_texture_cube :: proc(tm: ^TextureManager, handle: $H) -> ^gpu.CubeImage {
  gpu_handle := transmute(TextureCubeHandle)handle
  img, _ := cont.get(tm.images_cube, gpu_handle)
  return img
}

@(private)
write_texture_descriptor :: proc(
  gctx: ^gpu.GPUContext,
  set: vk.DescriptorSet,
  binding, index: u32,
  view: vk.ImageView,
) {
  gpu.write_descriptor_array_element(gctx, set, binding, index, .SAMPLED_IMAGE, {imageView = view, imageLayout = .GENERAL})
}

create_texture_2d_from_data :: proc(
  gctx: ^gpu.GPUContext,
  texture_manager: ^TextureManager,
  data: []u8,
  format: vk.Format = .R8G8B8A8_SRGB,
  generate_mips: bool = false,
) -> (
  handle: Texture2DHandle,
  ret: vk.Result,
) {
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
    return {}, .ERROR_UNKNOWN
  }
  defer stbi.image_free(pixels)
  pixel_size := vk.DeviceSize(width * height * 4)
  return allocate_texture_2d_with_data(
    texture_manager,
    gctx,
    pixels,
    pixel_size,
    vk.Extent2D {u32(width), u32(height)},
    format,
    {.SAMPLED},
    generate_mips,
  )
}

create_texture_2d_from_path :: proc(
  gctx: ^gpu.GPUContext,
  texture_manager: ^TextureManager,
  path: string,
  format: vk.Format = .R8G8B8A8_SRGB,
  generate_mips: bool = false,
  usage: vk.ImageUsageFlags = {.SAMPLED},
  is_hdr: bool = false,
) -> (
  handle: Texture2DHandle,
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
      log.errorf(
        "Failed to load HDR texture '%s': %s",
        path,
        stbi.failure_reason(),
      )
      return {}, .ERROR_UNKNOWN
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
    vk.Extent2D {u32(width), u32(height)},
    format,
    usage,
    generate_mips,
  )
}

package gpu

import "core:log"
import "core:math"
import vk "vendor:vulkan"

// A device-local, optimal-tiling 2D or cube image with a view over every mip
// and layer.
Image :: struct {
  image:      vk.Image,
  memory:     vk.DeviceMemory,
  view:       vk.ImageView,
  extent:     vk.Extent2D,
  format:     vk.Format,
  mip_levels: u32,
  // array layers; six for a cube
  layers:     u32,
}

@(private)
infer_aspect_mask :: proc(format: vk.Format) -> vk.ImageAspectFlags {
  #partial switch format {
  case .D16_UNORM, .D32_SFLOAT, .X8_D24_UNORM_PACK32:
    return {.DEPTH}
  case .D16_UNORM_S8_UINT, .D24_UNORM_S8_UINT, .D32_SFLOAT_S8_UINT:
    return {.DEPTH, .STENCIL}
  case .S8_UINT:
    return {.STENCIL}
  case:
    return {.COLOR}
  }
}

// Full mip chain length for the given dimensions.
calculate_mip_levels :: proc(width, height: u32) -> u32 {
  return u32(math.floor(math.log2(f32(max(width, height))))) + 1
}

image_create :: proc(
  gctx: ^GPUContext,
  extent: vk.Extent2D,
  format: vk.Format,
  usage: vk.ImageUsageFlags,
  mip_levels: u32 = 1,
  // six layers viewed as a cube
  cube := false,
  // 2D layer count
  layers: u32 = 1,
  // view the 2D layers as an array, even when there is one
  array := false,
  // also accessed by the async compute queue
  shared := false,
  // channel remapping of the view; identity by default
  components: vk.ComponentMapping = {},
) -> (
  img: Image,
  ret: vk.Result,
) {
  assert(!cube || (layers == 1 && !array))
  assert(array || layers == 1)
  layers := u32(6) if cube else layers
  img = {
    extent     = extent,
    format     = format,
    mip_levels = mip_levels,
    layers     = layers,
  }
  view_type: vk.ImageViewType = .CUBE if cube else .D2_ARRAY if array else .D2
  create_info := vk.ImageCreateInfo {
    sType         = .IMAGE_CREATE_INFO,
    flags         = vk.ImageCreateFlags{.CUBE_COMPATIBLE} if cube else {},
    imageType     = .D2,
    extent        = {extent.width, extent.height, 1},
    mipLevels     = mip_levels,
    arrayLayers   = layers,
    format        = format,
    tiling        = .OPTIMAL,
    initialLayout = .UNDEFINED,
    usage         = usage,
    samples       = {._1},
  }
  families: [2]u32
  set_sharing(gctx, &create_info, shared, &families)
  vk.CreateImage(gctx.device, &create_info, nil, &img.image) or_return
  mem_reqs: vk.MemoryRequirements
  vk.GetImageMemoryRequirements(gctx.device, img.image, &mem_reqs)
  img.memory = allocate_memory(gctx, mem_reqs, {.DEVICE_LOCAL}) or_return
  vk.BindImageMemory(gctx.device, img.image, img.memory, 0) or_return
  img.view = image_create_view(
    gctx.device,
    &img,
    view_type,
    mip_count = mip_levels,
    layer_count = layers,
    components = components,
  ) or_return
  log.debugf(
    "Created image %v %dx%d (mips=%d, layers=%d) 0x%x",
    format,
    extent.width,
    extent.height,
    mip_levels,
    layers,
    img.image,
  )
  return img, .SUCCESS
}

image_create_view :: proc(
  device: vk.Device,
  img: ^Image,
  view_type: vk.ImageViewType,
  base_mip: u32 = 0,
  mip_count: u32 = 1,
  base_layer: u32 = 0,
  layer_count: u32 = 1,
  components: vk.ComponentMapping = {},
) -> (
  view: vk.ImageView,
  ret: vk.Result,
) {
  view_info := vk.ImageViewCreateInfo {
    sType = .IMAGE_VIEW_CREATE_INFO,
    image = img.image,
    viewType = view_type,
    format = img.format,
    components = components,
    subresourceRange = {
      aspectMask = infer_aspect_mask(img.format),
      baseMipLevel = base_mip,
      levelCount = mip_count,
      baseArrayLayer = base_layer,
      layerCount = layer_count,
    },
  }
  ret = vk.CreateImageView(device, &view_info, nil, &view)
  return
}

image_destroy :: proc(device: vk.Device, img: ^Image) {
  vk.DestroyImageView(device, img.view, nil)
  vk.DestroyImage(device, img.image, nil)
  vk.FreeMemory(device, img.memory, nil)
  img^ = {}
}

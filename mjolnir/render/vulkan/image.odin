#+private
package vulkan_backend

import "core:log"
import "../rhi"
import vk "vendor:vulkan"

// Image is a device-local, optimal-tiling 2D or cube image with a view over every mip and layer,
// made from desc (mip_levels and layers at least 1).
Image :: struct {
  image:  vk.Image,
  memory: Allocation,
  view:   vk.ImageView,
  desc:   rhi.TextureDesc,
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

// image_create allocates a device-local Image with a view of desc: mipmapped, a cube (six
// layers), or an array when it has more than one layer.
image_create :: proc(
  gctx: ^GPUContext,
  desc: rhi.TextureDesc,
  usage: vk.ImageUsageFlags,
  // channel remapping of the view; identity by default
  components: vk.ComponentMapping = {},
) -> (
  img: Image,
  ret: vk.Result,
) {
  img.desc = desc
  img.desc.mip_levels = max(desc.mip_levels, 1)
  img.desc.layers = max(desc.layers, 1)
  assert(!desc.cube || img.desc.layers == 1)
  layers := u32(6) if desc.cube else img.desc.layers
  format := FORMATS[desc.format]
  view_type: vk.ImageViewType = .CUBE if desc.cube else .D2_ARRAY if layers > 1 else .D2
  create_info := vk.ImageCreateInfo {
    sType         = .IMAGE_CREATE_INFO,
    flags         = vk.ImageCreateFlags{.CUBE_COMPATIBLE} if desc.cube else {},
    imageType     = .D2,
    extent        = {desc.extent.x, desc.extent.y, 1},
    mipLevels     = img.desc.mip_levels,
    arrayLayers   = layers,
    format        = format,
    tiling        = .OPTIMAL,
    initialLayout = .UNDEFINED,
    usage         = usage,
    samples       = {._1},
  }
  families: [2]u32
  set_sharing(gctx, &create_info, desc.shared, &families)
  vk.CreateImage(gctx.device, &create_info, nil, &img.image) or_return
  mem_reqs: vk.MemoryRequirements
  vk.GetImageMemoryRequirements(gctx.device, img.image, &mem_reqs)
  img.memory = memory_alloc(gctx, mem_reqs, {.DEVICE_LOCAL}, linear = false) or_return
  vk.BindImageMemory(gctx.device, img.image, allocation_memory(gctx, img.memory), img.memory.offset) or_return
  img.view = image_create_view(
    gctx.device,
    &img,
    view_type,
    mip_count = img.desc.mip_levels,
    layer_count = layers,
    components = components,
  ) or_return
  log.debugf(
    "Created image %v %dx%d (mips=%d, layers=%d) 0x%x",
    format,
    desc.extent.x,
    desc.extent.y,
    img.desc.mip_levels,
    layers,
    img.image,
  )
  return img, .SUCCESS
}

// image_create_view creates a view of img over the given mip and layer range.
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
    format = FORMATS[img.desc.format],
    components = components,
    subresourceRange = {
      aspectMask = infer_aspect_mask(FORMATS[img.desc.format]),
      baseMipLevel = base_mip,
      levelCount = mip_count,
      baseArrayLayer = base_layer,
      layerCount = layer_count,
    },
  }
  ret = vk.CreateImageView(device, &view_info, nil, &view)
  return
}

// image_destroy frees the view, image and memory of img.
image_destroy :: proc(gctx: ^GPUContext, img: ^Image) {
  vk.DestroyImageView(gctx.device, img.view, nil)
  vk.DestroyImage(gctx.device, img.image, nil)
  memory_free(gctx, &img.memory)
  img^ = {}
}

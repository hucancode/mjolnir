package gpu

import "core:log"
import "core:math"
import "core:mem"
import vk "vendor:vulkan"

// A device-local, optimal-tiling 2D or cube image with a view over every mip
// and layer. A cube image used as an attachment also gets one 2D view per
// face (+X, -X, +Y, -Y, +Z, -Z) to render into.
Image :: struct {
  image:      vk.Image,
  memory:     vk.DeviceMemory,
  view:       vk.ImageView,
  face_views: [6]vk.ImageView,
  extent:     vk.Extent2D,
  format:     vk.Format,
  mip_levels: u32,
  cube:       bool,
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
  cube := false,
  // also accessed by the async compute queue
  shared := false,
) -> (
  img: Image,
  ret: vk.Result,
) {
  img = {
    extent     = extent,
    format     = format,
    mip_levels = mip_levels,
    cube       = cube,
  }
  layers: u32 = 6 if cube else 1
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
    .CUBE if cube else .D2,
    mip_count = mip_levels,
    layer_count = layers,
  ) or_return
  if cube && usage & {.COLOR_ATTACHMENT, .DEPTH_STENCIL_ATTACHMENT} != {} {
    for &face_view, face in img.face_views {
      face_view = image_create_view(gctx.device, &img, .D2, base_layer = u32(face)) or_return
    }
  }
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

// Create a 2D image and fill mip 0 with `data`; with mip_levels > 1 the rest
// of the chain is blitted down from it.
image_create_with_data :: proc(
  gctx: ^GPUContext,
  extent: vk.Extent2D,
  format: vk.Format,
  usage: vk.ImageUsageFlags,
  data: rawptr,
  size: vk.DeviceSize,
  mip_levels: u32 = 1,
) -> (
  img: Image,
  ret: vk.Result,
) {
  img = image_create(
    gctx,
    extent,
    format,
    usage | {.TRANSFER_DST, .TRANSFER_SRC},
    mip_levels,
  ) or_return
  staging := create_mutable_buffer(gctx, u8, int(size), {.TRANSFER_SRC}) or_return
  defer mutable_buffer_destroy(gctx.device, &staging)
  mem.copy(staging.mapped, data, int(size))
  aspect := infer_aspect_mask(format)
  cmd := begin_single_time_command(gctx) or_return
  image_discard_barrier(
    cmd,
    img.image,
    {.TRANSFER_WRITE},
    {.TRANSFER},
    aspect,
    level_count = mip_levels,
  )
  region := vk.BufferImageCopy {
    imageSubresource = {aspectMask = aspect, layerCount = 1},
    imageExtent = {extent.width, extent.height, 1},
  }
  vk.CmdCopyBufferToImage(cmd, staging.buffer, img.image, .GENERAL, 1, &region)
  w, h := i32(extent.width), i32(extent.height)
  for i in 1 ..< mip_levels {
    // Previous mip's writes must land before this blit reads it
    memory_barrier(cmd, {.TRANSFER_WRITE}, {.TRANSFER_READ}, {.TRANSFER}, {.TRANSFER})
    blit := vk.ImageBlit {
      srcOffsets = {{0, 0, 0}, {w, h, 1}},
      srcSubresource = {aspectMask = aspect, mipLevel = i - 1, layerCount = 1},
      dstOffsets = {{0, 0, 0}, {max(w / 2, 1), max(h / 2, 1), 1}},
      dstSubresource = {aspectMask = aspect, mipLevel = i, layerCount = 1},
    }
    vk.CmdBlitImage(cmd, img.image, .GENERAL, img.image, .GENERAL, 1, &blit, .LINEAR)
    w, h = max(w / 2, 1), max(h / 2, 1)
  }
  // Make all mip writes visible to shader sampling
  memory_barrier(cmd, {.TRANSFER_WRITE}, {.SHADER_READ}, {.TRANSFER}, {.FRAGMENT_SHADER})
  end_single_time_command(gctx, &cmd) or_return
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
  for face_view in img.face_views do vk.DestroyImageView(device, face_view, nil)
  vk.DestroyImageView(device, img.view, nil)
  vk.DestroyImage(device, img.image, nil)
  vk.FreeMemory(device, img.memory, nil)
  img^ = {}
}

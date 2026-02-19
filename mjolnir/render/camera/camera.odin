package camera

import alg "../../algebra"
import "../../gpu"
import rd "../data"
import "core:log"
import "core:math"
import vk "vendor:vulkan"

FRAMES_IN_FLIGHT :: rd.FRAMES_IN_FLIGHT
MAX_DEPTH_MIPS_LEVEL :: 16

AttachmentType :: enum {
  FINAL_IMAGE        = 0,
  POSITION           = 1,
  NORMAL             = 2,
  ALBEDO             = 3,
  METALLIC_ROUGHNESS = 4,
  EMISSIVE           = 5,
  DEPTH              = 6,
}

PassType :: enum {
  SHADOW       = 0,
  GEOMETRY     = 1,
  LIGHTING     = 2,
  TRANSPARENCY = 3,
  PARTICLES    = 4,
  POST_PROCESS = 5,
}

PassTypeSet :: bit_set[PassType;u32]

Camera :: struct {
  // Render pass configuration
  enabled_passes:                PassTypeSet,
  // Visibility culling control flags
  enable_culling:                bool, // If false, skip culling compute pass
  enable_depth_pyramid:          bool, // If false, skip depth pyramid generation
  // GPU resources - Render target attachments (G-buffer textures, depth, final image)
  attachments:                   [AttachmentType][FRAMES_IN_FLIGHT]gpu.Texture2DHandle,
  // Indirect draw buffers (double-buffered for async compute)
  // Frame N compute writes to buffers[N], Frame N graphics reads from buffers[N-1]
  opaque_draw_count:             [FRAMES_IN_FLIGHT]gpu.MutableBuffer(u32),
  opaque_draw_commands:          [FRAMES_IN_FLIGHT]gpu.MutableBuffer(
    vk.DrawIndexedIndirectCommand,
  ),
  transparent_draw_count:        [FRAMES_IN_FLIGHT]gpu.MutableBuffer(u32),
  transparent_draw_commands:     [FRAMES_IN_FLIGHT]gpu.MutableBuffer(
    vk.DrawIndexedIndirectCommand,
  ),
  sprite_draw_count:             [FRAMES_IN_FLIGHT]gpu.MutableBuffer(u32),
  sprite_draw_commands:          [FRAMES_IN_FLIGHT]gpu.MutableBuffer(
    vk.DrawIndexedIndirectCommand,
  ),
  // Depth pyramid for hierarchical Z culling
  depth_pyramid:                 [FRAMES_IN_FLIGHT]DepthPyramid,
  // Descriptor sets for visibility culling compute shaders
  descriptor_set:                [FRAMES_IN_FLIGHT]vk.DescriptorSet,
  depth_reduce_descriptor_sets:  [FRAMES_IN_FLIGHT][MAX_DEPTH_MIPS_LEVEL]vk.DescriptorSet,
}

// Get camera viewport extent from its depth attachment
get_extent :: proc(
  camera: ^Camera,
  texture_manager: ^gpu.TextureManager,
  frame_index: u32,
) -> (
  width: u32,
  height: u32,
) {
  depth_texture := gpu.get_texture_2d(
    texture_manager,
    camera.attachments[.DEPTH][frame_index],
  )
  if depth_texture != nil {
    return depth_texture.spec.width, depth_texture.spec.height
  }
  return 0, 0
}

// DepthPyramid - Hierarchical depth buffer for occlusion culling (GPU resource)
DepthPyramid :: struct {
  texture:    gpu.Texture2DHandle,
  views:      [MAX_DEPTH_MIPS_LEVEL]vk.ImageView,
  full_view:  vk.ImageView,
  sampler:    vk.Sampler,
  mip_levels: u32,
  using extent:     vk.Extent2D,
}


// Initialize GPU resources for perspective camera
// Takes only the specific resources needed, no dependency on render manager
init_gpu :: proc(
  gctx: ^gpu.GPUContext,
  camera: ^Camera,
  texture_manager: ^gpu.TextureManager,
  extent: vk.Extent2D,
  color_format, depth_format: vk.Format,
  enabled_passes: PassTypeSet = {
    .SHADOW,
    .GEOMETRY,
    .LIGHTING,
    .TRANSPARENCY,
    .PARTICLES,
    .POST_PROCESS,
  },
  enable_depth_pyramid: bool = true,
  max_draws: u32,
) -> vk.Result {
  // Determine which attachments are needed based on enabled passes
  needs_gbuffer := .GEOMETRY in enabled_passes || .LIGHTING in enabled_passes
  needs_final :=
    .LIGHTING in enabled_passes ||
    .TRANSPARENCY in enabled_passes ||
    .PARTICLES in enabled_passes ||
    .POST_PROCESS in enabled_passes

  // Create render target attachments for each frame
  for frame in 0 ..< FRAMES_IN_FLIGHT {
    if needs_final {
      camera.attachments[.FINAL_IMAGE][frame] = gpu.allocate_texture_2d(
        texture_manager,
        gctx,
        extent,
        color_format,
        {.COLOR_ATTACHMENT, .SAMPLED},
      ) or_return
    }
    if needs_gbuffer {
      camera.attachments[.POSITION][frame] = gpu.allocate_texture_2d(
        texture_manager,
        gctx,
        extent,
        .R32G32B32A32_SFLOAT,
        {.COLOR_ATTACHMENT, .SAMPLED},
      ) or_return
      camera.attachments[.NORMAL][frame] = gpu.allocate_texture_2d(
        texture_manager,
        gctx,
        extent,
        .R8G8B8A8_UNORM,
        {.COLOR_ATTACHMENT, .SAMPLED},
      ) or_return
      camera.attachments[.ALBEDO][frame] = gpu.allocate_texture_2d(
        texture_manager,
        gctx,
        extent,
        .R8G8B8A8_UNORM,
        {.COLOR_ATTACHMENT, .SAMPLED},
      ) or_return
      camera.attachments[.METALLIC_ROUGHNESS][frame] = gpu.allocate_texture_2d(
        texture_manager,
        gctx,
        extent,
        .R8G8B8A8_UNORM,
        {.COLOR_ATTACHMENT, .SAMPLED},
      ) or_return
      camera.attachments[.EMISSIVE][frame] = gpu.allocate_texture_2d(
        texture_manager,
        gctx,
        extent,
        .R8G8B8A8_UNORM,
        {.COLOR_ATTACHMENT, .SAMPLED},
      ) or_return
    }
    camera.attachments[.DEPTH][frame] = gpu.allocate_texture_2d(
      texture_manager,
      gctx,
      extent,
      depth_format,
      {.DEPTH_STENCIL_ATTACHMENT, .SAMPLED},
    ) or_return

    // Transition depth image from UNDEFINED to DEPTH_STENCIL_READ_ONLY_OPTIMAL
    if depth := gpu.get_texture_2d(
      texture_manager,
      camera.attachments[.DEPTH][frame],
    ); depth != nil {
      cmd_buf := gpu.begin_single_time_command(gctx) or_return
      gpu.image_barrier(
        cmd_buf,
        depth.image,
        .UNDEFINED,
        .DEPTH_STENCIL_READ_ONLY_OPTIMAL,
        {},
        {.DEPTH_STENCIL_ATTACHMENT_READ},
        {.TOP_OF_PIPE},
        {.EARLY_FRAGMENT_TESTS},
        {.DEPTH},
      )
      gpu.end_single_time_command(gctx, &cmd_buf) or_return
    }
  }

  // Create indirect draw buffers (double-buffered)
  for frame in 0 ..< FRAMES_IN_FLIGHT {
    camera.opaque_draw_count[frame] = gpu.create_mutable_buffer(
      gctx,
      u32,
      1,
      {.STORAGE_BUFFER, .INDIRECT_BUFFER, .TRANSFER_DST},
    ) or_return
    camera.opaque_draw_commands[frame] = gpu.create_mutable_buffer(
      gctx,
      vk.DrawIndexedIndirectCommand,
      int(max_draws),
      {.STORAGE_BUFFER, .INDIRECT_BUFFER, .TRANSFER_DST},
    ) or_return
    camera.transparent_draw_count[frame] = gpu.create_mutable_buffer(
      gctx,
      u32,
      1,
      {.STORAGE_BUFFER, .INDIRECT_BUFFER, .TRANSFER_DST},
    ) or_return
    camera.transparent_draw_commands[frame] = gpu.create_mutable_buffer(
      gctx,
      vk.DrawIndexedIndirectCommand,
      int(max_draws),
      {.STORAGE_BUFFER, .INDIRECT_BUFFER, .TRANSFER_DST},
    ) or_return
    camera.sprite_draw_count[frame] = gpu.create_mutable_buffer(
      gctx,
      u32,
      1,
      {.STORAGE_BUFFER, .INDIRECT_BUFFER, .TRANSFER_DST},
    ) or_return
    camera.sprite_draw_commands[frame] = gpu.create_mutable_buffer(
      gctx,
      vk.DrawIndexedIndirectCommand,
      int(max_draws),
      {.STORAGE_BUFFER, .INDIRECT_BUFFER, .TRANSFER_DST},
    ) or_return
  }

  // Create depth pyramids for hierarchical Z culling
  if enable_depth_pyramid {
    for frame in 0 ..< FRAMES_IN_FLIGHT {
      create_depth_pyramid(
        gctx,
        camera,
        texture_manager,
        extent,
        u32(frame),
      ) or_return
    }
  }

  return .SUCCESS
}

// Destroy GPU resources for perspective/orthographic camera
destroy_gpu :: proc(
  gctx: ^gpu.GPUContext,
  camera: ^Camera,
  texture_manager: ^gpu.TextureManager,
) {
  // Destroy all attachment textures
  for attachment_type in AttachmentType {
    for frame in 0 ..< FRAMES_IN_FLIGHT {
      handle := camera.attachments[attachment_type][frame]
      if handle.index == 0 do continue
      gpu.free_texture_2d(texture_manager, gctx, handle)
    }
  }

  // Destroy depth pyramids
  for frame in 0 ..< FRAMES_IN_FLIGHT {
    pyramid := &camera.depth_pyramid[frame]
    if pyramid.mip_levels == 0 do continue

    for mip in 0 ..< pyramid.mip_levels {
      vk.DestroyImageView(gctx.device, pyramid.views[mip], nil)
    }
    vk.DestroyImageView(gctx.device, pyramid.full_view, nil)
    vk.DestroySampler(gctx.device, pyramid.sampler, nil)

    gpu.free_texture_2d(texture_manager, gctx, pyramid.texture)
  }

  // Destroy indirect draw buffers
  for frame in 0 ..< FRAMES_IN_FLIGHT {
    gpu.mutable_buffer_destroy(gctx.device, &camera.opaque_draw_count[frame])
    gpu.mutable_buffer_destroy(
      gctx.device,
      &camera.opaque_draw_commands[frame],
    )
    gpu.mutable_buffer_destroy(
      gctx.device,
      &camera.transparent_draw_count[frame],
    )
    gpu.mutable_buffer_destroy(
      gctx.device,
      &camera.transparent_draw_commands[frame],
    )
    gpu.mutable_buffer_destroy(gctx.device, &camera.sprite_draw_count[frame])
    gpu.mutable_buffer_destroy(
      gctx.device,
      &camera.sprite_draw_commands[frame],
    )
  }
  // Zero out the GPU struct
  camera^ = {}
}

// Allocate descriptor sets for perspective/orthographic camera culling pipelines
allocate_descriptors :: proc(
  gctx: ^gpu.GPUContext,
  camera: ^Camera,
  texture_manager: ^gpu.TextureManager,
  normal_descriptor_layout: ^vk.DescriptorSetLayout,
  depth_reduce_descriptor_layout: ^vk.DescriptorSetLayout,
  node_data_buffer: ^gpu.BindlessBuffer(rd.Node),
  mesh_data_buffer: ^gpu.BindlessBuffer(rd.Mesh),
  world_matrix_buffer: ^gpu.BindlessBuffer(matrix[4, 4]f32),
  camera_buffer: ^gpu.PerFrameBindlessBuffer(rd.Camera, FRAMES_IN_FLIGHT),
) -> vk.Result {
  for frame_index in 0 ..< FRAMES_IN_FLIGHT {
    prev_frame_index := (frame_index + FRAMES_IN_FLIGHT - 1) % FRAMES_IN_FLIGHT
    pyramid := &camera.depth_pyramid[frame_index]
    prev_pyramid := &camera.depth_pyramid[prev_frame_index]
    prev_depth := gpu.get_texture_2d(
      texture_manager,
      camera.attachments[.DEPTH][prev_frame_index],
    )
    if prev_depth == nil {
      log.errorf(
        "allocate_descriptors: missing depth attachment for frame %d",
        prev_frame_index,
      )
      return .ERROR_INITIALIZATION_FAILED
    }
    if pyramid.mip_levels == 0 {
      log.errorf(
        "allocate_descriptors: missing depth pyramid for frame %d",
        frame_index,
      )
      return .ERROR_INITIALIZATION_FAILED
    }

    camera.descriptor_set[frame_index] = gpu.create_descriptor_set(
      gctx,
      normal_descriptor_layout,
      {.STORAGE_BUFFER, gpu.buffer_info(&node_data_buffer.buffer)},
      {.STORAGE_BUFFER, gpu.buffer_info(&mesh_data_buffer.buffer)},
      {.STORAGE_BUFFER, gpu.buffer_info(&world_matrix_buffer.buffer)},
      {.STORAGE_BUFFER, gpu.buffer_info(&camera_buffer.buffers[frame_index])},
      {
        .STORAGE_BUFFER,
        gpu.buffer_info(&camera.opaque_draw_count[frame_index]),
      },
      {
        .STORAGE_BUFFER,
        gpu.buffer_info(&camera.opaque_draw_commands[frame_index]),
      },
      {
        .STORAGE_BUFFER,
        gpu.buffer_info(&camera.transparent_draw_count[frame_index]),
      },
      {
        .STORAGE_BUFFER,
        gpu.buffer_info(&camera.transparent_draw_commands[frame_index]),
      },
      {
        .STORAGE_BUFFER,
        gpu.buffer_info(&camera.sprite_draw_count[frame_index]),
      },
      {
        .STORAGE_BUFFER,
        gpu.buffer_info(&camera.sprite_draw_commands[frame_index]),
      },
      {
        .COMBINED_IMAGE_SAMPLER,
        vk.DescriptorImageInfo {
          sampler = prev_pyramid.sampler,
          imageView = prev_pyramid.full_view,
          imageLayout = .GENERAL,
        },
      },
    ) or_return

    for mip in 0 ..< pyramid.mip_levels {
      source_info: vk.DescriptorImageInfo
      if mip == 0 {
        source_info = {
          sampler     = pyramid.sampler,
          imageView   = prev_depth.view,
          imageLayout = .DEPTH_STENCIL_READ_ONLY_OPTIMAL,
        }
      } else {
        source_info = {
          sampler     = pyramid.sampler,
          imageView   = pyramid.views[mip - 1],
          imageLayout = .GENERAL,
        }
      }
      dest_info := vk.DescriptorImageInfo {
        imageView   = pyramid.views[mip],
        imageLayout = .GENERAL,
      }
      camera.depth_reduce_descriptor_sets[frame_index][mip] =
        gpu.create_descriptor_set(
          gctx,
          depth_reduce_descriptor_layout,
          {.COMBINED_IMAGE_SAMPLER, source_info},
          {.STORAGE_IMAGE, dest_info},
        ) or_return
    }
  }

  return .SUCCESS
}

// Resize camera render targets (called on window resize)
resize :: proc(
  gctx: ^gpu.GPUContext,
  camera: ^Camera,
  texture_manager: ^gpu.TextureManager,
  extent: vk.Extent2D,
  color_format, depth_format: vk.Format,
  enabled_passes: PassTypeSet,
  enable_depth_pyramid: bool,
) -> vk.Result {
  // Destroy old attachments
  for attachment_type in AttachmentType {
    for frame in 0 ..< FRAMES_IN_FLIGHT {
      handle := camera.attachments[attachment_type][frame]
      if handle.index == 0 do continue
      gpu.free_texture_2d(texture_manager, gctx, handle)
      camera.attachments[attachment_type][frame] = {}
    }
  }

  // Destroy old depth pyramids
  for frame in 0 ..< FRAMES_IN_FLIGHT {
    pyramid := &camera.depth_pyramid[frame]
    if pyramid.mip_levels == 0 do continue

    for mip in 0 ..< pyramid.mip_levels {
      vk.DestroyImageView(gctx.device, pyramid.views[mip], nil)
    }
    vk.DestroyImageView(gctx.device, pyramid.full_view, nil)
    vk.DestroySampler(gctx.device, pyramid.sampler, nil)

    gpu.free_texture_2d(texture_manager, gctx, pyramid.texture)
    pyramid^ = {}
  }

  // Recreate attachments with new dimensions
  needs_gbuffer := .GEOMETRY in enabled_passes || .LIGHTING in enabled_passes
  needs_final :=
    .LIGHTING in enabled_passes ||
    .TRANSPARENCY in enabled_passes ||
    .PARTICLES in enabled_passes ||
    .POST_PROCESS in enabled_passes

  for frame in 0 ..< FRAMES_IN_FLIGHT {
    if needs_final {
      camera.attachments[.FINAL_IMAGE][frame] = gpu.allocate_texture_2d(
        texture_manager,
        gctx,
        extent,
        color_format,
        {.COLOR_ATTACHMENT, .SAMPLED},
      ) or_return
    }
    if needs_gbuffer {
      camera.attachments[.POSITION][frame] = gpu.allocate_texture_2d(
        texture_manager,
        gctx,
        extent,
        .R32G32B32A32_SFLOAT,
        {.COLOR_ATTACHMENT, .SAMPLED},
      ) or_return
      camera.attachments[.NORMAL][frame] = gpu.allocate_texture_2d(
        texture_manager,
        gctx,
        extent,
        .R8G8B8A8_UNORM,
        {.COLOR_ATTACHMENT, .SAMPLED},
      ) or_return
      camera.attachments[.ALBEDO][frame] = gpu.allocate_texture_2d(
        texture_manager,
        gctx,
        extent,
        .R8G8B8A8_UNORM,
        {.COLOR_ATTACHMENT, .SAMPLED},
      ) or_return
      camera.attachments[.METALLIC_ROUGHNESS][frame] = gpu.allocate_texture_2d(
        texture_manager,
        gctx,
        extent,
        .R8G8B8A8_UNORM,
        {.COLOR_ATTACHMENT, .SAMPLED},
      ) or_return
      camera.attachments[.EMISSIVE][frame] = gpu.allocate_texture_2d(
        texture_manager,
        gctx,
        extent,
        .R8G8B8A8_UNORM,
        {.COLOR_ATTACHMENT, .SAMPLED},
      ) or_return
    }
    camera.attachments[.DEPTH][frame] = gpu.allocate_texture_2d(
      texture_manager,
      gctx,
      extent,
      depth_format,
      {.DEPTH_STENCIL_ATTACHMENT, .SAMPLED},
    ) or_return

    if depth := gpu.get_texture_2d(
      texture_manager,
      camera.attachments[.DEPTH][frame],
    ); depth != nil {
      cmd_buf := gpu.begin_single_time_command(gctx) or_return
      gpu.image_barrier(
        cmd_buf,
        depth.image,
        .UNDEFINED,
        .DEPTH_STENCIL_READ_ONLY_OPTIMAL,
        {},
        {.DEPTH_STENCIL_ATTACHMENT_READ},
        {.TOP_OF_PIPE},
        {.EARLY_FRAGMENT_TESTS},
        {.DEPTH},
      )
      gpu.end_single_time_command(gctx, &cmd_buf) or_return
    }
  }

  // Recreate depth pyramids
  if enable_depth_pyramid {
    for frame in 0 ..< FRAMES_IN_FLIGHT {
      create_depth_pyramid(
        gctx,
        camera,
        texture_manager,
        extent,
        u32(frame),
      ) or_return
    }
  }

  log.infof("Camera resized to %dx%d", extent.width, extent.height)
  return .SUCCESS
}

// Helper: Create depth pyramid for hierarchical Z culling
@(private)
create_depth_pyramid :: proc(
  gctx: ^gpu.GPUContext,
  camera: ^Camera,
  texture_manager: ^gpu.TextureManager,
  extent: vk.Extent2D,
  frame_index: u32,
) -> vk.Result {
  extent := vk.Extent2D{max(1, extent.width / 2), max(1, extent.height / 2)}
  mip_levels := alg.log2_greater_than(max(extent.width, extent.height))
  pyramid_handle := gpu.allocate_texture_2d(
    texture_manager,
    gctx,
    extent,
    .R32_SFLOAT,
    {.SAMPLED, .STORAGE, .TRANSFER_DST},
    true, // generate_mips
  ) or_return

  pyramid_texture := gpu.get_texture_2d(texture_manager, pyramid_handle)
  if pyramid_texture == nil {
    log.error("Failed to get allocated depth pyramid texture")
    return .ERROR_OUT_OF_DEVICE_MEMORY
  }

  // Transition all mip levels to GENERAL layout
  {
    cmd_buf := gpu.begin_single_time_command(gctx) or_return
    gpu.image_barrier(
      cmd_buf,
      pyramid_texture.image,
      .UNDEFINED,
      .GENERAL,
      {},
      {.SHADER_READ, .SHADER_WRITE},
      {.TOP_OF_PIPE},
      {.COMPUTE_SHADER},
      {.COLOR},
      level_count = mip_levels,
    )
    gpu.end_single_time_command(gctx, &cmd_buf) or_return
  }

  camera.depth_pyramid[frame_index].texture = pyramid_handle
  camera.depth_pyramid[frame_index].mip_levels = mip_levels
  camera.depth_pyramid[frame_index].extent = extent

  // Create per-mip views
  for mip in 0 ..< mip_levels {
    view_info := vk.ImageViewCreateInfo {
      sType = .IMAGE_VIEW_CREATE_INFO,
      image = pyramid_texture.image,
      viewType = .D2,
      format = .R32_SFLOAT,
      subresourceRange = {
        aspectMask = {.COLOR},
        baseMipLevel = mip,
        levelCount = 1,
        layerCount = 1,
      },
    }
    vk.CreateImageView(
      gctx.device,
      &view_info,
      nil,
      &camera.depth_pyramid[frame_index].views[mip],
    ) or_return
  }

  // Create full pyramid view
  full_view_info := vk.ImageViewCreateInfo {
    sType = .IMAGE_VIEW_CREATE_INFO,
    image = pyramid_texture.image,
    viewType = .D2,
    format = .R32_SFLOAT,
    subresourceRange = {
      aspectMask = {.COLOR},
      baseMipLevel = 0,
      levelCount = mip_levels,
      layerCount = 1,
    },
  }
  vk.CreateImageView(
    gctx.device,
    &full_view_info,
    nil,
    &camera.depth_pyramid[frame_index].full_view,
  ) or_return

  // Create sampler for depth pyramid with MAX reduction for forward-Z
  reduction_mode := vk.SamplerReductionModeCreateInfo {
    sType         = .SAMPLER_REDUCTION_MODE_CREATE_INFO,
    reductionMode = .MAX,
  }
  sampler_info := vk.SamplerCreateInfo {
    sType        = .SAMPLER_CREATE_INFO,
    magFilter    = .LINEAR,
    minFilter    = .LINEAR,
    mipmapMode   = .NEAREST,
    addressModeU = .CLAMP_TO_EDGE,
    addressModeV = .CLAMP_TO_EDGE,
    addressModeW = .CLAMP_TO_EDGE,
    minLod       = 0.0,
    maxLod       = f32(mip_levels),
    borderColor  = .FLOAT_OPAQUE_WHITE,
    pNext        = &reduction_mode,
  }
  vk.CreateSampler(
    gctx.device,
    &sampler_info,
    nil,
    &camera.depth_pyramid[frame_index].sampler,
  ) or_return

  return .SUCCESS
}

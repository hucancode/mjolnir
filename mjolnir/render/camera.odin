package render

import "../gpu"
import "core:log"
import depth_pyramid_system "depth_pyramid"
import "occlusion_culling"
import vk "vendor:vulkan"

visibility_stats :: proc(
  self: ^Manager,
  camera_index: u32,
  frame_index: u32,
) -> VisibilityStats {
  cam, ok := &self.cameras[camera_index]
  if !ok do return {node_count = self.internal.visibility.node_count}
  st := occlusion_culling.stats(
    &self.internal.visibility,
    &cam.draws[.OPAQUE].count[frame_index],
    camera_index,
    frame_index,
  )
  return {
    node_count = self.internal.visibility.node_count,
    opaque_draw_count = st.opaque_draw_count,
  }
}

camera_init :: proc(
  gctx: ^gpu.GPUContext,
  camera: ^CameraTarget,
  texture_manager: ^gpu.TextureManager,
  extent: vk.Extent2D,
  color_format, depth_format: vk.Format,
  enabled_passes: PassTypeSet = DEFAULT_ENABLED_PASSES,
  enable_culling: bool = true,
  max_draws: u32,
) -> vk.Result {
  camera.enabled_passes = enabled_passes
  camera.enable_culling = enable_culling
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
        gpu.HDR_COLOR_FORMAT,
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

  // Create indirect draw buffers (double-buffered) for each pipeline.
  for pipe in DrawPipeline {
    for frame in 0 ..< FRAMES_IN_FLIGHT {
      camera.draws[pipe].count[frame] = gpu.create_mutable_buffer(
        gctx,
        u32,
        1,
        {.STORAGE_BUFFER, .INDIRECT_BUFFER, .TRANSFER_DST},
      ) or_return
      camera.draws[pipe].commands[frame] = gpu.create_mutable_buffer(
        gctx,
        vk.DrawIndexedIndirectCommand,
        int(max_draws),
        {.STORAGE_BUFFER, .INDIRECT_BUFFER, .TRANSFER_DST},
      ) or_return
    }
  }

  if enable_culling {
    for frame in 0 ..< FRAMES_IN_FLIGHT {
      depth_pyramid_system.setup_pyramid(
        gctx,
        &camera.depth_pyramid[frame],
        texture_manager,
        extent,
      ) or_return
    }
  }

  return .SUCCESS
}

// Destroy GPU resources for perspective/orthographic camera
camera_destroy :: proc(
  gctx: ^gpu.GPUContext,
  camera: ^CameraTarget,
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
    depth_pyramid_system.destroy_pyramid(
      gctx,
      &camera.depth_pyramid[frame],
      texture_manager,
    )
  }

  // Destroy indirect draw buffers
  for pipe in DrawPipeline {
    for frame in 0 ..< FRAMES_IN_FLIGHT {
      gpu.mutable_buffer_destroy(gctx.device, &camera.draws[pipe].count[frame])
      gpu.mutable_buffer_destroy(
        gctx.device,
        &camera.draws[pipe].commands[frame],
      )
    }
  }
  // Zero out the GPU struct
  camera^ = {}
}

// Allocate descriptor sets for perspective/orthographic camera culling pipelines
camera_allocate_descriptors :: proc(
  self: ^Manager,
  gctx: ^gpu.GPUContext,
  camera: ^CameraTarget,
) -> vk.Result {
  texture_manager := &self.texture_manager
  normal_descriptor_layout := &self.internal.visibility.depth_descriptor_layout
  depth_reduce_descriptor_layout := &self.internal.depth_pyramid.depth_reduce_descriptor_layout
  node_data_buffer := &self.internal.node_data_buffer
  mesh_data_buffer := &self.internal.mesh_data_buffer
  camera_buffer := &self.internal.camera_buffer
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
      {.STORAGE_BUFFER, gpu.buffer_info(&camera_buffer.buffers[frame_index])},
      {
        .STORAGE_BUFFER,
        gpu.buffer_info(&camera.draws[.OPAQUE].count[frame_index]),
      },
      {
        .STORAGE_BUFFER,
        gpu.buffer_info(&camera.draws[.OPAQUE].commands[frame_index]),
      },
      {
        .STORAGE_BUFFER,
        gpu.buffer_info(&camera.draws[.TRANSPARENT].count[frame_index]),
      },
      {
        .STORAGE_BUFFER,
        gpu.buffer_info(&camera.draws[.TRANSPARENT].commands[frame_index]),
      },
      {
        .STORAGE_BUFFER,
        gpu.buffer_info(&camera.draws[.SPRITE].count[frame_index]),
      },
      {
        .STORAGE_BUFFER,
        gpu.buffer_info(&camera.draws[.SPRITE].commands[frame_index]),
      },
      {
        .STORAGE_BUFFER,
        gpu.buffer_info(&camera.draws[.WIREFRAME].count[frame_index]),
      },
      {
        .STORAGE_BUFFER,
        gpu.buffer_info(&camera.draws[.WIREFRAME].commands[frame_index]),
      },
      {
        .STORAGE_BUFFER,
        gpu.buffer_info(&camera.draws[.RANDOM_COLOR].count[frame_index]),
      },
      {
        .STORAGE_BUFFER,
        gpu.buffer_info(&camera.draws[.RANDOM_COLOR].commands[frame_index]),
      },
      {
        .STORAGE_BUFFER,
        gpu.buffer_info(&camera.draws[.LINE_STRIP].count[frame_index]),
      },
      {
        .STORAGE_BUFFER,
        gpu.buffer_info(&camera.draws[.LINE_STRIP].commands[frame_index]),
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
camera_resize :: proc(
  gctx: ^gpu.GPUContext,
  camera: ^CameraTarget,
  texture_manager: ^gpu.TextureManager,
  extent: vk.Extent2D,
  color_format, depth_format: vk.Format,
) -> vk.Result {
  enabled_passes := camera.enabled_passes
  enable_culling := camera.enable_culling
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
        gpu.HDR_COLOR_FORMAT,
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
  if enable_culling {
    for frame in 0 ..< FRAMES_IN_FLIGHT {
      depth_pyramid_system.setup_pyramid(
        gctx,
        &camera.depth_pyramid[frame],
        texture_manager,
        extent,
      ) or_return
    }
  }

  log.infof("Camera resized to %dx%d", extent.width, extent.height)
  return .SUCCESS
}

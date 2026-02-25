package render

import alg "../algebra"
import "../gpu"
import "camera"
import rd "data"
import rg "graph"
import particles_compute "particles_compute"
import "shadow"
import ui_render "ui"
import vk "vendor:vulkan"

ResourceIndex :: rg.ResourceIndex

ParticleResources :: struct {
  particle_buffer:         gpu.MutableBuffer(particles_compute.Particle),
  compact_particle_buffer: gpu.MutableBuffer(particles_compute.Particle),
  draw_command_buffer:     gpu.MutableBuffer(vk.DrawIndirectCommand),
}

UIResources :: struct {
  vertex_buffers: [FRAMES_IN_FLIGHT]gpu.MutableBuffer(ui_render.Vertex2D),
  index_buffers:  [FRAMES_IN_FLIGHT]gpu.MutableBuffer(u32),
}

RenderResourceManager :: struct {
  // Owned GPU resources (progressive P0.3 migration target).
  particle_resources:                ParticleResources,
  ui_resources:                      UIResources,
  bone_buffer:                       gpu.PerFrameBindlessBuffer(
    matrix[4, 4]f32,
    FRAMES_IN_FLIGHT,
  ),
  camera_buffer:                     gpu.PerFrameBindlessBuffer(
    rd.Camera,
    FRAMES_IN_FLIGHT,
  ),
  material_buffer:                   gpu.BindlessBuffer(Material),
  node_data_buffer:                  gpu.BindlessBuffer(Node),
  mesh_data_buffer:                  gpu.BindlessBuffer(Mesh),
  emitter_buffer:                    gpu.BindlessBuffer(Emitter),
  forcefield_buffer:                 gpu.BindlessBuffer(ForceField),
  sprite_buffer:                     gpu.BindlessBuffer(Sprite),
  lights_buffer:                     gpu.BindlessBuffer(rd.Light),
  shadow_spot_maps:                  [shadow.MAX_SHADOW_MAPS][FRAMES_IN_FLIGHT]gpu.Texture2DHandle,
  shadow_directional_maps:           [shadow.MAX_SHADOW_MAPS][FRAMES_IN_FLIGHT]gpu.Texture2DHandle,
  shadow_point_cubes:                [shadow.MAX_SHADOW_MAPS][FRAMES_IN_FLIGHT]gpu.TextureCubeHandle,
  shadow_spot_draw_counts:           [shadow.MAX_SHADOW_MAPS][FRAMES_IN_FLIGHT]gpu.MutableBuffer(u32),
  shadow_spot_draw_commands:         [shadow.MAX_SHADOW_MAPS][FRAMES_IN_FLIGHT]gpu.MutableBuffer(vk.DrawIndexedIndirectCommand),
  shadow_directional_draw_counts:    [shadow.MAX_SHADOW_MAPS][FRAMES_IN_FLIGHT]gpu.MutableBuffer(u32),
  shadow_directional_draw_commands:  [shadow.MAX_SHADOW_MAPS][FRAMES_IN_FLIGHT]gpu.MutableBuffer(vk.DrawIndexedIndirectCommand),
  shadow_point_draw_counts:          [shadow.MAX_SHADOW_MAPS][FRAMES_IN_FLIGHT]gpu.MutableBuffer(u32),
  shadow_point_draw_commands:        [shadow.MAX_SHADOW_MAPS][FRAMES_IN_FLIGHT]gpu.MutableBuffer(vk.DrawIndexedIndirectCommand),
  camera_opaque_draw_counts:         [rd.MAX_ACTIVE_CAMERAS][FRAMES_IN_FLIGHT]gpu.MutableBuffer(u32),
  camera_opaque_draw_commands:       [rd.MAX_ACTIVE_CAMERAS][FRAMES_IN_FLIGHT]gpu.MutableBuffer(vk.DrawIndexedIndirectCommand),
  camera_transparent_draw_counts:    [rd.MAX_ACTIVE_CAMERAS][FRAMES_IN_FLIGHT]gpu.MutableBuffer(u32),
  camera_transparent_draw_commands:  [rd.MAX_ACTIVE_CAMERAS][FRAMES_IN_FLIGHT]gpu.MutableBuffer(vk.DrawIndexedIndirectCommand),
  camera_wireframe_draw_counts:      [rd.MAX_ACTIVE_CAMERAS][FRAMES_IN_FLIGHT]gpu.MutableBuffer(u32),
  camera_wireframe_draw_commands:    [rd.MAX_ACTIVE_CAMERAS][FRAMES_IN_FLIGHT]gpu.MutableBuffer(vk.DrawIndexedIndirectCommand),
  camera_random_color_draw_counts:   [rd.MAX_ACTIVE_CAMERAS][FRAMES_IN_FLIGHT]gpu.MutableBuffer(u32),
  camera_random_color_draw_commands: [rd.MAX_ACTIVE_CAMERAS][FRAMES_IN_FLIGHT]gpu.MutableBuffer(vk.DrawIndexedIndirectCommand),
  camera_line_strip_draw_counts:     [rd.MAX_ACTIVE_CAMERAS][FRAMES_IN_FLIGHT]gpu.MutableBuffer(u32),
  camera_line_strip_draw_commands:   [rd.MAX_ACTIVE_CAMERAS][FRAMES_IN_FLIGHT]gpu.MutableBuffer(vk.DrawIndexedIndirectCommand),
  camera_sprite_draw_counts:         [rd.MAX_ACTIVE_CAMERAS][FRAMES_IN_FLIGHT]gpu.MutableBuffer(u32),
  camera_sprite_draw_commands:       [rd.MAX_ACTIVE_CAMERAS][FRAMES_IN_FLIGHT]gpu.MutableBuffer(vk.DrawIndexedIndirectCommand),
  camera_attachments:                [rd.MAX_ACTIVE_CAMERAS][camera.AttachmentType][FRAMES_IN_FLIGHT]gpu.Texture2DHandle,
  camera_depth_pyramids:             [rd.MAX_ACTIVE_CAMERAS][FRAMES_IN_FLIGHT]camera.DepthPyramid,
  camera_cull_input_descriptor_sets: [rd.MAX_ACTIVE_CAMERAS][FRAMES_IN_FLIGHT]vk.DescriptorSet,
  camera_cull_output_descriptor_sets: [rd.MAX_ACTIVE_CAMERAS][FRAMES_IN_FLIGHT]vk.DescriptorSet,
  camera_depth_reduce_descriptor_sets: [rd.MAX_ACTIVE_CAMERAS][FRAMES_IN_FLIGHT][camera.MAX_DEPTH_MIPS_LEVEL]vk.DescriptorSet,
}

ResourcePool :: RenderResourceManager

resource_pool_build :: proc(pool: ^ResourcePool) {
  pool^ = {}
}

resource_pool_init_persistent :: proc(
  pool: ^ResourcePool,
  gctx: ^gpu.GPUContext,
  bone_capacity: int,
) -> (
  ret: vk.Result,
) {
  gpu.per_frame_bindless_buffer_init(
    &pool.bone_buffer,
    gctx,
    bone_capacity,
    {.VERTEX},
  ) or_return
  defer if ret != .SUCCESS {
    gpu.per_frame_bindless_buffer_destroy(&pool.bone_buffer, gctx.device)
  }

  gpu.per_frame_bindless_buffer_init(
    &pool.camera_buffer,
    gctx,
    rd.MAX_ACTIVE_CAMERAS,
    {.VERTEX, .FRAGMENT, .COMPUTE},
  ) or_return
  defer if ret != .SUCCESS {
    gpu.per_frame_bindless_buffer_destroy(&pool.camera_buffer, gctx.device)
  }

  gpu.bindless_buffer_init(
    &pool.material_buffer,
    gctx,
    rd.MAX_MATERIALS,
    {.VERTEX, .FRAGMENT},
  ) or_return
  defer if ret != .SUCCESS {
    gpu.bindless_buffer_destroy(&pool.material_buffer, gctx.device)
  }

  gpu.bindless_buffer_init(
    &pool.node_data_buffer,
    gctx,
    rd.MAX_NODES_IN_SCENE,
    {.VERTEX, .FRAGMENT, .COMPUTE},
  ) or_return
  defer if ret != .SUCCESS {
    gpu.bindless_buffer_destroy(&pool.node_data_buffer, gctx.device)
  }

  gpu.bindless_buffer_init(
    &pool.mesh_data_buffer,
    gctx,
    rd.MAX_MESHES,
    {.VERTEX},
  ) or_return
  defer if ret != .SUCCESS {
    gpu.bindless_buffer_destroy(&pool.mesh_data_buffer, gctx.device)
  }

  gpu.bindless_buffer_init(
    &pool.emitter_buffer,
    gctx,
    rd.MAX_EMITTERS,
    {.COMPUTE},
  ) or_return
  defer if ret != .SUCCESS {
    gpu.bindless_buffer_destroy(&pool.emitter_buffer, gctx.device)
  }

  gpu.bindless_buffer_init(
    &pool.forcefield_buffer,
    gctx,
    rd.MAX_FORCE_FIELDS,
    {.COMPUTE},
  ) or_return
  defer if ret != .SUCCESS {
    gpu.bindless_buffer_destroy(&pool.forcefield_buffer, gctx.device)
  }

  gpu.bindless_buffer_init(
    &pool.sprite_buffer,
    gctx,
    rd.MAX_SPRITES,
    {.VERTEX, .FRAGMENT},
  ) or_return
  defer if ret != .SUCCESS {
    gpu.bindless_buffer_destroy(&pool.sprite_buffer, gctx.device)
  }

  gpu.bindless_buffer_init(
    &pool.lights_buffer,
    gctx,
    rd.MAX_LIGHTS,
    {.VERTEX, .FRAGMENT},
  ) or_return
  defer if ret != .SUCCESS {
    gpu.bindless_buffer_destroy(&pool.lights_buffer, gctx.device)
  }

  return .SUCCESS
}

resource_pool_realloc_descriptors :: proc(
  pool: ^ResourcePool,
  gctx: ^gpu.GPUContext,
) -> vk.Result {
  gpu.bindless_buffer_realloc_descriptor(&pool.material_buffer, gctx) or_return
  gpu.bindless_buffer_realloc_descriptor(
    &pool.node_data_buffer,
    gctx,
  ) or_return
  gpu.bindless_buffer_realloc_descriptor(
    &pool.mesh_data_buffer,
    gctx,
  ) or_return
  gpu.bindless_buffer_realloc_descriptor(&pool.emitter_buffer, gctx) or_return
  gpu.bindless_buffer_realloc_descriptor(
    &pool.forcefield_buffer,
    gctx,
  ) or_return
  gpu.bindless_buffer_realloc_descriptor(&pool.sprite_buffer, gctx) or_return
  gpu.bindless_buffer_realloc_descriptor(&pool.lights_buffer, gctx) or_return
  gpu.per_frame_bindless_buffer_realloc_descriptors(
    &pool.bone_buffer,
    gctx,
  ) or_return
  gpu.per_frame_bindless_buffer_realloc_descriptors(
    &pool.camera_buffer,
    gctx,
  ) or_return
  return .SUCCESS
}

resource_pool_zero_descriptors :: proc(pool: ^ResourcePool) {
  pool.material_buffer.descriptor_set = 0
  pool.node_data_buffer.descriptor_set = 0
  pool.mesh_data_buffer.descriptor_set = 0
  pool.emitter_buffer.descriptor_set = 0
  pool.forcefield_buffer.descriptor_set = 0
  pool.sprite_buffer.descriptor_set = 0
  pool.lights_buffer.descriptor_set = 0
  for &ds in pool.bone_buffer.descriptor_sets do ds = 0
  for &ds in pool.camera_buffer.descriptor_sets do ds = 0
  for cam_idx in 0 ..< rd.MAX_ACTIVE_CAMERAS {
    for frame_idx in 0 ..< FRAMES_IN_FLIGHT {
      pool.camera_cull_input_descriptor_sets[cam_idx][frame_idx] = 0
      pool.camera_cull_output_descriptor_sets[cam_idx][frame_idx] = 0
      for mip in 0 ..< camera.MAX_DEPTH_MIPS_LEVEL {
        pool.camera_depth_reduce_descriptor_sets[cam_idx][frame_idx][mip] = 0
      }
    }
  }
}

resource_pool_destroy_persistent :: proc(
  pool: ^ResourcePool,
  device: vk.Device,
) {
  gpu.bindless_buffer_destroy(&pool.material_buffer, device)
  gpu.bindless_buffer_destroy(&pool.node_data_buffer, device)
  gpu.bindless_buffer_destroy(&pool.mesh_data_buffer, device)
  gpu.bindless_buffer_destroy(&pool.emitter_buffer, device)
  gpu.bindless_buffer_destroy(&pool.forcefield_buffer, device)
  gpu.bindless_buffer_destroy(&pool.sprite_buffer, device)
  gpu.bindless_buffer_destroy(&pool.lights_buffer, device)
  gpu.per_frame_bindless_buffer_destroy(&pool.camera_buffer, device)
  gpu.per_frame_bindless_buffer_destroy(&pool.bone_buffer, device)
}

@(private)
destroy_camera_depth_pyramid_resource :: proc(
  pool: ^ResourcePool,
  gctx: ^gpu.GPUContext,
  texture_manager: ^gpu.TextureManager,
  camera_index, frame_index: u32,
) {
  if camera_index >= rd.MAX_ACTIVE_CAMERAS || frame_index >= FRAMES_IN_FLIGHT do return
  pyramid := &pool.camera_depth_pyramids[camera_index][frame_index]
  if pyramid.mip_levels > 0 {
    for mip in 0 ..< pyramid.mip_levels {
      if pyramid.views[mip] != 0 {
        vk.DestroyImageView(gctx.device, pyramid.views[mip], nil)
      }
    }
  }
  if pyramid.full_view != 0 {
    vk.DestroyImageView(gctx.device, pyramid.full_view, nil)
  }
  if pyramid.sampler != 0 {
    vk.DestroySampler(gctx.device, pyramid.sampler, nil)
  }
  if pyramid.texture.index != 0 {
    gpu.free_texture_2d(texture_manager, gctx, pyramid.texture)
  }
  pyramid^ = {}
}

@(private)
create_camera_depth_pyramid_resource :: proc(
  pool: ^ResourcePool,
  gctx: ^gpu.GPUContext,
  texture_manager: ^gpu.TextureManager,
  camera_index, frame_index: u32,
  extent: vk.Extent2D,
) -> vk.Result {
  if camera_index >= rd.MAX_ACTIVE_CAMERAS || frame_index >= FRAMES_IN_FLIGHT {
    return .ERROR_OUT_OF_DEVICE_MEMORY
  }

  pyramid_extent := vk.Extent2D {
    max(1, extent.width / 2),
    max(1, extent.height / 2),
  }
  mip_levels := alg.log2_greater_than(
    max(pyramid_extent.width, pyramid_extent.height),
  )
  pyramid_handle := gpu.allocate_texture_2d(
    texture_manager,
    gctx,
    pyramid_extent,
    .R32_SFLOAT,
    {.SAMPLED, .STORAGE, .TRANSFER_DST},
    true,
  ) or_return
  pyramid_texture := gpu.get_texture_2d(texture_manager, pyramid_handle)
  if pyramid_texture == nil {
    return .ERROR_OUT_OF_DEVICE_MEMORY
  }

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

  pyramid := &pool.camera_depth_pyramids[camera_index][frame_index]
  pyramid.texture = pyramid_handle
  pyramid.mip_levels = mip_levels
  pyramid.extent = pyramid_extent

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
      &pyramid.views[mip],
    ) or_return
  }

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
    &pyramid.full_view,
  ) or_return

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
  vk.CreateSampler(gctx.device, &sampler_info, nil, &pyramid.sampler) or_return

  return .SUCCESS
}

resource_pool_release_camera_resources :: proc(
  pool: ^ResourcePool,
  gctx: ^gpu.GPUContext,
  texture_manager: ^gpu.TextureManager,
  camera_index: u32,
) {
  if camera_index >= rd.MAX_ACTIVE_CAMERAS do return
  for attachment in camera.AttachmentType {
    for frame in 0 ..< FRAMES_IN_FLIGHT {
      handle := pool.camera_attachments[camera_index][attachment][frame]
      if handle.index != 0 {
        gpu.free_texture_2d(texture_manager, gctx, handle)
      }
      pool.camera_attachments[camera_index][attachment][frame] = {}
    }
  }
  for frame in 0 ..< FRAMES_IN_FLIGHT {
    destroy_camera_depth_pyramid_resource(
      pool,
      gctx,
      texture_manager,
      camera_index,
      u32(frame),
    )
    pool.camera_cull_input_descriptor_sets[camera_index][frame] = 0
    pool.camera_cull_output_descriptor_sets[camera_index][frame] = 0
    for mip in 0 ..< camera.MAX_DEPTH_MIPS_LEVEL {
      pool.camera_depth_reduce_descriptor_sets[camera_index][frame][mip] = 0
    }
  }
}

resource_pool_allocate_camera_resources :: proc(
  pool: ^ResourcePool,
  gctx: ^gpu.GPUContext,
  texture_manager: ^gpu.TextureManager,
  camera_index: u32,
  extent: vk.Extent2D,
  color_format, depth_format: vk.Format,
  enabled_passes: camera.PassTypeSet,
  enable_depth_pyramid: bool,
) -> (
  ret: vk.Result,
) {
  if camera_index >= rd.MAX_ACTIVE_CAMERAS do return .ERROR_OUT_OF_DEVICE_MEMORY

  resource_pool_release_camera_resources(
    pool,
    gctx,
    texture_manager,
    camera_index,
  )
  defer if ret != .SUCCESS {
    resource_pool_release_camera_resources(
      pool,
      gctx,
      texture_manager,
      camera_index,
    )
  }

  needs_gbuffer := .GEOMETRY in enabled_passes || .LIGHTING in enabled_passes
  needs_final :=
    .LIGHTING in enabled_passes ||
    .TRANSPARENCY in enabled_passes ||
    .PARTICLES in enabled_passes ||
    .POST_PROCESS in enabled_passes

  for frame in 0 ..< FRAMES_IN_FLIGHT {
    if needs_final {
      pool.camera_attachments[camera_index][.FINAL_IMAGE][frame] =
        gpu.allocate_texture_2d(
          texture_manager,
          gctx,
          extent,
          color_format,
          {.COLOR_ATTACHMENT, .SAMPLED},
        ) or_return
    }
    if needs_gbuffer {
      pool.camera_attachments[camera_index][.POSITION][frame] =
        gpu.allocate_texture_2d(
          texture_manager,
          gctx,
          extent,
          .R32G32B32A32_SFLOAT,
          {.COLOR_ATTACHMENT, .SAMPLED},
        ) or_return
      pool.camera_attachments[camera_index][.NORMAL][frame] =
        gpu.allocate_texture_2d(
          texture_manager,
          gctx,
          extent,
          .R8G8B8A8_UNORM,
          {.COLOR_ATTACHMENT, .SAMPLED},
        ) or_return
      pool.camera_attachments[camera_index][.ALBEDO][frame] =
        gpu.allocate_texture_2d(
          texture_manager,
          gctx,
          extent,
          .R8G8B8A8_UNORM,
          {.COLOR_ATTACHMENT, .SAMPLED},
        ) or_return
      pool.camera_attachments[camera_index][.METALLIC_ROUGHNESS][frame] =
        gpu.allocate_texture_2d(
          texture_manager,
          gctx,
          extent,
          .R8G8B8A8_UNORM,
          {.COLOR_ATTACHMENT, .SAMPLED},
        ) or_return
      pool.camera_attachments[camera_index][.EMISSIVE][frame] =
        gpu.allocate_texture_2d(
          texture_manager,
          gctx,
          extent,
          .R8G8B8A8_UNORM,
          {.COLOR_ATTACHMENT, .SAMPLED},
        ) or_return
    }

    pool.camera_attachments[camera_index][.DEPTH][frame] =
      gpu.allocate_texture_2d(
        texture_manager,
        gctx,
        extent,
        depth_format,
        {.DEPTH_STENCIL_ATTACHMENT, .SAMPLED},
      ) or_return

    if depth := gpu.get_texture_2d(
      texture_manager,
      pool.camera_attachments[camera_index][.DEPTH][frame],
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

  if enable_depth_pyramid {
    for frame in 0 ..< FRAMES_IN_FLIGHT {
      create_camera_depth_pyramid_resource(
        pool,
        gctx,
        texture_manager,
        camera_index,
        u32(frame),
        extent,
      ) or_return
    }
  }

  return .SUCCESS
}

resource_pool_get_camera_attachment :: proc(
  pool: ^ResourcePool,
  camera_index: u32,
  attachment: camera.AttachmentType,
  frame_index: u32,
) -> (gpu.Texture2DHandle, bool) {
  if camera_index >= rd.MAX_ACTIVE_CAMERAS || frame_index >= FRAMES_IN_FLIGHT {
    return {}, false
  }
  handle := pool.camera_attachments[camera_index][attachment][frame_index]
  if handle.index == 0 do return {}, false
  return handle, true
}

resource_pool_get_camera_extent :: proc(
  pool: ^ResourcePool,
  texture_manager: ^gpu.TextureManager,
  camera_index: u32,
  frame_index: u32,
) -> (
  width, height: u32,
) {
  depth_handle, ok := resource_pool_get_camera_attachment(
    pool,
    camera_index,
    .DEPTH,
    frame_index,
  )
  if !ok do return 0, 0
  depth_texture := gpu.get_texture_2d(texture_manager, depth_handle)
  if depth_texture == nil do return 0, 0
  return depth_texture.spec.width, depth_texture.spec.height
}

resource_pool_allocate_camera_descriptors :: proc(
  pool: ^ResourcePool,
  gctx: ^gpu.GPUContext,
  texture_manager: ^gpu.TextureManager,
  camera_index: u32,
  cull_input_descriptor_layout: ^vk.DescriptorSetLayout,
  cull_output_descriptor_layout: ^vk.DescriptorSetLayout,
  depth_reduce_descriptor_layout: ^vk.DescriptorSetLayout,
) -> vk.Result {
  if camera_index >= rd.MAX_ACTIVE_CAMERAS {
    return .ERROR_OUT_OF_DEVICE_MEMORY
  }

  for frame_index in 0 ..< FRAMES_IN_FLIGHT {
    prev_frame_index := (frame_index + FRAMES_IN_FLIGHT - 1) % FRAMES_IN_FLIGHT
    pyramid := &pool.camera_depth_pyramids[camera_index][frame_index]
    prev_pyramid := &pool.camera_depth_pyramids[camera_index][prev_frame_index]

    prev_depth_handle := pool.camera_attachments[camera_index][.DEPTH][
      prev_frame_index
    ]
    prev_depth := gpu.get_texture_2d(texture_manager, prev_depth_handle)
    if prev_depth == nil {
      return .ERROR_INITIALIZATION_FAILED
    }
    if pyramid.mip_levels == 0 {
      // No depth pyramid for this camera: clear descriptor references.
      pool.camera_cull_input_descriptor_sets[camera_index][frame_index] = 0
      pool.camera_cull_output_descriptor_sets[camera_index][frame_index] = 0
      for mip in 0 ..< camera.MAX_DEPTH_MIPS_LEVEL {
        pool.camera_depth_reduce_descriptor_sets[camera_index][frame_index][mip] = 0
      }
      continue
    }

    pool.camera_cull_input_descriptor_sets[camera_index][frame_index] =
      gpu.create_descriptor_set(
        gctx,
        cull_input_descriptor_layout,
        {.STORAGE_BUFFER, gpu.buffer_info(&pool.node_data_buffer.buffer)},
        {.STORAGE_BUFFER, gpu.buffer_info(&pool.mesh_data_buffer.buffer)},
        {.STORAGE_BUFFER, gpu.buffer_info(&pool.camera_buffer.buffers[frame_index])},
        {
          .COMBINED_IMAGE_SAMPLER,
          vk.DescriptorImageInfo{
            sampler = prev_pyramid.sampler,
            imageView = prev_pyramid.full_view,
            imageLayout = .GENERAL,
          },
        },
      ) or_return

    pool.camera_cull_output_descriptor_sets[camera_index][frame_index] =
      gpu.create_descriptor_set(
        gctx,
        cull_output_descriptor_layout,
        {.STORAGE_BUFFER, gpu.buffer_info(&pool.camera_opaque_draw_counts[camera_index][frame_index])},
        {.STORAGE_BUFFER, gpu.buffer_info(&pool.camera_opaque_draw_commands[camera_index][frame_index])},
        {.STORAGE_BUFFER, gpu.buffer_info(&pool.camera_transparent_draw_counts[camera_index][frame_index])},
        {.STORAGE_BUFFER, gpu.buffer_info(&pool.camera_transparent_draw_commands[camera_index][frame_index])},
        {.STORAGE_BUFFER, gpu.buffer_info(&pool.camera_wireframe_draw_counts[camera_index][frame_index])},
        {.STORAGE_BUFFER, gpu.buffer_info(&pool.camera_wireframe_draw_commands[camera_index][frame_index])},
        {.STORAGE_BUFFER, gpu.buffer_info(&pool.camera_random_color_draw_counts[camera_index][frame_index])},
        {.STORAGE_BUFFER, gpu.buffer_info(&pool.camera_random_color_draw_commands[camera_index][frame_index])},
        {.STORAGE_BUFFER, gpu.buffer_info(&pool.camera_line_strip_draw_counts[camera_index][frame_index])},
        {.STORAGE_BUFFER, gpu.buffer_info(&pool.camera_line_strip_draw_commands[camera_index][frame_index])},
        {.STORAGE_BUFFER, gpu.buffer_info(&pool.camera_sprite_draw_counts[camera_index][frame_index])},
        {.STORAGE_BUFFER, gpu.buffer_info(&pool.camera_sprite_draw_commands[camera_index][frame_index])},
      ) or_return

    for mip in 0 ..< pyramid.mip_levels {
      source_info: vk.DescriptorImageInfo
      if mip == 0 {
        source_info = {
          sampler = pyramid.sampler,
          imageView = prev_depth.view,
          imageLayout = .DEPTH_STENCIL_READ_ONLY_OPTIMAL,
        }
      } else {
        source_info = {
          sampler = pyramid.sampler,
          imageView = pyramid.views[mip - 1],
          imageLayout = .GENERAL,
        }
      }
      dest_info := vk.DescriptorImageInfo{
        imageView = pyramid.views[mip],
        imageLayout = .GENERAL,
      }
      pool.camera_depth_reduce_descriptor_sets[camera_index][frame_index][mip] =
        gpu.create_descriptor_set(
          gctx,
          depth_reduce_descriptor_layout,
          {.COMBINED_IMAGE_SAMPLER, source_info},
          {.STORAGE_IMAGE, dest_info},
        ) or_return
    }
    for mip in pyramid.mip_levels ..< camera.MAX_DEPTH_MIPS_LEVEL {
      pool.camera_depth_reduce_descriptor_sets[camera_index][frame_index][mip] = 0
    }
  }

  return .SUCCESS
}

resource_pool_setup :: proc(
  pool: ^ResourcePool,
  gctx: ^gpu.GPUContext,
  texture_manager: ^gpu.TextureManager,
) -> (
  ret: vk.Result,
) {
  resource_pool_teardown(pool, gctx, texture_manager)

  pool.particle_resources.particle_buffer = gpu.create_mutable_buffer(
    gctx,
    particles_compute.Particle,
    particles_compute.MAX_PARTICLES,
    {.STORAGE_BUFFER, .VERTEX_BUFFER, .TRANSFER_DST},
  ) or_return
  defer if ret != .SUCCESS {
    gpu.mutable_buffer_destroy(
      gctx.device,
      &pool.particle_resources.particle_buffer,
    )
  }

  pool.particle_resources.compact_particle_buffer = gpu.create_mutable_buffer(
    gctx,
    particles_compute.Particle,
    particles_compute.MAX_PARTICLES,
    {.STORAGE_BUFFER, .VERTEX_BUFFER, .TRANSFER_SRC},
  ) or_return
  defer if ret != .SUCCESS {
    gpu.mutable_buffer_destroy(
      gctx.device,
      &pool.particle_resources.compact_particle_buffer,
    )
  }

  pool.particle_resources.draw_command_buffer = gpu.create_mutable_buffer(
    gctx,
    vk.DrawIndirectCommand,
    1,
    {.STORAGE_BUFFER, .INDIRECT_BUFFER},
  ) or_return
  defer if ret != .SUCCESS {
    gpu.mutable_buffer_destroy(
      gctx.device,
      &pool.particle_resources.draw_command_buffer,
    )
  }

  defer if ret != .SUCCESS {
    for i in 0 ..< FRAMES_IN_FLIGHT {
      gpu.mutable_buffer_destroy(
        gctx.device,
        &pool.ui_resources.vertex_buffers[i],
      )
      gpu.mutable_buffer_destroy(
        gctx.device,
        &pool.ui_resources.index_buffers[i],
      )
    }
  }
  for i in 0 ..< FRAMES_IN_FLIGHT {
    pool.ui_resources.vertex_buffers[i] = gpu.create_mutable_buffer(
      gctx,
      ui_render.Vertex2D,
      ui_render.UI_MAX_VERTICES,
      {.VERTEX_BUFFER},
    ) or_return
    pool.ui_resources.index_buffers[i] = gpu.create_mutable_buffer(
      gctx,
      u32,
      ui_render.UI_MAX_INDICES,
      {.INDEX_BUFFER},
    ) or_return
  }
  defer if ret != .SUCCESS {
    for camera_index in 0 ..< rd.MAX_ACTIVE_CAMERAS {
      for frame in 0 ..< FRAMES_IN_FLIGHT {
        gpu.mutable_buffer_destroy(
          gctx.device,
          &pool.camera_opaque_draw_counts[camera_index][frame],
        )
        gpu.mutable_buffer_destroy(
          gctx.device,
          &pool.camera_opaque_draw_commands[camera_index][frame],
        )
        gpu.mutable_buffer_destroy(
          gctx.device,
          &pool.camera_transparent_draw_counts[camera_index][frame],
        )
        gpu.mutable_buffer_destroy(
          gctx.device,
          &pool.camera_transparent_draw_commands[camera_index][frame],
        )
        gpu.mutable_buffer_destroy(
          gctx.device,
          &pool.camera_wireframe_draw_counts[camera_index][frame],
        )
        gpu.mutable_buffer_destroy(
          gctx.device,
          &pool.camera_wireframe_draw_commands[camera_index][frame],
        )
        gpu.mutable_buffer_destroy(
          gctx.device,
          &pool.camera_random_color_draw_counts[camera_index][frame],
        )
        gpu.mutable_buffer_destroy(
          gctx.device,
          &pool.camera_random_color_draw_commands[camera_index][frame],
        )
        gpu.mutable_buffer_destroy(
          gctx.device,
          &pool.camera_line_strip_draw_counts[camera_index][frame],
        )
        gpu.mutable_buffer_destroy(
          gctx.device,
          &pool.camera_line_strip_draw_commands[camera_index][frame],
        )
        gpu.mutable_buffer_destroy(
          gctx.device,
          &pool.camera_sprite_draw_counts[camera_index][frame],
        )
        gpu.mutable_buffer_destroy(
          gctx.device,
          &pool.camera_sprite_draw_commands[camera_index][frame],
        )
      }
    }
  }
  for camera_index in 0 ..< rd.MAX_ACTIVE_CAMERAS {
    for frame in 0 ..< FRAMES_IN_FLIGHT {
      pool.camera_opaque_draw_counts[camera_index][frame] =
        gpu.create_mutable_buffer(
          gctx,
          u32,
          1,
          {.STORAGE_BUFFER, .INDIRECT_BUFFER, .TRANSFER_DST},
        ) or_return
      pool.camera_opaque_draw_commands[camera_index][frame] =
        gpu.create_mutable_buffer(
          gctx,
          vk.DrawIndexedIndirectCommand,
          rd.MAX_NODES_IN_SCENE,
          {.STORAGE_BUFFER, .INDIRECT_BUFFER, .TRANSFER_DST},
        ) or_return
      pool.camera_transparent_draw_counts[camera_index][frame] =
        gpu.create_mutable_buffer(
          gctx,
          u32,
          1,
          {.STORAGE_BUFFER, .INDIRECT_BUFFER, .TRANSFER_DST},
        ) or_return
      pool.camera_transparent_draw_commands[camera_index][frame] =
        gpu.create_mutable_buffer(
          gctx,
          vk.DrawIndexedIndirectCommand,
          rd.MAX_NODES_IN_SCENE,
          {.STORAGE_BUFFER, .INDIRECT_BUFFER, .TRANSFER_DST},
        ) or_return
      pool.camera_wireframe_draw_counts[camera_index][frame] =
        gpu.create_mutable_buffer(
          gctx,
          u32,
          1,
          {.STORAGE_BUFFER, .INDIRECT_BUFFER, .TRANSFER_DST},
        ) or_return
      pool.camera_wireframe_draw_commands[camera_index][frame] =
        gpu.create_mutable_buffer(
          gctx,
          vk.DrawIndexedIndirectCommand,
          rd.MAX_NODES_IN_SCENE,
          {.STORAGE_BUFFER, .INDIRECT_BUFFER, .TRANSFER_DST},
        ) or_return
      pool.camera_random_color_draw_counts[camera_index][frame] =
        gpu.create_mutable_buffer(
          gctx,
          u32,
          1,
          {.STORAGE_BUFFER, .INDIRECT_BUFFER, .TRANSFER_DST},
        ) or_return
      pool.camera_random_color_draw_commands[camera_index][frame] =
        gpu.create_mutable_buffer(
          gctx,
          vk.DrawIndexedIndirectCommand,
          rd.MAX_NODES_IN_SCENE,
          {.STORAGE_BUFFER, .INDIRECT_BUFFER, .TRANSFER_DST},
        ) or_return
      pool.camera_line_strip_draw_counts[camera_index][frame] =
        gpu.create_mutable_buffer(
          gctx,
          u32,
          1,
          {.STORAGE_BUFFER, .INDIRECT_BUFFER, .TRANSFER_DST},
        ) or_return
      pool.camera_line_strip_draw_commands[camera_index][frame] =
        gpu.create_mutable_buffer(
          gctx,
          vk.DrawIndexedIndirectCommand,
          rd.MAX_NODES_IN_SCENE,
          {.STORAGE_BUFFER, .INDIRECT_BUFFER, .TRANSFER_DST},
        ) or_return
      pool.camera_sprite_draw_counts[camera_index][frame] =
        gpu.create_mutable_buffer(
          gctx,
          u32,
          1,
          {.STORAGE_BUFFER, .INDIRECT_BUFFER, .TRANSFER_DST},
        ) or_return
      pool.camera_sprite_draw_commands[camera_index][frame] =
        gpu.create_mutable_buffer(
          gctx,
          vk.DrawIndexedIndirectCommand,
          rd.MAX_NODES_IN_SCENE,
          {.STORAGE_BUFFER, .INDIRECT_BUFFER, .TRANSFER_DST},
        ) or_return
    }
  }
  defer if ret != .SUCCESS {
    for slot in 0 ..< shadow.MAX_SHADOW_MAPS {
      for frame in 0 ..< FRAMES_IN_FLIGHT {
        gpu.free_texture_2d(
          texture_manager,
          gctx,
          pool.shadow_spot_maps[slot][frame],
        )
        gpu.free_texture_2d(
          texture_manager,
          gctx,
          pool.shadow_directional_maps[slot][frame],
        )
        gpu.free_texture_cube(
          texture_manager,
          gctx,
          pool.shadow_point_cubes[slot][frame],
        )
      }
    }
  }
  for slot in 0 ..< shadow.MAX_SHADOW_MAPS {
    for frame in 0 ..< FRAMES_IN_FLIGHT {
      pool.shadow_spot_maps[slot][frame] = gpu.allocate_texture_2d(
        texture_manager,
        gctx,
        vk.Extent2D{shadow.SHADOW_MAP_SIZE, shadow.SHADOW_MAP_SIZE},
        .D32_SFLOAT,
        {.DEPTH_STENCIL_ATTACHMENT, .SAMPLED},
      ) or_return
      pool.shadow_directional_maps[slot][frame] = gpu.allocate_texture_2d(
        texture_manager,
        gctx,
        vk.Extent2D{shadow.SHADOW_MAP_SIZE, shadow.SHADOW_MAP_SIZE},
        .D32_SFLOAT,
        {.DEPTH_STENCIL_ATTACHMENT, .SAMPLED},
      ) or_return
      pool.shadow_point_cubes[slot][frame] = gpu.allocate_texture_cube(
        texture_manager,
        gctx,
        shadow.SHADOW_MAP_SIZE,
        .D32_SFLOAT,
        {.DEPTH_STENCIL_ATTACHMENT, .SAMPLED},
      ) or_return
    }
  }
  defer if ret != .SUCCESS {
    for slot in 0 ..< shadow.MAX_SHADOW_MAPS {
      for frame in 0 ..< FRAMES_IN_FLIGHT {
        gpu.mutable_buffer_destroy(
          gctx.device,
          &pool.shadow_spot_draw_counts[slot][frame],
        )
        gpu.mutable_buffer_destroy(
          gctx.device,
          &pool.shadow_spot_draw_commands[slot][frame],
        )
        gpu.mutable_buffer_destroy(
          gctx.device,
          &pool.shadow_directional_draw_counts[slot][frame],
        )
        gpu.mutable_buffer_destroy(
          gctx.device,
          &pool.shadow_directional_draw_commands[slot][frame],
        )
        gpu.mutable_buffer_destroy(
          gctx.device,
          &pool.shadow_point_draw_counts[slot][frame],
        )
        gpu.mutable_buffer_destroy(
          gctx.device,
          &pool.shadow_point_draw_commands[slot][frame],
        )
      }
    }
  }
  for slot in 0 ..< shadow.MAX_SHADOW_MAPS {
    for frame in 0 ..< FRAMES_IN_FLIGHT {
      pool.shadow_spot_draw_counts[slot][frame] = gpu.create_mutable_buffer(
        gctx,
        u32,
        1,
        {.STORAGE_BUFFER, .INDIRECT_BUFFER},
      ) or_return
      pool.shadow_spot_draw_commands[slot][frame] = gpu.create_mutable_buffer(
        gctx,
        vk.DrawIndexedIndirectCommand,
        rd.MAX_NODES_IN_SCENE,
        {.STORAGE_BUFFER, .INDIRECT_BUFFER},
      ) or_return
      pool.shadow_directional_draw_counts[slot][frame] =
        gpu.create_mutable_buffer(
          gctx,
          u32,
          1,
          {.STORAGE_BUFFER, .INDIRECT_BUFFER},
        ) or_return
      pool.shadow_directional_draw_commands[slot][frame] =
        gpu.create_mutable_buffer(
          gctx,
          vk.DrawIndexedIndirectCommand,
          rd.MAX_NODES_IN_SCENE,
          {.STORAGE_BUFFER, .INDIRECT_BUFFER},
        ) or_return
      pool.shadow_point_draw_counts[slot][frame] = gpu.create_mutable_buffer(
        gctx,
        u32,
        1,
        {.STORAGE_BUFFER, .INDIRECT_BUFFER},
      ) or_return
      pool.shadow_point_draw_commands[slot][frame] = gpu.create_mutable_buffer(
        gctx,
        vk.DrawIndexedIndirectCommand,
        rd.MAX_NODES_IN_SCENE,
        {.STORAGE_BUFFER, .INDIRECT_BUFFER},
      ) or_return
    }
  }

  return .SUCCESS
}

resource_pool_teardown :: proc(
  pool: ^ResourcePool,
  gctx: ^gpu.GPUContext,
  texture_manager: ^gpu.TextureManager,
) {
  gpu.mutable_buffer_destroy(
    gctx.device,
    &pool.particle_resources.particle_buffer,
  )
  gpu.mutable_buffer_destroy(
    gctx.device,
    &pool.particle_resources.compact_particle_buffer,
  )
  gpu.mutable_buffer_destroy(
    gctx.device,
    &pool.particle_resources.draw_command_buffer,
  )
  pool.particle_resources = {}
  for i in 0 ..< FRAMES_IN_FLIGHT {
    gpu.mutable_buffer_destroy(
      gctx.device,
      &pool.ui_resources.vertex_buffers[i],
    )
    gpu.mutable_buffer_destroy(
      gctx.device,
      &pool.ui_resources.index_buffers[i],
    )
  }
  pool.ui_resources = {}
  for camera_index in 0 ..< rd.MAX_ACTIVE_CAMERAS {
    resource_pool_release_camera_resources(
      pool,
      gctx,
      texture_manager,
      u32(camera_index),
    )
  }
  pool.camera_attachments = {}
  pool.camera_depth_pyramids = {}
  pool.camera_cull_input_descriptor_sets = {}
  pool.camera_cull_output_descriptor_sets = {}
  pool.camera_depth_reduce_descriptor_sets = {}
  for camera_index in 0 ..< rd.MAX_ACTIVE_CAMERAS {
    for frame in 0 ..< FRAMES_IN_FLIGHT {
      gpu.mutable_buffer_destroy(
        gctx.device,
        &pool.camera_opaque_draw_counts[camera_index][frame],
      )
      gpu.mutable_buffer_destroy(
        gctx.device,
        &pool.camera_opaque_draw_commands[camera_index][frame],
      )
      gpu.mutable_buffer_destroy(
        gctx.device,
        &pool.camera_transparent_draw_counts[camera_index][frame],
      )
      gpu.mutable_buffer_destroy(
        gctx.device,
        &pool.camera_transparent_draw_commands[camera_index][frame],
      )
      gpu.mutable_buffer_destroy(
        gctx.device,
        &pool.camera_wireframe_draw_counts[camera_index][frame],
      )
      gpu.mutable_buffer_destroy(
        gctx.device,
        &pool.camera_wireframe_draw_commands[camera_index][frame],
      )
      gpu.mutable_buffer_destroy(
        gctx.device,
        &pool.camera_random_color_draw_counts[camera_index][frame],
      )
      gpu.mutable_buffer_destroy(
        gctx.device,
        &pool.camera_random_color_draw_commands[camera_index][frame],
      )
      gpu.mutable_buffer_destroy(
        gctx.device,
        &pool.camera_line_strip_draw_counts[camera_index][frame],
      )
      gpu.mutable_buffer_destroy(
        gctx.device,
        &pool.camera_line_strip_draw_commands[camera_index][frame],
      )
      gpu.mutable_buffer_destroy(
        gctx.device,
        &pool.camera_sprite_draw_counts[camera_index][frame],
      )
      gpu.mutable_buffer_destroy(
        gctx.device,
        &pool.camera_sprite_draw_commands[camera_index][frame],
      )
    }
  }
  pool.camera_opaque_draw_counts = {}
  pool.camera_opaque_draw_commands = {}
  pool.camera_transparent_draw_counts = {}
  pool.camera_transparent_draw_commands = {}
  pool.camera_wireframe_draw_counts = {}
  pool.camera_wireframe_draw_commands = {}
  pool.camera_random_color_draw_counts = {}
  pool.camera_random_color_draw_commands = {}
  pool.camera_line_strip_draw_counts = {}
  pool.camera_line_strip_draw_commands = {}
  pool.camera_sprite_draw_counts = {}
  pool.camera_sprite_draw_commands = {}
  for slot in 0 ..< shadow.MAX_SHADOW_MAPS {
    for frame in 0 ..< FRAMES_IN_FLIGHT {
      gpu.free_texture_2d(
        texture_manager,
        gctx,
        pool.shadow_spot_maps[slot][frame],
      )
      gpu.free_texture_2d(
        texture_manager,
        gctx,
        pool.shadow_directional_maps[slot][frame],
      )
      gpu.free_texture_cube(
        texture_manager,
        gctx,
        pool.shadow_point_cubes[slot][frame],
      )
    }
  }
  pool.shadow_spot_maps = {}
  pool.shadow_directional_maps = {}
  pool.shadow_point_cubes = {}
  for slot in 0 ..< shadow.MAX_SHADOW_MAPS {
    for frame in 0 ..< FRAMES_IN_FLIGHT {
      gpu.mutable_buffer_destroy(
        gctx.device,
        &pool.shadow_spot_draw_counts[slot][frame],
      )
      gpu.mutable_buffer_destroy(
        gctx.device,
        &pool.shadow_spot_draw_commands[slot][frame],
      )
      gpu.mutable_buffer_destroy(
        gctx.device,
        &pool.shadow_directional_draw_counts[slot][frame],
      )
      gpu.mutable_buffer_destroy(
        gctx.device,
        &pool.shadow_directional_draw_commands[slot][frame],
      )
      gpu.mutable_buffer_destroy(
        gctx.device,
        &pool.shadow_point_draw_counts[slot][frame],
      )
      gpu.mutable_buffer_destroy(
        gctx.device,
        &pool.shadow_point_draw_commands[slot][frame],
      )
    }
  }
  pool.shadow_spot_draw_counts = {}
  pool.shadow_spot_draw_commands = {}
  pool.shadow_directional_draw_counts = {}
  pool.shadow_directional_draw_commands = {}
  pool.shadow_point_draw_counts = {}
  pool.shadow_point_draw_commands = {}
}

@(private)
resource_buffer_from_mutable :: proc(
  buffer: gpu.MutableBuffer($T),
  descriptor_set: vk.DescriptorSet = 0,
) -> rg.Buffer {
  return rg.Buffer {
    buffer = buffer.buffer,
    size = vk.DeviceSize(buffer.bytes_count),
    descriptor_set = descriptor_set,
  }
}

@(private)
resource_texture_from_image :: proc(
  image: ^gpu.Image,
  index: u32,
) -> rg.Texture {
  return rg.Texture {
    image = image.image,
    view = image.view,
    extent = image.spec.extent,
    format = image.spec.format,
    index = index,
  }
}

@(private)
resource_depth_from_image :: proc(
  image: ^gpu.Image,
  index: u32,
) -> rg.DepthTexture {
  return rg.DepthTexture {
    image = image.image,
    view = image.view,
    extent = image.spec.extent,
    index = index,
  }
}

@(private)
resource_depth_from_cube :: proc(
  cube: ^gpu.CubeImage,
  index: u32,
) -> rg.DepthTexture {
  return rg.DepthTexture {
    image = cube.image,
    view = cube.view,
    extent = vk.Extent2D{cube.spec.width, cube.spec.height},
    index = index,
  }
}

resolve_resource_index_from_manager :: proc(
  render_manager: rawptr,
  idx: rg.ResourceIndex,
  frame_index, scope_index: u32,
) -> (
  rg.Resource,
  bool,
) {
  // Ownership model:
  // - RenderResourceManager owns all scene/camera/light/frame resources.
  // - post_process.Renderer owns ping-pong images (.POST_PROCESS_IMAGE_0/1).
  // This resolver reads directly from owners to avoid sync/cache duplication.
  manager := cast(^Manager)render_manager
  pool := &manager.resource_pool
  texture_manager := &manager.texture_manager

  if frame_index >= FRAMES_IN_FLIGHT do return {}, false

  #partial switch idx {
  case .NODE_DATA_BUFFER:
    return resource_buffer_from_mutable(
        pool.node_data_buffer.buffer,
        pool.node_data_buffer.descriptor_set,
      ),
      true
  case .MESH_DATA_BUFFER:
    return resource_buffer_from_mutable(
        pool.mesh_data_buffer.buffer,
        pool.mesh_data_buffer.descriptor_set,
      ),
      true
  case .MATERIAL_BUFFER:
    return resource_buffer_from_mutable(
        pool.material_buffer.buffer,
        pool.material_buffer.descriptor_set,
      ),
      true
  case .LIGHTS_BUFFER:
    return resource_buffer_from_mutable(
        pool.lights_buffer.buffer,
        pool.lights_buffer.descriptor_set,
      ),
      true
  case .EMITTER_BUFFER:
    return resource_buffer_from_mutable(
        pool.emitter_buffer.buffer,
        pool.emitter_buffer.descriptor_set,
      ),
      true
  case .FORCEFIELD_BUFFER:
    return resource_buffer_from_mutable(
        pool.forcefield_buffer.buffer,
        pool.forcefield_buffer.descriptor_set,
      ),
      true
  case .SPRITE_BUFFER:
    return resource_buffer_from_mutable(
        pool.sprite_buffer.buffer,
        pool.sprite_buffer.descriptor_set,
      ),
      true
  case .PARTICLE_BUFFER:
    return resource_buffer_from_mutable(
        pool.particle_resources.particle_buffer,
      ),
      true
  case .COMPACT_PARTICLE_BUFFER:
    return resource_buffer_from_mutable(
        pool.particle_resources.compact_particle_buffer,
      ),
      true
  case .DRAW_COMMAND_BUFFER:
    return resource_buffer_from_mutable(
        pool.particle_resources.draw_command_buffer,
      ),
      true
  case .POST_PROCESS_IMAGE_0:
    handle := manager.post_process.images[0]
    if handle.index == 0 do return {}, false
    texture := gpu.get_texture_2d(texture_manager, handle)
    if texture == nil do return {}, false
    return resource_texture_from_image(texture, handle.index), true
  case .POST_PROCESS_IMAGE_1:
    handle := manager.post_process.images[1]
    if handle.index == 0 do return {}, false
    texture := gpu.get_texture_2d(texture_manager, handle)
    if texture == nil do return {}, false
    return resource_texture_from_image(texture, handle.index), true

  case .BONE_BUFFER:
    return resource_buffer_from_mutable(
        pool.bone_buffer.buffers[frame_index],
        pool.bone_buffer.descriptor_sets[frame_index],
      ),
      true
  case .CAMERA_BUFFER:
    return resource_buffer_from_mutable(
        pool.camera_buffer.buffers[frame_index],
        pool.camera_buffer.descriptor_sets[frame_index],
      ),
      true
  case .UI_VERTEX_BUFFER:
    return resource_buffer_from_mutable(
        pool.ui_resources.vertex_buffers[frame_index],
      ),
      true
  case .UI_INDEX_BUFFER:
    return resource_buffer_from_mutable(
        pool.ui_resources.index_buffers[frame_index],
      ),
      true

  case .CAMERA_DEPTH:
    if scope_index >= rd.MAX_ACTIVE_CAMERAS do return {}, false
    handle := pool.camera_attachments[scope_index][.DEPTH][frame_index]
    if handle.index == 0 do return {}, false
    texture := gpu.get_texture_2d(texture_manager, handle)
    if texture == nil do return {}, false
    return resource_depth_from_image(texture, handle.index), true
  case .CAMERA_GBUFFER_POSITION:
    if scope_index >= rd.MAX_ACTIVE_CAMERAS do return {}, false
    handle := pool.camera_attachments[scope_index][.POSITION][frame_index]
    if handle.index == 0 do return {}, false
    texture := gpu.get_texture_2d(texture_manager, handle)
    if texture == nil do return {}, false
    return resource_texture_from_image(texture, handle.index), true
  case .CAMERA_GBUFFER_NORMAL:
    if scope_index >= rd.MAX_ACTIVE_CAMERAS do return {}, false
    handle := pool.camera_attachments[scope_index][.NORMAL][frame_index]
    if handle.index == 0 do return {}, false
    texture := gpu.get_texture_2d(texture_manager, handle)
    if texture == nil do return {}, false
    return resource_texture_from_image(texture, handle.index), true
  case .CAMERA_GBUFFER_ALBEDO:
    if scope_index >= rd.MAX_ACTIVE_CAMERAS do return {}, false
    handle := pool.camera_attachments[scope_index][.ALBEDO][frame_index]
    if handle.index == 0 do return {}, false
    texture := gpu.get_texture_2d(texture_manager, handle)
    if texture == nil do return {}, false
    return resource_texture_from_image(texture, handle.index), true
  case .CAMERA_GBUFFER_METALLIC_ROUGHNESS:
    if scope_index >= rd.MAX_ACTIVE_CAMERAS do return {}, false
    handle :=
      pool.camera_attachments[scope_index][.METALLIC_ROUGHNESS][frame_index]
    if handle.index == 0 do return {}, false
    texture := gpu.get_texture_2d(texture_manager, handle)
    if texture == nil do return {}, false
    return resource_texture_from_image(texture, handle.index), true
  case .CAMERA_GBUFFER_EMISSIVE:
    if scope_index >= rd.MAX_ACTIVE_CAMERAS do return {}, false
    handle := pool.camera_attachments[scope_index][.EMISSIVE][frame_index]
    if handle.index == 0 do return {}, false
    texture := gpu.get_texture_2d(texture_manager, handle)
    if texture == nil do return {}, false
    return resource_texture_from_image(texture, handle.index), true
  case .CAMERA_FINAL_IMAGE:
    if scope_index >= rd.MAX_ACTIVE_CAMERAS do return {}, false
    handle := pool.camera_attachments[scope_index][.FINAL_IMAGE][frame_index]
    if handle.index == 0 do return {}, false
    texture := gpu.get_texture_2d(texture_manager, handle)
    if texture == nil do return {}, false
    return resource_texture_from_image(texture, handle.index), true
  case .CAMERA_DEPTH_PYRAMID:
    if scope_index >= rd.MAX_ACTIVE_CAMERAS do return {}, false
    pyramid := &pool.camera_depth_pyramids[scope_index][frame_index]
    if pyramid.texture.index == 0 do return {}, false
    texture := gpu.get_texture_2d(texture_manager, pyramid.texture)
    if texture == nil do return {}, false
    return rg.Texture {
        image = texture.image,
        view = pyramid.full_view,
        extent = texture.spec.extent,
        format = texture.spec.format,
        index = pyramid.texture.index,
      },
      true
  case .CAMERA_OPAQUE_DRAW_COMMANDS:
    if scope_index >= rd.MAX_ACTIVE_CAMERAS do return {}, false
    return resource_buffer_from_mutable(
        pool.camera_opaque_draw_commands[scope_index][frame_index],
      ),
      true
  case .CAMERA_OPAQUE_DRAW_COUNT:
    if scope_index >= rd.MAX_ACTIVE_CAMERAS do return {}, false
    return resource_buffer_from_mutable(
        pool.camera_opaque_draw_counts[scope_index][frame_index],
      ),
      true
  case .CAMERA_TRANSPARENT_DRAW_COMMANDS:
    if scope_index >= rd.MAX_ACTIVE_CAMERAS do return {}, false
    return resource_buffer_from_mutable(
        pool.camera_transparent_draw_commands[scope_index][frame_index],
      ),
      true
  case .CAMERA_TRANSPARENT_DRAW_COUNT:
    if scope_index >= rd.MAX_ACTIVE_CAMERAS do return {}, false
    return resource_buffer_from_mutable(
        pool.camera_transparent_draw_counts[scope_index][frame_index],
      ),
      true
  case .CAMERA_WIREFRAME_DRAW_COMMANDS:
    if scope_index >= rd.MAX_ACTIVE_CAMERAS do return {}, false
    return resource_buffer_from_mutable(
        pool.camera_wireframe_draw_commands[scope_index][frame_index],
      ),
      true
  case .CAMERA_WIREFRAME_DRAW_COUNT:
    if scope_index >= rd.MAX_ACTIVE_CAMERAS do return {}, false
    return resource_buffer_from_mutable(
        pool.camera_wireframe_draw_counts[scope_index][frame_index],
      ),
      true
  case .CAMERA_RANDOM_COLOR_DRAW_COMMANDS:
    if scope_index >= rd.MAX_ACTIVE_CAMERAS do return {}, false
    return resource_buffer_from_mutable(
        pool.camera_random_color_draw_commands[scope_index][frame_index],
      ),
      true
  case .CAMERA_RANDOM_COLOR_DRAW_COUNT:
    if scope_index >= rd.MAX_ACTIVE_CAMERAS do return {}, false
    return resource_buffer_from_mutable(
        pool.camera_random_color_draw_counts[scope_index][frame_index],
      ),
      true
  case .CAMERA_LINE_STRIP_DRAW_COMMANDS:
    if scope_index >= rd.MAX_ACTIVE_CAMERAS do return {}, false
    return resource_buffer_from_mutable(
        pool.camera_line_strip_draw_commands[scope_index][frame_index],
      ),
      true
  case .CAMERA_LINE_STRIP_DRAW_COUNT:
    if scope_index >= rd.MAX_ACTIVE_CAMERAS do return {}, false
    return resource_buffer_from_mutable(
        pool.camera_line_strip_draw_counts[scope_index][frame_index],
      ),
      true
  case .CAMERA_SPRITE_DRAW_COMMANDS:
    if scope_index >= rd.MAX_ACTIVE_CAMERAS do return {}, false
    return resource_buffer_from_mutable(
        pool.camera_sprite_draw_commands[scope_index][frame_index],
      ),
      true
  case .CAMERA_SPRITE_DRAW_COUNT:
    if scope_index >= rd.MAX_ACTIVE_CAMERAS do return {}, false
    return resource_buffer_from_mutable(
        pool.camera_sprite_draw_counts[scope_index][frame_index],
      ),
      true

  case .SHADOW_DRAW_COMMANDS:
    if scope_index >= shadow.MAX_SHADOW_MAPS || !manager.shadow.slot_active[scope_index] do return {}, false
    switch manager.shadow.slot_kind[scope_index] {
    case .SPOT:
      return resource_buffer_from_mutable(
          pool.shadow_spot_draw_commands[scope_index][frame_index],
        ),
        true
    case .DIRECTIONAL:
      return resource_buffer_from_mutable(
          pool.shadow_directional_draw_commands[scope_index][frame_index],
        ),
        true
    case .POINT:
      return resource_buffer_from_mutable(
          pool.shadow_point_draw_commands[scope_index][frame_index],
        ),
        true
    }
  case .SHADOW_DRAW_COUNT:
    if scope_index >= shadow.MAX_SHADOW_MAPS || !manager.shadow.slot_active[scope_index] do return {}, false
    switch manager.shadow.slot_kind[scope_index] {
    case .SPOT:
      return resource_buffer_from_mutable(
          pool.shadow_spot_draw_counts[scope_index][frame_index],
        ),
        true
    case .DIRECTIONAL:
      return resource_buffer_from_mutable(
          pool.shadow_directional_draw_counts[scope_index][frame_index],
        ),
        true
    case .POINT:
      return resource_buffer_from_mutable(
          pool.shadow_point_draw_counts[scope_index][frame_index],
        ),
        true
    }
  case .SHADOW_MAP:
    if scope_index >= shadow.MAX_SHADOW_MAPS || !manager.shadow.slot_active[scope_index] do return {}, false
    switch manager.shadow.slot_kind[scope_index] {
    case .SPOT:
      handle := pool.shadow_spot_maps[scope_index][frame_index]
      if handle.index == 0 do return {}, false
      texture := gpu.get_texture_2d(texture_manager, handle)
      if texture == nil do return {}, false
      return resource_depth_from_image(texture, handle.index), true
    case .DIRECTIONAL:
      handle := pool.shadow_directional_maps[scope_index][frame_index]
      if handle.index == 0 do return {}, false
      texture := gpu.get_texture_2d(texture_manager, handle)
      if texture == nil do return {}, false
      return resource_depth_from_image(texture, handle.index), true
    case .POINT:
      handle := pool.shadow_point_cubes[scope_index][frame_index]
      if handle.index == 0 do return {}, false
      cube := gpu.get_texture_cube(texture_manager, handle)
      if cube == nil do return {}, false
      return resource_depth_from_cube(cube, handle.index), true
    }
  }
  return {}, false
}

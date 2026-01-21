package resources

import alg "../algebra"
import cont "../containers"
import "../geometry"
import "../gpu"
import "core:log"
import "core:math"
import "core:math/linalg"
import vk "vendor:vulkan"

MAX_DEPTH_MIPS_LEVEL :: 16

PerspectiveProjection :: struct {
  fov:          f32,
  aspect_ratio: f32,
  near:         f32,
  far:          f32,
}

OrthographicProjection :: struct {
  width:  f32,
  height: f32,
  near:   f32,
  far:    f32,
}

CameraData :: struct {
  view:            matrix[4, 4]f32,
  projection:      matrix[4, 4]f32,
  // TODO: consider store inverse view, inverse projection
  viewport_params: [4]f32,
  position:        [4]f32,
  frustum_planes:  [6][4]f32,
}

// GPU-side spherical camera data (optimized for point light shadows)
// Only contains what's actually used by shadow rendering and lighting passes
SphericalCameraData :: struct {
  projection: matrix[4, 4]f32, // 90-degree FOV for cube faces
  position:   [4]f32, // center.xyz, radius in w
  near_far:   [2]f32, // near, far planes
  _padding:   [2]f32, // Align to 16 bytes
}

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
  NAVIGATION   = 5,
  DEBUG_DRAW   = 6,
  POST_PROCESS = 7,
}

PassTypeSet :: bit_set[PassType;u32]

Camera :: struct {
  position:                     [3]f32,
  rotation:                     quaternion128,
  projection:                   union {
    PerspectiveProjection,
    OrthographicProjection,
  },
  // Per-frame GPU data
  // Frame N compute uses data[N] for culling, Frame N render uses data[N-1] for drawing
  data:                         [FRAMES_IN_FLIGHT]CameraData,
  // Render target data
  extent:                       vk.Extent2D,
  attachments:                  [AttachmentType][FRAMES_IN_FLIGHT]Image2DHandle,
  enabled_passes:               PassTypeSet,
  // Visibility culling control flags
  enable_culling:               bool, // If false, skip culling compute pass
  enable_depth_pyramid:         bool, // If false, skip depth pyramid generation
  // Double-buffered draw lists for lock-free async compute:
  //   - Frame N graphics reads from draw_commands[N-1]
  //   - Frame N compute writes to draw_commands[N]
  // Graphics reads from previous frame's draw list while compute prepares current frame's list
  opaque_draw_count:            [FRAMES_IN_FLIGHT]gpu.MutableBuffer(u32),
  opaque_draw_commands:         [FRAMES_IN_FLIGHT]gpu.MutableBuffer(
    vk.DrawIndexedIndirectCommand,
  ),
  transparent_draw_count:       [FRAMES_IN_FLIGHT]gpu.MutableBuffer(u32),
  transparent_draw_commands:    [FRAMES_IN_FLIGHT]gpu.MutableBuffer(
    vk.DrawIndexedIndirectCommand,
  ),
  sprite_draw_count:            [FRAMES_IN_FLIGHT]gpu.MutableBuffer(u32),
  sprite_draw_commands:         [FRAMES_IN_FLIGHT]gpu.MutableBuffer(
    vk.DrawIndexedIndirectCommand,
  ),
  // External draw list source (if set, use this camera's draw lists instead of own)
  draw_list_source:             ^Camera,
  depth_pyramid:                [FRAMES_IN_FLIGHT]DepthPyramid,
  descriptor_set:               [FRAMES_IN_FLIGHT]vk.DescriptorSet,
  depth_reduce_descriptor_sets: [FRAMES_IN_FLIGHT][MAX_DEPTH_MIPS_LEVEL]vk.DescriptorSet,
}

DepthPyramid :: struct {
  texture:    Image2DHandle,
  views:      [MAX_DEPTH_MIPS_LEVEL]vk.ImageView,
  full_view:  vk.ImageView,
  sampler:    vk.Sampler,
  mip_levels: u32,
  width:      u32,
  height:     u32,
}

camera_init :: proc(
  camera: ^Camera,
  gctx: ^gpu.GPUContext,
  rm: ^Manager,
  width, height: u32,
  color_format, depth_format: vk.Format,
  enabled_passes: PassTypeSet = {
    .SHADOW,
    .GEOMETRY,
    .LIGHTING,
    .TRANSPARENCY,
    .PARTICLES,
    .NAVIGATION,
    .POST_PROCESS,
  },
  camera_position: [3]f32 = {0, 0, 3},
  camera_target: [3]f32 = {0, 0, 0},
  fov: f32 = 1.57079632679,
  near_plane: f32 = 0.1,
  far_plane: f32 = 100.0,
  max_draws: u32 = MAX_NODES_IN_SCENE,
) -> vk.Result {
  camera.rotation = linalg.QUATERNIONF32_IDENTITY
  camera.projection = PerspectiveProjection {
    fov          = fov,
    aspect_ratio = f32(width) / f32(height),
    near         = near_plane,
    far          = far_plane,
  }
  camera.position = camera_position
  forward := linalg.normalize(camera_target - camera_position)
  safe_up := linalg.VECTOR3F32_Y_AXIS
  if math.abs(linalg.dot(forward, safe_up)) > 0.999 {
    safe_up = linalg.VECTOR3F32_Z_AXIS
    if math.abs(linalg.dot(forward, safe_up)) > 0.999 {
      safe_up = linalg.VECTOR3F32_X_AXIS
    }
  }
  right := linalg.normalize(linalg.cross(forward, safe_up))
  recalc_up := linalg.cross(right, forward)
  rotation_matrix := matrix[3, 3]f32{
    right.x, recalc_up.x, -forward.x,
    right.y, recalc_up.y, -forward.y,
    right.z, recalc_up.z, -forward.z,
  }
  camera.rotation = linalg.to_quaternion(rotation_matrix)
  camera.extent = {width, height}
  camera.enabled_passes = enabled_passes
  // Enable culling and depth pyramid by default
  camera.enable_culling = true
  camera.enable_depth_pyramid = true
  camera.draw_list_source = nil
  needs_gbuffer := .GEOMETRY in enabled_passes || .LIGHTING in enabled_passes
  needs_final :=
    .LIGHTING in enabled_passes ||
    .TRANSPARENCY in enabled_passes ||
    .PARTICLES in enabled_passes ||
    .POST_PROCESS in enabled_passes
  for frame in 0 ..< FRAMES_IN_FLIGHT {
    if needs_final {
      camera.attachments[.FINAL_IMAGE][frame] =
      create_texture(
        gctx,
        rm,
        width,
        height,
        color_format,
        vk.ImageUsageFlags{.COLOR_ATTACHMENT, .SAMPLED},
      ) or_continue
    }
    if needs_gbuffer {
      camera.attachments[.POSITION][frame] =
      create_texture(
        gctx,
        rm,
        width,
        height,
        vk.Format.R32G32B32A32_SFLOAT,
        vk.ImageUsageFlags{.COLOR_ATTACHMENT, .SAMPLED},
      ) or_continue
      camera.attachments[.NORMAL][frame] =
      create_texture(
        gctx,
        rm,
        width,
        height,
        vk.Format.R8G8B8A8_UNORM,
        vk.ImageUsageFlags{.COLOR_ATTACHMENT, .SAMPLED},
      ) or_continue
      camera.attachments[.ALBEDO][frame] =
      create_texture(
        gctx,
        rm,
        width,
        height,
        vk.Format.R8G8B8A8_UNORM,
        vk.ImageUsageFlags{.COLOR_ATTACHMENT, .SAMPLED},
      ) or_continue
      camera.attachments[.METALLIC_ROUGHNESS][frame] =
      create_texture(
        gctx,
        rm,
        width,
        height,
        vk.Format.R8G8B8A8_UNORM,
        vk.ImageUsageFlags{.COLOR_ATTACHMENT, .SAMPLED},
      ) or_continue
      camera.attachments[.EMISSIVE][frame] =
      create_texture(
        gctx,
        rm,
        width,
        height,
        vk.Format.R8G8B8A8_UNORM,
        vk.ImageUsageFlags{.COLOR_ATTACHMENT, .SAMPLED},
      ) or_continue
    }
    camera.attachments[.DEPTH][frame] =
    create_texture(
      gctx,
      rm,
      width,
      height,
      depth_format,
      vk.ImageUsageFlags{.DEPTH_STENCIL_ATTACHMENT, .SAMPLED},
    ) or_continue
    // Transition depth image from UNDEFINED to DEPTH_STENCIL_READ_ONLY_OPTIMAL
    if depth, ok := cont.get(rm.images_2d, camera.attachments[.DEPTH][frame]);
       ok {
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
  for frame in 0 ..< FRAMES_IN_FLIGHT {
    create_camera_depth_pyramid(
      gctx,
      rm,
      camera,
      width,
      height,
      u32(frame),
    ) or_return
  }
  return .SUCCESS
}

camera_init_orthographic :: proc(
  camera: ^Camera,
  gctx: ^gpu.GPUContext,
  rm: ^Manager,
  width, height: u32,
  color_format, depth_format: vk.Format,
  enabled_passes: PassTypeSet = {.SHADOW},
  camera_position: [3]f32 = {0, 0, 0},
  camera_target: [3]f32 = {0, 0, -1},
  ortho_width: f32 = 100.0,
  ortho_height: f32 = 100.0,
  near_plane: f32 = 1.0,
  far_plane: f32 = 1000.0,
  max_draws: u32 = MAX_NODES_IN_SCENE,
) -> vk.Result {
  camera.rotation = linalg.QUATERNIONF32_IDENTITY
  camera.projection = OrthographicProjection {
    width  = ortho_width,
    height = ortho_height,
    near   = near_plane,
    far    = far_plane,
  }
  camera.position = camera_position
  forward := linalg.normalize(camera_target - camera_position)
  safe_up := linalg.VECTOR3F32_Y_AXIS
  if math.abs(linalg.dot(forward, safe_up)) > 0.999 {
    safe_up = linalg.VECTOR3F32_Z_AXIS
    if math.abs(linalg.dot(forward, safe_up)) > 0.999 {
      safe_up = linalg.VECTOR3F32_X_AXIS
    }
  }
  right := linalg.normalize(linalg.cross(forward, safe_up))
  recalc_up := linalg.cross(right, forward)
  rotation_matrix := matrix[3, 3]f32{
    right.x, recalc_up.x, -forward.x,
    right.y, recalc_up.y, -forward.y,
    right.z, recalc_up.z, -forward.z,
  }
  camera.rotation = linalg.to_quaternion(rotation_matrix)
  camera.extent = {width, height}
  camera.enabled_passes = enabled_passes
  // Enable culling and depth pyramid by default
  camera.enable_culling = true
  camera.enable_depth_pyramid = true
  camera.draw_list_source = nil
  needs_gbuffer := .GEOMETRY in enabled_passes || .LIGHTING in enabled_passes
  needs_final :=
    .LIGHTING in enabled_passes ||
    .TRANSPARENCY in enabled_passes ||
    .PARTICLES in enabled_passes ||
    .POST_PROCESS in enabled_passes
  for frame in 0 ..< FRAMES_IN_FLIGHT {
    if needs_final {
      camera.attachments[.FINAL_IMAGE][frame] =
      create_texture(
        gctx,
        rm,
        width,
        height,
        color_format,
        vk.ImageUsageFlags{.COLOR_ATTACHMENT, .SAMPLED},
      ) or_continue
    }
    if needs_gbuffer {
      camera.attachments[.POSITION][frame] =
      create_texture(
        gctx,
        rm,
        width,
        height,
        vk.Format.R32G32B32A32_SFLOAT,
        vk.ImageUsageFlags{.COLOR_ATTACHMENT, .SAMPLED},
      ) or_continue
      camera.attachments[.NORMAL][frame] =
      create_texture(
        gctx,
        rm,
        width,
        height,
        vk.Format.R8G8B8A8_UNORM,
        vk.ImageUsageFlags{.COLOR_ATTACHMENT, .SAMPLED},
      ) or_continue
      camera.attachments[.ALBEDO][frame] =
      create_texture(
        gctx,
        rm,
        width,
        height,
        vk.Format.R8G8B8A8_UNORM,
        vk.ImageUsageFlags{.COLOR_ATTACHMENT, .SAMPLED},
      ) or_continue
      camera.attachments[.METALLIC_ROUGHNESS][frame] =
      create_texture(
        gctx,
        rm,
        width,
        height,
        vk.Format.R8G8B8A8_UNORM,
        vk.ImageUsageFlags{.COLOR_ATTACHMENT, .SAMPLED},
      ) or_continue
      camera.attachments[.EMISSIVE][frame] =
      create_texture(
        gctx,
        rm,
        width,
        height,
        vk.Format.R8G8B8A8_UNORM,
        vk.ImageUsageFlags{.COLOR_ATTACHMENT, .SAMPLED},
      ) or_continue
    }
    camera.attachments[.DEPTH][frame] =
    create_texture(
      gctx,
      rm,
      width,
      height,
      depth_format,
      vk.ImageUsageFlags{.DEPTH_STENCIL_ATTACHMENT, .SAMPLED},
    ) or_continue
    if depth, ok := cont.get(rm.images_2d, camera.attachments[.DEPTH][frame]);
       ok {
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
  for frame in 0 ..< FRAMES_IN_FLIGHT {
    create_camera_depth_pyramid(
      gctx,
      rm,
      camera,
      width,
      height,
      u32(frame),
    ) or_return
  }
  return .SUCCESS
}

camera_destroy :: proc(self: ^Camera, gctx: ^gpu.GPUContext, rm: ^Manager) {
  for handles in self.attachments {
    for handle in handles {
      if item, freed := cont.free(&rm.images_2d, handle); freed {
        gpu.image_destroy(gctx.device, item)
      }
    }
  }
  for frame in 0 ..< FRAMES_IN_FLIGHT {
    for mip in 0 ..< self.depth_pyramid[frame].mip_levels {
      vk.DestroyImageView(
        gctx.device,
        self.depth_pyramid[frame].views[mip],
        nil,
      )
    }
    vk.DestroyImageView(gctx.device, self.depth_pyramid[frame].full_view, nil)
    vk.DestroySampler(gctx.device, self.depth_pyramid[frame].sampler, nil)
    gpu.mutable_buffer_destroy(gctx.device, &self.opaque_draw_count[frame])
    gpu.mutable_buffer_destroy(gctx.device, &self.opaque_draw_commands[frame])
    gpu.mutable_buffer_destroy(
      gctx.device,
      &self.transparent_draw_count[frame],
    )
    gpu.mutable_buffer_destroy(
      gctx.device,
      &self.transparent_draw_commands[frame],
    )
    gpu.mutable_buffer_destroy(gctx.device, &self.sprite_draw_count[frame])
    gpu.mutable_buffer_destroy(gctx.device, &self.sprite_draw_commands[frame])
    // Free depth pyramid texture
    if pyramid_item, freed := cont.free(
      &rm.images_2d,
      self.depth_pyramid[frame].texture,
    ); freed {
      gpu.image_destroy(gctx.device, pyramid_item)
    }
  }
}

camera_view_matrix :: proc(camera: ^Camera) -> matrix[4, 4]f32 {
  forward_vec := camera_forward(camera)
  up_vec := camera_up(camera)
  target_point := camera.position + forward_vec
  return linalg.matrix4_look_at(camera.position, target_point, up_vec)
}

camera_projection_matrix :: proc(camera: ^Camera) -> matrix[4, 4]f32 {
  switch proj in camera.projection {
  case PerspectiveProjection:
    // Use Odin's perspective - it works with Vulkan
    return linalg.matrix4_perspective(
      proj.fov,
      proj.aspect_ratio,
      proj.near,
      proj.far,
    )
  case OrthographicProjection:
    // Vulkan-style orthographic projection
    // Maps z_view in [-far, -near] to z_ndc in [0, 1]
    hw := proj.width / 2
    hh := proj.height / 2
    return matrix[4, 4]f32{
      1/hw, 0,    0,                                0,
      0,    1/hh, 0,                                0,
      0,    0,    1/(proj.near - proj.far),         0,
      0,    0,    proj.near/(proj.near - proj.far), 1,
    }
  case:
    return linalg.MATRIX4F32_IDENTITY
  }
}

camera_forward :: proc(self: ^Camera) -> [3]f32 {
  return geometry.qmv(self.rotation, -linalg.VECTOR3F32_Z_AXIS)
}

camera_right :: proc(self: ^Camera) -> [3]f32 {
  return geometry.qmv(self.rotation, linalg.VECTOR3F32_X_AXIS)
}

camera_up :: proc(self: ^Camera) -> [3]f32 {
  return geometry.qmv(self.rotation, linalg.VECTOR3F32_Y_AXIS)
}

camera_get_near_far :: proc(self: ^Camera) -> (near: f32, far: f32) {
  switch proj in self.projection {
  case PerspectiveProjection:
    return proj.near, proj.far
  case OrthographicProjection:
    return proj.near, proj.far
  case:
    return 0.1, 50.0
  }
}

camera_look_at :: proc(
  self: ^Camera,
  from, to: [3]f32,
) {
  self.position = from
  forward := linalg.normalize(to - from)
  safe_up := linalg.VECTOR3F32_Y_AXIS
  if math.abs(linalg.dot(forward, safe_up)) > 0.999 {
    safe_up = linalg.VECTOR3F32_Z_AXIS
    if math.abs(linalg.dot(forward, safe_up)) > 0.999 {
      safe_up = linalg.VECTOR3F32_X_AXIS
    }
  }
  right := linalg.normalize(linalg.cross(forward, safe_up))
  recalc_up := linalg.cross(right, forward)
  rotation_matrix := matrix[3, 3]f32{
    right.x, recalc_up.x, -forward.x,
    right.y, recalc_up.y, -forward.y,
    right.z, recalc_up.z, -forward.z,
  }
  self.rotation = linalg.to_quaternion(rotation_matrix)
}

camera_update_aspect_ratio :: proc(self: ^Camera, new_aspect_ratio: f32) {
  switch &proj in self.projection {
  case PerspectiveProjection:
    proj.aspect_ratio = new_aspect_ratio
  case OrthographicProjection:
  // For orthographic projection, might want to adjust width/height
  }
}

camera_resize :: proc(
  camera: ^Camera,
  gctx: ^gpu.GPUContext,
  rm: ^Manager,
  width, height: u32,
  color_format: vk.Format,
  depth_format: vk.Format,
) -> vk.Result {
  if camera.extent.width == width && camera.extent.height == height do return .SUCCESS
  vk.DeviceWaitIdle(gctx.device) or_return
  // Destroy depth pyramids (views, samplers, textures)
  for &p in camera.depth_pyramid {
    for mip in 0 ..< p.mip_levels {
      vk.DestroyImageView(gctx.device, p.views[mip], nil)
    }
    vk.DestroyImageView(gctx.device, p.full_view, nil)
    vk.DestroySampler(gctx.device, p.sampler, nil)
    if pyramid_item, freed := cont.free(&rm.images_2d, p.texture); freed {
      gpu.image_destroy(gctx.device, pyramid_item)
    }
  }
  for handles in camera.attachments {
    for handle in handles {
      if item, freed := cont.free(&rm.images_2d, handle); freed {
        gpu.image_destroy(gctx.device, item)
      }
    }
  }
  camera.extent = {width, height}
  if perspective, ok := &camera.projection.(PerspectiveProjection); ok {
    perspective.aspect_ratio = f32(width) / f32(height)
  }
  needs_gbuffer :=
    .GEOMETRY in camera.enabled_passes || .LIGHTING in camera.enabled_passes
  needs_final :=
    .LIGHTING in camera.enabled_passes ||
    .TRANSPARENCY in camera.enabled_passes ||
    .PARTICLES in camera.enabled_passes ||
    .POST_PROCESS in camera.enabled_passes
  for frame in 0 ..< FRAMES_IN_FLIGHT {
    if needs_final {
      camera.attachments[.FINAL_IMAGE][frame] =
      create_texture(
        gctx,
        rm,
        width,
        height,
        color_format,
        vk.ImageUsageFlags{.COLOR_ATTACHMENT, .SAMPLED},
      ) or_continue
    }
    if needs_gbuffer {
      camera.attachments[.POSITION][frame] =
      create_texture(
        gctx,
        rm,
        width,
        height,
        vk.Format.R32G32B32A32_SFLOAT,
        vk.ImageUsageFlags{.COLOR_ATTACHMENT, .SAMPLED},
      ) or_continue
      camera.attachments[.NORMAL][frame] =
      create_texture(
        gctx,
        rm,
        width,
        height,
        vk.Format.R8G8B8A8_UNORM,
        vk.ImageUsageFlags{.COLOR_ATTACHMENT, .SAMPLED},
      ) or_continue
      camera.attachments[.ALBEDO][frame] =
      create_texture(
        gctx,
        rm,
        width,
        height,
        vk.Format.R8G8B8A8_UNORM,
        vk.ImageUsageFlags{.COLOR_ATTACHMENT, .SAMPLED},
      ) or_continue
      camera.attachments[.METALLIC_ROUGHNESS][frame] =
      create_texture(
        gctx,
        rm,
        width,
        height,
        vk.Format.R8G8B8A8_UNORM,
        vk.ImageUsageFlags{.COLOR_ATTACHMENT, .SAMPLED},
      ) or_continue
      camera.attachments[.EMISSIVE][frame] =
      create_texture(
        gctx,
        rm,
        width,
        height,
        vk.Format.R8G8B8A8_UNORM,
        vk.ImageUsageFlags{.COLOR_ATTACHMENT, .SAMPLED},
      ) or_continue
    }
    camera.attachments[.DEPTH][frame] =
    create_texture(
      gctx,
      rm,
      width,
      height,
      depth_format,
      vk.ImageUsageFlags{.DEPTH_STENCIL_ATTACHMENT, .SAMPLED},
    ) or_continue
    depth_tex := cont.get(rm.images_2d, camera.attachments[.DEPTH][frame])
    if depth_tex != nil {
      cmd_buf := gpu.begin_single_time_command(gctx) or_return
      gpu.image_barrier(
        cmd_buf,
        depth_tex.image,
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
  // Create all depth pyramids first
  for frame in 0 ..< FRAMES_IN_FLIGHT {
    create_camera_depth_pyramid(
      gctx,
      rm,
      camera,
      width,
      height,
      u32(frame),
    ) or_return
  }
  // Then update all descriptors (references prev_frame pyramids, so all must exist first)
  for frame in 0 ..< FRAMES_IN_FLIGHT {
    camera_update_descriptors(gctx, rm, camera, u32(frame))
  }
  log.infof("Camera resized to %dx%d", width, height)
  return .SUCCESS
}

camera_get_visible_count :: proc(camera: ^Camera, frame_index: u32) -> u32 {
  if camera.opaque_draw_count[frame_index].mapped == nil do return 0
  return camera.opaque_draw_count[frame_index].mapped[0]
}

// TODO: this procedure has around 8 matrices operations, if you run this thousands times per frame you should optimize it first
camera_viewport_to_world_ray :: proc(
  camera: ^Camera,
  mouse_x, mouse_y: f32,
) -> (
  ray_origin: [3]f32,
  ray_dir: [3]f32,
) {
  // Convert screen coordinates to normalized device coordinates (NDC)
  ndc_x := (2.0 * mouse_x) / f32(camera.extent.width) - 1.0
  ndc_y := 1.0 - (2.0 * mouse_y) / f32(camera.extent.height)
  // Get view and projection matrices
  view_matrix := camera_view_matrix(camera)
  proj_matrix := camera_projection_matrix(camera)
  inv_proj := linalg.matrix4_inverse(proj_matrix)
  inv_view := linalg.matrix4_inverse(view_matrix)
  // Ray in clip space
  ray_clip := [4]f32{ndc_x, ndc_y, -1.0, 1.0}
  // Ray in view space
  ray_eye := inv_proj * ray_clip
  ray_eye = [4]f32{ray_eye.x, ray_eye.y, -1.0, 0.0}
  // Ray in world space
  ray_world_4 := inv_view * ray_eye
  ray_dir = linalg.normalize(ray_world_4.xyz)
  ray_origin = camera.position
  return ray_origin, ray_dir
}

@(private)
create_camera_depth_pyramid :: proc(
  gctx: ^gpu.GPUContext,
  rm: ^Manager,
  camera: ^Camera,
  width: u32,
  height: u32,
  frame_index: u32,
) -> vk.Result {
  depth_handle := camera.attachments[.DEPTH][frame_index]
  log.debugf(
    "Using depth texture at bindless index %d for frame %d",
    depth_handle.index,
    frame_index,
  )
  // Depth pyramid dimensions: mip 0 is HALF the resolution of source depth texture
  pyramid_width := max(1, width / 2)
  pyramid_height := max(1, height / 2)
  // Calculate mip levels for depth pyramid based on pyramid base size
  mip_levels :=
    u32(math.floor(math.log2(f32(max(pyramid_width, pyramid_height))))) + 1
  // Create depth pyramid texture with mip levels using new Image API
  pyramid_handle, pyramid_texture, pyramid_ok := cont.alloc(
    &rm.images_2d,
    Image2DHandle,
  )
  if !pyramid_ok {
    log.error("Failed to allocate handle for depth pyramid texture")
    return .ERROR_OUT_OF_DEVICE_MEMORY
  }
  spec := gpu.image_spec_2d(
    pyramid_width,
    pyramid_height,
    .R32_SFLOAT,
    {.SAMPLED, .STORAGE, .TRANSFER_DST},
    true,
  )
  spec.mip_levels = mip_levels
  pyramid_texture^ = gpu.image_create(gctx, spec) or_return
  // Transition all mip levels from UNDEFINED to GENERAL layout for compute shader read/write
  // Use immediate command buffer for initialization
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
  // Register the auto-created view in bindless texture array
  set_texture_2d_descriptor(
    gctx,
    rm,
    pyramid_handle.index,
    pyramid_texture.view,
  )
  camera.depth_pyramid[frame_index].texture = pyramid_handle
  camera.depth_pyramid[frame_index].mip_levels = mip_levels
  camera.depth_pyramid[frame_index].width = pyramid_width
  camera.depth_pyramid[frame_index].height = pyramid_height
  log.debugf(
    "Created depth pyramid texture at bindless index %d with %d mip levels for frame %d",
    pyramid_handle.index,
    mip_levels,
    frame_index,
  )
  // Create per-mip views for depth reduction shader (write to individual mips)
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
  // Create full pyramid view for culling shader (sample from all mips)
  full_view_info := vk.ImageViewCreateInfo {
    sType = .IMAGE_VIEW_CREATE_INFO,
    image = pyramid_texture.image,
    viewType = .D2,
    format = .R32_SFLOAT,
    subresourceRange = {
      aspectMask = {.COLOR},
      levelCount = mip_levels, // ALL mip levels accessible
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
    minLod       = 0,
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

camera_allocate_descriptors :: proc(
  gctx: ^gpu.GPUContext,
  rm: ^Manager,
  camera: ^Camera,
  frame_index: u32,
  normal_cam_descriptor_layout: ^vk.DescriptorSetLayout,
  depth_reduce_descriptor_layout: ^vk.DescriptorSetLayout,
) -> vk.Result {
  gpu.allocate_descriptor_set(
    gctx,
    &camera.descriptor_set[frame_index],
    normal_cam_descriptor_layout,
  ) or_return
  // Allocate all 16 possible descriptor sets upfront to handle any mip count on resize
  for mip in 0 ..< MAX_DEPTH_MIPS_LEVEL {
    gpu.allocate_descriptor_set(
      gctx,
      &camera.depth_reduce_descriptor_sets[frame_index][mip],
      depth_reduce_descriptor_layout,
    ) or_return
  }
  camera_update_descriptors(gctx, rm, camera, frame_index)
  return .SUCCESS
}

camera_update_descriptors :: proc(
  gctx: ^gpu.GPUContext,
  rm: ^Manager,
  camera: ^Camera,
  frame_index: u32,
) {
  prev_frame := alg.prev(frame_index, FRAMES_IN_FLIGHT)
  // Update all descriptor bindings (buffers don't change, only image views/samplers)
  gpu.update_descriptor_set(
    gctx,
    camera.descriptor_set[frame_index],
    {.STORAGE_BUFFER, gpu.buffer_info(&rm.node_data_buffer.buffer)},
    {.STORAGE_BUFFER, gpu.buffer_info(&rm.mesh_data_buffer.buffer)},
    {.STORAGE_BUFFER, gpu.buffer_info(&rm.world_matrix_buffer.buffer)},
    {.STORAGE_BUFFER, gpu.buffer_info(&rm.camera_buffer.buffers[frame_index])},
    {.STORAGE_BUFFER, gpu.buffer_info(&camera.opaque_draw_count[frame_index])},
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
    {.STORAGE_BUFFER, gpu.buffer_info(&camera.sprite_draw_count[frame_index])},
    {
      .STORAGE_BUFFER,
      gpu.buffer_info(&camera.sprite_draw_commands[frame_index]),
    },
    {
      .COMBINED_IMAGE_SAMPLER,
      vk.DescriptorImageInfo {
        sampler = camera.depth_pyramid[prev_frame].sampler,
        imageView = camera.depth_pyramid[prev_frame].full_view,
        imageLayout = .GENERAL,
      },
    },
  )
  // Update depth reduce descriptor sets with new views/samplers
  for mip in 0 ..< camera.depth_pyramid[frame_index].mip_levels {
    prev_depth_texture := cont.get(
      rm.images_2d,
      camera.attachments[.DEPTH][prev_frame],
    )
    source_view :=
      mip == 0 ? prev_depth_texture.view : camera.depth_pyramid[frame_index].views[mip - 1]
    source_layout :=
      mip == 0 ? vk.ImageLayout.DEPTH_STENCIL_READ_ONLY_OPTIMAL : vk.ImageLayout.GENERAL
    gpu.update_descriptor_set(
      gctx,
      camera.depth_reduce_descriptor_sets[frame_index][mip],
      {
        type = .COMBINED_IMAGE_SAMPLER,
        info = vk.DescriptorImageInfo {
          sampler = camera.depth_pyramid[frame_index].sampler,
          imageView = source_view,
          imageLayout = source_layout,
        },
      },
      {
        type = .STORAGE_IMAGE,
        info = vk.DescriptorImageInfo {
          imageView = camera.depth_pyramid[frame_index].views[mip],
          imageLayout = .GENERAL,
        },
      },
    )
  }
}

camera_upload_data :: proc(
  self: ^Manager,
  camera_index: u32,
  frame_index: u32,
) {
  camera := &self.cameras.entries[camera_index].item
  camera.data[frame_index].view = camera_view_matrix(camera)
  camera.data[frame_index].projection = camera_projection_matrix(camera)
  near, far := camera_get_near_far(camera)
  camera.data[frame_index].viewport_params = [4]f32 {
    f32(camera.extent.width),
    f32(camera.extent.height),
    near,
    far,
  }
  camera.data[frame_index].position = [4]f32 {
    camera.position[0],
    camera.position[1],
    camera.position[2],
    1.0,
  }
  frustum := geometry.make_frustum(
    camera.data[frame_index].projection * camera.data[frame_index].view,
  )
  camera.data[frame_index].frustum_planes = frustum.planes
  gpu.write(
    &self.camera_buffer.buffers[frame_index],
    &camera.data[frame_index],
    int(camera_index),
  )
}

// Configure a camera to use external draw lists from another camera
// This is useful when you know for sure that 2 cameras will produce identical draw list
// Disables culling and depth pyramid generation for the target camera
camera_use_external_draw_list :: proc(
  target_camera: ^Camera,
  source_camera: ^Camera,
) {
  target_camera.draw_list_source = source_camera
  target_camera.enable_culling = false
  target_camera.enable_depth_pyramid = false
}

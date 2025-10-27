package resources

import "../geometry"
import "../gpu"
import "core:log"
import "core:math"
import "core:math/linalg"
import vk "vendor:vulkan"

// Camera projection types
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

// GPU-side camera data for bindless buffer
CameraData :: struct {
  view:            matrix[4, 4]f32,
  projection:      matrix[4, 4]f32,
  viewport_params: [4]f32,
  position:        [4]f32,
  frustum_planes:  [6][4]f32,
}

// Attachment types for camera render targets
AttachmentType :: enum {
  FINAL_IMAGE        = 0,
  POSITION           = 1,
  NORMAL             = 2,
  ALBEDO             = 3,
  METALLIC_ROUGHNESS = 4,
  EMISSIVE           = 5,
  DEPTH              = 6,
}

// Pass types for enabled rendering passes
PassType :: enum {
  SHADOW       = 0,
  GEOMETRY     = 1,
  LIGHTING     = 2,
  TRANSPARENCY = 3,
  PARTICLES    = 4,
  NAVIGATION   = 5,
  POST_PROCESS = 6,
}

PassTypeSet :: bit_set[PassType;u32]

// Unified Camera struct combining geometry camera, render target, and visibility task
Camera :: struct {
  // Geometry camera data (embedded directly from geometry.Camera)
  position:                     [3]f32,
  rotation:                     quaternion128,
  projection:                   union {
    PerspectiveProjection,
    OrthographicProjection,
  },
  // GPU data for bindless buffer
  data:                         CameraData,
  // Render target data
  extent:                       vk.Extent2D,
  attachments:                  [AttachmentType][MAX_FRAMES_IN_FLIGHT]Handle,
  enabled_passes:               PassTypeSet,
  // Per-pass secondary command buffers for this camera
  geometry_commands:            [MAX_FRAMES_IN_FLIGHT]vk.CommandBuffer,
  lighting_commands:            [MAX_FRAMES_IN_FLIGHT]vk.CommandBuffer,
  transparency_commands:        [MAX_FRAMES_IN_FLIGHT]vk.CommandBuffer,
  // Double-buffered draw lists for lock-free async compute:
  //   - Frame N graphics reads from late_draw_commands[N]
  //   - Frame N compute writes to late_draw_commands[(N+1)%2]
  // This ensures graphics and compute never access the same buffer
  late_draw_count:              [MAX_FRAMES_IN_FLIGHT]gpu.MutableBuffer(u32),
  late_draw_commands:           [MAX_FRAMES_IN_FLIGHT]gpu.MutableBuffer(
    vk.DrawIndexedIndirectCommand,
  ),
  depth_pyramid:                [MAX_FRAMES_IN_FLIGHT]DepthPyramid,
  late_descriptor_set:          [MAX_FRAMES_IN_FLIGHT]vk.DescriptorSet,
  depth_reduce_descriptor_sets: [MAX_FRAMES_IN_FLIGHT][16]vk.DescriptorSet,
}

// Depth pyramid for hierarchical Z-buffer occlusion culling
DepthPyramid :: struct {
  texture:    Handle,
  views:      [16]vk.ImageView,
  full_view:  vk.ImageView,
  sampler:    vk.Sampler,
  mip_levels: u32,
  width:      u32,
  height:     u32,
}

camera_init :: proc(
  camera: ^Camera,
  gctx: ^gpu.GPUContext,
  manager: ^Manager,
  width, height: u32,
  color_format: vk.Format,
  depth_format: vk.Format,
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
  // Initialize geometry camera fields
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
  rotation_matrix := linalg.Matrix3f32 {
    right.x,
    recalc_up.x,
    -forward.x,
    right.y,
    recalc_up.y,
    -forward.y,
    right.z,
    recalc_up.z,
    -forward.z,
  }
  camera.rotation = linalg.quaternion_from_matrix3(rotation_matrix)
  camera.extent = {width, height}
  camera.enabled_passes = enabled_passes
  needs_gbuffer := .GEOMETRY in enabled_passes || .LIGHTING in enabled_passes
  needs_final :=
    .LIGHTING in enabled_passes ||
    .TRANSPARENCY in enabled_passes ||
    .PARTICLES in enabled_passes ||
    .POST_PROCESS in enabled_passes
  for frame in 0 ..< MAX_FRAMES_IN_FLIGHT {
    if needs_final {
      camera.attachments[.FINAL_IMAGE][frame], _, _ = create_texture(
        gctx,
        manager,
        width,
        height,
        color_format,
        vk.ImageUsageFlags{.COLOR_ATTACHMENT, .SAMPLED},
      )
    }
    if needs_gbuffer {
      camera.attachments[.POSITION][frame], _, _ = create_texture(
        gctx,
        manager,
        width,
        height,
        vk.Format.R32G32B32A32_SFLOAT,
        vk.ImageUsageFlags{.COLOR_ATTACHMENT, .SAMPLED},
      )
      camera.attachments[.NORMAL][frame], _, _ = create_texture(
        gctx,
        manager,
        width,
        height,
        vk.Format.R8G8B8A8_UNORM,
        vk.ImageUsageFlags{.COLOR_ATTACHMENT, .SAMPLED},
      )
      camera.attachments[.ALBEDO][frame], _, _ = create_texture(
        gctx,
        manager,
        width,
        height,
        vk.Format.R8G8B8A8_UNORM,
        vk.ImageUsageFlags{.COLOR_ATTACHMENT, .SAMPLED},
      )
      camera.attachments[.METALLIC_ROUGHNESS][frame], _, _ = create_texture(
        gctx,
        manager,
        width,
        height,
        vk.Format.R8G8B8A8_UNORM,
        vk.ImageUsageFlags{.COLOR_ATTACHMENT, .SAMPLED},
      )
      camera.attachments[.EMISSIVE][frame], _, _ = create_texture(
        gctx,
        manager,
        width,
        height,
        vk.Format.R8G8B8A8_UNORM,
        vk.ImageUsageFlags{.COLOR_ATTACHMENT, .SAMPLED},
      )
    }
    camera.attachments[.DEPTH][frame], _, _ = create_texture(
      gctx,
      manager,
      width,
      height,
      depth_format,
      vk.ImageUsageFlags{.DEPTH_STENCIL_ATTACHMENT, .SAMPLED},
    )
  }
  // Allocate per-pass command buffers for this camera
  alloc_info := vk.CommandBufferAllocateInfo {
    sType              = .COMMAND_BUFFER_ALLOCATE_INFO,
    commandPool        = gctx.command_pool,
    level              = .SECONDARY,
    commandBufferCount = MAX_FRAMES_IN_FLIGHT,
  }
  if .GEOMETRY in enabled_passes {
    vk.AllocateCommandBuffers(
      gctx.device,
      &alloc_info,
      raw_data(camera.geometry_commands[:]),
    ) or_return
  }
  if .LIGHTING in enabled_passes {
    vk.AllocateCommandBuffers(
      gctx.device,
      &alloc_info,
      raw_data(camera.lighting_commands[:]),
    ) or_return
  }
  if .TRANSPARENCY in enabled_passes {
    vk.AllocateCommandBuffers(
      gctx.device,
      &alloc_info,
      raw_data(camera.transparency_commands[:]),
    ) or_return
  }
  for frame in 0 ..< MAX_FRAMES_IN_FLIGHT {
    camera.late_draw_count[frame] = gpu.create_mutable_buffer(
      gctx,
      u32,
      1,
      {.STORAGE_BUFFER, .TRANSFER_DST},
    ) or_return
    camera.late_draw_commands[frame] = gpu.create_mutable_buffer(
      gctx,
      vk.DrawIndexedIndirectCommand,
      int(max_draws),
      {.STORAGE_BUFFER, .INDIRECT_BUFFER, .TRANSFER_DST},
    ) or_return
  }
  for frame in 0 ..< MAX_FRAMES_IN_FLIGHT {
    create_camera_depth_pyramid(
      gctx,
      manager,
      camera,
      width,
      height,
      u32(frame),
    ) or_return
  }
  for frame in 0 ..< MAX_FRAMES_IN_FLIGHT {
    camera_allocate_visibility_descriptors(
      gctx,
      manager,
      camera,
      u32(frame),
      &manager.visibility_late_descriptor_layout,
      &manager.visibility_depth_reduce_descriptor_layout,
    ) or_return
  }
  return .SUCCESS
}

camera_destroy :: proc(
  camera: ^Camera,
  device: vk.Device,
  command_pool: vk.CommandPool,
  manager: ^Manager,
) {
  for attachment_type in AttachmentType {
    for frame in 0 ..< MAX_FRAMES_IN_FLIGHT {
      handle := camera.attachments[attachment_type][frame]
      if item, freed := free(&manager.image_2d_buffers, handle); freed {
        gpu.image_destroy(device, item)
      }
    }
  }
  vk.FreeCommandBuffers(
    device,
    command_pool,
    MAX_FRAMES_IN_FLIGHT,
    raw_data(camera.geometry_commands[:]),
  )
  camera.geometry_commands = {}
  vk.FreeCommandBuffers(
    device,
    command_pool,
    MAX_FRAMES_IN_FLIGHT,
    raw_data(camera.lighting_commands[:]),
  )
  camera.lighting_commands = {}
  vk.FreeCommandBuffers(
    device,
    command_pool,
    MAX_FRAMES_IN_FLIGHT,
    raw_data(camera.transparency_commands[:]),
  )
  camera.transparency_commands = {}
  for frame in 0 ..< MAX_FRAMES_IN_FLIGHT {
    // Clean up depth pyramid views and samplers
    for mip in 0 ..< camera.depth_pyramid[frame].mip_levels {
      vk.DestroyImageView(device, camera.depth_pyramid[frame].views[mip], nil)
    }
    vk.DestroyImageView(device, camera.depth_pyramid[frame].full_view, nil)
    vk.DestroySampler(device, camera.depth_pyramid[frame].sampler, nil)
    // Clean up draw buffers
    gpu.mutable_buffer_destroy(device, &camera.late_draw_count[frame])
    gpu.mutable_buffer_destroy(device, &camera.late_draw_commands[frame])
    // Free depth pyramid texture
    if pyramid_item, freed := free(
      &manager.image_2d_buffers,
      camera.depth_pyramid[frame].texture,
    ); freed {
      gpu.image_destroy(device, pyramid_item)
    }
  }
}

// Update camera data in the bindless buffer
camera_upload_data :: proc(
  manager: ^Manager,
  camera: ^Camera,
  camera_index: u32,
) {
  camera.data.view = camera_calculate_view_matrix(camera)
  camera.data.projection = camera_calculate_projection_matrix(camera)
  near, far := camera_get_near_far(camera)
  camera.data.viewport_params = [4]f32 {
    f32(camera.extent.width),
    f32(camera.extent.height),
    near,
    far,
  }
  camera.data.position = [4]f32 {
    camera.position[0],
    camera.position[1],
    camera.position[2],
    1.0,
  }
  frustum := make_frustum(camera.data.projection * camera.data.view)
  camera.data.frustum_planes = frustum.planes
  gpu.write(&manager.camera_buffer, &camera.data, int(camera_index))
}

// Helper functions that work directly with Camera
camera_calculate_view_matrix :: proc(camera: ^Camera) -> matrix[4, 4]f32 {
  forward_vec := camera_forward(camera)
  up_vec := camera_up(camera)
  target_point := camera.position + forward_vec
  return linalg.matrix4_look_at(camera.position, target_point, up_vec)
}

camera_calculate_projection_matrix :: proc(
  camera: ^Camera,
) -> matrix[4, 4]f32 {
  switch proj in camera.projection {
  case PerspectiveProjection:
    return linalg.matrix4_perspective(
      proj.fov,
      proj.aspect_ratio,
      proj.near,
      proj.far,
    )
  case OrthographicProjection:
    return linalg.matrix_ortho3d(
      -proj.width / 2,
      proj.width / 2,
      -proj.height / 2,
      proj.height / 2,
      proj.near,
      proj.far,
    )
  case:
    return linalg.MATRIX4F32_IDENTITY
  }
}

camera_forward :: proc(camera: ^Camera) -> [3]f32 {
  return linalg.quaternion_mul_vector3(
    camera.rotation,
    -linalg.VECTOR3F32_Z_AXIS,
  )
}

camera_right :: proc(camera: ^Camera) -> [3]f32 {
  return linalg.quaternion_mul_vector3(
    camera.rotation,
    linalg.VECTOR3F32_X_AXIS,
  )
}

camera_up :: proc(camera: ^Camera) -> [3]f32 {
  return linalg.quaternion_mul_vector3(
    camera.rotation,
    linalg.VECTOR3F32_Y_AXIS,
  )
}

camera_get_near_far :: proc(camera: ^Camera) -> (near: f32, far: f32) {
  switch proj in camera.projection {
  case PerspectiveProjection:
    return proj.near, proj.far
  case OrthographicProjection:
    return proj.near, proj.far
  case:
    return 0.1, 50.0
  }
}

camera_look_at :: proc(
  camera: ^Camera,
  from, to: [3]f32,
  world_up := linalg.VECTOR3F32_Y_AXIS,
) {
  camera.position = from
  forward := linalg.normalize(to - from)
  safe_up := world_up
  if math.abs(linalg.dot(forward, world_up)) > 0.999 {
    safe_up = linalg.VECTOR3F32_Z_AXIS
    if math.abs(linalg.dot(forward, safe_up)) > 0.999 {
      safe_up = linalg.VECTOR3F32_X_AXIS
    }
  }
  right := linalg.normalize(linalg.cross(forward, safe_up))
  recalc_up := linalg.cross(right, forward)
  rotation_matrix := linalg.Matrix3f32 {
    right.x,
    recalc_up.x,
    -forward.x,
    right.y,
    recalc_up.y,
    -forward.y,
    right.z,
    recalc_up.z,
    -forward.z,
  }
  camera.rotation = linalg.quaternion_from_matrix3(rotation_matrix)
}

camera_update_aspect_ratio :: proc(camera: ^Camera, new_aspect_ratio: f32) {
  switch &proj in camera.projection {
  case PerspectiveProjection:
    proj.aspect_ratio = new_aspect_ratio
  case OrthographicProjection:
  // For orthographic projection, might want to adjust width/height
  }
}

// Create a frustum from a view-projection matrix
make_frustum :: proc(
  view_projection_matrix: matrix[4, 4]f32,
) -> geometry.Frustum {
  m := linalg.transpose(view_projection_matrix)
  planes := [6]geometry.Plane {
    m[3] + m[0], // Left
    m[3] - m[0], // Right
    m[3] + m[1], // Bottom
    m[3] - m[1], // Top
    m[3] + m[2], // Near
    m[3] - m[2], // Far
  }
  for &plane in planes {
    mag := linalg.length(plane.xyz)
    if mag > 1e-6 {
      plane /= mag
    }
  }
  return geometry.Frustum{planes}
}

camera_make_frustum :: proc(camera: ^Camera) -> geometry.Frustum {
  view_matrix := camera_calculate_view_matrix(camera)
  proj_matrix := camera_calculate_projection_matrix(camera)
  return make_frustum(proj_matrix * view_matrix)
}

// Get attachment handle for a specific type and frame
camera_get_attachment :: proc(
  camera: ^Camera,
  attachment_type: AttachmentType,
  frame_index: u32,
) -> Handle {
  return camera.attachments[attachment_type][frame_index]
}

// Resize camera and its attachments
camera_resize :: proc(
  camera: ^Camera,
  gctx: ^gpu.GPUContext,
  manager: ^Manager,
  width, height: u32,
  color_format: vk.Format,
  depth_format: vk.Format,
) -> vk.Result {
  if camera.extent.width == width && camera.extent.height == height do return .SUCCESS
  vk.DeviceWaitIdle(gctx.device) or_return
  // Clear descriptor set references (will be reallocated after resource recreation)
  for frame in 0 ..< MAX_FRAMES_IN_FLIGHT {
    camera.late_descriptor_set[frame] = 0
    for mip in 0 ..< camera.depth_pyramid[frame].mip_levels {
      camera.depth_reduce_descriptor_sets[frame][mip] = 0
    }
  }
  // Destroy depth pyramids (views, samplers, textures)
  for frame in 0 ..< MAX_FRAMES_IN_FLIGHT {
    for mip in 0 ..< camera.depth_pyramid[frame].mip_levels {
      vk.DestroyImageView(
        gctx.device,
        camera.depth_pyramid[frame].views[mip],
        nil,
      )
    }
    vk.DestroyImageView(
      gctx.device,
      camera.depth_pyramid[frame].full_view,
      nil,
    )
    vk.DestroySampler(gctx.device, camera.depth_pyramid[frame].sampler, nil)
    if pyramid_item, freed := free(
      &manager.image_2d_buffers,
      camera.depth_pyramid[frame].texture,
    ); freed {
      gpu.image_destroy(gctx.device, pyramid_item)
    }
    camera.depth_pyramid[frame] = {}
  }
  // Destroy attachment textures
  for frame in 0 ..< MAX_FRAMES_IN_FLIGHT {
    for attachment_type in AttachmentType {
      handle := camera.attachments[attachment_type][frame]
      if handle.index == 0 && handle.generation == 0 do continue
      if item, freed := free(&manager.image_2d_buffers, handle); freed {
        gpu.image_destroy(gctx.device, item)
      }
      camera.attachments[attachment_type][frame] = {}
    }
  }
  // Update dimensions and aspect ratio
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
  for frame in 0 ..< MAX_FRAMES_IN_FLIGHT {
    if needs_final {
      camera.attachments[.FINAL_IMAGE][frame], _, _ = create_texture(
        gctx,
        manager,
        width,
        height,
        color_format,
        vk.ImageUsageFlags{.COLOR_ATTACHMENT, .SAMPLED},
      )
    }
    if needs_gbuffer {
      camera.attachments[.POSITION][frame], _, _ = create_texture(
        gctx,
        manager,
        width,
        height,
        vk.Format.R32G32B32A32_SFLOAT,
        vk.ImageUsageFlags{.COLOR_ATTACHMENT, .SAMPLED},
      )
      camera.attachments[.NORMAL][frame], _, _ = create_texture(
        gctx,
        manager,
        width,
        height,
        vk.Format.R8G8B8A8_UNORM,
        vk.ImageUsageFlags{.COLOR_ATTACHMENT, .SAMPLED},
      )
      camera.attachments[.ALBEDO][frame], _, _ = create_texture(
        gctx,
        manager,
        width,
        height,
        vk.Format.R8G8B8A8_UNORM,
        vk.ImageUsageFlags{.COLOR_ATTACHMENT, .SAMPLED},
      )
      camera.attachments[.METALLIC_ROUGHNESS][frame], _, _ = create_texture(
        gctx,
        manager,
        width,
        height,
        vk.Format.R8G8B8A8_UNORM,
        vk.ImageUsageFlags{.COLOR_ATTACHMENT, .SAMPLED},
      )
      camera.attachments[.EMISSIVE][frame], _, _ = create_texture(
        gctx,
        manager,
        width,
        height,
        vk.Format.R8G8B8A8_UNORM,
        vk.ImageUsageFlags{.COLOR_ATTACHMENT, .SAMPLED},
      )
    }
    camera.attachments[.DEPTH][frame], _, _ = create_texture(
      gctx,
      manager,
      width,
      height,
      depth_format,
      vk.ImageUsageFlags{.DEPTH_STENCIL_ATTACHMENT, .SAMPLED},
    )
  }
  // Recreate depth pyramids for all frames before allocating descriptors
  // (late culling uses prev frame's pyramid, so all must exist first)
  for frame in 0 ..< MAX_FRAMES_IN_FLIGHT {
    create_camera_depth_pyramid(
      gctx,
      manager,
      camera,
      width,
      height,
      u32(frame),
    ) or_return
  }
  for frame in 0 ..< MAX_FRAMES_IN_FLIGHT {
    camera_allocate_visibility_descriptors(
      gctx,
      manager,
      camera,
      u32(frame),
      &manager.visibility_late_descriptor_layout,
      &manager.visibility_depth_reduce_descriptor_layout,
    ) or_return
  }
  log.infof("Camera resized to %dx%d", width, height)
  return .SUCCESS
}

// Get visible object count from late pass for a specific frame
camera_get_visible_count :: proc(camera: ^Camera, frame_index: u32) -> u32 {
  if camera.late_draw_count[frame_index].mapped == nil do return 0
  return camera.late_draw_count[frame_index].mapped[0]
}

// Convert viewport coordinates to a world-space ray
// mouse_x, mouse_y: Mouse coordinates (origin at top-left, Y increases downward)
// Returns: ray origin and normalized ray direction in world space
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
  view_matrix := camera_calculate_view_matrix(camera)
  proj_matrix := camera_calculate_projection_matrix(camera)
  inv_proj := linalg.matrix4_inverse(proj_matrix)
  inv_view := linalg.matrix4_inverse(view_matrix)
  // Ray in clip space
  ray_clip := [4]f32{ndc_x, ndc_y, -1.0, 1.0}
  // Ray in view space
  ray_eye := inv_proj * ray_clip
  ray_eye = [4]f32{ray_eye.x, ray_eye.y, -1.0, 0.0}
  // Ray in world space
  ray_world_4 := inv_view * ray_eye
  ray_dir = linalg.normalize(
    [3]f32{ray_world_4.x, ray_world_4.y, ray_world_4.z},
  )
  ray_origin = camera.position
  return ray_origin, ray_dir
}

// Camera-based raycast - finds closest hit from viewport coordinates
// mouse_x, mouse_y: Mouse coordinates (origin at top-left, Y increases downward)
// Returns the closest primitive hit by the ray from the camera through the viewport position
camera_raycast :: proc(
  camera: ^Camera,
  mouse_x, mouse_y: f32,
  primitives: []$T,
  intersection_func: proc(
    ray: geometry.Ray,
    primitive: T,
    max_t: f32,
  ) -> (
    hit: bool,
    t: f32,
  ),
  bounds_func: proc(t: T) -> geometry.Aabb,
  config: geometry.RaycastConfig = geometry.DEFAULT_RAYCAST_CONFIG,
) -> geometry.RayHit(T) {
  ray_origin, ray_dir := camera_viewport_to_world_ray(camera, mouse_x, mouse_y)
  ray := geometry.Ray {
    origin    = ray_origin,
    direction = ray_dir,
  }
  return geometry.raycast(
    primitives,
    ray,
    intersection_func,
    bounds_func,
    config,
  )
}

// Camera-based raycast - finds any hit from viewport coordinates (early exit)
// mouse_x, mouse_y: Mouse coordinates (origin at top-left, Y increases downward)
// Returns as soon as any hit is found
camera_raycast_single :: proc(
  camera: ^Camera,
  mouse_x, mouse_y: f32,
  primitives: []$T,
  intersection_func: proc(
    ray: geometry.Ray,
    primitive: T,
    max_t: f32,
  ) -> (
    hit: bool,
    t: f32,
  ),
  bounds_func: proc(t: T) -> geometry.Aabb,
  config: geometry.RaycastConfig = geometry.DEFAULT_RAYCAST_CONFIG,
) -> geometry.RayHit(T) {
  ray_origin, ray_dir := camera_viewport_to_world_ray(camera, mouse_x, mouse_y)
  ray := geometry.Ray {
    origin    = ray_origin,
    direction = ray_dir,
  }
  return geometry.raycast_single(
    primitives,
    ray,
    intersection_func,
    bounds_func,
    config,
  )
}

// Camera-based raycast - finds all hits from viewport coordinates
// mouse_x, mouse_y: Mouse coordinates (origin at top-left, Y increases downward)
// Returns all primitives hit by the ray, sorted by distance
camera_raycast_multi :: proc(
  camera: ^Camera,
  mouse_x, mouse_y: f32,
  primitives: []$T,
  intersection_func: proc(
    ray: geometry.Ray,
    primitive: T,
    max_t: f32,
  ) -> (
    hit: bool,
    t: f32,
  ),
  bounds_func: proc(t: T) -> geometry.Aabb,
  config: geometry.RaycastConfig = geometry.DEFAULT_RAYCAST_CONFIG,
  results: ^[dynamic]geometry.RayHit(T),
) {
  ray_origin, ray_dir := camera_viewport_to_world_ray(camera, mouse_x, mouse_y)
  ray := geometry.Ray {
    origin    = ray_origin,
    direction = ray_dir,
  }
  geometry.raycast_multi(
    primitives,
    ray,
    intersection_func,
    bounds_func,
    config,
    results,
  )
}

// Create depth pyramid for a specific frame
@(private)
create_camera_depth_pyramid :: proc(
  gctx: ^gpu.GPUContext,
  manager: ^Manager,
  camera: ^Camera,
  width: u32,
  height: u32,
  frame_index: u32,
) -> vk.Result {
  // Get depth texture from attachments (already created in camera_init)
  depth_handle := camera.attachments[.DEPTH][frame_index]
  depth_texture := get(manager.image_2d_buffers, depth_handle)
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
  pyramid_handle, pyramid_texture, pyramid_ok := alloc(
    &manager.image_2d_buffers,
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
  // Register the auto-created view in bindless texture array
  set_texture_2d_descriptor(
    gctx,
    manager,
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
        baseArrayLayer = 0,
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
      aspectMask     = {.COLOR},
      baseMipLevel   = 0,
      levelCount     = mip_levels, // ALL mip levels accessible
      baseArrayLayer = 0,
      layerCount     = 1,
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

// Allocate and update camera descriptor sets for visibility culling
// This should be called AFTER create_camera_depth_pyramid and requires the visibility system's descriptor layouts
camera_allocate_visibility_descriptors :: proc(
  gctx: ^gpu.GPUContext,
  manager: ^Manager,
  camera: ^Camera,
  frame_index: u32,
  late_descriptor_layout: ^vk.DescriptorSetLayout,
  depth_reduce_descriptor_layout: ^vk.DescriptorSetLayout,
) -> vk.Result {
  // Allocate late pass descriptor set for this frame
  vk.AllocateDescriptorSets(
    gctx.device,
    &vk.DescriptorSetAllocateInfo {
      sType = .DESCRIPTOR_SET_ALLOCATE_INFO,
      descriptorPool = gctx.descriptor_pool,
      descriptorSetCount = 1,
      pSetLayouts = late_descriptor_layout,
    },
    &camera.late_descriptor_set[frame_index],
  ) or_return
  // Allocate descriptor sets for depth pyramid reduction (one per mip level)
  for mip in 0 ..< camera.depth_pyramid[frame_index].mip_levels {
    vk.AllocateDescriptorSets(
      gctx.device,
      &vk.DescriptorSetAllocateInfo {
        sType = .DESCRIPTOR_SET_ALLOCATE_INFO,
        descriptorPool = gctx.descriptor_pool,
        descriptorSetCount = 1,
        pSetLayouts = depth_reduce_descriptor_layout,
      },
      &camera.depth_reduce_descriptor_sets[frame_index][mip],
    ) or_return
  }
  // Update late pass descriptor set for this frame
  camera_update_late_descriptor_set(gctx, manager, camera, frame_index)
  // Update depth reduction descriptor sets for this frame
  for mip in 0 ..< camera.depth_pyramid[frame_index].mip_levels {
    camera_update_depth_reduce_descriptor_set(
      gctx,
      manager,
      camera,
      frame_index,
      u32(mip),
    )
  }
  return .SUCCESS
}

// Update late pass descriptor set for a specific frame
@(private)
camera_update_late_descriptor_set :: proc(
  gctx: ^gpu.GPUContext,
  manager: ^Manager,
  camera: ^Camera,
  frame_index: u32,
) {
  // For late culling pass, we bind the PREVIOUS frame's pyramid
  // Frame 0 uses frame MAX_FRAMES_IN_FLIGHT-1, frame 1 uses frame 0, etc.
  prev_frame := (frame_index + MAX_FRAMES_IN_FLIGHT - 1) % MAX_FRAMES_IN_FLIGHT
  node_info := vk.DescriptorBufferInfo {
    buffer = manager.node_data_buffer.buffer,
    range  = vk.DeviceSize(manager.node_data_buffer.bytes_count),
  }
  mesh_info := vk.DescriptorBufferInfo {
    buffer = manager.mesh_data_buffer.buffer,
    range  = vk.DeviceSize(manager.mesh_data_buffer.bytes_count),
  }
  world_info := vk.DescriptorBufferInfo {
    buffer = manager.world_matrix_buffer.buffer,
    range  = vk.DeviceSize(manager.world_matrix_buffer.bytes_count),
  }
  camera_info := vk.DescriptorBufferInfo {
    buffer = manager.camera_buffer.buffer,
    range  = vk.DeviceSize(manager.camera_buffer.bytes_count),
  }
  count_info := vk.DescriptorBufferInfo {
    buffer = camera.late_draw_count[frame_index].buffer,
    range  = vk.DeviceSize(camera.late_draw_count[frame_index].bytes_count),
  }
  command_info := vk.DescriptorBufferInfo {
    buffer = camera.late_draw_commands[frame_index].buffer,
    range  = vk.DeviceSize(camera.late_draw_commands[frame_index].bytes_count),
  }
  // Bind previous frame's depth pyramid for occlusion culling
  pyramid_info := vk.DescriptorImageInfo {
    sampler     = camera.depth_pyramid[prev_frame].sampler,
    imageView   = camera.depth_pyramid[prev_frame].full_view,
    imageLayout = .SHADER_READ_ONLY_OPTIMAL,
  }
  writes := [?]vk.WriteDescriptorSet {
    {
      sType = .WRITE_DESCRIPTOR_SET,
      dstSet = camera.late_descriptor_set[frame_index],
      dstBinding = 0,
      descriptorType = .STORAGE_BUFFER,
      descriptorCount = 1,
      pBufferInfo = &node_info,
    },
    {
      sType = .WRITE_DESCRIPTOR_SET,
      dstSet = camera.late_descriptor_set[frame_index],
      dstBinding = 1,
      descriptorType = .STORAGE_BUFFER,
      descriptorCount = 1,
      pBufferInfo = &mesh_info,
    },
    {
      sType = .WRITE_DESCRIPTOR_SET,
      dstSet = camera.late_descriptor_set[frame_index],
      dstBinding = 2,
      descriptorType = .STORAGE_BUFFER,
      descriptorCount = 1,
      pBufferInfo = &world_info,
    },
    {
      sType = .WRITE_DESCRIPTOR_SET,
      dstSet = camera.late_descriptor_set[frame_index],
      dstBinding = 3,
      descriptorType = .STORAGE_BUFFER,
      descriptorCount = 1,
      pBufferInfo = &camera_info,
    },
    {
      sType = .WRITE_DESCRIPTOR_SET,
      dstSet = camera.late_descriptor_set[frame_index],
      dstBinding = 4,
      descriptorType = .STORAGE_BUFFER,
      descriptorCount = 1,
      pBufferInfo = &count_info,
    },
    {
      sType = .WRITE_DESCRIPTOR_SET,
      dstSet = camera.late_descriptor_set[frame_index],
      dstBinding = 5,
      descriptorType = .STORAGE_BUFFER,
      descriptorCount = 1,
      pBufferInfo = &command_info,
    },
    {
      sType = .WRITE_DESCRIPTOR_SET,
      dstSet = camera.late_descriptor_set[frame_index],
      dstBinding = 6,
      descriptorType = .COMBINED_IMAGE_SAMPLER,
      descriptorCount = 1,
      pImageInfo = &pyramid_info,
    },
  }
  vk.UpdateDescriptorSets(
    gctx.device,
    len(writes),
    raw_data(writes[:]),
    0,
    nil,
  )
}

// Update depth reduction descriptor set for a specific frame and mip level
@(private)
camera_update_depth_reduce_descriptor_set :: proc(
  gctx: ^gpu.GPUContext,
  manager: ^Manager,
  camera: ^Camera,
  frame_index: u32,
  mip: u32,
) {
  curr_depth_texture := get(
    manager.image_2d_buffers,
    camera.attachments[.DEPTH][frame_index],
  )
  // Mip 0 reads from depth texture, other mips read from previous mip level
  source_view :=
    mip == 0 ? curr_depth_texture.view : camera.depth_pyramid[frame_index].views[mip - 1]
  // Use DEPTH_STENCIL_READ_ONLY_OPTIMAL for depth texture (mip 0), SHADER_READ_ONLY_OPTIMAL for pyramid mips
  source_layout :=
    mip == 0 ? vk.ImageLayout.DEPTH_STENCIL_READ_ONLY_OPTIMAL : vk.ImageLayout.SHADER_READ_ONLY_OPTIMAL
  source_info := vk.DescriptorImageInfo {
    sampler     = camera.depth_pyramid[frame_index].sampler,
    imageView   = source_view,
    imageLayout = source_layout,
  }
  dest_info := vk.DescriptorImageInfo {
    imageView   = camera.depth_pyramid[frame_index].views[mip],
    imageLayout = .GENERAL,
  }
  writes := [?]vk.WriteDescriptorSet {
    {
      sType = .WRITE_DESCRIPTOR_SET,
      dstSet = camera.depth_reduce_descriptor_sets[frame_index][mip],
      dstBinding = 0,
      descriptorType = .COMBINED_IMAGE_SAMPLER,
      descriptorCount = 1,
      pImageInfo = &source_info,
    },
    {
      sType = .WRITE_DESCRIPTOR_SET,
      dstSet = camera.depth_reduce_descriptor_sets[frame_index][mip],
      dstBinding = 1,
      descriptorType = .STORAGE_IMAGE,
      descriptorCount = 1,
      pImageInfo = &dest_info,
    },
  }
  vk.UpdateDescriptorSets(
    gctx.device,
    len(writes),
    raw_data(writes[:]),
    0,
    nil,
  )
}

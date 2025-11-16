package resources

import cont "../containers"
import "../gpu"
import "core:log"
import "core:math"
import "core:math/linalg"
import vk "vendor:vulkan"

// SphericalCamera captures a full sphere (omnidirectional view) into a cube map
SphericalCamera :: struct {
  center:          [3]f32, // Center position of the sphere
  radius:          f32, // Capture radius
  near:            f32, // Near plane
  far:             f32, // Far plane
  size:            u32, // Resolution of cube map faces (size x size)
  depth_cube:      [FRAMES_IN_FLIGHT]Handle, // Cube depth textures (per-frame)
  draw_commands:   gpu.MutableBuffer(vk.DrawIndexedIndirectCommand), // Draw commands for visible objects
  draw_count:      gpu.MutableBuffer(u32), // Number of visible objects
  max_draws:       u32, // Maximum number of draw calls
  descriptor_sets: [FRAMES_IN_FLIGHT]vk.DescriptorSet, // Per-frame descriptor sets for sphere culling
}

// Initialize a new spherical camera
spherical_camera_init :: proc(
  camera: ^SphericalCamera,
  gctx: ^gpu.GPUContext,
  manager: ^Manager,
  size: u32 = SHADOW_MAP_SIZE,
  center: [3]f32 = {0, 0, 0},
  radius: f32 = 10.0,
  near: f32 = 0.1,
  far: f32 = 100.0,
  depth_format: vk.Format = .D32_SFLOAT,
  max_draws: u32 = MAX_NODES_IN_SCENE,
) -> vk.Result {
  camera.center = center
  camera.radius = radius
  camera.near = near
  camera.far = far
  camera.size = size
  camera.max_draws = max_draws
  for &v in camera.depth_cube {
    v, _, _ = create_empty_texture_cube(
      gctx,
      manager,
      size,
      depth_format,
      {.DEPTH_STENCIL_ATTACHMENT, .SAMPLED},
    )
  }
  camera.draw_count = gpu.create_mutable_buffer(
    gctx,
    u32,
    1,
    {.STORAGE_BUFFER, .INDIRECT_BUFFER, .TRANSFER_DST},
  ) or_return
  camera.draw_commands = gpu.create_mutable_buffer(
    gctx,
    vk.DrawIndexedIndirectCommand,
    int(max_draws),
    {.STORAGE_BUFFER, .INDIRECT_BUFFER, .TRANSFER_DST},
  ) or_return
  return .SUCCESS
}

spherical_camera_allocate_descriptors :: proc(
  camera: ^SphericalCamera,
  gctx: ^gpu.GPUContext,
  manager: ^Manager,
  sphere_cam_descriptor_layout: ^vk.DescriptorSetLayout,
) -> vk.Result {
  // Create and update all per-frame descriptor sets
  for frame_index in 0 ..< FRAMES_IN_FLIGHT {
    camera.descriptor_sets[frame_index] = gpu.create_descriptor_set(
      gctx,
      sphere_cam_descriptor_layout,
      {.STORAGE_BUFFER, gpu.buffer_info(&manager.node_data_buffer.buffer)},
      {.STORAGE_BUFFER, gpu.buffer_info(&manager.mesh_data_buffer.buffer)},
      {.STORAGE_BUFFER, gpu.buffer_info(&manager.world_matrix_buffer.buffer)},
      {
        .STORAGE_BUFFER,
        gpu.buffer_info(
          &manager.spherical_camera_buffer.buffers[frame_index],
        ),
      },
      {.STORAGE_BUFFER, gpu.buffer_info(&camera.draw_count)},
      {.STORAGE_BUFFER, gpu.buffer_info(&camera.draw_commands)},
    ) or_return
  }
  return .SUCCESS
}

spherical_camera_destroy :: proc(
  self: ^SphericalCamera,
  gctx: ^gpu.GPUContext,
  manager: ^Manager,
) {
  for v in self.depth_cube {
    if item, freed := cont.free(&manager.images_cube, v); freed {
      gpu.cube_depth_texture_destroy(gctx.device, item)
    }
  }
  gpu.mutable_buffer_destroy(gctx.device, &self.draw_count)
  gpu.mutable_buffer_destroy(gctx.device, &self.draw_commands)
}

// Upload camera data to GPU buffer
spherical_camera_upload_data :: proc(
  manager: ^Manager,
  camera: ^SphericalCamera,
  camera_index: u32,
  frame_index: u32 = 0,
) {
  dst := gpu.get(&manager.spherical_camera_buffer.buffers[frame_index], camera_index)
  if dst == nil {
    log.errorf("Spherical camera index %d out of bounds", camera_index)
    return
  }
  // Perspective projection with 90-degree FOV for cube map faces
  fov := f32(math.PI * 0.5) // 90 degrees
  aspect := f32(1.0) // Square faces
  dst.projection = linalg.matrix4_perspective(
    fov,
    aspect,
    camera.near,
    camera.far,
  )
  dst.position = [4]f32 {
    camera.center[0],
    camera.center[1],
    camera.center[2],
    camera.radius, // Store radius in w component
  }
  dst.near_far = [2]f32{camera.near, camera.far}
}

spherical_camera_visible_count :: proc(camera: ^SphericalCamera) -> u32 {
  if camera.draw_count.mapped == nil do return 0
  return camera.draw_count.mapped[0]
}

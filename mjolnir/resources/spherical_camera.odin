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
  depth_cube:      [FRAMES_IN_FLIGHT]ImageCubeHandle, // Cube depth textures (per-frame)
  // Per-frame GPU data (double-buffered for async compute)
  draw_commands:   [FRAMES_IN_FLIGHT]gpu.MutableBuffer(vk.DrawIndexedIndirectCommand),
  draw_count:      [FRAMES_IN_FLIGHT]gpu.MutableBuffer(u32),
  max_draws:       u32, // Maximum number of draw calls
  descriptor_sets: [FRAMES_IN_FLIGHT]vk.DescriptorSet, // Per-frame descriptor sets for sphere culling
}

// Initialize a new spherical camera
spherical_camera_init :: proc(
  self: ^SphericalCamera,
  gctx: ^gpu.GPUContext,
  rm: ^Manager,
  size: u32 = SHADOW_MAP_SIZE,
  center: [3]f32 = {0, 0, 0},
  radius: f32 = 10.0,
  near: f32 = 0.1,
  far: f32 = 100.0,
  depth_format: vk.Format = .D32_SFLOAT,
  max_draws: u32 = MAX_NODES_IN_SCENE,
) -> vk.Result {
  self.center = center
  self.radius = radius
  self.near = near
  self.far = far
  self.size = size
  self.max_draws = max_draws
  for &v in self.depth_cube {
    v, _ = create_empty_texture_cube(
      gctx,
      rm,
      size,
      depth_format,
      {.DEPTH_STENCIL_ATTACHMENT, .SAMPLED},
    )
  }
  for frame in 0 ..< FRAMES_IN_FLIGHT {
    self.draw_count[frame] = gpu.create_mutable_buffer(
      gctx,
      u32,
      1,
      {.STORAGE_BUFFER, .INDIRECT_BUFFER, .TRANSFER_DST},
    ) or_return
    self.draw_commands[frame] = gpu.create_mutable_buffer(
      gctx,
      vk.DrawIndexedIndirectCommand,
      int(max_draws),
      {.STORAGE_BUFFER, .INDIRECT_BUFFER, .TRANSFER_DST},
    ) or_return
  }
  return .SUCCESS
}

spherical_camera_allocate_descriptors :: proc(
  self: ^SphericalCamera,
  gctx: ^gpu.GPUContext,
  rm: ^Manager,
  sphere_cam_descriptor_layout: ^vk.DescriptorSetLayout,
) -> vk.Result {
  // Create and update all per-frame descriptor sets
  for frame_index in 0 ..< FRAMES_IN_FLIGHT {
    self.descriptor_sets[frame_index] = gpu.create_descriptor_set(
      gctx,
      sphere_cam_descriptor_layout,
      {.STORAGE_BUFFER, gpu.buffer_info(&rm.node_data_buffer.buffer)},
      {.STORAGE_BUFFER, gpu.buffer_info(&rm.mesh_data_buffer.buffer)},
      {.STORAGE_BUFFER, gpu.buffer_info(&rm.world_matrix_buffer.buffer)},
      {
        .STORAGE_BUFFER,
        gpu.buffer_info(
          &rm.spherical_camera_buffer.buffers[frame_index],
        ),
      },
      {.STORAGE_BUFFER, gpu.buffer_info(&self.draw_count[frame_index])},
      {.STORAGE_BUFFER, gpu.buffer_info(&self.draw_commands[frame_index])},
    ) or_return
  }
  return .SUCCESS
}

spherical_camera_destroy :: proc(
  self: ^SphericalCamera,
  gctx: ^gpu.GPUContext,
  rm: ^Manager,
) {
  for v in self.depth_cube {
    if item, freed := cont.free(&rm.images_cube, v); freed {
      gpu.cube_depth_texture_destroy(gctx.device, item)
    }
  }
  for frame in 0 ..< FRAMES_IN_FLIGHT {
    gpu.mutable_buffer_destroy(gctx.device, &self.draw_count[frame])
    gpu.mutable_buffer_destroy(gctx.device, &self.draw_commands[frame])
  }
}

// Upload camera data to GPU buffer
spherical_camera_upload_data :: proc(
  rm: ^Manager,
  camera: ^SphericalCamera,
  camera_index: u32,
  frame_index: u32 = 0,
) {
  dst := gpu.get(&rm.spherical_camera_buffer.buffers[frame_index], camera_index)
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
    flip_z_axis = false,  // Vulkan-style: Z in [0, 1]
  )
  dst.position = [4]f32 {
    camera.center[0],
    camera.center[1],
    camera.center[2],
    camera.radius, // Store radius in w component
  }
  dst.near_far = [2]f32{camera.near, camera.far}
}

spherical_camera_visible_count :: proc(
  camera: ^SphericalCamera,
  frame_index: u32,
) -> u32 {
  if camera.draw_count[frame_index].mapped == nil do return 0
  return camera.draw_count[frame_index].mapped[0]
}

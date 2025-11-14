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
  depth_cube:      [MAX_FRAMES_IN_FLIGHT]Handle, // Cube depth textures (per-frame)
  command_buffer:  vk.CommandBuffer, // Secondary command buffer
  draw_commands:   gpu.MutableBuffer(vk.DrawIndexedIndirectCommand), // Draw commands for visible objects
  draw_count:      gpu.MutableBuffer(u32), // Number of visible objects
  max_draws:       u32, // Maximum number of draw calls
  descriptor_sets: [MAX_FRAMES_IN_FLIGHT]vk.DescriptorSet, // Per-frame descriptor sets for sphere culling
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
  alloc_info := vk.CommandBufferAllocateInfo {
    sType              = .COMMAND_BUFFER_ALLOCATE_INFO,
    commandPool        = gctx.command_pool,
    level              = .SECONDARY,
    commandBufferCount = 1,
  }
  vk.AllocateCommandBuffers(
    gctx.device,
    &alloc_info,
    &camera.command_buffer,
  ) or_return
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
  set_layouts := [MAX_FRAMES_IN_FLIGHT]vk.DescriptorSetLayout {
    manager.visibility_sphere_descriptor_layout,
    manager.visibility_sphere_descriptor_layout,
  }
  vk.AllocateDescriptorSets(
    gctx.device,
    &vk.DescriptorSetAllocateInfo {
      sType = .DESCRIPTOR_SET_ALLOCATE_INFO,
      descriptorPool = gctx.descriptor_pool,
      descriptorSetCount = MAX_FRAMES_IN_FLIGHT,
      pSetLayouts = raw_data(set_layouts[:]),
    },
    raw_data(camera.descriptor_sets[:]),
  ) or_return
  // Update all per-frame descriptor sets
  for frame_idx in 0 ..< MAX_FRAMES_IN_FLIGHT {
    spherical_camera_update_descriptor_set(
      gctx,
      manager,
      camera,
      u32(frame_idx),
    )
  }
  return .SUCCESS
}

spherical_camera_destroy :: proc(
  camera: ^SphericalCamera,
  device: vk.Device,
  command_pool: vk.CommandPool,
  manager: ^Manager,
) {
  for v in camera.depth_cube {
    if item, freed := cont.free(&manager.image_cube_buffers, v); freed {
      gpu.cube_depth_texture_destroy(device, item)
    }
  }
  vk.FreeCommandBuffers(device, command_pool, 1, &camera.command_buffer)
  gpu.mutable_buffer_destroy(device, &camera.draw_count)
  gpu.mutable_buffer_destroy(device, &camera.draw_commands)
}

// Upload camera data to GPU buffer
spherical_camera_upload_data :: proc(
  manager: ^Manager,
  camera: ^SphericalCamera,
  camera_index: u32,
  frame_index: u32 = 0,
) {
  dst := gpu.mutable_buffer_get(
    &manager.spherical_camera_buffers[frame_index],
    camera_index,
  )
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

spherical_camera_get_visible_count :: proc(camera: ^SphericalCamera) -> u32 {
  if camera.draw_count.mapped == nil do return 0
  return camera.draw_count.mapped[0]
}

// Update sphere culling descriptor set with current buffer bindings (per-frame)
@(private)
spherical_camera_update_descriptor_set :: proc(
  gctx: ^gpu.GPUContext,
  manager: ^Manager,
  camera: ^SphericalCamera,
  frame_index: u32,
) {
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
  // Use per-frame spherical camera buffer to match rendering
  camera_info := vk.DescriptorBufferInfo {
    buffer = manager.spherical_camera_buffers[frame_index].buffer,
    range  = vk.DeviceSize(
      manager.spherical_camera_buffers[frame_index].bytes_count,
    ),
  }
  count_info := vk.DescriptorBufferInfo {
    buffer = camera.draw_count.buffer,
    range  = vk.DeviceSize(camera.draw_count.bytes_count),
  }
  command_info := vk.DescriptorBufferInfo {
    buffer = camera.draw_commands.buffer,
    range  = vk.DeviceSize(camera.draw_commands.bytes_count),
  }
  // NOTE: Bindings must match sphere_cull.comp shader!
  // Binding 4 is skipped (no depth pyramid in sphere culling)
  // Bindings 5,6 are for draw count/commands to match the shader layout
  writes := [?]vk.WriteDescriptorSet {
    {
      sType = .WRITE_DESCRIPTOR_SET,
      dstSet = camera.descriptor_sets[frame_index],
      dstBinding = 0,
      descriptorType = .STORAGE_BUFFER,
      descriptorCount = 1,
      pBufferInfo = &node_info,
    },
    {
      sType = .WRITE_DESCRIPTOR_SET,
      dstSet = camera.descriptor_sets[frame_index],
      dstBinding = 1,
      descriptorType = .STORAGE_BUFFER,
      descriptorCount = 1,
      pBufferInfo = &mesh_info,
    },
    {
      sType = .WRITE_DESCRIPTOR_SET,
      dstSet = camera.descriptor_sets[frame_index],
      dstBinding = 2,
      descriptorType = .STORAGE_BUFFER,
      descriptorCount = 1,
      pBufferInfo = &world_info,
    },
    {
      sType = .WRITE_DESCRIPTOR_SET,
      dstSet = camera.descriptor_sets[frame_index],
      dstBinding = 3,
      descriptorType = .STORAGE_BUFFER,
      descriptorCount = 1,
      pBufferInfo = &camera_info,
    },
    {
      sType = .WRITE_DESCRIPTOR_SET,
      dstSet = camera.descriptor_sets[frame_index],
      dstBinding = 5,
      descriptorType = .STORAGE_BUFFER,
      descriptorCount = 1,
      pBufferInfo = &count_info,
    },
    {
      sType = .WRITE_DESCRIPTOR_SET,
      dstSet = camera.descriptor_sets[frame_index],
      dstBinding = 6,
      descriptorType = .STORAGE_BUFFER,
      descriptorCount = 1,
      pBufferInfo = &command_info,
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

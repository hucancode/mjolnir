package mjolnir

import "core:log"
import "core:slice"
import "geometry"
import "gpu"
import "resource"
import vk "vendor:vulkan"

// Maximum number of cameras that can be culled simultaneously.
// Includes main camera + shadow cameras (point lights need 6 cameras each).
// Example: 1 main + 20 point lights = 1 + (20 * 6) = 121 cameras
// Keep some headroom for spot lights and user-defined cameras.
MAX_ACTIVE_CAMERAS :: 128

// Maximum number of scene nodes that can be processed for culling.
// Each node (mesh, light, particle system, etc.) gets tested against all active cameras.
// Memory usage: 128 cameras * 65536 nodes * 1 byte * 3 buffers = ~25MB for visibility results
// Additional: 65536 nodes * 32 bytes * 2 frames = ~4MB for node data
// Total GPU memory for culling: ~29MB
MAX_NODES_IN_SCENE :: 65536

// Structure passed to GPU for culling
NodeCullingData :: struct {
  aabb_min:        [3]f32,
  culling_enabled: b32,
  aabb_max:        [3]f32,
  padding:         f32,
}

// Multi-camera GPU culling parameters
MultiCameraCullingParams :: struct {
  node_count:          u32,
  active_camera_count: u32,
  current_frame:       u32, // 0 or 1 for double buffering
  padding:             u32,
}

// Active camera data for GPU
ActiveCameraData :: struct {
  frustum_planes: [6][4]f32,
  camera_index:   u32, // Index in the global camera array
  padding:        [3]u32,
}


VISIBILITY_BUFFER_COUNT :: 3 // Ring buffer for 1-2 frame latency

// Visibility culler
VisibilityCuller :: struct {
  // Shared node data buffer (per frame in flight)
  node_data_buffer:      [MAX_FRAMES_IN_FLIGHT]gpu.DataBuffer(NodeCullingData),
  // Multi-camera buffers
  params_buffer:         [MAX_FRAMES_IN_FLIGHT]gpu.DataBuffer(
    MultiCameraCullingParams,
  ),
  active_camera_buffer:  [MAX_FRAMES_IN_FLIGHT]gpu.DataBuffer(
    ActiveCameraData,
  ),
  visibility_buffer:     [VISIBILITY_BUFFER_COUNT]gpu.DataBuffer(b32),
  // Multi-camera pipeline
  descriptor_set_layout: vk.DescriptorSetLayout,
  pipeline_layout:       vk.PipelineLayout,
  pipeline:              vk.Pipeline,
  descriptor_sets:       [MAX_FRAMES_IN_FLIGHT]vk.DescriptorSet,
  // CPU tracking
  node_count:            u32,
  current_frame:         u32, // 0 or 1 for double buffering
  visibility_write_idx:  u32, // Ring buffer write index
  visibility_read_idx:   u32, // Ring buffer read index
  frames_processed:      u32, // Total frames processed
  last_descriptor_write_idx: [MAX_FRAMES_IN_FLIGHT]u32, // Track last write idx per frame
}

visibility_culler_init :: proc(
  self: ^VisibilityCuller,
  gpu_context: ^gpu.GPUContext,
) -> vk.Result {
  log.debugf("Initializing visibility culler")

  // Create buffers for each frame in flight
  for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
    self.node_data_buffer[i] = gpu.create_host_visible_buffer(
      gpu_context,
      NodeCullingData,
      MAX_NODES_IN_SCENE,
      {.STORAGE_BUFFER},
    ) or_return

    self.params_buffer[i] = gpu.create_host_visible_buffer(
      gpu_context,
      MultiCameraCullingParams,
      1,
      {.UNIFORM_BUFFER},
    ) or_return

    self.active_camera_buffer[i] = gpu.create_host_visible_buffer(
      gpu_context,
      ActiveCameraData,
      MAX_ACTIVE_CAMERAS,
      {.STORAGE_BUFFER},
    ) or_return

  }

  // Create visibility buffers (ring buffer for async reads)
  for i in 0 ..< VISIBILITY_BUFFER_COUNT {
    self.visibility_buffer[i] = gpu.create_host_visible_buffer(
      gpu_context,
      b32,
      MAX_ACTIVE_CAMERAS * MAX_NODES_IN_SCENE,
      {.STORAGE_BUFFER, .TRANSFER_DST},
    ) or_return
  }

  // Create multi-camera descriptor set layout
  culling_bindings := [?]vk.DescriptorSetLayoutBinding {
    {
      binding         = 0,
      descriptorType  = .UNIFORM_BUFFER, // Multi-camera params buffer
      descriptorCount = 1,
      stageFlags      = {.COMPUTE},
    },
    {
      binding         = 1,
      descriptorType  = .STORAGE_BUFFER, // Node data buffer (shared)
      descriptorCount = 1,
      stageFlags      = {.COMPUTE},
    },
    {
      binding         = 2,
      descriptorType  = .STORAGE_BUFFER, // Active camera buffer
      descriptorCount = 1,
      stageFlags      = {.COMPUTE},
    },
    {
      binding         = 3,
      descriptorType  = .STORAGE_BUFFER, // Multi-camera visibility buffer
      descriptorCount = 1,
      stageFlags      = {.COMPUTE},
    },
  }

  vk.CreateDescriptorSetLayout(
    gpu_context.device,
    &{
      sType = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
      bindingCount = len(culling_bindings),
      pBindings = raw_data(culling_bindings[:]),
    },
    nil,
    &self.descriptor_set_layout,
  ) or_return

  // Allocate multi-camera descriptor sets
  layouts := make([]vk.DescriptorSetLayout, MAX_FRAMES_IN_FLIGHT, context.temp_allocator)
  for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
    layouts[i] = self.descriptor_set_layout
  }

  vk.AllocateDescriptorSets(
    gpu_context.device,
    &{
      sType = .DESCRIPTOR_SET_ALLOCATE_INFO,
      descriptorPool = gpu_context.descriptor_pool,
      descriptorSetCount = MAX_FRAMES_IN_FLIGHT,
      pSetLayouts = raw_data(layouts[:]),
    },
    raw_data(self.descriptor_sets[:]),
  ) or_return

  vk.CreatePipelineLayout(
    gpu_context.device,
    &{
      sType = .PIPELINE_LAYOUT_CREATE_INFO,
      setLayoutCount = 1,
      pSetLayouts = &self.descriptor_set_layout,
    },
    nil,
    &self.pipeline_layout,
  ) or_return

  // Update multi-camera descriptor sets
  for frame_idx in 0 ..< MAX_FRAMES_IN_FLIGHT {
    params_buffer_info := vk.DescriptorBufferInfo {
      buffer = self.params_buffer[frame_idx].buffer,
      range  = vk.DeviceSize(self.params_buffer[frame_idx].bytes_count),
    }
    node_data_buffer_info := vk.DescriptorBufferInfo {
      buffer = self.node_data_buffer[frame_idx].buffer,
      range  = vk.DeviceSize(self.node_data_buffer[frame_idx].bytes_count),
    }
    active_camera_buffer_info := vk.DescriptorBufferInfo {
      buffer = self.active_camera_buffer[frame_idx].buffer,
      range  = vk.DeviceSize(self.active_camera_buffer[frame_idx].bytes_count),
    }
    visibility_buffer_info := vk.DescriptorBufferInfo {
      buffer = self.visibility_buffer[0].buffer,
      range  = vk.DeviceSize(self.visibility_buffer[0].bytes_count),
    }

    culling_writes := [?]vk.WriteDescriptorSet {
      {
        sType = .WRITE_DESCRIPTOR_SET,
        dstSet = self.descriptor_sets[frame_idx],
        dstBinding = 0,
        descriptorType = .UNIFORM_BUFFER,
        descriptorCount = 1,
        pBufferInfo = &params_buffer_info,
      },
      {
        sType = .WRITE_DESCRIPTOR_SET,
        dstSet = self.descriptor_sets[frame_idx],
        dstBinding = 1,
        descriptorType = .STORAGE_BUFFER,
        descriptorCount = 1,
        pBufferInfo = &node_data_buffer_info,
      },
      {
        sType = .WRITE_DESCRIPTOR_SET,
        dstSet = self.descriptor_sets[frame_idx],
        dstBinding = 2,
        descriptorType = .STORAGE_BUFFER,
        descriptorCount = 1,
        pBufferInfo = &active_camera_buffer_info,
      },
      {
        sType = .WRITE_DESCRIPTOR_SET,
        dstSet = self.descriptor_sets[frame_idx],
        dstBinding = 3,
        descriptorType = .STORAGE_BUFFER,
        descriptorCount = 1,
        pBufferInfo = &visibility_buffer_info,
      },
    }

    vk.UpdateDescriptorSets(
      gpu_context.device,
      len(culling_writes),
      raw_data(culling_writes[:]),
      0,
      nil,
    )
  }

  // Create multi-camera compute pipeline
  culling_shader_module := gpu.create_shader_module(
    gpu_context,
    #load("shader/visibility_culling/culling.spv"),
  ) or_return
  defer vk.DestroyShaderModule(gpu_context.device, culling_shader_module, nil)

  culling_pipeline_info := vk.ComputePipelineCreateInfo {
    sType = .COMPUTE_PIPELINE_CREATE_INFO,
    stage = {
      sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
      stage = {.COMPUTE},
      module = culling_shader_module,
      pName = "main",
    },
    layout = self.pipeline_layout,
  }

  vk.CreateComputePipelines(
    gpu_context.device,
    0,
    1,
    &culling_pipeline_info,
    nil,
    &self.pipeline,
  ) or_return

  self.current_frame = 0
  self.visibility_write_idx = 0
  self.visibility_read_idx = 0
  self.frames_processed = 0
  for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
    self.last_descriptor_write_idx[i] = ~u32(0) // Force initial update
  }
  return .SUCCESS
}

visibility_culler_deinit :: proc(
  self: ^VisibilityCuller,
  gpu_context: ^gpu.GPUContext,
) {
  vk.DestroyPipeline(gpu_context.device, self.pipeline, nil)
  vk.DestroyPipelineLayout(gpu_context.device, self.pipeline_layout, nil)
  vk.DestroyDescriptorSetLayout(
    gpu_context.device,
    self.descriptor_set_layout,
    nil,
  )
  for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
    gpu.data_buffer_deinit(gpu_context, &self.node_data_buffer[i])
    gpu.data_buffer_deinit(gpu_context, &self.params_buffer[i])
    gpu.data_buffer_deinit(gpu_context, &self.active_camera_buffer[i])
  }
  for i in 0 ..< VISIBILITY_BUFFER_COUNT {
    gpu.data_buffer_deinit(gpu_context, &self.visibility_buffer[i])
  }
}

// Update scene culling data from current scene state (once per frame)
visibility_culler_update :: proc(
  self: ^VisibilityCuller,
  scene: ^Scene,
  render_targets: []RenderTarget,
  warehouse: ^ResourceWarehouse,
  frame_index: u32,
) {
  // Update node data (same as single camera)
  node_data_slice := gpu.data_buffer_get_all(
    &self.node_data_buffer[frame_index],
  )
  self.node_count = u32(len(scene.nodes.entries))

  for &entry, entry_index in scene.nodes.entries {
    node_data_slice[entry_index].culling_enabled = false
    if !entry.active do continue
    if entry_index >= MAX_NODES_IN_SCENE do continue
    node := &entry.item
    if !node.culling_enabled do continue
    aabb := calculate_node_aabb(node, warehouse)
    if aabb == geometry.AABB_UNDEFINED do continue
    world_aabb := geometry.aabb_transform(aabb, geometry.transform_get_world_matrix(&node.transform))
    node_data_slice[entry_index] = {
      aabb_min        = world_aabb.min,
      aabb_max        = world_aabb.max,
      culling_enabled = true,
    }
  }

  // Update active camera data
  active_camera_slice := gpu.data_buffer_get_all(
    &self.active_camera_buffer[frame_index],
  )

  // Clear active camera data
  for i in 0 ..< MAX_ACTIVE_CAMERAS {
    active_camera_slice[i] = {}
  }

  // Populate active cameras from render targets (only current frame cameras)
  camera_count: u32 = 0
  for &target in render_targets {
    if camera_count >= MAX_ACTIVE_CAMERAS do break

    camera := resource.get(warehouse.cameras, target.camera)
    if camera == nil do continue

    // Calculate frustum for this camera
    view_matrix, proj_matrix := geometry.camera_calculate_matrices(camera^)
    frustum := geometry.make_frustum(proj_matrix * view_matrix)

    active_camera_slice[camera_count] = {
      frustum_planes = frustum.planes,
      camera_index   = target.camera.index,
    }
    camera_count += 1
  }

  // Update params buffer
  params := gpu.data_buffer_get(&self.params_buffer[frame_index])
  params.node_count = self.node_count
  params.active_camera_count = camera_count
  params.current_frame = self.current_frame

  // Toggle frame for next update (double buffering)
  self.current_frame = 1 - self.current_frame
}

// Execute GPU culling
visibility_culler_execute :: proc(
  self: ^VisibilityCuller,
  gpu_context: ^gpu.GPUContext,
  command_buffer: vk.CommandBuffer,
  frame_index: u32,
) {
  params := gpu.data_buffer_get(&self.params_buffer[frame_index])
  if self.node_count == 0 || params.active_camera_count == 0 {
    return
  }

  // Update descriptor set only when write buffer changes
  if self.last_descriptor_write_idx[frame_index] != self.visibility_write_idx {
    visibility_buffer_info := vk.DescriptorBufferInfo {
      buffer = self.visibility_buffer[self.visibility_write_idx].buffer,
      range  = vk.DeviceSize(
        self.visibility_buffer[self.visibility_write_idx].bytes_count,
      ),
    }

    write_descriptor := vk.WriteDescriptorSet {
      sType           = .WRITE_DESCRIPTOR_SET,
      dstSet          = self.descriptor_sets[frame_index],
      dstBinding      = 3,
      descriptorType  = .STORAGE_BUFFER,
      descriptorCount = 1,
      pBufferInfo     = &visibility_buffer_info,
    }

    vk.UpdateDescriptorSets(gpu_context.device, 1, &write_descriptor, 0, nil)
    self.last_descriptor_write_idx[frame_index] = self.visibility_write_idx
  }

  // Clear visibility buffer on GPU instead of CPU to avoid stalls
  vk.CmdFillBuffer(
    command_buffer,
    self.visibility_buffer[self.visibility_write_idx].buffer,
    0,
    vk.DeviceSize(self.visibility_buffer[self.visibility_write_idx].bytes_count),
    0,
  )

  // Barrier to ensure clear completes before compute shader
  buffer_barrier := vk.BufferMemoryBarrier {
    sType               = .BUFFER_MEMORY_BARRIER,
    srcAccessMask       = {.TRANSFER_WRITE},
    dstAccessMask       = {.SHADER_WRITE},
    srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
    dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
    buffer              = self.visibility_buffer[self.visibility_write_idx].buffer,
    offset              = 0,
    size                = vk.DeviceSize(self.visibility_buffer[self.visibility_write_idx].bytes_count),
  }
  vk.CmdPipelineBarrier(
    command_buffer,
    {.TRANSFER},
    {.COMPUTE_SHADER},
    {},
    0,
    nil,
    1,
    &buffer_barrier,
    0,
    nil,
  )

  // Dispatch culling compute shader
  vk.CmdBindPipeline(command_buffer, .COMPUTE, self.pipeline)
  vk.CmdBindDescriptorSets(
    command_buffer,
    .COMPUTE,
    self.pipeline_layout,
    0,
    1,
    &self.descriptor_sets[frame_index],
    0,
    nil,
  )

  // One thread per node (local_size_x = 64)
  dispatch_count := (self.node_count + 63) / 64
  vk.CmdDispatch(command_buffer, dispatch_count, 1, 1)
  // Advance write index for next frame
  self.visibility_write_idx =
    (self.visibility_write_idx + 1) % VISIBILITY_BUFFER_COUNT
  self.frames_processed += 1
  // Update read index to lag 1-2 frames behind write
  if self.frames_processed >= 2 {
    self.visibility_read_idx =
      (self.visibility_write_idx + VISIBILITY_BUFFER_COUNT - 2) %
      VISIBILITY_BUFFER_COUNT
  }
}

// Check if a node is visible for a specific camera slot
is_node_visible :: proc(
  self: ^VisibilityCuller,
  camera_slot: u32,
  node_index: u32,
  frame_index: u32,
) -> bool {
  // Use stale data if not enough frames processed yet
  if self.frames_processed < 2 {
    return true // Conservative: assume visible until we have data
  }

  params := gpu.data_buffer_get(&self.params_buffer[frame_index])
  if camera_slot >= params.active_camera_count ||
     node_index >= self.node_count {
    return false
  }

  visibility_slice := gpu.data_buffer_get_all(
    &self.visibility_buffer[self.visibility_read_idx],
  )
  visibility_index := camera_slot * self.node_count + node_index
  if visibility_index >= u32(len(visibility_slice)) {
    return false
  }

  return bool(visibility_slice[visibility_index])
}

// Count visible objects for a specific camera slot
count_visible_objects :: proc(
  self: ^VisibilityCuller,
  camera_slot: u32,
  frame_index: u32,
) -> (
  disabled: u32,
  visible: u32,
  total: u32,
) {
  total = self.node_count

  // Return conservative counts if not enough frames processed
  if self.frames_processed < 2 {
    return 0, total, total // All visible until we have data
  }

  params := gpu.data_buffer_get(&self.params_buffer[frame_index])
  if self.node_count == 0 || camera_slot >= params.active_camera_count {
    return 0, 0, 0
  }

  visibility_slice := gpu.data_buffer_get_all(
    &self.visibility_buffer[self.visibility_read_idx],
  )
  node_data_slice := gpu.data_buffer_get_all(
    &self.node_data_buffer[frame_index],
  )

  for i in 0 ..< self.node_count {
    visibility_index := camera_slot * self.node_count + i
    if visibility_index >= u32(len(visibility_slice)) do continue

    if !node_data_slice[i].culling_enabled {
      disabled += 1
    } else if visibility_slice[visibility_index] {
      visible += 1
    }
  }
  return
}

// Calculate AABB for a node based on its attachment type
calculate_node_aabb :: proc(
  node: ^Node,
  warehouse: ^ResourceWarehouse,
) -> geometry.Aabb {
  // Otherwise, calculate based on attachment type
  #partial switch data in node.attachment {
  case MeshAttachment:
    mesh := resource.get(warehouse.meshes, data.handle)
    if mesh != nil {
      return mesh.aabb
    }
  case ParticleSystemAttachment:
    return data.bounding_box
  case EmitterAttachment:
    return data.bounding_box
  case PointLightAttachment:
    // Light bounds based on radius
    radius := data.radius
    return {{-radius, -radius, -radius}, {radius, radius, radius}}
  case SpotLightAttachment:
    // Spot light bounds (simplified)
    radius := data.radius
    return {{-radius, -radius, -radius}, {radius, radius, radius}}
  }
  return geometry.AABB_UNDEFINED
}

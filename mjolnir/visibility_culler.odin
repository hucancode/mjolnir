package mjolnir

import "core:log"
import "core:slice"
import "geometry"
import "resource"
import vk "vendor:vulkan"

MAX_CAMERA :: 128
MAX_ACTIVE_CAMERAS :: 64
MAX_NODES_IN_SCENE :: 65536

// Structure passed to GPU for culling
NodeCullingData :: struct {
  aabb_min:        [3]f32,
  culling_enabled: b32,
  aabb_max:        [3]f32,
  padding:         f32,
}

// GPU culling parameters (legacy single camera)
SceneCullingParams :: struct {
  frustum_planes: [6][4]f32,
  node_count:     u32,
  padding:        [3]u32,
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

// Per-camera visibility data (legacy)
CameraVisibilityData :: struct {
  params_buffer:     DataBuffer(SceneCullingParams),
  visibility_buffer: DataBuffer(b32),
  descriptor_set:    vk.DescriptorSet,
  camera_active:     bool,
}

// Visibility culler
VisibilityCuller :: struct {
  // Shared node data buffer (per frame in flight)
  node_data_buffer:            [MAX_FRAMES_IN_FLIGHT]DataBuffer(
    NodeCullingData,
  ),
  // Per-camera visibility data (per frame in flight) - legacy
  camera_data:                 [MAX_FRAMES_IN_FLIGHT][MAX_CAMERA]CameraVisibilityData,
  // Multi-camera buffers
  multi_params_buffer:         [MAX_FRAMES_IN_FLIGHT]DataBuffer(
    MultiCameraCullingParams,
  ),
  active_camera_buffer:        [MAX_FRAMES_IN_FLIGHT]DataBuffer(
    ActiveCameraData,
  ),
  multi_visibility_buffer:     [MAX_FRAMES_IN_FLIGHT]DataBuffer(b32),
  // GPU pipelines
  descriptor_set_layout:       vk.DescriptorSetLayout,
  pipeline_layout:             vk.PipelineLayout,
  pipeline:                    vk.Pipeline,
  // Multi-camera pipeline
  multi_descriptor_set_layout: vk.DescriptorSetLayout,
  multi_pipeline_layout:       vk.PipelineLayout,
  multi_pipeline:              vk.Pipeline,
  multi_descriptor_sets:       [MAX_FRAMES_IN_FLIGHT]vk.DescriptorSet,
  // CPU tracking
  node_count:                  u32,
  current_frame:               u32, // 0 or 1 for double buffering
}

visibility_culler_init :: proc(self: ^VisibilityCuller) -> vk.Result {
  log.debugf("Initializing visibility culler")

  // Create buffers for each frame in flight
  for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
    self.node_data_buffer[i] = create_host_visible_buffer(
      NodeCullingData,
      MAX_NODES_IN_SCENE,
      {.STORAGE_BUFFER},
    ) or_return

    // Initialize camera data for this frame (legacy)
    for cam_idx in 0 ..< MAX_CAMERA {
      self.camera_data[i][cam_idx].params_buffer = create_host_visible_buffer(
        SceneCullingParams,
        1,
        {.UNIFORM_BUFFER},
      ) or_return

      self.camera_data[i][cam_idx].visibility_buffer =
        create_host_visible_buffer(
          b32,
          MAX_NODES_IN_SCENE,
          {.STORAGE_BUFFER, .TRANSFER_DST},
        ) or_return

      self.camera_data[i][cam_idx].camera_active = false
    }

    // Initialize multi-camera buffers
    self.multi_params_buffer[i] = create_host_visible_buffer(
      MultiCameraCullingParams,
      1,
      {.UNIFORM_BUFFER},
    ) or_return

    self.active_camera_buffer[i] = create_host_visible_buffer(
      ActiveCameraData,
      MAX_ACTIVE_CAMERAS,
      {.STORAGE_BUFFER},
    ) or_return

    // Visibility buffer size: MAX_ACTIVE_CAMERAS * MAX_NODES_IN_SCENE
    self.multi_visibility_buffer[i] = create_host_visible_buffer(
      b32,
      MAX_ACTIVE_CAMERAS * MAX_NODES_IN_SCENE,
      {.STORAGE_BUFFER, .TRANSFER_DST},
    ) or_return
  }

  // Create descriptor set layout
  culling_bindings := [?]vk.DescriptorSetLayoutBinding {
    {
      binding         = 0,
      descriptorType  = .UNIFORM_BUFFER, // Params buffer
      descriptorCount = 1,
      stageFlags      = {.COMPUTE},
    },
    {
      binding         = 1,
      descriptorType  = .STORAGE_BUFFER, // Node data buffer
      descriptorCount = 1,
      stageFlags      = {.COMPUTE},
    },
    {
      binding         = 2,
      descriptorType  = .STORAGE_BUFFER, // Visibility buffer
      descriptorCount = 1,
      stageFlags      = {.COMPUTE},
    },
  }

  vk.CreateDescriptorSetLayout(
    g_device,
    &{
      sType = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
      bindingCount = len(culling_bindings),
      pBindings = raw_data(culling_bindings[:]),
    },
    nil,
    &self.descriptor_set_layout,
  ) or_return

  // Allocate descriptor sets for all cameras in all frames
  total_sets := MAX_FRAMES_IN_FLIGHT * MAX_CAMERA
  layouts := make([]vk.DescriptorSetLayout, total_sets)
  defer delete(layouts)
  for i in 0 ..< total_sets {
    layouts[i] = self.descriptor_set_layout
  }

  // Allocate all descriptor sets at once
  all_descriptor_sets := make([]vk.DescriptorSet, total_sets)
  defer delete(all_descriptor_sets)

  vk.AllocateDescriptorSets(
    g_device,
    &{
      sType = .DESCRIPTOR_SET_ALLOCATE_INFO,
      descriptorPool = g_descriptor_pool,
      descriptorSetCount = u32(total_sets),
      pSetLayouts = raw_data(layouts[:]),
    },
    raw_data(all_descriptor_sets[:]),
  ) or_return

  // Assign descriptor sets to camera data
  for frame_idx in 0 ..< MAX_FRAMES_IN_FLIGHT {
    for cam_idx in 0 ..< MAX_CAMERA {
      set_index := frame_idx * MAX_CAMERA + cam_idx
      self.camera_data[frame_idx][cam_idx].descriptor_set =
        all_descriptor_sets[set_index]
    }
  }

  vk.CreatePipelineLayout(
    g_device,
    &{
      sType = .PIPELINE_LAYOUT_CREATE_INFO,
      setLayoutCount = 1,
      pSetLayouts = &self.descriptor_set_layout,
    },
    nil,
    &self.pipeline_layout,
  ) or_return

  // Update descriptor sets for each camera in each frame
  for frame_idx in 0 ..< MAX_FRAMES_IN_FLIGHT {
    for cam_idx in 0 ..< MAX_CAMERA {
      params_buffer_info := vk.DescriptorBufferInfo {
        buffer = self.camera_data[frame_idx][cam_idx].params_buffer.buffer,
        range  = vk.DeviceSize(
          self.camera_data[frame_idx][cam_idx].params_buffer.bytes_count,
        ),
      }
      node_data_buffer_info := vk.DescriptorBufferInfo {
        buffer = self.node_data_buffer[frame_idx].buffer,
        range  = vk.DeviceSize(self.node_data_buffer[frame_idx].bytes_count),
      }
      visibility_buffer_info := vk.DescriptorBufferInfo {
        buffer = self.camera_data[frame_idx][cam_idx].visibility_buffer.buffer,
        range  = vk.DeviceSize(
          self.camera_data[frame_idx][cam_idx].visibility_buffer.bytes_count,
        ),
      }

      culling_writes := [?]vk.WriteDescriptorSet {
        {
          sType = .WRITE_DESCRIPTOR_SET,
          dstSet = self.camera_data[frame_idx][cam_idx].descriptor_set,
          dstBinding = 0,
          descriptorType = .UNIFORM_BUFFER,
          descriptorCount = 1,
          pBufferInfo = &params_buffer_info,
        },
        {
          sType = .WRITE_DESCRIPTOR_SET,
          dstSet = self.camera_data[frame_idx][cam_idx].descriptor_set,
          dstBinding = 1,
          descriptorType = .STORAGE_BUFFER,
          descriptorCount = 1,
          pBufferInfo = &node_data_buffer_info,
        },
        {
          sType = .WRITE_DESCRIPTOR_SET,
          dstSet = self.camera_data[frame_idx][cam_idx].descriptor_set,
          dstBinding = 2,
          descriptorType = .STORAGE_BUFFER,
          descriptorCount = 1,
          pBufferInfo = &visibility_buffer_info,
        },
      }

      vk.UpdateDescriptorSets(
        g_device,
        len(culling_writes),
        raw_data(culling_writes[:]),
        0,
        nil,
      )
    }
  }

  // Create compute pipeline
  culling_shader_module := create_shader_module(
    #load("shader/scene_culling/culling.spv"),
  ) or_return
  defer vk.DestroyShaderModule(g_device, culling_shader_module, nil)

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
    g_device,
    0,
    1,
    &culling_pipeline_info,
    nil,
    &self.pipeline,
  ) or_return

  // Create multi-camera descriptor set layout
  multi_culling_bindings := [?]vk.DescriptorSetLayoutBinding {
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
    g_device,
    &{
      sType = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
      bindingCount = len(multi_culling_bindings),
      pBindings = raw_data(multi_culling_bindings[:]),
    },
    nil,
    &self.multi_descriptor_set_layout,
  ) or_return

  // Allocate multi-camera descriptor sets
  multi_layouts := make([]vk.DescriptorSetLayout, MAX_FRAMES_IN_FLIGHT)
  defer delete(multi_layouts)
  for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
    multi_layouts[i] = self.multi_descriptor_set_layout
  }

  vk.AllocateDescriptorSets(
    g_device,
    &{
      sType = .DESCRIPTOR_SET_ALLOCATE_INFO,
      descriptorPool = g_descriptor_pool,
      descriptorSetCount = MAX_FRAMES_IN_FLIGHT,
      pSetLayouts = raw_data(multi_layouts[:]),
    },
    raw_data(self.multi_descriptor_sets[:]),
  ) or_return

  vk.CreatePipelineLayout(
    g_device,
    &{
      sType = .PIPELINE_LAYOUT_CREATE_INFO,
      setLayoutCount = 1,
      pSetLayouts = &self.multi_descriptor_set_layout,
    },
    nil,
    &self.multi_pipeline_layout,
  ) or_return

  // Update multi-camera descriptor sets
  for frame_idx in 0 ..< MAX_FRAMES_IN_FLIGHT {
    multi_params_buffer_info := vk.DescriptorBufferInfo {
      buffer = self.multi_params_buffer[frame_idx].buffer,
      range  = vk.DeviceSize(self.multi_params_buffer[frame_idx].bytes_count),
    }
    node_data_buffer_info := vk.DescriptorBufferInfo {
      buffer = self.node_data_buffer[frame_idx].buffer,
      range  = vk.DeviceSize(self.node_data_buffer[frame_idx].bytes_count),
    }
    active_camera_buffer_info := vk.DescriptorBufferInfo {
      buffer = self.active_camera_buffer[frame_idx].buffer,
      range  = vk.DeviceSize(self.active_camera_buffer[frame_idx].bytes_count),
    }
    multi_visibility_buffer_info := vk.DescriptorBufferInfo {
      buffer = self.multi_visibility_buffer[frame_idx].buffer,
      range  = vk.DeviceSize(
        self.multi_visibility_buffer[frame_idx].bytes_count,
      ),
    }

    multi_culling_writes := [?]vk.WriteDescriptorSet {
      {
        sType = .WRITE_DESCRIPTOR_SET,
        dstSet = self.multi_descriptor_sets[frame_idx],
        dstBinding = 0,
        descriptorType = .UNIFORM_BUFFER,
        descriptorCount = 1,
        pBufferInfo = &multi_params_buffer_info,
      },
      {
        sType = .WRITE_DESCRIPTOR_SET,
        dstSet = self.multi_descriptor_sets[frame_idx],
        dstBinding = 1,
        descriptorType = .STORAGE_BUFFER,
        descriptorCount = 1,
        pBufferInfo = &node_data_buffer_info,
      },
      {
        sType = .WRITE_DESCRIPTOR_SET,
        dstSet = self.multi_descriptor_sets[frame_idx],
        dstBinding = 2,
        descriptorType = .STORAGE_BUFFER,
        descriptorCount = 1,
        pBufferInfo = &active_camera_buffer_info,
      },
      {
        sType = .WRITE_DESCRIPTOR_SET,
        dstSet = self.multi_descriptor_sets[frame_idx],
        dstBinding = 3,
        descriptorType = .STORAGE_BUFFER,
        descriptorCount = 1,
        pBufferInfo = &multi_visibility_buffer_info,
      },
    }

    vk.UpdateDescriptorSets(
      g_device,
      len(multi_culling_writes),
      raw_data(multi_culling_writes[:]),
      0,
      nil,
    )
  }

  // Create multi-camera compute pipeline
  multi_culling_shader_module := create_shader_module(
    #load("shader/multi_camera_culling/culling.spv"),
  ) or_return
  defer vk.DestroyShaderModule(g_device, multi_culling_shader_module, nil)

  multi_culling_pipeline_info := vk.ComputePipelineCreateInfo {
    sType = .COMPUTE_PIPELINE_CREATE_INFO,
    stage = {
      sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
      stage = {.COMPUTE},
      module = multi_culling_shader_module,
      pName = "main",
    },
    layout = self.multi_pipeline_layout,
  }

  vk.CreateComputePipelines(
    g_device,
    0,
    1,
    &multi_culling_pipeline_info,
    nil,
    &self.multi_pipeline,
  ) or_return

  self.current_frame = 0
  return .SUCCESS
}

visibility_culler_deinit :: proc(self: ^VisibilityCuller) {
  vk.DestroyPipeline(g_device, self.pipeline, nil)
  vk.DestroyPipelineLayout(g_device, self.pipeline_layout, nil)
  vk.DestroyDescriptorSetLayout(g_device, self.descriptor_set_layout, nil)
  vk.DestroyPipeline(g_device, self.multi_pipeline, nil)
  vk.DestroyPipelineLayout(g_device, self.multi_pipeline_layout, nil)
  vk.DestroyDescriptorSetLayout(
    g_device,
    self.multi_descriptor_set_layout,
    nil,
  )
  for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
    data_buffer_deinit(&self.node_data_buffer[i])
    data_buffer_deinit(&self.multi_params_buffer[i])
    data_buffer_deinit(&self.active_camera_buffer[i])
    data_buffer_deinit(&self.multi_visibility_buffer[i])
    for cam_idx in 0 ..< MAX_CAMERA {
      data_buffer_deinit(&self.camera_data[i][cam_idx].params_buffer)
      data_buffer_deinit(&self.camera_data[i][cam_idx].visibility_buffer)
    }
  }
}

// Update scene culling data from current scene state (once per frame)
visibility_culler_update :: proc(self: ^VisibilityCuller, scene: ^Scene) {
  node_data_slice := data_buffer_get_all(&self.node_data_buffer[g_frame_index])
  self.node_count = u32(len(scene.nodes.entries))
  // Clear all camera visibility buffers
  for cam_idx in 0 ..< MAX_CAMERA {
    if self.camera_data[g_frame_index][cam_idx].camera_active {
      visibility_slice := data_buffer_get_all(
        &self.camera_data[g_frame_index][cam_idx].visibility_buffer,
      )
      slice.fill(visibility_slice, false)
    }
  }
  // Update node data once per frame (world-space AABBs)
  for &entry, entry_index in scene.nodes.entries {
    node_data_slice[entry_index].culling_enabled = false
    if !entry.active do continue
    if entry_index >= MAX_NODES_IN_SCENE do continue
    node := &entry.item
    if !node.culling_enabled do continue
    aabb := calculate_node_aabb(node)
    if aabb == geometry.AABB_UNDEFINED do continue
    world_aabb := geometry.aabb_transform(aabb, node.transform.world_matrix)
    node_data_slice[entry_index] = {
      aabb_min        = world_aabb.min,
      aabb_max        = world_aabb.max,
      culling_enabled = true,
    }
  }
}

// Calculate AABB for a node based on its attachment type
calculate_node_aabb :: proc(node: ^Node) -> geometry.Aabb {
  // Otherwise, calculate based on attachment type
  #partial switch data in node.attachment {
  case MeshAttachment:
    mesh := resource.get(g_meshes, data.handle)
    if mesh != nil {
      return mesh.aabb
    }
  case ParticleSystemAttachment:
    return data.bounding_box
  case EmitterAttachment:
    // Default emitter bounds (can be customized)
    return {{-1.0, -1.0, -1.0}, {1.0, 1.0, 1.0}}
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

// Perform GPU culling for a specific camera
visibility_culler_execute :: proc(
  self: ^VisibilityCuller,
  command_buffer: vk.CommandBuffer,
  camera_index: u32,
  camera: geometry.Camera,
) {
  if self.node_count == 0 {
    return
  }

  if camera_index >= MAX_CAMERA {
    log.errorf("Invalid camera index: %d", camera_index)
    return
  }

  camera_data := &self.camera_data[g_frame_index][camera_index]
  camera_data.camera_active = true

  // Update frustum planes for this camera
  params_ptr := data_buffer_get(&camera_data.params_buffer)
  params_ptr.node_count = self.node_count
  frustum := geometry.camera_make_frustum(camera)
  for i in 0 ..< 6 {
    params_ptr.frustum_planes[i] = frustum.planes[i]
  }

  // Dispatch culling compute shader
  vk.CmdBindPipeline(command_buffer, .COMPUTE, self.pipeline)
  vk.CmdBindDescriptorSets(
    command_buffer,
    .COMPUTE,
    self.pipeline_layout,
    0,
    1,
    &camera_data.descriptor_set,
    0,
    nil,
  )
  // One thread per node (local_size_x = 64)
  dispatch_count := (self.node_count + 63) / 64
  vk.CmdDispatch(command_buffer, dispatch_count, 1, 1)
}

// Perform GPU culling with a pre-calculated frustum (to ensure consistency with CPU)
visibility_culler_execute_with_frustum :: proc(
  self: ^VisibilityCuller,
  command_buffer: vk.CommandBuffer,
  camera_index: u32,
  frustum: geometry.Frustum,
) {
  if self.node_count == 0 {
    return
  }
  if camera_index >= MAX_CAMERA {
    log.errorf("Invalid camera index: %d", camera_index)
    return
  }
  camera_data := &self.camera_data[g_frame_index][camera_index]
  camera_data.camera_active = true
  // Update frustum planes for this camera
  params_ptr := data_buffer_get(&camera_data.params_buffer)
  params_ptr.node_count = self.node_count
  for i in 0 ..< 6 {
    params_ptr.frustum_planes[i] = frustum.planes[i]
  }
  // Dispatch culling compute shader
  vk.CmdBindPipeline(command_buffer, .COMPUTE, self.pipeline)
  vk.CmdBindDescriptorSets(
    command_buffer,
    .COMPUTE,
    self.pipeline_layout,
    0,
    1,
    &camera_data.descriptor_set,
    0,
    nil,
  )

  // One thread per node (local_size_x = 64)
  dispatch_count := (self.node_count + 63) / 64
  vk.CmdDispatch(command_buffer, dispatch_count, 1, 1)
  // Add immediate memory barrier for light cameras and check results
  // TODO: recheck if this is optimal or not
  if camera_index > 0 {
    // Force GPU to complete compute shader immediately
    vk.CmdPipelineBarrier(
      command_buffer,
      {.COMPUTE_SHADER},
      {.HOST},
      {},
      0,
      nil,
      0,
      nil,
      0,
      nil,
    )
    // Submit command buffer immediately and check results
    vk.EndCommandBuffer(command_buffer)
    cmd_buffer := command_buffer
    submit_info := vk.SubmitInfo {
      sType              = .SUBMIT_INFO,
      commandBufferCount = 1,
      pCommandBuffers    = &cmd_buffer,
    }
    vk.QueueSubmit(g_graphics_queue, 1, &submit_info, vk.Fence(0))
    // TODO: recheck if this is optimal or not
    vk.QueueWaitIdle(g_graphics_queue)
    vk.ResetCommandBuffer(command_buffer, {})
    vk.BeginCommandBuffer(
      command_buffer,
      &{sType = .COMMAND_BUFFER_BEGIN_INFO, flags = {.ONE_TIME_SUBMIT}},
    )
  }
}

// Check if a node is visible after culling for a specific camera
is_node_visible :: proc(
  self: ^VisibilityCuller,
  camera_index: u32,
  node_index: u32,
) -> bool {
  if camera_index >= MAX_CAMERA {
    // log.debugf("Camera index %d >= MAX_CAMERA %d", camera_index, MAX_CAMERA)
    return false
  }
  if !self.camera_data[g_frame_index][camera_index].camera_active {
    return false
  }
  result := bool(
    data_buffer_get(
      &self.camera_data[g_frame_index][camera_index].visibility_buffer,
      node_index,
    )^,
  )
  return result
}

// Count visible objects after GPU culling for a specific camera
count_visible_objects :: proc(
  self: ^VisibilityCuller,
  camera_index: u32,
) -> (
  disabled: u32,
  visible: u32,
  total: u32,
) {
  total = self.node_count
  if self.node_count == 0 || camera_index >= MAX_CAMERA {
    return 0, 0, 0
  }
  if !self.camera_data[g_frame_index][camera_index].camera_active {
    return 0, 0, 0
  }
  visibility_slice := data_buffer_get_all(
    &self.camera_data[g_frame_index][camera_index].visibility_buffer,
  )
  // Get node data to check culling enabled status
  node_data_slice := data_buffer_get_all(&self.node_data_buffer[g_frame_index])
  for i in 0 ..< self.node_count {
    if !node_data_slice[i].culling_enabled {
      disabled += 1
    } else if visibility_slice[i] {
      visible += 1
    }
  }
  return
}

// Multi-camera GPU culling functions

// Update scene and active cameras for multi-camera culling
visibility_culler_update_multi_camera :: proc(
  self: ^VisibilityCuller,
  scene: ^Scene,
  render_targets: []RenderTarget,
) {
  // Update node data (same as single camera)
  node_data_slice := data_buffer_get_all(&self.node_data_buffer[g_frame_index])
  self.node_count = u32(len(scene.nodes.entries))

  for &entry, entry_index in scene.nodes.entries {
    node_data_slice[entry_index].culling_enabled = false
    if !entry.active do continue
    if entry_index >= MAX_NODES_IN_SCENE do continue
    node := &entry.item
    if !node.culling_enabled do continue
    aabb := calculate_node_aabb(node)
    if aabb == geometry.AABB_UNDEFINED do continue
    world_aabb := geometry.aabb_transform(aabb, node.transform.world_matrix)
    node_data_slice[entry_index] = {
      aabb_min        = world_aabb.min,
      aabb_max        = world_aabb.max,
      culling_enabled = true,
    }
  }

  // Update active camera data
  active_camera_slice := data_buffer_get_all(
    &self.active_camera_buffer[g_frame_index],
  )

  // Clear active camera data
  for i in 0 ..< MAX_ACTIVE_CAMERAS {
    active_camera_slice[i] = {}
  }

  // Populate active cameras from render targets (only current frame cameras)
  camera_count: u32 = 0
  for &target in render_targets {
    if camera_count >= MAX_ACTIVE_CAMERAS do break

    camera := resource.get(g_cameras, target.camera)
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
  params := data_buffer_get(&self.multi_params_buffer[g_frame_index])
  params.node_count = self.node_count
  params.active_camera_count = camera_count
  params.current_frame = self.current_frame

  // Toggle frame for next update (double buffering)
  self.current_frame = 1 - self.current_frame
}

// Execute multi-camera GPU culling
visibility_culler_execute_multi_camera :: proc(
  self: ^VisibilityCuller,
  command_buffer: vk.CommandBuffer,
) {
  params := data_buffer_get(&self.multi_params_buffer[g_frame_index])
  if self.node_count == 0 || params.active_camera_count == 0 {
    return
  }

  // Clear visibility buffer
  visibility_slice := data_buffer_get_all(
    &self.multi_visibility_buffer[g_frame_index],
  )
  slice.fill(visibility_slice, false)

  // Dispatch culling compute shader
  vk.CmdBindPipeline(command_buffer, .COMPUTE, self.multi_pipeline)
  vk.CmdBindDescriptorSets(
    command_buffer,
    .COMPUTE,
    self.multi_pipeline_layout,
    0,
    1,
    &self.multi_descriptor_sets[g_frame_index],
    0,
    nil,
  )

  // One thread per node (local_size_x = 64)
  dispatch_count := (self.node_count + 63) / 64
  vk.CmdDispatch(command_buffer, dispatch_count, 1, 1)
}

// Check if a node is visible for a specific camera in multi-camera mode
multi_camera_is_node_visible :: proc(
  self: ^VisibilityCuller,
  camera_slot: u32,
  node_index: u32,
) -> bool {
  params := data_buffer_get(&self.multi_params_buffer[g_frame_index])
  if camera_slot >= params.active_camera_count ||
     node_index >= self.node_count {
    return false
  }

  visibility_slice := data_buffer_get_all(
    &self.multi_visibility_buffer[g_frame_index],
  )
  visibility_index := camera_slot * self.node_count + node_index
  if visibility_index >= u32(len(visibility_slice)) {
    return false
  }

  return bool(visibility_slice[visibility_index])
}

// Count visible objects for a specific camera slot in multi-camera mode
multi_camera_count_visible_objects :: proc(
  self: ^VisibilityCuller,
  camera_slot: u32,
) -> (
  disabled: u32,
  visible: u32,
  total: u32,
) {
  total = self.node_count
  params := data_buffer_get(&self.multi_params_buffer[g_frame_index])
  if self.node_count == 0 || camera_slot >= params.active_camera_count {
    return 0, 0, 0
  }

  visibility_slice := data_buffer_get_all(
    &self.multi_visibility_buffer[g_frame_index],
  )
  node_data_slice := data_buffer_get_all(&self.node_data_buffer[g_frame_index])

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

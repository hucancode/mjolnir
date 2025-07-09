package mjolnir

import "core:log"
import linalg "core:math/linalg"
import "core:slice"
import "geometry"
import "resource"
import vk "vendor:vulkan"

MAX_SCENE_NODES :: 4096

// Structure passed to GPU for culling
NodeCullingData :: struct {
  aabb_min:        linalg.Vector3f32,
  culling_enabled: b32,
  aabb_max:        linalg.Vector3f32,
  padding:         f32,
}

// GPU culling parameters
SceneCullingParams :: struct {
  frustum_planes: [6]linalg.Vector4f32,
  node_count:     u32,
  padding:        [3]u32,
}

// Scene culling renderer
RendererSceneCulling :: struct {
  // GPU buffers (per frame in flight)
  params_buffer:         [MAX_FRAMES_IN_FLIGHT]DataBuffer(SceneCullingParams),
  node_data_buffer:      [MAX_FRAMES_IN_FLIGHT]DataBuffer(NodeCullingData),
  visibility_buffer:     [MAX_FRAMES_IN_FLIGHT]DataBuffer(b32),
  // GPU pipeline
  descriptor_set_layout: vk.DescriptorSetLayout,
  descriptor_set:        [MAX_FRAMES_IN_FLIGHT]vk.DescriptorSet,
  pipeline_layout:       vk.PipelineLayout,
  pipeline:              vk.Pipeline,
  // CPU tracking
  node_count:            u32,
}

renderer_scene_culling_init :: proc(self: ^RendererSceneCulling) -> vk.Result {
  log.debugf("Initializing scene culling renderer")

  // Create buffers for each frame in flight
  for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
    self.params_buffer[i] = create_host_visible_buffer(
      SceneCullingParams,
      1,
      {.UNIFORM_BUFFER},
    ) or_return

    self.node_data_buffer[i] = create_host_visible_buffer(
      NodeCullingData,
      MAX_SCENE_NODES,
      {.STORAGE_BUFFER},
    ) or_return

    self.visibility_buffer[i] = create_host_visible_buffer(
      b32,
      MAX_SCENE_NODES,
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

  layouts := [MAX_FRAMES_IN_FLIGHT]vk.DescriptorSetLayout {
    self.descriptor_set_layout,
    self.descriptor_set_layout,
  }
  vk.AllocateDescriptorSets(
    g_device,
    &{
      sType = .DESCRIPTOR_SET_ALLOCATE_INFO,
      descriptorPool = g_descriptor_pool,
      descriptorSetCount = MAX_FRAMES_IN_FLIGHT,
      pSetLayouts = raw_data(layouts[:]),
    },
    raw_data(self.descriptor_set[:]),
  ) or_return

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

  // Update descriptor sets for each frame
  for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
    params_buffer_info := vk.DescriptorBufferInfo {
      buffer = self.params_buffer[i].buffer,
      range  = vk.DeviceSize(self.params_buffer[i].bytes_count),
    }
    node_data_buffer_info := vk.DescriptorBufferInfo {
      buffer = self.node_data_buffer[i].buffer,
      range  = vk.DeviceSize(self.node_data_buffer[i].bytes_count),
    }
    visibility_buffer_info := vk.DescriptorBufferInfo {
      buffer = self.visibility_buffer[i].buffer,
      range  = vk.DeviceSize(self.visibility_buffer[i].bytes_count),
    }

    log.debugf(
      "Scene culling frame %d: visibility buffer=0x%x size=%d",
      i,
      self.visibility_buffer[i].buffer,
      self.visibility_buffer[i].bytes_count,
    )

    culling_writes := [?]vk.WriteDescriptorSet {
      {
        sType = .WRITE_DESCRIPTOR_SET,
        dstSet = self.descriptor_set[i],
        dstBinding = 0,
        descriptorType = .UNIFORM_BUFFER,
        descriptorCount = 1,
        pBufferInfo = &params_buffer_info,
      },
      {
        sType = .WRITE_DESCRIPTOR_SET,
        dstSet = self.descriptor_set[i],
        dstBinding = 1,
        descriptorType = .STORAGE_BUFFER,
        descriptorCount = 1,
        pBufferInfo = &node_data_buffer_info,
      },
      {
        sType = .WRITE_DESCRIPTOR_SET,
        dstSet = self.descriptor_set[i],
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

  return .SUCCESS
}

renderer_scene_culling_deinit :: proc(self: ^RendererSceneCulling) {
  vk.DestroyPipeline(g_device, self.pipeline, nil)
  vk.DestroyPipelineLayout(g_device, self.pipeline_layout, nil)
  vk.DestroyDescriptorSetLayout(g_device, self.descriptor_set_layout, nil)
  for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
    data_buffer_deinit(&self.params_buffer[i])
    data_buffer_deinit(&self.node_data_buffer[i])
    data_buffer_deinit(&self.visibility_buffer[i])
  }
}

// Update scene culling data from current scene state
update_scene_culling_data :: proc(self: ^RendererSceneCulling, scene: ^Scene) {
  params_ptr := data_buffer_get(&self.params_buffer[g_frame_index])
  node_data_slice := data_buffer_get_all(&self.node_data_buffer[g_frame_index])
  visibility_slice := data_buffer_get_all(&self.visibility_buffer[g_frame_index])
  slice.fill(visibility_slice, false)
  self.node_count = u32(len(scene.nodes.entries))
  params_ptr.node_count = self.node_count
  for &entry, entry_index in scene.nodes.entries {
    node_data_slice[entry_index].culling_enabled = false
    if !entry.active do continue
    if self.node_count >= MAX_SCENE_NODES do continue
    node := &entry.item
    if !node.culling_enabled do continue
    aabb := calculate_node_aabb(node)
    if aabb == geometry.AABB_UNDEFINED do continue
    world_aabb := geometry.aabb_transform(
      aabb,
      node.transform.world_matrix,
    )
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

// Perform GPU culling
perform_scene_culling :: proc(
  self: ^RendererSceneCulling,
  command_buffer: vk.CommandBuffer,
  camera: geometry.Camera,
) {
  if self.node_count == 0 {
    return
  }

  // Update frustum planes
  params_ptr := data_buffer_get(&self.params_buffer[g_frame_index])
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
    &self.descriptor_set[g_frame_index],
    0,
    nil,
  )
  // One thread per node (local_size_x = 64)
  dispatch_count := (self.node_count + 63) / 64
  vk.CmdDispatch(command_buffer, dispatch_count, 1, 1)
}

// Perform GPU culling with a pre-calculated frustum (to ensure consistency with CPU)
perform_scene_culling_with_frustum :: proc(
  self: ^RendererSceneCulling,
  command_buffer: vk.CommandBuffer,
  frustum: geometry.Frustum,
) {
  if self.node_count == 0 {
    return
  }

  // Update frustum planes
  params_ptr := data_buffer_get(&self.params_buffer[g_frame_index])
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
    &self.descriptor_set[g_frame_index],
    0,
    nil,
  )
  // One thread per node (local_size_x = 64)
  dispatch_count := (self.node_count + 63) / 64
  vk.CmdDispatch(command_buffer, dispatch_count, 1, 1)
}

// Check if a node is visible after culling
is_node_visible :: proc(self: ^RendererSceneCulling, index: u32) -> bool {
  return bool(data_buffer_get(&self.visibility_buffer[g_frame_index], index)^)
}

// Helper functions for node management


set_node_culling :: proc(node: ^Node, enabled: bool) {
  node.culling_enabled = enabled
}

// Count visible objects after GPU culling
count_visible_objects :: proc(
  self: ^RendererSceneCulling,
) -> (
  disabled: u32,
  visible: u32,
  total: u32,
) {
  total = self.node_count
  if self.node_count == 0 {
    return 0, 0, 0
  }
  visibility_slice := data_buffer_get_all(
    &self.visibility_buffer[g_frame_index],
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

  // Verify actual data being sent to GPU compute shader
  @(static) debug_frame_count: u32 = 0
  debug_frame_count += 1
  if debug_frame_count <= 5 && self.node_count > 0 {
    params_ptr := data_buffer_get(&self.params_buffer[g_frame_index])
    log.debugf("=== GPU CULLING DATA VERIFICATION ===")
    log.debugf(
      "Frame %d: Sending %d nodes to GPU",
      debug_frame_count,
      self.node_count,
    )
    // Verify frustum planes being sent to GPU
    log.debugf("Frustum planes sent to GPU:")
    for i in 0 ..< 6 {
      plane := params_ptr.frustum_planes[i]
      log.debugf("  Plane %d: %v", i, plane)
    }

    // Verify AABB data for first few nodes being sent to GPU
    log.debugf("AABB data sent to GPU (first 10 nodes):")
    for i in 0 ..< min(10, self.node_count) {
      node_data := &node_data_slice[i]
      log.debugf(
        "  Node %d: min=%v max=%v enabled=%v",
        i,
        node_data.aabb_min.xyz,
        node_data.aabb_max.xyz,
        node_data.culling_enabled,
      )
    }

    // Show GPU results after processing
    log.debugf("GPU visibility results (first 10 nodes):")
    for i in 0 ..< min(10, self.node_count) {
      log.debugf("  Node %d: visible=%d", i, visibility_slice[i])
    }

    log.debugf("=== END VERIFICATION ===")
  }
  return
}

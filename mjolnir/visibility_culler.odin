package mjolnir

import "core:log"
import "gpu"
import vk "vendor:vulkan"

MAX_ACTIVE_CAMERAS :: 128
MAX_NODES_IN_SCENE :: 65536

VisibilityPushConstants :: struct {
  camera_index: u32,
  node_count:   u32,
  max_draws:    u32,
  include_flags: u32,
  exclude_flags: u32,
}

VisibilityCuller :: struct {
  descriptor_set_layout: vk.DescriptorSetLayout,
  pipeline_layout:       vk.PipelineLayout,
  pipeline:              vk.Pipeline,
  descriptor_sets:       [MAX_FRAMES_IN_FLIGHT]vk.DescriptorSet,
  draw_count_buffer:     [MAX_FRAMES_IN_FLIGHT]gpu.DataBuffer(u32),
  draw_command_buffer:   [MAX_FRAMES_IN_FLIGHT]gpu.DataBuffer(
      vk.DrawIndexedIndirectCommand,
  ),
  max_draws:             u32,
  node_count:            u32,
}

visibility_culler_init :: proc(
  self: ^VisibilityCuller,
  gpu_context: ^gpu.GPUContext,
  warehouse: ^ResourceWarehouse,
) -> vk.Result {
  log.debugf("Initializing visibility culler")

  self.max_draws = MAX_NODES_IN_SCENE

  for frame_idx in 0 ..< MAX_FRAMES_IN_FLIGHT {
    self.draw_count_buffer[frame_idx] = gpu.create_host_visible_buffer(
      gpu_context,
      u32,
      1,
      {.STORAGE_BUFFER, .TRANSFER_DST},
    ) or_return

    self.draw_command_buffer[frame_idx] = gpu.create_host_visible_buffer(
      gpu_context,
      vk.DrawIndexedIndirectCommand,
      int(self.max_draws),
      {.STORAGE_BUFFER, .INDIRECT_BUFFER, .TRANSFER_DST},
    ) or_return
  }

  bindings := [?]vk.DescriptorSetLayoutBinding {
    {
      binding         = 0,
      descriptorType  = .STORAGE_BUFFER,
      descriptorCount = 1,
      stageFlags      = {.COMPUTE},
    },
    {
      binding         = 1,
      descriptorType  = .STORAGE_BUFFER,
      descriptorCount = 1,
      stageFlags      = {.COMPUTE},
    },
    {
      binding         = 2,
      descriptorType  = .STORAGE_BUFFER,
      descriptorCount = 1,
      stageFlags      = {.COMPUTE},
    },
    {
      binding         = 3,
      descriptorType  = .STORAGE_BUFFER,
      descriptorCount = 1,
      stageFlags      = {.COMPUTE},
    },
    {
      binding         = 4,
      descriptorType  = .STORAGE_BUFFER,
      descriptorCount = 1,
      stageFlags      = {.COMPUTE},
    },
    {
      binding         = 5,
      descriptorType  = .STORAGE_BUFFER,
      descriptorCount = 1,
      stageFlags      = {.COMPUTE},
    },
  }

  vk.CreateDescriptorSetLayout(
    gpu_context.device,
    &vk.DescriptorSetLayoutCreateInfo {
      sType = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
      bindingCount = len(bindings),
      pBindings = raw_data(bindings[:]),
    },
    nil,
    &self.descriptor_set_layout,
  ) or_return

  layouts := [MAX_FRAMES_IN_FLIGHT]vk.DescriptorSetLayout{}
  for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
    layouts[i] = self.descriptor_set_layout
  }

  vk.AllocateDescriptorSets(
    gpu_context.device,
    &vk.DescriptorSetAllocateInfo {
      sType              = .DESCRIPTOR_SET_ALLOCATE_INFO,
      descriptorPool     = gpu_context.descriptor_pool,
      descriptorSetCount = MAX_FRAMES_IN_FLIGHT,
      pSetLayouts        = &layouts[0],
    },
    &self.descriptor_sets[0],
  ) or_return

  push_constant_range := vk.PushConstantRange {
    stageFlags = {.COMPUTE},
    size       = size_of(VisibilityPushConstants),
  }

  vk.CreatePipelineLayout(
    gpu_context.device,
    &vk.PipelineLayoutCreateInfo {
      sType = .PIPELINE_LAYOUT_CREATE_INFO,
      setLayoutCount = 1,
      pSetLayouts = &self.descriptor_set_layout,
      pushConstantRangeCount = 1,
      pPushConstantRanges = &push_constant_range,
    },
    nil,
    &self.pipeline_layout,
  ) or_return

  shader_module := gpu.create_shader_module(
    gpu_context,
    #load("shader/visibility_culling/culling.spv"),
  ) or_return
  defer vk.DestroyShaderModule(gpu_context.device, shader_module, nil)

  compute_info := vk.ComputePipelineCreateInfo {
    sType = .COMPUTE_PIPELINE_CREATE_INFO,
    stage = {
      sType  = .PIPELINE_SHADER_STAGE_CREATE_INFO,
      stage  = {.COMPUTE},
      module = shader_module,
      pName  = "main",
    },
    layout = self.pipeline_layout,
  }

  vk.CreateComputePipelines(
    gpu_context.device,
    0,
    1,
    &compute_info,
    nil,
    &self.pipeline,
  ) or_return

  for frame_idx in 0 ..< MAX_FRAMES_IN_FLIGHT {
    node_info := vk.DescriptorBufferInfo {
      buffer = warehouse.node_data_buffer.buffer,
      range  = vk.DeviceSize(warehouse.node_data_buffer.bytes_count),
    }
    mesh_info := vk.DescriptorBufferInfo {
      buffer = warehouse.mesh_data_buffer.buffer,
      range  = vk.DeviceSize(warehouse.mesh_data_buffer.bytes_count),
    }
    world_info := vk.DescriptorBufferInfo {
      buffer = warehouse.world_matrix_buffers[frame_idx].buffer,
      range  = vk.DeviceSize(warehouse.world_matrix_buffers[frame_idx].bytes_count),
    }
    camera_info := vk.DescriptorBufferInfo {
      buffer = warehouse.camera_buffer.buffer,
      range  = vk.DeviceSize(warehouse.camera_buffer.bytes_count),
    }
    count_info := vk.DescriptorBufferInfo {
      buffer = self.draw_count_buffer[frame_idx].buffer,
      range  = vk.DeviceSize(self.draw_count_buffer[frame_idx].bytes_count),
    }
    command_info := vk.DescriptorBufferInfo {
      buffer = self.draw_command_buffer[frame_idx].buffer,
      range  = vk.DeviceSize(self.draw_command_buffer[frame_idx].bytes_count),
    }

    writes := [?]vk.WriteDescriptorSet {
      {
        sType           = .WRITE_DESCRIPTOR_SET,
        dstSet          = self.descriptor_sets[frame_idx],
        dstBinding      = 0,
        descriptorType  = .STORAGE_BUFFER,
        descriptorCount = 1,
        pBufferInfo     = &node_info,
      },
      {
        sType           = .WRITE_DESCRIPTOR_SET,
        dstSet          = self.descriptor_sets[frame_idx],
        dstBinding      = 1,
        descriptorType  = .STORAGE_BUFFER,
        descriptorCount = 1,
        pBufferInfo     = &mesh_info,
      },
      {
        sType           = .WRITE_DESCRIPTOR_SET,
        dstSet          = self.descriptor_sets[frame_idx],
        dstBinding      = 2,
        descriptorType  = .STORAGE_BUFFER,
        descriptorCount = 1,
        pBufferInfo     = &world_info,
      },
      {
        sType           = .WRITE_DESCRIPTOR_SET,
        dstSet          = self.descriptor_sets[frame_idx],
        dstBinding      = 3,
        descriptorType  = .STORAGE_BUFFER,
        descriptorCount = 1,
        pBufferInfo     = &camera_info,
      },
      {
        sType           = .WRITE_DESCRIPTOR_SET,
        dstSet          = self.descriptor_sets[frame_idx],
        dstBinding      = 4,
        descriptorType  = .STORAGE_BUFFER,
        descriptorCount = 1,
        pBufferInfo     = &count_info,
      },
      {
        sType           = .WRITE_DESCRIPTOR_SET,
        dstSet          = self.descriptor_sets[frame_idx],
        dstBinding      = 5,
        descriptorType  = .STORAGE_BUFFER,
        descriptorCount = 1,
        pBufferInfo     = &command_info,
      },
    }

    vk.UpdateDescriptorSets(
      gpu_context.device,
      len(writes),
      raw_data(writes[:]),
      0,
      nil,
    )
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
  for frame_idx in 0 ..< MAX_FRAMES_IN_FLIGHT {
    gpu.data_buffer_deinit(gpu_context, &self.draw_count_buffer[frame_idx])
    gpu.data_buffer_deinit(gpu_context, &self.draw_command_buffer[frame_idx])
  }
  self.pipeline = 0
  self.pipeline_layout = 0
  self.descriptor_set_layout = 0
}

visibility_culler_update :: proc(
  self: ^VisibilityCuller,
  scene: ^Scene,
) {
  self.node_count = u32(len(scene.nodes.entries))
  if self.node_count > self.max_draws {
    self.node_count = self.max_draws
  }
}

visibility_culler_dispatch :: proc(
  self: ^VisibilityCuller,
  gpu_context: ^gpu.GPUContext,
  command_buffer: vk.CommandBuffer,
  frame_index: u32,
  camera_index: u32,
  include_flags: u32,
  exclude_flags: u32,
) {
  if self.node_count == 0 {
    return
  }
  if frame_index >= MAX_FRAMES_IN_FLIGHT {
    return
  }

  count_buffer := self.draw_count_buffer[frame_index]
  draw_buffer := self.draw_command_buffer[frame_index]

  vk.CmdFillBuffer(
    command_buffer,
    count_buffer.buffer,
    0,
    vk.DeviceSize(count_buffer.bytes_count),
    0,
  )
  vk.CmdFillBuffer(
    command_buffer,
    draw_buffer.buffer,
    0,
    vk.DeviceSize(draw_buffer.bytes_count),
    0,
  )

  buffer_barriers := [?]vk.BufferMemoryBarrier {
    {
      sType         = .BUFFER_MEMORY_BARRIER,
      srcAccessMask = {.TRANSFER_WRITE},
      dstAccessMask = {.SHADER_WRITE},
      buffer        = count_buffer.buffer,
      offset        = 0,
      size          = vk.DeviceSize(count_buffer.bytes_count),
    },
    {
      sType         = .BUFFER_MEMORY_BARRIER,
      srcAccessMask = {.TRANSFER_WRITE},
      dstAccessMask = {.SHADER_WRITE},
      buffer        = draw_buffer.buffer,
      offset        = 0,
      size          = vk.DeviceSize(draw_buffer.bytes_count),
    },
  }

  vk.CmdPipelineBarrier(
    command_buffer,
    {.TRANSFER},
    {.COMPUTE_SHADER},
    {},
    0,
    nil,
    len(buffer_barriers),
    raw_data(buffer_barriers[:]),
    0,
    nil,
  )

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

  push_constants := VisibilityPushConstants {
    camera_index  = camera_index,
    node_count    = self.node_count,
    max_draws     = self.max_draws,
    include_flags = include_flags,
    exclude_flags = exclude_flags,
  }

  vk.CmdPushConstants(
    command_buffer,
    self.pipeline_layout,
    {.COMPUTE},
    0,
    size_of(VisibilityPushConstants),
    &push_constants,
  )

  dispatch_x := (self.node_count + 63) / 64
  vk.CmdDispatch(command_buffer, dispatch_x, 1, 1)

  post_barriers := [?]vk.BufferMemoryBarrier {
    {
      sType         = .BUFFER_MEMORY_BARRIER,
      srcAccessMask = {.SHADER_WRITE},
      dstAccessMask = {.INDIRECT_COMMAND_READ},
      buffer        = draw_buffer.buffer,
      offset        = 0,
      size          = vk.DeviceSize(draw_buffer.bytes_count),
    },
  }

  vk.CmdPipelineBarrier(
    command_buffer,
    {.COMPUTE_SHADER},
    {.DRAW_INDIRECT},
    {},
    0,
    nil,
    len(post_barriers),
    raw_data(post_barriers[:]),
    0,
    nil,
  )
}

visibility_culler_command_buffer :: proc(
  self: ^VisibilityCuller,
  frame_index: u32,
) -> vk.Buffer {
  return self.draw_command_buffer[frame_index].buffer
}

visibility_culler_command_stride :: proc() -> u32 {
  return u32(size_of(vk.DrawIndexedIndirectCommand))
}

visibility_culler_max_draw_count :: proc(
  self: ^VisibilityCuller,
) -> u32 {
  return self.node_count
}

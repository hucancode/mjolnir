package world

import "core:log"
import "core:fmt"
import gpu "../gpu"
import resources "../resources"
import vk "vendor:vulkan"

VisibilityCategory :: enum u32 {
  OPAQUE,
  SHADOW,
  TRANSPARENT,
  WIREFRAME,
  CUSTOM0,
  CUSTOM1,
}

VISIBILITY_TASK_COUNT :: len(VisibilityCategory)

visibility_category_name :: proc(task: VisibilityCategory) -> string {
  return fmt.tprintf("%v", task)
}

VisibilityTask :: struct {
  draw_count:    gpu.DataBuffer(u32),
  draw_commands: gpu.DataBuffer(vk.DrawIndexedIndirectCommand),
  descriptor_set: vk.DescriptorSet,
}

VisibilityFrame :: struct {
  tasks: [VISIBILITY_TASK_COUNT]VisibilityTask,
}

VisibilityRequest :: struct {
  camera_index: u32,
  include_flags: resources.NodeFlagSet,
  exclude_flags: resources.NodeFlagSet,
}

VisibilityPushConstants :: struct {
  camera_index:  u32,
  node_count:    u32,
  max_draws:     u32,
  include_flags: resources.NodeFlagSet,
  exclude_flags: resources.NodeFlagSet,
}

VisibilityResult :: struct {
  draw_buffer:    vk.Buffer,
  count_buffer:   vk.Buffer,
  max_draws:      u32,
  command_stride: u32,
}

VisibilitySystem :: struct {
  descriptor_set_layout: vk.DescriptorSetLayout,
  pipeline_layout:       vk.PipelineLayout,
  pipeline:              vk.Pipeline,
  frames:                [resources.MAX_FRAMES_IN_FLIGHT]VisibilityFrame,
  max_draws:             u32,
  node_count:            u32,
}

visibility_system_command_stride :: proc() -> u32 {
  return u32(size_of(vk.DrawIndexedIndirectCommand))
}

visibility_system_init :: proc(
  system: ^VisibilitySystem,
  gpu_context: ^gpu.GPUContext,
  resources_manager: ^resources.Manager,
) -> vk.Result {
  if gpu_context == nil || resources_manager == nil {
    return vk.Result.ERROR_INITIALIZATION_FAILED
  }

  system.max_draws = resources.MAX_NODES_IN_SCENE

  for frame_idx in 0 ..< resources.MAX_FRAMES_IN_FLIGHT {
    frame := &system.frames[frame_idx]
    for task_idx in 0 ..< VISIBILITY_TASK_COUNT {
      buffers := &frame.tasks[task_idx]
      buffers.draw_count = gpu.create_host_visible_buffer(
        gpu_context,
        u32,
        1,
        {.STORAGE_BUFFER, .TRANSFER_DST},
      ) or_return

      buffers.draw_commands = gpu.create_host_visible_buffer(
        gpu_context,
        vk.DrawIndexedIndirectCommand,
        int(system.max_draws),
        {.STORAGE_BUFFER, .INDIRECT_BUFFER, .TRANSFER_DST},
      ) or_return
    }
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
      sType        = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
      bindingCount = len(bindings),
      pBindings    = raw_data(bindings[:]),
    },
    nil,
    &system.descriptor_set_layout,
  ) or_return

  push_constant_range := vk.PushConstantRange {
    stageFlags = {.COMPUTE},
    size       = size_of(VisibilityPushConstants),
  }

  vk.CreatePipelineLayout(
    gpu_context.device,
    &vk.PipelineLayoutCreateInfo {
      sType                  = .PIPELINE_LAYOUT_CREATE_INFO,
      setLayoutCount         = 1,
      pSetLayouts            = &system.descriptor_set_layout,
      pushConstantRangeCount = 1,
      pPushConstantRanges    = &push_constant_range,
    },
    nil,
    &system.pipeline_layout,
  ) or_return

  shader_module := gpu.create_shader_module(
    gpu_context,
    #load("../shader/visibility_culling/culling.spv"),
  ) or_return
  defer vk.DestroyShaderModule(gpu_context.device, shader_module, nil)

  compute_info := vk.ComputePipelineCreateInfo {
    sType  = .COMPUTE_PIPELINE_CREATE_INFO,
    stage  = {
      sType  = .PIPELINE_SHADER_STAGE_CREATE_INFO,
      stage  = {.COMPUTE},
      module = shader_module,
      pName  = "main",
    },
    layout = system.pipeline_layout,
  }

  vk.CreateComputePipelines(
    gpu_context.device,
    0,
    1,
    &compute_info,
    nil,
    &system.pipeline,
  ) or_return

  for frame_idx in 0 ..< resources.MAX_FRAMES_IN_FLIGHT {
    frame := &system.frames[frame_idx]
    layout_array := [VISIBILITY_TASK_COUNT]vk.DescriptorSetLayout{}
    for task_idx in 0 ..< VISIBILITY_TASK_COUNT do layout_array[task_idx] = system.descriptor_set_layout
    descriptor_sets := [VISIBILITY_TASK_COUNT]vk.DescriptorSet{}

    vk.AllocateDescriptorSets(
      gpu_context.device,
      &vk.DescriptorSetAllocateInfo {
        sType              = .DESCRIPTOR_SET_ALLOCATE_INFO,
        descriptorPool     = gpu_context.descriptor_pool,
        descriptorSetCount = VISIBILITY_TASK_COUNT,
        pSetLayouts        = &layout_array[0],
      },
      &descriptor_sets[0],
    ) or_return

    for task_idx in 0 ..< VISIBILITY_TASK_COUNT {
      buffers := &frame.tasks[task_idx]
      buffers.descriptor_set = descriptor_sets[task_idx]

      node_info := vk.DescriptorBufferInfo {
        buffer = resources_manager.node_data_buffer.buffer,
        range  = vk.DeviceSize(resources_manager.node_data_buffer.bytes_count),
      }
      mesh_info := vk.DescriptorBufferInfo {
        buffer = resources_manager.mesh_data_buffer.buffer,
        range  = vk.DeviceSize(resources_manager.mesh_data_buffer.bytes_count),
      }
      world_info := vk.DescriptorBufferInfo {
        buffer = resources_manager.world_matrix_buffers[frame_idx].buffer,
        range  = vk.DeviceSize(resources_manager.world_matrix_buffers[frame_idx].bytes_count),
      }
      camera_info := vk.DescriptorBufferInfo {
        buffer = resources_manager.camera_buffer.buffer,
        range  = vk.DeviceSize(resources_manager.camera_buffer.bytes_count),
      }
      count_info := vk.DescriptorBufferInfo {
        buffer = buffers.draw_count.buffer,
        range  = vk.DeviceSize(buffers.draw_count.bytes_count),
      }
      command_info := vk.DescriptorBufferInfo {
        buffer = buffers.draw_commands.buffer,
        range  = vk.DeviceSize(buffers.draw_commands.bytes_count),
      }

      writes := [?]vk.WriteDescriptorSet {
        {
          sType           = .WRITE_DESCRIPTOR_SET,
          dstSet          = buffers.descriptor_set,
          dstBinding      = 0,
          descriptorType  = .STORAGE_BUFFER,
          descriptorCount = 1,
          pBufferInfo     = &node_info,
        },
        {
          sType           = .WRITE_DESCRIPTOR_SET,
          dstSet          = buffers.descriptor_set,
          dstBinding      = 1,
          descriptorType  = .STORAGE_BUFFER,
          descriptorCount = 1,
          pBufferInfo     = &mesh_info,
        },
        {
          sType           = .WRITE_DESCRIPTOR_SET,
          dstSet          = buffers.descriptor_set,
          dstBinding      = 2,
          descriptorType  = .STORAGE_BUFFER,
          descriptorCount = 1,
          pBufferInfo     = &world_info,
        },
        {
          sType           = .WRITE_DESCRIPTOR_SET,
          dstSet          = buffers.descriptor_set,
          dstBinding      = 3,
          descriptorType  = .STORAGE_BUFFER,
          descriptorCount = 1,
          pBufferInfo     = &camera_info,
        },
        {
          sType           = .WRITE_DESCRIPTOR_SET,
          dstSet          = buffers.descriptor_set,
          dstBinding      = 4,
          descriptorType  = .STORAGE_BUFFER,
          descriptorCount = 1,
          pBufferInfo     = &count_info,
        },
        {
          sType           = .WRITE_DESCRIPTOR_SET,
          dstSet          = buffers.descriptor_set,
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
  }

  return vk.Result.SUCCESS
}

visibility_system_shutdown :: proc(
  system: ^VisibilitySystem,
  gpu_context: ^gpu.GPUContext,
) {
  if gpu_context == nil {
    return
  }
  vk.DestroyPipeline(gpu_context.device, system.pipeline, nil)
  vk.DestroyPipelineLayout(gpu_context.device, system.pipeline_layout, nil)
  vk.DestroyDescriptorSetLayout(
    gpu_context.device,
    system.descriptor_set_layout,
    nil,
  )
  system.pipeline = 0
  system.pipeline_layout = 0
  system.descriptor_set_layout = 0

  for frame_idx in 0 ..< resources.MAX_FRAMES_IN_FLIGHT {
    frame := &system.frames[frame_idx]
    for task_idx in 0 ..< VISIBILITY_TASK_COUNT {
      buffers := &frame.tasks[task_idx]
      gpu.data_buffer_destroy(gpu_context, &buffers.draw_count)
      gpu.data_buffer_destroy(gpu_context, &buffers.draw_commands)
      buffers.descriptor_set = 0
    }
  }
}

visibility_system_set_node_count :: proc(system: ^VisibilitySystem, count: u32) {
  system.node_count = min(count, system.max_draws)
}

visibility_system_dispatch :: proc(
  system: ^VisibilitySystem,
  gpu_context: ^gpu.GPUContext,
  command_buffer: vk.CommandBuffer,
  frame_index: u32,
  task: VisibilityCategory,
  request: VisibilityRequest,
) -> VisibilityResult {
  result := VisibilityResult {
    draw_buffer    = 0,
    count_buffer   = 0,
    max_draws      = system.node_count,
    command_stride = visibility_system_command_stride(),
  }

  if system.node_count == 0 {
    return result
  }
  if frame_index >= resources.MAX_FRAMES_IN_FLIGHT {
    log.errorf("visibility_system_dispatch: invalid frame index %d", frame_index)
    return result
  }

  frame := &system.frames[frame_index]
  buffers := &frame.tasks[int(task)]

  vk.CmdFillBuffer(
    command_buffer,
    buffers.draw_count.buffer,
    0,
    vk.DeviceSize(buffers.draw_count.bytes_count),
    0,
  )
  vk.CmdFillBuffer(
    command_buffer,
    buffers.draw_commands.buffer,
    0,
    vk.DeviceSize(buffers.draw_commands.bytes_count),
    0,
  )

  buffer_barriers := [?]vk.BufferMemoryBarrier {
    {
      sType         = .BUFFER_MEMORY_BARRIER,
      srcAccessMask = {.TRANSFER_WRITE},
      dstAccessMask = {.SHADER_WRITE},
      buffer        = buffers.draw_count.buffer,
      offset        = 0,
      size          = vk.DeviceSize(buffers.draw_count.bytes_count),
    },
    {
      sType         = .BUFFER_MEMORY_BARRIER,
      srcAccessMask = {.TRANSFER_WRITE},
      dstAccessMask = {.SHADER_WRITE},
      buffer        = buffers.draw_commands.buffer,
      offset        = 0,
      size          = vk.DeviceSize(buffers.draw_commands.bytes_count),
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

  vk.CmdBindPipeline(command_buffer, .COMPUTE, system.pipeline)
  vk.CmdBindDescriptorSets(
    command_buffer,
    .COMPUTE,
    system.pipeline_layout,
    0,
    1,
    &buffers.descriptor_set,
    0,
    nil,
  )

  push_constants := VisibilityPushConstants {
    camera_index  = request.camera_index,
    node_count    = system.node_count,
    max_draws     = system.max_draws,
    include_flags = request.include_flags,
    exclude_flags = request.exclude_flags,
  }

  vk.CmdPushConstants(
    command_buffer,
    system.pipeline_layout,
    {.COMPUTE},
    0,
    size_of(push_constants),
    &push_constants,
  )

  dispatch_x := (system.node_count + 63) / 64
  vk.CmdDispatch(command_buffer, dispatch_x, 1, 1)

  post_barriers := [?]vk.BufferMemoryBarrier {
    {
      sType         = .BUFFER_MEMORY_BARRIER,
      srcAccessMask = {.SHADER_WRITE},
      dstAccessMask = {.INDIRECT_COMMAND_READ},
      buffer        = buffers.draw_commands.buffer,
      offset        = 0,
      size          = vk.DeviceSize(buffers.draw_commands.bytes_count),
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

  result.draw_buffer = buffers.draw_commands.buffer
  result.count_buffer = buffers.draw_count.buffer
  return result
}

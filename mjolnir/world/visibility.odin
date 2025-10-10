package world

import "core:log"
import "core:fmt"
import "core:math"
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
  // Early pass: cull using previous frame's visibility
  early_draw_count:    gpu.DataBuffer(u32),
  early_draw_commands: gpu.DataBuffer(vk.DrawIndexedIndirectCommand),
  early_descriptor_set: vk.DescriptorSet,

  // Late pass: cull all objects using depth pyramid
  late_draw_count:     gpu.DataBuffer(u32),
  late_draw_commands:  gpu.DataBuffer(vk.DrawIndexedIndirectCommand),
  late_descriptor_set:  vk.DescriptorSet,

  // Visibility tracking (which nodes are visible)
  visibility_buffer:   gpu.DataBuffer(u32), // Bitset: 1 = visible, 0 = not visible

  // Depth pyramid for occlusion culling
  depth_pyramid:       resources.Handle,
  depth_pyramid_mips:  u32,
  depth_pyramid_mip_views: [dynamic]vk.ImageView, // Individual views for each mip level

  // Descriptor sets for depth pyramid generation (one per mip level transition)
  // pyramid_gen_descriptor_sets[i] reads from mip i and writes to mip i+1
  pyramid_gen_descriptor_sets: [dynamic]vk.DescriptorSet,
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

DepthPyramidPushConstants :: struct {
  src_mip: u32,
  dst_mip: u32,
  dst_size: [2]u32,
}

LateCullPushConstants :: struct {
  camera_index:  u32,
  node_count:    u32,
  max_draws:     u32,
  include_flags: resources.NodeFlagSet,
  exclude_flags: resources.NodeFlagSet,
  depth_pyramid_mips: u32,
}

VisibilityResult :: struct {
  draw_buffer:    vk.Buffer,
  count_buffer:   vk.Buffer,
  command_stride: u32,
}

VisibilitySystem :: struct {
  // Early pass: frustum cull with previous visibility
  early_cull_descriptor_layout: vk.DescriptorSetLayout,
  early_cull_pipeline_layout:   vk.PipelineLayout,
  early_cull_pipeline:          vk.Pipeline,

  // Depth pyramid generation
  depth_pyramid_descriptor_layout: vk.DescriptorSetLayout,
  depth_pyramid_pipeline_layout:   vk.PipelineLayout,
  depth_pyramid_pipeline:          vk.Pipeline,

  // Late pass: frustum + occlusion cull
  late_cull_descriptor_layout: vk.DescriptorSetLayout,
  late_cull_pipeline_layout:   vk.PipelineLayout,
  late_cull_pipeline:          vk.Pipeline,

  frames:                [resources.MAX_FRAMES_IN_FLIGHT]VisibilityFrame,
  max_draws:             u32,
  node_count:            u32,
}

draw_command_stride :: proc() -> u32 {
  return u32(size_of(vk.DrawIndexedIndirectCommand))
}

calculate_mip_levels :: proc(width, height: u32) -> u32 {
  max_dim := max(width, height)
  return u32(math.floor(math.log2(f32(max_dim)))) + 1
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

  // TODO: Get actual depth texture size - for now assume 1920x1080
  depth_width := u32(1920)
  depth_height := u32(1080)
  depth_mips := calculate_mip_levels(depth_width, depth_height)

  // Create buffers and resources for each frame
  for frame_idx in 0 ..< resources.MAX_FRAMES_IN_FLIGHT {
    frame := &system.frames[frame_idx]
    for task_idx in 0 ..< VISIBILITY_TASK_COUNT {
      task := &frame.tasks[task_idx]

      // Create early pass buffers
      task.early_draw_count = gpu.create_host_visible_buffer(
        gpu_context,
        u32,
        1,
        {.STORAGE_BUFFER, .TRANSFER_DST},
      ) or_return
      task.early_draw_commands = gpu.create_host_visible_buffer(
        gpu_context,
        vk.DrawIndexedIndirectCommand,
        int(system.max_draws),
        {.STORAGE_BUFFER, .INDIRECT_BUFFER, .TRANSFER_DST},
      ) or_return

      // Create late pass buffers
      task.late_draw_count = gpu.create_host_visible_buffer(
        gpu_context,
        u32,
        1,
        {.STORAGE_BUFFER, .TRANSFER_DST},
      ) or_return
      task.late_draw_commands = gpu.create_host_visible_buffer(
        gpu_context,
        vk.DrawIndexedIndirectCommand,
        int(system.max_draws),
        {.STORAGE_BUFFER, .INDIRECT_BUFFER, .TRANSFER_DST},
      ) or_return

      // Create visibility buffer (one u32 per node)
      task.visibility_buffer = gpu.create_host_visible_buffer(
        gpu_context,
        u32,
        int(resources.MAX_NODES_IN_SCENE),
        {.STORAGE_BUFFER, .TRANSFER_DST},
      ) or_return

      // Create depth pyramid (storage image for compute writes)
      task.depth_pyramid_mips = depth_mips
      pyramid_handle, pyramid_texture, pyramid_ok := resources.alloc(&resources_manager.image_2d_buffers)
      if !pyramid_ok {
        log.error("Failed to allocate depth pyramid texture")
        return .ERROR_OUT_OF_DEVICE_MEMORY
      }
      task.depth_pyramid = pyramid_handle

      // Create image with mips for storage
      pyramid_texture^ = gpu.malloc_image_buffer_with_mips(
        gpu_context,
        depth_width,
        depth_height,
        .R32_SFLOAT,
        .OPTIMAL,
        {.SAMPLED, .STORAGE},
        {.DEVICE_LOCAL},
        depth_mips,
      ) or_return

      // Create image view for all mips (for sampling in late pass)
      pyramid_texture.view = gpu.create_image_view_with_mips(
        gpu_context.device,
        pyramid_texture.image,
        .R32_SFLOAT,
        {.COLOR},
        depth_mips,
      ) or_return

      // Initialize arrays for pyramid generation
      task.pyramid_gen_descriptor_sets = make([dynamic]vk.DescriptorSet, 0, depth_mips)
      task.depth_pyramid_mip_views = make([dynamic]vk.ImageView, 0, depth_mips)
    }
  }

  // Initialize pipelines
  _init_early_cull_pipeline(system, gpu_context) or_return
  _init_depth_pyramid_pipeline(system, gpu_context) or_return
  _init_late_cull_pipeline(system, gpu_context) or_return

  // Create descriptor sets
  _create_descriptor_sets(system, gpu_context, resources_manager) or_return

  return vk.Result.SUCCESS
}

@(private = "file")
_init_early_cull_pipeline :: proc(
  system: ^VisibilitySystem,
  gpu_context: ^gpu.GPUContext,
) -> vk.Result {
  // Descriptor layout: nodes, meshes, world matrices, cameras, previous visibility, draw count, draw commands
  bindings := [?]vk.DescriptorSetLayoutBinding {
    {binding = 0, descriptorType = .STORAGE_BUFFER, descriptorCount = 1, stageFlags = {.COMPUTE}},
    {binding = 1, descriptorType = .STORAGE_BUFFER, descriptorCount = 1, stageFlags = {.COMPUTE}},
    {binding = 2, descriptorType = .STORAGE_BUFFER, descriptorCount = 1, stageFlags = {.COMPUTE}},
    {binding = 3, descriptorType = .STORAGE_BUFFER, descriptorCount = 1, stageFlags = {.COMPUTE}},
    {binding = 4, descriptorType = .STORAGE_BUFFER, descriptorCount = 1, stageFlags = {.COMPUTE}},
    {binding = 5, descriptorType = .STORAGE_BUFFER, descriptorCount = 1, stageFlags = {.COMPUTE}},
    {binding = 6, descriptorType = .STORAGE_BUFFER, descriptorCount = 1, stageFlags = {.COMPUTE}},
  }

  vk.CreateDescriptorSetLayout(
    gpu_context.device,
    &vk.DescriptorSetLayoutCreateInfo {
      sType        = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
      bindingCount = len(bindings),
      pBindings    = raw_data(bindings[:]),
    },
    nil,
    &system.early_cull_descriptor_layout,
  ) or_return

  push_range := vk.PushConstantRange {
    stageFlags = {.COMPUTE},
    size       = size_of(VisibilityPushConstants),
  }

  vk.CreatePipelineLayout(
    gpu_context.device,
    &vk.PipelineLayoutCreateInfo {
      sType                  = .PIPELINE_LAYOUT_CREATE_INFO,
      setLayoutCount         = 1,
      pSetLayouts            = &system.early_cull_descriptor_layout,
      pushConstantRangeCount = 1,
      pPushConstantRanges    = &push_range,
    },
    nil,
    &system.early_cull_pipeline_layout,
  ) or_return

  shader := gpu.create_shader_module(
    gpu_context.device,
    #load("../shader/visibility_culling/early_cull.spv"),
  ) or_return
  defer vk.DestroyShaderModule(gpu_context.device, shader, nil)

  vk.CreateComputePipelines(
    gpu_context.device,
    0,
    1,
    &vk.ComputePipelineCreateInfo {
      sType  = .COMPUTE_PIPELINE_CREATE_INFO,
      stage  = {
        sType  = .PIPELINE_SHADER_STAGE_CREATE_INFO,
        stage  = {.COMPUTE},
        module = shader,
        pName  = "main",
      },
      layout = system.early_cull_pipeline_layout,
    },
    nil,
    &system.early_cull_pipeline,
  ) or_return

  return .SUCCESS
}

@(private = "file")
_init_depth_pyramid_pipeline :: proc(
  system: ^VisibilitySystem,
  gpu_context: ^gpu.GPUContext,
) -> vk.Result {
  // Descriptor layout: source depth (sampler2D), destination depth (storage image)
  bindings := [?]vk.DescriptorSetLayoutBinding {
    {binding = 0, descriptorType = .COMBINED_IMAGE_SAMPLER, descriptorCount = 1, stageFlags = {.COMPUTE}},
    {binding = 1, descriptorType = .STORAGE_IMAGE, descriptorCount = 1, stageFlags = {.COMPUTE}},
  }

  vk.CreateDescriptorSetLayout(
    gpu_context.device,
    &vk.DescriptorSetLayoutCreateInfo {
      sType        = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
      bindingCount = len(bindings),
      pBindings    = raw_data(bindings[:]),
    },
    nil,
    &system.depth_pyramid_descriptor_layout,
  ) or_return

  push_range := vk.PushConstantRange {
    stageFlags = {.COMPUTE},
    size       = size_of(DepthPyramidPushConstants),
  }

  vk.CreatePipelineLayout(
    gpu_context.device,
    &vk.PipelineLayoutCreateInfo {
      sType                  = .PIPELINE_LAYOUT_CREATE_INFO,
      setLayoutCount         = 1,
      pSetLayouts            = &system.depth_pyramid_descriptor_layout,
      pushConstantRangeCount = 1,
      pPushConstantRanges    = &push_range,
    },
    nil,
    &system.depth_pyramid_pipeline_layout,
  ) or_return

  shader := gpu.create_shader_module(
    gpu_context.device,
    #load("../shader/visibility_culling/depth_pyramid.spv"),
  ) or_return
  defer vk.DestroyShaderModule(gpu_context.device, shader, nil)

  vk.CreateComputePipelines(
    gpu_context.device,
    0,
    1,
    &vk.ComputePipelineCreateInfo {
      sType  = .COMPUTE_PIPELINE_CREATE_INFO,
      stage  = {
        sType  = .PIPELINE_SHADER_STAGE_CREATE_INFO,
        stage  = {.COMPUTE},
        module = shader,
        pName  = "main",
      },
      layout = system.depth_pyramid_pipeline_layout,
    },
    nil,
    &system.depth_pyramid_pipeline,
  ) or_return

  return .SUCCESS
}

@(private = "file")
_init_late_cull_pipeline :: proc(
  system: ^VisibilitySystem,
  gpu_context: ^gpu.GPUContext,
) -> vk.Result {
  // Descriptor layout: nodes, meshes, world matrices, cameras, depth pyramid, visibility, draw count, draw commands
  bindings := [?]vk.DescriptorSetLayoutBinding {
    {binding = 0, descriptorType = .STORAGE_BUFFER, descriptorCount = 1, stageFlags = {.COMPUTE}},
    {binding = 1, descriptorType = .STORAGE_BUFFER, descriptorCount = 1, stageFlags = {.COMPUTE}},
    {binding = 2, descriptorType = .STORAGE_BUFFER, descriptorCount = 1, stageFlags = {.COMPUTE}},
    {binding = 3, descriptorType = .STORAGE_BUFFER, descriptorCount = 1, stageFlags = {.COMPUTE}},
    {binding = 4, descriptorType = .COMBINED_IMAGE_SAMPLER, descriptorCount = 1, stageFlags = {.COMPUTE}},
    {binding = 5, descriptorType = .STORAGE_BUFFER, descriptorCount = 1, stageFlags = {.COMPUTE}},
    {binding = 6, descriptorType = .STORAGE_BUFFER, descriptorCount = 1, stageFlags = {.COMPUTE}},
    {binding = 7, descriptorType = .STORAGE_BUFFER, descriptorCount = 1, stageFlags = {.COMPUTE}},
  }

  vk.CreateDescriptorSetLayout(
    gpu_context.device,
    &vk.DescriptorSetLayoutCreateInfo {
      sType        = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
      bindingCount = len(bindings),
      pBindings    = raw_data(bindings[:]),
    },
    nil,
    &system.late_cull_descriptor_layout,
  ) or_return

  push_range := vk.PushConstantRange {
    stageFlags = {.COMPUTE},
    size       = size_of(LateCullPushConstants),
  }

  vk.CreatePipelineLayout(
    gpu_context.device,
    &vk.PipelineLayoutCreateInfo {
      sType                  = .PIPELINE_LAYOUT_CREATE_INFO,
      setLayoutCount         = 1,
      pSetLayouts            = &system.late_cull_descriptor_layout,
      pushConstantRangeCount = 1,
      pPushConstantRanges    = &push_range,
    },
    nil,
    &system.late_cull_pipeline_layout,
  ) or_return

  shader := gpu.create_shader_module(
    gpu_context.device,
    #load("../shader/visibility_culling/late_cull.spv"),
  ) or_return
  defer vk.DestroyShaderModule(gpu_context.device, shader, nil)

  vk.CreateComputePipelines(
    gpu_context.device,
    0,
    1,
    &vk.ComputePipelineCreateInfo {
      sType  = .COMPUTE_PIPELINE_CREATE_INFO,
      stage  = {
        sType  = .PIPELINE_SHADER_STAGE_CREATE_INFO,
        stage  = {.COMPUTE},
        module = shader,
        pName  = "main",
      },
      layout = system.late_cull_pipeline_layout,
    },
    nil,
    &system.late_cull_pipeline,
  ) or_return

  return .SUCCESS
}

@(private = "file")
_create_descriptor_sets :: proc(
  system: ^VisibilitySystem,
  gpu_context: ^gpu.GPUContext,
  resources_manager: ^resources.Manager,
) -> vk.Result {
  // Allocate descriptor sets for each frame and task
  for frame_idx in 0 ..< resources.MAX_FRAMES_IN_FLIGHT {
    frame := &system.frames[frame_idx]

    // Allocate early and late descriptor sets
    early_layouts := [VISIBILITY_TASK_COUNT]vk.DescriptorSetLayout{}
    late_layouts := [VISIBILITY_TASK_COUNT]vk.DescriptorSetLayout{}
    for i in 0 ..< VISIBILITY_TASK_COUNT {
      early_layouts[i] = system.early_cull_descriptor_layout
      late_layouts[i] = system.late_cull_descriptor_layout
    }

    early_sets := [VISIBILITY_TASK_COUNT]vk.DescriptorSet{}
    late_sets := [VISIBILITY_TASK_COUNT]vk.DescriptorSet{}

    vk.AllocateDescriptorSets(
      gpu_context.device,
      &vk.DescriptorSetAllocateInfo {
        sType              = .DESCRIPTOR_SET_ALLOCATE_INFO,
        descriptorPool     = gpu_context.descriptor_pool,
        descriptorSetCount = VISIBILITY_TASK_COUNT,
        pSetLayouts        = &early_layouts[0],
      },
      &early_sets[0],
    ) or_return

    vk.AllocateDescriptorSets(
      gpu_context.device,
      &vk.DescriptorSetAllocateInfo {
        sType              = .DESCRIPTOR_SET_ALLOCATE_INFO,
        descriptorPool     = gpu_context.descriptor_pool,
        descriptorSetCount = VISIBILITY_TASK_COUNT,
        pSetLayouts        = &late_layouts[0],
      },
      &late_sets[0],
    ) or_return

    for task_idx in 0 ..< VISIBILITY_TASK_COUNT {
      task := &frame.tasks[task_idx]
      task.early_descriptor_set = early_sets[task_idx]
      task.late_descriptor_set = late_sets[task_idx]

      // Get previous frame's visibility buffer for early pass
      prev_frame_idx := (frame_idx + resources.MAX_FRAMES_IN_FLIGHT - 1) % resources.MAX_FRAMES_IN_FLIGHT
      prev_visibility := system.frames[prev_frame_idx].tasks[task_idx].visibility_buffer

      // Update early pass descriptor set
      early_writes := [?]vk.WriteDescriptorSet {
        {
          sType           = .WRITE_DESCRIPTOR_SET,
          dstSet          = task.early_descriptor_set,
          dstBinding      = 0,
          descriptorType  = .STORAGE_BUFFER,
          descriptorCount = 1,
          pBufferInfo     = &vk.DescriptorBufferInfo {
            buffer = resources_manager.node_data_buffer.device_buffer,
            range  = vk.DeviceSize(resources_manager.node_data_buffer.bytes_count),
          },
        },
        {
          sType           = .WRITE_DESCRIPTOR_SET,
          dstSet          = task.early_descriptor_set,
          dstBinding      = 1,
          descriptorType  = .STORAGE_BUFFER,
          descriptorCount = 1,
          pBufferInfo     = &vk.DescriptorBufferInfo {
            buffer = resources_manager.mesh_data_buffer.device_buffer,
            range  = vk.DeviceSize(resources_manager.mesh_data_buffer.bytes_count),
          },
        },
        {
          sType           = .WRITE_DESCRIPTOR_SET,
          dstSet          = task.early_descriptor_set,
          dstBinding      = 2,
          descriptorType  = .STORAGE_BUFFER,
          descriptorCount = 1,
          pBufferInfo     = &vk.DescriptorBufferInfo {
            buffer = resources_manager.world_matrix_buffer.device_buffer,
            range  = vk.DeviceSize(resources_manager.world_matrix_buffer.bytes_count),
          },
        },
        {
          sType           = .WRITE_DESCRIPTOR_SET,
          dstSet          = task.early_descriptor_set,
          dstBinding      = 3,
          descriptorType  = .STORAGE_BUFFER,
          descriptorCount = 1,
          pBufferInfo     = &vk.DescriptorBufferInfo {
            buffer = resources_manager.camera_buffer.buffer,
            range  = vk.DeviceSize(resources_manager.camera_buffer.bytes_count),
          },
        },
        {
          sType           = .WRITE_DESCRIPTOR_SET,
          dstSet          = task.early_descriptor_set,
          dstBinding      = 4,
          descriptorType  = .STORAGE_BUFFER,
          descriptorCount = 1,
          pBufferInfo     = &vk.DescriptorBufferInfo {
            buffer = prev_visibility.buffer,
            range  = vk.DeviceSize(prev_visibility.bytes_count),
          },
        },
        {
          sType           = .WRITE_DESCRIPTOR_SET,
          dstSet          = task.early_descriptor_set,
          dstBinding      = 5,
          descriptorType  = .STORAGE_BUFFER,
          descriptorCount = 1,
          pBufferInfo     = &vk.DescriptorBufferInfo {
            buffer = task.early_draw_count.buffer,
            range  = vk.DeviceSize(task.early_draw_count.bytes_count),
          },
        },
        {
          sType           = .WRITE_DESCRIPTOR_SET,
          dstSet          = task.early_descriptor_set,
          dstBinding      = 6,
          descriptorType  = .STORAGE_BUFFER,
          descriptorCount = 1,
          pBufferInfo     = &vk.DescriptorBufferInfo {
            buffer = task.early_draw_commands.buffer,
            range  = vk.DeviceSize(task.early_draw_commands.bytes_count),
          },
        },
      }

      vk.UpdateDescriptorSets(
        gpu_context.device,
        len(early_writes),
        raw_data(early_writes[:]),
        0,
        nil,
      )

      // Update late pass descriptor set
      pyramid_texture := resources.get(resources_manager.image_2d_buffers, task.depth_pyramid)
      late_writes := [?]vk.WriteDescriptorSet {
        {
          sType           = .WRITE_DESCRIPTOR_SET,
          dstSet          = task.late_descriptor_set,
          dstBinding      = 0,
          descriptorType  = .STORAGE_BUFFER,
          descriptorCount = 1,
          pBufferInfo     = &vk.DescriptorBufferInfo {
            buffer = resources_manager.node_data_buffer.device_buffer,
            range  = vk.DeviceSize(resources_manager.node_data_buffer.bytes_count),
          },
        },
        {
          sType           = .WRITE_DESCRIPTOR_SET,
          dstSet          = task.late_descriptor_set,
          dstBinding      = 1,
          descriptorType  = .STORAGE_BUFFER,
          descriptorCount = 1,
          pBufferInfo     = &vk.DescriptorBufferInfo {
            buffer = resources_manager.mesh_data_buffer.device_buffer,
            range  = vk.DeviceSize(resources_manager.mesh_data_buffer.bytes_count),
          },
        },
        {
          sType           = .WRITE_DESCRIPTOR_SET,
          dstSet          = task.late_descriptor_set,
          dstBinding      = 2,
          descriptorType  = .STORAGE_BUFFER,
          descriptorCount = 1,
          pBufferInfo     = &vk.DescriptorBufferInfo {
            buffer = resources_manager.world_matrix_buffer.device_buffer,
            range  = vk.DeviceSize(resources_manager.world_matrix_buffer.bytes_count),
          },
        },
        {
          sType           = .WRITE_DESCRIPTOR_SET,
          dstSet          = task.late_descriptor_set,
          dstBinding      = 3,
          descriptorType  = .STORAGE_BUFFER,
          descriptorCount = 1,
          pBufferInfo     = &vk.DescriptorBufferInfo {
            buffer = resources_manager.camera_buffer.buffer,
            range  = vk.DeviceSize(resources_manager.camera_buffer.bytes_count),
          },
        },
        {
          sType           = .WRITE_DESCRIPTOR_SET,
          dstSet          = task.late_descriptor_set,
          dstBinding      = 4,
          descriptorType  = .COMBINED_IMAGE_SAMPLER,
          descriptorCount = 1,
          pImageInfo      = &vk.DescriptorImageInfo {
            sampler     = resources_manager.linear_clamp_sampler,
            imageView   = pyramid_texture.view,
            imageLayout = .SHADER_READ_ONLY_OPTIMAL,
          },
        },
        {
          sType           = .WRITE_DESCRIPTOR_SET,
          dstSet          = task.late_descriptor_set,
          dstBinding      = 5,
          descriptorType  = .STORAGE_BUFFER,
          descriptorCount = 1,
          pBufferInfo     = &vk.DescriptorBufferInfo {
            buffer = task.visibility_buffer.buffer,
            range  = vk.DeviceSize(task.visibility_buffer.bytes_count),
          },
        },
        {
          sType           = .WRITE_DESCRIPTOR_SET,
          dstSet          = task.late_descriptor_set,
          dstBinding      = 6,
          descriptorType  = .STORAGE_BUFFER,
          descriptorCount = 1,
          pBufferInfo     = &vk.DescriptorBufferInfo {
            buffer = task.late_draw_count.buffer,
            range  = vk.DeviceSize(task.late_draw_count.bytes_count),
          },
        },
        {
          sType           = .WRITE_DESCRIPTOR_SET,
          dstSet          = task.late_descriptor_set,
          dstBinding      = 7,
          descriptorType  = .STORAGE_BUFFER,
          descriptorCount = 1,
          pBufferInfo     = &vk.DescriptorBufferInfo {
            buffer = task.late_draw_commands.buffer,
            range  = vk.DeviceSize(task.late_draw_commands.bytes_count),
          },
        },
      }

      vk.UpdateDescriptorSets(
        gpu_context.device,
        len(late_writes),
        raw_data(late_writes[:]),
        0,
        nil,
      )

      // Create descriptor sets for depth pyramid generation
      pyramid_tex := resources.get(resources_manager.image_2d_buffers, task.depth_pyramid)
      if pyramid_tex != nil && task.depth_pyramid_mips > 1 {
        // Allocate descriptor sets for each mip transition
        num_transitions := task.depth_pyramid_mips - 1
        pyramid_layouts := make([]vk.DescriptorSetLayout, num_transitions)
        defer delete(pyramid_layouts)
        for i in 0 ..< num_transitions do pyramid_layouts[i] = system.depth_pyramid_descriptor_layout

        pyramid_sets := make([]vk.DescriptorSet, num_transitions)
        defer delete(pyramid_sets)

        vk.AllocateDescriptorSets(
          gpu_context.device,
          &vk.DescriptorSetAllocateInfo {
            sType              = .DESCRIPTOR_SET_ALLOCATE_INFO,
            descriptorPool     = gpu_context.descriptor_pool,
            descriptorSetCount = u32(num_transitions),
            pSetLayouts        = raw_data(pyramid_layouts),
          },
          raw_data(pyramid_sets),
        ) or_return

        // Create individual mip image views for storage access
        for mip_level in 0 ..< task.depth_pyramid_mips {
          mip_view_info := vk.ImageViewCreateInfo {
            sType    = .IMAGE_VIEW_CREATE_INFO,
            image    = pyramid_tex.image,
            viewType = .D2,
            format   = .R32_SFLOAT,
            subresourceRange = {
              aspectMask     = {.COLOR},
              baseMipLevel   = u32(mip_level),
              levelCount     = 1,
              baseArrayLayer = 0,
              layerCount     = 1,
            },
          }
          view: vk.ImageView
          vk.CreateImageView(
            gpu_context.device,
            &mip_view_info,
            nil,
            &view,
          ) or_return
          append(&task.depth_pyramid_mip_views, view)
        }

        // Update descriptor sets for each mip transition
        for i in 0 ..< num_transitions {
          src_mip := i
          dst_mip := i + 1

          writes := [?]vk.WriteDescriptorSet {
            {
              sType           = .WRITE_DESCRIPTOR_SET,
              dstSet          = pyramid_sets[i],
              dstBinding      = 0,
              descriptorType  = .COMBINED_IMAGE_SAMPLER,
              descriptorCount = 1,
              pImageInfo      = &vk.DescriptorImageInfo {
                sampler     = resources_manager.linear_clamp_sampler,
                imageView   = task.depth_pyramid_mip_views[src_mip],
                imageLayout = .SHADER_READ_ONLY_OPTIMAL,
              },
            },
            {
              sType           = .WRITE_DESCRIPTOR_SET,
              dstSet          = pyramid_sets[i],
              dstBinding      = 1,
              descriptorType  = .STORAGE_IMAGE,
              descriptorCount = 1,
              pImageInfo      = &vk.DescriptorImageInfo {
                imageView   = task.depth_pyramid_mip_views[dst_mip],
                imageLayout = .GENERAL,
              },
            },
          }

          vk.UpdateDescriptorSets(
            gpu_context.device,
            len(writes),
            raw_data(writes[:]),
            0,
            nil,
          )

          append(&task.pyramid_gen_descriptor_sets, pyramid_sets[i])
        }
      }
    }
  }

  return .SUCCESS
}

visibility_system_shutdown :: proc(
  system: ^VisibilitySystem,
  gpu_context: ^gpu.GPUContext,
) {
  if gpu_context == nil {
    return
  }

  // Destroy pipelines
  vk.DestroyPipeline(gpu_context.device, system.early_cull_pipeline, nil)
  vk.DestroyPipeline(gpu_context.device, system.depth_pyramid_pipeline, nil)
  vk.DestroyPipeline(gpu_context.device, system.late_cull_pipeline, nil)

  // Destroy pipeline layouts
  vk.DestroyPipelineLayout(gpu_context.device, system.early_cull_pipeline_layout, nil)
  vk.DestroyPipelineLayout(gpu_context.device, system.depth_pyramid_pipeline_layout, nil)
  vk.DestroyPipelineLayout(gpu_context.device, system.late_cull_pipeline_layout, nil)

  // Destroy descriptor set layouts
  vk.DestroyDescriptorSetLayout(gpu_context.device, system.early_cull_descriptor_layout, nil)
  vk.DestroyDescriptorSetLayout(gpu_context.device, system.depth_pyramid_descriptor_layout, nil)
  vk.DestroyDescriptorSetLayout(gpu_context.device, system.late_cull_descriptor_layout, nil)

  // Clean up buffers
  for frame_idx in 0 ..< resources.MAX_FRAMES_IN_FLIGHT {
    frame := &system.frames[frame_idx]
    for task_idx in 0 ..< VISIBILITY_TASK_COUNT {
      task := &frame.tasks[task_idx]
      gpu.data_buffer_destroy(gpu_context.device, &task.early_draw_count)
      gpu.data_buffer_destroy(gpu_context.device, &task.early_draw_commands)
      gpu.data_buffer_destroy(gpu_context.device, &task.late_draw_count)
      gpu.data_buffer_destroy(gpu_context.device, &task.late_draw_commands)
      gpu.data_buffer_destroy(gpu_context.device, &task.visibility_buffer)

      // Clean up depth pyramid mip views
      for view in task.depth_pyramid_mip_views {
        vk.DestroyImageView(gpu_context.device, view, nil)
      }
      delete(task.depth_pyramid_mip_views)
      delete(task.pyramid_gen_descriptor_sets)

      // Note: depth_pyramid textures are managed by resources.Manager
      task.early_descriptor_set = 0
      task.late_descriptor_set = 0
    }
  }
}

visibility_system_set_node_count :: proc(system: ^VisibilitySystem, count: u32) {
  system.node_count = min(count, system.max_draws)
}

// Generate depth pyramid by downsampling from mip 0 to all higher mips
@(private = "file")
_generate_depth_pyramid :: proc(
  system: ^VisibilitySystem,
  command_buffer: vk.CommandBuffer,
  task: ^VisibilityTask,
  resources_manager: ^resources.Manager,
  source_width, source_height: u32,
) {
  if task.depth_pyramid_mips <= 1 {
    return
  }

  pyramid_texture := resources.get(resources_manager.image_2d_buffers, task.depth_pyramid)
  if pyramid_texture == nil {
    log.error("Failed to get depth pyramid texture")
    return
  }

  // Transition pyramid to GENERAL layout for compute writes
  pyramid_barrier := vk.ImageMemoryBarrier {
    sType               = .IMAGE_MEMORY_BARRIER,
    srcAccessMask       = {.DEPTH_STENCIL_ATTACHMENT_WRITE},
    dstAccessMask       = {.SHADER_READ, .SHADER_WRITE},
    oldLayout           = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
    newLayout           = .GENERAL,
    image               = pyramid_texture.image,
    subresourceRange    = {
      aspectMask      = {.COLOR},
      baseMipLevel    = 0,
      levelCount      = task.depth_pyramid_mips,
      baseArrayLayer  = 0,
      layerCount      = 1,
    },
  }

  vk.CmdPipelineBarrier(
    command_buffer,
    {.LATE_FRAGMENT_TESTS},
    {.COMPUTE_SHADER},
    {},
    0, nil,
    0, nil,
    1, &pyramid_barrier,
  )

  // Bind pipeline
  vk.CmdBindPipeline(command_buffer, .COMPUTE, system.depth_pyramid_pipeline)

  // Generate each mip level
  current_width := source_width
  current_height := source_height

  for mip_level in 0 ..< task.depth_pyramid_mips - 1 {
    dst_width := max(current_width / 2, 1)
    dst_height := max(current_height / 2, 1)

    // Bind descriptor set for this mip transition
    vk.CmdBindDescriptorSets(
      command_buffer,
      .COMPUTE,
      system.depth_pyramid_pipeline_layout,
      0,
      1,
      &task.pyramid_gen_descriptor_sets[mip_level],
      0,
      nil,
    )

    // Push constants
    push := DepthPyramidPushConstants {
      src_mip  = u32(mip_level),
      dst_mip  = u32(mip_level + 1),
      dst_size = {dst_width, dst_height},
    }

    vk.CmdPushConstants(
      command_buffer,
      system.depth_pyramid_pipeline_layout,
      {.COMPUTE},
      0,
      size_of(push),
      &push,
    )

    // Dispatch compute shader
    dispatch_x := (dst_width + 15) / 16
    dispatch_y := (dst_height + 15) / 16
    vk.CmdDispatch(command_buffer, dispatch_x, dispatch_y, 1)

    // Barrier between mip levels (src mip -> dst mip)
    if mip_level < task.depth_pyramid_mips - 2 {
      mip_barrier := vk.ImageMemoryBarrier {
        sType               = .IMAGE_MEMORY_BARRIER,
        srcAccessMask       = {.SHADER_WRITE},
        dstAccessMask       = {.SHADER_READ},
        oldLayout           = .GENERAL,
        newLayout           = .GENERAL,
        image               = pyramid_texture.image,
        subresourceRange    = {
          aspectMask      = {.COLOR},
          baseMipLevel    = u32(mip_level + 1),
          levelCount      = 1,
          baseArrayLayer  = 0,
          layerCount      = 1,
        },
      }

      vk.CmdPipelineBarrier(
        command_buffer,
        {.COMPUTE_SHADER},
        {.COMPUTE_SHADER},
        {},
        0, nil,
        0, nil,
        1, &mip_barrier,
      )
    }

    current_width = dst_width
    current_height = dst_height
  }

  // Final transition to SHADER_READ_ONLY for late pass sampling
  final_barrier := vk.ImageMemoryBarrier {
    sType               = .IMAGE_MEMORY_BARRIER,
    srcAccessMask       = {.SHADER_WRITE},
    dstAccessMask       = {.SHADER_READ},
    oldLayout           = .GENERAL,
    newLayout           = .SHADER_READ_ONLY_OPTIMAL,
    image               = pyramid_texture.image,
    subresourceRange    = {
      aspectMask      = {.COLOR},
      baseMipLevel    = 0,
      levelCount      = task.depth_pyramid_mips,
      baseArrayLayer  = 0,
      layerCount      = 1,
    },
  }

  vk.CmdPipelineBarrier(
    command_buffer,
    {.COMPUTE_SHADER},
    {.COMPUTE_SHADER},
    {},
    0, nil,
    0, nil,
    1, &final_barrier,
  )
}

visibility_system_get_visible_count :: proc(
  system: ^VisibilitySystem,
  frame_index: u32,
  task: VisibilityCategory,
) -> u32 {
  if frame_index >= resources.MAX_FRAMES_IN_FLIGHT {
    return 0
  }
  frame := &system.frames[frame_index]
  task_data := &frame.tasks[int(task)]
  if task_data.late_draw_count.mapped == nil {
    return 0
  }
  return task_data.late_draw_count.mapped[0]
}

// 2-pass visibility dispatch with integrated depth rendering
// Returns the late pass draw commands for the geometry renderer to use
visibility_system_dispatch :: proc(
  system: ^VisibilitySystem,
  gpu_context: ^gpu.GPUContext,
  command_buffer: vk.CommandBuffer,
  frame_index: u32,
  category: VisibilityCategory,
  request: VisibilityRequest,
  depth_texture: resources.Handle,
  resources_manager: ^resources.Manager,
  extent: vk.Extent2D,
) -> VisibilityResult {
  result := VisibilityResult {
    draw_buffer    = 0,
    count_buffer   = 0,
    command_stride = draw_command_stride(),
  }

  if system.node_count == 0 {
    return result
  }
  if frame_index >= resources.MAX_FRAMES_IN_FLIGHT {
    log.errorf("visibility_system_dispatch: invalid frame index %d", frame_index)
    return result
  }

  frame := &system.frames[frame_index]
  task := &frame.tasks[int(category)]

  // === EARLY PASS: Frustum cull previously visible objects ===

  // Clear early pass buffers
  vk.CmdFillBuffer(command_buffer, task.early_draw_count.buffer, 0, vk.DeviceSize(vk.WHOLE_SIZE), 0)
  vk.CmdFillBuffer(command_buffer, task.early_draw_commands.buffer, 0, vk.DeviceSize(vk.WHOLE_SIZE), 0)

  early_barriers := [?]vk.BufferMemoryBarrier{
    {sType = .BUFFER_MEMORY_BARRIER, srcAccessMask = {.TRANSFER_WRITE}, dstAccessMask = {.SHADER_WRITE}, buffer = task.early_draw_count.buffer, size = vk.DeviceSize(vk.WHOLE_SIZE)},
    {sType = .BUFFER_MEMORY_BARRIER, srcAccessMask = {.TRANSFER_WRITE}, dstAccessMask = {.SHADER_WRITE}, buffer = task.early_draw_commands.buffer, size = vk.DeviceSize(vk.WHOLE_SIZE)},
  }
  vk.CmdPipelineBarrier(
    command_buffer,
    {.TRANSFER},
    {.COMPUTE_SHADER},
    {},
    0, nil,
    len(early_barriers),
    raw_data(early_barriers[:]),
    0, nil,
  )

  // Dispatch early cull compute shader
  vk.CmdBindPipeline(command_buffer, .COMPUTE, system.early_cull_pipeline)
  vk.CmdBindDescriptorSets(command_buffer, .COMPUTE, system.early_cull_pipeline_layout, 0, 1, &task.early_descriptor_set, 0, nil)

  early_push := VisibilityPushConstants {
    camera_index  = request.camera_index,
    node_count    = system.node_count,
    max_draws     = system.max_draws,
    include_flags = request.include_flags,
    exclude_flags = request.exclude_flags,
  }
  vk.CmdPushConstants(command_buffer, system.early_cull_pipeline_layout, {.COMPUTE}, 0, size_of(early_push), &early_push)

  dispatch_x := (system.node_count + 63) / 64
  vk.CmdDispatch(command_buffer, dispatch_x, 1, 1)

  // Barrier: early cull compute → early depth render
  early_to_depth_barriers := [?]vk.BufferMemoryBarrier{
    {sType = .BUFFER_MEMORY_BARRIER, srcAccessMask = {.SHADER_WRITE}, dstAccessMask = {.INDIRECT_COMMAND_READ}, buffer = task.early_draw_count.buffer, size = vk.DeviceSize(vk.WHOLE_SIZE)},
    {sType = .BUFFER_MEMORY_BARRIER, srcAccessMask = {.SHADER_WRITE}, dstAccessMask = {.INDIRECT_COMMAND_READ}, buffer = task.early_draw_commands.buffer, size = vk.DeviceSize(vk.WHOLE_SIZE)},
  }
  vk.CmdPipelineBarrier(
    command_buffer,
    {.COMPUTE_SHADER},
    {.DRAW_INDIRECT},
    {},
    0, nil,
    len(early_to_depth_barriers),
    raw_data(early_to_depth_barriers[:]),
    0, nil,
  )

  // Render depth using early pass draw commands
  // TODO: Call depth rendering here with task.early_draw_commands
  // For now, we'll skip this and implement it in the integration phase

  // === DEPTH PYRAMID GENERATION ===

  // Generate depth pyramid from the rendered depth texture
  _generate_depth_pyramid(system, command_buffer, task, resources_manager, extent.width, extent.height)

  // === LATE PASS: Frustum + occlusion cull all objects ===

  // Clear late pass buffers and visibility buffer
  vk.CmdFillBuffer(command_buffer, task.late_draw_count.buffer, 0, vk.DeviceSize(vk.WHOLE_SIZE), 0)
  vk.CmdFillBuffer(command_buffer, task.late_draw_commands.buffer, 0, vk.DeviceSize(vk.WHOLE_SIZE), 0)
  vk.CmdFillBuffer(command_buffer, task.visibility_buffer.buffer, 0, vk.DeviceSize(vk.WHOLE_SIZE), 0)

  late_barriers := [?]vk.BufferMemoryBarrier{
    {sType = .BUFFER_MEMORY_BARRIER, srcAccessMask = {.TRANSFER_WRITE}, dstAccessMask = {.SHADER_WRITE}, buffer = task.late_draw_count.buffer, size = vk.DeviceSize(vk.WHOLE_SIZE)},
    {sType = .BUFFER_MEMORY_BARRIER, srcAccessMask = {.TRANSFER_WRITE}, dstAccessMask = {.SHADER_WRITE}, buffer = task.late_draw_commands.buffer, size = vk.DeviceSize(vk.WHOLE_SIZE)},
    {sType = .BUFFER_MEMORY_BARRIER, srcAccessMask = {.TRANSFER_WRITE}, dstAccessMask = {.SHADER_WRITE}, buffer = task.visibility_buffer.buffer, size = vk.DeviceSize(vk.WHOLE_SIZE)},
  }
  vk.CmdPipelineBarrier(
    command_buffer,
    {.TRANSFER},
    {.COMPUTE_SHADER},
    {},
    0, nil,
    len(late_barriers),
    raw_data(late_barriers[:]),
    0, nil,
  )

  // Dispatch late cull compute shader
  vk.CmdBindPipeline(command_buffer, .COMPUTE, system.late_cull_pipeline)
  vk.CmdBindDescriptorSets(command_buffer, .COMPUTE, system.late_cull_pipeline_layout, 0, 1, &task.late_descriptor_set, 0, nil)

  late_push := LateCullPushConstants {
    camera_index       = request.camera_index,
    node_count         = system.node_count,
    max_draws          = system.max_draws,
    include_flags      = request.include_flags,
    exclude_flags      = request.exclude_flags,
    depth_pyramid_mips = task.depth_pyramid_mips,
  }
  vk.CmdPushConstants(command_buffer, system.late_cull_pipeline_layout, {.COMPUTE}, 0, size_of(late_push), &late_push)

  vk.CmdDispatch(command_buffer, dispatch_x, 1, 1)

  // Barrier: late cull compute → geometry render
  late_to_geom_barriers := [?]vk.BufferMemoryBarrier{
    {sType = .BUFFER_MEMORY_BARRIER, srcAccessMask = {.SHADER_WRITE}, dstAccessMask = {.INDIRECT_COMMAND_READ}, buffer = task.late_draw_count.buffer, size = vk.DeviceSize(vk.WHOLE_SIZE)},
    {sType = .BUFFER_MEMORY_BARRIER, srcAccessMask = {.SHADER_WRITE}, dstAccessMask = {.INDIRECT_COMMAND_READ}, buffer = task.late_draw_commands.buffer, size = vk.DeviceSize(vk.WHOLE_SIZE)},
  }
  vk.CmdPipelineBarrier(
    command_buffer,
    {.COMPUTE_SHADER},
    {.DRAW_INDIRECT},
    {},
    0, nil,
    len(late_to_geom_barriers),
    raw_data(late_to_geom_barriers[:]),
    0, nil,
  )

  // Return late pass results for geometry rendering
  result.draw_buffer = task.late_draw_commands.buffer
  result.count_buffer = task.late_draw_count.buffer
  return result
}

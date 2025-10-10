package world

import "core:log"
import "core:fmt"
import "core:math"
import "core:mem"
import geometry "../geometry"
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
  early_depth_texture: resources.Handle, // Own depth texture for early pass rendering
  early_debug_counter: gpu.DataBuffer(u32), // DEBUG: Safe buffer for sentinel tracing

  // Late pass: cull all objects using depth pyramid
  late_draw_count:     gpu.DataBuffer(u32),
  late_draw_commands:  gpu.DataBuffer(vk.DrawIndexedIndirectCommand),
  late_descriptor_set:  vk.DescriptorSet,
  late_depth_texture:  resources.Handle, // Own depth texture for late pass rendering
  late_debug_counter:  gpu.DataBuffer(u32), // DEBUG: Safe buffer for sentinel tracing

  // Visibility tracking (which nodes are visible)
  visibility_buffer:   gpu.DataBuffer(u32), // Bitset: 1 = visible, 0 = not visible

  // Depth pyramid for occlusion culling (built from early_depth_texture)
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

  // Early depth render: depth-only rendering using early pass results
  early_depth_pipeline_layout:  vk.PipelineLayout,
  early_depth_pipeline:         vk.Pipeline,

  // Depth pyramid generation (from early depth mip 0)
  depth_pyramid_descriptor_layout: vk.DescriptorSetLayout,
  depth_pyramid_pipeline_layout:   vk.PipelineLayout,
  depth_pyramid_pipeline:          vk.Pipeline,

  // Late pass: frustum + occlusion cull
  late_cull_descriptor_layout: vk.DescriptorSetLayout,
  late_cull_pipeline_layout:   vk.PipelineLayout,
  late_cull_pipeline:          vk.Pipeline,

  // Late depth render: depth rendering using late pass results
  late_depth_pipeline_layout:  vk.PipelineLayout,
  late_depth_pipeline:         vk.Pipeline,

  frames:                [resources.MAX_FRAMES_IN_FLIGHT]VisibilityFrame,
  max_draws:             u32,
  node_count:            u32,
  frame_counter:         u64, // Total frames rendered
  depth_extent:          vk.Extent2D, // Size of depth textures
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
  depth_width: u32,
  depth_height: u32,
) -> vk.Result {
  if gpu_context == nil || resources_manager == nil {
    return vk.Result.ERROR_INITIALIZATION_FAILED
  }

  system.max_draws = resources.MAX_NODES_IN_SCENE
  system.depth_extent = vk.Extent2D{width = depth_width, height = depth_height}
  
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
      task.early_debug_counter = gpu.create_host_visible_buffer(
        gpu_context,
        u32,
        1,
        {.TRANSFER_DST},
      ) or_return

      // Create early depth texture (for rendering previously visible objects)
      early_depth_handle, early_depth_texture, early_depth_ok := resources.alloc(&resources_manager.image_2d_buffers)
      if !early_depth_ok {
        log.error("Failed to allocate early depth texture")
        return .ERROR_OUT_OF_DEVICE_MEMORY
      }
      task.early_depth_texture = early_depth_handle
      early_depth_texture^ = gpu.malloc_image_buffer(
        gpu_context,
        depth_width,
        depth_height,
        .D32_SFLOAT,
        .OPTIMAL,
        {.DEPTH_STENCIL_ATTACHMENT, .SAMPLED},
        {.DEVICE_LOCAL},
      ) or_return
      early_depth_texture.view = gpu.create_image_view(
        gpu_context.device,
        early_depth_texture.image,
        .D32_SFLOAT,
        {.DEPTH},
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
      task.late_debug_counter = gpu.create_host_visible_buffer(
        gpu_context,
        u32,
        1,
        {.TRANSFER_DST},
      ) or_return

      // Create late depth texture (for rendering final visible objects)
      late_depth_handle, late_depth_texture, late_depth_ok := resources.alloc(&resources_manager.image_2d_buffers)
      if !late_depth_ok {
        log.error("Failed to allocate late depth texture")
        return .ERROR_OUT_OF_DEVICE_MEMORY
      }
      task.late_depth_texture = late_depth_handle
      late_depth_texture^ = gpu.malloc_image_buffer(
        gpu_context,
        depth_width,
        depth_height,
        .D32_SFLOAT,
        .OPTIMAL,
        {.DEPTH_STENCIL_ATTACHMENT},
        {.DEVICE_LOCAL},
      ) or_return
      late_depth_texture.view = gpu.create_image_view(
        gpu_context.device,
        late_depth_texture.image,
        .D32_SFLOAT,
        {.DEPTH},
      ) or_return

      // Create visibility buffer (one u32 per node) - DEVICE_LOCAL for better GPU coherency
      // Initialize with all ZEROS so early pass renders nothing on frame 0 (as per design doc)
      visibility_init := make([]u32, resources.MAX_NODES_IN_SCENE)
      defer delete(visibility_init)
      for i in 0 ..< resources.MAX_NODES_IN_SCENE {
        visibility_init[i] = 0  // Start with nothing visible
      }

      task.visibility_buffer = gpu.create_local_buffer(
        gpu_context,
        u32,
        int(resources.MAX_NODES_IN_SCENE),
        {.STORAGE_BUFFER},
        raw_data(visibility_init),
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

  // Clear depth textures and pyramids to far plane (1.0)
  _clear_depth_resources(system, gpu_context, resources_manager) or_return

  // Initialize pipelines
  _init_early_cull_pipeline(system, gpu_context) or_return
  _init_early_depth_pipeline(system, gpu_context, resources_manager) or_return
  _init_depth_pyramid_pipeline(system, gpu_context) or_return
  _init_late_cull_pipeline(system, gpu_context) or_return
  _init_late_depth_pipeline(system, gpu_context, resources_manager) or_return

  // Create descriptor sets
  _create_descriptor_sets(system, gpu_context, resources_manager) or_return

  return vk.Result.SUCCESS
}

// Clear all depth textures and pyramids to far plane (1.0) during initialization
@(private = "file")
_clear_depth_resources :: proc(
  system: ^VisibilitySystem,
  gpu_context: ^gpu.GPUContext,
  resources_manager: ^resources.Manager,
) -> vk.Result {
  // Create one-time command buffer for initialization
  cmd_buf_info := vk.CommandBufferAllocateInfo {
    sType              = .COMMAND_BUFFER_ALLOCATE_INFO,
    commandPool        = gpu_context.command_pool,
    level              = .PRIMARY,
    commandBufferCount = 1,
  }

  command_buffer: vk.CommandBuffer
  vk.AllocateCommandBuffers(gpu_context.device, &cmd_buf_info, &command_buffer) or_return

  begin_info := vk.CommandBufferBeginInfo {
    sType = .COMMAND_BUFFER_BEGIN_INFO,
    flags = {.ONE_TIME_SUBMIT},
  }
  vk.BeginCommandBuffer(command_buffer, &begin_info) or_return

  // Clear all depth textures and pyramids in all frames/tasks
  for frame_idx in 0 ..< resources.MAX_FRAMES_IN_FLIGHT {
    frame := &system.frames[frame_idx]
    for task_idx in 0 ..< VISIBILITY_TASK_COUNT {
      task := &frame.tasks[task_idx]
      
      // Clear early depth texture
      early_depth := resources.get(resources_manager.image_2d_buffers, task.early_depth_texture)
      if early_depth != nil {
        barrier := vk.ImageMemoryBarrier {
          sType               = .IMAGE_MEMORY_BARRIER,
          srcAccessMask       = {},
          dstAccessMask       = {.TRANSFER_WRITE},
          oldLayout           = .UNDEFINED,
          newLayout           = .TRANSFER_DST_OPTIMAL,
          image               = early_depth.image,
          subresourceRange    = {
            aspectMask      = {.DEPTH},
            baseMipLevel    = 0,
            levelCount      = 1,
            baseArrayLayer  = 0,
            layerCount      = 1,
          },
        }
        vk.CmdPipelineBarrier(command_buffer, {.TOP_OF_PIPE}, {.TRANSFER}, {}, 0, nil, 0, nil, 1, &barrier)
        
        clear_value := vk.ClearDepthStencilValue {depth = 1.0, stencil = 0}
        clear_range := vk.ImageSubresourceRange {
          aspectMask      = {.DEPTH},
          baseMipLevel    = 0,
          levelCount      = 1,
          baseArrayLayer  = 0,
          layerCount      = 1,
        }
        vk.CmdClearDepthStencilImage(command_buffer, early_depth.image, .TRANSFER_DST_OPTIMAL, &clear_value, 1, &clear_range)
        
        barrier_final := vk.ImageMemoryBarrier {
          sType               = .IMAGE_MEMORY_BARRIER,
          srcAccessMask       = {.TRANSFER_WRITE},
          dstAccessMask       = {.DEPTH_STENCIL_ATTACHMENT_WRITE},
          oldLayout           = .TRANSFER_DST_OPTIMAL,
          newLayout           = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
          image               = early_depth.image,
          subresourceRange    = clear_range,
        }
        vk.CmdPipelineBarrier(command_buffer, {.TRANSFER}, {.EARLY_FRAGMENT_TESTS}, {}, 0, nil, 0, nil, 1, &barrier_final)
      }
      
      // Clear late depth texture
      late_depth := resources.get(resources_manager.image_2d_buffers, task.late_depth_texture)
      if late_depth != nil {
        barrier := vk.ImageMemoryBarrier {
          sType               = .IMAGE_MEMORY_BARRIER,
          srcAccessMask       = {},
          dstAccessMask       = {.TRANSFER_WRITE},
          oldLayout           = .UNDEFINED,
          newLayout           = .TRANSFER_DST_OPTIMAL,
          image               = late_depth.image,
          subresourceRange    = {
            aspectMask      = {.DEPTH},
            baseMipLevel    = 0,
            levelCount      = 1,
            baseArrayLayer  = 0,
            layerCount      = 1,
          },
        }
        vk.CmdPipelineBarrier(command_buffer, {.TOP_OF_PIPE}, {.TRANSFER}, {}, 0, nil, 0, nil, 1, &barrier)
        
        clear_value := vk.ClearDepthStencilValue {depth = 1.0, stencil = 0}
        clear_range := vk.ImageSubresourceRange {
          aspectMask      = {.DEPTH},
          baseMipLevel    = 0,
          levelCount      = 1,
          baseArrayLayer  = 0,
          layerCount      = 1,
        }
        vk.CmdClearDepthStencilImage(command_buffer, late_depth.image, .TRANSFER_DST_OPTIMAL, &clear_value, 1, &clear_range)
        
        barrier_final := vk.ImageMemoryBarrier {
          sType               = .IMAGE_MEMORY_BARRIER,
          srcAccessMask       = {.TRANSFER_WRITE},
          dstAccessMask       = {.DEPTH_STENCIL_ATTACHMENT_WRITE},
          oldLayout           = .TRANSFER_DST_OPTIMAL,
          newLayout           = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
          image               = late_depth.image,
          subresourceRange    = clear_range,
        }
        vk.CmdPipelineBarrier(command_buffer, {.TRANSFER}, {.EARLY_FRAGMENT_TESTS}, {}, 0, nil, 0, nil, 1, &barrier_final)
      }
      
      // Clear pyramid
      pyramid_texture := resources.get(resources_manager.image_2d_buffers, task.depth_pyramid)
      if pyramid_texture == nil do continue

      // Transition to TRANSFER_DST for clearing
      barrier_to_transfer := vk.ImageMemoryBarrier {
        sType               = .IMAGE_MEMORY_BARRIER,
        srcAccessMask       = {},
        dstAccessMask       = {.TRANSFER_WRITE},
        oldLayout           = .UNDEFINED,
        newLayout           = .TRANSFER_DST_OPTIMAL,
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
        {.TOP_OF_PIPE},
        {.TRANSFER},
        {},
        0, nil,
        0, nil,
        1, &barrier_to_transfer,
      )

      // Clear to far plane depth (1.0 in normalized depth)
      clear_value := vk.ClearColorValue {float32 = {1.0, 1.0, 1.0, 1.0}}
      clear_range := vk.ImageSubresourceRange {
        aspectMask      = {.COLOR},
        baseMipLevel    = 0,
        levelCount      = task.depth_pyramid_mips,
        baseArrayLayer  = 0,
        layerCount      = 1,
      }
      vk.CmdClearColorImage(
        command_buffer,
        pyramid_texture.image,
        .TRANSFER_DST_OPTIMAL,
        &clear_value,
        1,
        &clear_range,
      )

      // Transition to SHADER_READ_ONLY_OPTIMAL (matches descriptor expectation)
      barrier_to_read_only := vk.ImageMemoryBarrier {
        sType               = .IMAGE_MEMORY_BARRIER,
        srcAccessMask       = {.TRANSFER_WRITE},
        dstAccessMask       = {.SHADER_READ},
        oldLayout           = .TRANSFER_DST_OPTIMAL,
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
        {.TRANSFER},
        {.COMPUTE_SHADER},
        {},
        0, nil,
        0, nil,
        1, &barrier_to_read_only,
      )
    }
  }

  vk.EndCommandBuffer(command_buffer) or_return

  // Submit and wait
  submit_info := vk.SubmitInfo {
    sType              = .SUBMIT_INFO,
    commandBufferCount = 1,
    pCommandBuffers    = &command_buffer,
  }
  vk.QueueSubmit(gpu_context.graphics_queue, 1, &submit_info, 0) or_return
  vk.QueueWaitIdle(gpu_context.graphics_queue) or_return

  // Free command buffer
  vk.FreeCommandBuffers(gpu_context.device, gpu_context.command_pool, 1, &command_buffer)

  return .SUCCESS
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
_init_early_depth_pipeline :: proc(
  system: ^VisibilitySystem,
  gpu_context: ^gpu.GPUContext,
  resources_manager: ^resources.Manager,
) -> vk.Result {
  // Use geometry pipeline layout for bindless rendering
  system.early_depth_pipeline_layout = resources_manager.geometry_pipeline_layout
  if system.early_depth_pipeline_layout == 0 {
    log.error("Geometry pipeline layout not initialized")
    return .ERROR_INITIALIZATION_FAILED
  }

  // Load depth-only vertex shader (same as shadow pass)
  vert_module := gpu.create_shader_module(
    gpu_context.device,
    #load("../shader/shadow/vert.spv"),
  ) or_return
  defer vk.DestroyShaderModule(gpu_context.device, vert_module, nil)

  // Load minimal fragment shader (shadow frag is depth-only)
  frag_module := gpu.create_shader_module(
    gpu_context.device,
    #load("../shader/shadow/frag.spv"),
  ) or_return
  defer vk.DestroyShaderModule(gpu_context.device, frag_module, nil)

  shader_stages := [?]vk.PipelineShaderStageCreateInfo {
    {
      sType  = .PIPELINE_SHADER_STAGE_CREATE_INFO,
      stage  = {.VERTEX},
      module = vert_module,
      pName  = "main",
    },
    {
      sType  = .PIPELINE_SHADER_STAGE_CREATE_INFO,
      stage  = {.FRAGMENT},
      module = frag_module,
      pName  = "main",
    },
  }

  input_assembly := vk.PipelineInputAssemblyStateCreateInfo {
    sType    = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
    topology = .TRIANGLE_LIST,
  }

  dynamic_states_values := [?]vk.DynamicState{.VIEWPORT, .SCISSOR}
  dynamic_state_info := vk.PipelineDynamicStateCreateInfo {
    sType             = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
    dynamicStateCount = len(dynamic_states_values),
    pDynamicStates    = raw_data(dynamic_states_values[:]),
  }

  viewport_state := vk.PipelineViewportStateCreateInfo {
    sType         = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
    viewportCount = 1,
    scissorCount  = 1,
  }

  rasterizer := vk.PipelineRasterizationStateCreateInfo {
    sType       = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
    polygonMode = .FILL,
    cullMode    = {.BACK},
    frontFace   = .CLOCKWISE,
    lineWidth   = 1.0,
  }

  multisampling := vk.PipelineMultisampleStateCreateInfo {
    sType                = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
    rasterizationSamples = {._1},
  }

  depth_stencil_state := vk.PipelineDepthStencilStateCreateInfo {
    sType            = .PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
    depthTestEnable  = true,
    depthWriteEnable = true,
    depthCompareOp   = .LESS,
  }

  // Use dynamic rendering
  rendering_info := vk.PipelineRenderingCreateInfo {
    sType                 = .PIPELINE_RENDERING_CREATE_INFO,
    depthAttachmentFormat = .D32_SFLOAT,
  }

  vertex_input_info := vk.PipelineVertexInputStateCreateInfo {
    sType                           = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
    vertexBindingDescriptionCount   = len(geometry.VERTEX_BINDING_DESCRIPTION),
    pVertexBindingDescriptions      = raw_data(geometry.VERTEX_BINDING_DESCRIPTION[:]),
    vertexAttributeDescriptionCount = len(geometry.VERTEX_ATTRIBUTE_DESCRIPTIONS),
    pVertexAttributeDescriptions    = raw_data(geometry.VERTEX_ATTRIBUTE_DESCRIPTIONS[:]),
  }

  pipeline_info := vk.GraphicsPipelineCreateInfo {
    sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
    pNext               = &rendering_info,
    stageCount          = len(shader_stages),
    pStages             = raw_data(shader_stages[:]),
    pVertexInputState   = &vertex_input_info,
    pInputAssemblyState = &input_assembly,
    pViewportState      = &viewport_state,
    pRasterizationState = &rasterizer,
    pMultisampleState   = &multisampling,
    pDepthStencilState  = &depth_stencil_state,
    pDynamicState       = &dynamic_state_info,
    layout              = system.early_depth_pipeline_layout,
  }

  vk.CreateGraphicsPipelines(
    gpu_context.device,
    0,
    1,
    &pipeline_info,
    nil,
    &system.early_depth_pipeline,
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
_init_late_depth_pipeline :: proc(
  system: ^VisibilitySystem,
  gpu_context: ^gpu.GPUContext,
  resources_manager: ^resources.Manager,
) -> vk.Result {
  // Use geometry pipeline layout for bindless rendering (same as early depth)
  system.late_depth_pipeline_layout = resources_manager.geometry_pipeline_layout
  if system.late_depth_pipeline_layout == 0 {
    log.error("Geometry pipeline layout not initialized")
    return .ERROR_INITIALIZATION_FAILED
  }

  // Load depth-only vertex shader (same as shadow pass)
  vert_module := gpu.create_shader_module(
    gpu_context.device,
    #load("../shader/shadow/vert.spv"),
  ) or_return
  defer vk.DestroyShaderModule(gpu_context.device, vert_module, nil)

  // Load minimal fragment shader (shadow frag is depth-only)
  frag_module := gpu.create_shader_module(
    gpu_context.device,
    #load("../shader/shadow/frag.spv"),
  ) or_return
  defer vk.DestroyShaderModule(gpu_context.device, frag_module, nil)

  shader_stages := [?]vk.PipelineShaderStageCreateInfo {
    {
      sType  = .PIPELINE_SHADER_STAGE_CREATE_INFO,
      stage  = {.VERTEX},
      module = vert_module,
      pName  = "main",
    },
    {
      sType  = .PIPELINE_SHADER_STAGE_CREATE_INFO,
      stage  = {.FRAGMENT},
      module = frag_module,
      pName  = "main",
    },
  }

  input_assembly := vk.PipelineInputAssemblyStateCreateInfo {
    sType    = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
    topology = .TRIANGLE_LIST,
  }

  dynamic_states_values := [?]vk.DynamicState{.VIEWPORT, .SCISSOR}
  dynamic_state_info := vk.PipelineDynamicStateCreateInfo {
    sType             = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
    dynamicStateCount = len(dynamic_states_values),
    pDynamicStates    = raw_data(dynamic_states_values[:]),
  }

  viewport_state := vk.PipelineViewportStateCreateInfo {
    sType         = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
    viewportCount = 1,
    scissorCount  = 1,
  }

  rasterizer := vk.PipelineRasterizationStateCreateInfo {
    sType       = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
    polygonMode = .FILL,
    cullMode    = {.BACK},
    frontFace   = .CLOCKWISE,
    lineWidth   = 1.0,
  }

  multisampling := vk.PipelineMultisampleStateCreateInfo {
    sType                = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
    rasterizationSamples = {._1},
  }

  depth_stencil_state := vk.PipelineDepthStencilStateCreateInfo {
    sType            = .PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
    depthTestEnable  = true,
    depthWriteEnable = true,
    depthCompareOp   = .LESS,
  }

  // Use dynamic rendering
  rendering_info := vk.PipelineRenderingCreateInfo {
    sType                 = .PIPELINE_RENDERING_CREATE_INFO,
    depthAttachmentFormat = .D32_SFLOAT,
  }

  vertex_input_info := vk.PipelineVertexInputStateCreateInfo {
    sType                           = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
    vertexBindingDescriptionCount   = len(geometry.VERTEX_BINDING_DESCRIPTION),
    pVertexBindingDescriptions      = raw_data(geometry.VERTEX_BINDING_DESCRIPTION[:]),
    vertexAttributeDescriptionCount = len(geometry.VERTEX_ATTRIBUTE_DESCRIPTIONS),
    pVertexAttributeDescriptions    = raw_data(geometry.VERTEX_ATTRIBUTE_DESCRIPTIONS[:]),
  }

  pipeline_info := vk.GraphicsPipelineCreateInfo {
    sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
    pNext               = &rendering_info,
    stageCount          = len(shader_stages),
    pStages             = raw_data(shader_stages[:]),
    pVertexInputState   = &vertex_input_info,
    pInputAssemblyState = &input_assembly,
    pViewportState      = &viewport_state,
    pRasterizationState = &rasterizer,
    pMultisampleState   = &multisampling,
    pDepthStencilState  = &depth_stencil_state,
    pDynamicState       = &dynamic_state_info,
    layout              = system.late_depth_pipeline_layout,
  }

  vk.CreateGraphicsPipelines(
    gpu_context.device,
    0,
    1,
    &pipeline_info,
    nil,
    &system.late_depth_pipeline,
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

      // Get previous submission's visibility buffer for early pass
      // Early pass at frame N should read results written by late pass at frame N-1
      // With MAX_FRAMES_IN_FLIGHT=3, frame indices wrap: 0,1,2,0,1,2,...
      // So when processing frame_idx=0, previous frame is frame_idx=2
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
            sampler     = resources_manager.depth_pyramid_sampler,
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
                sampler     = resources_manager.depth_pyramid_sampler,
                imageView   = task.depth_pyramid_mip_views[src_mip],
                imageLayout = .GENERAL,  // Must match actual layout during pyramid generation
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
  vk.DestroyPipeline(gpu_context.device, system.early_depth_pipeline, nil)
  vk.DestroyPipeline(gpu_context.device, system.depth_pyramid_pipeline, nil)
  vk.DestroyPipeline(gpu_context.device, system.late_cull_pipeline, nil)
  vk.DestroyPipeline(gpu_context.device, system.late_depth_pipeline, nil)

  // Destroy pipeline layouts (early_depth and late_depth use geometry layout, don't destroy)
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

      // Note: depth_pyramid is managed by resources.Manager
      task.early_descriptor_set = 0
      task.late_descriptor_set = 0
    }
  }
}

visibility_system_set_node_count :: proc(system: ^VisibilitySystem, count: u32) {
  old_count := system.node_count
  system.node_count = min(count, system.max_draws)
  log.warnf("[Visibility] set_node_count: %d active nodes -> node_count=%d (max_draws=%d)",
            count, system.node_count, system.max_draws)

  if count != system.node_count {
    log.errorf("[Visibility] Node count CLAMPED from %d to %d by max_draws!", count, system.node_count)
  }
  if system.node_count == 0 {
    log.errorf("[Visibility] NODE COUNT IS ZERO! No objects will be rendered!")
  }
}

// Generate depth pyramid by downsampling early_depth texture to all pyramid mips
// The pyramid mip 0 comes directly from early_depth (via sampler), then we downsample to higher mips
@(private = "file")
_generate_depth_pyramid :: proc(
  system: ^VisibilitySystem,
  command_buffer: vk.CommandBuffer,
  task: ^VisibilityTask,
  gpu_context: ^gpu.GPUContext,
  resources_manager: ^resources.Manager,
  early_depth_texture: ^gpu.ImageBuffer,
) {
  if task.depth_pyramid_mips <= 1 {
    return
  }

  pyramid_texture := resources.get(resources_manager.image_2d_buffers, task.depth_pyramid)
  if pyramid_texture == nil {
    log.error("Failed to get depth pyramid texture")
    return
  }

  // Transition all pyramid mips to GENERAL layout for compute writes
  pyramid_barrier := vk.ImageMemoryBarrier {
    sType               = .IMAGE_MEMORY_BARRIER,
    srcAccessMask       = {.SHADER_READ},
    dstAccessMask       = {.SHADER_WRITE, .SHADER_READ},
    oldLayout           = .SHADER_READ_ONLY_OPTIMAL,
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
    {.COMPUTE_SHADER},
    {.COMPUTE_SHADER},
    {},
    0, nil,
    0, nil,
    1, &pyramid_barrier,
  )

  // Bind pipeline
  vk.CmdBindPipeline(command_buffer, .COMPUTE, system.depth_pyramid_pipeline)

  // First transition: Sample from early_depth, write to pyramid mip 0
  // We need a temporary descriptor set that samples early_depth and writes to pyramid mip 0
  first_desc_set: vk.DescriptorSet
  vk.AllocateDescriptorSets(
    gpu_context.device,
    &vk.DescriptorSetAllocateInfo {
      sType              = .DESCRIPTOR_SET_ALLOCATE_INFO,
      descriptorPool     = gpu_context.descriptor_pool,
      descriptorSetCount = 1,
      pSetLayouts        = &system.depth_pyramid_descriptor_layout,
    },
    &first_desc_set,
  )
  
  first_writes := [?]vk.WriteDescriptorSet {
    {
      sType           = .WRITE_DESCRIPTOR_SET,
      dstSet          = first_desc_set,
      dstBinding      = 0,
      descriptorType  = .COMBINED_IMAGE_SAMPLER,
      descriptorCount = 1,
      pImageInfo      = &vk.DescriptorImageInfo {
        sampler     = resources_manager.depth_pyramid_sampler,
        imageView   = early_depth_texture.view,
        imageLayout = .SHADER_READ_ONLY_OPTIMAL,
      },
    },
    {
      sType           = .WRITE_DESCRIPTOR_SET,
      dstSet          = first_desc_set,
      dstBinding      = 1,
      descriptorType  = .STORAGE_IMAGE,
      descriptorCount = 1,
      pImageInfo      = &vk.DescriptorImageInfo {
        imageView   = task.depth_pyramid_mip_views[0],
        imageLayout = .GENERAL,
      },
    },
  }
  
  vk.UpdateDescriptorSets(
    gpu_context.device,
    len(first_writes),
    raw_data(first_writes[:]),
    0,
    nil,
  )
  
  // Dispatch: early_depth → pyramid mip 0
  vk.CmdBindDescriptorSets(
    command_buffer,
    .COMPUTE,
    system.depth_pyramid_pipeline_layout,
    0,
    1,
    &first_desc_set,
    0,
    nil,
  )
  
  dst_width := max(system.depth_extent.width / 2, 1)
  dst_height := max(system.depth_extent.height / 2, 1)
  
  first_push := DepthPyramidPushConstants {
    src_mip  = 0,
    dst_mip  = 0,
    dst_size = {dst_width, dst_height},
  }
  
  vk.CmdPushConstants(
    command_buffer,
    system.depth_pyramid_pipeline_layout,
    {.COMPUTE},
    0,
    size_of(first_push),
    &first_push,
  )
  
  dispatch_x := (dst_width + 15) / 16
  dispatch_y := (dst_height + 15) / 16
  vk.CmdDispatch(command_buffer, dispatch_x, dispatch_y, 1)
  
  // Barrier: pyramid mip 0 write complete
  if task.depth_pyramid_mips > 1 {
    mip0_barrier := vk.ImageMemoryBarrier {
      sType               = .IMAGE_MEMORY_BARRIER,
      srcAccessMask       = {.SHADER_WRITE},
      dstAccessMask       = {.SHADER_READ},
      oldLayout           = .GENERAL,
      newLayout           = .GENERAL,
      image               = pyramid_texture.image,
      subresourceRange    = {
        aspectMask      = {.COLOR},
        baseMipLevel    = 0,
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
      1, &mip0_barrier,
    )
  }

  // Generate remaining mip levels: pyramid mip N → pyramid mip N+1
  current_width := dst_width
  current_height := dst_height

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

// Render early pass draw commands to early depth buffer
@(private = "file")
_render_early_depth :: proc(
  system: ^VisibilitySystem,
  command_buffer: vk.CommandBuffer,
  task: ^VisibilityTask,
  gpu_context: ^gpu.GPUContext,
  resources_manager: ^resources.Manager,
  camera_index: u32,
) {
  depth_img := resources.get(resources_manager.image_2d_buffers, task.early_depth_texture)
  if depth_img == nil {
    log.error("Failed to get early depth texture for rendering")
    return
  }

  // Transition depth to ATTACHMENT_OPTIMAL for rendering
  depth_barrier_to_attach := vk.ImageMemoryBarrier {
    sType               = .IMAGE_MEMORY_BARRIER,
    srcAccessMask       = {.DEPTH_STENCIL_ATTACHMENT_WRITE},
    dstAccessMask       = {.DEPTH_STENCIL_ATTACHMENT_WRITE, .DEPTH_STENCIL_ATTACHMENT_READ},
    oldLayout           = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
    newLayout           = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
    image               = depth_img.image,
    subresourceRange    = {
      aspectMask      = {.DEPTH},
      baseMipLevel    = 0,
      levelCount      = 1,
      baseArrayLayer  = 0,
      layerCount      = 1,
    },
  }

  vk.CmdPipelineBarrier(
    command_buffer,
    {.EARLY_FRAGMENT_TESTS, .LATE_FRAGMENT_TESTS},
    {.EARLY_FRAGMENT_TESTS, .LATE_FRAGMENT_TESTS},
    {},
    0, nil,
    0, nil,
    1, &depth_barrier_to_attach,
  )

  // Begin dynamic rendering
  depth_attachment := vk.RenderingAttachmentInfo {
    sType       = .RENDERING_ATTACHMENT_INFO,
    imageView   = depth_img.view,
    imageLayout = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
    loadOp      = .CLEAR, // Clear to far plane for early depth pass
    storeOp     = .STORE,
    clearValue  = {depthStencil = {depth = 1.0, stencil = 0}},
  }

  rendering_info := vk.RenderingInfo {
    sType                = .RENDERING_INFO,
    renderArea           = {extent = system.depth_extent},
    layerCount           = 1,
    pDepthAttachment     = &depth_attachment,
  }

  vk.CmdBeginRendering(command_buffer, &rendering_info)

  // Set viewport and scissor
  viewport := vk.Viewport {
    width    = f32(system.depth_extent.width),
    height   = f32(system.depth_extent.height),
    minDepth = 0.0,
    maxDepth = 1.0,
  }
  scissor := vk.Rect2D {
    extent = system.depth_extent,
  }
  vk.CmdSetViewport(command_buffer, 0, 1, &viewport)
  vk.CmdSetScissor(command_buffer, 0, 1, &scissor)

  // Bind pipeline and resources
  vk.CmdBindPipeline(command_buffer, .GRAPHICS, system.early_depth_pipeline)
  vertex_offset := vk.DeviceSize(0)
  vk.CmdBindVertexBuffers(
    command_buffer,
    0,
    1,
    &resources_manager.vertex_buffer.buffer,
    &vertex_offset,
  )
  vk.CmdBindIndexBuffer(
    command_buffer,
    resources_manager.index_buffer.buffer,
    0,
    .UINT32,
  )

  // Bind all descriptor sets (geometry pipeline layout)
  descriptor_sets := [?]vk.DescriptorSet {
    resources_manager.world_matrix_descriptor_set,
    resources_manager.mesh_data_descriptor_set,
    resources_manager.node_data_descriptor_set,
    resources_manager.material_buffer_descriptor_set,
    resources_manager.camera_buffer_descriptor_set,
    resources_manager.textures_descriptor_set,
    resources_manager.bone_buffer_descriptor_set,
    resources_manager.lights_buffer_descriptor_set,
  }
  vk.CmdBindDescriptorSets(
    command_buffer,
    .GRAPHICS,
    system.early_depth_pipeline_layout,
    0,
    len(descriptor_sets),
    raw_data(descriptor_sets[:]),
    0,
    nil,
  )

  // Push camera index
  PushConstant :: struct {
    camera_index: u32,
  }
  push := PushConstant {
    camera_index = camera_index,
  }
  vk.CmdPushConstants(
    command_buffer,
    system.early_depth_pipeline_layout,
    {.VERTEX, .FRAGMENT},
    0,
    size_of(push),
    &push,
  )

  // Draw indexed indirect with count buffer (only draws as many as early pass generated)
  vk.CmdDrawIndexedIndirectCount(
    command_buffer,
    task.early_draw_commands.buffer,
    0,
    task.early_draw_count.buffer,
    0,
    system.max_draws,
    draw_command_stride(),
  )

  vk.CmdEndRendering(command_buffer)
}

// Render late pass draw commands to late depth buffer
@(private = "file")
_render_late_depth :: proc(
  system: ^VisibilitySystem,
  command_buffer: vk.CommandBuffer,
  task: ^VisibilityTask,
  gpu_context: ^gpu.GPUContext,
  resources_manager: ^resources.Manager,
  camera_index: u32,
) {
  depth_img := resources.get(resources_manager.image_2d_buffers, task.late_depth_texture)
  if depth_img == nil {
    log.error("Failed to get late depth texture for rendering")
    return
  }

  // Transition depth to ATTACHMENT_OPTIMAL for rendering
  depth_barrier_to_attach := vk.ImageMemoryBarrier {
    sType               = .IMAGE_MEMORY_BARRIER,
    srcAccessMask       = {.DEPTH_STENCIL_ATTACHMENT_WRITE},
    dstAccessMask       = {.DEPTH_STENCIL_ATTACHMENT_WRITE, .DEPTH_STENCIL_ATTACHMENT_READ},
    oldLayout           = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
    newLayout           = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
    image               = depth_img.image,
    subresourceRange    = {
      aspectMask      = {.DEPTH},
      baseMipLevel    = 0,
      levelCount      = 1,
      baseArrayLayer  = 0,
      layerCount      = 1,
    },
  }

  vk.CmdPipelineBarrier(
    command_buffer,
    {.EARLY_FRAGMENT_TESTS, .LATE_FRAGMENT_TESTS},
    {.EARLY_FRAGMENT_TESTS, .LATE_FRAGMENT_TESTS},
    {},
    0, nil,
    0, nil,
    1, &depth_barrier_to_attach,
  )

  // Begin dynamic rendering
  depth_attachment := vk.RenderingAttachmentInfo {
    sType       = .RENDERING_ATTACHMENT_INFO,
    imageView   = depth_img.view,
    imageLayout = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
    loadOp      = .CLEAR, // Clear to far plane for late depth pass
    storeOp     = .STORE,
    clearValue  = {depthStencil = {depth = 1.0, stencil = 0}},
  }

  rendering_info := vk.RenderingInfo {
    sType                = .RENDERING_INFO,
    renderArea           = {extent = system.depth_extent},
    layerCount           = 1,
    pDepthAttachment     = &depth_attachment,
  }

  vk.CmdBeginRendering(command_buffer, &rendering_info)

  // Set viewport and scissor
  viewport := vk.Viewport {
    width    = f32(system.depth_extent.width),
    height   = f32(system.depth_extent.height),
    minDepth = 0.0,
    maxDepth = 1.0,
  }
  scissor := vk.Rect2D {
    extent = system.depth_extent,
  }
  vk.CmdSetViewport(command_buffer, 0, 1, &viewport)
  vk.CmdSetScissor(command_buffer, 0, 1, &scissor)

  // Bind pipeline and resources
  vk.CmdBindPipeline(command_buffer, .GRAPHICS, system.late_depth_pipeline)
  vertex_offset := vk.DeviceSize(0)
  vk.CmdBindVertexBuffers(
    command_buffer,
    0,
    1,
    &resources_manager.vertex_buffer.buffer,
    &vertex_offset,
  )
  vk.CmdBindIndexBuffer(
    command_buffer,
    resources_manager.index_buffer.buffer,
    0,
    .UINT32,
  )

  // Bind all descriptor sets (geometry pipeline layout)
  descriptor_sets := [?]vk.DescriptorSet {
    resources_manager.world_matrix_descriptor_set,
    resources_manager.mesh_data_descriptor_set,
    resources_manager.node_data_descriptor_set,
    resources_manager.material_buffer_descriptor_set,
    resources_manager.camera_buffer_descriptor_set,
    resources_manager.textures_descriptor_set,
    resources_manager.bone_buffer_descriptor_set,
    resources_manager.lights_buffer_descriptor_set,
  }
  vk.CmdBindDescriptorSets(
    command_buffer,
    .GRAPHICS,
    system.late_depth_pipeline_layout,
    0,
    len(descriptor_sets),
    raw_data(descriptor_sets[:]),
    0,
    nil,
  )

  // Push camera index
  PushConstant :: struct {
    camera_index: u32,
  }
  push := PushConstant {
    camera_index = camera_index,
  }
  vk.CmdPushConstants(
    command_buffer,
    system.late_depth_pipeline_layout,
    {.VERTEX, .FRAGMENT},
    0,
    size_of(push),
    &push,
  )

  // Draw indexed indirect
  vk.CmdDrawIndexedIndirect(
    command_buffer,
    task.late_draw_commands.buffer,
    0,
    system.max_draws,
    draw_command_stride(),
  )

  vk.CmdEndRendering(command_buffer)
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
  resources_manager: ^resources.Manager,
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

  // DEBUG: Read previous frame's result NOW (after fence, GPU completed)
  if system.frame_counter > 0 && system.frame_counter <= 8 && int(category) == 0 {
    prev_value := task.early_draw_count.mapped != nil ? task.early_draw_count.mapped[0] : 0
    log.warnf("[Visibility Frame %d START] Reading PREVIOUS frame's early_draw_count = %d (0x%x) - this is AFTER GPU completed",
              system.frame_counter, prev_value, prev_value)
  }

  // Clear early pass buffers
  vk.CmdFillBuffer(command_buffer, task.early_draw_count.buffer, 0, vk.DeviceSize(vk.WHOLE_SIZE), 0)
  vk.CmdFillBuffer(command_buffer, task.early_draw_commands.buffer, 0, vk.DeviceSize(vk.WHOLE_SIZE), 0)
  // DEBUG: Unique sentinel in safe debug buffer
  early_sentinel := u32(0xEA000000) + u32(category) * 0x00010000 + u32(system.frame_counter & 0xFFFF)
  vk.CmdFillBuffer(command_buffer, task.early_debug_counter.buffer, 0, vk.DeviceSize(vk.WHOLE_SIZE), early_sentinel)

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
  if system.frame_counter < 3 {
    log.warnf("[Visibility] Binding early cull pipeline=%p, descriptor_set=%p", system.early_cull_pipeline, task.early_descriptor_set)
  }
  vk.CmdBindPipeline(command_buffer, .COMPUTE, system.early_cull_pipeline)
  vk.CmdBindDescriptorSets(command_buffer, .COMPUTE, system.early_cull_pipeline_layout, 0, 1, &task.early_descriptor_set, 0, nil)

  early_push := VisibilityPushConstants {
    camera_index  = request.camera_index,
    node_count    = system.node_count,
    max_draws     = system.max_draws,
    include_flags = request.include_flags,
    exclude_flags = request.exclude_flags,
  }

  if system.frame_counter < 3 {
    log.warnf("[Visibility Frame %d] Early pass push constants: node_count=%d, include_flags=0x%x, exclude_flags=0x%x",
              system.frame_counter, early_push.node_count, early_push.include_flags, early_push.exclude_flags)
  }

  vk.CmdPushConstants(command_buffer, system.early_cull_pipeline_layout, {.COMPUTE}, 0, size_of(early_push), &early_push)

  dispatch_x := (system.node_count + 63) / 64
  if system.frame_counter < 3 {
    log.warnf("[Visibility] Early pass dispatch: node_count=%d, workgroups=%d (threads=%d)", system.node_count, dispatch_x, dispatch_x * 64)
  }
  vk.CmdDispatch(command_buffer, dispatch_x, 1, 1)

  if system.frame_counter < 3 {
    log.warnf("[Visibility] RIGHT AFTER dispatch - early_draw_count buffer value=%d (NOTE: GPU hasn't executed yet!)",
              task.early_draw_count.mapped != nil ? task.early_draw_count.mapped[0] : 999)
  }

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

  // === EARLY DEPTH RENDERING ===
  // Render previously visible objects to early_depth_texture for occlusion pyramid
  _render_early_depth(system, command_buffer, task, gpu_context, resources_manager, request.camera_index)

  // === DEPTH PYRAMID GENERATION ===

  // Transition early depth from ATTACHMENT to SHADER_READ for pyramid generation
  early_depth_img := resources.get(resources_manager.image_2d_buffers, task.early_depth_texture)
  if early_depth_img != nil {
    depth_to_shader_barrier := vk.ImageMemoryBarrier {
      sType               = .IMAGE_MEMORY_BARRIER,
      srcAccessMask       = {.DEPTH_STENCIL_ATTACHMENT_WRITE},
      dstAccessMask       = {.SHADER_READ},
      oldLayout           = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
      newLayout           = .SHADER_READ_ONLY_OPTIMAL,
      image               = early_depth_img.image,
      subresourceRange    = {
        aspectMask      = {.DEPTH},
        baseMipLevel    = 0,
        levelCount      = 1,
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
      1, &depth_to_shader_barrier,
    )
  }

  // Generate pyramid mip chain from early depth texture
  _generate_depth_pyramid(system, command_buffer, task, gpu_context, resources_manager, early_depth_img)

  system.frame_counter += 1

  // === LATE PASS: Frustum + occlusion cull all objects ===

  // Debug: Read early pass draw count before late pass
  if system.frame_counter < 5 {
    // Force GPU to finish early pass (TEMPORARY DEBUG)
    vk.CmdPipelineBarrier(
      command_buffer,
      {.COMPUTE_SHADER},
      {.HOST},
      {},
      1,
      &vk.MemoryBarrier{
        sType         = .MEMORY_BARRIER,
        srcAccessMask = {.SHADER_WRITE},
        dstAccessMask = {.HOST_READ},
      },
      0, nil,
      0, nil,
    )
  }

  // Clear late pass buffers (visibility buffer is overwritten by shader, no clear needed)
  vk.CmdFillBuffer(command_buffer, task.late_draw_count.buffer, 0, vk.DeviceSize(vk.WHOLE_SIZE), 0)
  vk.CmdFillBuffer(command_buffer, task.late_draw_commands.buffer, 0, vk.DeviceSize(vk.WHOLE_SIZE), 0)
  // DEBUG: Unique sentinel in safe debug buffer (0xAA = lAte pass)
  late_sentinel := u32(0xAA000000) + u32(category) * 0x00010000 + u32(system.frame_counter & 0xFFFF)
  vk.CmdFillBuffer(command_buffer, task.late_debug_counter.buffer, 0, vk.DeviceSize(vk.WHOLE_SIZE), late_sentinel)

  late_barriers := [?]vk.BufferMemoryBarrier{
    {sType = .BUFFER_MEMORY_BARRIER, srcAccessMask = {.TRANSFER_WRITE}, dstAccessMask = {.SHADER_WRITE}, buffer = task.late_draw_count.buffer, size = vk.DeviceSize(vk.WHOLE_SIZE)},
    {sType = .BUFFER_MEMORY_BARRIER, srcAccessMask = {.TRANSFER_WRITE}, dstAccessMask = {.SHADER_WRITE}, buffer = task.late_draw_commands.buffer, size = vk.DeviceSize(vk.WHOLE_SIZE)},
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

  // Barrier: late cull compute → late depth render
  late_cull_to_depth_barriers := [?]vk.BufferMemoryBarrier{
    {sType = .BUFFER_MEMORY_BARRIER, srcAccessMask = {.SHADER_WRITE}, dstAccessMask = {.INDIRECT_COMMAND_READ}, buffer = task.late_draw_count.buffer, size = vk.DeviceSize(vk.WHOLE_SIZE)},
    {sType = .BUFFER_MEMORY_BARRIER, srcAccessMask = {.SHADER_WRITE}, dstAccessMask = {.INDIRECT_COMMAND_READ}, buffer = task.late_draw_commands.buffer, size = vk.DeviceSize(vk.WHOLE_SIZE)},
  }
  vk.CmdPipelineBarrier(
    command_buffer,
    {.COMPUTE_SHADER},
    {.DRAW_INDIRECT},
    {},
    0, nil,
    len(late_cull_to_depth_barriers),
    raw_data(late_cull_to_depth_barriers[:]),
    0, nil,
  )

  // === LATE DEPTH RENDERING ===
  // Render final visible objects to late_depth_texture
  _render_late_depth(system, command_buffer, task, gpu_context, resources_manager, request.camera_index)

  // Barrier: late depth render → geometry pass
  // IMPORTANT: Include visibility buffer with memory dependency to ensure writes are AVAILABLE
  late_to_geom_barriers := [?]vk.BufferMemoryBarrier{
    {sType = .BUFFER_MEMORY_BARRIER, srcAccessMask = {.SHADER_WRITE}, dstAccessMask = {.INDIRECT_COMMAND_READ}, buffer = task.late_draw_count.buffer, size = vk.DeviceSize(vk.WHOLE_SIZE)},
    {sType = .BUFFER_MEMORY_BARRIER, srcAccessMask = {.SHADER_WRITE}, dstAccessMask = {.INDIRECT_COMMAND_READ}, buffer = task.late_draw_commands.buffer, size = vk.DeviceSize(vk.WHOLE_SIZE)},
    {sType = .BUFFER_MEMORY_BARRIER, srcAccessMask = {.SHADER_WRITE}, dstAccessMask = {.SHADER_READ}, buffer = task.visibility_buffer.buffer, size = vk.DeviceSize(vk.WHOLE_SIZE)},
  }
  vk.CmdPipelineBarrier(
    command_buffer,
    {.LATE_FRAGMENT_TESTS, .COMPUTE_SHADER},
    {.DRAW_INDIRECT, .COMPUTE_SHADER},
    {},
    0, nil,
    len(late_to_geom_barriers),
    raw_data(late_to_geom_barriers[:]),
    0, nil,
  )

  // Additional global memory barrier to ensure visibility buffer writes are globally visible
  // This is critical for fence-synchronized cross-command-buffer reads
  vk.CmdPipelineBarrier(
    command_buffer,
    {.COMPUTE_SHADER},
    {.ALL_COMMANDS},
    {},
    1,
    &vk.MemoryBarrier{
      sType         = .MEMORY_BARRIER,
      srcAccessMask = {.SHADER_WRITE},
      dstAccessMask = {.MEMORY_READ},
    },
    0, nil,
    0, nil,
  )

  // Return late pass results for geometry rendering
  result.draw_buffer = task.late_draw_commands.buffer
  result.count_buffer = task.late_draw_count.buffer

  // Debug logging - read COMPLETED frame's results (from MAX_FRAMES_IN_FLIGHT ago)
  // This frame's results won't be available until the GPU finishes executing
  if system.frame_counter >= u64(resources.MAX_FRAMES_IN_FLIGHT) && system.frame_counter <= 60 && int(category) == 0 {
    // Read results from the frame that just completed (wraps around due to frame-in-flight)
    completed_frame_idx := (frame_index + 1) % resources.MAX_FRAMES_IN_FLIGHT
    completed_task := &system.frames[completed_frame_idx].tasks[int(category)]
    early_count := completed_task.early_draw_count.mapped != nil ? completed_task.early_draw_count.mapped[0] : 0
    late_count := completed_task.late_draw_count.mapped != nil ? completed_task.late_draw_count.mapped[0] : 0
    early_debug := completed_task.early_debug_counter.mapped != nil ? completed_task.early_debug_counter.mapped[0] : 0
    late_debug := completed_task.late_debug_counter.mapped != nil ? completed_task.late_debug_counter.mapped[0] : 0

    // Decode sentinel values to understand execution
    early_msg := ""
    if early_debug >= 0xEA000000 && early_debug < 0xEB000000 {
      early_msg = fmt.tprintf(" [SENT_UNCHANGED]")
    }
    late_msg := ""
    if late_debug >= 0xAA000000 && late_debug < 0xAB000000 {
      late_msg = fmt.tprintf(" [SENT_UNCHANGED]")
    }

    log.warnf("[Visibility Frame %d RESULTS] Early: %d%s, Late: %d%s (category %v) frame_slot=%d",
              system.frame_counter - u64(resources.MAX_FRAMES_IN_FLIGHT),
              early_count, early_msg, late_count, late_msg, category, frame_index)
  }

  return result
}

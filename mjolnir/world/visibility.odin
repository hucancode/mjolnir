package world

import "core:log"
import "core:fmt"
import "core:math"
import gpu "../gpu"
import geometry "../geometry"
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

// Enhanced visibility data for 2-pass culling
VisibilityTask :: struct {
  // Late pass buffers
  late_visibility:    gpu.DataBuffer(u32), // Current frame visibility
  late_draw_count:    gpu.DataBuffer(u32),
  late_draw_commands: gpu.DataBuffer(vk.DrawIndexedIndirectCommand),

  // Depth resources
  depth_texture:      gpu.ImageBuffer,
  depth_pyramid:      DepthPyramid,
  depth_framebuffer:  vk.Framebuffer,
  depth_render_pass:  vk.RenderPass,

  // Descriptor sets
  late_descriptor_set:  vk.DescriptorSet,
  depth_reduce_descriptor_sets: [16]vk.DescriptorSet, // For each mip level
}

// Depth pyramid for hierarchical Z-buffer occlusion culling
DepthPyramid :: struct {
  texture:         gpu.ImageBuffer,
  views:           [16]vk.ImageView, // Per-mip views for depth reduction (write)
  full_view:       vk.ImageView,     // Full pyramid view for sampling (read all mips)
  sampler:         vk.Sampler,
  mip_levels:      u32,
  width:           u32,
  height:          u32,
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
  camera_index:   u32,
  node_count:     u32,
  max_draws:      u32,
  include_flags:  resources.NodeFlagSet,
  exclude_flags:  resources.NodeFlagSet,
  pyramid_width:  f32,
  pyramid_height: f32,
  depth_bias:     f32,
  occlusion_enabled: u32,
}

DepthReducePushConstants :: struct {
  current_mip: u32,
  _padding: [3]u32,
}

VisibilityResult :: struct {
  draw_buffer:    vk.Buffer,
  count_buffer:   vk.Buffer,
  command_stride: u32,
}

// Statistics for a single culling pass
CullingStats :: struct {
  late_draw_count:   u32,
  category:          VisibilityCategory,
  frame_index:       u32,
}

VisibilitySystem :: struct {
  // Compute pipelines
  early_cull_pipeline:       vk.Pipeline,
  late_cull_pipeline:        vk.Pipeline,
  depth_reduce_pipeline:     vk.Pipeline,

  // Pipeline layouts
  early_cull_layout:         vk.PipelineLayout,
  late_cull_layout:          vk.PipelineLayout,
  depth_reduce_layout:       vk.PipelineLayout,

  // Descriptor set layouts
  early_descriptor_layout:   vk.DescriptorSetLayout,
  late_descriptor_layout:    vk.DescriptorSetLayout,
  depth_reduce_descriptor_layout: vk.DescriptorSetLayout,

  // Depth rendering pipeline
  depth_pipeline:            vk.Pipeline,
  depth_pipeline_layout:     vk.PipelineLayout,

  // Per-frame resources
  frames:                    [resources.MAX_FRAMES_IN_FLIGHT]VisibilityFrame,

  // System parameters
  max_draws:                 u32,
  node_count:                u32,
  depth_width:               u32,
  depth_height:              u32,
  depth_bias:                f32,

  // Statistics for debugging
  stats_enabled:             bool,
}

draw_command_stride :: proc() -> u32 {
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
  // Match depth buffer aspect ratio to camera (16:9) for projection consistency
  // 1024x576 gives ~1.78 aspect ratio matching typical camera setup
  system.depth_width = 1024
  system.depth_height = 576
  system.depth_bias = 0.0001 // Small depth bias to prevent self-occlusion and precision issues

  // Initialize per-frame resources
  for frame_idx in 0 ..< resources.MAX_FRAMES_IN_FLIGHT {
    frame := &system.frames[frame_idx]

    for task_idx in 0 ..< VISIBILITY_TASK_COUNT {
      task := &frame.tasks[task_idx]

      task.late_visibility = gpu.create_local_buffer(
        gpu_context,
        u32,
        int(system.max_draws),
        {.STORAGE_BUFFER, .TRANSFER_DST},
      ) or_return

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

      // Create depth resources
      create_depth_resources(gpu_context, task, system.depth_width, system.depth_height) or_return
    }
  }
  // Initialize all late_visibility buffers to zero
  {
    command_buffer := gpu.begin_single_time_command(gpu_context) or_return
    defer gpu.end_single_time_command(gpu_context, &command_buffer)

    for frame in system.frames {
      for task in frame.tasks {
        // Clear late_visibility to zero so Frame 0 early pass will start with empty set
        vk.CmdFillBuffer(
          command_buffer,
          task.late_visibility.buffer,
          0,
          vk.DeviceSize(task.late_visibility.bytes_count),
          0, // Fill with zeros
        )
      }
    }
  }

  // Create descriptor set layouts
  create_descriptor_layouts(system, gpu_context) or_return

  // Create compute pipelines
  create_compute_pipelines(system, gpu_context) or_return

  // Create depth rendering pipeline
  create_depth_pipeline(system, gpu_context, resources_manager) or_return

  // Allocate and update descriptor sets
  // For 2-pass culling with double buffering, each frame's early pass must read from
  // the OTHER frame's late visibility (the actual previous frame)
  for frame_idx in 0 ..< resources.MAX_FRAMES_IN_FLIGHT {
    prev_frame_idx := (frame_idx + resources.MAX_FRAMES_IN_FLIGHT - 1) % resources.MAX_FRAMES_IN_FLIGHT

    frame := &system.frames[frame_idx]
    prev_frame := &system.frames[prev_frame_idx]

    for task_idx in 0 ..< VISIBILITY_TASK_COUNT {
      task := &frame.tasks[task_idx]
      prev_task := &prev_frame.tasks[task_idx]

      allocate_descriptor_sets(system, gpu_context, resources_manager, task, prev_task) or_return
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

  device := gpu_context.device

  // Destroy pipelines
  vk.DestroyPipeline(device, system.early_cull_pipeline, nil)
  vk.DestroyPipeline(device, system.late_cull_pipeline, nil)
  vk.DestroyPipeline(device, system.depth_reduce_pipeline, nil)
  vk.DestroyPipeline(device, system.depth_pipeline, nil)

  // Destroy pipeline layouts
  vk.DestroyPipelineLayout(device, system.early_cull_layout, nil)
  vk.DestroyPipelineLayout(device, system.late_cull_layout, nil)
  vk.DestroyPipelineLayout(device, system.depth_reduce_layout, nil)
  // Note: depth_pipeline_layout is shared from resources_manager, don't destroy it

  // Destroy descriptor set layouts
  vk.DestroyDescriptorSetLayout(device, system.early_descriptor_layout, nil)
  vk.DestroyDescriptorSetLayout(device, system.late_descriptor_layout, nil)
  vk.DestroyDescriptorSetLayout(device, system.depth_reduce_descriptor_layout, nil)

  // Clean up per-frame resources
  for frame_idx in 0 ..< resources.MAX_FRAMES_IN_FLIGHT {
    frame := &system.frames[frame_idx]
    for task_idx in 0 ..< VISIBILITY_TASK_COUNT {
      task := &frame.tasks[task_idx]

      // Destroy depth resources
      vk.DestroyFramebuffer(device, task.depth_framebuffer, nil)
      vk.DestroyRenderPass(device, task.depth_render_pass, nil)

      // Destroy depth pyramid views and sampler
      for mip in 0 ..< task.depth_pyramid.mip_levels {
        vk.DestroyImageView(device, task.depth_pyramid.views[mip], nil)
      }
      vk.DestroyImageView(device, task.depth_pyramid.full_view, nil)
      vk.DestroySampler(device, task.depth_pyramid.sampler, nil)

      // Destroy buffers
      gpu.data_buffer_destroy(device, &task.late_visibility)
      gpu.data_buffer_destroy(device, &task.late_draw_count)
      gpu.data_buffer_destroy(device, &task.late_draw_commands)

      // Destroy images
      gpu.image_buffer_destroy(device, &task.depth_texture)
      gpu.image_buffer_destroy(device, &task.depth_pyramid.texture)
    }
  }
}

visibility_system_set_node_count :: proc(system: ^VisibilitySystem, count: u32) {
  system.node_count = min(count, system.max_draws)
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

  // Return late pass draw count (final visibility)
  if task_data.late_draw_count.mapped == nil {
    return 0
  }
  return task_data.late_draw_count.mapped[0]
}

// Read back culling statistics from GPU buffers
visibility_system_get_stats :: proc(
  system: ^VisibilitySystem,
  frame_index: u32,
  task: VisibilityCategory,
) -> CullingStats {
  stats := CullingStats {
    category = task,
    frame_index = frame_index,
  }

  if frame_index >= resources.MAX_FRAMES_IN_FLIGHT {
    return stats
  }

  frame := &system.frames[frame_index]
  task_data := &frame.tasks[int(task)]

  // Read late pass draw count
  if task_data.late_draw_count.mapped != nil {
    stats.late_draw_count = task_data.late_draw_count.mapped[0]
  }

  return stats
}

// Enable or disable statistics collection
visibility_system_set_stats_enabled :: proc(system: ^VisibilitySystem, enabled: bool) {
  system.stats_enabled = enabled
}

visibility_system_dispatch :: proc(
  system: ^VisibilitySystem,
  gpu_context: ^gpu.GPUContext,
  command_buffer: vk.CommandBuffer,
  frame_index: u32,
  task_category: VisibilityCategory,
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
  frame := &system.frames[frame_index]
  task := &frame.tasks[int(task_category)]
  // Barrier: Wait for depth rendering to finish before compute shader reads it
  depth_render_done := vk.ImageMemoryBarrier {
    sType = .IMAGE_MEMORY_BARRIER,
    srcAccessMask = {.DEPTH_STENCIL_ATTACHMENT_WRITE},
    dstAccessMask = {.SHADER_READ},
    oldLayout = .DEPTH_STENCIL_READ_ONLY_OPTIMAL,
    newLayout = .SHADER_READ_ONLY_OPTIMAL,
    srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
    dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
    image = task.depth_texture.image,
    subresourceRange = {
      aspectMask = {.DEPTH},
      baseMipLevel = 0,
      levelCount = 1,
      baseArrayLayer = 0,
      layerCount = 1,
    },
  }

  vk.CmdPipelineBarrier(
    command_buffer,
    {.LATE_FRAGMENT_TESTS},
    {.COMPUTE_SHADER},
    {},
    0,
    nil,
    0,
    nil,
    1,
    &depth_render_done,
  )

  // === STEP 3: BUILD DEPTH PYRAMID ===
  // This copies depth to pyramid mip 0, then generates all mip levels
  // (includes final barrier inside the function)
  build_depth_pyramid(
    system,
    gpu_context,
    command_buffer,
    task,
  )

  // Clear buffers
  vk.CmdFillBuffer(
    command_buffer,
    task.late_draw_count.buffer,
    0,
    vk.DeviceSize(task.late_draw_count.bytes_count),
    0,
  )
  // === STEP 4: LATE PASS COMPUTE ===
  // Full frustum + occlusion culling using depth pyramid
  execute_late_pass(
    system,
    gpu_context,
    command_buffer,
    frame_index,
    task,
    request,
    resources_manager,
  )

  // Barrier: Wait for late pass compute to finish before anyone reads the draw commands
  late_compute_done := [?]vk.BufferMemoryBarrier{
    {
      sType         = .BUFFER_MEMORY_BARRIER,
      srcAccessMask = {.SHADER_WRITE},
      dstAccessMask = {.INDIRECT_COMMAND_READ},
      buffer        = task.late_draw_commands.buffer,
      size          = vk.DeviceSize(task.late_draw_commands.bytes_count),
    },
    {
      sType         = .BUFFER_MEMORY_BARRIER,
      srcAccessMask = {.SHADER_WRITE},
      dstAccessMask = {.INDIRECT_COMMAND_READ},
      buffer        = task.late_draw_count.buffer,
      size          = vk.DeviceSize(task.late_draw_count.bytes_count),
    },
  }

  vk.CmdPipelineBarrier(
    command_buffer,
    {.COMPUTE_SHADER},
    {.DRAW_INDIRECT},
    {},
    0,
    nil,
    len(late_compute_done),
    raw_data(late_compute_done[:]),
    0,
    nil,
  )

  render_depth_pass(
    system,
    gpu_context,
    command_buffer,
    frame_index,
    task,
    resources_manager,
    request,
  )

  // Set result to late pass draw buffer (final visibility)
  result.draw_buffer = task.late_draw_commands.buffer
  result.count_buffer = task.late_draw_count.buffer

  // Log draw counts if statistics are enabled
  if system.stats_enabled {
    log_culling_stats(system, frame_index, task_category, task)
  }

  return result
}

@(private)
create_depth_resources :: proc(
  gpu_context: ^gpu.GPUContext,
  task: ^VisibilityTask,
  width: u32,
  height: u32,
) -> vk.Result {
  // Create depth texture for depth rendering
  depth_create_info := vk.ImageCreateInfo {
    sType = .IMAGE_CREATE_INFO,
    imageType = .D2,
    format = .D32_SFLOAT,
    extent = {width, height, 1},
    mipLevels = 1,
    arrayLayers = 1,
    samples = {._1},
    tiling = .OPTIMAL,
    usage = {.DEPTH_STENCIL_ATTACHMENT, .SAMPLED},
    sharingMode = .EXCLUSIVE,
    initialLayout = .UNDEFINED,
  }

  // Create depth texture using GPU helper function
  task.depth_texture = gpu.malloc_image_buffer(
    gpu_context,
    width,
    height,
    .D32_SFLOAT,
    .OPTIMAL,
    {.DEPTH_STENCIL_ATTACHMENT, .SAMPLED},
    {.DEVICE_LOCAL},
  ) or_return

  // Create image view for depth texture
  task.depth_texture.view = gpu.create_image_view(
    gpu_context.device,
    task.depth_texture.image,
    .D32_SFLOAT,
    {.DEPTH},
  ) or_return

  // Depth pyramid dimensions: mip 0 is HALF the resolution of source depth texture
  // because we perform 2x2 MAX reduction to generate mip 0
  pyramid_width := max(1, width / 2)
  pyramid_height := max(1, height / 2)

  // Calculate mip levels for depth pyramid based on pyramid base size
  mip_levels := u32(math.floor(math.log2(f32(max(pyramid_width, pyramid_height))))) + 1

  // Create depth pyramid texture with mip levels
  task.depth_pyramid.texture = gpu.malloc_image_buffer_with_mips(
    gpu_context,
    pyramid_width,
    pyramid_height,
    .R32_SFLOAT, // Store depth as float for compute shader access
    .OPTIMAL,
    {.SAMPLED, .STORAGE, .TRANSFER_DST},
    {.DEVICE_LOCAL},
    mip_levels,
  ) or_return
  task.depth_pyramid.mip_levels = mip_levels
  task.depth_pyramid.width = pyramid_width
  task.depth_pyramid.height = pyramid_height

  // Create per-mip views for depth reduction shader (write to individual mips)
  for mip in 0 ..< mip_levels {
    view_info := vk.ImageViewCreateInfo {
      sType = .IMAGE_VIEW_CREATE_INFO,
      image = task.depth_pyramid.texture.image,
      viewType = .D2,
      format = .R32_SFLOAT,
      subresourceRange = {
        aspectMask = {.COLOR},
        baseMipLevel = mip,
        levelCount = 1,
        baseArrayLayer = 0,
        layerCount = 1,
      },
    }

    vk.CreateImageView(
      gpu_context.device,
      &view_info,
      nil,
      &task.depth_pyramid.views[mip],
    ) or_return
  }

  // Create full pyramid view for culling shader (sample from all mips)
  full_view_info := vk.ImageViewCreateInfo {
    sType = .IMAGE_VIEW_CREATE_INFO,
    image = task.depth_pyramid.texture.image,
    viewType = .D2,
    format = .R32_SFLOAT,
    subresourceRange = {
      aspectMask = {.COLOR},
      baseMipLevel = 0,
      levelCount = mip_levels, // ALL mip levels accessible
      baseArrayLayer = 0,
      layerCount = 1,
    },
  }

  vk.CreateImageView(
    gpu_context.device,
    &full_view_info,
    nil,
    &task.depth_pyramid.full_view,
  ) or_return

  // Create sampler for depth pyramid with MAX reduction for forward-Z
  // LINEAR filter with MAX reduction - hardware automatically samples 2x2 and returns maximum
  sampler_info := vk.SamplerCreateInfo {
    sType = .SAMPLER_CREATE_INFO,
    magFilter = .LINEAR,
    minFilter = .LINEAR,
    mipmapMode = .NEAREST,
    addressModeU = .CLAMP_TO_EDGE,
    addressModeV = .CLAMP_TO_EDGE,
    addressModeW = .CLAMP_TO_EDGE,
    minLod = 0,
    maxLod = f32(mip_levels),
    borderColor = .FLOAT_OPAQUE_WHITE,
  }

  // Enable MAX reduction mode (Vulkan 1.2+ feature)
  // For forward-Z, MAX gives us the farthest occluder (larger depth = farther)
  reduction_mode := vk.SamplerReductionModeCreateInfo {
    sType = .SAMPLER_REDUCTION_MODE_CREATE_INFO,
    reductionMode = .MAX,
  }
  sampler_info.pNext = &reduction_mode

  vk.CreateSampler(
    gpu_context.device,
    &sampler_info,
    nil,
    &task.depth_pyramid.sampler,
  ) or_return

  // Create render pass for depth rendering
  attachment := vk.AttachmentDescription {
    format = .D32_SFLOAT,
    samples = {._1},
    loadOp = .CLEAR,
    storeOp = .STORE,
    stencilLoadOp = .DONT_CARE,
    stencilStoreOp = .DONT_CARE,
    initialLayout = .UNDEFINED,
    finalLayout = .DEPTH_STENCIL_READ_ONLY_OPTIMAL,
  }

  attachment_ref := vk.AttachmentReference {
    attachment = 0,
    layout = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
  }

  subpass := vk.SubpassDescription {
    pipelineBindPoint = .GRAPHICS,
    pDepthStencilAttachment = &attachment_ref,
  }

  dependency := vk.SubpassDependency {
    srcSubpass = vk.SUBPASS_EXTERNAL,
    dstSubpass = 0,
    srcStageMask = {.COMPUTE_SHADER},
    dstStageMask = {.EARLY_FRAGMENT_TESTS},
    srcAccessMask = {.SHADER_WRITE},
    dstAccessMask = {.DEPTH_STENCIL_ATTACHMENT_WRITE},
  }

  render_pass_info := vk.RenderPassCreateInfo {
    sType = .RENDER_PASS_CREATE_INFO,
    attachmentCount = 1,
    pAttachments = &attachment,
    subpassCount = 1,
    pSubpasses = &subpass,
    dependencyCount = 1,
    pDependencies = &dependency,
  }

  vk.CreateRenderPass(
    gpu_context.device,
    &render_pass_info,
    nil,
    &task.depth_render_pass,
  ) or_return

  // Create framebuffer
  framebuffer_info := vk.FramebufferCreateInfo {
    sType = .FRAMEBUFFER_CREATE_INFO,
    renderPass = task.depth_render_pass,
    attachmentCount = 1,
    pAttachments = &task.depth_texture.view,
    width = width,
    height = height,
    layers = 1,
  }

  vk.CreateFramebuffer(
    gpu_context.device,
    &framebuffer_info,
    nil,
    &task.depth_framebuffer,
  ) or_return

  return vk.Result.SUCCESS
}

@(private)
create_descriptor_layouts :: proc(
  system: ^VisibilitySystem,
  gpu_context: ^gpu.GPUContext,
) -> vk.Result {
  // Early pass descriptor layout
  early_bindings := [?]vk.DescriptorSetLayoutBinding {
    {binding = 0, descriptorType = .STORAGE_BUFFER, descriptorCount = 1, stageFlags = {.COMPUTE}}, // Node data
    {binding = 1, descriptorType = .STORAGE_BUFFER, descriptorCount = 1, stageFlags = {.COMPUTE}}, // Mesh data
    {binding = 2, descriptorType = .STORAGE_BUFFER, descriptorCount = 1, stageFlags = {.COMPUTE}}, // World matrices
    {binding = 3, descriptorType = .STORAGE_BUFFER, descriptorCount = 1, stageFlags = {.COMPUTE}}, // Camera data
    {binding = 4, descriptorType = .STORAGE_BUFFER, descriptorCount = 1, stageFlags = {.COMPUTE}}, // Previous visibility
    {binding = 5, descriptorType = .STORAGE_BUFFER, descriptorCount = 1, stageFlags = {.COMPUTE}}, // Draw count
    {binding = 6, descriptorType = .STORAGE_BUFFER, descriptorCount = 1, stageFlags = {.COMPUTE}}, // Draw commands
  }

  vk.CreateDescriptorSetLayout(
    gpu_context.device,
    &vk.DescriptorSetLayoutCreateInfo {
      sType = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
      bindingCount = len(early_bindings),
      pBindings = raw_data(early_bindings[:]),
    },
    nil,
    &system.early_descriptor_layout,
  ) or_return

  // Late pass descriptor layout (includes depth pyramid)
  late_bindings := [?]vk.DescriptorSetLayoutBinding {
    {binding = 0, descriptorType = .STORAGE_BUFFER, descriptorCount = 1, stageFlags = {.COMPUTE}}, // Node data
    {binding = 1, descriptorType = .STORAGE_BUFFER, descriptorCount = 1, stageFlags = {.COMPUTE}}, // Mesh data
    {binding = 2, descriptorType = .STORAGE_BUFFER, descriptorCount = 1, stageFlags = {.COMPUTE}}, // World matrices
    {binding = 3, descriptorType = .STORAGE_BUFFER, descriptorCount = 1, stageFlags = {.COMPUTE}}, // Camera data
    {binding = 4, descriptorType = .STORAGE_BUFFER, descriptorCount = 1, stageFlags = {.COMPUTE}}, // Current visibility
    {binding = 5, descriptorType = .STORAGE_BUFFER, descriptorCount = 1, stageFlags = {.COMPUTE}}, // Draw count
    {binding = 6, descriptorType = .STORAGE_BUFFER, descriptorCount = 1, stageFlags = {.COMPUTE}}, // Draw commands
    {binding = 7, descriptorType = .COMBINED_IMAGE_SAMPLER, descriptorCount = 1, stageFlags = {.COMPUTE}}, // Depth pyramid
  }

  vk.CreateDescriptorSetLayout(
    gpu_context.device,
    &vk.DescriptorSetLayoutCreateInfo {
      sType = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
      bindingCount = len(late_bindings),
      pBindings = raw_data(late_bindings[:]),
    },
    nil,
    &system.late_descriptor_layout,
  ) or_return

  // Depth pyramid reduction descriptor layout
  depth_bindings := [?]vk.DescriptorSetLayoutBinding {
    {binding = 0, descriptorType = .COMBINED_IMAGE_SAMPLER, descriptorCount = 1, stageFlags = {.COMPUTE}}, // Source mip
    {binding = 1, descriptorType = .STORAGE_IMAGE, descriptorCount = 1, stageFlags = {.COMPUTE}}, // Dest mip
  }

  vk.CreateDescriptorSetLayout(
    gpu_context.device,
    &vk.DescriptorSetLayoutCreateInfo {
      sType = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
      bindingCount = len(depth_bindings),
      pBindings = raw_data(depth_bindings[:]),
    },
    nil,
    &system.depth_reduce_descriptor_layout,
  ) or_return

  return vk.Result.SUCCESS
}

@(private)
create_compute_pipelines :: proc(
  system: ^VisibilitySystem,
  gpu_context: ^gpu.GPUContext,
) -> vk.Result {
  // Create pipeline layouts with push constants
  push_constant_range := vk.PushConstantRange {
    stageFlags = {.COMPUTE},
    size = size_of(VisibilityPushConstants),
  }

  vk.CreatePipelineLayout(
    gpu_context.device,
    &vk.PipelineLayoutCreateInfo {
      sType = .PIPELINE_LAYOUT_CREATE_INFO,
      setLayoutCount = 1,
      pSetLayouts = &system.early_descriptor_layout,
      pushConstantRangeCount = 1,
      pPushConstantRanges = &push_constant_range,
    },
    nil,
    &system.early_cull_layout,
  ) or_return

  vk.CreatePipelineLayout(
    gpu_context.device,
    &vk.PipelineLayoutCreateInfo {
      sType = .PIPELINE_LAYOUT_CREATE_INFO,
      setLayoutCount = 1,
      pSetLayouts = &system.late_descriptor_layout,
      pushConstantRangeCount = 1,
      pPushConstantRanges = &push_constant_range,
    },
    nil,
    &system.late_cull_layout,
  ) or_return

  depth_push_range := vk.PushConstantRange {
    stageFlags = {.COMPUTE},
    size = size_of(DepthReducePushConstants),
  }

  vk.CreatePipelineLayout(
    gpu_context.device,
    &vk.PipelineLayoutCreateInfo {
      sType = .PIPELINE_LAYOUT_CREATE_INFO,
      setLayoutCount = 1,
      pSetLayouts = &system.depth_reduce_descriptor_layout,
      pushConstantRangeCount = 1,
      pPushConstantRanges = &depth_push_range,
    },
    nil,
    &system.depth_reduce_layout,
  ) or_return

  // Load and create compute shaders
  early_shader := gpu.create_shader_module(
    gpu_context.device,
    #load("../shader/occlusion_culling/early_cull.spv"),
  ) or_return
  defer vk.DestroyShaderModule(gpu_context.device, early_shader, nil)

  late_shader := gpu.create_shader_module(
    gpu_context.device,
    #load("../shader/occlusion_culling/late_cull.spv"),
  ) or_return
  defer vk.DestroyShaderModule(gpu_context.device, late_shader, nil)

  depth_shader := gpu.create_shader_module(
    gpu_context.device,
    #load("../shader/occlusion_culling/depth_reduce.spv"),
  ) or_return
  defer vk.DestroyShaderModule(gpu_context.device, depth_shader, nil)

  // Create compute pipelines
  early_info := vk.ComputePipelineCreateInfo {
    sType = .COMPUTE_PIPELINE_CREATE_INFO,
    stage = {
      sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
      stage = {.COMPUTE},
      module = early_shader,
      pName = "main",
    },
    layout = system.early_cull_layout,
  }

  vk.CreateComputePipelines(
    gpu_context.device,
    0,
    1,
    &early_info,
    nil,
    &system.early_cull_pipeline,
  ) or_return

  late_info := vk.ComputePipelineCreateInfo {
    sType = .COMPUTE_PIPELINE_CREATE_INFO,
    stage = {
      sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
      stage = {.COMPUTE},
      module = late_shader,
      pName = "main",
    },
    layout = system.late_cull_layout,
  }

  vk.CreateComputePipelines(
    gpu_context.device,
    0,
    1,
    &late_info,
    nil,
    &system.late_cull_pipeline,
  ) or_return

  depth_info := vk.ComputePipelineCreateInfo {
    sType = .COMPUTE_PIPELINE_CREATE_INFO,
    stage = {
      sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
      stage = {.COMPUTE},
      module = depth_shader,
      pName = "main",
    },
    layout = system.depth_reduce_layout,
  }

  vk.CreateComputePipelines(
    gpu_context.device,
    0,
    1,
    &depth_info,
    nil,
    &system.depth_reduce_pipeline,
  ) or_return

  return vk.Result.SUCCESS
}

@(private)
create_depth_pipeline :: proc(
  system: ^VisibilitySystem,
  gpu_context: ^gpu.GPUContext,
  resources_manager: ^resources.Manager,
) -> vk.Result {
  // Create depth-only rendering pipeline for early/late pass depth rendering

  // Load shaders
  vert_shader := gpu.create_shader_module(
    gpu_context.device,
    #load("../shader/occlusion_culling/vert.spv"),
  ) or_return
  defer vk.DestroyShaderModule(gpu_context.device, vert_shader, nil)

  // Shader stages
  shader_stages := [?]vk.PipelineShaderStageCreateInfo {
    {
      sType  = .PIPELINE_SHADER_STAGE_CREATE_INFO,
      stage  = {.VERTEX},
      module = vert_shader,
      pName  = "main",
    },
  }

  // Vertex input: only position from Vertex struct
  vertex_bindings := [?]vk.VertexInputBindingDescription {
    {binding = 0, stride = size_of(geometry.Vertex), inputRate = .VERTEX},
  }

  vertex_attributes := [?]vk.VertexInputAttributeDescription {
    {location = 0, binding = 0, format = .R32G32B32_SFLOAT, offset = u32(offset_of(geometry.Vertex, position))},
  }

  vertex_input_info := vk.PipelineVertexInputStateCreateInfo {
    sType                           = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
    vertexBindingDescriptionCount   = len(vertex_bindings),
    pVertexBindingDescriptions      = raw_data(vertex_bindings[:]),
    vertexAttributeDescriptionCount = len(vertex_attributes),
    pVertexAttributeDescriptions    = raw_data(vertex_attributes[:]),
  }

  // Input assembly
  input_assembly := vk.PipelineInputAssemblyStateCreateInfo {
    sType                  = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
    topology               = .TRIANGLE_LIST,
    primitiveRestartEnable = false,
  }

  // Viewport and scissor (dynamic state)
  viewport_state := vk.PipelineViewportStateCreateInfo {
    sType         = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
    viewportCount = 1,
    scissorCount  = 1,
  }

  // Rasterization
  // Note: Using CLOCKWISE because viewport Y is flipped (negative height)
  // When Y is flipped, CCW triangles become CW on screen
  rasterizer := vk.PipelineRasterizationStateCreateInfo {
    sType                   = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
    depthClampEnable        = false,
    rasterizerDiscardEnable = false,
    polygonMode             = .FILL,
    cullMode                = {.BACK},
    frontFace               = .COUNTER_CLOCKWISE,
    depthBiasEnable         = false,
    lineWidth               = 1.0,
  }

  // Multisampling (disabled)
  multisampling := vk.PipelineMultisampleStateCreateInfo {
    sType                = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
    rasterizationSamples = {._1},
    sampleShadingEnable  = false,
  }

  // Depth stencil (depth write enabled, test LESS for forward-Z)
  depth_stencil := vk.PipelineDepthStencilStateCreateInfo {
    sType                 = .PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
    depthTestEnable       = true,
    depthWriteEnable      = true,
    depthCompareOp        = .LESS,
    depthBoundsTestEnable = false,
    stencilTestEnable     = false,
  }

  // No color attachments for depth-only pass
  color_blend := vk.PipelineColorBlendStateCreateInfo {
    sType           = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
    logicOpEnable   = false,
    attachmentCount = 0,
    pAttachments    = nil,
  }

  // Dynamic states
  dynamic_states := [?]vk.DynamicState{.VIEWPORT, .SCISSOR}
  dynamic_state := vk.PipelineDynamicStateCreateInfo {
    sType             = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
    dynamicStateCount = len(dynamic_states),
    pDynamicStates    = raw_data(dynamic_states[:]),
  }

  // Use the shared geometry pipeline layout from resources manager
  system.depth_pipeline_layout = resources_manager.geometry_pipeline_layout
  if system.depth_pipeline_layout == 0 {
    return .ERROR_INITIALIZATION_FAILED
  }

  // Create graphics pipeline (using first task's render pass as reference)
  pipeline_info := vk.GraphicsPipelineCreateInfo {
    sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
    stageCount          = len(shader_stages),
    pStages             = raw_data(shader_stages[:]),
    pVertexInputState   = &vertex_input_info,
    pInputAssemblyState = &input_assembly,
    pViewportState      = &viewport_state,
    pRasterizationState = &rasterizer,
    pMultisampleState   = &multisampling,
    pDepthStencilState  = &depth_stencil,
    pColorBlendState    = &color_blend,
    pDynamicState       = &dynamic_state,
    layout              = system.depth_pipeline_layout,
    renderPass          = system.frames[0].tasks[0].depth_render_pass,
    subpass             = 0,
  }

  vk.CreateGraphicsPipelines(
    gpu_context.device,
    0,
    1,
    &pipeline_info,
    nil,
    &system.depth_pipeline,
  ) or_return

  return vk.Result.SUCCESS
}

@(private)
allocate_descriptor_sets :: proc(
  system: ^VisibilitySystem,
  gpu_context: ^gpu.GPUContext,
  resources_manager: ^resources.Manager,
  task: ^VisibilityTask,
  prev_task: ^VisibilityTask, // Previous frame's task for cross-frame visibility
) -> vk.Result {
  vk.AllocateDescriptorSets(
    gpu_context.device,
    &vk.DescriptorSetAllocateInfo {
      sType = .DESCRIPTOR_SET_ALLOCATE_INFO,
      descriptorPool = gpu_context.descriptor_pool,
      descriptorSetCount = 1,
      pSetLayouts = &system.late_descriptor_layout,
    },
    &task.late_descriptor_set,
  ) or_return

  // Allocate descriptor sets for depth pyramid reduction (one per mip level, INCLUDING mip 0)
  for mip in 0 ..< task.depth_pyramid.mip_levels {
    vk.AllocateDescriptorSets(
      gpu_context.device,
      &vk.DescriptorSetAllocateInfo {
        sType = .DESCRIPTOR_SET_ALLOCATE_INFO,
        descriptorPool = gpu_context.descriptor_pool,
        descriptorSetCount = 1,
        pSetLayouts = &system.depth_reduce_descriptor_layout,
      },
      &task.depth_reduce_descriptor_sets[mip],
    ) or_return
  }

  // Update late pass descriptor set
  update_late_descriptor_set(gpu_context, resources_manager, task)

  // Update depth reduction descriptor sets (ALL mips, including mip 0)
  for mip in 0 ..< task.depth_pyramid.mip_levels {
    update_depth_reduce_descriptor_set(gpu_context, task, u32(mip))
  }

  return vk.Result.SUCCESS
}

@(private)
update_late_descriptor_set :: proc(
  gpu_context: ^gpu.GPUContext,
  resources_manager: ^resources.Manager,
  task: ^VisibilityTask,
) {
  node_info := vk.DescriptorBufferInfo {
    buffer = resources_manager.node_data_buffer.device_buffer,
    range = vk.DeviceSize(resources_manager.node_data_buffer.bytes_count),
  }
  mesh_info := vk.DescriptorBufferInfo {
    buffer = resources_manager.mesh_data_buffer.device_buffer,
    range = vk.DeviceSize(resources_manager.mesh_data_buffer.bytes_count),
  }
  world_info := vk.DescriptorBufferInfo {
    buffer = resources_manager.world_matrix_buffer.device_buffer,
    range = vk.DeviceSize(resources_manager.world_matrix_buffer.bytes_count),
  }
  camera_info := vk.DescriptorBufferInfo {
    buffer = resources_manager.camera_buffer.buffer,
    range = vk.DeviceSize(resources_manager.camera_buffer.bytes_count),
  }
  vis_info := vk.DescriptorBufferInfo {
    buffer = task.late_visibility.buffer,
    range = vk.DeviceSize(task.late_visibility.bytes_count),
  }
  count_info := vk.DescriptorBufferInfo {
    buffer = task.late_draw_count.buffer,
    range = vk.DeviceSize(task.late_draw_count.bytes_count),
  }
  command_info := vk.DescriptorBufferInfo {
    buffer = task.late_draw_commands.buffer,
    range = vk.DeviceSize(task.late_draw_commands.bytes_count),
  }
  pyramid_info := vk.DescriptorImageInfo {
    sampler = task.depth_pyramid.sampler,
    imageView = task.depth_pyramid.full_view, // Full pyramid with all mips
    imageLayout = .SHADER_READ_ONLY_OPTIMAL,
  }

  writes := [?]vk.WriteDescriptorSet {
    {sType = .WRITE_DESCRIPTOR_SET, dstSet = task.late_descriptor_set, dstBinding = 0, descriptorType = .STORAGE_BUFFER, descriptorCount = 1, pBufferInfo = &node_info},
    {sType = .WRITE_DESCRIPTOR_SET, dstSet = task.late_descriptor_set, dstBinding = 1, descriptorType = .STORAGE_BUFFER, descriptorCount = 1, pBufferInfo = &mesh_info},
    {sType = .WRITE_DESCRIPTOR_SET, dstSet = task.late_descriptor_set, dstBinding = 2, descriptorType = .STORAGE_BUFFER, descriptorCount = 1, pBufferInfo = &world_info},
    {sType = .WRITE_DESCRIPTOR_SET, dstSet = task.late_descriptor_set, dstBinding = 3, descriptorType = .STORAGE_BUFFER, descriptorCount = 1, pBufferInfo = &camera_info},
    {sType = .WRITE_DESCRIPTOR_SET, dstSet = task.late_descriptor_set, dstBinding = 4, descriptorType = .STORAGE_BUFFER, descriptorCount = 1, pBufferInfo = &vis_info},
    {sType = .WRITE_DESCRIPTOR_SET, dstSet = task.late_descriptor_set, dstBinding = 5, descriptorType = .STORAGE_BUFFER, descriptorCount = 1, pBufferInfo = &count_info},
    {sType = .WRITE_DESCRIPTOR_SET, dstSet = task.late_descriptor_set, dstBinding = 6, descriptorType = .STORAGE_BUFFER, descriptorCount = 1, pBufferInfo = &command_info},
    {sType = .WRITE_DESCRIPTOR_SET, dstSet = task.late_descriptor_set, dstBinding = 7, descriptorType = .COMBINED_IMAGE_SAMPLER, descriptorCount = 1, pImageInfo = &pyramid_info},
  }

  vk.UpdateDescriptorSets(gpu_context.device, len(writes), raw_data(writes[:]), 0, nil)
}

@(private)
update_depth_reduce_descriptor_set :: proc(
  gpu_context: ^gpu.GPUContext,
  task: ^VisibilityTask,
  mip: u32,
) {
  // For mip 0: read from depth texture, write to pyramid mip 0
  // For other mips: read from previous pyramid mip, write to current mip
  source_view := mip == 0 ? task.depth_texture.view : task.depth_pyramid.views[mip - 1]

  source_info := vk.DescriptorImageInfo {
    sampler = task.depth_pyramid.sampler,
    imageView = source_view,
    imageLayout = .SHADER_READ_ONLY_OPTIMAL,
  }
  dest_info := vk.DescriptorImageInfo {
    imageView = task.depth_pyramid.views[mip],
    imageLayout = .GENERAL,
  }

  writes := [?]vk.WriteDescriptorSet {
    {sType = .WRITE_DESCRIPTOR_SET, dstSet = task.depth_reduce_descriptor_sets[mip], dstBinding = 0, descriptorType = .COMBINED_IMAGE_SAMPLER, descriptorCount = 1, pImageInfo = &source_info},
    {sType = .WRITE_DESCRIPTOR_SET, dstSet = task.depth_reduce_descriptor_sets[mip], dstBinding = 1, descriptorType = .STORAGE_IMAGE, descriptorCount = 1, pImageInfo = &dest_info},
  }

  vk.UpdateDescriptorSets(gpu_context.device, len(writes), raw_data(writes[:]), 0, nil)
}

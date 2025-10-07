package occlusion

import "../../geometry"
import "../../gpu"
import "../../resources"
import "../targets"
import "core:log"
import "core:math"
import vk "vendor:vulkan"

// Occlusion culling using depth pyramid technique
// Based on: https://github.com/zeux/niagara and depth pyramid paper

OcclusionSystem :: struct {
  // Depth pyramid
  pyramid_image:       gpu.ImageBuffer,
  pyramid_mip_views:   [16]vk.ImageView,
  pyramid_levels:      u32,
  pyramid_width:       u32,
  pyramid_height:      u32,
  pyramid_sampler:     vk.Sampler,

  // Visibility tracking (uint per node for descriptor compatibility)
  visibility_prev:     gpu.DataBuffer(u32), // Previous frame visibility
  visibility_curr:     gpu.DataBuffer(u32), // Current frame visibility

  // Node bounding spheres (xyz=center in world space, w=radius)
  node_bounds:         gpu.DataBuffer([4]f32),

  // Compute shaders
  depth_reduce_pipeline:        vk.Pipeline,
  depth_reduce_pipeline_layout: vk.PipelineLayout,
  depth_reduce_descriptor_pool: vk.DescriptorPool,
  depth_reduce_descriptor_sets: [16]vk.DescriptorSet, // One per mip level

  // Occlusion culling pipeline
  occlusion_cull_pipeline:        vk.Pipeline,
  occlusion_cull_pipeline_layout: vk.PipelineLayout,
  occlusion_cull_descriptor_pool: vk.DescriptorPool,
  occlusion_cull_descriptor_set:  vk.DescriptorSet,

  // Debug visualization
  debug_pipeline:              vk.Pipeline,
  debug_pipeline_layout:       vk.PipelineLayout,
  debug_descriptor_pool:       vk.DescriptorPool,
  debug_descriptor_set:        vk.DescriptorSet,
  debug_mip_level:             u32,

  // State
  enabled:             bool,
  max_nodes:           u32,
}

DepthReducePushConstants :: struct {
  image_size: [2]f32,
}

DebugPushConstants :: struct {
  mip_level:     u32,
  screen_width:  u32,
  screen_height: u32,
  debug_scale:   f32,
}

OcclusionCullPushConstants :: struct {
  view:            matrix[4, 4]f32,
  P00:             f32,
  P11:             f32,
  znear:           f32,
  zfar:            f32,
  pyramid_width:   f32,
  pyramid_height:  f32,
  node_count:      u32,
  occlusion_enabled: u32,
}

// Get next power of 2 that's <= value
previous_pow2 :: proc(value: u32) -> u32 {
  if value == 0 do return 0
  result := u32(1)
  for result * 2 <= value {
    result *= 2
  }
  return result
}

// Calculate number of mip levels for a texture
get_mip_levels :: proc(width, height: u32) -> u32 {
  max_dim := max(width, height)
  if max_dim == 0 do return 1
  levels := u32(1)
  dim := max_dim
  for dim > 1 {
    dim /= 2
    levels += 1
  }
  return levels
}

init :: proc(
  system: ^OcclusionSystem,
  gpu_context: ^gpu.GPUContext,
  resources_manager: ^resources.Manager,
  width, height: u32,
) -> vk.Result {
  system.max_nodes = resources.MAX_NODES_IN_SCENE
  system.enabled = false

  // Create visibility buffers
  system.visibility_prev = gpu.create_host_visible_buffer(
    gpu_context,
    u32,
    int(system.max_nodes),
    {.STORAGE_BUFFER, .TRANSFER_DST},
  ) or_return

  system.visibility_curr = gpu.create_host_visible_buffer(
    gpu_context,
    u32,
    int(system.max_nodes),
    {.STORAGE_BUFFER, .TRANSFER_DST},
  ) or_return

  // Initialize visibility to 0 (all occluded)
  for i in 0 ..< int(system.max_nodes) {
    gpu.data_buffer_get(&system.visibility_prev, u32(i))^ = 0
    gpu.data_buffer_get(&system.visibility_curr, u32(i))^ = 0
  }

  // Create node bounds buffer
  system.node_bounds = gpu.create_host_visible_buffer(
    gpu_context,
    [4]f32,
    int(system.max_nodes),
    {.STORAGE_BUFFER},
  ) or_return

  // Initialize bounds to zero
  for i in 0 ..< int(system.max_nodes) {
    gpu.data_buffer_get(&system.node_bounds, u32(i))^ = [4]f32{0, 0, 0, 1}
  }

  // Create depth pyramid resources
  recreate_pyramid(system, gpu_context, width, height) or_return

  // Create sampler with MIN reduction mode
  sampler_reduction_info := vk.SamplerReductionModeCreateInfo {
    sType         = .SAMPLER_REDUCTION_MODE_CREATE_INFO,
    reductionMode = .MIN,
  }

  sampler_info := vk.SamplerCreateInfo {
    sType                   = .SAMPLER_CREATE_INFO,
    pNext                   = &sampler_reduction_info,
    magFilter               = .LINEAR,
    minFilter               = .LINEAR,
    mipmapMode              = .NEAREST,
    addressModeU            = .CLAMP_TO_EDGE,
    addressModeV            = .CLAMP_TO_EDGE,
    addressModeW            = .CLAMP_TO_EDGE,
    mipLodBias              = 0.0,
    anisotropyEnable        = false,
    compareEnable           = false,
    minLod                  = 0.0,
    maxLod                  = f32(system.pyramid_levels),
    unnormalizedCoordinates = false,
  }

  vk.CreateSampler(
    gpu_context.device,
    &sampler_info,
    nil,
    &system.pyramid_sampler,
  ) or_return

  // Create depth reduce compute pipeline
  create_depth_reduce_pipeline(system, gpu_context) or_return

  // Create debug visualization pipeline
  create_debug_pipeline(system, gpu_context) or_return

  // Create occlusion culling pipeline
  create_occlusion_cull_pipeline(system, gpu_context, resources_manager) or_return

  system.debug_mip_level = 3

  log.info("Occlusion culling system initialized")
  return .SUCCESS
}

recreate_pyramid :: proc(
  system: ^OcclusionSystem,
  gpu_context: ^gpu.GPUContext,
  width, height: u32,
) -> vk.Result {
  // Destroy old pyramid if exists
  if system.pyramid_image.image != 0 {
    for i in 0 ..< system.pyramid_levels {
      if system.pyramid_mip_views[i] != 0 {
        vk.DestroyImageView(gpu_context.device, system.pyramid_mip_views[i], nil)
        system.pyramid_mip_views[i] = 0
      }
    }
    gpu.image_buffer_destroy(gpu_context.device, &system.pyramid_image)
  }

  // Use power-of-2 dimensions for conservative reduction
  system.pyramid_width = previous_pow2(width)
  system.pyramid_height = previous_pow2(height)
  system.pyramid_levels = get_mip_levels(system.pyramid_width, system.pyramid_height)

  log.infof(
    "Creating depth pyramid: %dx%d with %d levels",
    system.pyramid_width,
    system.pyramid_height,
    system.pyramid_levels,
  )

  // Create pyramid image
  image_info := vk.ImageCreateInfo {
    sType         = .IMAGE_CREATE_INFO,
    imageType     = .D2,
    format        = .R32_SFLOAT,
    extent        = {system.pyramid_width, system.pyramid_height, 1},
    mipLevels     = system.pyramid_levels,
    arrayLayers   = 1,
    samples       = {._1},
    tiling        = .OPTIMAL,
    usage         = {.SAMPLED, .STORAGE, .TRANSFER_SRC},
    sharingMode   = .EXCLUSIVE,
    initialLayout = .UNDEFINED,
  }

  vk.CreateImage(
    gpu_context.device,
    &image_info,
    nil,
    &system.pyramid_image.image,
  ) or_return

  // Allocate memory
  mem_requirements: vk.MemoryRequirements
  vk.GetImageMemoryRequirements(
    gpu_context.device,
    system.pyramid_image.image,
    &mem_requirements,
  )

  system.pyramid_image.memory = gpu.allocate_vulkan_memory(
    gpu_context,
    mem_requirements,
    {.DEVICE_LOCAL},
  ) or_return

  vk.BindImageMemory(
    gpu_context.device,
    system.pyramid_image.image,
    system.pyramid_image.memory,
    0,
  ) or_return

  // Create main view (all mips)
  view_info := vk.ImageViewCreateInfo {
    sType    = .IMAGE_VIEW_CREATE_INFO,
    image    = system.pyramid_image.image,
    viewType = .D2,
    format   = .R32_SFLOAT,
    subresourceRange = {
      aspectMask     = {.COLOR},
      baseMipLevel   = 0,
      levelCount     = system.pyramid_levels,
      baseArrayLayer = 0,
      layerCount     = 1,
    },
  }

  vk.CreateImageView(
    gpu_context.device,
    &view_info,
    nil,
    &system.pyramid_image.view,
  ) or_return

  // Create per-mip views for compute shader writes
  for i in 0 ..< system.pyramid_levels {
    mip_view_info := vk.ImageViewCreateInfo {
      sType    = .IMAGE_VIEW_CREATE_INFO,
      image    = system.pyramid_image.image,
      viewType = .D2,
      format   = .R32_SFLOAT,
      subresourceRange = {
        aspectMask     = {.COLOR},
        baseMipLevel   = i,
        levelCount     = 1,
        baseArrayLayer = 0,
        layerCount     = 1,
      },
    }

    vk.CreateImageView(
      gpu_context.device,
      &mip_view_info,
      nil,
      &system.pyramid_mip_views[i],
    ) or_return
  }

  return .SUCCESS
}

SHADER_DEPTH_REDUCE_COMP :: #load("../../shader/depth_reduce/compute.spv")

create_depth_reduce_pipeline :: proc(
  system: ^OcclusionSystem,
  gpu_context: ^gpu.GPUContext,
) -> vk.Result {
  // Descriptor set layout: binding 0 = output image, binding 1 = input sampler
  bindings := [?]vk.DescriptorSetLayoutBinding {
    {
      binding         = 0,
      descriptorType  = .STORAGE_IMAGE,
      descriptorCount = 1,
      stageFlags      = {.COMPUTE},
    },
    {
      binding         = 1,
      descriptorType  = .COMBINED_IMAGE_SAMPLER,
      descriptorCount = 1,
      stageFlags      = {.COMPUTE},
    },
  }

  layout_info := vk.DescriptorSetLayoutCreateInfo {
    sType        = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
    bindingCount = len(bindings),
    pBindings    = raw_data(bindings[:]),
  }

  descriptor_layout: vk.DescriptorSetLayout
  vk.CreateDescriptorSetLayout(
    gpu_context.device,
    &layout_info,
    nil,
    &descriptor_layout,
  ) or_return

  // Pipeline layout with push constants
  push_constant_range := vk.PushConstantRange {
    stageFlags = {.COMPUTE},
    offset     = 0,
    size       = size_of(DepthReducePushConstants),
  }

  pipeline_layout_info := vk.PipelineLayoutCreateInfo {
    sType                  = .PIPELINE_LAYOUT_CREATE_INFO,
    setLayoutCount         = 1,
    pSetLayouts            = &descriptor_layout,
    pushConstantRangeCount = 1,
    pPushConstantRanges    = &push_constant_range,
  }

  vk.CreatePipelineLayout(
    gpu_context.device,
    &pipeline_layout_info,
    nil,
    &system.depth_reduce_pipeline_layout,
  ) or_return

  // Create compute shader
  shader_module := gpu.create_shader_module(
    gpu_context.device,
    SHADER_DEPTH_REDUCE_COMP,
  ) or_return
  defer vk.DestroyShaderModule(gpu_context.device, shader_module, nil)

  shader_stage := vk.PipelineShaderStageCreateInfo {
    sType  = .PIPELINE_SHADER_STAGE_CREATE_INFO,
    stage  = {.COMPUTE},
    module = shader_module,
    pName  = "main",
  }

  pipeline_info := vk.ComputePipelineCreateInfo {
    sType  = .COMPUTE_PIPELINE_CREATE_INFO,
    stage  = shader_stage,
    layout = system.depth_reduce_pipeline_layout,
  }

  vk.CreateComputePipelines(
    gpu_context.device,
    0,
    1,
    &pipeline_info,
    nil,
    &system.depth_reduce_pipeline,
  ) or_return

  // Create descriptor pool for mip levels
  pool_size := vk.DescriptorPoolSize {
    type            = .STORAGE_IMAGE,
    descriptorCount = 16,
  }
  pool_size_sampler := vk.DescriptorPoolSize {
    type            = .COMBINED_IMAGE_SAMPLER,
    descriptorCount = 16,
  }
  pool_sizes := [?]vk.DescriptorPoolSize{pool_size, pool_size_sampler}

  pool_info := vk.DescriptorPoolCreateInfo {
    sType         = .DESCRIPTOR_POOL_CREATE_INFO,
    maxSets       = 16,
    poolSizeCount = len(pool_sizes),
    pPoolSizes    = raw_data(pool_sizes[:]),
  }

  vk.CreateDescriptorPool(
    gpu_context.device,
    &pool_info,
    nil,
    &system.depth_reduce_descriptor_pool,
  ) or_return

  // Allocate descriptor sets (will be updated when we build pyramid)
  layouts: [16]vk.DescriptorSetLayout
  for i in 0 ..< 16 {
    layouts[i] = descriptor_layout
  }

  alloc_info := vk.DescriptorSetAllocateInfo {
    sType              = .DESCRIPTOR_SET_ALLOCATE_INFO,
    descriptorPool     = system.depth_reduce_descriptor_pool,
    descriptorSetCount = 16,
    pSetLayouts        = raw_data(layouts[:]),
  }

  vk.AllocateDescriptorSets(
    gpu_context.device,
    &alloc_info,
    raw_data(system.depth_reduce_descriptor_sets[:]),
  ) or_return

  vk.DestroyDescriptorSetLayout(gpu_context.device, descriptor_layout, nil)

  return .SUCCESS
}

shutdown :: proc(
  system: ^OcclusionSystem,
  device: vk.Device,
) {
  if system.pyramid_sampler != 0 {
    vk.DestroySampler(device, system.pyramid_sampler, nil)
  }

  if system.pyramid_image.image != 0 {
    for i in 0 ..< system.pyramid_levels {
      if system.pyramid_mip_views[i] != 0 {
        vk.DestroyImageView(device, system.pyramid_mip_views[i], nil)
      }
    }
    gpu.image_buffer_destroy(device, &system.pyramid_image)
  }

  if system.depth_reduce_pipeline != 0 {
    vk.DestroyPipeline(device, system.depth_reduce_pipeline, nil)
  }

  if system.depth_reduce_pipeline_layout != 0 {
    vk.DestroyPipelineLayout(device, system.depth_reduce_pipeline_layout, nil)
  }

  if system.depth_reduce_descriptor_pool != 0 {
    vk.DestroyDescriptorPool(device, system.depth_reduce_descriptor_pool, nil)
  }

  if system.debug_pipeline != 0 {
    vk.DestroyPipeline(device, system.debug_pipeline, nil)
  }

  if system.debug_pipeline_layout != 0 {
    vk.DestroyPipelineLayout(device, system.debug_pipeline_layout, nil)
  }

  if system.debug_descriptor_pool != 0 {
    vk.DestroyDescriptorPool(device, system.debug_descriptor_pool, nil)
  }

  if system.occlusion_cull_pipeline != 0 {
    vk.DestroyPipeline(device, system.occlusion_cull_pipeline, nil)
  }

  if system.occlusion_cull_pipeline_layout != 0 {
    vk.DestroyPipelineLayout(device, system.occlusion_cull_pipeline_layout, nil)
  }

  if system.occlusion_cull_descriptor_pool != 0 {
    vk.DestroyDescriptorPool(device, system.occlusion_cull_descriptor_pool, nil)
  }

  gpu.data_buffer_destroy(device, &system.visibility_prev)
  gpu.data_buffer_destroy(device, &system.visibility_curr)
  gpu.data_buffer_destroy(device, &system.node_bounds)

  log.info("Occlusion culling system shutdown")
}

// Build depth pyramid from depth texture
build_pyramid :: proc(
  system: ^OcclusionSystem,
  gpu_context: ^gpu.GPUContext,
  resources_manager: ^resources.Manager,
  command_buffer: vk.CommandBuffer,
  depth_texture: resources.Handle,
) {
  depth_image := resources.get(resources_manager.image_2d_buffers, depth_texture)

  vk.CmdBindPipeline(command_buffer, .COMPUTE, system.depth_reduce_pipeline)

  for level in 0 ..< system.pyramid_levels {
    // Update descriptor set for this level
    output_image_info := vk.DescriptorImageInfo {
      imageView   = system.pyramid_mip_views[level],
      imageLayout = .GENERAL,
    }

    // Source is either depth texture (level 0) or previous mip
    input_image_info: vk.DescriptorImageInfo
    if level == 0 {
      input_image_info = {
        sampler     = system.pyramid_sampler,
        imageView   = depth_image.view,
        imageLayout = .SHADER_READ_ONLY_OPTIMAL,
      }
    } else {
      input_image_info = {
        sampler     = system.pyramid_sampler,
        imageView   = system.pyramid_mip_views[level - 1],
        imageLayout = .GENERAL,
      }
    }

    writes := [?]vk.WriteDescriptorSet {
      {
        sType           = .WRITE_DESCRIPTOR_SET,
        dstSet          = system.depth_reduce_descriptor_sets[level],
        dstBinding      = 0,
        dstArrayElement = 0,
        descriptorCount = 1,
        descriptorType  = .STORAGE_IMAGE,
        pImageInfo      = &output_image_info,
      },
      {
        sType           = .WRITE_DESCRIPTOR_SET,
        dstSet          = system.depth_reduce_descriptor_sets[level],
        dstBinding      = 1,
        dstArrayElement = 0,
        descriptorCount = 1,
        descriptorType  = .COMBINED_IMAGE_SAMPLER,
        pImageInfo      = &input_image_info,
      },
    }

    vk.UpdateDescriptorSets(
      gpu_context.device,
      len(writes),
      raw_data(writes[:]),
      0,
      nil,
    )

    // Bind descriptor set
    vk.CmdBindDescriptorSets(
      command_buffer,
      .COMPUTE,
      system.depth_reduce_pipeline_layout,
      0,
      1,
      &system.depth_reduce_descriptor_sets[level],
      0,
      nil,
    )

    // Calculate dispatch size
    level_width := max(1, system.pyramid_width >> level)
    level_height := max(1, system.pyramid_height >> level)

    push_constants := DepthReducePushConstants {
      image_size = {f32(level_width), f32(level_height)},
    }

    vk.CmdPushConstants(
      command_buffer,
      system.depth_reduce_pipeline_layout,
      {.COMPUTE},
      0,
      size_of(DepthReducePushConstants),
      &push_constants,
    )

    // Dispatch compute shader (32x32 workgroup)
    group_count_x := (level_width + 31) / 32
    group_count_y := (level_height + 31) / 32
    vk.CmdDispatch(command_buffer, group_count_x, group_count_y, 1)

    // Barrier between levels
    if level < system.pyramid_levels - 1 {
      barrier := vk.MemoryBarrier2 {
        sType         = .MEMORY_BARRIER_2,
        srcStageMask  = {.COMPUTE_SHADER},
        srcAccessMask = {.SHADER_WRITE},
        dstStageMask  = {.COMPUTE_SHADER},
        dstAccessMask = {.SHADER_READ},
      }

      dependency_info := vk.DependencyInfo {
        sType                   = .DEPENDENCY_INFO,
        memoryBarrierCount      = 1,
        pMemoryBarriers         = &barrier,
      }

      vk.CmdPipelineBarrier2(command_buffer, &dependency_info)
    }
  }
}

SHADER_DEBUG_COMP :: #load("../../shader/depth_pyramid_debug/compute.spv")
SHADER_OCCLUSION_CULL_COMP :: #load("../../shader/occlusion_cull/compute.spv")

create_occlusion_cull_pipeline :: proc(
  system: ^OcclusionSystem,
  gpu_context: ^gpu.GPUContext,
  resources_manager: ^resources.Manager,
) -> vk.Result {
  // Descriptor set layout
  bindings := [?]vk.DescriptorSetLayoutBinding {
    { // Node bounds
      binding         = 0,
      descriptorType  = .STORAGE_BUFFER,
      descriptorCount = 1,
      stageFlags      = {.COMPUTE},
    },
    { // Visibility previous
      binding         = 1,
      descriptorType  = .STORAGE_BUFFER,
      descriptorCount = 1,
      stageFlags      = {.COMPUTE},
    },
    { // Visibility current
      binding         = 2,
      descriptorType  = .STORAGE_BUFFER,
      descriptorCount = 1,
      stageFlags      = {.COMPUTE},
    },
    { // Depth pyramid
      binding         = 3,
      descriptorType  = .COMBINED_IMAGE_SAMPLER,
      descriptorCount = 1,
      stageFlags      = {.COMPUTE},
    },
  }

  layout_info := vk.DescriptorSetLayoutCreateInfo {
    sType        = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
    bindingCount = len(bindings),
    pBindings    = raw_data(bindings[:]),
  }

  descriptor_layout: vk.DescriptorSetLayout
  vk.CreateDescriptorSetLayout(
    gpu_context.device,
    &layout_info,
    nil,
    &descriptor_layout,
  ) or_return

  // Pipeline layout with push constants
  push_constant_range := vk.PushConstantRange {
    stageFlags = {.COMPUTE},
    offset     = 0,
    size       = size_of(OcclusionCullPushConstants),
  }

  pipeline_layout_info := vk.PipelineLayoutCreateInfo {
    sType                  = .PIPELINE_LAYOUT_CREATE_INFO,
    setLayoutCount         = 1,
    pSetLayouts            = &descriptor_layout,
    pushConstantRangeCount = 1,
    pPushConstantRanges    = &push_constant_range,
  }

  vk.CreatePipelineLayout(
    gpu_context.device,
    &pipeline_layout_info,
    nil,
    &system.occlusion_cull_pipeline_layout,
  ) or_return

  // Create compute shader
  shader_module := gpu.create_shader_module(
    gpu_context.device,
    SHADER_OCCLUSION_CULL_COMP,
  ) or_return
  defer vk.DestroyShaderModule(gpu_context.device, shader_module, nil)

  shader_stage := vk.PipelineShaderStageCreateInfo {
    sType  = .PIPELINE_SHADER_STAGE_CREATE_INFO,
    stage  = {.COMPUTE},
    module = shader_module,
    pName  = "main",
  }

  pipeline_info := vk.ComputePipelineCreateInfo {
    sType  = .COMPUTE_PIPELINE_CREATE_INFO,
    stage  = shader_stage,
    layout = system.occlusion_cull_pipeline_layout,
  }

  vk.CreateComputePipelines(
    gpu_context.device,
    0,
    1,
    &pipeline_info,
    nil,
    &system.occlusion_cull_pipeline,
  ) or_return

  // Create descriptor pool
  pool_sizes := [?]vk.DescriptorPoolSize {
    {type = .STORAGE_BUFFER, descriptorCount = 3},
    {type = .COMBINED_IMAGE_SAMPLER, descriptorCount = 1},
  }

  pool_info := vk.DescriptorPoolCreateInfo {
    sType         = .DESCRIPTOR_POOL_CREATE_INFO,
    maxSets       = 1,
    poolSizeCount = len(pool_sizes),
    pPoolSizes    = raw_data(pool_sizes[:]),
  }

  vk.CreateDescriptorPool(
    gpu_context.device,
    &pool_info,
    nil,
    &system.occlusion_cull_descriptor_pool,
  ) or_return

  // Allocate descriptor set
  alloc_info := vk.DescriptorSetAllocateInfo {
    sType              = .DESCRIPTOR_SET_ALLOCATE_INFO,
    descriptorPool     = system.occlusion_cull_descriptor_pool,
    descriptorSetCount = 1,
    pSetLayouts        = &descriptor_layout,
  }

  vk.AllocateDescriptorSets(
    gpu_context.device,
    &alloc_info,
    &system.occlusion_cull_descriptor_set,
  ) or_return

  vk.DestroyDescriptorSetLayout(gpu_context.device, descriptor_layout, nil)

  return .SUCCESS
}

create_debug_pipeline :: proc(
  system: ^OcclusionSystem,
  gpu_context: ^gpu.GPUContext,
) -> vk.Result {
  // Descriptor set layout: binding 0 = depth pyramid sampler, binding 1 = output image
  bindings := [?]vk.DescriptorSetLayoutBinding {
    {
      binding         = 0,
      descriptorType  = .COMBINED_IMAGE_SAMPLER,
      descriptorCount = 1,
      stageFlags      = {.COMPUTE},
    },
    {
      binding         = 1,
      descriptorType  = .STORAGE_IMAGE,
      descriptorCount = 1,
      stageFlags      = {.COMPUTE},
    },
  }

  layout_info := vk.DescriptorSetLayoutCreateInfo {
    sType        = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
    bindingCount = len(bindings),
    pBindings    = raw_data(bindings[:]),
  }

  descriptor_layout: vk.DescriptorSetLayout
  vk.CreateDescriptorSetLayout(
    gpu_context.device,
    &layout_info,
    nil,
    &descriptor_layout,
  ) or_return

  // Pipeline layout with push constants
  push_constant_range := vk.PushConstantRange {
    stageFlags = {.COMPUTE},
    offset     = 0,
    size       = size_of(DebugPushConstants),
  }

  pipeline_layout_info := vk.PipelineLayoutCreateInfo {
    sType                  = .PIPELINE_LAYOUT_CREATE_INFO,
    setLayoutCount         = 1,
    pSetLayouts            = &descriptor_layout,
    pushConstantRangeCount = 1,
    pPushConstantRanges    = &push_constant_range,
  }

  vk.CreatePipelineLayout(
    gpu_context.device,
    &pipeline_layout_info,
    nil,
    &system.debug_pipeline_layout,
  ) or_return

  // Create compute shader
  shader_module := gpu.create_shader_module(
    gpu_context.device,
    SHADER_DEBUG_COMP,
  ) or_return
  defer vk.DestroyShaderModule(gpu_context.device, shader_module, nil)

  shader_stage := vk.PipelineShaderStageCreateInfo {
    sType  = .PIPELINE_SHADER_STAGE_CREATE_INFO,
    stage  = {.COMPUTE},
    module = shader_module,
    pName  = "main",
  }

  pipeline_info := vk.ComputePipelineCreateInfo {
    sType  = .COMPUTE_PIPELINE_CREATE_INFO,
    stage  = shader_stage,
    layout = system.debug_pipeline_layout,
  }

  vk.CreateComputePipelines(
    gpu_context.device,
    0,
    1,
    &pipeline_info,
    nil,
    &system.debug_pipeline,
  ) or_return

  // Create descriptor pool
  pool_sizes := [?]vk.DescriptorPoolSize {
    {type = .COMBINED_IMAGE_SAMPLER, descriptorCount = 1},
    {type = .STORAGE_IMAGE, descriptorCount = 1},
  }

  pool_info := vk.DescriptorPoolCreateInfo {
    sType         = .DESCRIPTOR_POOL_CREATE_INFO,
    maxSets       = 1,
    poolSizeCount = len(pool_sizes),
    pPoolSizes    = raw_data(pool_sizes[:]),
  }

  vk.CreateDescriptorPool(
    gpu_context.device,
    &pool_info,
    nil,
    &system.debug_descriptor_pool,
  ) or_return

  // Allocate descriptor set
  alloc_info := vk.DescriptorSetAllocateInfo {
    sType              = .DESCRIPTOR_SET_ALLOCATE_INFO,
    descriptorPool     = system.debug_descriptor_pool,
    descriptorSetCount = 1,
    pSetLayouts        = &descriptor_layout,
  }

  vk.AllocateDescriptorSets(
    gpu_context.device,
    &alloc_info,
    &system.debug_descriptor_set,
  ) or_return

  vk.DestroyDescriptorSetLayout(gpu_context.device, descriptor_layout, nil)

  return .SUCCESS
}

// Update node bounding spheres from mesh AABBs and world transforms
update_node_bounds :: proc(
  system: ^OcclusionSystem,
  resources_manager: ^resources.Manager,
  node_count: u32,
) {
  if !system.enabled do return
  if node_count == 0 do return
  if system.node_bounds.buffer == 0 do return

  // Safety check: ensure staged buffers are initialized and mapped
  if resources_manager.node_data_buffer.buffer == 0 do return
  if resources_manager.node_data_buffer.mapped == nil do return
  if resources_manager.mesh_data_buffer.buffer == 0 do return
  if resources_manager.mesh_data_buffer.mapped == nil do return
  if resources_manager.world_matrix_buffer.buffer == 0 do return
  if resources_manager.world_matrix_buffer.mapped == nil do return

  // Safety check: ensure node_count doesn't exceed buffer capacity
  safe_count := min(node_count, system.max_nodes)

  for i in 0 ..< safe_count {
    // Get node data
    node_data := gpu.staged_buffer_get(&resources_manager.node_data_buffer, i)
    if node_data == nil do continue

    // Skip if mesh_id is invalid
    if node_data.mesh_id >= resources.MAX_MESHES do continue

    // Get mesh data
    mesh_data := gpu.staged_buffer_get(&resources_manager.mesh_data_buffer, node_data.mesh_id)
    if mesh_data == nil do continue

    // Get world matrix
    world_matrix := gpu.staged_buffer_get(&resources_manager.world_matrix_buffer, i)
    if world_matrix == nil do continue

    // Transform AABB to world space and compute bounding sphere
    aabb_min := mesh_data.aabb_min
    aabb_max := mesh_data.aabb_max

    // Get 8 corners of AABB
    corners := [8][3]f32 {
      {aabb_min.x, aabb_min.y, aabb_min.z},
      {aabb_max.x, aabb_min.y, aabb_min.z},
      {aabb_min.x, aabb_max.y, aabb_min.z},
      {aabb_max.x, aabb_max.y, aabb_min.z},
      {aabb_min.x, aabb_min.y, aabb_max.z},
      {aabb_max.x, aabb_min.y, aabb_max.z},
      {aabb_min.x, aabb_max.y, aabb_max.z},
      {aabb_max.x, aabb_max.y, aabb_max.z},
    }

    // Transform corners to world space
    world_corners := [8][3]f32{}
    for corner, j in corners {
      world_pos := world_matrix^ * [4]f32{corner.x, corner.y, corner.z, 1.0}
      world_corners[j] = world_pos.xyz / world_pos.w
    }

    // Compute center of transformed AABB
    center := [3]f32{0, 0, 0}
    for corner in world_corners {
      center += corner
    }
    center /= 8.0

    // Compute radius as max distance from center to any corner
    radius := f32(0)
    for corner in world_corners {
      dist_sq := (corner.x - center.x) * (corner.x - center.x) +
                 (corner.y - center.y) * (corner.y - center.y) +
                 (corner.z - center.z) * (corner.z - center.z)
      dist := math.sqrt(dist_sq)
      radius = max(radius, dist)
    }

    // Write to node_bounds buffer (xyz=center, w=radius)
    bounds := gpu.data_buffer_get(&system.node_bounds, i)
    if bounds == nil do continue
    bounds^ = [4]f32{center.x, center.y, center.z, radius}
  }
}

// Dispatch occlusion culling compute shader
dispatch_occlusion_cull :: proc(
  system: ^OcclusionSystem,
  gpu_context: ^gpu.GPUContext,
  resources_manager: ^resources.Manager,
  command_buffer: vk.CommandBuffer,
  camera_handle: resources.Handle,
  node_count: u32,
) {
  log.infof("  dispatch_occlusion_cull: camera_handle=(index=%d,gen=%d) node_count=%d",
    camera_handle.index, camera_handle.generation, node_count)

  if !system.enabled {
    log.info("  Early return: system not enabled")
    return
  }
  if node_count == 0 {
    log.info("  Early return: node_count == 0")
    return
  }

  // Get camera data from buffer
  camera_data := resources.get_camera_data(resources_manager, camera_handle.index)
  if camera_data == nil {
    log.infof("  Early return: camera_data is nil for camera_index=%d", camera_handle.index)
    return
  }

  // Get camera for near/far values
  camera, ok := resources.get_camera(resources_manager, camera_handle)
  if !ok {
    log.infof("  Early return: failed to get camera for handle=(index=%d,gen=%d)",
      camera_handle.index, camera_handle.generation)
    return
  }

  near, far := geometry.camera_get_near_far(camera^)
  log.infof("  Got camera successfully: near=%.3f far=%.3f", near, far)

  // Update descriptor sets
  node_bounds_buffer_info := vk.DescriptorBufferInfo {
    buffer = system.node_bounds.buffer,
    offset = 0,
    range  = vk.DeviceSize(system.max_nodes * size_of([4]f32)),
  }

  visibility_prev_buffer_info := vk.DescriptorBufferInfo {
    buffer = system.visibility_prev.buffer,
    offset = 0,
    range  = vk.DeviceSize(system.max_nodes * size_of(u32)),
  }

  visibility_curr_buffer_info := vk.DescriptorBufferInfo {
    buffer = system.visibility_curr.buffer,
    offset = 0,
    range  = vk.DeviceSize(system.max_nodes * size_of(u32)),
  }

  depth_pyramid_image_info := vk.DescriptorImageInfo {
    sampler     = system.pyramid_sampler,
    imageView   = system.pyramid_image.view,
    imageLayout = .GENERAL,
  }

  writes := [?]vk.WriteDescriptorSet {
    {
      sType           = .WRITE_DESCRIPTOR_SET,
      dstSet          = system.occlusion_cull_descriptor_set,
      dstBinding      = 0,
      dstArrayElement = 0,
      descriptorCount = 1,
      descriptorType  = .STORAGE_BUFFER,
      pBufferInfo     = &node_bounds_buffer_info,
    },
    {
      sType           = .WRITE_DESCRIPTOR_SET,
      dstSet          = system.occlusion_cull_descriptor_set,
      dstBinding      = 1,
      dstArrayElement = 0,
      descriptorCount = 1,
      descriptorType  = .STORAGE_BUFFER,
      pBufferInfo     = &visibility_prev_buffer_info,
    },
    {
      sType           = .WRITE_DESCRIPTOR_SET,
      dstSet          = system.occlusion_cull_descriptor_set,
      dstBinding      = 2,
      dstArrayElement = 0,
      descriptorCount = 1,
      descriptorType  = .STORAGE_BUFFER,
      pBufferInfo     = &visibility_curr_buffer_info,
    },
    {
      sType           = .WRITE_DESCRIPTOR_SET,
      dstSet          = system.occlusion_cull_descriptor_set,
      dstBinding      = 3,
      dstArrayElement = 0,
      descriptorCount = 1,
      descriptorType  = .COMBINED_IMAGE_SAMPLER,
      pImageInfo      = &depth_pyramid_image_info,
    },
  }

  vk.UpdateDescriptorSets(
    gpu_context.device,
    len(writes),
    raw_data(writes[:]),
    0,
    nil,
  )

  // Set up push constants
  push_constants := OcclusionCullPushConstants {
    view           = camera_data.view,
    P00            = camera_data.projection[0, 0],
    P11            = camera_data.projection[1, 1],
    znear          = near,
    zfar           = far,
    pyramid_width  = f32(system.pyramid_width),
    pyramid_height = f32(system.pyramid_height),
    node_count     = node_count,
    occlusion_enabled = 1,  // Enable depth test
  }

  log.infof("  Camera: near=%.3f far=%.3f P00=%.3f P11=%.3f", near, far, camera_data.projection[0,0], camera_data.projection[1,1])

  // Bind pipeline and descriptor set
  vk.CmdBindPipeline(command_buffer, .COMPUTE, system.occlusion_cull_pipeline)
  vk.CmdBindDescriptorSets(
    command_buffer,
    .COMPUTE,
    system.occlusion_cull_pipeline_layout,
    0,
    1,
    &system.occlusion_cull_descriptor_set,
    0,
    nil,
  )

  // Push constants
  vk.CmdPushConstants(
    command_buffer,
    system.occlusion_cull_pipeline_layout,
    {.COMPUTE},
    0,
    size_of(OcclusionCullPushConstants),
    &push_constants,
  )

  // Dispatch compute shader (64 threads per workgroup)
  group_count := (node_count + 63) / 64
  vk.CmdDispatch(command_buffer, group_count, 1, 1)

  // Add barrier to ensure visibility results are available
  barrier := vk.MemoryBarrier2 {
    sType         = .MEMORY_BARRIER_2,
    srcStageMask  = {.COMPUTE_SHADER},
    srcAccessMask = {.SHADER_WRITE},
    dstStageMask  = {.COMPUTE_SHADER, .DRAW_INDIRECT},
    dstAccessMask = {.SHADER_READ, .INDIRECT_COMMAND_READ},
  }

  dependency_info := vk.DependencyInfo {
    sType              = .DEPENDENCY_INFO,
    memoryBarrierCount = 1,
    pMemoryBarriers    = &barrier,
  }

  vk.CmdPipelineBarrier2(command_buffer, &dependency_info)
}

// Get visibility statistics (for debugging)
get_visibility_stats :: proc(system: ^OcclusionSystem, node_count: u32) -> (visible: u32, total: u32) {
  if system.visibility_curr.mapped == nil do return 0, 0

  total = min(node_count, system.max_nodes)
  visible = 0

  // Sample first few bounds to check if they're valid
  valid_bounds := 0
  for i in 0 ..< min(10, total) {
    bounds := gpu.data_buffer_get(&system.node_bounds, i)
    if bounds != nil {
      radius := bounds^.w
      if radius > 0.001 {
        valid_bounds += 1
      }
      if i < 3 {
        log.infof("  Bound[%d]: center=(%.2f,%.2f,%.2f) radius=%.2f", i, bounds^.x, bounds^.y, bounds^.z, radius)
      }
    }
  }
  log.infof("  Valid bounds in first 10: %d/10", valid_bounds)

  for i in 0 ..< total {
    vis := gpu.data_buffer_get(&system.visibility_curr, i)
    if vis != nil && vis^ != 0 {
      visible += 1
    }
  }

  return visible, total
}

// Swap visibility buffers at end of frame
swap_visibility_buffers :: proc(system: ^OcclusionSystem) {
  system.visibility_prev, system.visibility_curr = system.visibility_curr, system.visibility_prev
}

// Visualize depth pyramid for debugging
visualize_pyramid :: proc(
  system: ^OcclusionSystem,
  gpu_context: ^gpu.GPUContext,
  command_buffer: vk.CommandBuffer,
  output_image_view: vk.ImageView,
  width, height: u32,
) {

  // Update descriptor set
  pyramid_image_info := vk.DescriptorImageInfo {
    sampler     = system.pyramid_sampler,
    imageView   = system.pyramid_image.view,
    imageLayout = .GENERAL,
  }

  output_image_info := vk.DescriptorImageInfo {
    imageView   = output_image_view,
    imageLayout = .GENERAL,
  }

  writes := [?]vk.WriteDescriptorSet {
    {
      sType           = .WRITE_DESCRIPTOR_SET,
      dstSet          = system.debug_descriptor_set,
      dstBinding      = 0,
      dstArrayElement = 0,
      descriptorCount = 1,
      descriptorType  = .COMBINED_IMAGE_SAMPLER,
      pImageInfo      = &pyramid_image_info,
    },
    {
      sType           = .WRITE_DESCRIPTOR_SET,
      dstSet          = system.debug_descriptor_set,
      dstBinding      = 1,
      dstArrayElement = 0,
      descriptorCount = 1,
      descriptorType  = .STORAGE_IMAGE,
      pImageInfo      = &output_image_info,
    },
  }

  vk.UpdateDescriptorSets(
    gpu_context.device,
    len(writes),
    raw_data(writes[:]),
    0,
    nil,
  )

  // Bind pipeline and descriptor set
  vk.CmdBindPipeline(command_buffer, .COMPUTE, system.debug_pipeline)
  vk.CmdBindDescriptorSets(
    command_buffer,
    .COMPUTE,
    system.debug_pipeline_layout,
    0,
    1,
    &system.debug_descriptor_set,
    0,
    nil,
  )

  // Push constants
  push_constants := DebugPushConstants {
    mip_level     = system.debug_mip_level,
    screen_width  = width,
    screen_height = height,
    debug_scale   = 1.0,
  }

  vk.CmdPushConstants(
    command_buffer,
    system.debug_pipeline_layout,
    {.COMPUTE},
    0,
    size_of(DebugPushConstants),
    &push_constants,
  )

  // Dispatch
  group_count_x := (width + 15) / 16
  group_count_y := (height + 15) / 16
  vk.CmdDispatch(command_buffer, group_count_x, group_count_y, 1)
}

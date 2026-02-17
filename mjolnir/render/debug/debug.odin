package debug

import "../../gpu"
import "../camera"
import "../data"
import "../shared"
import "core:log"
import vk "vendor:vulkan"

// Compiled SPIR-V shaders
SHADER_BONE_VERT :: #load("../../shader/debug_bone/vert.spv")
SHADER_BONE_FRAG :: #load("../../shader/debug_bone/frag.spv")

// Debug rendering module for 3D debug visualization
// Currently supports: Bone visualization with hierarchical coloring

// Bone instance data for GPU instanced rendering
BoneInstance :: struct {
  position: [3]f32,
  scale:    f32,
  color:    [4]f32,
}

Renderer :: struct {
  // Graphics pipeline
  pipeline:        vk.Pipeline,
  pipeline_layout: vk.PipelineLayout,

  // Instance buffer for bone data
  instance_buffer: gpu.MutableBuffer(BoneInstance),
  max_bones:       u32,

  // Staged bone instances for rendering (populated by engine/world)
  bone_instances: [dynamic]BoneInstance,
}

init :: proc(
  self: ^Renderer,
  gctx: ^gpu.GPUContext,
  camera_set_layout: vk.DescriptorSetLayout,
) -> (
  ret: vk.Result,
) {
  log.debugf("Initializing debug renderer")

  // Initialize bone instances array
  self.bone_instances = make([dynamic]BoneInstance, 0, 1024)

  // Create instance buffer (support up to 4096 bones)
  self.max_bones = 4096
  self.instance_buffer = gpu.create_mutable_buffer(
    gctx,
    BoneInstance,
    int(self.max_bones),
    {.VERTEX_BUFFER},
  ) or_return
  defer if ret != .SUCCESS {
    gpu.mutable_buffer_destroy(gctx.device, &self.instance_buffer)
  }

  // Create pipeline layout with camera descriptor set
  self.pipeline_layout = gpu.create_pipeline_layout(
    gctx,
    vk.PushConstantRange{stageFlags = {.VERTEX}, size = size_of(u32)},
    camera_set_layout,
  ) or_return
  defer if ret != .SUCCESS {
    vk.DestroyPipelineLayout(gctx.device, self.pipeline_layout, nil)
  }

  // Set up vertex input (per-instance attributes)
  vertex_binding := vk.VertexInputBindingDescription {
    binding   = 0,
    stride    = size_of(BoneInstance),
    inputRate = .VERTEX,  // Per-vertex (one per bone)
  }

  vertex_attributes := [?]vk.VertexInputAttributeDescription {
    // Location 0: position
    {
      location = 0,
      binding  = 0,
      format   = .R32G32B32_SFLOAT,
      offset   = u32(offset_of(BoneInstance, position)),
    },
    // Location 1: color
    {
      location = 1,
      binding  = 0,
      format   = .R32G32B32A32_SFLOAT,
      offset   = u32(offset_of(BoneInstance, color)),
    },
    // Location 2: scale
    {
      location = 2,
      binding  = 0,
      format   = .R32_SFLOAT,
      offset   = u32(offset_of(BoneInstance, scale)),
    },
  }

  vertex_input_info := vk.PipelineVertexInputStateCreateInfo {
    sType                           = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
    vertexBindingDescriptionCount   = 1,
    pVertexBindingDescriptions      = &vertex_binding,
    vertexAttributeDescriptionCount = len(vertex_attributes),
    pVertexAttributeDescriptions    = raw_data(vertex_attributes[:]),
  }

  // Create shader modules
  vert_module := gpu.create_shader_module(
    gctx.device,
    SHADER_BONE_VERT,
  ) or_return
  frag_module := gpu.create_shader_module(
    gctx.device,
    SHADER_BONE_FRAG,
  ) or_return
  defer vk.DestroyShaderModule(gctx.device, vert_module, nil)
  defer vk.DestroyShaderModule(gctx.device, frag_module, nil)

  shader_stages := gpu.create_vert_frag_stages(
    vert_module,
    frag_module,
    &shared.SHADER_SPEC_CONSTANTS,
  )

  // Depth state with depth testing disabled (always render on top)
  disabled_depth_state := vk.PipelineDepthStencilStateCreateInfo {
    sType           = .PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
    depthTestEnable = false,  // Don't test depth
    depthWriteEnable = false,  // Don't write depth
  }

  // Create graphics pipeline
  // - Point topology (each bone is a point sprite)
  // - Depth test disabled (always render on top for debugging)
  // - Alpha blending enabled
  pipeline_info := vk.GraphicsPipelineCreateInfo {
    sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
    stageCount          = len(shader_stages),
    pStages             = raw_data(shader_stages[:]),
    pVertexInputState   = &vertex_input_info,
    pInputAssemblyState = &gpu.POINT_INPUT_ASSEMBLY,
    pViewportState      = &gpu.STANDARD_VIEWPORT_STATE,
    pRasterizationState = &gpu.DOUBLE_SIDED_RASTERIZER,
    pMultisampleState   = &gpu.STANDARD_MULTISAMPLING,
    pColorBlendState    = &gpu.COLOR_BLENDING_ADDITIVE,
    pDynamicState       = &gpu.STANDARD_DYNAMIC_STATES,
    pDepthStencilState  = &disabled_depth_state,  // Always render on top
    layout              = self.pipeline_layout,
    pNext               = &gpu.STANDARD_RENDERING_INFO,
  }

  vk.CreateGraphicsPipelines(
    gctx.device,
    0,
    1,
    &pipeline_info,
    nil,
    &self.pipeline,
  ) or_return

  log.debugf("Debug renderer initialized successfully")
  return .SUCCESS
}

shutdown :: proc(self: ^Renderer, gctx: ^gpu.GPUContext) {
  log.debugf("Shutting down debug renderer")
  delete(self.bone_instances)
  gpu.mutable_buffer_destroy(gctx.device, &self.instance_buffer)
  vk.DestroyPipeline(gctx.device, self.pipeline, nil)
  vk.DestroyPipelineLayout(gctx.device, self.pipeline_layout, nil)
}

// Stage bone instances for rendering
// Called by engine/world before render() to populate bone data
stage_bones :: proc(self: ^Renderer, instances: []BoneInstance) {
  clear(&self.bone_instances)
  append(&self.bone_instances, ..instances)
}

// Clear staged bone instances
clear_bones :: proc(self: ^Renderer) {
  clear(&self.bone_instances)
}

// Begin debug rendering pass
// Attaches to the camera's final image and depth buffer
// Returns false if attachments are missing (caller should skip rendering)
begin_pass :: proc(
  self: ^Renderer,
  camera: ^camera.Camera,
  texture_manager: ^gpu.TextureManager,
  command_buffer: vk.CommandBuffer,
  frame_index: u32,
) -> bool {
  color_texture := gpu.get_texture_2d(
    texture_manager,
    camera.attachments[.FINAL_IMAGE][frame_index],
  )
  if color_texture == nil {
    log.error("Debug rendering missing color attachment")
    return false
  }

  depth_texture := gpu.get_texture_2d(
    texture_manager,
    camera.attachments[.DEPTH][frame_index],
  )
  if depth_texture == nil {
    log.error("Debug rendering missing depth attachment")
    return false
  }

  // Begin rendering with LOAD ops (don't clear, render on top of existing content)
  gpu.begin_rendering(
    command_buffer,
    depth_texture.spec.width,
    depth_texture.spec.height,
    gpu.create_depth_attachment(depth_texture, .LOAD, .STORE),
    gpu.create_color_attachment(color_texture, .LOAD, .STORE),
  )

  gpu.set_viewport_scissor(
    command_buffer,
    depth_texture.spec.width,
    depth_texture.spec.height,
  )

  return true
}

// End debug rendering pass
end_pass :: proc(self: ^Renderer, command_buffer: vk.CommandBuffer) {
  vk.CmdEndRendering(command_buffer)
}

// Render all staged bone instances
// Should be called between begin_pass and end_pass
// Uses point sprite rendering to draw all bones in a single draw call
render :: proc(
  self: ^Renderer,
  command_buffer: vk.CommandBuffer,
  camera_descriptor_set: vk.DescriptorSet,
  camera_index: u32,
) -> vk.Result {
  if len(self.bone_instances) == 0 do return .SUCCESS

  bone_count := u32(len(self.bone_instances))
  if bone_count > self.max_bones {
    log.warnf(
      "Too many bones to render: %d (max %d), truncating",
      bone_count,
      self.max_bones,
    )
    bone_count = self.max_bones
  }

  // Upload bone instance data to GPU
  // Copy to instance buffer (CPU → GPU staging)
  instance_data := gpu.get_all(&self.instance_buffer)
  for i in 0 ..< bone_count {
    instance_data[i] = self.bone_instances[i]
  }

  // Bind pipeline
  vk.CmdBindPipeline(command_buffer, .GRAPHICS, self.pipeline)

  // Bind vertex buffer (instance data)
  offsets := [?]vk.DeviceSize{0}
  vk.CmdBindVertexBuffers(
    command_buffer,
    0,
    1,
    &self.instance_buffer.buffer,
    raw_data(offsets[:]),
  )

  // Bind descriptor sets (camera)
  descriptor_set := camera_descriptor_set
  vk.CmdBindDescriptorSets(
    command_buffer,
    .GRAPHICS,
    self.pipeline_layout,
    0,
    1,
    &descriptor_set,
    0,
    nil,
  )

  // Push constants (camera index)
  camera_index_copy := camera_index
  vk.CmdPushConstants(
    command_buffer,
    self.pipeline_layout,
    {.VERTEX},
    0,
    size_of(u32),
    &camera_index_copy,
  )

  // Draw points (one per bone)
  vk.CmdDraw(command_buffer, bone_count, 1, 0, 0)

  return .SUCCESS
}

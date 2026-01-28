package debug_draw

import cont "../../containers"
import "../../geometry"
import "../../gpu"
import "../../resources"
import "core:log"
import "core:math/linalg"
import "core:time"
import vk "vendor:vulkan"

SHADER_VERT :: #load("../../shader/debug_draw/vert.spv")
SHADER_FRAG :: #load("../../shader/debug_draw/frag.spv")

MAX_DEBUG_OBJECTS :: 4096

DebugObjectHandle :: distinct resources.Handle

RenderStyle :: enum u32 {
  UNIFORM_COLOR = 0,
  RANDOM_COLOR  = 1,
  WIREFRAME     = 2,
}

DebugObject :: struct {
  mesh_handle:   resources.MeshHandle,
  transform:     matrix[4, 4]f32,
  color:         [4]f32, // RGBA
  style:         RenderStyle,
  bypass_depth:  bool,
  expiry_time:   Maybe(time.Time), // When to auto-destroy (if set)
  is_line_strip: bool,
}

Renderer :: struct {
  objects:                   cont.Pool(DebugObject),
  pipeline_layout:           vk.PipelineLayout,
  solid_pipeline:            vk.Pipeline,
  wireframe_pipeline:        vk.Pipeline,
  depth_test_pipeline:       vk.Pipeline,
  depth_bypass_pipeline:     vk.Pipeline,
  wireframe_depth_bypass:    vk.Pipeline,
  line_strip_pipeline:       vk.Pipeline,
  line_strip_depth_bypass:   vk.Pipeline,
}

PushConstant :: struct {
  transform:    matrix[4, 4]f32,
  color:        [4]f32,
  camera_index: u32,
  style:        u32,
}

init :: proc(
  self: ^Renderer,
  gctx: ^gpu.GPUContext,
  rm: ^resources.Manager,
) -> (
  ret: vk.Result,
) {
  log.info("Initializing debug draw renderer")
  cont.init(&self.objects, MAX_DEBUG_OBJECTS)
  // Create dedicated pipeline layout with larger push constant range
  // Debug draw only needs camera buffer - everything else is in push constants
  self.pipeline_layout = gpu.create_pipeline_layout(
    gctx,
    vk.PushConstantRange {
      stageFlags = {.VERTEX, .FRAGMENT},
      size = size_of(PushConstant),
    },
    rm.camera_buffer.set_layout, // Set 0
  ) or_return
  create_pipelines(gctx, self, self.pipeline_layout) or_return
  log.infof(
    "Debug draw pipelines created: solid=%v, wireframe=%v, depth_bypass=%v",
    self.solid_pipeline,
    self.wireframe_pipeline,
    self.depth_bypass_pipeline,
  )
  log.info("Debug draw renderer initialized successfully")
  return .SUCCESS
}

create_pipelines :: proc(
  gctx: ^gpu.GPUContext,
  self: ^Renderer,
  pipeline_layout: vk.PipelineLayout,
) -> vk.Result {
  vert_module := gpu.create_shader_module(gctx.device, SHADER_VERT) or_return
  defer vk.DestroyShaderModule(gctx.device, vert_module, nil)
  frag_module := gpu.create_shader_module(gctx.device, SHADER_FRAG) or_return
  defer vk.DestroyShaderModule(gctx.device, frag_module, nil)
  vertex_input_info := vk.PipelineVertexInputStateCreateInfo {
    sType                           = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
    vertexBindingDescriptionCount   = len(geometry.VERTEX_BINDING_DESCRIPTION),
    pVertexBindingDescriptions      = raw_data(
      geometry.VERTEX_BINDING_DESCRIPTION[:],
    ),
    vertexAttributeDescriptionCount = len(
      geometry.VERTEX_ATTRIBUTE_DESCRIPTIONS,
    ),
    pVertexAttributeDescriptions    = raw_data(
      geometry.VERTEX_ATTRIBUTE_DESCRIPTIONS[:],
    ),
  }
  shader_stages := gpu.create_vert_frag_stages(vert_module, frag_module)
  // Solid pipeline with depth test
  solid_info := vk.GraphicsPipelineCreateInfo {
    sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
    stageCount          = len(shader_stages),
    pStages             = raw_data(shader_stages[:]),
    pVertexInputState   = &vertex_input_info,
    pInputAssemblyState = &gpu.STANDARD_INPUT_ASSEMBLY,
    pViewportState      = &gpu.STANDARD_VIEWPORT_STATE,
    pRasterizationState = &gpu.STANDARD_RASTERIZER,
    pMultisampleState   = &gpu.STANDARD_MULTISAMPLING,
    pDepthStencilState  = &gpu.READ_ONLY_DEPTH_STATE,
    pColorBlendState    = &gpu.COLOR_BLENDING_ADDITIVE,
    pDynamicState       = &gpu.STANDARD_DYNAMIC_STATES,
    layout              = pipeline_layout,
    pNext               = &gpu.STANDARD_RENDERING_INFO,
  }
  vk.CreateGraphicsPipelines(
    gctx.device,
    0,
    1,
    &solid_info,
    nil,
    &self.solid_pipeline,
  ) or_return
  // Wireframe pipeline with depth test
  wireframe_info := vk.GraphicsPipelineCreateInfo {
    sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
    stageCount          = len(shader_stages),
    pStages             = raw_data(shader_stages[:]),
    pVertexInputState   = &vertex_input_info,
    pInputAssemblyState = &gpu.STANDARD_INPUT_ASSEMBLY,
    pViewportState      = &gpu.STANDARD_VIEWPORT_STATE,
    pRasterizationState = &gpu.LINE_RASTERIZER,
    pMultisampleState   = &gpu.STANDARD_MULTISAMPLING,
    pDepthStencilState  = &gpu.READ_ONLY_DEPTH_STATE,
    pColorBlendState    = &gpu.COLOR_BLENDING_ADDITIVE,
    pDynamicState       = &gpu.STANDARD_DYNAMIC_STATES,
    layout              = pipeline_layout,
    pNext               = &gpu.STANDARD_RENDERING_INFO,
  }
  vk.CreateGraphicsPipelines(
    gctx.device,
    0,
    1,
    &wireframe_info,
    nil,
    &self.wireframe_pipeline,
  ) or_return
  // Solid pipeline without depth test (bypass)
  depth_bypass_state := vk.PipelineDepthStencilStateCreateInfo {
    sType                 = .PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
    depthTestEnable       = false,
    depthWriteEnable      = false,
    depthCompareOp        = .ALWAYS,
    depthBoundsTestEnable = false,
    stencilTestEnable     = false,
  }
  bypass_info := vk.GraphicsPipelineCreateInfo {
    sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
    stageCount          = len(shader_stages),
    pStages             = raw_data(shader_stages[:]),
    pVertexInputState   = &vertex_input_info,
    pInputAssemblyState = &gpu.STANDARD_INPUT_ASSEMBLY,
    pViewportState      = &gpu.STANDARD_VIEWPORT_STATE,
    pRasterizationState = &gpu.STANDARD_RASTERIZER,
    pMultisampleState   = &gpu.STANDARD_MULTISAMPLING,
    pDepthStencilState  = &depth_bypass_state,
    pColorBlendState    = &gpu.COLOR_BLENDING_ADDITIVE,
    pDynamicState       = &gpu.STANDARD_DYNAMIC_STATES,
    layout              = pipeline_layout,
    pNext               = &gpu.STANDARD_RENDERING_INFO,
  }
  vk.CreateGraphicsPipelines(
    gctx.device,
    0,
    1,
    &bypass_info,
    nil,
    &self.depth_bypass_pipeline,
  ) or_return
  // Wireframe without depth test
  wireframe_bypass_info := vk.GraphicsPipelineCreateInfo {
    sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
    stageCount          = len(shader_stages),
    pStages             = raw_data(shader_stages[:]),
    pVertexInputState   = &vertex_input_info,
    pInputAssemblyState = &gpu.STANDARD_INPUT_ASSEMBLY,
    pViewportState      = &gpu.STANDARD_VIEWPORT_STATE,
    pRasterizationState = &gpu.LINE_RASTERIZER,
    pMultisampleState   = &gpu.STANDARD_MULTISAMPLING,
    pDepthStencilState  = &depth_bypass_state,
    pColorBlendState    = &gpu.COLOR_BLENDING_ADDITIVE,
    pDynamicState       = &gpu.STANDARD_DYNAMIC_STATES,
    layout              = pipeline_layout,
    pNext               = &gpu.STANDARD_RENDERING_INFO,
  }
  vk.CreateGraphicsPipelines(
    gctx.device,
    0,
    1,
    &wireframe_bypass_info,
    nil,
    &self.wireframe_depth_bypass,
  ) or_return
  // Line strip pipeline with depth test
  line_strip_info := vk.GraphicsPipelineCreateInfo {
    sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
    stageCount          = len(shader_stages),
    pStages             = raw_data(shader_stages[:]),
    pVertexInputState   = &vertex_input_info,
    pInputAssemblyState = &gpu.LINE_INPUT_ASSEMBLY,
    pViewportState      = &gpu.STANDARD_VIEWPORT_STATE,
    pRasterizationState = &gpu.LINE_RASTERIZER,
    pMultisampleState   = &gpu.STANDARD_MULTISAMPLING,
    pDepthStencilState  = &gpu.READ_ONLY_DEPTH_STATE,
    pColorBlendState    = &gpu.COLOR_BLENDING_ADDITIVE,
    pDynamicState       = &gpu.STANDARD_DYNAMIC_STATES,
    layout              = pipeline_layout,
    pNext               = &gpu.STANDARD_RENDERING_INFO,
  }
  vk.CreateGraphicsPipelines(
    gctx.device,
    0,
    1,
    &line_strip_info,
    nil,
    &self.line_strip_pipeline,
  ) or_return
  // Line strip pipeline without depth test
  line_strip_bypass_info := vk.GraphicsPipelineCreateInfo {
    sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
    stageCount          = len(shader_stages),
    pStages             = raw_data(shader_stages[:]),
    pVertexInputState   = &vertex_input_info,
    pInputAssemblyState = &gpu.LINE_INPUT_ASSEMBLY,
    pViewportState      = &gpu.STANDARD_VIEWPORT_STATE,
    pRasterizationState = &gpu.LINE_RASTERIZER,
    pMultisampleState   = &gpu.STANDARD_MULTISAMPLING,
    pDepthStencilState  = &depth_bypass_state,
    pColorBlendState    = &gpu.COLOR_BLENDING_ADDITIVE,
    pDynamicState       = &gpu.STANDARD_DYNAMIC_STATES,
    layout              = pipeline_layout,
    pNext               = &gpu.STANDARD_RENDERING_INFO,
  }
  vk.CreateGraphicsPipelines(
    gctx.device,
    0,
    1,
    &line_strip_bypass_info,
    nil,
    &self.line_strip_depth_bypass,
  ) or_return
  return .SUCCESS
}

shutdown :: proc(self: ^Renderer, gctx: ^gpu.GPUContext) {
  vk.DestroyPipeline(gctx.device, self.solid_pipeline, nil)
  vk.DestroyPipeline(gctx.device, self.wireframe_pipeline, nil)
  vk.DestroyPipeline(gctx.device, self.depth_bypass_pipeline, nil)
  vk.DestroyPipeline(gctx.device, self.wireframe_depth_bypass, nil)
  vk.DestroyPipeline(gctx.device, self.line_strip_pipeline, nil)
  vk.DestroyPipeline(gctx.device, self.line_strip_depth_bypass, nil)
  vk.DestroyPipelineLayout(gctx.device, self.pipeline_layout, nil)
  self.solid_pipeline = 0
  self.wireframe_pipeline = 0
  self.depth_bypass_pipeline = 0
  self.wireframe_depth_bypass = 0
  self.line_strip_pipeline = 0
  self.line_strip_depth_bypass = 0
  self.pipeline_layout = 0
}

spawn_mesh :: proc(
  self: ^Renderer,
  mesh_handle: resources.MeshHandle,
  transform: matrix[4, 4]f32,
  color: [4]f32 = {1.0, 0.0, 0.75, 1.0}, // Pink default
  style: RenderStyle = .UNIFORM_COLOR,
  bypass_depth: bool = false,
) -> (
  handle: DebugObjectHandle,
  ok: bool,
) #optional_ok {
  h, obj := cont.alloc(&self.objects, DebugObjectHandle) or_return
  obj^ = DebugObject {
    mesh_handle   = mesh_handle,
    transform     = transform,
    color         = color,
    style         = style,
    bypass_depth  = bypass_depth,
    is_line_strip = false,
  }
  log.infof(
    "Debug draw spawned mesh: handle=%v, style=%v, color=%v",
    h,
    style,
    color,
  )
  return h, true
}

spawn_line_strip :: proc(
  self: ^Renderer,
  points: []geometry.Vertex,
  gctx: ^gpu.GPUContext,
  rm: ^resources.Manager,
  color: [4]f32 = {1.0, 0.0, 0.75, 1.0}, // Pink default
  bypass_depth: bool = false,
) -> (
  handle: DebugObjectHandle,
  ok: bool,
) #optional_ok {
  // Create line strip mesh from points
  indices := make([]u32, len(points))
  defer delete(indices)
  for i in 0 ..< len(points) {
    indices[i] = u32(i)
  }
  vertices_copy := make([]geometry.Vertex, len(points))
  defer delete(vertices_copy)
  copy(vertices_copy, points)
  geom := geometry.Geometry {
    vertices = vertices_copy,
    indices  = indices,
    aabb     = geometry.aabb_from_vertices(points),
  }
  mesh_h, mesh_res := resources.create_mesh(gctx, rm, geom)
  if mesh_res != .SUCCESS do return {}, false
  h, obj := cont.alloc(&self.objects, DebugObjectHandle) or_return
  obj^ = DebugObject {
    mesh_handle   = mesh_h,
    transform     = linalg.MATRIX4F32_IDENTITY,
    color         = color,
    style         = .UNIFORM_COLOR,
    bypass_depth  = bypass_depth,
    is_line_strip = true,
  }
  return h, true
}

spawn_mesh_temporary :: proc(
  self: ^Renderer,
  mesh_handle: resources.MeshHandle,
  transform: matrix[4, 4]f32,
  duration_seconds: f64,
  color: [4]f32 = {1.0, 0.0, 0.75, 1.0},
  style: RenderStyle = .UNIFORM_COLOR,
  bypass_depth: bool = false,
) -> (
  handle: DebugObjectHandle,
  ok: bool,
) #optional_ok {
  h, obj := cont.alloc(&self.objects, DebugObjectHandle) or_return
  duration := time.Duration(duration_seconds * f64(time.Second))
  expiry := time.time_add(time.now(), duration)
  obj^ = DebugObject {
    mesh_handle   = mesh_handle,
    transform     = transform,
    color         = color,
    style         = style,
    bypass_depth  = bypass_depth,
    expiry_time   = expiry,
    is_line_strip = false,
  }
  return h, true
}

spawn_line_strip_temporary :: proc(
  self: ^Renderer,
  points: []geometry.Vertex,
  gctx: ^gpu.GPUContext,
  rm: ^resources.Manager,
  duration_seconds: f64,
  color: [4]f32 = {1.0, 0.0, 0.75, 1.0},
  bypass_depth: bool = false,
) -> (
  handle: DebugObjectHandle,
  ok: bool,
) #optional_ok {
  indices := make([]u32, len(points))
  defer if !ok do delete(indices)
  for i in 0 ..< len(points) {
    indices[i] = u32(i)
  }
  vertices_copy := make([]geometry.Vertex, len(points))
  defer if !ok do delete(vertices_copy)
  copy(vertices_copy, points)
  geom := geometry.Geometry {
    vertices = vertices_copy,
    indices  = indices,
    aabb     = geometry.aabb_from_vertices(points),
  }
  mesh_h, mesh_res := resources.create_mesh(gctx, rm, geom)
  if mesh_res != .SUCCESS do return {}, false
  h, obj := cont.alloc(&self.objects, DebugObjectHandle) or_return
  duration := time.Duration(duration_seconds * f64(time.Second))
  expiry := time.time_add(time.now(), duration)
  obj^ = DebugObject {
    mesh_handle   = mesh_h,
    transform     = linalg.MATRIX4F32_IDENTITY,
    color         = color,
    style         = .UNIFORM_COLOR,
    bypass_depth  = bypass_depth,
    expiry_time   = expiry,
    is_line_strip = true,
  }
  return h, true
}

destroy :: proc(
  self: ^Renderer,
  handle: DebugObjectHandle,
  rm: ^resources.Manager,
) {
  obj := cont.get(self.objects, handle)
  if obj != nil {
    // Only destroy mesh if this debug object owns it (line strips)
    if obj.is_line_strip {
      resources.destroy_mesh(rm, obj.mesh_handle)
    }
  }
  cont.free(&self.objects, handle)
}

update :: proc(self: ^Renderer, rm: ^resources.Manager) {
  // Clean up expired objects
  now := time.now()
  for &entry, idx in self.objects.entries do if entry.active {
    obj := &entry.item
    expiry, has_expiry := obj.expiry_time.?
    if !has_expiry do continue
    if time.diff(now, expiry) > 0 do continue
    handle := DebugObjectHandle {
      index      = u32(idx),
      generation = entry.generation,
    }
    destroy(self, handle, rm)
  }
}

begin_pass :: proc(
  self: ^Renderer,
  camera_handle: resources.CameraHandle,
  command_buffer: vk.CommandBuffer,
  rm: ^resources.Manager,
  frame_index: u32,
) {
  camera := cont.get(rm.cameras, camera_handle)
  if camera == nil do return
  color_texture := cont.get(
    rm.images_2d,
    camera.attachments[.FINAL_IMAGE][frame_index],
  )
  if color_texture == nil {
    log.error("Debug draw missing color attachment")
    return
  }
  depth_texture := cont.get(
    rm.images_2d,
    camera.attachments[.DEPTH][frame_index],
  )
  if depth_texture == nil {
    log.error("Debug draw missing depth attachment")
    return
  }
  extent := camera.extent
  gpu.begin_rendering(
    command_buffer,
    extent.width,
    extent.height,
    gpu.create_depth_attachment(depth_texture, .LOAD, .STORE),
    gpu.create_color_attachment(color_texture, .LOAD, .STORE),
  )
  gpu.set_viewport_scissor(command_buffer, extent.width, extent.height)
}

render :: proc(
  self: ^Renderer,
  camera_handle: resources.CameraHandle,
  command_buffer: vk.CommandBuffer,
  rm: ^resources.Manager,
  frame_index: u32,
) {
  // Render all debug objects
  active_count := 0
  for &entry, idx in self.objects.entries {
    if !entry.active do continue
    active_count += 1
    obj := &entry.item
    mesh := cont.get(rm.meshes, obj.mesh_handle)
    if mesh == nil {
      log.warnf("Debug draw: mesh not found for object %d", idx)
      continue
    }
    // Select pipeline based on style, topology, and depth settings
    pipeline: vk.Pipeline
    if obj.is_line_strip {
      pipeline =
        self.line_strip_depth_bypass if obj.bypass_depth else self.line_strip_pipeline
    } else if obj.style == .WIREFRAME {
      pipeline =
        self.wireframe_depth_bypass if obj.bypass_depth else self.wireframe_pipeline
    } else {
      pipeline =
        self.depth_bypass_pipeline if obj.bypass_depth else self.solid_pipeline
    }
    // if frame_index == 0 && active_count == 1 {
    //   log.infof(
    //     "Debug draw object %d: pipeline=%v, indices=%d, style=%v, bypass=%v",
    //     idx,
    //     pipeline,
    //     mesh.index_count,
    //     obj.style,
    //     obj.bypass_depth,
    //   )
    // }
    gpu.bind_graphics_pipeline(
      command_buffer,
      pipeline,
      self.pipeline_layout,
      rm.camera_buffer.descriptor_sets[frame_index], // Set 0 (only one needed)
    )
    push_constants := PushConstant {
      camera_index = camera_handle.index,
      style        = u32(obj.style),
      transform    = obj.transform,
      color        = obj.color,
    }
    vk.CmdPushConstants(
      command_buffer,
      self.pipeline_layout,
      {.VERTEX, .FRAGMENT},
      0,
      size_of(PushConstant),
      &push_constants,
    )
    vertex_buffers := [?]vk.Buffer{rm.vertex_buffer.buffer}
    vertex_offsets := [?]vk.DeviceSize{0}
    vk.CmdBindVertexBuffers(
      command_buffer,
      0,
      1,
      raw_data(vertex_buffers[:]),
      raw_data(vertex_offsets[:]),
    )
    vk.CmdBindIndexBuffer(command_buffer, rm.index_buffer.buffer, 0, .UINT32)
    // Simple indexed draw (not indirect)
    vk.CmdDrawIndexed(
      command_buffer,
      mesh.index_count,
      1,
      mesh.first_index,
      mesh.vertex_offset,
      0,
    )
  }
  if active_count > 0 && frame_index == 0 {
    // log.infof("Debug draw rendered %d objects", active_count)
  }
}

end_pass :: proc(self: ^Renderer, command_buffer: vk.CommandBuffer) {
  vk.CmdEndRendering(command_buffer)
}

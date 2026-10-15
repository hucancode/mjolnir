package wgpu_backend

import rhi "../rhi"

import "core:log"
import "core:mem"
import wgpu "vendor:wgpu"

// Every pipeline's layout is {scene buffers of its ScenePass, a texture group (GroupLayout),
// the frame group}. Shaders declare these as @group(0), @group(1), @group(2) with bindings
// numbered in the order listed here.

// The storage buffers a pass reads (or, for compute, writes), in binding order.
@(private)
SceneBuffer :: enum {
  VIEWS,
  NODES,
  MESHES,
  MATERIALS,
  BONES,
  SKINNING,
  VERTICES,
  INDICES,
  EMITTERS,
  FORCEFIELDS,
  PARTICLES,
  PARTICLE_ALIVE,
  LIGHTS,
  DEBUG_LINES,
  BATCHES,
  NODE_BATCH,
}

@(private)
ScenePass :: enum {
  NONE,
  // material vertex and fragment shaders
  MESH,
  LIGHTING,
  // the shadow depth vertex shader
  SHADOW,
  CULL,
  PARTICLE_EMIT,
  PARTICLE_SIMULATE,
  PARTICLE_DRAW,
  DEBUG_LINE,
}

@(private)
SCENE_PASSES := [ScenePass]struct {
  buffers:    []SceneBuffer,
  visibility: wgpu.ShaderStageFlags,
  // bound read-write (compute only); the rest read-only
  writes:     bit_set[SceneBuffer],
} {
  .NONE              = {},
  .MESH              = {{.VIEWS, .NODES, .MESHES, .MATERIALS, .BONES, .SKINNING, .VERTICES, .INDICES}, {.Vertex, .Fragment}, {}},
  .LIGHTING          = {{.VIEWS, .LIGHTS}, {.Vertex, .Fragment}, {}},
  .SHADOW            = {{.VIEWS, .NODES, .MESHES, .BONES, .SKINNING}, {.Vertex}, {}},
  .CULL              = {{.VIEWS, .NODES, .MESHES, .MATERIALS, .BATCHES, .NODE_BATCH}, {.Compute}, {}},
  .PARTICLE_EMIT     = {{.NODES, .EMITTERS, .PARTICLES}, {.Compute}, {.PARTICLES}},
  .PARTICLE_SIMULATE = {{.NODES, .FORCEFIELDS, .PARTICLES, .PARTICLE_ALIVE}, {.Compute}, {.PARTICLES, .PARTICLE_ALIVE}},
  .PARTICLE_DRAW     = {{.VIEWS, .PARTICLES, .PARTICLE_ALIVE}, {.Vertex}, {}},
  .DEBUG_LINE        = {{.VIEWS, .DEBUG_LINES}, {.Vertex}, {}},
}

// Texture groups (group 1): each slot is a texture of this kind.
@(private)
TextureSlot :: enum {
  FLOAT,
  UNFILTERABLE,
  DEPTH,
  CUBE,
  // the backend's shadow atlas, whatever the key holds
  SHADOW_ATLAS,
}

@(private)
GroupLayout :: enum {
  NONE,
  // albedo, metallic-roughness, normal, emissive
  MATERIAL,
  // normal, albedo, metallic-roughness, emissive, depth, shadow atlas, irradiance, prefilter,
  // BRDF LUT, environment
  LIGHTING,
  // input, original, normal, depth
  POST,
  SINGLE,
  PARTICLES,
}

@(private)
MAX_GROUP_TEXTURES :: 10
// distinct textures the particle pass draws with (pass_particles.odin)
@(private)
MAX_PARTICLE_TEXTURES :: 8

@(private)
GROUP_LAYOUTS := [GroupLayout][]TextureSlot {
  .NONE      = {},
  .MATERIAL  = {.FLOAT, .FLOAT, .FLOAT, .FLOAT},
  .LIGHTING  = {.FLOAT, .FLOAT, .FLOAT, .FLOAT, .DEPTH, .SHADOW_ATLAS, .CUBE, .CUBE, .FLOAT, .FLOAT},
  .POST      = {.FLOAT, .FLOAT, .FLOAT, .DEPTH},
  .SINGLE    = {.FLOAT},
  .PARTICLES = {.FLOAT, .FLOAT, .FLOAT, .FLOAT, .FLOAT, .FLOAT, .FLOAT, .FLOAT},
}

// Group 2: the uniforms of the draw or dispatch at a dynamic offset, then every sampler.
@(private)
UNIFORM_ALIGNMENT :: 256
@(private)
UNIFORM_CAPACITY :: 1 << 20

@(private)
layouts_init :: proc(b: ^Backend) {
  entries := make([dynamic]wgpu.BindGroupLayoutEntry, context.temp_allocator)
  for pass, p in SCENE_PASSES {
    clear(&entries)
    for buffer, i in pass.buffers {
      type: wgpu.BufferBindingType = .Storage if buffer in pass.writes else .ReadOnlyStorage
      append(&entries, wgpu.BindGroupLayoutEntry{binding = u32(i), visibility = pass.visibility, buffer = {type = type}})
    }
    b.scene_layouts[p] = wgpu.DeviceCreateBindGroupLayout(b.device, &{entryCount = len(entries), entries = raw_data(entries)})
  }
  for slots, l in GROUP_LAYOUTS {
    clear(&entries)
    for slot, i in slots {
      texture: wgpu.TextureBindingLayout
      switch slot {
      case .FLOAT:        texture = {sampleType = .Float, viewDimension = ._2D}
      case .UNFILTERABLE: texture = {sampleType = .UnfilterableFloat, viewDimension = ._2D}
      case .DEPTH:        texture = {sampleType = .Depth, viewDimension = ._2D}
      case .CUBE:         texture = {sampleType = .Float, viewDimension = .Cube}
      case .SHADOW_ATLAS: texture = {sampleType = .Depth, viewDimension = ._2DArray}
      }
      append(&entries, wgpu.BindGroupLayoutEntry{binding = u32(i), visibility = {.Vertex, .Fragment, .Compute}, texture = texture})
    }
    b.group_layouts[l] = wgpu.DeviceCreateBindGroupLayout(b.device, &{entryCount = len(entries), entries = raw_data(entries)})
  }
  clear(&entries)
  all_stages := wgpu.ShaderStageFlags{.Vertex, .Fragment, .Compute}
  append(&entries, wgpu.BindGroupLayoutEntry{binding = 0, visibility = all_stages, buffer = {type = .Uniform, hasDynamicOffset = true, minBindingSize = UNIFORM_ALIGNMENT}})
  for type in SamplerType {
    kind: wgpu.SamplerBindingType = .Comparison if type == .SHADOW_COMPARE else .Filtering
    append(&entries, wgpu.BindGroupLayoutEntry{binding = 1 + u32(type), visibility = all_stages, sampler = {type = kind}})
  }
  b.frame_layout = wgpu.DeviceCreateBindGroupLayout(b.device, &{entryCount = len(entries), entries = raw_data(entries)})
}

// The scene groups bind the table, mesh and backend buffers, which live as long as the backend.
@(private)
scene_groups_init :: proc(b: ^Backend) {
  entries := make([dynamic]wgpu.BindGroupEntry, context.temp_allocator)
  for pass, p in SCENE_PASSES {
    clear(&entries)
    for buffer, i in pass.buffers {
      buf := scene_buffer(b, buffer)
      append(&entries, wgpu.BindGroupEntry{binding = u32(i), buffer = buf, size = wgpu.BufferGetSize(buf)})
    }
    b.scene_groups[p] = wgpu.DeviceCreateBindGroup(b.device, &{layout = b.scene_layouts[p], entryCount = len(entries), entries = raw_data(entries)})
  }
  b.uniform_buffer = buffer_create(b, UNIFORM_CAPACITY, {.Uniform, .CopyDst})
  b.uniforms = make([]u8, UNIFORM_CAPACITY)
  clear(&entries)
  append(&entries, wgpu.BindGroupEntry{binding = 0, buffer = b.uniform_buffer, size = UNIFORM_ALIGNMENT})
  for sampler, type in b.samplers do append(&entries, wgpu.BindGroupEntry{binding = 1 + u32(type), sampler = sampler})
  b.frame_group = wgpu.DeviceCreateBindGroup(b.device, &{layout = b.frame_layout, entryCount = len(entries), entries = raw_data(entries)})
}

@(private = "file")
scene_buffer :: proc(b: ^Backend, buffer: SceneBuffer) -> wgpu.Buffer {
  switch buffer {
  case .VIEWS:          return b.table_buffers[.VIEWS]
  case .NODES:          return b.table_buffers[.NODES]
  case .MESHES:         return b.table_buffers[.MESHES]
  case .MATERIALS:      return b.table_buffers[.MATERIALS]
  case .BONES:          return b.table_buffers[.BONES]
  case .SKINNING:       return b.mesh_buffers[.SKINNING]
  case .VERTICES:       return b.mesh_buffers[.VERTEX]
  case .INDICES:        return b.mesh_buffers[.INDEX]
  case .EMITTERS:       return b.table_buffers[.EMITTERS]
  case .FORCEFIELDS:    return b.table_buffers[.FORCEFIELDS]
  case .PARTICLES:      return b.particle_buffer
  case .PARTICLE_ALIVE: return b.particle_alive_buffer
  case .LIGHTS:         return b.table_buffers[.LIGHTS]
  case .DEBUG_LINES:    return b.table_buffers[.DEBUG_LINES]
  case .BATCHES:        return b.table_buffers[.BATCHES]
  case .NODE_BATCH:     return b.table_buffers[.NODE_BATCH]
  }
  return nil
}

// uniform stages value for the next draw or dispatch: bind_frame with the offset it returns.
@(private)
uniform :: proc(b: ^Backend, value: ^$T) -> u32 {
  #assert(size_of(T) <= UNIFORM_ALIGNMENT)
  offset := b.uniform_cursor
  assert(offset + UNIFORM_ALIGNMENT <= UNIFORM_CAPACITY, "uniform ring full")
  mem.copy(&b.uniforms[offset], value, size_of(T))
  b.uniform_cursor += UNIFORM_ALIGNMENT
  return u32(offset)
}

@(private)
pipeline_layout :: proc(b: ^Backend, scene: ScenePass, textures: GroupLayout) -> wgpu.PipelineLayout {
  layouts := [3]wgpu.BindGroupLayout{b.scene_layouts[scene], b.group_layouts[textures], b.frame_layout}
  return wgpu.DeviceCreatePipelineLayout(b.device, &{bindGroupLayoutCount = len(layouts), bindGroupLayouts = raw_data(layouts[:])})
}

@(private)
shader_module :: proc(b: ^Backend, source: string) -> wgpu.ShaderModule {
  wgsl := wgpu.ShaderSourceWGSL{chain = {sType = .ShaderSourceWGSL}, code = source}
  return wgpu.DeviceCreateShaderModule(b.device, &{nextInChain = &wgsl.chain})
}

// Front faces wind counter-clockwise on screen, as in Vulkan: the vertex shaders flip y on
// output (clip_output in common.wgsl), so primitives land on the same pixels in the same order.
@(private)
FRONT_FACE :: wgpu.FrontFace.CCW

@(private)
BLEND_ALPHA := wgpu.BlendState {
  color = {operation = .Add, srcFactor = .SrcAlpha, dstFactor = .OneMinusSrcAlpha},
  alpha = {operation = .Add, srcFactor = .SrcAlpha, dstFactor = .OneMinusSrcAlpha},
}
@(private)
BLEND_ADDITIVE := wgpu.BlendState {
  color = {operation = .Add, srcFactor = .One, dstFactor = .One},
  alpha = {operation = .Add, srcFactor = .One, dstFactor = .One},
}

// GraphicsPipelineDesc is everything that varies between the graphics pipelines. Entry points
// are vs_main and fs_main; `fragment` false draws depth only. `blend` applies to every target.
@(private)
GraphicsPipelineDesc :: struct {
  source:         string,
  constants:      []wgpu.ConstantEntry,
  scene:          ScenePass,
  textures:       GroupLayout,
  vertex_buffers: []wgpu.VertexBufferLayout,
  topology:       wgpu.PrimitiveTopology,
  cull:           wgpu.CullMode,
  color_formats:  []wgpu.TextureFormat,
  blend:          ^wgpu.BlendState,
  depth:          bool,
  depth_write:    bool,
  depth_compare:  wgpu.CompareFunction,
  slope_bias:     f32,
  fragment:       bool,
}

@(private)
graphics_pipeline :: proc(b: ^Backend, desc: GraphicsPipelineDesc) -> wgpu.RenderPipeline {
  module := shader_module(b, desc.source)
  defer wgpu.ShaderModuleRelease(module)
  layout := pipeline_layout(b, desc.scene, desc.textures)
  defer wgpu.PipelineLayoutRelease(layout)
  targets := make([]wgpu.ColorTargetState, len(desc.color_formats), context.temp_allocator)
  for format, i in desc.color_formats {
    targets[i] = {format = format, blend = desc.blend, writeMask = wgpu.ColorWriteMaskFlags_All}
  }
  depth := wgpu.DepthStencilState {
    format              = .Depth32Float,
    depthWriteEnabled   = .True if desc.depth_write else .False,
    depthCompare        = desc.depth_compare,
    stencilFront        = {compare = .Always},
    stencilBack         = {compare = .Always},
    depthBiasSlopeScale = desc.slope_bias,
  }
  fragment := wgpu.FragmentState {
    module        = module,
    entryPoint    = "fs_main",
    constantCount = len(desc.constants),
    constants     = raw_data(desc.constants),
    targetCount   = len(targets),
    targets       = raw_data(targets),
  }
  pipeline := wgpu.DeviceCreateRenderPipeline(
    b.device,
    &{
      layout = layout,
      vertex = {
        module = module,
        entryPoint = "vs_main",
        constantCount = len(desc.constants),
        constants = raw_data(desc.constants),
        bufferCount = len(desc.vertex_buffers),
        buffers = raw_data(desc.vertex_buffers),
      },
      primitive = {topology = desc.topology, frontFace = FRONT_FACE, cullMode = desc.cull},
      depthStencil = &depth if desc.depth else nil,
      multisample = {count = 1, mask = 0xFFFFFFFF},
      fragment = &fragment if desc.fragment else nil,
    },
  )
  if pipeline == nil do log.errorf("Render pipeline creation failed")
  return pipeline
}

@(private)
compute_pipeline :: proc(b: ^Backend, source: string, scene: ScenePass, textures: GroupLayout, extra: wgpu.BindGroupLayout = nil) -> wgpu.ComputePipeline {
  module := shader_module(b, source)
  defer wgpu.ShaderModuleRelease(module)
  // compute passes with storage textures bind them in group 3
  layouts := [4]wgpu.BindGroupLayout{b.scene_layouts[scene], b.group_layouts[textures], b.frame_layout, extra}
  count: uint = 4 if extra != nil else 3
  layout := wgpu.DeviceCreatePipelineLayout(b.device, &{bindGroupLayoutCount = count, bindGroupLayouts = raw_data(layouts[:])})
  defer wgpu.PipelineLayoutRelease(layout)
  pipeline := wgpu.DeviceCreateComputePipeline(b.device, &{layout = layout, compute = {module = module, entryPoint = "main"}})
  if pipeline == nil do log.errorf("Compute pipeline creation failed")
  return pipeline
}

// The vertex stream of mesh draws: the vertex, then the node index of the draw (instance step,
// from a draw list's instance array; WebGPU indirect draws have no first instance).
@(private)
VERTEX_ATTRIBUTES := [?]wgpu.VertexAttribute {
  {format = .Float32x3, offset = u64(offset_of(rhi.Vertex, position)), shaderLocation = 0},
  {format = .Float32x3, offset = u64(offset_of(rhi.Vertex, normal)), shaderLocation = 1},
  {format = .Float32x4, offset = u64(offset_of(rhi.Vertex, color)), shaderLocation = 2},
  {format = .Float32x2, offset = u64(offset_of(rhi.Vertex, uv)), shaderLocation = 3},
  {format = .Float32x4, offset = u64(offset_of(rhi.Vertex, tangent)), shaderLocation = 4},
}
@(private)
NODE_ATTRIBUTE := wgpu.VertexAttribute{format = .Uint32, offset = 0, shaderLocation = 5}

@(private)
mesh_vertex_buffers :: proc() -> []wgpu.VertexBufferLayout {
  layouts := make([]wgpu.VertexBufferLayout, 2, context.temp_allocator)
  layouts[0] = {stepMode = .Vertex, arrayStride = size_of(rhi.Vertex), attributeCount = len(VERTEX_ATTRIBUTES), attributes = raw_data(VERTEX_ATTRIBUTES[:])}
  layouts[1] = {stepMode = .Instance, arrayStride = size_of(u32), attributeCount = 1, attributes = &NODE_ATTRIBUTE}
  return layouts
}

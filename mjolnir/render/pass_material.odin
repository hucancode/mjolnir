package render

import "rhi"

// Each MaterialType's pipeline is built against the targets of its pass; .CUSTOM has a
// pipeline per user shader (material_shader_create), drawn after the built-in forward types.
@(private)
MaterialPass :: enum {
  // writes the G-buffer and depth, lit by the lighting pass
  GBUFFER,
  // alpha-blends into the lit image, depth-tested; only opaque custom shaders write depth
  FORWARD,
}

@(private = "file")
MATERIAL_PASS_TARGETS := [MaterialPass][]CameraImage {
  .GBUFFER = {.NORMAL, .ALBEDO, .METALLIC_ROUGHNESS, .EMISSIVE},
  .FORWARD = {.FINAL_IMAGE},
}

@(private = "file")
MATERIAL_PASS_TYPES := [MaterialPass][2]MaterialType {
  .GBUFFER = {MaterialType(0), FIRST_FORWARD_TYPE},
  .FORWARD = {FIRST_FORWARD_TYPE, .CUSTOM},
}

// the draw list keys (material_list) of the built-in types and then the custom shaders
@(private = "file")
MATERIAL_LISTS := [DRAW_LISTS]u32{0, 1, 2, 3, 4, 5, 6, 7}
#assert(DRAW_LISTS == 8)

// The formats a material pass draws into, for the pipelines of anything drawn in it.
@(private)
material_pass_formats :: proc(pass: MaterialPass) -> []TextureFormat {
  targets := MATERIAL_PASS_TARGETS[pass]
  formats := make([]TextureFormat, len(targets), context.temp_allocator)
  images := CAMERA_IMAGES
  for a, i in targets do formats[i] = images[a].format
  return formats
}

// The depth the pipelines of a pass test: the G-buffer writes it, the forward pass reads, unless
// the pipeline is opaque (a custom shader without blending), which writes it too.
@(private)
material_pass_depth :: proc(pass: MaterialPass, opaque := false) -> rhi.DepthState {
  return {write = pass == .GBUFFER || opaque, compare = .LESS_EQUAL}
}

// The vertex stream of mesh draws: the vertex, then on a device that cannot tag draws with a
// first instance (WebGPU) the node index of the draw, one per instance, from a draw list.
@(private)
mesh_vertex_streams :: proc(self: ^Renderer, position_only := false) -> []rhi.VertexBuffer {
  @(static) all := [?]rhi.VertexAttribute {
    {location = 0, format = .F32X3, offset = u32(offset_of(Vertex, position))},
    {location = 1, format = .F32X3, offset = u32(offset_of(Vertex, normal))},
    {location = 2, format = .F32X4, offset = u32(offset_of(Vertex, color))},
    {location = 3, format = .F32X2, offset = u32(offset_of(Vertex, uv))},
    {location = 4, format = .F32X4, offset = u32(offset_of(Vertex, tangent))},
  }
  @(static) node := [?]rhi.VertexAttribute{{location = 5, format = .U32, offset = 0}}
  streams := make([dynamic]rhi.VertexBuffer, context.temp_allocator)
  append(&streams, rhi.VertexBuffer{stride = size_of(Vertex), attributes = all[:1] if position_only else all[:]})
  when !BINDLESS do append(&streams, rhi.VertexBuffer{stride = size_of(u32), step = .INSTANCE, attributes = node[:]})
  return streams[:]
}

@(private)
material_init :: proc(self: ^Renderer) -> bool {
  common := wgsl("shader/wgpu/common.wgsl")
  mesh := wgsl_join(common, wgsl("shader/wgpu/mesh.wgsl"))
  pulled := wgsl_join(common, wgsl("shader/wgpu/mesh_pulled.wgsl"))
  sources := #partial [MaterialType]rhi.ShaderSource {
    .PBR = {
      spirv = {vert = spirv("shader/vulkan/gbuffer/vert.spv"), frag = spirv("shader/vulkan/gbuffer/frag.spv")},
      wgsl = wgsl_join(mesh, wgsl("shader/wgpu/gbuffer.wgsl")),
    },
    .TRANSPARENT = {
      spirv = {vert = spirv("shader/vulkan/gbuffer/vert.spv"), frag = spirv("shader/vulkan/transparent/frag.spv")},
      wgsl = wgsl_join(mesh, wgsl("shader/wgpu/transparent.wgsl")),
    },
    // no line polygon mode and no primitive index in core WebGPU: the shader pulls vertices
    .WIREFRAME = {
      spirv = {vert = spirv("shader/vulkan/gbuffer/vert.spv"), frag = spirv("shader/vulkan/wireframe/frag.spv")},
      wgsl = wgsl_join(pulled, wgsl("shader/wgpu/wireframe.wgsl")),
    },
    .RANDOM_COLOR = {
      spirv = {vert = spirv("shader/vulkan/gbuffer/vert.spv"), frag = spirv("shader/vulkan/random_color/frag.spv")},
      wgsl = wgsl_join(pulled, wgsl("shader/wgpu/random_color.wgsl")),
    },
    .SPRITE = {
      spirv = {vert = spirv("shader/vulkan/sprite/vert.spv"), frag = spirv("shader/vulkan/sprite/frag.spv")},
      wgsl = wgsl_join(common, wgsl("shader/wgpu/sprite.wgsl")),
    },
  }
  cull := #partial [MaterialType]rhi.CullMode{.PBR = .BACK, .TRANSPARENT = .BACK, .WIREFRAME = .NONE, .RANDOM_COLOR = .BACK, .SPRITE = .NONE}
  for pass in MaterialPass {
    types := MATERIAL_PASS_TYPES[pass]
    for type in types[0] ..< types[1] {
      desc := rhi.GraphicsPipelineDesc {
        shader        = sources[type],
        layout        = pipeline_layout(self, .MESH, .MATERIAL),
        vertex        = mesh_vertex_streams(self),
        topology      = .LINE_LIST if type == .WIREFRAME && !BINDLESS else .TRIANGLE_LIST,
        cull          = cull[type],
        color_formats = material_pass_formats(pass),
        blend         = .ALPHA if pass == .FORWARD else .NONE,
        depth         = material_pass_depth(pass),
        wireframe     = type == .WIREFRAME,
      }
      self.material_pipelines[pass][int(type)] = dev.graphics_pipeline_create(&self.gpu, desc) or_return
    }
  }
  return true
}

// The forward pass draws particles first. A camera draws nothing until a cull has written its
// lists (Vulkan; WebGPU culls the frame it draws).
@(private)
material_record :: proc(self: ^Renderer, cmd: rhi.CommandList, f: u32, cam: u32, pass: MaterialPass) {
  images := &self.camera_targets[cam].images
  targets := MATERIAL_PASS_TARGETS[pass]
  colors := make([]rhi.ColorTarget, len(targets), context.temp_allocator)
  load: rhi.LoadOp = .CLEAR if pass == .GBUFFER else .LOAD
  for a, i in targets do colors[i] = {texture = images[a][f], load = load, clear = {0, 0, 0, 1}}
  depth := rhi.DepthTarget{texture = images[.DEPTH][f], load = load, clear = 1, store = true}
  dev.cmd_begin_pass(&self.gpu, cmd, {colors = colors, depth = depth})
  if pass == .FORWARD do particles_draw(self, cmd, f, cam)
  types := MATERIAL_PASS_TYPES[pass]
  keys := make([dynamic]u32, context.temp_allocator)
  pipelines := make([dynamic]rhi.Pipeline, context.temp_allocator)
  append(&keys, ..MATERIAL_LISTS[types[0]:types[1]])
  append(&pipelines, ..self.material_pipelines[pass][int(types[0]):int(types[1])])
  if pass == .FORWARD {
    for p, i in self.custom_material_pipelines {
      if p == 0 do continue
      append(&keys, MATERIAL_LISTS[int(MaterialType.CUSTOM) + i])
      append(&pipelines, p)
    }
  }
  push := MeshPush{cam}
  pipeline_bind(self, cmd, pipelines[0], .MESH, f, &push, .MATERIAL)
  when BINDLESS {
    ready, slot := camera_ready(self, cam), camera_slot(cam) + f
  } else {
    ready, slot := true, camera_next_slot(cam, f)
  }
  if ready {
    mesh_buffers_bind(self, cmd)
    draw_list_draw(self, cmd, slot, 0, keys[:], pipelines[:], f)
  }
  dev.cmd_end_pass(&self.gpu, cmd)
}

// What every mesh draw reads besides the scene: the camera it draws for.
@(private = "file")
MeshPush :: struct {
  camera_index: u32,
}

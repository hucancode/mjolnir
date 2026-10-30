package render

import "../geometry"

import "rhi"

// Each MaterialType's pipeline is built against the targets of its pass; your shaders
// (material_shader_create) are forward types after the built-in ones.
@(private)
MaterialPass :: enum {
  // writes the G-buffer and depth, lit by the lighting pass
  GBUFFER,
  // alpha-blends into the lit image, depth-tested; only sprites and opaque custom shaders write depth
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
  .FORWARD = {FIRST_FORWARD_TYPE, MaterialType(DRAW_LISTS)},
}

// How a material shader draws, built-in or yours (material_shader_create): its source, face
// culling and blending, whether it writes depth in the forward pass (`opaque`), and whether it
// draws edges (`wireframe`). The pass is its type's (MATERIAL_PASS_TYPES).
@(private)
MaterialShaderDesc :: struct {
  source:    rhi.ShaderSource,
  cull:      rhi.CullMode,
  blend:     rhi.BlendMode,
  opaque:    bool,
  wireframe: bool,
  // pulls its vertices from the index buffer where there are no line polygons nor primitive
  // indices (WebGPU): its draws are non-indexed
  pulled:    bool,
}

// The built-in material types.
@(private)
material_types :: proc() -> [MaterialType]MaterialShaderDesc {
  return #partial {
    .PBR          = {source = shader_source("gbuffer"), cull = .BACK},
    .TRANSPARENT  = {source = shader_source("transparent"), cull = .BACK, blend = .ALPHA},
    .WIREFRAME    = {source = shader_source("wireframe"), cull = .NONE, blend = .ALPHA, wireframe = true, pulled = true},
    .RANDOM_COLOR = {source = shader_source("random_color"), cull = .BACK, blend = .ALPHA, pulled = true},
    // cut-out pixels: opaque, depth-ordered
    .SPRITE       = {source = shader_source("sprite"), cull = .NONE, blend = .ALPHA, opaque = true},
  }
}

// The pipeline of a material shader drawn in `pass`.
@(private)
material_pipeline_create :: proc(self: ^Renderer, pass: MaterialPass, desc: MaterialShaderDesc) -> (rhi.Pipeline, bool) {
  return dev.graphics_pipeline_create(
    &self.gpu,
    {
      shader = desc.source,
      layout = pipeline_layout(self, .MESH, .MATERIAL),
      vertex = mesh_vertex_streams(),
      topology = .LINE_LIST if desc.wireframe && !BINDLESS else .TRIANGLE_LIST,
      cull = desc.cull,
      color_formats = material_pass_formats(pass),
      blend = desc.blend,
      depth = material_pass_depth(pass, desc.opaque),
      wireframe = desc.wireframe,
    },
  )
}

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
// the pipeline is opaque (a sprite, whose cut-out pixels are, or a custom shader without
// blending), which writes it too.
@(private)
material_pass_depth :: proc(pass: MaterialPass, opaque := false) -> rhi.DepthState {
  return {write = pass == .GBUFFER || opaque, compare = .LESS_EQUAL}
}

// The vertex stream of mesh draws: the vertex, then on a device that cannot tag draws with a
// first instance (WebGPU) the node index of the draw, one per instance, from a draw list.
@(private)
mesh_vertex_streams :: proc(position_only := false) -> []rhi.VertexBuffer {
  @(static) all := [?]rhi.VertexAttribute {
    {location = 0, format = .F32X3, offset = u32(offset_of(geometry.Vertex, position))},
    {location = 1, format = .F32X3, offset = u32(offset_of(geometry.Vertex, normal))},
    {location = 2, format = .F32X4, offset = u32(offset_of(geometry.Vertex, color))},
    {location = 3, format = .F32X2, offset = u32(offset_of(geometry.Vertex, uv))},
    {location = 4, format = .F32X4, offset = u32(offset_of(geometry.Vertex, tangent))},
  }
  @(static) node := [?]rhi.VertexAttribute{{location = 5, format = .U32, offset = 0}}
  streams := make([dynamic]rhi.VertexBuffer, context.temp_allocator)
  append(&streams, rhi.VertexBuffer{stride = size_of(geometry.Vertex), attributes = all[:1] if position_only else all[:]})
  when !BINDLESS do append(&streams, rhi.VertexBuffer{stride = size_of(u32), step = .INSTANCE, attributes = node[:]})
  return streams[:]
}

@(private)
material_init :: proc(self: ^Renderer) -> bool {
  types := material_types()
  for pass in MaterialPass {
    range := MATERIAL_PASS_TYPES[pass]
    for type in range[0] ..< min(range[1], MaterialType(len(MaterialType))) {
      self.material_pipelines[pass][int(type)] = material_pipeline_create(self, pass, types[type]) or_return
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
  if pass == .FORWARD {
    gpu_draws_record(self, cmd, f, cam)
    particles_draw(self, cmd, f, cam)
  }
  types := MATERIAL_PASS_TYPES[pass]
  // a type's draw list key (material_list) is the type; a free shader's has no pipeline
  keys: [DRAW_LISTS]u32
  pipelines: [DRAW_LISTS]rhi.Pipeline
  count := 0
  for t in types[0] ..< types[1] {
    p := self.material_pipelines[pass][int(t)]
    if p == 0 do continue
    keys[count], pipelines[count] = u32(t), p
    count += 1
  }
  // every mesh draw reads the camera it draws for
  camera_index := cam
  pipeline_bind(self, cmd, pipelines[0], .MESH, f, &camera_index, .MATERIAL)
  when BINDLESS {
    ready, slot := camera_ready(self, cam), camera_slot(cam) + f
  } else {
    ready, slot := true, camera_next_slot(cam, f)
  }
  if ready {
    mesh_buffers_bind(self, cmd)
    draw_list_draw(self, cmd, slot, 0, keys[:count], pipelines[:count], f)
  }
  dev.cmd_end_pass(&self.gpu, cmd)
}

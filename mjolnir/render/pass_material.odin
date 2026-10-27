package render

import "rhi"

// Each MaterialType's pipeline is built against the targets of its pass; .CUSTOM has a
// pipeline per user shader (material_shader_create), drawn after the built-in forward types.
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
  .FORWARD = {FIRST_FORWARD_TYPE, .CUSTOM},
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
  sources := #partial [MaterialType]rhi.ShaderSource {
    .PBR          = shader_source("gbuffer"),
    .TRANSPARENT  = shader_source("transparent"),
    // no line polygon mode and no primitive index in core WebGPU: the shader pulls vertices
    .WIREFRAME    = shader_source("wireframe"),
    .RANDOM_COLOR = shader_source("random_color"),
    .SPRITE       = shader_source("sprite"),
  }
  cull := #partial [MaterialType]rhi.CullMode{.PBR = .BACK, .TRANSPARENT = .BACK, .WIREFRAME = .NONE, .RANDOM_COLOR = .BACK, .SPRITE = .NONE}
  for pass in MaterialPass {
    types := MATERIAL_PASS_TYPES[pass]
    for type in types[0] ..< types[1] {
      desc := rhi.GraphicsPipelineDesc {
        shader        = sources[type],
        layout        = pipeline_layout(self, .MESH, .MATERIAL),
        vertex        = mesh_vertex_streams(),
        topology      = .LINE_LIST if type == .WIREFRAME && !BINDLESS else .TRIANGLE_LIST,
        cull          = cull[type],
        color_formats = material_pass_formats(pass),
        blend         = .ALPHA if pass == .FORWARD else .NONE,
        depth         = material_pass_depth(pass, opaque = type == .SPRITE),
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
  if pass == .FORWARD {
    gpu_draws_record(self, cmd, f, cam)
    particles_draw(self, cmd, f, cam)
  }
  types := MATERIAL_PASS_TYPES[pass]
  keys := make([dynamic]u32, context.temp_allocator)
  pipelines := make([dynamic]rhi.Pipeline, context.temp_allocator)
  // a type's draw list key (material_list) is the type; custom shader i's is CUSTOM + i
  for t in types[0] ..< types[1] do append(&keys, u32(t))
  append(&pipelines, ..self.material_pipelines[pass][int(types[0]):int(types[1])])
  if pass == .FORWARD {
    for p, i in self.custom_material_pipelines {
      if p == 0 do continue
      append(&keys, u32(MaterialType.CUSTOM) + u32(i))
      append(&pipelines, p)
    }
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
    draw_list_draw(self, cmd, slot, 0, keys[:], pipelines[:], f)
  }
  dev.cmd_end_pass(&self.gpu, cmd)
}

package render

import "rhi"

// Shadow maps are the layers of one depth atlas per frame in flight, a layer per shadow view,
// grown by doubling up to MAX_SHADOW_VIEWS. Where the device renders layers together (Vulkan)
// one cull dispatch tests every node against every shadow view into one draw list, and one
// layered draw renders every view; the cull tags each draw first_instance = node | view << 16.
// Elsewhere (WebGPU) each view renders its own pass from its own list. There is no depth
// clamp in core WebGPU: a caster behind a directional cascade's near plane is clipped.
#assert(MAX_NODES_IN_SCENE <= 1 << 16)
#assert(MAX_VIEWS < 1 << 16)

@(private)
MIN_ATLAS_LAYERS :: 2
@(private = "file")
SHADOW_SLOPE_BIAS :: 1.5

@(private)
ShadowState :: struct {
  pipeline: rhi.Pipeline,
}

@(private)
atlas_make :: proc(r: ^Renderer, f: int, layers: u32) -> bool {
  desc := TextureDesc {
    extent = {SHADOW_MAP_SIZE, SHADOW_MAP_SIZE},
    format = .D32F,
    usage  = {.DEPTH_TARGET, .SAMPLED},
    layers = layers,
  }
  atlas := allocate_texture(r, desc, target = true) or_return
  if old := r.res.atlas[f]; old != 0 do destroy_texture(r, old)
  r.res.atlas[f], r.res.atlas_layers[f] = atlas, layers
  return true
}

// Doubles up to MAX_SHADOW_VIEWS and rebinds. Call once the frame's previous submission is done.
@(private)
shadow_atlas_reserve :: proc(r: ^Renderer, f: u32, layers: u32) -> bool {
  have := r.res.atlas_layers[f]
  if layers <= have do return true
  atlas_make(r, int(f), max(layers, min(have * 2, MAX_SHADOW_VIEWS))) or_return
  if r.res.caps.bindless do return scene_group_make(r, int(f))
  texture_groups_clear(r)
  return true
}

@(private)
shadow_init :: proc(r: ^Renderer) -> bool {
  caps := r.res.caps
  position := [?]rhi.VertexAttribute{{location = 0, format = .F32X3, offset = u32(offset_of(Vertex, position))}}
  node := [?]rhi.VertexAttribute{{location = 5, format = .U32, offset = 0}}
  streams := [?]rhi.VertexBuffer{{stride = size_of(Vertex), attributes = position[:]}, {stride = size_of(u32), step = .INSTANCE, attributes = node[:]}}
  common := wgsl("shader/wgpu/common.wgsl")
  r.shadow.pipeline = dev.graphics_pipeline_create(
    &r.gpu,
    {
      shader = {spirv = {vert = spirv("shader/vulkan/shadow/vert.spv")}, wgsl = wgsl_join(common, wgsl("shader/wgpu/shadow.wgsl"))},
      layout = pipeline_layout(r, .SHADOW),
      // WebGPU draws take their node from an instance stream
      vertex = streams[:1 if caps.bindless else 2],
      cull = .BACK,
      depth = rhi.DepthState{write = true, compare = .LESS_EQUAL, clamp = true, slope_bias = SHADOW_SLOPE_BIAS},
    },
  ) or_return
  return true
}

// The atlas of frame `f` is lit from whole, so every layer leaves UNDEFINED even when nothing
// renders. Culls (Vulkan) and renders the shadow views into it.
@(private)
shadow_record :: proc(r: ^Renderer, cmd: rhi.CommandList, f: u32) {
  atlas := r.res.atlas[f]
  textures := [1]TextureHandle{atlas}
  views := r.shadow_view_count
  layered := r.res.caps.layered_rendering && views > 0
  // with the layered path's clear of the shadow lists, last frame's draws done with them
  if layered do barrier_discard(r, cmd, textures[:], .INDIRECT_TO_FILL)
  else do barrier_discard(r, cmd, textures[:])
  if views == 0 do return
  types := [1]MaterialType{.PBR}
  pipelines := [1]rhi.Pipeline{r.shadow.pipeline}
  if layered {
    draw_lists_clear(r, cmd, r.shadow_draw_list)
    barrier(r, cmd, .FILL_TO_CULL)
    cull_compacted(r, cmd, f, SHADOW_VIEW_BASE, views)
    barrier(r, cmd, .CULL_TO_INDIRECT)
    dev.cmd_begin_pass(&r.gpu, cmd, {depth = rhi.DepthTarget{texture = atlas, load = .CLEAR, clear = 1, store = true}, layer_count = views})
    mesh_buffers_bind(r, cmd)
    dev.cmd_bind_pipeline(&r.gpu, cmd, r.shadow.pipeline)
    scene_bind(r, cmd, .SHADOW, f)
    draw_list_draw(r, cmd, r.shadow_draw_list, 0, types[:], pipelines[:], f, false)
    dev.cmd_end_pass(&r.gpu, cmd)
    barrier(r, cmd, .SHADOW_TO_LIGHTING)
    return
  }
  for v in 0 ..< views {
    dev.cmd_begin_pass(&r.gpu, cmd, {depth = rhi.DepthTarget{texture = atlas, layer = v, load = .CLEAR, clear = 1, store = true}})
    view := u32(SHADOW_VIEW_BASE) + v
    pipeline_bind(r, cmd, r.shadow.pipeline, .SHADOW, f, &view, .NONE)
    mesh_buffers_bind(r, cmd)
    draw_list_draw(r, cmd, r.shadow_draw_list, v, types[:], pipelines[:], f, false)
    dev.cmd_end_pass(&r.gpu, cmd)
  }
}

// The vertex and index streams every mesh draw reads.
@(private)
mesh_buffers_bind :: proc(r: ^Renderer, cmd: rhi.CommandList) {
  dev.cmd_bind_vertex(&r.gpu, cmd, 0, r.res.vertices, 0)
  dev.cmd_bind_index(&r.gpu, cmd, r.res.indices, 0)
}

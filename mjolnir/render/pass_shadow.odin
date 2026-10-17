package render

import "rhi"

// Shadow maps live in one depth atlas per frame in flight, a map per shadow view, grown by
// doubling up to MAX_SHADOW_VIEWS. Where the device renders layers together (Vulkan) the atlas
// is an array, a layer per view: one cull dispatch tests every node against every shadow view
// into one draw list, and one layered draw renders every view; the cull tags each draw
// first_instance = node | view << 16. Elsewhere (WebGPU) the atlas is one 2D texture of
// SHADOW_MAP_SIZE tiles, ATLAS_COLUMNS to a row, a tile per view (shadow_tile): one pass
// renders every view, each into its tile's viewport from its own list. There is no depth
// clamp in core WebGPU: a caster behind a directional cascade's near plane is clipped.
#assert(MAX_SLOTS <= 1 << 16)
#assert(MAX_VIEWS < 1 << 16)

@(private)
MIN_ATLAS_LAYERS :: 2
// tiles to a row of the 2D atlas: 16 * SHADOW_MAP_SIZE is WebGPU's least maxTextureDimension2D
@(private)
ATLAS_COLUMNS :: 16
#assert(ATLAS_COLUMNS * SHADOW_MAP_SIZE <= 8192)
@(private = "file")
SHADOW_SLOPE_BIAS :: 1.5

// The texel rectangle (x, y, width, height) of view `layer`'s map in a 2D atlas of `layers` tiles.
@(private)
shadow_tile :: proc(layer, layers: u32) -> [4]u32 {
  cols := min(layers, ATLAS_COLUMNS)
  return {layer % cols * SHADOW_MAP_SIZE, layer / cols * SHADOW_MAP_SIZE, SHADOW_MAP_SIZE, SHADOW_MAP_SIZE}
}

@(private)
atlas_make :: proc(self: ^Renderer, f: int, layers: u32) -> bool {
  desc := TextureDesc {
    extent = {SHADOW_MAP_SIZE, SHADOW_MAP_SIZE},
    format = .D32F,
    usage  = {.DEPTH_TARGET, .SAMPLED},
    layers = layers,
  }
  when !LAYERED_RENDERING {
    cols := min(layers, ATLAS_COLUMNS)
    desc.extent = {cols * SHADOW_MAP_SIZE, (layers + cols - 1) / cols * SHADOW_MAP_SIZE}
    desc.layers = 1
  }
  atlas := allocate_texture(self, desc, target = true) or_return
  if old := self.atlas[f]; old != 0 do texture_destroy(self, old)
  self.atlas[f], self.atlas_layers[f] = atlas, layers
  return true
}

// Doubles up to MAX_SHADOW_VIEWS and rebinds. Call once the frame's previous submission is done.
@(private)
shadow_atlas_reserve :: proc(self: ^Renderer, f: u32, layers: u32) -> bool {
  have := self.atlas_layers[f]
  if layers <= have do return true
  atlas_make(self, int(f), max(layers, min(have * 2, MAX_SHADOW_VIEWS))) or_return
  when BINDLESS {
    return scene_group_make(self, int(f))
  } else {
    groups_clear(self)
    return true
  }
}

@(private)
shadow_init :: proc(self: ^Renderer) -> bool {
  position := [?]rhi.VertexAttribute{{location = 0, format = .F32X3, offset = u32(offset_of(Vertex, position))}}
  node := [?]rhi.VertexAttribute{{location = 5, format = .U32, offset = 0}}
  streams := [?]rhi.VertexBuffer{{stride = size_of(Vertex), attributes = position[:]}, {stride = size_of(u32), step = .INSTANCE, attributes = node[:]}}
  common := wgsl("shader/wgpu/common.wgsl")
  self.shadow_pipeline = dev.graphics_pipeline_create(
    &self.gpu,
    {
      shader = {spirv = {vert = spirv("shader/vulkan/shadow/vert.spv")}, wgsl = wgsl_join(common, wgsl("shader/wgpu/shadow.wgsl"))},
      layout = pipeline_layout(self, .SHADOW),
      // WebGPU draws take their node from an instance stream
      vertex = streams[:1 if BINDLESS else 2],
      cull = .BACK,
      depth = rhi.DepthState{write = true, compare = .LESS_EQUAL, clamp = true, slope_bias = SHADOW_SLOPE_BIAS},
    },
  ) or_return
  return true
}

// The atlas of frame `f` is lit from whole, so every layer leaves UNDEFINED even when nothing
// renders. Culls (Vulkan) and renders the shadow views into it.
@(private)
shadow_record :: proc(self: ^Renderer, cmd: rhi.CommandList, f: u32) {
  atlas := self.atlas[f]
  textures := [1]TextureHandle{atlas}
  views := self.shadow_view_count
  draw_list := SHADOW_DRAW_SLOT_BASE + f
  types := [1]u32{u32(MaterialType.PBR)}
  pipelines := [1]rhi.Pipeline{self.shadow_pipeline}
  when LAYERED_RENDERING {
    // with the clear of the shadow lists, last frame's draws done with them
    if views == 0 {
      barrier_discard(self, cmd, textures[:])
      return
    }
    barrier_discard(self, cmd, textures[:], .INDIRECT_TO_FILL)
    draw_lists_clear(self, cmd, draw_list)
    barrier(self, cmd, .FILL_TO_CULL)
    cull_compacted(self, cmd, f, SHADOW_VIEW_BASE, views)
    barrier(self, cmd, .CULL_TO_INDIRECT)
    dev.cmd_begin_pass(&self.gpu, cmd, {depth = rhi.DepthTarget{texture = atlas, load = .CLEAR, clear = 1, store = true}, layer_count = views})
    mesh_buffers_bind(self, cmd)
    dev.cmd_bind_pipeline(&self.gpu, cmd, self.shadow_pipeline)
    scene_bind(self, cmd, .SHADOW, f)
    draw_list_draw(self, cmd, draw_list, 0, types[:], pipelines[:], f, false)
    dev.cmd_end_pass(&self.gpu, cmd)
    barrier(self, cmd, .SHADOW_TO_LIGHTING)
  } else {
    barrier_discard(self, cmd, textures[:])
    if views == 0 do return
    dev.cmd_begin_pass(&self.gpu, cmd, {depth = rhi.DepthTarget{texture = atlas, load = .CLEAR, clear = 1, store = true}})
    push := ShadowPush{SHADOW_VIEW_BASE}
    pipeline_bind(self, cmd, self.shadow_pipeline, .SHADOW, f, &push, .NONE)
    mesh_buffers_bind(self, cmd)
    for v in 0 ..< views {
      tile := shadow_tile(v, self.atlas_layers[f])
      dev.cmd_set_viewport(&self.gpu, cmd, tile.x, tile.y, tile.z, tile.w)
      dev.cmd_set_scissor(&self.gpu, cmd, tile.x, tile.y, tile.z, tile.w)
      push.view_index = SHADOW_VIEW_BASE + v
      dev.cmd_push(&self.gpu, cmd, &push, size_of(push))
      draw_list_draw(self, cmd, draw_list, v, types[:], pipelines[:], f, false)
    }
    dev.cmd_end_pass(&self.gpu, cmd)
  }
}

// The vertex and index streams every mesh draw reads.
@(private)
mesh_buffers_bind :: proc(self: ^Renderer, cmd: rhi.CommandList) {
  dev.cmd_bind_vertex(&self.gpu, cmd, 0, mesh_buffer(self, .VERTEX), 0)
  dev.cmd_bind_index(&self.gpu, cmd, mesh_buffer(self, .INDEX), 0)
}

// The shadow view a batched shadow draw renders (the bindless path reads it per draw).
@(private = "file")
ShadowPush :: struct {
  view_index: u32,
}

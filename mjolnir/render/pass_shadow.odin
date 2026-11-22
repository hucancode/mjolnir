package render

import "rhi"

// Shadow maps live in one depth atlas, a map per shadow view, grown by
// doubling up to Renderer.max_shadow_views. Where the device renders layers together (Vulkan) the atlas
// is an array, a layer per view: one cull dispatch tests every node against every shadow view
// into one draw list, and one layered draw renders every view; the cull tags each draw
// first_instance = node | (view - SHADOW_VIEW_BASE) << 24 (TABLE_CEILINGS[.NODES]). Elsewhere (WebGPU) the atlas is one 2D texture of
// SHADOW_MAP_SIZE tiles, ATLAS_COLUMNS to a row, a tile per view (shadow_tile): one pass
// renders every view, each into its tile's viewport from its own list. There is no depth
// clamp in core WebGPU: a caster behind a directional cascade's near plane is clipped.
// shader/shadow.slang mirrors it
#assert(SHADOW_VIEW_BASE == 512)

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
atlas_make :: proc(self: ^Renderer, layers: u32) -> bool {
  desc := TextureDesc {
    extent = {SHADOW_MAP_SIZE, SHADOW_MAP_SIZE},
    format = .D32F,
    usage  = {.DEPTH_TARGET, .SAMPLED},
    layers = layers,
  }
  when !BINDLESS {
    cols := min(layers, ATLAS_COLUMNS)
    desc.extent = {cols * SHADOW_MAP_SIZE, (layers + cols - 1) / cols * SHADOW_MAP_SIZE}
    desc.layers = 1
  }
  atlas := allocate_texture(self, desc, target = true) or_return
  if old := self.atlas; old != 0 do texture_destroy(self, old)
  self.atlas, self.atlas_layers = atlas, layers
  return true
}

// Doubles up to max_shadow_views and rebinds: frame f's scene group now, the other frames' as
// they come round (the old atlas lives until no frame in flight binds it).
@(private)
shadow_atlas_reserve :: proc(self: ^Renderer, f: u32, layers: u32) -> bool {
  have := self.atlas_layers
  if layers <= have do return true
  atlas_make(self, max(layers, min(have * 2, self.max_shadow_views))) or_return
  when BINDLESS {
    self.groups_stale = true
    self.groups_stale[f] = false
    return scene_group_make(self, int(f))
  } else {
    groups_clear(self)
    return true
  }
}

@(private)
shadow_init :: proc(self: ^Renderer) -> bool {
  self.pipelines[.SHADOW] = dev.graphics_pipeline_create(
    &self.gpu,
    {
      shader = shader_source("shadow"),
      layout = pipeline_layout(self, .SHADOW),
      vertex = mesh_vertex_streams(position_only = true),
      cull = .BACK,
      depth = rhi.DepthState{write = true, compare = .LESS_EQUAL, clamp = true, slope_bias = SHADOW_SLOPE_BIAS},
    },
  ) or_return
  return true
}

// The shadow views of frame f render into its atlas. Compacted, they cull first, into their one
// list; batched, the frame's cull fills their lists.
@(private)
shadow_declare :: proc(self: ^Renderer) {
  if self.shadow_view_count == 0 do return
  list := buffer_use(self.draw_lists[SHADOW_DRAW_SLOT].buffer, .INDIRECT)
  when BINDLESS {
    declare(self, "shadow lists clear", .TRANSFER, .SHADOW_LISTS_CLEAR, 0, as(list, .COPY_DST))
    declare(self, "shadow cull", .COMPUTE, .SHADOW_CULL, 0, as(list, .WRITE))
  }
  declare(self, "shadows", .RASTER, .SHADOW, 0, texture_use(self.atlas, .DEPTH), list, as(list, .READ), skinned_use(self))
}

@(private)
shadow_cull_record :: proc(self: ^Renderer, cmd: rhi.CommandList, f: u32) {
  cull_compacted(self, cmd, f, SHADOW_VIEW_BASE, self.shadow_view_count)
}

@(private)
shadow_record :: proc(self: ^Renderer, cmd: rhi.CommandList, f: u32) {
  atlas := self.atlas
  views := self.shadow_view_count
  draw_list := u32(SHADOW_DRAW_SLOT)
  types := [1]u32{u32(MaterialType.PBR)}
  pipelines := [1]rhi.Pipeline{self.pipelines[.SHADOW]}
  when BINDLESS {
    dev.cmd_begin_pass(&self.gpu, cmd, {depth = rhi.DepthTarget{texture = atlas, load = .CLEAR, clear = 1, store = true}, layer_count = views})
    mesh_buffers_bind(self, cmd)
    dev.cmd_bind_pipeline(&self.gpu, cmd, self.pipelines[.SHADOW])
    scene_bind(self, cmd, .SHADOW, f)
    draw_list_draw(self, cmd, draw_list, 0, types[:], pipelines[:], f, GBUFFER_TYPES, false)
    dev.cmd_end_pass(&self.gpu, cmd)
  } else {
    dev.cmd_begin_pass(&self.gpu, cmd, {depth = rhi.DepthTarget{texture = atlas, load = .CLEAR, clear = 1, store = true}})
    // the shadow view a batched draw renders (the bindless path reads it per draw)
    view_index: u32 = SHADOW_VIEW_BASE
    pipeline_bind(self, cmd, self.pipelines[.SHADOW], .SHADOW, f, &view_index, .NONE)
    mesh_buffers_bind(self, cmd)
    for v in 0 ..< views {
      tile := shadow_tile(v, self.atlas_layers)
      dev.cmd_set_viewport(&self.gpu, cmd, tile.x, tile.y, tile.z, tile.w)
      dev.cmd_set_scissor(&self.gpu, cmd, tile.x, tile.y, tile.z, tile.w)
      view_index = SHADOW_VIEW_BASE + v
      dev.cmd_push(&self.gpu, cmd, &view_index, size_of(view_index))
      draw_list_draw(self, cmd, draw_list, v, types[:], pipelines[:], f, GBUFFER_TYPES, false)
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

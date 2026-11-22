package render

import "../containers"
import "base:intrinsics"
import "core:slice"
import "rhi"

// Culling decides what each view draws and writes it as indirect draws.
//
// Each camera has a depth pyramid and a draw-list slot (its index), the shadow views one slot
// after the cameras'.
//
// With multi-draw (Vulkan) one dispatch tests every node against every view and compacts the
// visible ones into a draw list per material type; a count at the head of the buffer says how
// many commands to draw. Without it (WebGPU) render has grouped nodes into batches
// (batches.odin): one dispatch writes each batch's indirect draw, another tests every node and
// counts it into its batch's draw and writes its index into the batch's range of the list's
// instance array, so the CPU issues one indirect draw per batch.

// counts at the head of a compacted draw list buffer, one per list; commands follow
@(private)
DRAW_LIST_HEADER :: 8
// A camera has a draw list per material type (material_list): the built-in ones, then your
// shaders in the room the header leaves.
@(private)
DRAW_LISTS :: DRAW_LIST_HEADER
// MAX_MATERIAL_SHADERS is how many material shaders (material_shader_create) exist at once.
MAX_MATERIAL_SHADERS :: DRAW_LISTS - len(MaterialType)
// Mip 0 texels a depth pyramid group reduces per side (shader/depth_reduce.slang).
@(private = "file")
PYRAMID_TILE :: 32
// words of an indirect draw
@(private = "file")
DRAW_WORDS :: 5
@(private = "file")
DRAW_BYTES :: DRAW_WORDS * size_of(u32)

// A draw-list slot: one buffer. Compacted: DRAW_LIST_HEADER counts, then per list `capacity`
// draws. Batched: per list a count (padded to 4 words), then per list `batches` draws, then
// per list `capacity` instance indices. Offsets are in words. `binding` is its index in the
// bindless storage buffers (Pool.DRAW_LISTS), which views name.
@(private)
GpuDrawList :: struct {
  buffer:                                   rhi.Buffer,
  capacity, batches, binding, lists, views: u32,
  bytes:                                    int,
  draws_base, draws_stride, instances_base: u32,
}

// Draws a shadow view may list: the shadow views share one list (bindless).
@(private = "file")
SHADOW_LIST_VIEW_CAPACITY :: 4096

@(private)
CullKey :: struct {
  slot:    u32,
  pyramid: TextureHandle,
}

@(private)
ReduceKey :: struct {
  slot, mip: u32,
  // the depth image mip 0 reduces; 0 for the other mips
  depth:     TextureHandle,
}

@(private = "file")
CullPush :: struct {
  node_count: u32,
  first_view: u32,
}

@(private = "file")
DepthReducePush :: struct {
  depth_index: u32,
  mip_count:   u32,
  group_count: u32,
  first_view:  u32,
  counter:     u32,
}

// Batched cull and draw writing (cull.slang, cull_draws.slang).
@(private = "file")
BatchPush :: struct {
  node_count:      u32,
  first_view:      u32,
  instance_stride: u32,
  draws_base:      u32,
  instances_base:  u32,
  max_batches:     u32,
  batch_count:     u32,
  first_instance:  u32,
}

// Batched: group 3 of the cull (its draw list, the pyramid) and of the pyramid build (the depth
// image or mip above, read as unfilterable float, and the mip written).
@(private = "file")
CULL_LAYOUT :: GpuLayoutKey{count = 2, compute = true, kinds = {0 = .STORAGE_BUFFER, 1 = .TEXTURE_UNFILTERABLE}}
@(private = "file")
REDUCE_LAYOUT :: GpuLayoutKey{count = 2, compute = true, kinds = {0 = .TEXTURE_UNFILTERABLE, 1 = .STORAGE_TEXTURE}, formats = {1 = .R32F}}

@(private)
cull_init :: proc(self: ^Renderer) -> bool {
  when BINDLESS {
    layout := pipeline_layout(self, .CULL)
    self.pipelines[.CULL] = dev.compute_pipeline_create(&self.gpu, {shader_source("cull"), layout}) or_return
    self.pipelines[.DEPTH_REDUCE] = dev.compute_pipeline_create(&self.gpu, {shader_source("depth_reduce"), layout}) or_return
    counters := dev.buffer_create(&self.gpu, {size = MAX_ACTIVE_CAMERAS * size_of(u32), usage = {.STORAGE}}) or_return
    self.buffers[.PYRAMID_COUNTERS][0] = counters
    self.buffer_sizes[.PYRAMID_COUNTERS][0] = MAX_ACTIVE_CAMERAS * size_of(u32)
    dev.buffer_write(&self.gpu, counters, 0, make([]u8, MAX_ACTIVE_CAMERAS * size_of(u32), context.temp_allocator))
    dev.bindless_write(&self.gpu, .EXTRA_BUFFERS, 0, rhi.BufferRange{buffer = counters})
  } else {
    cull_layout := pipeline_layout(self, .CULL, .NONE, gpu_layout(self, CULL_LAYOUT) or_return)
    self.pipelines[.CULL] = dev.compute_pipeline_create(&self.gpu, {shader_source("cull"), cull_layout}) or_return
    self.pipelines[.CULL_DRAWS] = dev.compute_pipeline_create(&self.gpu, {shader_source("cull_draws"), cull_layout}) or_return
    reduce_layout := pipeline_layout(self, .NONE, .NONE, gpu_layout(self, REDUCE_LAYOUT) or_return)
    self.pipelines[.DEPTH_REDUCE] = dev.compute_pipeline_create(&self.gpu, {shader_source("depth_reduce"), reduce_layout}) or_return
  }
  return true
}

// A depth pyramid is a mipmapped max-depth R32F texture at half its camera's resolution.
@(private)
pyramid_shape :: proc(extent: [2]u32) -> (half: [2]u32, mips: u32) {
  half = {max(1, extent.x / 2), max(1, extent.y / 2)}
  mips = calculate_mip_levels(half.x, half.y)
  assert(mips <= MAX_DEPTH_MIPS)
  return
}

// draw_list_reserve makes draw-list slot `slot`, a camera's or the shadow views', room for every
// node the node table holds, replacing a smaller one with a new buffer and binding: frames in
// flight keep drawing the old until they are done. Compacted by multi-draw: a camera one list per
// material type it draws (CameraFilter; draw_list_index), the shadow views one list of SHADOW_LIST_VIEW_CAPACITY
// draws per view. Batched: one list per view (the shadow slot has a view per shadow map face),
// each of room for every node's instance and every batch's draw. Call before the frame
// records with the slot's lists: when the slot's next writer is recorded.
@(private)
draw_list_reserve :: proc(self: ^Renderer, slot: u32, shadow: bool, shadow_views: u32 = 0) -> bool {
  nodes := u32(table_capacity(self, .NODES))
  // the shadow views' room doubles up to the most there can be, like the atlas
  views := self.draw_lists[slot].views
  if shadow && shadow_views > views do views = min(max(shadow_views, views * 2), self.max_shadow_views)
  when BINDLESS {
    // a camera's lists are the material types it draws, in type order
    lists: u32 = 1 if shadow else u32(card(self.camera_targets[slot].filter.types))
    capacity: u32 = SHADOW_LIST_VIEW_CAPACITY * views if shadow else nodes
    batches: u32 = 0
  } else {
    lists: u32 = views if shadow else 1
    capacity := nodes
    batches := u32(table_capacity(self, .BATCHES))
  }
  old := &self.draw_lists[slot]
  if old.buffer != 0 && old.capacity >= capacity && old.batches >= batches && old.lists >= lists do return true
  dl := GpuDrawList{capacity = capacity, batches = batches, lists = lists, views = views}
  words: u32
  when BINDLESS {
    dl.draws_base, dl.draws_stride = DRAW_LIST_HEADER, capacity
    words = DRAW_LIST_HEADER + lists * capacity * DRAW_WORDS
  } else {
    dl.draws_base, dl.draws_stride = (lists + 3) &~ 3, batches
    dl.instances_base = dl.draws_base + lists * batches * DRAW_WORDS
    words = dl.instances_base + lists * capacity
  }
  dl.bytes = int(words) * size_of(u32)
  dl.buffer = dev.buffer_create(&self.gpu, {size = dl.bytes, usage = {.STORAGE, .INDIRECT, .VERTEX, .COPY_SRC, .COPY_DST}}) or_return
  when BINDLESS {
    binding, bound := pool_alloc(self, .DRAW_LISTS)
    if !bound {
      dev.buffer_retire(&self.gpu, dl.buffer)
      return false
    }
    dl.binding = binding
    dev.bindless_write(&self.gpu, .STORAGE_BUFFERS, binding, rhi.BufferRange{buffer = dl.buffer})
  }
  draw_list_destroy(self, slot)
  self.draw_lists[slot] = dl
  return true
}

// draw_list_destroy releases slot's draw lists once no frame in flight uses them.
@(private)
draw_list_destroy :: proc(self: ^Renderer, slot: u32) {
  dl := &self.draw_lists[slot]
  if dl.buffer == 0 do return
  dev.buffer_retire(&self.gpu, dl.buffer)
  when BINDLESS do containers.slots_free(&self.slots[.DRAW_LISTS], dl.binding)
  dl^ = {}
  groups_clear(self)
}

// Zeroes slot's counts: the compacted cull appends to them, the batched adds to them. Without
// multi-draw count every command is drawn, so a compacted clear zeroes the commands too
// (instanceCount 0 draws nothing). Order earlier indirect reads before it and the cull after it.
@(private)
draw_lists_clear :: proc(self: ^Renderer, cmd: rhi.CommandList, slot: u32) {
  dl := &self.draw_lists[slot]
  size := dl.bytes
  when BINDLESS {
    if dev.caps(&self.gpu).multi_draw_indirect_count do size = DRAW_LIST_HEADER * size_of(u32)
  } else {
    size = int(dl.draws_base) * size_of(u32)
  }
  dev.cmd_fill_buffer(&self.gpu, cmd, dl.buffer, 0, size)
}

// The cull, in three steps: zero every camera's lists (and, batched, the shadow views'), build
// each ready camera's pyramid from the depth the last frame left, then cull every camera into
// its lists. The shadow cull is the shadow pass's where it is compacted; batched, this cull fills
// the shadow lists too.
@(private)
cull_declare :: proc(self: ^Renderer) {
  if containers.slots_count(&self.slots[.CAMERAS]) == 0 do return
  shadow_list: rhi.Buffer
  when !BINDLESS do if self.shadow_view_count > 0 do shadow_list = self.draw_lists[SHADOW_DRAW_SLOT].buffer
  clears, culls := uses_make(), uses_make()
  c: u32
  for i in containers.slots_next(&self.slots[.CAMERAS], &c) {
    append(&clears, buffer_use(self.draw_lists[i].buffer, .COPY_DST))
    append(&culls, buffer_use(self.draw_lists[i].buffer, .WRITE))
  }
  append(&clears, buffer_use(shadow_list, .COPY_DST))
  append(&culls, buffer_use(shadow_list, .WRITE))
  declare(self, "lists clear", .TRANSFER, .LISTS_CLEAR, 0, ..clears[:])
  c = 0
  for i in containers.slots_next(&self.slots[.CAMERAS], &c) {
    targets := &self.camera_targets[i]
    if targets.pyramid == 0 || !camera_ready(self, i) do continue
    // before this frame's G-buffer rewrites the depth
    counter: rhi.Buffer
    when BINDLESS do counter = self.buffers[.PYRAMID_COUNTERS][0]
    declare(self, "depth pyramid", .COMPUTE, .PYRAMID, i, texture_use(targets.depth, .READ), texture_use(targets.pyramid, .WRITE), buffer_use(counter, .WRITE_CONCURRENT))
    append(&culls, texture_use(targets.pyramid, .READ))
  }
  declare(self, "cull", .COMPUTE, .CULL, 0, ..culls[:])
}

@(private)
lists_clear_record :: proc(self: ^Renderer, cmd: rhi.CommandList) {
  c: u32
  for i in containers.slots_next(&self.slots[.CAMERAS], &c) do draw_lists_clear(self, cmd, i)
  when !BINDLESS do if self.shadow_view_count > 0 do draw_lists_clear(self, cmd, SHADOW_DRAW_SLOT)
}

// Camera c's pyramid, from the depth the last frame left: uses 0 and 1 are the depth and the
// pyramid.
@(private)
pyramid_record :: proc(self: ^Renderer, cmd: rhi.CommandList, pass: GraphPass) {
  depth, pyramid := pass_texture(self, pass, 0), pass_texture(self, pass, 1)
  extent, mips := pyramid_shape(self.camera_targets[pass.arg].extent)
  when BINDLESS {
    dev.cmd_bind_pipeline(&self.gpu, cmd, self.pipelines[.DEPTH_REDUCE])
    scene_bind(self, cmd, .CULL, 0)
    groups := [2]u32{(extent.x + PYRAMID_TILE - 1) / PYRAMID_TILE, (extent.y + PYRAMID_TILE - 1) / PYRAMID_TILE}
    push := DepthReducePush{u32(depth), mips, groups.x * groups.y, storage_view(self, pyramid), pass.arg}
    dev.cmd_push(&self.gpu, cmd, &push, size_of(push))
    dev.cmd_dispatch(&self.gpu, cmd, groups.x, groups.y, 1)
  } else {
    // one dispatch per mip: mip 0 from the depth image, each other from the mip above
    zero: u32
    pipeline_bind(self, cmd, self.pipelines[.DEPTH_REDUCE], .NONE, 0, &zero, .NONE)
    for mip in 0 ..< mips {
      src := rhi.TextureView{depth, -1} if mip == 0 else rhi.TextureView{pyramid, i32(mip - 1)}
      resources := [2]rhi.BindResource{src, rhi.TextureView{pyramid, i32(mip)}}
      group := cached_group(self, ReduceKey{pass.arg, mip, depth if mip == 0 else 0}, gpu_layout(self, REDUCE_LAYOUT) or_else 0, resources[:]) or_else 0
      if group == 0 do return
      dev.cmd_bind_group(&self.gpu, cmd, 3, group)
      size := [2]u32{max(extent.x >> mip, 1), max(extent.y >> mip, 1)}
      dev.cmd_dispatch(&self.gpu, cmd, (size.x + 7) / 8, (size.y + 7) / 8, 1)
    }
  }
}

@(private)
cull_record :: proc(self: ^Renderer, cmd: rhi.CommandList, f: u32) {
  when BINDLESS {
    cull_compacted(self, cmd, f, CAMERA_VIEW_BASE + 1, self.slots[.CAMERAS].high_water - 1)
  } else {
    if self.slots[.BATCHES].high_water <= 1 do return
    c: u32
    for i in containers.slots_next(&self.slots[.CAMERAS], &c) {
      cull_batched(self, cmd, i, CAMERA_VIEW_BASE + i, 1, self.camera_targets[i].pyramid)
    }
    if self.shadow_view_count > 0 do cull_batched(self, cmd, SHADOW_DRAW_SLOT, SHADOW_VIEW_BASE, self.shadow_view_count, 0)
  }
}

// Tests every node against `view_count` views from first_view, appending to the lists the views
// name. The caller zeroes the counts first and orders the clear before this.
@(private)
cull_compacted :: proc(self: ^Renderer, cmd: rhi.CommandList, f, first_view, view_count: u32) {
  if self.node_count == 0 || view_count == 0 do return
  push := CullPush{self.node_count, first_view}
  pipeline_bind(self, cmd, self.pipelines[.CULL], .CULL, f, &push, .NONE)
  dev.cmd_dispatch(&self.gpu, cmd, (self.node_count + 63) / 64, view_count, 1)
}

// Batched: fills `views` lists of slot from views first_view ..., testing against `pyramid`
// (the white texture for a view without occlusion).
@(private = "file")
cull_batched :: proc(self: ^Renderer, cmd: rhi.CommandList, slot, first_view, views: u32, pyramid: TextureHandle) {
  dl := &self.draw_lists[slot]
  resources := [2]rhi.BindResource {
    rhi.BufferRange{buffer = dl.buffer},
    rhi.TextureView{texture = pyramid if pyramid != 0 else self.white, mip = -1},
  }
  group := cached_group(self, CullKey{slot, pyramid}, gpu_layout(self, CULL_LAYOUT) or_else 0, resources[:]) or_else 0
  if group == 0 do return
  push := BatchPush {
    node_count      = self.node_count,
    first_view      = first_view,
    instance_stride = dl.capacity,
    draws_base      = dl.draws_base,
    instances_base  = dl.instances_base,
    max_batches     = dl.batches,
    batch_count     = self.slots[.BATCHES].high_water,
    first_instance  = u32(dev.caps(&self.gpu).indirect_first_instance),
  }
  pipeline_bind(self, cmd, self.pipelines[.CULL_DRAWS], .CULL, 0, &push, .NONE)
  dev.cmd_bind_group(&self.gpu, cmd, 3, group)
  dev.cmd_dispatch(&self.gpu, cmd, (self.slots[.BATCHES].high_water + 63) / 64, views, 1)
  if self.node_count == 0 do return
  // same layout and push: the groups stay bound
  dev.cmd_bind_pipeline(&self.gpu, cmd, self.pipelines[.CULL])
  dev.cmd_dispatch(&self.gpu, cmd, (self.node_count + 63) / 64, views, 1)
}

// The draw list a material's draws go to: its type's (cull.slang computes the same). A type
// past every shader goes to NO_DRAW_LIST, drawn by no one.
@(private)
material_list :: proc(m: Material) -> u32 {
  return u32(m.type) if u32(m.type) < DRAW_LISTS else NO_DRAW_LIST
}

@(private)
NO_DRAW_LIST :: max(u32)

// Where material type `type`'s draws are in a view's lists (bindless): lists are kept for the
// types in `seen` only, in type order (cull.slang computes the same).
@(private)
draw_list_index :: #force_inline proc "contextless" (seen, type: u32) -> u32 {
  return u32(intrinsics.count_ones(seen & (1 << type - 1)))
}

// Draws the draws of each draw list key in `keys` (material_list) from list `list` of slot's
// draw lists, `pipelines[i]` for keys[i]. `seen` is the types the view's lists were made for
// (CameraFilter.types; the shadow views' are the G-buffer types). Inside a pass with the mesh buffers, the scene set
// and the camera pushed. `materials` binds each material's textures between batches (WebGPU).
@(private)
draw_list_draw :: proc(self: ^Renderer, cmd: rhi.CommandList, slot, list: u32, keys: []u32, pipelines: []rhi.Pipeline, f: u32, seen: u32, materials := true) {
  when BINDLESS {
    dl := &self.draw_lists[slot]
    count := dev.caps(&self.gpu).multi_draw_indirect_count
    for key, i in keys {
      index := draw_list_index(seen, key)
      dev.cmd_bind_pipeline(&self.gpu, cmd, pipelines[i])
      offset := int(dl.draws_base + index * dl.draws_stride * DRAW_WORDS) * size_of(u32)
      if count {
        dev.cmd_draw_indexed_indirect_count(&self.gpu, cmd, dl.buffer, offset, dl.buffer, int(index) * size_of(u32), dl.capacity, DRAW_BYTES)
      } else {
        dev.cmd_draw_indexed_indirect(&self.gpu, cmd, dl.buffer, offset, dl.capacity, DRAW_BYTES)
      }
    }
  } else {
    draw_batches(self, cmd, slot, list, keys, pipelines, materials, f)
  }
}

// The batched draw loop: an indirect draw per batch, its nodes the instance stream at the
// batch's range, walking each key's batches in batch_order. Where a draw's first instance places
// the stream (Caps.indirect_first_instance) the stream is bound once and a run of consecutive
// batch ids that draw alike is one multi-draw. Material draws start with the MESH scene group
// bound; a type reading another (MaterialShaderDesc.scene) binds its own.
@(private = "file")
draw_batches :: proc(self: ^Renderer, cmd: rhi.CommandList, slot, list: u32, keys: []u32, pipelines: []rhi.Pipeline, materials: bool, f: u32) {
  order := self.batch_order[:]
  if len(order) == 0 do return
  batches := write_table(self, .BATCHES, Batch)
  material_table := write_table(self, .MATERIALS, Material)
  dl := &self.draw_lists[slot]
  first_instance := dev.caps(&self.gpu).indirect_first_instance
  types := material_types()
  if first_instance do dev.cmd_bind_vertex(&self.gpu, cmd, 1, dl.buffer, 0)
  bound_scene := ScenePass.MESH
  for key, t in keys {
    // this key's entries
    lo, _ := slice.binary_search_by(order, u64(key) << 44, proc(e, k: u64) -> slice.Ordering {return slice.cmp(e, k)})
    hi, _ := slice.binary_search_by(order, u64(key + 1) << 44, proc(e, k: u64) -> slice.Ordering {return slice.cmp(e, k)})
    if lo >= hi do continue
    dev.cmd_bind_pipeline(&self.gpu, cmd, pipelines[t])
    if materials {
      scene := types[MaterialType(key)].scene if key < u32(len(MaterialType)) else .NONE
      if scene == .NONE do scene = .MESH
      if scene != bound_scene do scene_bind(self, cmd, scene, f)
      bound_scene = scene
    }
    bound: u32
    for k := lo; k < hi; {
      id := u32(order[k] & 0xFFFFF)
      batch := batches[id]
      if materials && batch.material_id != bound {
        bound = batch.material_id
        m := &material_table[bound]
        texture_bind(self, cmd, .MATERIAL, m.albedo_texture, m.metallic_roughness_texture, m.normal_texture, m.emissive_texture)
      }
      run := 1
      if first_instance {
        // consecutive ids of this key drawing alike
        for k + run < hi {
          next := u32(order[k + run] & 0xFFFFF)
          if next != id + u32(run) || (materials && batches[next].material_id != bound) do break
          run += 1
        }
      } else {
        instances := int(dl.instances_base + list * dl.capacity + batch.first_instance) * size_of(u32)
        dev.cmd_bind_vertex(&self.gpu, cmd, 1, dl.buffer, instances)
      }
      draw := int(dl.draws_base + (list * dl.draws_stride + id) * DRAW_WORDS) * size_of(u32)
      // your shaders' types are past the built-in ones, and pull nothing
      type := material_table[batch.material_id].type
      if type < MaterialType(len(MaterialType)) && types[type].pulled {
        dev.cmd_draw_indirect(&self.gpu, cmd, dl.buffer, draw, u32(run), DRAW_BYTES)
      } else {
        dev.cmd_draw_indexed_indirect(&self.gpu, cmd, dl.buffer, draw, u32(run), DRAW_BYTES)
      }
      k += run
    }
  }
}

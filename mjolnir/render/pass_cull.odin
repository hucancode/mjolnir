package render

import "../containers"
import "core:slice"
import "rhi"

// Culling decides what each view draws and writes it as indirect draws.
//
// Depth pyramids and draw lists live in slots render assigns: a pyramid per camera and frame
// in flight, a draw-list slot per camera and frame in flight, plus one per frame for the
// shadow views.
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
// A camera's draw lists, one per key (material_list): a list per built-in type, then one per
// custom material shader in the room the header leaves.
@(private)
DRAW_LISTS :: DRAW_LIST_HEADER
// MAX_MATERIAL_SHADERS is how many material shaders (material_shader_create) exist at once.
MAX_MATERIAL_SHADERS :: 3
#assert(int(MaterialType.CUSTOM) + MAX_MATERIAL_SHADERS == DRAW_LISTS)
// Mip 0 texels a depth pyramid group reduces per side (shader/depth_reduce.slang).
@(private = "file")
PYRAMID_TILE :: 32
// words of an indirect draw
@(private = "file")
DRAW_WORDS :: 5
@(private = "file")
DRAW_BYTES :: DRAW_WORDS * size_of(u32)

// Types whose shaders pull vertices from the index buffer (WebGPU): the draw is non-indexed,
// two vertices per triangle edge for wireframe, one per index for random color.
@(private)
PULLED_TYPES :: bit_set[MaterialType]{.WIREFRAME, .RANDOM_COLOR}

// A draw-list slot: one buffer. Compacted: DRAW_LIST_HEADER counts, then per list `capacity`
// draws. Batched: per list a count (padded to 4 words), then per list MAX_BATCHES draws, then
// per list `capacity` instance indices. Offsets are in words.
@(private)
GpuDrawList :: struct {
  buffer:                                   rhi.Buffer,
  capacity:                                 u32,
  bytes:                                    int,
  draws_base, draws_stride, instances_base: u32,
}

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
  slot:        u32,
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

@(private)
cull_init :: proc(self: ^Renderer) -> bool {
  for &b in self.draw_count_readback do b = dev.buffer_create(&self.gpu, {size = size_of(u32), usage = {.COPY_DST}, memory = .READBACK}) or_return
  when BINDLESS {
    layout := pipeline_layout(self, .CULL)
    self.cull_pipeline = dev.compute_pipeline_create(&self.gpu, {shader_source("cull"), layout}) or_return
    self.reduce_pipeline = dev.compute_pipeline_create(&self.gpu, {shader_source("depth_reduce"), layout}) or_return
    self.pyramid_counters = dev.buffer_create(&self.gpu, {size = MAX_PYRAMID_SLOTS * size_of(u32), usage = {.STORAGE}}) or_return
    dev.buffer_write(&self.gpu, self.pyramid_counters, 0, make([]u8, MAX_PYRAMID_SLOTS * size_of(u32), context.temp_allocator))
    dev.bindless_write(&self.gpu, .PYRAMID_COUNTERS, 0, rhi.BufferRange{buffer = self.pyramid_counters})
  } else {
    stages := bit_set[rhi.ShaderStage]{.COMPUTE}
    cull_entries := [?]rhi.BindEntry{{kind = .STORAGE_BUFFER, stages = stages}, {kind = .TEXTURE_UNFILTERABLE, stages = stages}}
    self.cull_layout = dev.bind_layout_create(&self.gpu, {entries = cull_entries[:]}) or_return
    cull_layout := pipeline_layout(self, .CULL, .NONE, self.cull_layout)
    self.cull_pipeline = dev.compute_pipeline_create(&self.gpu, {shader_source("cull"), cull_layout}) or_return
    self.cull_draws_pipeline = dev.compute_pipeline_create(&self.gpu, {shader_source("cull_draws"), cull_layout}) or_return
    // the depth image reads as unfilterable float, like the mips
    reduce_entries := [?]rhi.BindEntry{{kind = .TEXTURE_UNFILTERABLE, stages = stages}, {kind = .STORAGE_TEXTURE, stages = stages, format = .R32F}}
    self.reduce_layout = dev.bind_layout_create(&self.gpu, {entries = reduce_entries[:]}) or_return
    reduce_layout := pipeline_layout(self, .NONE, .NONE, self.reduce_layout)
    self.reduce_pipeline = dev.compute_pipeline_create(&self.gpu, {shader_source("depth_reduce"), reduce_layout}) or_return
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

// Registers the storage views of the live cameras' pyramids that are not yet, and of the
// lit image the lighting pass writes at the same slot (LIT_STORAGE_BASE). A pyramid's views
// enter the bindless array at its slot's next frame, once no frame in flight reads the
// previous ones.
@(private)
pyramids_bind :: proc(self: ^Renderer, f: u32) {
  when !BINDLESS do return
  c: u32
  for i in containers.slots_next(&self.slots[.CAMERAS], &c) {
    targets := &self.camera_targets[i]
    if targets.pyramid_bound[f] do continue
    targets.pyramid_bound[f] = true
    slot := camera_slot(i) + f
    _, mips := pyramid_shape(targets.extent)
    for mip in 0 ..< mips {
      dev.bindless_write(&self.gpu, .STORAGE_IMAGES, slot * MAX_DEPTH_MIPS + mip, rhi.TextureView{targets.pyramid[f], i32(mip)})
    }
    dev.bindless_write(&self.gpu, .STORAGE_IMAGES, LIT_STORAGE_BASE + slot, rhi.TextureView{targets.images[.FINAL_IMAGE][f], 0})
  }
}

// Drops the bind groups of the cull and the pyramid build, made again on use.
@(private)
cull_groups_clear :: proc(self: ^Renderer) {
  for _, g in self.cull_groups do dev.bind_group_retire(&self.gpu, g)
  clear(&self.cull_groups)
  for _, g in self.reduce_groups do dev.bind_group_retire(&self.gpu, g)
  clear(&self.reduce_groups)
}

// draw_list_create makes draw-list slot `slot`, a camera's or the shadow views'. Compacted by
// multi-draw: a camera DRAW_LISTS lists, one per material_list key, of CAMERA_LIST_CAPACITY
// draws, the shadow views one list. Batched: one list per view (the shadow slot has a view per
// shadow map face), each of room for every node's instance.
@(private)
draw_list_create :: proc(self: ^Renderer, slot: u32, shadow: bool) -> bool {
  when BINDLESS {
    lists: u32 = 1 if shadow else DRAW_LISTS
    capacity: u32 = SHADOW_LIST_CAPACITY if shadow else CAMERA_LIST_CAPACITY
  } else {
    lists: u32 = MAX_SHADOW_VIEWS if shadow else 1
    capacity: u32 = MAX_SLOTS
  }
  draw_list_destroy(self, slot)
  dl := GpuDrawList{capacity = capacity}
  words: u32
  when BINDLESS {
    dl.draws_base, dl.draws_stride = DRAW_LIST_HEADER, capacity
    words = DRAW_LIST_HEADER + lists * capacity * DRAW_WORDS
  } else {
    dl.draws_base, dl.draws_stride = (lists + 3) &~ 3, MAX_BATCHES
    dl.instances_base = dl.draws_base + lists * MAX_BATCHES * DRAW_WORDS
    words = dl.instances_base + lists * capacity
  }
  dl.bytes = int(words) * size_of(u32)
  dl.buffer = dev.buffer_create(&self.gpu, {size = dl.bytes, usage = {.STORAGE, .INDIRECT, .VERTEX, .COPY_SRC, .COPY_DST}}) or_return
  self.draw_lists[slot] = dl
  when BINDLESS do dev.bindless_write(&self.gpu, .DRAW_LISTS, slot, rhi.BufferRange{buffer = dl.buffer})
  return true
}

// draw_list_destroy releases slot's draw lists once no frame in flight uses them.
@(private)
draw_list_destroy :: proc(self: ^Renderer, slot: u32) {
  dl := &self.draw_lists[slot]
  if dl.buffer == 0 do return
  dev.buffer_retire(&self.gpu, dl.buffer)
  dl^ = {}
  cull_groups_clear(self)
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

// The compute half of the frame: zeroes the lists, builds each ready camera's pyramid from its
// previous depth, then culls every camera into the lists the next frame draws. Compacted:
// ordering against the previous graphics frame is the submission's (async compute) or the
// caller's barrier; the shadow cull is the shadow pass's. Batched: also fills the shadow lists,
// on the one command list, which draws the frame after.
@(private)
cull_record :: proc(self: ^Renderer, cmd: rhi.CommandList, f: u32) {
  c: u32
  for i in containers.slots_next(&self.slots[.CAMERAS], &c) do draw_lists_clear(self, cmd, camera_next_slot(i, f))
  when !BINDLESS do if self.shadow_view_count > 0 do draw_lists_clear(self, cmd, SHADOW_DRAW_SLOT_BASE + f)
  dev.cmd_begin_compute(&self.gpu, cmd)
  defer dev.cmd_end_compute(&self.gpu, cmd)
  when BINDLESS {
    bound := false
    c = 0
    for i in containers.slots_next(&self.slots[.CAMERAS], &c) {
      if !camera_ready(self, i) do continue
      if !bound {
        dev.cmd_bind_pipeline(&self.gpu, cmd, self.reduce_pipeline)
        scene_bind(self, cmd, .CULL, f)
        bound = true
      }
      pyramid_build_bindless(self, cmd, i, f)
    }
    barrier(self, cmd, .FILL_TO_COMPUTE)
    cull_compacted(self, cmd, f, CAMERA_VIEW_BASE + 1, self.slots[.CAMERAS].high_water - 1)
  } else {
    c = 0
    for i in containers.slots_next(&self.slots[.CAMERAS], &c) do if camera_ready(self, i) do pyramid_build_groups(self, cmd, i, f)
    if self.batch_high == 0 do return
    c = 0
    for i in containers.slots_next(&self.slots[.CAMERAS], &c) {
      cull_batched(self, cmd, camera_next_slot(i, f), CAMERA_VIEW_BASE + i, 1, self.camera_targets[i].pyramid[f])
    }
    if self.shadow_view_count > 0 do cull_batched(self, cmd, SHADOW_DRAW_SLOT_BASE + f, SHADOW_VIEW_BASE, self.shadow_view_count, 0)
  }
}

// Tests every node against `view_count` views from first_view, appending to the lists the views
// name. The caller zeroes the counts first and orders the clear before this.
@(private)
cull_compacted :: proc(self: ^Renderer, cmd: rhi.CommandList, f, first_view, view_count: u32) {
  if self.node_count == 0 || view_count == 0 do return
  push := CullPush{self.node_count, first_view}
  pipeline_bind(self, cmd, self.cull_pipeline, .CULL, f, &push, .NONE)
  dev.cmd_dispatch(&self.gpu, cmd, (self.node_count + 63) / 64, view_count, 1)
}

// Camera c's pyramid of frame f, from the previous frame's depth.
@(private = "file")
pyramid_build_bindless :: proc(self: ^Renderer, cmd: rhi.CommandList, c, f: u32) {
  slot := camera_slot(c) + f
  if !self.camera_targets[c].pyramid_bound[f] do return
  extent, mips := pyramid_shape(self.camera_targets[c].extent)
  prev_depth := self.camera_targets[c].images[.DEPTH][(f + FRAMES_IN_FLIGHT - 1) % FRAMES_IN_FLIGHT]
  groups := [2]u32{(extent.x + PYRAMID_TILE - 1) / PYRAMID_TILE, (extent.y + PYRAMID_TILE - 1) / PYRAMID_TILE}
  push := DepthReducePush{u32(prev_depth), mips, groups.x * groups.y, slot}
  dev.cmd_push(&self.gpu, cmd, &push, size_of(push))
  dev.cmd_dispatch(&self.gpu, cmd, groups.x, groups.y, 1)
}

// One dispatch per mip: mip 0 from the depth image, each other from the mip above.
@(private = "file")
pyramid_build_groups :: proc(self: ^Renderer, cmd: rhi.CommandList, c, f: u32) {
  slot := camera_slot(c) + f
  pyramid := self.camera_targets[c].pyramid[f]
  prev_depth := self.camera_targets[c].images[.DEPTH][(f + FRAMES_IN_FLIGHT - 1) % FRAMES_IN_FLIGHT]
  extent, mips := pyramid_shape(self.camera_targets[c].extent)
  zero: u32
  pipeline_bind(self, cmd, self.reduce_pipeline, .NONE, 0, &zero, .NONE)
  for mip in 0 ..< mips {
    key := ReduceKey{slot, mip, prev_depth if mip == 0 else 0}
    group, cached := self.reduce_groups[key]
    if !cached {
      src := rhi.TextureView{prev_depth, -1} if mip == 0 else rhi.TextureView{pyramid, i32(mip - 1)}
      resources := [2]rhi.BindResource{src, rhi.TextureView{pyramid, i32(mip)}}
      ok: bool
      group, ok = dev.bind_group_create(&self.gpu, {layout = self.reduce_layout, resources = resources[:]})
      if !ok do return
      self.reduce_groups[key] = group
    }
    dev.cmd_bind_group(&self.gpu, cmd, 3, group)
    size := [2]u32{max(extent.x >> mip, 1), max(extent.y >> mip, 1)}
    dev.cmd_dispatch(&self.gpu, cmd, (size.x + 7) / 8, (size.y + 7) / 8, 1)
  }
}

// Batched: fills `views` lists of slot from views first_view ..., testing against `pyramid`
// (the white texture for a view without occlusion).
@(private = "file")
cull_batched :: proc(self: ^Renderer, cmd: rhi.CommandList, slot, first_view, views: u32, pyramid: TextureHandle) {
  dl := &self.draw_lists[slot]
  key := CullKey{slot, pyramid}
  group, cached := self.cull_groups[key]
  if !cached {
    resources := [2]rhi.BindResource {
      rhi.BufferRange{buffer = dl.buffer},
      rhi.TextureView{texture = pyramid if pyramid != 0 else self.white, mip = -1},
    }
    ok: bool
    group, ok = dev.bind_group_create(&self.gpu, {layout = self.cull_layout, resources = resources[:]})
    if !ok do return
    self.cull_groups[key] = group
  }
  push := BatchPush {
    node_count      = self.node_count,
    first_view      = first_view,
    instance_stride = dl.capacity,
    draws_base      = dl.draws_base,
    instances_base  = dl.instances_base,
    max_batches     = MAX_BATCHES,
    batch_count     = self.batch_high,
    first_instance  = u32(dev.caps(&self.gpu).indirect_first_instance),
  }
  pipeline_bind(self, cmd, self.cull_draws_pipeline, .CULL, 0, &push, .NONE)
  dev.cmd_bind_group(&self.gpu, cmd, 3, group)
  dev.cmd_dispatch(&self.gpu, cmd, (self.batch_high + 63) / 64, views, 1)
  if self.node_count == 0 do return
  // same layout and push: the groups stay bound
  dev.cmd_bind_pipeline(&self.gpu, cmd, self.cull_pipeline)
  dev.cmd_dispatch(&self.gpu, cmd, (self.node_count + 63) / 64, views, 1)
}

// The draw list a material's draws go to: its type's, or for .CUSTOM its shader's after
// the built-in types' (cull.comp computes the same). A custom material without a valid
// shader goes to NO_DRAW_LIST, drawn by no one.
@(private)
material_list :: proc(m: Material) -> u32 {
  if m.type != .CUSTOM do return u32(m.type)
  if m.shader == 0 || int(m.shader) > MAX_MATERIAL_SHADERS do return NO_DRAW_LIST
  return u32(MaterialType.CUSTOM) + u32(m.shader) - 1
}

@(private)
NO_DRAW_LIST :: max(u32)

// Draws the draws of each draw list key in `keys` (material_list) from list `list` of slot's
// draw lists, `pipelines[i]` for keys[i]. Inside a pass with the mesh buffers, the scene set
// and the camera pushed. `materials` binds each material's textures between batches (WebGPU).
@(private)
draw_list_draw :: proc(self: ^Renderer, cmd: rhi.CommandList, slot, list: u32, keys: []u32, pipelines: []rhi.Pipeline, f: u32, materials := true) {
  when BINDLESS {
    dl := &self.draw_lists[slot]
    count := dev.caps(&self.gpu).multi_draw_indirect_count
    for key, i in keys {
      dev.cmd_bind_pipeline(&self.gpu, cmd, pipelines[i])
      offset := int(dl.draws_base + key * dl.draws_stride * DRAW_WORDS) * size_of(u32)
      if count {
        dev.cmd_draw_indexed_indirect_count(&self.gpu, cmd, dl.buffer, offset, dl.buffer, int(key) * size_of(u32), dl.capacity, DRAW_BYTES)
      } else {
        dev.cmd_draw_indexed_indirect(&self.gpu, cmd, dl.buffer, offset, dl.capacity, DRAW_BYTES)
      }
    }
  } else {
    draw_batches(self, cmd, slot, list, keys, pipelines, materials)
  }
}

// The batched draw loop: an indirect draw per batch, its nodes the instance stream at the
// batch's range, walking each key's batches in batch_order. Where a draw's first instance places
// the stream (Caps.indirect_first_instance) the stream is bound once and a run of consecutive
// batch ids that draw alike is one multi-draw.
@(private = "file")
draw_batches :: proc(self: ^Renderer, cmd: rhi.CommandList, slot, list: u32, keys: []u32, pipelines: []rhi.Pipeline, materials: bool) {
  order := self.batch_order[:]
  if len(order) == 0 do return
  batches := write_table(self, .BATCHES, Batch)
  material_table := write_table(self, .MATERIALS, Material)
  dl := &self.draw_lists[slot]
  first_instance := dev.caps(&self.gpu).indirect_first_instance
  if first_instance do dev.cmd_bind_vertex(&self.gpu, cmd, 1, dl.buffer, 0)
  for key, t in keys {
    // this key's entries
    lo, _ := slice.binary_search_by(order, u64(key) << 44, proc(e, k: u64) -> slice.Ordering {return slice.cmp(e, k)})
    hi, _ := slice.binary_search_by(order, u64(key + 1) << 44, proc(e, k: u64) -> slice.Ordering {return slice.cmp(e, k)})
    if lo >= hi do continue
    dev.cmd_bind_pipeline(&self.gpu, cmd, pipelines[t])
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
      if material_table[batch.material_id].type in PULLED_TYPES {
        dev.cmd_draw_indirect(&self.gpu, cmd, dl.buffer, draw, u32(run), DRAW_BYTES)
      } else {
        dev.cmd_draw_indexed_indirect(&self.gpu, cmd, dl.buffer, draw, u32(run), DRAW_BYTES)
      }
      k += run
    }
  }
}

// draw_count is how many opaque draws the main camera's culling kept in a recent frame:
// a statistic to show.
draw_count :: proc(self: ^Renderer) -> u32 {
  if _, ok := main_camera(self); !ok do return 0
  value: [size_of(u32)]u8
  dev.buffer_read(&self.gpu, self.draw_count_readback[current_frame(self)], 0, value[:])
  return (^u32)(&value)^
}

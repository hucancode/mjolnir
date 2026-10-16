package render

import cont "../containers"
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

// mips a depth pyramid may have
@(private)
MAX_DEPTH_MIPS :: 16
// counts at the head of a compacted draw list buffer, one per list; commands follow
@(private)
DRAW_LIST_HEADER :: 8
#assert(len(MaterialType) <= DRAW_LIST_HEADER)
// Mip 0 texels a depth pyramid group reduces per side (depth_reduce.comp).
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
  lists:                                    u32,
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

// Batched cull and draw writing: the same words as cull.wgsl's CullUniforms.
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
cull_init :: proc(r: ^Renderer) -> bool {
  for &b in r.draw_count_readback do b = dev.buffer_create(&r.gpu, {size = size_of(u32), usage = {.COPY_DST}, memory = .READBACK}) or_return
  when BINDLESS {
    layout := pipeline_layout(r, .CULL)
    r.cull_pipeline = dev.compute_pipeline_create(&r.gpu, {{spirv = {comp = spirv("shader/vulkan/occlusion_culling/cull.spv")}}, layout}) or_return
    r.reduce_pipeline = dev.compute_pipeline_create(&r.gpu, {{spirv = {comp = spirv("shader/vulkan/occlusion_culling/depth_reduce.spv")}}, layout}) or_return
    r.pyramid_counters = dev.buffer_create(&r.gpu, {size = MAX_PYRAMID_SLOTS * size_of(u32), usage = {.STORAGE}}) or_return
    dev.buffer_write(&r.gpu, r.pyramid_counters, 0, make([]u8, MAX_PYRAMID_SLOTS * size_of(u32), context.temp_allocator))
    dev.bindless_write(&r.gpu, .PYRAMID_COUNTERS, 0, rhi.BufferRange{buffer = r.pyramid_counters})
  } else {
    stages := bit_set[rhi.ShaderStage]{.COMPUTE}
    cull_entries := [?]rhi.BindEntry{{kind = .STORAGE_BUFFER, stages = stages}, {kind = .TEXTURE_UNFILTERABLE, stages = stages}}
    r.cull_layout = dev.bind_layout_create(&r.gpu, {entries = cull_entries[:]}) or_return
    common := wgsl("shader/wgpu/common.wgsl")
    cull_layout := pipeline_layout(r, .CULL, .NONE, r.cull_layout)
    r.cull_pipeline = dev.compute_pipeline_create(&r.gpu, {{wgsl = wgsl_join(common, wgsl("shader/wgpu/cull.wgsl"))}, cull_layout}) or_return
    r.cull_draws_pipeline = dev.compute_pipeline_create(&r.gpu, {{wgsl = wgsl_join(common, wgsl("shader/wgpu/cull_draws.wgsl"))}, cull_layout}) or_return
    // the depth image reads as unfilterable float, like the mips
    reduce_entries := [?]rhi.BindEntry{{kind = .TEXTURE_UNFILTERABLE, stages = stages}, {kind = .STORAGE_TEXTURE, stages = stages, format = .R32F}}
    r.reduce_layout = dev.bind_layout_create(&r.gpu, {entries = reduce_entries[:]}) or_return
    reduce_layout := pipeline_layout(r, .NONE, .NONE, r.reduce_layout)
    r.reduce_pipeline = dev.compute_pipeline_create(&r.gpu, {{wgsl = wgsl_join(common, wgsl("shader/wgpu/depth_reduce.wgsl"))}, reduce_layout}) or_return
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
pyramids_bind :: proc(r: ^Renderer, f: u32) {
  when !BINDLESS do return
  c: u32
  for i in cont.slots_next(&r.camera_slots, &c) {
    slot := camera_slot(i) + f
    if r.pyramid_bound[slot] do continue
    r.pyramid_bound[slot] = true
    _, mips := pyramid_shape(r.cameras[i].extent)
    for mip in 0 ..< mips {
      dev.bindless_write(&r.gpu, .STORAGE_IMAGES, slot * MAX_DEPTH_MIPS + mip, rhi.TextureView{r.pyramids[slot], i32(mip)})
    }
    dev.bindless_write(&r.gpu, .STORAGE_IMAGES, LIT_STORAGE_BASE + slot, rhi.TextureView{r.cameras[i].attachments[.FINAL_IMAGE][f], 0})
  }
}

// Drops the bind groups of the cull and the pyramid build, made again on use.
@(private)
cull_groups_clear :: proc(r: ^Renderer) {
  for _, g in r.cull_groups do dev.bind_group_retire(&r.gpu, g)
  clear(&r.cull_groups)
  for _, g in r.reduce_groups do dev.bind_group_retire(&r.gpu, g)
  clear(&r.reduce_groups)
}

// draw_list_create makes draw-list slot `slot`: `lists` lists with room for `capacity` draws
// (compacted) or instances (batched), see draw_list_shape.
@(private)
draw_list_create :: proc(r: ^Renderer, slot, lists, capacity: u32) -> bool {
  draw_list_destroy(r, slot)
  dl := GpuDrawList{lists = lists, capacity = capacity}
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
  dl.buffer = dev.buffer_create(&r.gpu, {size = dl.bytes, usage = {.STORAGE, .INDIRECT, .VERTEX, .COPY_SRC, .COPY_DST}}) or_return
  r.draw_lists[slot] = dl
  when BINDLESS do dev.bindless_write(&r.gpu, .DRAW_LISTS, slot, rhi.BufferRange{buffer = dl.buffer})
  return true
}

// draw_list_destroy releases slot's draw lists once no frame in flight uses them.
@(private)
draw_list_destroy :: proc(r: ^Renderer, slot: u32) {
  dl := &r.draw_lists[slot]
  if dl.buffer == 0 do return
  dev.buffer_retire(&r.gpu, dl.buffer)
  dl^ = {}
  cull_groups_clear(r)
}

// Zeroes slot's counts: the compacted cull appends to them, the batched adds to them. Without
// multi-draw count every command is drawn, so a compacted clear zeroes the commands too
// (instanceCount 0 draws nothing). Order earlier indirect reads before it and the cull after it.
@(private)
draw_lists_clear :: proc(r: ^Renderer, cmd: rhi.CommandList, slot: u32) {
  dl := &r.draw_lists[slot]
  size := dl.bytes
  when BINDLESS {
    if dev.caps(&r.gpu).multi_draw_indirect_count do size = DRAW_LIST_HEADER * size_of(u32)
  } else {
    size = int(dl.draws_base) * size_of(u32)
  }
  dev.cmd_fill_buffer(&r.gpu, cmd, dl.buffer, 0, size)
}

// The compute half of the frame: zeroes the lists, builds each ready camera's pyramid from its
// previous depth, then culls every camera into the lists the next frame draws. Compacted:
// ordering against the previous graphics frame is the submission's (async compute) or the
// caller's barrier; the shadow cull is the shadow pass's. Batched: also fills the shadow lists,
// on the one command list, which draws the frame after.
@(private)
cull_record :: proc(r: ^Renderer, cmd: rhi.CommandList, f: u32) {
  c: u32
  for i in cont.slots_next(&r.camera_slots, &c) do draw_lists_clear(r, cmd, camera_next_slot(i, f))
  when !BINDLESS do if r.shadow_view_count > 0 do draw_lists_clear(r, cmd, SHADOW_DRAW_SLOT_BASE + f)
  dev.cmd_begin_compute(&r.gpu, cmd)
  defer dev.cmd_end_compute(&r.gpu, cmd)
  when BINDLESS {
    bound := false
    c = 0
    for i in cont.slots_next(&r.camera_slots, &c) {
      if !camera_ready(r, i) do continue
      if !bound {
        dev.cmd_bind_pipeline(&r.gpu, cmd, r.reduce_pipeline)
        scene_bind(r, cmd, .CULL, f)
        bound = true
      }
      pyramid_build_bindless(r, cmd, i, f)
    }
    barrier(r, cmd, .FILL_TO_COMPUTE)
    cull_compacted(r, cmd, f, CAMERA_VIEW_BASE + 1, r.camera_slots.high_water - 1)
  } else {
    c = 0
    for i in cont.slots_next(&r.camera_slots, &c) do if camera_ready(r, i) do pyramid_build_groups(r, cmd, i, f)
    if r.batch_high == 0 do return
    c = 0
    for i in cont.slots_next(&r.camera_slots, &c) {
      cull_batched(r, cmd, camera_next_slot(i, f), CAMERA_VIEW_BASE + i, 1, r.pyramids[camera_slot(i) + f])
    }
    if r.shadow_view_count > 0 do cull_batched(r, cmd, SHADOW_DRAW_SLOT_BASE + f, SHADOW_VIEW_BASE, r.shadow_view_count, 0)
  }
}

// Tests every node against `view_count` views from first_view, appending to the lists the views
// name. The caller zeroes the counts first and orders the clear before this.
@(private)
cull_compacted :: proc(r: ^Renderer, cmd: rhi.CommandList, f, first_view, view_count: u32) {
  if r.node_count == 0 || view_count == 0 do return
  push := CullPush{r.node_count, first_view}
  pipeline_bind(r, cmd, r.cull_pipeline, .CULL, f, &push, .NONE)
  dev.cmd_dispatch(&r.gpu, cmd, (r.node_count + 63) / 64, view_count, 1)
}

// Camera c's pyramid of frame f, from the previous frame's depth.
@(private = "file")
pyramid_build_bindless :: proc(r: ^Renderer, cmd: rhi.CommandList, c, f: u32) {
  slot := camera_slot(c) + f
  if !r.pyramid_bound[slot] do return
  extent, mips := pyramid_shape(r.cameras[c].extent)
  prev_depth := r.cameras[c].attachments[.DEPTH][(f + FRAMES_IN_FLIGHT - 1) % FRAMES_IN_FLIGHT]
  groups := [2]u32{(extent.x + PYRAMID_TILE - 1) / PYRAMID_TILE, (extent.y + PYRAMID_TILE - 1) / PYRAMID_TILE}
  push := DepthReducePush{u32(prev_depth), mips, groups.x * groups.y, slot}
  dev.cmd_push(&r.gpu, cmd, &push, size_of(push))
  dev.cmd_dispatch(&r.gpu, cmd, groups.x, groups.y, 1)
}

// One dispatch per mip: mip 0 from the depth image, each other from the mip above.
@(private = "file")
pyramid_build_groups :: proc(r: ^Renderer, cmd: rhi.CommandList, c, f: u32) {
  slot := camera_slot(c) + f
  pyramid := r.pyramids[slot]
  prev_depth := r.cameras[c].attachments[.DEPTH][(f + FRAMES_IN_FLIGHT - 1) % FRAMES_IN_FLIGHT]
  extent, mips := pyramid_shape(r.cameras[c].extent)
  for mip in 0 ..< mips {
    key := ReduceKey{slot, mip, prev_depth if mip == 0 else 0}
    group, cached := r.reduce_groups[key]
    if !cached {
      src := rhi.TextureView{prev_depth, -1} if mip == 0 else rhi.TextureView{pyramid, i32(mip - 1)}
      resources := [2]rhi.BindResource{src, rhi.TextureView{pyramid, i32(mip)}}
      ok: bool
      group, ok = dev.bind_group_create(&r.gpu, {layout = r.reduce_layout, resources = resources[:]})
      if !ok do return
      r.reduce_groups[key] = group
    }
    zero: u32
    pipeline_bind(r, cmd, r.reduce_pipeline, .NONE, 0, &zero, .NONE)
    dev.cmd_bind_group(&r.gpu, cmd, 3, group)
    size := [2]u32{max(extent.x >> mip, 1), max(extent.y >> mip, 1)}
    dev.cmd_dispatch(&r.gpu, cmd, (size.x + 7) / 8, (size.y + 7) / 8, 1)
  }
}

// Batched: fills `views` lists of slot from views first_view ..., testing against `pyramid`
// (the white texture for a view without occlusion).
@(private = "file")
cull_batched :: proc(r: ^Renderer, cmd: rhi.CommandList, slot, first_view, views: u32, pyramid: TextureHandle) {
  dl := &r.draw_lists[slot]
  key := CullKey{slot, pyramid}
  group, cached := r.cull_groups[key]
  if !cached {
    resources := [2]rhi.BindResource {
      rhi.BufferRange{buffer = dl.buffer},
      rhi.TextureView{texture = pyramid if pyramid != 0 else r.white, mip = -1},
    }
    ok: bool
    group, ok = dev.bind_group_create(&r.gpu, {layout = r.cull_layout, resources = resources[:]})
    if !ok do return
    r.cull_groups[key] = group
  }
  push := BatchPush {
    node_count      = r.node_count,
    first_view      = first_view,
    instance_stride = dl.capacity,
    draws_base      = dl.draws_base,
    instances_base  = dl.instances_base,
    max_batches     = MAX_BATCHES,
    batch_count     = r.batch_high,
    first_instance  = u32(dev.caps(&r.gpu).indirect_first_instance),
  }
  pipeline_bind(r, cmd, r.cull_draws_pipeline, .CULL, 0, &push, .NONE)
  dev.cmd_bind_group(&r.gpu, cmd, 3, group)
  dev.cmd_dispatch(&r.gpu, cmd, (r.batch_high + 63) / 64, views, 1)
  if r.node_count == 0 do return
  pipeline_bind(r, cmd, r.cull_pipeline, .CULL, 0, &push, .NONE)
  dev.cmd_bind_group(&r.gpu, cmd, 3, group)
  dev.cmd_dispatch(&r.gpu, cmd, (r.node_count + 63) / 64, views, 1)
}

// Draws each of `types`' draws from list `list` of slot's draw lists, `pipelines[i]` for
// types[i]. Inside a pass with the mesh buffers, the scene set and the camera pushed.
// `materials` binds each material's textures between batches (WebGPU).
@(private)
draw_list_draw :: proc(r: ^Renderer, cmd: rhi.CommandList, slot, list: u32, types: []MaterialType, pipelines: []rhi.Pipeline, f: u32, materials := true) {
  when BINDLESS {
    dl := &r.draw_lists[slot]
    count := dev.caps(&r.gpu).multi_draw_indirect_count
    for type, i in types {
      dev.cmd_bind_pipeline(&r.gpu, cmd, pipelines[i])
      offset := int(dl.draws_base + u32(type) * dl.draws_stride * DRAW_WORDS) * size_of(u32)
      if count {
        dev.cmd_draw_indexed_indirect_count(&r.gpu, cmd, dl.buffer, offset, dl.buffer, int(type) * size_of(u32), dl.capacity, DRAW_BYTES)
      } else {
        dev.cmd_draw_indexed_indirect(&r.gpu, cmd, dl.buffer, offset, dl.capacity, DRAW_BYTES)
      }
    }
  } else {
    draw_batches(r, cmd, slot, list, types, pipelines, materials)
  }
}

// The batched draw loop: an indirect draw per batch, its nodes the instance stream at the
// batch's range. Where a draw's first instance places the stream (Caps.indirect_first_instance)
// the stream is bound once and a run of batches that draw alike, the empty ones among them
// drawing nothing, is one multi-draw.
@(private = "file")
draw_batches :: proc(r: ^Renderer, cmd: rhi.CommandList, slot, list: u32, types: []MaterialType, pipelines: []rhi.Pipeline, materials: bool) {
  if r.batch_high == 0 do return
  batches := write_table(r, .BATCHES, Batch)[:r.batch_high]
  material_table := write_table(r, .MATERIALS, Material)
  dl := &r.draw_lists[slot]
  first_instance := dev.caps(&r.gpu).indirect_first_instance
  if first_instance do dev.cmd_bind_vertex(&r.gpu, cmd, 1, dl.buffer, 0)
  bound: u32
  for type, t in types {
    pipeline_set := false
    for id := 0; id < len(batches); {
      batch := batches[id]
      if batch.capacity == 0 || material_table[batch.material_id].type != type {
        id += 1
        continue
      }
      if !pipeline_set {
        dev.cmd_bind_pipeline(&r.gpu, cmd, pipelines[t])
        pipeline_set = true
        bound = 0
      }
      if materials && batch.material_id != bound {
        bound = batch.material_id
        m := &material_table[bound]
        texture_bind(r, cmd, .MATERIAL, m.albedo_index, m.metallic_roughness_index, m.normal_index, m.emissive_index)
      }
      run := 1
      if first_instance {
        // up to the last batch that draws alike
        for next := id + 1; next < len(batches); next += 1 {
          b := batches[next]
          if b.capacity == 0 do continue
          if material_table[b.material_id].type != type || (materials && b.material_id != bound) do break
          run = next - id + 1
        }
      } else {
        instances := int(dl.instances_base + list * dl.capacity + batch.first_instance) * size_of(u32)
        dev.cmd_bind_vertex(&r.gpu, cmd, 1, dl.buffer, instances)
      }
      draw := int(dl.draws_base + (list * dl.draws_stride + u32(id)) * DRAW_WORDS) * size_of(u32)
      if type in PULLED_TYPES {
        dev.cmd_draw_indirect(&r.gpu, cmd, dl.buffer, draw, u32(run), DRAW_BYTES)
      } else {
        dev.cmd_draw_indexed_indirect(&r.gpu, cmd, dl.buffer, draw, u32(run), DRAW_BYTES)
      }
      id += run
    }
  }
}

// Copies the main camera's opaque draw count out of slot's lists, for draw_count.
@(private)
draw_count_record :: proc(r: ^Renderer, cmd: rhi.CommandList, slot, f: u32) {
  dev.cmd_copy_buffer(&r.gpu, cmd, r.draw_lists[slot].buffer, 0, r.draw_count_readback[f], 0, size_of(u32))
}

// draw_count is the opaque draws the main camera's cull wrote, a few frames back (WebGPU) or
// of the last finished frame (Vulkan).
@(private)
draw_count :: proc(r: ^Renderer, f: u32) -> u32 {
  value: [size_of(u32)]u8
  dev.buffer_read(&r.gpu, r.draw_count_readback[f], 0, value[:])
  return (^u32)(&value)^
}

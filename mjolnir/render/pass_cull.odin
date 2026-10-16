package render

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

@(private)
CullState :: struct {
  cull:             rhi.Pipeline,
  // batched: writes the draw of each batch
  draws:            rhi.Pipeline,
  // [from_depth]: compacted has only [0], which builds every mip; batched builds mip by mip
  reduce:           [2]rhi.Pipeline,
  // batched: group 3 of the cull and of the pyramid build
  cull_layout:      rhi.BindLayout,
  reduce_layouts:   [2]rhi.BindLayout,
  cull_groups:      map[CullKey]rhi.BindGroup,
  reduce_groups:    map[ReduceKey]rhi.BindGroup,
  lists:            [MAX_DRAW_LIST_SLOTS]GpuDrawList,
  // the slot's storage views are in the bindless array
  pyramid_bound:    [MAX_PYRAMID_SLOTS]bool,
  pyramid_extent:   [MAX_PYRAMID_SLOTS][2]u32,
  pyramid_mips:     [MAX_PYRAMID_SLOTS]u32,
  pyramid_counters: rhi.Buffer,
  // the main camera's visible opaque draws, copied out per frame in flight
  readback:         [FRAMES_IN_FLIGHT]rhi.Buffer,
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
  c := &r.cull
  for &b in c.readback do b = dev.buffer_create(&r.gpu, {size = size_of(u32), usage = {.COPY_DST}, memory = .READBACK}) or_return
  if r.res.caps.bindless {
    layout := pipeline_layout(r, .CULL)
    c.cull = dev.compute_pipeline_create(&r.gpu, {{spirv = {comp = spirv("shader/vulkan/occlusion_culling/cull.spv")}}, layout}) or_return
    c.reduce[0] = dev.compute_pipeline_create(&r.gpu, {{spirv = {comp = spirv("shader/vulkan/occlusion_culling/depth_reduce.spv")}}, layout}) or_return
    c.pyramid_counters = dev.buffer_create(&r.gpu, {size = MAX_PYRAMID_SLOTS * size_of(u32), usage = {.STORAGE}}) or_return
    dev.buffer_write(&r.gpu, c.pyramid_counters, 0, make([]u8, MAX_PYRAMID_SLOTS * size_of(u32), context.temp_allocator))
    dev.bindless_write(&r.gpu, .PYRAMID_COUNTERS, 0, rhi.BufferRange{buffer = c.pyramid_counters})
    return true
  }
  stages := bit_set[rhi.ShaderStage]{.COMPUTE}
  cull_entries := [?]rhi.BindEntry{{kind = .STORAGE_BUFFER, stages = stages}, {kind = .TEXTURE_UNFILTERABLE, stages = stages}}
  c.cull_layout = dev.bind_layout_create(&r.gpu, {entries = cull_entries[:]}) or_return
  common := wgsl("shader/wgpu/common.wgsl")
  cull_layout := pipeline_layout(r, .CULL, .NONE, c.cull_layout)
  c.cull = dev.compute_pipeline_create(&r.gpu, {{wgsl = wgsl_join(common, wgsl("shader/wgpu/cull.wgsl"))}, cull_layout}) or_return
  c.draws = dev.compute_pipeline_create(&r.gpu, {{wgsl = wgsl_join(common, wgsl("shader/wgpu/cull_draws.wgsl"))}, cull_layout}) or_return
  for &layout, from_depth in c.reduce_layouts {
    entries := [?]rhi.BindEntry{{kind = .TEXTURE_DEPTH if from_depth == 1 else .TEXTURE_UNFILTERABLE, stages = stages}, {kind = .STORAGE_TEXTURE, stages = stages, format = .R32F}}
    layout = dev.bind_layout_create(&r.gpu, {entries = entries[:]}) or_return
  }
  reduce_from_mip := wgsl_join(common, wgsl("shader/wgpu/depth_reduce_from_mip.wgsl"), wgsl("shader/wgpu/depth_reduce.wgsl"))
  reduce_from_depth := wgsl_join(common, wgsl("shader/wgpu/depth_reduce_from_depth.wgsl"), wgsl("shader/wgpu/depth_reduce.wgsl"))
  reduce_sources := [2]string{reduce_from_mip, reduce_from_depth}
  for from_depth in 0 ..< 2 {
    layout := pipeline_layout(r, .NONE, .NONE, c.reduce_layouts[from_depth])
    c.reduce[from_depth] = dev.compute_pipeline_create(&r.gpu, {{wgsl = reduce_sources[from_depth]}, layout}) or_return
  }
  return true
}

@(private)
cull_shutdown :: proc(r: ^Renderer) {
  c := &r.cull
  delete(c.cull_groups)
  delete(c.reduce_groups)
}

// pyramid_create makes pyramid slot `slot` build into `pyramid`, a mipmapped R32F storage
// texture. Its storage views enter the bindless array at the slot's next frame
// (pyramids_bind), once no frame in flight reads the previous ones.
@(private)
pyramid_create :: proc(r: ^Renderer, slot: u32, extent: [2]u32, mips: u32) {
  assert(mips <= MAX_DEPTH_MIPS)
  r.cull.pyramid_bound[slot] = false
  r.cull.pyramid_extent[slot], r.cull.pyramid_mips[slot] = extent, mips
}

// pyramid_destroy forgets slot's views and bind groups; the texture is destroyed by render.
@(private)
pyramid_destroy :: proc(r: ^Renderer, slot: u32) {
  r.cull.pyramid_bound[slot] = false
  cull_groups_clear(r)
}

// Registers the storage views of the live cameras' pyramids that are not yet, and of the
// lit image the lighting pass writes at the same slot (LIT_STORAGE_BASE).
@(private)
pyramids_bind :: proc(r: ^Renderer) {
  if !r.res.caps.bindless do return
  for &cam in r.live_cameras {
    if r.cull.pyramid_bound[cam.slot] do continue
    r.cull.pyramid_bound[cam.slot] = true
    for mip in 0 ..< r.cull.pyramid_mips[cam.slot] {
      dev.bindless_write(&r.gpu, .STORAGE_IMAGES, cam.slot * MAX_DEPTH_MIPS + mip, rhi.TextureView{cam.pyramid, i32(mip)})
    }
    dev.bindless_write(&r.gpu, .STORAGE_IMAGES, LIT_STORAGE_BASE + cam.slot, rhi.TextureView{cam.attachments[.FINAL_IMAGE], 0})
  }
}

// Drops the bind groups of the cull and the pyramid build, made again on use.
@(private)
cull_groups_clear :: proc(r: ^Renderer) {
  c := &r.cull
  for _, g in c.cull_groups do dev.bind_group_retire(&r.gpu, g)
  clear(&c.cull_groups)
  for _, g in c.reduce_groups do dev.bind_group_retire(&r.gpu, g)
  clear(&c.reduce_groups)
}

// draw_list_create makes draw-list slot `slot`: `lists` lists with room for `capacity` draws
// (compacted) or instances (batched), see draw_list_shape.
@(private)
draw_list_create :: proc(r: ^Renderer, slot, lists, capacity: u32) -> bool {
  draw_list_destroy(r, slot)
  dl := GpuDrawList{lists = lists, capacity = capacity}
  words: u32
  if r.res.caps.bindless {
    dl.draws_base, dl.draws_stride = DRAW_LIST_HEADER, capacity
    words = DRAW_LIST_HEADER + lists * capacity * DRAW_WORDS
  } else {
    dl.draws_base, dl.draws_stride = (lists + 3) &~ 3, MAX_BATCHES
    dl.instances_base = dl.draws_base + lists * MAX_BATCHES * DRAW_WORDS
    words = dl.instances_base + lists * capacity
  }
  dl.bytes = int(words) * size_of(u32)
  dl.buffer = dev.buffer_create(&r.gpu, {size = dl.bytes, usage = {.STORAGE, .INDIRECT, .VERTEX, .COPY_SRC, .COPY_DST}}) or_return
  r.cull.lists[slot] = dl
  if r.res.caps.bindless do dev.bindless_write(&r.gpu, .DRAW_LISTS, slot, rhi.BufferRange{buffer = dl.buffer})
  return true
}

// draw_list_destroy releases slot's draw lists once no frame in flight uses them.
@(private)
draw_list_destroy :: proc(r: ^Renderer, slot: u32) {
  dl := &r.cull.lists[slot]
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
  dl := &r.cull.lists[slot]
  size := dl.bytes
  if r.res.caps.multi_draw_indirect_count do size = DRAW_LIST_HEADER * size_of(u32)
  if !r.res.caps.bindless do size = int(dl.draws_base) * size_of(u32)
  dev.cmd_fill_buffer(&r.gpu, cmd, dl.buffer, 0, size)
}

// The compute half of the frame: zeroes the lists, builds each ready camera's pyramid from its
// previous depth, then culls every camera into the lists the next frame draws. Compacted:
// ordering against the previous graphics frame is the submission's (async compute) or the
// caller's barrier; the shadow cull is the shadow pass's. Batched: also fills the shadow lists,
// on the one command list, which draws the frame after.
@(private)
cull_record :: proc(r: ^Renderer, cmd: rhi.CommandList, f: u32) {
  c := &r.cull
  bindless := r.res.caps.bindless
  for &cam in r.live_cameras do draw_lists_clear(r, cmd, cam.next_slot)
  if !bindless && r.shadow_view_count > 0 do draw_lists_clear(r, cmd, r.shadow_draw_list)
  dev.cmd_begin_compute(&r.gpu, cmd)
  defer dev.cmd_end_compute(&r.gpu, cmd)
  if bindless {
    bound := false
    for &cam in r.live_cameras {
      if !cam.ready do continue
      if !bound {
        dev.cmd_bind_pipeline(&r.gpu, cmd, c.reduce[0])
        scene_bind(r, cmd, .CULL, f)
        bound = true
      }
      pyramid_build_bindless(r, cmd, &cam)
    }
    barrier(r, cmd, .FILL_TO_COMPUTE)
    cull_compacted(r, cmd, f, CAMERA_VIEW_BASE + 1, r.camera_view_count)
    return
  }
  for &cam in r.live_cameras do if cam.ready do pyramid_build_groups(r, cmd, &cam)
  if r.batch_count == 0 do return
  for &cam in r.live_cameras do cull_batched(r, cmd, cam.next_slot, CAMERA_VIEW_BASE + cam.index, 1, cam.pyramid)
  if r.shadow_view_count > 0 do cull_batched(r, cmd, r.shadow_draw_list, SHADOW_VIEW_BASE, r.shadow_view_count, 0)
}

// Tests every node against `view_count` views from first_view, appending to the lists the views
// name. The caller zeroes the counts first and orders the clear before this.
@(private)
cull_compacted :: proc(r: ^Renderer, cmd: rhi.CommandList, f, first_view, view_count: u32) {
  if r.node_count == 0 || view_count == 0 do return
  push := CullPush{r.node_count, first_view}
  pipeline_bind(r, cmd, r.cull.cull, .CULL, f, &push, .NONE)
  dev.cmd_dispatch(&r.gpu, cmd, (r.node_count + 63) / 64, view_count, 1)
}

@(private = "file")
pyramid_build_bindless :: proc(r: ^Renderer, cmd: rhi.CommandList, cam: ^FrameCamera) {
  if !r.cull.pyramid_bound[cam.slot] do return
  extent := r.cull.pyramid_extent[cam.slot]
  groups := [2]u32{(extent.x + PYRAMID_TILE - 1) / PYRAMID_TILE, (extent.y + PYRAMID_TILE - 1) / PYRAMID_TILE}
  push := DepthReducePush{u32(cam.prev_depth), r.cull.pyramid_mips[cam.slot], groups.x * groups.y, cam.slot}
  dev.cmd_push(&r.gpu, cmd, &push, size_of(push))
  dev.cmd_dispatch(&r.gpu, cmd, groups.x, groups.y, 1)
}

// One dispatch per mip: mip 0 from the depth image, each other from the mip above.
@(private = "file")
pyramid_build_groups :: proc(r: ^Renderer, cmd: rhi.CommandList, cam: ^FrameCamera) {
  c := &r.cull
  extent := r.cull.pyramid_extent[cam.slot]
  for mip in 0 ..< r.cull.pyramid_mips[cam.slot] {
    from_depth := int(mip == 0)
    key := ReduceKey{cam.slot, mip, cam.prev_depth if mip == 0 else 0}
    group, cached := c.reduce_groups[key]
    if !cached {
      src := TextureView{cam.prev_depth, -1} if mip == 0 else TextureView{cam.pyramid, i32(mip - 1)}
      resources := [2]rhi.BindResource{rhi.TextureView(src), rhi.TextureView{cam.pyramid, i32(mip)}}
      ok: bool
      group, ok = dev.bind_group_create(&r.gpu, {layout = c.reduce_layouts[from_depth], resources = resources[:]})
      if !ok do return
      c.reduce_groups[key] = group
    }
    zero: u32
    pipeline_bind(r, cmd, c.reduce[from_depth], .NONE, 0, &zero, .NONE)
    dev.cmd_bind_group(&r.gpu, cmd, 3, group)
    size := [2]u32{max(extent.x >> mip, 1), max(extent.y >> mip, 1)}
    dev.cmd_dispatch(&r.gpu, cmd, (size.x + 7) / 8, (size.y + 7) / 8, 1)
  }
}

@(private = "file")
TextureView :: rhi.TextureView

// Batched: fills `views` lists of slot from views first_view ..., testing against `pyramid`
// (the white texture for a view without occlusion).
@(private = "file")
cull_batched :: proc(r: ^Renderer, cmd: rhi.CommandList, slot, first_view, views: u32, pyramid: TextureHandle) {
  c := &r.cull
  dl := &c.lists[slot]
  key := CullKey{slot, pyramid}
  group, cached := c.cull_groups[key]
  if !cached {
    resources := [2]rhi.BindResource {
      rhi.BufferRange{buffer = dl.buffer},
      rhi.TextureView{texture = pyramid if pyramid != 0 else r.res.white, mip = -1},
    }
    ok: bool
    group, ok = dev.bind_group_create(&r.gpu, {layout = c.cull_layout, resources = resources[:]})
    if !ok do return
    c.cull_groups[key] = group
  }
  push := BatchPush {
    node_count      = r.node_count,
    first_view      = first_view,
    instance_stride = dl.capacity,
    draws_base      = dl.draws_base,
    instances_base  = dl.instances_base,
    max_batches     = MAX_BATCHES,
    batch_count     = r.batch_count,
    first_instance  = u32(r.res.caps.indirect_first_instance),
  }
  pipeline_bind(r, cmd, c.draws, .CULL, 0, &push, .NONE)
  dev.cmd_bind_group(&r.gpu, cmd, 3, group)
  dev.cmd_dispatch(&r.gpu, cmd, (r.batch_count + 63) / 64, views, 1)
  if r.node_count == 0 do return
  pipeline_bind(r, cmd, c.cull, .CULL, 0, &push, .NONE)
  dev.cmd_bind_group(&r.gpu, cmd, 3, group)
  dev.cmd_dispatch(&r.gpu, cmd, (r.node_count + 63) / 64, views, 1)
}

// Draws each of `types`' draws from list `list` of slot's draw lists, `pipelines[i]` for
// types[i]. Inside a pass with the mesh buffers, the scene set and the camera pushed.
// `materials` binds each material's textures between batches (WebGPU).
@(private)
draw_list_draw :: proc(r: ^Renderer, cmd: rhi.CommandList, slot, list: u32, types: []MaterialType, pipelines: []rhi.Pipeline, f: u32, materials := true) {
  if r.res.caps.bindless {
    dl := &r.cull.lists[slot]
    for type, i in types {
      dev.cmd_bind_pipeline(&r.gpu, cmd, pipelines[i])
      offset := int(dl.draws_base + u32(type) * dl.draws_stride * DRAW_WORDS) * size_of(u32)
      if r.res.caps.multi_draw_indirect_count {
        dev.cmd_draw_indexed_indirect_count(&r.gpu, cmd, dl.buffer, offset, dl.buffer, int(type) * size_of(u32), dl.capacity, DRAW_BYTES)
      } else {
        dev.cmd_draw_indexed_indirect(&r.gpu, cmd, dl.buffer, offset, dl.capacity, DRAW_BYTES)
      }
    }
    return
  }
  draw_batches(r, cmd, slot, list, types, pipelines, materials)
}

// The batched draw loop: an indirect draw per batch, its nodes the instance stream at the
// batch's range. Where a draw's first instance places the stream (Caps.indirect_first_instance)
// the stream is bound once and a run of batches that draw alike, the empty ones among them
// drawing nothing, is one multi-draw.
@(private = "file")
draw_batches :: proc(r: ^Renderer, cmd: rhi.CommandList, slot, list: u32, types: []MaterialType, pipelines: []rhi.Pipeline, materials: bool) {
  if r.batch_count == 0 do return
  batches := write_table(r, .BATCHES, Batch)[:r.batch_count]
  material_table := write_table(r, .MATERIALS, Material)
  dl := &r.cull.lists[slot]
  first_instance := r.res.caps.indirect_first_instance
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
  dev.cmd_copy_buffer(&r.gpu, cmd, r.cull.lists[slot].buffer, 0, r.cull.readback[f], 0, size_of(u32))
}

// draw_count is the opaque draws the main camera's cull wrote, a few frames back (WebGPU) or
// of the last finished frame (Vulkan).
@(private)
draw_count :: proc(r: ^Renderer, f: u32) -> u32 {
  value: [size_of(u32)]u8
  dev.buffer_read(&r.gpu, r.cull.readback[f], 0, value[:])
  return (^u32)(&value)^
}

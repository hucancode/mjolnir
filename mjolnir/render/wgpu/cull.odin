package wgpu_backend

import rhi "../rhi"

import wgpu "vendor:wgpu"

// Depth pyramids and draw lists live in slots render assigns: a pyramid and a draw-list slot
// per camera (and frame in flight: one), plus a draw-list slot for the shadow views.
MAX_PYRAMID_SLOTS :: rhi.MAX_ACTIVE_CAMERAS * FRAMES_IN_FLIGHT
MAX_DRAW_LIST_SLOTS :: (rhi.MAX_ACTIVE_CAMERAS + 1) * FRAMES_IN_FLIGHT

// mips a depth pyramid may have
@(private)
MAX_DEPTH_MIPS :: 16

// render groups nodes into batches, the nodes drawing one mesh with one material (batches.odin,
// Table.BATCHES). Per view, two dispatches fill a draw list: cull_draws.wgsl writes the indirect
// draw of every batch, cull.wgsl tests every node against the view, counts it into its batch's
// draw and writes its index into the batch's range of the list's instance array. The draw loop
// then issues one indirect draw per batch, the instance array bound as the node index vertex
// stream at the batch's offset: CPU work scales with batches, not nodes.

// Types whose shaders pull vertices from the index buffer: the draw is non-indexed
// (DrawIndirect in the first 16 bytes), two vertices per triangle edge for wireframe, one
// per index for random color.
@(private)
PULLED_TYPES :: bit_set[rhi.MaterialType]{.WIREFRAME, .RANDOM_COLOR}

// A draw-list slot is one buffer of u32 words: per list the count of visible opaque nodes
// (padded to 4 words), then per list rhi.MAX_BATCHES five-word indirect draws, then per list
// `instance_stride` node indices. A camera has one list, the shadow slot one per view.
@(private)
DrawList :: struct {
  buffer:                                         wgpu.Buffer,
  lists:                                          u32,
  // all in words
  instance_stride, draws_base, instances_base:    u32,
}

@(private)
DRAW_WORDS :: 5

@(private = "file")
CullUniforms :: struct {
  node_count:      u32,
  first_view:      u32,
  instance_stride: u32,
  draws_base:      u32,
  instances_base:  u32,
  max_batches:     u32,
  batch_count:     u32,
  _pad:            u32,
}

@(private)
CullKey :: struct {
  slot:    u32,
  pyramid: rhi.TextureHandle,
}

@(private)
ReduceKey :: struct {
  slot, mip: u32,
  // the depth image mip 0 reduces; 0 for the other mips
  depth:     rhi.TextureHandle,
}

@(private)
CULL_WGSL :: #load("shader/common.wgsl", string) + #load("shader/cull.wgsl", string)
@(private = "file")
CULL_DRAWS_WGSL :: #load("shader/common.wgsl", string) + #load("shader/cull_draws.wgsl", string)
// [from_depth]
@(private = "file")
DEPTH_REDUCE_WGSL := [2]string {
  #load("shader/common.wgsl", string) + #load("shader/depth_reduce_from_mip.wgsl", string) + #load("shader/depth_reduce.wgsl", string),
  #load("shader/common.wgsl", string) + #load("shader/depth_reduce_from_depth.wgsl", string) + #load("shader/depth_reduce.wgsl", string),
}

@(private)
cull_init :: proc(b: ^Backend) {
  for &r in b.draw_count_readback do r.buffer = buffer_create(b, size_of(u32), {.MapRead, .CopyDst})
  list_entries := [?]wgpu.BindGroupLayoutEntry {
    {binding = 0, visibility = {.Compute}, buffer = {type = .Storage}},
    {binding = 1, visibility = {.Compute}, texture = {sampleType = .UnfilterableFloat, viewDimension = ._2D}},
  }
  b.cull_layout = wgpu.DeviceCreateBindGroupLayout(b.device, &{entryCount = len(list_entries), entries = raw_data(list_entries[:])})
  b.cull_pipeline = compute_pipeline(b, CULL_WGSL, .CULL, .NONE, b.cull_layout)
  b.finalize_pipeline = compute_pipeline(b, CULL_DRAWS_WGSL, .CULL, .NONE, b.cull_layout)
  for &layout, from_depth in b.reduce_layouts {
    entries := [?]wgpu.BindGroupLayoutEntry {
      {binding = 0, visibility = {.Compute}, texture = {sampleType = .Depth if from_depth == 1 else .UnfilterableFloat, viewDimension = ._2D}},
      {binding = 1, visibility = {.Compute}, storageTexture = {access = .WriteOnly, format = .R32Float, viewDimension = ._2D}},
    }
    layout = wgpu.DeviceCreateBindGroupLayout(b.device, &{entryCount = len(entries), entries = raw_data(entries[:])})
    module := shader_module(b, DEPTH_REDUCE_WGSL[from_depth])
    layouts := [4]wgpu.BindGroupLayout{b.scene_layouts[.NONE], b.group_layouts[.NONE], b.frame_layout, layout}
    pipeline_layout := wgpu.DeviceCreatePipelineLayout(b.device, &{bindGroupLayoutCount = 4, bindGroupLayouts = raw_data(layouts[:])})
    b.reduce_pipelines[from_depth] = wgpu.DeviceCreateComputePipeline(
      b.device,
      &{layout = pipeline_layout, compute = {module = module, entryPoint = "main"}},
    )
    wgpu.PipelineLayoutRelease(pipeline_layout)
    wgpu.ShaderModuleRelease(module)
  }
}

// draw_list_create makes draw-list slot `slot`: `lists` lists, each with room for `capacity`
// instances (render's draw_list_shape).
draw_list_create :: proc(b: ^Backend, slot, lists, capacity: u32) -> bool {
  draw_list_destroy(b, slot)
  dl := DrawList {
    lists           = lists,
    instance_stride = capacity,
    draws_base      = (lists + 3) &~ 3,
  }
  dl.instances_base = dl.draws_base + lists * rhi.MAX_BATCHES * DRAW_WORDS
  words := dl.instances_base + lists * capacity
  dl.buffer = buffer_create(b, int(words) * size_of(u32), {.Storage, .Indirect, .Vertex, .CopySrc, .CopyDst})
  b.draw_lists[slot] = dl
  return dl.buffer != nil
}

// draw_list_destroy releases slot's draw lists; WebGPU keeps them for submitted work.
draw_list_destroy :: proc(b: ^Backend, slot: u32) {
  if b.draw_lists[slot].buffer == nil do return
  wgpu.BufferRelease(b.draw_lists[slot].buffer)
  b.draw_lists[slot] = {}
  cull_groups_clear(b)
}

// pyramid_create makes pyramid slot `slot` build into `pyramid`, a mipmapped R32F storage
// texture render made: a storage view per mip.
pyramid_create :: proc(b: ^Backend, slot: u32, pyramid: rhi.TextureHandle) -> bool {
  pyramid_destroy(b, slot)
  t := &b.textures[pyramid]
  assert(t.desc.mip_levels <= MAX_DEPTH_MIPS)
  for mip in 0 ..< t.desc.mip_levels {
    b.pyramid_views[slot][mip] = wgpu.TextureCreateView(t.texture, &{dimension = ._2D, baseMipLevel = mip, mipLevelCount = 1, arrayLayerCount = 1})
  }
  return true
}

// pyramid_destroy releases slot's views.
pyramid_destroy :: proc(b: ^Backend, slot: u32) {
  for &view in b.pyramid_views[slot] {
    if view != nil do wgpu.TextureViewRelease(view)
    view = nil
  }
  cull_groups_clear(b)
}

// Drops the bind groups of the cull and the pyramid build, made again on use.
@(private)
cull_groups_clear :: proc(b: ^Backend) {
  for _, g in b.cull_groups do wgpu.BindGroupRelease(g)
  clear(&b.cull_groups)
  for _, g in b.reduce_groups do wgpu.BindGroupRelease(g)
  clear(&b.reduce_groups)
}

// The bind group of the cull into slot's lists, testing against `pyramid` (the white texture
// for a view without occlusion).
@(private = "file")
cull_group :: proc(b: ^Backend, slot: u32, pyramid: rhi.TextureHandle) -> wgpu.BindGroup {
  key := CullKey{slot, pyramid}
  if g, ok := b.cull_groups[key]; ok do return g
  list := b.draw_lists[slot].buffer
  entries := [?]wgpu.BindGroupEntry {
    {binding = 0, buffer = list, size = wgpu.BufferGetSize(list)},
    {binding = 1, textureView = b.textures[pyramid].view if pyramid != 0 else b.white.view},
  }
  g := wgpu.DeviceCreateBindGroup(b.device, &{layout = b.cull_layout, entryCount = len(entries), entries = raw_data(entries[:])})
  b.cull_groups[key] = g
  return g
}

// Builds each ready camera's pyramid from its previous depth, then fills each camera's draw list
// and the shadow views' lists. Before any pass of the frame draws.
@(private)
cull_record :: proc(b: ^Backend, desc: ^rhi.FrameDesc, encoder: wgpu.CommandEncoder) {
  for &cam in desc.live_cameras do counts_clear(b, encoder, cam.next_slot)
  if desc.shadow_view_count > 0 do counts_clear(b, encoder, desc.shadow_draw_list)
  pass := wgpu.CommandEncoderBeginComputePass(encoder)
  defer {
    wgpu.ComputePassEncoderEnd(pass)
    wgpu.ComputePassEncoderRelease(pass)
  }
  wgpu.ComputePassEncoderSetBindGroup(pass, 0, b.scene_groups[.NONE])
  wgpu.ComputePassEncoderSetBindGroup(pass, 1, group(b, {layout = .NONE}))
  for &cam in desc.live_cameras {
    if cam.ready do pyramid_record(b, pass, &cam)
  }
  if desc.batch_count == 0 do return
  wgpu.ComputePassEncoderSetBindGroup(pass, 0, b.scene_groups[.CULL])
  for &cam in desc.live_cameras {
    cull_dispatch(b, pass, desc, cam.next_slot, rhi.CAMERA_VIEW_BASE + cam.index, 1, cam.pyramid)
  }
  if desc.shadow_view_count > 0 {
    cull_dispatch(b, pass, desc, desc.shadow_draw_list, rhi.SHADOW_VIEW_BASE, desc.shadow_view_count, 0)
  }
}

// Zeroes slot's visible-node counts, which the cull adds to.
@(private = "file")
counts_clear :: proc(b: ^Backend, encoder: wgpu.CommandEncoder, slot: u32) {
  dl := &b.draw_lists[slot]
  wgpu.CommandEncoderClearBuffer(encoder, dl.buffer, 0, u64(dl.draws_base) * size_of(u32))
}

// Fills `views` lists of slot from views first_view ...
@(private = "file")
cull_dispatch :: proc(
  b: ^Backend,
  pass: wgpu.ComputePassEncoder,
  desc: ^rhi.FrameDesc,
  slot, first_view, views: u32,
  pyramid: rhi.TextureHandle,
) {
  dl := &b.draw_lists[slot]
  u := CullUniforms {
    node_count      = desc.node_count,
    first_view      = first_view,
    instance_stride = dl.instance_stride,
    draws_base      = dl.draws_base,
    instances_base  = dl.instances_base,
    max_batches     = rhi.MAX_BATCHES,
    batch_count     = desc.batch_count,
  }
  offset := uniform(b, &u)
  wgpu.ComputePassEncoderSetBindGroup(pass, 2, b.frame_group, {offset})
  wgpu.ComputePassEncoderSetBindGroup(pass, 3, cull_group(b, slot, pyramid))
  wgpu.ComputePassEncoderSetPipeline(pass, b.finalize_pipeline)
  wgpu.ComputePassEncoderDispatchWorkgroups(pass, (desc.batch_count + 63) / 64, views, 1)
  if desc.node_count == 0 do return
  wgpu.ComputePassEncoderSetPipeline(pass, b.cull_pipeline)
  wgpu.ComputePassEncoderDispatchWorkgroups(pass, (desc.node_count + 63) / 64, views, 1)
}

// One dispatch per mip: mip 0 from the depth image, each other from the mip above.
@(private = "file")
pyramid_record :: proc(b: ^Backend, pass: wgpu.ComputePassEncoder, cam: ^rhi.FrameCamera) {
  t := &b.textures[cam.pyramid]
  offset := uniform(b, &[1]u32{0})
  wgpu.ComputePassEncoderSetBindGroup(pass, 2, b.frame_group, {offset})
  for mip in 0 ..< t.desc.mip_levels {
    from_depth := mip == 0
    key := ReduceKey{cam.slot, mip, cam.prev_depth if from_depth else 0}
    g, cached := b.reduce_groups[key]
    if !cached {
      src := b.textures[cam.prev_depth].view if from_depth else b.pyramid_views[cam.slot][mip - 1]
      entries := [?]wgpu.BindGroupEntry{{binding = 0, textureView = src}, {binding = 1, textureView = b.pyramid_views[cam.slot][mip]}}
      g = wgpu.DeviceCreateBindGroup(b.device, &{layout = b.reduce_layouts[int(from_depth)], entryCount = len(entries), entries = raw_data(entries[:])})
      b.reduce_groups[key] = g
    }
    wgpu.ComputePassEncoderSetPipeline(pass, b.reduce_pipelines[int(from_depth)])
    wgpu.ComputePassEncoderSetBindGroup(pass, 3, g)
    size := [2]u32{max(t.desc.extent.x >> mip, 1), max(t.desc.extent.y >> mip, 1)}
    wgpu.ComputePassEncoderDispatchWorkgroups(pass, (size.x + 7) / 8, (size.y + 7) / 8, 1)
  }
}

// A bind group for this frame only, released once it is submitted.
@(private)
frame_group :: proc(b: ^Backend, layout: wgpu.BindGroupLayout, entries: []wgpu.BindGroupEntry) -> wgpu.BindGroup {
  g := wgpu.DeviceCreateBindGroup(b.device, &{layout = layout, entryCount = len(entries), entries = raw_data(entries)})
  append(&b.frame_groups, g)
  return g
}

// Draws each of `types`' batches, each type with its pipeline, from list `list` of slot's draw
// lists: one indirect draw per batch, its nodes the instance stream at the batch's range.
// Mesh buffers, the scene group and the frame group are bound by the caller.
@(private)
draw_batches :: proc(
  b: ^Backend,
  desc: ^rhi.FrameDesc,
  pass: wgpu.RenderPassEncoder,
  slot, list: u32,
  types: []rhi.MaterialType,
  pipelines: []wgpu.RenderPipeline,
  // bind each material's textures (group 1)
  bind_materials := true,
) {
  if desc.batch_count == 0 do return
  batches := table(desc, .BATCHES, BatchData)[:desc.batch_count]
  materials := table(desc, .MATERIALS, MaterialData)
  textures := table(desc, .MATERIALS, [16]u32)
  dl := &b.draw_lists[slot]
  for type, t in types {
    pipeline_set := false
    material: u32 = 0
    for batch, id in batches {
      if batch.capacity == 0 || materials[batch.material_id].type != type do continue
      if !pipeline_set {
        wgpu.RenderPassEncoderSetPipeline(pass, pipelines[t])
        pipeline_set = true
      }
      if bind_materials && batch.material_id != material {
        material = batch.material_id
        key := GroupKey{layout = .MATERIAL}
        for j in 0 ..< 4 do key.textures[j] = rhi.TextureHandle(textures[material][j])
        wgpu.RenderPassEncoderSetBindGroup(pass, 1, group(b, key))
      }
      instances := u64(dl.instances_base + list * dl.instance_stride + batch.first_instance) * size_of(u32)
      wgpu.RenderPassEncoderSetVertexBuffer(pass, 1, dl.buffer, instances, u64(batch.capacity) * size_of(u32))
      draw := u64(dl.draws_base + (list * rhi.MAX_BATCHES + u32(id)) * DRAW_WORDS) * size_of(u32)
      if type in PULLED_TYPES {
        wgpu.RenderPassEncoderDrawIndirect(pass, dl.buffer, draw)
      } else {
        wgpu.RenderPassEncoderDrawIndexedIndirect(pass, dl.buffer, draw)
      }
    }
  }
}

// Copies the main camera's opaque draw count out; the latest that came back is draw_count's.
@(private)
draw_count_record :: proc(b: ^Backend, encoder: wgpu.CommandEncoder, slot: u32) {
  for &r in b.draw_count_readback {
    if r.pending do continue
    wgpu.CommandEncoderCopyBufferToBuffer(encoder, b.draw_lists[slot].buffer, 0, r.buffer, 0, size_of(u32))
    r.pending = true
    r.copied = true
    return
  }
}

// After submission: maps what draw_count_record copied.
@(private)
draw_count_map :: proc(b: ^Backend) {
  for &r in b.draw_count_readback {
    if !r.copied do continue
    r.copied = false
    wgpu.BufferMapAsync(r.buffer, {.Read}, 0, size_of(u32), {mode = .AllowProcessEvents, callback = draw_count_mapped, userdata1 = b, userdata2 = &r})
  }
}

@(private = "file")
draw_count_mapped :: proc "c" (status: wgpu.MapAsyncStatus, message: wgpu.StringView, userdata1, userdata2: rawptr) {
  b := cast(^Backend)userdata1
  r := cast(^DrawCountReadback)userdata2
  if status == .Success {
    value := wgpu.BufferGetConstMappedRangeSlice(r.buffer, 0, 1, u32)
    b.draw_count_value = value[0]
    wgpu.BufferUnmap(r.buffer)
  }
  r.pending = false
}

@(private)
DrawCountReadback :: struct {
  buffer:  wgpu.Buffer,
  // copied this frame, to map once submitted
  copied:  bool,
  // copied or mapping
  pending: bool,
}

// draw_count is the opaque draws the main camera's cull wrote, a few frames back.
draw_count :: proc(b: ^Backend, frame_index: u32) -> u32 {
  return b.draw_count_value
}

package wgpu_backend

import "core:slice"
import wgpu "vendor:wgpu"

// Depth pyramids and draw lists live in slots render assigns: a pyramid and a draw-list slot
// per camera (and frame in flight: one), plus a draw-list slot for the shadow views.
MAX_PYRAMID_SLOTS :: MAX_ACTIVE_CAMERAS * FRAMES_IN_FLIGHT
MAX_DRAW_LIST_SLOTS :: (MAX_ACTIVE_CAMERAS + 1) * FRAMES_IN_FLIGHT

// mips a depth pyramid may have
@(private)
MAX_DEPTH_MIPS :: 16

// Each frame the CPU lists the candidates, the nodes any view may draw, sorted by material
// type then material, and uploads them. A cull dispatch tests candidate i against each of its
// views and writes the indirect draw of (view, i), zero instances when culled; the draw loop
// walks the candidates and issues every draw of its pass, its node index read from the
// candidate list as an instance attribute. Shadow views take the opaque candidates, at most
// `capacity / views` each.

// Types whose shaders pull vertices from the index buffer: the cull writes a non-indexed draw
// (DrawIndirect in the first 16 bytes) of two vertices per triangle edge for wireframe, one
// per index for random color.
@(private)
PULLED_TYPES :: bit_set[MaterialType]{.WIREFRAME, .RANDOM_COLOR}

@(private)
DrawCommand :: struct {
  index_count:    u32,
  instance_count: u32,
  first_index:    u32,
  vertex_offset:  i32,
  first_instance: u32,
}

@(private = "file")
CullUniforms :: struct {
  candidate_count: u32,
  first_view:      u32,
  // draws per view in the list
  stride:          u32,
  // draw_counts entry counting the visible opaque draws
  count_slot:      u32,
}

@(private)
CULL_WGSL :: #load("shader/common.wgsl", string) + #load("shader/cull.wgsl", string)
// [from_depth]
@(private = "file")
DEPTH_REDUCE_WGSL := [2]string {
  #load("shader/common.wgsl", string) + #load("shader/depth_reduce_from_mip.wgsl", string) + #load("shader/depth_reduce.wgsl", string),
  #load("shader/common.wgsl", string) + #load("shader/depth_reduce_from_depth.wgsl", string) + #load("shader/depth_reduce.wgsl", string),
}

@(private)
cull_init :: proc(b: ^Backend) {
  b.candidate_buffer = buffer_create(b, MAX_NODES_IN_SCENE * size_of(u32), {.Storage, .Vertex, .CopyDst})
  b.draw_count_buffer = buffer_create(b, MAX_DRAW_LIST_SLOTS * size_of(u32), {.Storage, .CopySrc, .CopyDst})
  for &r in b.draw_count_readback do r.buffer = buffer_create(b, size_of(u32), {.MapRead, .CopyDst})
  list_entries := [?]wgpu.BindGroupLayoutEntry {
    {binding = 0, visibility = {.Compute}, buffer = {type = .Storage}},
    {binding = 1, visibility = {.Compute}, texture = {sampleType = .UnfilterableFloat, viewDimension = ._2D}},
  }
  b.cull_layout = wgpu.DeviceCreateBindGroupLayout(b.device, &{entryCount = len(list_entries), entries = raw_data(list_entries[:])})
  b.cull_pipeline = compute_pipeline(b, CULL_WGSL, .CULL, .NONE, b.cull_layout)
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

// draw_list_create makes draw-list slot `slot`: one draw per candidate and view, `capacity`
// draws per list (`lists` lists: one draw per node serves every type here).
draw_list_create :: proc(b: ^Backend, slot, lists, capacity: u32) -> bool {
  b.draw_lists[slot] = buffer_create(b, int(capacity) * size_of(DrawCommand), {.Storage, .Indirect})
  b.draw_list_capacity[slot] = capacity
  return b.draw_lists[slot] != nil
}

// draw_list_destroy releases slot's draw lists; WebGPU keeps them for submitted work.
draw_list_destroy :: proc(b: ^Backend, slot: u32) {
  if b.draw_lists[slot] == nil do return
  wgpu.BufferRelease(b.draw_lists[slot])
  b.draw_lists[slot] = nil
  b.draw_list_capacity[slot] = 0
}

// pyramid_create makes pyramid slot `slot` build into `pyramid`, a mipmapped R32F storage
// texture render made: a storage view per mip.
pyramid_create :: proc(b: ^Backend, slot: u32, pyramid: TextureHandle) -> bool {
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
}

// Lists and uploads this frame's candidates; per-type ranges in b.type_first, b.type_count.
@(private)
candidates_collect :: proc(b: ^Backend, desc: ^FrameDesc) {
  nodes := table(desc, .NODES, NodeData)[:desc.node_count]
  materials := table(desc, .MATERIALS, MaterialData)
  keys := make([dynamic]u64, 0, len(nodes), context.temp_allocator)
  for &node, i in nodes {
    if node.mesh_id == 0 || node.material_id == 0 || node.flags & NODE_VISIBLE == 0 do continue
    type := u64(materials[node.material_id].type)
    append(&keys, type << 48 | u64(node.material_id) << 24 | u64(i))
  }
  slice.sort(keys[:])
  clear(&b.candidates)
  b.type_first, b.type_count = {}, {}
  for key, i in keys {
    append(&b.candidates, u32(key & 0xFFFFFF))
    type := MaterialType(key >> 48)
    if b.type_count[type] == 0 do b.type_first[type] = u32(i)
    b.type_count[type] += 1
  }
  if len(b.candidates) > 0 {
    wgpu.QueueWriteBuffer(b.queue, b.candidate_buffer, 0, raw_data(b.candidates), uint(len(b.candidates) * size_of(u32)))
  }
}

// Builds each ready camera's pyramid from its previous depth, then culls every camera into its
// draw list and the shadow views into theirs. Before any pass of the frame draws.
@(private)
cull_record :: proc(b: ^Backend, desc: ^FrameDesc, encoder: wgpu.CommandEncoder) {
  wgpu.CommandEncoderClearBuffer(encoder, b.draw_count_buffer, 0, wgpu.BufferGetSize(b.draw_count_buffer))
  candidates := u32(len(b.candidates))
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
  if candidates == 0 do return
  wgpu.ComputePassEncoderSetPipeline(pass, b.cull_pipeline)
  wgpu.ComputePassEncoderSetBindGroup(pass, 0, b.scene_groups[.CULL])
  for &cam in desc.live_cameras {
    u := CullUniforms{candidates, CAMERA_VIEW_BASE + cam.index, 0, cam.next_slot}
    cull_dispatch(b, pass, &u, cam.next_slot, b.textures[cam.pyramid].view, candidates, 1)
  }
  views := desc.shadow_view_count
  opaque := b.type_count[.PBR]
  if views > 0 && opaque > 0 {
    stride := min(opaque, b.draw_list_capacity[desc.shadow_draw_list] / views)
    b.shadow_stride = stride
    u := CullUniforms{stride, SHADOW_VIEW_BASE, stride, MAX_DRAW_LIST_SLOTS - 1}
    cull_dispatch(b, pass, &u, desc.shadow_draw_list, b.white.view, stride, views)
  }
}

@(private = "file")
cull_dispatch :: proc(
  b: ^Backend,
  pass: wgpu.ComputePassEncoder,
  u: ^CullUniforms,
  slot: u32,
  pyramid: wgpu.TextureView,
  count, views: u32,
) {
  entries := [?]wgpu.BindGroupEntry {
    {binding = 0, buffer = b.draw_lists[slot], size = wgpu.BufferGetSize(b.draw_lists[slot])},
    {binding = 1, textureView = pyramid},
  }
  g := frame_group(b, b.cull_layout, entries[:])
  offset := uniform(b, u)
  wgpu.ComputePassEncoderSetBindGroup(pass, 2, b.frame_group, {offset})
  wgpu.ComputePassEncoderSetBindGroup(pass, 3, g)
  wgpu.ComputePassEncoderDispatchWorkgroups(pass, (count + 63) / 64, views, 1)
}

// One dispatch per mip: mip 0 from the depth image, each other from the mip above.
@(private = "file")
pyramid_record :: proc(b: ^Backend, pass: wgpu.ComputePassEncoder, cam: ^FrameCamera) {
  t := &b.textures[cam.pyramid]
  offset := uniform(b, &[1]u32{0})
  wgpu.ComputePassEncoderSetBindGroup(pass, 2, b.frame_group, {offset})
  for mip in 0 ..< t.desc.mip_levels {
    from_depth := mip == 0
    src := b.textures[cam.prev_depth].view if from_depth else b.pyramid_views[cam.slot][mip - 1]
    entries := [?]wgpu.BindGroupEntry{{binding = 0, textureView = src}, {binding = 1, textureView = b.pyramid_views[cam.slot][mip]}}
    wgpu.ComputePassEncoderSetPipeline(pass, b.reduce_pipelines[int(from_depth)])
    wgpu.ComputePassEncoderSetBindGroup(pass, 3, frame_group(b, b.reduce_layouts[int(from_depth)], entries[:]))
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

// Issues the draws of each of `types`' candidates (at most `limit` each) with its pipeline,
// candidate i's draw at `base` + i in slot's list. Mesh buffers, the scene group and the frame
// group are bound by the caller.
@(private)
draw_candidates :: proc(
  b: ^Backend,
  desc: ^FrameDesc,
  pass: wgpu.RenderPassEncoder,
  slot: u32,
  base: u32,
  types: []MaterialType,
  pipelines: []wgpu.RenderPipeline,
  limit: u32 = max(u32),
  // bind each material's textures (group 1)
  bind_materials := true,
) {
  nodes := table(desc, .NODES, NodeData)
  materials := table(desc, .MATERIALS, [16]u32)
  list := b.draw_lists[slot]
  for type, t in types {
    first := b.type_first[type]
    count := min(b.type_count[type], limit)
    if count == 0 do continue
    wgpu.RenderPassEncoderSetPipeline(pass, pipelines[t])
    material: u32 = 0
    for i in first ..< first + count {
      node := b.candidates[i]
      if m := nodes[node].material_id; bind_materials && m != material {
        material = m
        textures := materials[m]
        key := GroupKey{layout = .MATERIAL}
        for j in 0 ..< 4 do key.textures[j] = TextureHandle(textures[j])
        wgpu.RenderPassEncoderSetBindGroup(pass, 1, group(b, key))
      }
      wgpu.RenderPassEncoderSetVertexBuffer(pass, 1, b.candidate_buffer, u64(i) * size_of(u32), size_of(u32))
      offset := u64(base + i) * size_of(DrawCommand)
      if type in PULLED_TYPES {
        wgpu.RenderPassEncoderDrawIndirect(pass, list, offset)
      } else {
        wgpu.RenderPassEncoderDrawIndexedIndirect(pass, list, offset)
      }
    }
  }
}

// Copies the main camera's opaque draw count out; the latest that came back is draw_count's.
@(private)
draw_count_record :: proc(b: ^Backend, encoder: wgpu.CommandEncoder, slot: u32) {
  for &r in b.draw_count_readback {
    if r.pending do continue
    wgpu.CommandEncoderCopyBufferToBuffer(encoder, b.draw_count_buffer, u64(slot) * size_of(u32), r.buffer, 0, size_of(u32))
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

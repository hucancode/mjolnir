package render

import "../containers"
import "core:log"
import "core:slice"
import "rhi"

// The GPU resources render owns, all made through rhi: the table and mesh buffers the scene
// lives in, the particle and UI buffers, and how shaders reach them. Where the device is
// bindless (Vulkan) every pipeline shares one scene set and textures are indices; elsewhere
// (WebGPU) each pass binds the scene buffers it reads as a group of its own and its textures
// as another.

// The groups of scene buffers a pass reads.
@(private)
ScenePass :: enum {
  NONE,
  // material vertex and fragment shaders
  MESH,
  // the sprite material's vertex and fragment shaders
  SPRITE,
  // the lighting compute shader
  LIGHTING,
  // the ambient occlusion compute shader
  AMBIENT_OCCLUSION,
  // the shadow depth vertex shader
  SHADOW,
  CULL,
  PARTICLE_EMIT,
  PARTICLE_SIMULATE,
  PARTICLE_DRAW,
  DEBUG_LINE,
  // the skinning compute shader
  SKIN,
  // your shaders (gpu.odin)
  USER,
}

// The buffers render owns: first every Table, in its order (SceneBuffer(t) is table t's), then
// the buffers with one copy.
@(private)
SceneBuffer :: enum {
  VIEWS,
  NODES,
  MESHES,
  MATERIALS,
  BONES,
  EMITTERS,
  FORCE_FIELDS,
  LIGHTS,
  DEBUG_LINES,
  BATCHES,
  NODE_BATCH,
  SKIN_OWNERS,
  LIGHT_PLACEMENTS,
  EMITTER_PLACEMENTS,
  FORCE_FIELD_PLACEMENTS,
  SPRITE_FRAMES,
  // the mesh streams, in MeshStream order
  VERTICES,
  INDICES,
  SKINNING,
  // what the skinning pass writes: SkinnedVertex per skin slab entry
  SKINNED_VERTICES,
  // the particle ring, and the alive list whose header is the indirect draw
  PARTICLES,
  PARTICLE_ALIVE,
  // the shadow atlas, a texture; only in the scene set of a bindless device
  SHADOW_MAPS,
  // the 2D overlay's vertices and indices, per frame in flight
  OVERLAY_VERTICES,
  OVERLAY_INDICES,
  // bindless: the pyramid build's per-slot counters
  PYRAMID_COUNTERS,
}
#assert(int(SceneBuffer.SKIN_OWNERS) == int(Table.SKIN_OWNERS) && len(Table) == int(SceneBuffer.VERTICES))
#assert(int(SceneBuffer.SKINNING) - int(SceneBuffer.VERTICES) == int(MeshStream.SKINNING))

// The buffer of a mesh stream.
@(private)
mesh_buffer :: #force_inline proc(self: ^Renderer, stream: MeshStream) -> rhi.Buffer {
  return self.buffers[mesh_scene_buffer(stream)][0]
}

@(private)
mesh_scene_buffer :: #force_inline proc(stream: MeshStream) -> SceneBuffer {
  return SceneBuffer(int(SceneBuffer.VERTICES) + int(stream))
}

// The scene set of a bindless device: the shaders' set 0, bindings in this order, every one
// visible to every stage.
@(private = "file")
SCENE_SET :: [?]SceneBuffer {
  .VIEWS,
  .NODES,
  .MESHES,
  .MATERIALS,
  .BONES,
  .SKINNING,
  .EMITTERS,
  .FORCE_FIELDS,
  .PARTICLES,
  .PARTICLE_ALIVE,
  .LIGHTS,
  .SHADOW_MAPS,
  .DEBUG_LINES,
  .BATCHES,
  .NODE_BATCH,
  .SKIN_OWNERS,
  .SKINNED_VERTICES,
  .VERTICES,
  .LIGHT_PLACEMENTS,
  .EMITTER_PLACEMENTS,
  .FORCE_FIELD_PLACEMENTS,
  .SPRITE_FRAMES,
}
// The scene groups of a device without bindless: the buffers each pass reads (or, for
// compute, writes), in binding order.
@(private = "file")
SCENE_PASSES := [ScenePass]struct {
  buffers:    []SceneBuffer,
  stages:     bit_set[rhi.ShaderStage],
  // bound read-write (compute only); the rest read-only
  writes:     bit_set[SceneBuffer],
} {
  .NONE              = {},
  .MESH              = {{.VIEWS, .NODES, .MESHES, .MATERIALS, .SKINNED_VERTICES, .VERTICES, .INDICES, .LIGHTS}, {.VERTEX, .FRAGMENT}, {}},
  // MESH is at WebGPU's 8 storage buffers a stage: the sprite pass takes its own
  .SPRITE            = {{.VIEWS, .NODES, .SPRITE_FRAMES, .MATERIALS}, {.VERTEX, .FRAGMENT}, {}},
  .LIGHTING          = {{.VIEWS, .LIGHTS, .NODES, .LIGHT_PLACEMENTS}, {.COMPUTE}, {}},
  .AMBIENT_OCCLUSION = {{.VIEWS}, {.COMPUTE}, {}},
  .SHADOW            = {{.VIEWS, .NODES, .MESHES, .SKINNED_VERTICES}, {.VERTEX}, {}},
  .CULL              = {{.VIEWS, .NODES, .MESHES, .MATERIALS, .BATCHES, .NODE_BATCH, .SPRITE_FRAMES}, {.COMPUTE}, {}},
  .PARTICLE_EMIT     = {{.NODES, .EMITTERS, .PARTICLES, .EMITTER_PLACEMENTS}, {.COMPUTE}, {.PARTICLES}},
  .PARTICLE_SIMULATE = {{.NODES, .FORCE_FIELDS, .PARTICLES, .PARTICLE_ALIVE, .FORCE_FIELD_PLACEMENTS}, {.COMPUTE}, {.PARTICLES, .PARTICLE_ALIVE}},
  .PARTICLE_DRAW     = {{.VIEWS, .PARTICLES, .PARTICLE_ALIVE}, {.VERTEX}, {}},
  .DEBUG_LINE        = {{.VIEWS, .DEBUG_LINES}, {.VERTEX}, {}},
  .SKIN              = {{.NODES, .MESHES, .BONES, .SKINNING, .VERTICES, .SKIN_OWNERS, .SKINNED_VERTICES}, {.COMPUTE}, {.SKINNED_VERTICES}},
  .USER              = {{.VIEWS}, {.VERTEX, .FRAGMENT, .COMPUTE}, {}},
}

// Texture groups of a device without bindless: each slot is a texture of this kind.
@(private)
TextureSlot :: enum {
  FLOAT,
  DEPTH,
  CUBE,
  // the shadow atlas, whatever the key holds
  SHADOW_ATLAS,
}

@(private)
TextureLayout :: enum {
  NONE,
  // albedo, metallic-roughness, normal, emissive
  MATERIAL,
  // normal, albedo, metallic-roughness, emissive, depth, shadow atlas, irradiance, prefilter,
  // BRDF LUT, environment, ambient occlusion
  LIGHTING,
  // normal, depth
  AMBIENT_OCCLUSION,
  // input, second, normal, depth
  POST,
  SINGLE,
  PARTICLES,
}

@(private)
MAX_GROUP_TEXTURES :: 11

@(private = "file")
TEXTURE_LAYOUTS := [TextureLayout][]TextureSlot {
  .NONE      = {},
  .MATERIAL  = {.FLOAT, .FLOAT, .FLOAT, .FLOAT},
  .LIGHTING  = {.FLOAT, .FLOAT, .FLOAT, .FLOAT, .DEPTH, .SHADOW_ATLAS, .CUBE, .CUBE, .FLOAT, .FLOAT, .FLOAT},
  .AMBIENT_OCCLUSION = {.FLOAT, .DEPTH},
  .POST      = {.FLOAT, .FLOAT, .FLOAT, .DEPTH},
  .SINGLE    = {.FLOAT},
  .PARTICLES = {.FLOAT, .FLOAT, .FLOAT, .FLOAT, .FLOAT, .FLOAT, .FLOAT, .FLOAT},
}

// Texture bind groups by what they bind; textures change only between frames, so any change
// drops them all.
@(private)
TextureGroupKey :: struct {
  layout:   TextureLayout,
  textures: [MAX_GROUP_TEXTURES]TextureHandle,
}

// The bytes of push constants (Vulkan) or the uniform entry (WebGPU) a draw or dispatch takes.
@(private)
PUSH_SIZE :: 128

// How render makes each buffer: usage and memory. Tables are written by the CPU every frame.
@(private = "file")
buffer_desc :: proc(buffer: SceneBuffer, size: int) -> rhi.BufferDesc {
  #partial switch buffer {
  // wireframe and random-color materials pull vertices and indices as storage (WebGPU)
  case .VERTICES:
    return {size = size, usage = {.VERTEX, .STORAGE, .COPY_SRC, .COPY_DST}}
  case .INDICES:
    return {size = size, usage = {.INDEX, .STORAGE, .COPY_SRC, .COPY_DST}}
  case .SKINNING:
    return {size = size, usage = {.STORAGE, .COPY_SRC, .COPY_DST}}
  case .SKINNED_VERTICES, .PARTICLES:
    return {size = size, usage = {.STORAGE}}
  case .PARTICLE_ALIVE:
    return {size = size, usage = {.STORAGE, .INDIRECT}}
  case .OVERLAY_VERTICES:
    return {size = size, usage = {.VERTEX}, memory = .UPLOAD}
  case .OVERLAY_INDICES:
    return {size = size, usage = {.INDEX}, memory = .UPLOAD}
  }
  return {size = size, usage = {.STORAGE}, memory = .UPLOAD}
}

// Makes copy f of buffer, `size` bytes, retiring the one it replaces.
@(private)
buffer_replace :: proc(self: ^Renderer, buffer: SceneBuffer, f: int, size: int) -> bool {
  made := dev.buffer_create(&self.gpu, buffer_desc(buffer, size)) or_return
  if old := self.buffers[buffer][f]; old != 0 do dev.buffer_retire(&self.gpu, old)
  self.buffers[buffer][f], self.buffer_sizes[buffer][f] = made, size
  return true
}

@(private)
resources_init :: proc(self: ^Renderer) -> bool {
  for t in Table do for f in 0 ..< FRAMES_IN_FLIGHT do buffer_replace(self, SceneBuffer(t), f, len(self.tables[t])) or_return
  for stream in MeshStream {
    size := int(self.mesh_ranges[stream].capacity) * MESH_STREAMS[stream].elem_size
    buffer_replace(self, mesh_scene_buffer(stream), 0, size) or_return
  }
  buffer_replace(self, .SKINNED_VERTICES, 0, table_capacity(self, .SKIN_OWNERS) * size_of(SkinnedVertex)) or_return
  buffer_replace(self, .PARTICLE_ALIVE, 0, (PARTICLE_ALIVE_HEADER + int(self.config.particles)) * size_of(u32)) or_return
  buffer_replace(self, .PARTICLES, 0, int(self.config.particles) * size_of(Particle)) or_return
  for f in 0 ..< FRAMES_IN_FLIGHT {
    buffer_replace(self, .OVERLAY_VERTICES, f, int(self.config.overlay_vertices) * size_of(Vertex2D)) or_return
    buffer_replace(self, .OVERLAY_INDICES, f, int(self.config.overlay_indices) * size_of(u32)) or_return
  }
  return true
}

// Grows frame f's copies to what render holds, once the frame's previous submission is done:
// a table's copy that is smaller than the table is replaced and written whole, the skinned
// vertices follow the skin owner table, and frame f's scene groups follow what was replaced.
@(private)
buffers_reserve :: proc(self: ^Renderer, f: u32) -> bool {
  for t in Table {
    if self.buffer_sizes[SceneBuffer(t)][f] >= len(self.tables[t]) do continue
    buffer_replace(self, SceneBuffer(t), int(f), len(self.tables[t])) or_return
    tables_stale_all(self, t, int(f))
    self.groups_stale[f] = true
  }
  // rewritten whole by every frame's skinning, so nothing to copy; every frame binds the one copy
  skinned := table_capacity(self, .SKIN_OWNERS) * size_of(SkinnedVertex)
  if self.buffer_sizes[.SKINNED_VERTICES][0] < skinned {
    buffer_replace(self, .SKINNED_VERTICES, 0, skinned) or_return
    self.groups_stale = true
  }
  if !self.groups_stale[f] do return true
  self.groups_stale[f] = false
  return scene_groups_make(self, int(f))
}

// mesh_stream_reserve grows a mesh stream's buffer to hold `need` more elements than its
// ranges hold, at least doubling: the new buffer takes the old one's contents on the GPU, in
// order with the uploads before and after, and every frame's scene groups follow.
@(private)
mesh_stream_reserve :: proc(self: ^Renderer, stream: MeshStream, need: u32) -> bool {
  ranges := &self.mesh_ranges[stream]
  capacity := max(ranges.capacity + need, ranges.capacity * 2)
  buffer := mesh_scene_buffer(stream)
  old, old_size := self.buffers[buffer][0], self.buffer_sizes[buffer][0]
  size := int(capacity) * MESH_STREAMS[stream].elem_size
  made := dev.buffer_create(&self.gpu, buffer_desc(buffer, size)) or_return
  dev.buffer_copy(&self.gpu, old, 0, made, 0, old_size)
  dev.buffer_retire(&self.gpu, old)
  self.buffers[buffer][0], self.buffer_sizes[buffer][0] = made, size
  containers.ranges_grow(ranges, capacity)
  self.groups_stale = true
  return true
}

// After the textures and particle buffers exist: the layouts and groups shaders reach them by.
@(private)
resources_bind :: proc(self: ^Renderer) -> bool {
  white := TextureDesc{extent = {1, 1}, format = .RGBA8_UNORM, usage = {.SAMPLED}}
  atlas_make(self, MIN_ATLAS_LAYERS) or_return
  self.white = allocate_texture(self, white, {255, 255, 255, 255}) or_return
  cube := TextureDesc{extent = {1, 1}, format = .RGBA16F, usage = {.SAMPLED}, cube = true}
  self.black_cube = allocate_texture(self, cube, make([]u8, 6 * 8, context.temp_allocator)) or_return
  self.default_depth = allocate_texture(self, {extent = {1, 1}, format = .D32F, usage = {.DEPTH_TARGET, .SAMPLED}}) or_return
  when BINDLESS {
    entries: [len(SCENE_SET)]rhi.BindEntry
    for e, i in SCENE_SET do entries[i] = {kind = .TEXTURE_DEPTH_ARRAY if e == .SHADOW_MAPS else .STORAGE_BUFFER, stages = {.VERTEX, .FRAGMENT, .COMPUTE}}
    self.scene_layouts[.NONE] = dev.bind_layout_create(&self.gpu, {entries = entries[:]}) or_return
    for f in 0 ..< FRAMES_IN_FLIGHT do scene_group_make(self, f) or_return
  } else {
    for pass, p in SCENE_PASSES {
      entries := make([]rhi.BindEntry, len(pass.buffers), context.temp_allocator)
      for buffer, i in pass.buffers do entries[i] = {kind = .STORAGE_BUFFER if buffer in pass.writes else .STORAGE_BUFFER_READ, stages = pass.stages}
      self.scene_layouts[p] = dev.bind_layout_create(&self.gpu, {entries = entries}) or_return
    }
    for f in 0 ..< FRAMES_IN_FLIGHT do scene_groups_make(self, f) or_return
    for slots, l in TEXTURE_LAYOUTS {
      entries := make([]rhi.BindEntry, len(slots), context.temp_allocator)
      for slot, i in slots do entries[i] = {kind = TEXTURE_SLOT_KINDS[slot], stages = {.VERTEX, .FRAGMENT, .COMPUTE}}
      self.texture_layouts[l] = dev.bind_layout_create(&self.gpu, {entries = entries}) or_return
    }
  }
  return true
}

@(private = "file")
TEXTURE_SLOT_KINDS := [TextureSlot]rhi.BindKind {
  .FLOAT        = .TEXTURE_FLOAT,
  .DEPTH        = .TEXTURE_DEPTH,
  .CUBE         = .TEXTURE_CUBE,
  // bind groups are WebGPU's, whose atlas is one 2D texture of tiles (pass_shadow.odin)
  .SHADOW_ATLAS = .TEXTURE_DEPTH,
}

// Frame `frame`'s copy of a table, the one copy of the rest.
@(private = "file")
scene_buffer :: proc(self: ^Renderer, buffer: SceneBuffer, frame: u32) -> rhi.Buffer {
  return self.buffers[buffer][frame if int(buffer) < len(Table) else 0]
}

// Frame f's scene groups, over the buffers as they are now: call again when one is replaced,
// before frame f records. The old groups retire.
@(private)
scene_groups_make :: proc(self: ^Renderer, f: int) -> bool {
  when BINDLESS {
    return scene_group_make(self, f)
  } else {
    for pass, p in SCENE_PASSES {
      if len(pass.buffers) == 0 do continue
      resources := make([]rhi.BindResource, len(pass.buffers), context.temp_allocator)
      for buffer, i in pass.buffers do resources[i] = rhi.BufferRange{buffer = scene_buffer(self, buffer, u32(f))}
      old := self.scene_groups[p][f]
      self.scene_groups[p][f] = dev.bind_group_create(&self.gpu, {layout = self.scene_layouts[p], resources = resources}) or_return
      if old != 0 do dev.bind_group_retire(&self.gpu, old)
    }
    return true
  }
}

// The bindless scene set of frame `f`, with the frame's shadow atlas. Call again when the
// atlas changes, once no submitted work reads the old group.
@(private)
scene_group_make :: proc(self: ^Renderer, f: int) -> bool {
  old := self.scene_groups[.NONE][f]
  resources: [len(SCENE_SET)]rhi.BindResource
  for e, i in SCENE_SET {
    if e == .SHADOW_MAPS {
      resources[i] = rhi.TextureView{texture = self.atlas, mip = -1}
    } else {
      resources[i] = rhi.BufferRange{buffer = scene_buffer(self, e, u32(f))}
    }
  }
  self.scene_groups[.NONE][f] = dev.bind_group_create(&self.gpu, {layout = self.scene_layouts[.NONE], resources = resources[:]}) or_return
  if old != 0 do dev.bind_group_retire(&self.gpu, old)
  return true
}

// Brings frame `f`'s copy of every table up to date with render's: a region render wrote goes
// stale in every copy and is written into each as its frame comes up.
@(private)
tables_sync :: proc(self: ^Renderer, f: u32) {
  tables_publish(self)
  for t in Table {
    region: int
    for lo, hi in tables_next_stale(self, t, int(f), &region) {
      dev.buffer_write(&self.gpu, self.buffers[SceneBuffer(t)][f], lo, self.tables[t][lo:hi])
    }
  }
}

// Binds the scene set (set 0) of `pass` for the frame, and the bindless arrays where there are
// any. After the pipeline is bound.
@(private)
scene_bind :: proc(self: ^Renderer, cmd: rhi.CommandList, pass: ScenePass, f: u32) {
  when BINDLESS {
    dev.cmd_bind_group(&self.gpu, cmd, 0, self.scene_groups[.NONE][f])
    dev.cmd_bind_bindless(&self.gpu, cmd)
  } else {
    dev.cmd_bind_group(&self.gpu, cmd, 0, self.scene_groups[pass][f])
  }
}

// The set of texture slots a WebGPU pass binds as set 1; textures reach a bindless shader
// by index instead. Slot 0 takes the default of its kind.
@(private)
texture_bind :: proc(self: ^Renderer, cmd: rhi.CommandList, layout: TextureLayout, textures: ..TextureHandle) {
  when BINDLESS do return
  key := TextureGroupKey{layout = layout}
  for t, i in textures do key.textures[i] = t
  slots := TEXTURE_LAYOUTS[layout]
  resources: [MAX_GROUP_TEXTURES]rhi.BindResource
  for slot, i in slots {
    texture := key.textures[i]
    switch slot {
    case .FLOAT:
      if texture == 0 do texture = self.white
    case .DEPTH:
      if texture == 0 do texture = self.default_depth
    case .CUBE:
      if texture == 0 do texture = self.black_cube
    case .SHADOW_ATLAS:
      texture = self.atlas
    }
    resources[i] = rhi.TextureView{texture = texture, mip = -1}
  }
  group, ok := cached_group(self, key, self.texture_layouts[layout], resources[:len(slots)])
  if !ok {
    log.errorf("Texture group %v failed", layout)
    return
  }
  dev.cmd_bind_group(&self.gpu, cmd, 1, group)
}

// What a cached bind group binds (WebGPU): a pass's textures, the lighting dispatch's output
// image, a batched cull's draw list and pyramid, a pyramid mip build.
@(private)
GroupKey :: union {
  TextureGroupKey,
  TextureHandle,
  CullKey,
  ReduceKey,
}

// The bind group of `key`, made of `layout` over `resources` the first time and kept until
// groups_clear.
@(private)
cached_group :: proc(self: ^Renderer, key: GroupKey, layout: rhi.BindLayout, resources: []rhi.BindResource) -> (group: rhi.BindGroup, ok: bool) {
  if group, ok = self.bind_groups[key]; ok do return
  group = dev.bind_group_create(&self.gpu, {layout = layout, resources = resources}) or_return
  self.bind_groups[key] = group
  return group, true
}

// Binds `pipeline` and what a pass binds after it: the scene set of `scene` for frame `f`, the
// texture group of `layout` (WebGPU) and `push`. WebGPU gives every pipeline a push group, so
// every pass pushes, whether or not its shaders read it.
@(private)
pipeline_bind :: proc(self: ^Renderer, cmd: rhi.CommandList, pipeline: rhi.Pipeline, scene: ScenePass, f: u32, push: ^$T, layout: TextureLayout, textures: ..TextureHandle) {
  dev.cmd_bind_pipeline(&self.gpu, cmd, pipeline)
  scene_bind(self, cmd, scene, f)
  texture_bind(self, cmd, layout, ..textures)
  dev.cmd_push(&self.gpu, cmd, push, size_of(T))
}

// Drops every cached bind group, made again on use: a texture they name changed.
@(private)
groups_clear :: proc(self: ^Renderer) {
  for _, g in self.bind_groups do dev.bind_group_retire(&self.gpu, g)
  clear(&self.bind_groups)
}

// The layouts of a pipeline of `pass`: the scene set, then `user` (set 1, a shader of yours,
// gpu.odin), else on a device without bindless the textures (set 1); there, the push group
// (set 2) and `extra` follow. The shaders' set numbers.
@(private)
pipeline_layout :: proc(self: ^Renderer, pass: ScenePass, textures: TextureLayout = .NONE, extra: rhi.BindLayout = 0, user: rhi.BindLayout = 0) -> rhi.PipelineLayoutDesc {
  layouts := make([dynamic]rhi.BindLayout, context.temp_allocator)
  when BINDLESS {
    append(&layouts, self.scene_layouts[.NONE])
    if user != 0 do append(&layouts, user)
    return {layouts = layouts[:], push_size = PUSH_SIZE, bindless = true}
  } else {
    append(&layouts, self.scene_layouts[pass], user if user != 0 else self.texture_layouts[textures], rhi.PUSH_GROUP)
    if extra != 0 do append(&layouts, extra)
    return {layouts = layouts[:], push_size = PUSH_SIZE}
  }
}

// mesh_write uploads data at element `first` of stream's buffer before the next frame.
@(private)
mesh_write :: proc(self: ^Renderer, stream: MeshStream, data: []$T, first: u32) -> bool {
  #assert(size_of(T) % 4 == 0)
  if len(data) == 0 do return true
  return dev.buffer_write(&self.gpu, mesh_buffer(self, stream), int(first) * size_of(T), ([^]u8)(raw_data(data))[:len(data) * size_of(T)])
}

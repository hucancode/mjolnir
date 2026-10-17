package render

import "core:log"
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
  // the lighting compute shader
  LIGHTING,
  // the shadow depth vertex shader
  SHADOW,
  CULL,
  PARTICLE_EMIT,
  PARTICLE_SIMULATE,
  PARTICLE_DRAW,
  DEBUG_LINE,
  // the skinning compute shader
  SKIN,
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
}
#assert(int(SceneBuffer.SKIN_OWNERS) == int(Table.SKIN_OWNERS) && len(Table) == int(SceneBuffer.VERTICES))
#assert(int(SceneBuffer.SKINNING) - int(SceneBuffer.VERTICES) == int(MeshStream.SKINNING))

// The buffer of a mesh stream.
@(private)
mesh_buffer :: #force_inline proc(self: ^Renderer, stream: MeshStream) -> rhi.Buffer {
  return self.buffers[SceneBuffer(int(SceneBuffer.VERTICES) + int(stream))][0]
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
  .MESH              = {{.VIEWS, .NODES, .MESHES, .MATERIALS, .SKINNED_VERTICES, .VERTICES, .INDICES}, {.VERTEX, .FRAGMENT}, {}},
  .LIGHTING          = {{.VIEWS, .LIGHTS, .NODES, .LIGHT_PLACEMENTS}, {.COMPUTE}, {}},
  .SHADOW            = {{.VIEWS, .NODES, .MESHES, .SKINNED_VERTICES}, {.VERTEX}, {}},
  .CULL              = {{.VIEWS, .NODES, .MESHES, .MATERIALS, .BATCHES, .NODE_BATCH}, {.COMPUTE}, {}},
  .PARTICLE_EMIT     = {{.NODES, .EMITTERS, .PARTICLES, .EMITTER_PLACEMENTS}, {.COMPUTE}, {.PARTICLES}},
  .PARTICLE_SIMULATE = {{.NODES, .FORCE_FIELDS, .PARTICLES, .PARTICLE_ALIVE, .FORCE_FIELD_PLACEMENTS}, {.COMPUTE}, {.PARTICLES, .PARTICLE_ALIVE}},
  .PARTICLE_DRAW     = {{.VIEWS, .PARTICLES, .PARTICLE_ALIVE}, {.VERTEX}, {}},
  .DEBUG_LINE        = {{.VIEWS, .DEBUG_LINES}, {.VERTEX}, {}},
  .SKIN              = {{.NODES, .MESHES, .BONES, .SKINNING, .VERTICES, .SKIN_OWNERS, .SKINNED_VERTICES}, {.COMPUTE}, {.SKINNED_VERTICES}},
}

// Texture groups of a device without bindless: each slot is a texture of this kind.
@(private)
TextureSlot :: enum {
  FLOAT,
  UNFILTERABLE,
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
  // BRDF LUT, environment
  LIGHTING,
  // input, original, normal, depth
  POST,
  SINGLE,
  PARTICLES,
}

@(private)
MAX_GROUP_TEXTURES :: 10

@(private = "file")
TEXTURE_LAYOUTS := [TextureLayout][]TextureSlot {
  .NONE      = {},
  .MATERIAL  = {.FLOAT, .FLOAT, .FLOAT, .FLOAT},
  .LIGHTING  = {.FLOAT, .FLOAT, .FLOAT, .FLOAT, .DEPTH, .SHADOW_ATLAS, .CUBE, .CUBE, .FLOAT, .FLOAT},
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

@(private)
resources_init :: proc(self: ^Renderer) -> bool {
  for t in Table {
    size := TABLES[t].stride * TABLES[t].capacity
    for f in 0 ..< FRAMES_IN_FLIGHT {
      self.buffers[SceneBuffer(t)][f] = dev.buffer_create(&self.gpu, {size = size, usage = {.STORAGE}, memory = .UPLOAD}) or_return
    }
  }
  // wireframe and random-color materials pull vertices and indices as storage (WebGPU)
  stream_usage := [MeshStream]bit_set[rhi.BufferUsage]{.VERTEX = {.VERTEX, .STORAGE}, .INDEX = {.INDEX, .STORAGE}, .SKINNING = {.STORAGE}}
  for stream in MeshStream {
    size := int(self.mesh_slabs[stream].capacity) * MESH_STREAMS[stream].elem_size
    self.buffers[SceneBuffer(int(SceneBuffer.VERTICES) + int(stream))][0] = dev.buffer_create(&self.gpu, {size = size, usage = stream_usage[stream]}) or_return
  }
  self.buffers[.SKINNED_VERTICES][0] = dev.buffer_create(&self.gpu, {size = SKIN_CAPACITY * size_of(SkinnedVertex), usage = {.STORAGE}}) or_return
  self.buffers[.PARTICLE_ALIVE][0] = dev.buffer_create(&self.gpu, {size = (PARTICLE_ALIVE_HEADER + MAX_PARTICLES) * size_of(u32), usage = {.STORAGE, .INDIRECT}}) or_return
  self.buffers[.PARTICLES][0] = dev.buffer_create(&self.gpu, {size = MAX_PARTICLES * size_of(Particle), usage = {.STORAGE}}) or_return
  for f in 0 ..< FRAMES_IN_FLIGHT {
    self.ui_vertex_buffers[f] = dev.buffer_create(&self.gpu, {size = UI_MAX_VERTICES * size_of(Vertex2D), usage = {.VERTEX}, memory = .UPLOAD}) or_return
    self.ui_index_buffers[f] = dev.buffer_create(&self.gpu, {size = UI_MAX_INDICES * size_of(u32), usage = {.INDEX}, memory = .UPLOAD}) or_return
  }
  return true
}

// After the textures and particle buffers exist: the layouts and groups shaders reach them by.
@(private)
resources_bind :: proc(self: ^Renderer) -> bool {
  white := TextureDesc{extent = {1, 1}, format = .RGBA8_UNORM, usage = {.SAMPLED}}
  for f in 0 ..< FRAMES_IN_FLIGHT do atlas_make(self, f, MIN_ATLAS_LAYERS) or_return
  self.white = allocate_texture(self, white, {255, 255, 255, 255}) or_return
  cube := TextureDesc{extent = {1, 1}, format = .RGBA16F, usage = {.SAMPLED}, cube = true}
  self.black_cube = allocate_texture(self, cube, make([]u8, 6 * 8, context.temp_allocator)) or_return
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
      for f in 0 ..< FRAMES_IN_FLIGHT {
        resources := make([]rhi.BindResource, len(pass.buffers), context.temp_allocator)
        for buffer, i in pass.buffers do resources[i] = rhi.BufferRange{buffer = scene_buffer(self, buffer, u32(f))}
        self.scene_groups[p][f] = dev.bind_group_create(&self.gpu, {layout = self.scene_layouts[p], resources = resources}) or_return
      }
    }
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
  .UNFILTERABLE = .TEXTURE_UNFILTERABLE,
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

// The bindless scene set of frame `f`, with the frame's shadow atlas. Call again when the
// atlas changes, once no submitted work reads the old group.
@(private)
scene_group_make :: proc(self: ^Renderer, f: int) -> bool {
  old := self.scene_groups[.NONE][f]
  resources: [len(SCENE_SET)]rhi.BindResource
  for e, i in SCENE_SET {
    if e == .SHADOW_MAPS {
      resources[i] = rhi.TextureView{texture = self.atlas[f], mip = -1}
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
  for t in Table {
    for &s in self.table_stale[t] do s |= self.dirty[t]
    stale := &self.table_stale[t][f]
    if stale^ == 0 do continue
    src := self.tables[t]
    size := (len(src) + TABLE_REGIONS - 1) / TABLE_REGIONS
    region := 0
    for region < TABLE_REGIONS {
      if stale^ & (1 << u64(region)) == 0 {
        region += 1
        continue
      }
      first := region
      for region < TABLE_REGIONS && stale^ & (1 << u64(region)) != 0 do region += 1
      // buffer writes take 4-byte multiples
      lo := min(first * size, len(src)) &~ 3
      hi := min((min(region * size, len(src)) + 3) &~ 3, len(src))
      if hi > lo do dev.buffer_write(&self.gpu, self.buffers[SceneBuffer(t)][f], lo, src[lo:hi])
    }
    stale^ = 0
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
  group, ok := self.texture_groups[key]
  if !ok {
    slots := TEXTURE_LAYOUTS[layout]
    resources := make([]rhi.BindResource, len(slots), context.temp_allocator)
    for slot, i in slots {
      texture := key.textures[i]
      switch slot {
      case .FLOAT, .UNFILTERABLE, .DEPTH:
        if texture == 0 do texture = self.white
      case .CUBE:
        if texture == 0 do texture = self.black_cube
      case .SHADOW_ATLAS:
        texture = self.atlas[0]
      }
      resources[i] = rhi.TextureView{texture = texture, mip = -1}
    }
    group, ok = dev.bind_group_create(&self.gpu, {layout = self.texture_layouts[layout], resources = resources})
    if !ok {
      log.errorf("Texture group %v failed", layout)
      return
    }
    self.texture_groups[key] = group
  }
  dev.cmd_bind_group(&self.gpu, cmd, 1, group)
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
  for _, g in self.texture_groups do dev.bind_group_retire(&self.gpu, g)
  clear(&self.texture_groups)
  cull_groups_clear(self)
  for _, g in self.lighting_output_groups do dev.bind_group_retire(&self.gpu, g)
  clear(&self.lighting_output_groups)
}

// The layouts of a pipeline of `pass`: the scene set, then on a device without bindless the
// textures (set 1) and the push group (set 2) and `extra`. The shaders' set numbers.
@(private)
pipeline_layout :: proc(self: ^Renderer, pass: ScenePass, textures: TextureLayout = .NONE, extra: rhi.BindLayout = 0) -> rhi.PipelineLayoutDesc {
  when BINDLESS {
    layouts := make([]rhi.BindLayout, 1, context.temp_allocator)
    layouts[0] = self.scene_layouts[.NONE]
    return {layouts = layouts, push_size = PUSH_SIZE, bindless = true}
  } else {
    layouts := make([dynamic]rhi.BindLayout, context.temp_allocator)
    append(&layouts, self.scene_layouts[pass], self.texture_layouts[textures], rhi.PUSH_GROUP)
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

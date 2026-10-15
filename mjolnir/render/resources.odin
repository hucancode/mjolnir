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
  LIGHTING,
  // the shadow depth vertex shader
  SHADOW,
  CULL,
  PARTICLE_EMIT,
  PARTICLE_SIMULATE,
  PARTICLE_DRAW,
  DEBUG_LINE,
}

@(private)
SceneBuffer :: enum {
  VIEWS,
  NODES,
  MESHES,
  MATERIALS,
  BONES,
  SKINNING,
  VERTICES,
  INDICES,
  EMITTERS,
  FORCEFIELDS,
  PARTICLES,
  PARTICLE_ALIVE,
  LIGHTS,
  DEBUG_LINES,
  BATCHES,
  NODE_BATCH,
  // the shadow atlas, a texture; only in the scene set of a bindless device
  SHADOW_MAPS,
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
  .FORCEFIELDS,
  .PARTICLES,
  .PARTICLE_ALIVE,
  .LIGHTS,
  .SHADOW_MAPS,
  .DEBUG_LINES,
  .BATCHES,
  .NODE_BATCH,
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
  .MESH              = {{.VIEWS, .NODES, .MESHES, .MATERIALS, .BONES, .SKINNING, .VERTICES, .INDICES}, {.VERTEX, .FRAGMENT}, {}},
  .LIGHTING          = {{.VIEWS, .LIGHTS}, {.VERTEX, .FRAGMENT}, {}},
  .SHADOW            = {{.VIEWS, .NODES, .MESHES, .BONES, .SKINNING}, {.VERTEX}, {}},
  .CULL              = {{.VIEWS, .NODES, .MESHES, .MATERIALS, .BATCHES, .NODE_BATCH}, {.COMPUTE}, {}},
  .PARTICLE_EMIT     = {{.NODES, .EMITTERS, .PARTICLES}, {.COMPUTE}, {.PARTICLES}},
  .PARTICLE_SIMULATE = {{.NODES, .FORCEFIELDS, .PARTICLES, .PARTICLE_ALIVE}, {.COMPUTE}, {.PARTICLES, .PARTICLE_ALIVE}},
  .PARTICLE_DRAW     = {{.VIEWS, .PARTICLES, .PARTICLE_ALIVE}, {.VERTEX}, {}},
  .DEBUG_LINE        = {{.VIEWS, .DEBUG_LINES}, {.VERTEX}, {}},
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
Resources :: struct {
  caps:              rhi.Caps,
  // one copy of each table per frame in flight, and the regions render wrote that the copy lacks
  tables:            [Table][FRAMES_IN_FLIGHT]rhi.Buffer,
  stale:             [Table][FRAMES_IN_FLIGHT]u64,
  vertices:          rhi.Buffer,
  indices:           rhi.Buffer,
  skinning:          rhi.Buffer,
  // the particle ring, and the alive list whose header is the indirect draw
  particles:         rhi.Buffer,
  particle_alive:    rhi.Buffer,
  ui_vertices:       [FRAMES_IN_FLIGHT]rhi.Buffer,
  ui_indices:        [FRAMES_IN_FLIGHT]rhi.Buffer,
  // bound where a slot has none: white 2D and black cube
  white, black_cube: TextureHandle,
  // the shadow atlas of each frame in flight (pass_shadow.odin)
  atlas:             [FRAMES_IN_FLIGHT]TextureHandle,
  atlas_layers:      [FRAMES_IN_FLIGHT]u32,
  scene_layouts:     [ScenePass]rhi.BindLayout,
  // per frame in flight; a bindless device has one group, in every pass's entry
  scene_groups:      [ScenePass][FRAMES_IN_FLIGHT]rhi.BindGroup,
  texture_layouts:   [TextureLayout]rhi.BindLayout,
  texture_groups:    map[TextureGroupKey]rhi.BindGroup,
}

@(private)
resources_init :: proc(r: ^Renderer) -> bool {
  res := &r.res
  res.caps = dev.caps(&r.gpu)
  for t in Table {
    size := TABLES[t].stride * TABLES[t].capacity
    for f in 0 ..< FRAMES_IN_FLIGHT {
      res.tables[t][f] = dev.buffer_create(&r.gpu, {size = size, usage = {.STORAGE}, memory = .UPLOAD}) or_return
    }
  }
  mesh_buffer :: proc(r: ^Renderer, stream: MeshStream, usage: bit_set[rhi.BufferUsage]) -> (rhi.Buffer, bool) {
    size := int(r.mesh_slabs[stream].capacity) * MESH_STREAMS[stream].elem_size
    return dev.buffer_create(&r.gpu, {size = size, usage = usage})
  }
  // wireframe and random-color materials pull vertices and indices as storage (WebGPU)
  res.vertices = mesh_buffer(r, .VERTEX, {.VERTEX, .STORAGE}) or_return
  res.indices = mesh_buffer(r, .INDEX, {.INDEX, .STORAGE}) or_return
  res.skinning = mesh_buffer(r, .SKINNING, {.STORAGE}) or_return
  res.particle_alive = dev.buffer_create(&r.gpu, {size = (PARTICLE_ALIVE_HEADER + MAX_PARTICLES) * size_of(u32), usage = {.STORAGE, .INDIRECT}}) or_return
  res.particles = dev.buffer_create(&r.gpu, {size = MAX_PARTICLES * size_of(Particle), usage = {.STORAGE}}) or_return
  for f in 0 ..< FRAMES_IN_FLIGHT {
    res.ui_vertices[f] = dev.buffer_create(&r.gpu, {size = UI_MAX_VERTICES * size_of(Vertex2D), usage = {.VERTEX}, memory = .UPLOAD}) or_return
    res.ui_indices[f] = dev.buffer_create(&r.gpu, {size = UI_MAX_INDICES * size_of(u32), usage = {.INDEX}, memory = .UPLOAD}) or_return
  }
  return true
}

// After the textures and particle buffers exist: the layouts and groups shaders reach them by.
@(private)
resources_bind :: proc(r: ^Renderer) -> bool {
  res := &r.res
  white := TextureDesc{extent = {1, 1}, format = .RGBA8_UNORM, usage = {.SAMPLED}}
  for f in 0 ..< FRAMES_IN_FLIGHT do atlas_make(r, f, MIN_ATLAS_LAYERS) or_return
  res.white = allocate_texture(r, white, {255, 255, 255, 255}) or_return
  cube := TextureDesc{extent = {1, 1}, format = .RGBA16F, usage = {.SAMPLED}, cube = true}
  res.black_cube = allocate_texture(r, cube, make([]u8, 6 * 8, context.temp_allocator)) or_return
  if res.caps.bindless {
    entries: [len(SCENE_SET)]rhi.BindEntry
    for e, i in SCENE_SET do entries[i] = {kind = .TEXTURE_DEPTH_ARRAY if e == .SHADOW_MAPS else .STORAGE_BUFFER, stages = {.VERTEX, .FRAGMENT, .COMPUTE}}
    layout := dev.bind_layout_create(&r.gpu, {entries = entries[:]}) or_return
    for &l in res.scene_layouts do l = layout
    for f in 0 ..< FRAMES_IN_FLIGHT do scene_group_make(r, f) or_return
    return true
  }
  for pass, p in SCENE_PASSES {
    entries := make([]rhi.BindEntry, len(pass.buffers), context.temp_allocator)
    for buffer, i in pass.buffers do entries[i] = {kind = .STORAGE_BUFFER if buffer in pass.writes else .STORAGE_BUFFER_READ, stages = pass.stages}
    res.scene_layouts[p] = dev.bind_layout_create(&r.gpu, {entries = entries}) or_return
    for f in 0 ..< FRAMES_IN_FLIGHT {
      resources := make([]rhi.BindResource, len(pass.buffers), context.temp_allocator)
      for buffer, i in pass.buffers do resources[i] = rhi.BufferRange{buffer = scene_buffer(r, buffer, u32(f))}
      res.scene_groups[p][f] = dev.bind_group_create(&r.gpu, {layout = res.scene_layouts[p], resources = resources}) or_return
    }
  }
  for slots, l in TEXTURE_LAYOUTS {
    entries := make([]rhi.BindEntry, len(slots), context.temp_allocator)
    for slot, i in slots do entries[i] = {kind = TEXTURE_SLOT_KINDS[slot], stages = {.VERTEX, .FRAGMENT, .COMPUTE}}
    res.texture_layouts[l] = dev.bind_layout_create(&r.gpu, {entries = entries}) or_return
  }
  return true
}

@(private = "file")
TEXTURE_SLOT_KINDS := [TextureSlot]rhi.BindKind {
  .FLOAT        = .TEXTURE_FLOAT,
  .UNFILTERABLE = .TEXTURE_UNFILTERABLE,
  .DEPTH        = .TEXTURE_DEPTH,
  .CUBE         = .TEXTURE_CUBE,
  .SHADOW_ATLAS = .TEXTURE_DEPTH_ARRAY,
}

@(private = "file")
scene_buffer :: proc(r: ^Renderer, buffer: SceneBuffer, frame: u32) -> rhi.Buffer {
  res := &r.res
  switch buffer {
  case .VIEWS:          return res.tables[.VIEWS][frame]
  case .NODES:          return res.tables[.NODES][frame]
  case .MESHES:         return res.tables[.MESHES][frame]
  case .MATERIALS:      return res.tables[.MATERIALS][frame]
  case .BONES:          return res.tables[.BONES][frame]
  case .SKINNING:       return res.skinning
  case .VERTICES:       return res.vertices
  case .INDICES:        return res.indices
  case .EMITTERS:       return res.tables[.EMITTERS][frame]
  case .FORCEFIELDS:    return res.tables[.FORCEFIELDS][frame]
  case .PARTICLES:      return res.particles
  case .PARTICLE_ALIVE: return res.particle_alive
  case .LIGHTS:         return res.tables[.LIGHTS][frame]
  case .DEBUG_LINES:    return res.tables[.DEBUG_LINES][frame]
  case .BATCHES:        return res.tables[.BATCHES][frame]
  case .NODE_BATCH:     return res.tables[.NODE_BATCH][frame]
  case .SHADOW_MAPS:    return 0
  }
  return 0
}

// The bindless scene set of frame `f`, with the frame's shadow atlas. Call again when the
// atlas changes, once no submitted work reads the old group.
@(private)
scene_group_make :: proc(r: ^Renderer, f: int) -> bool {
  res := &r.res
  old := res.scene_groups[.NONE][f]
  resources: [len(SCENE_SET)]rhi.BindResource
  for e, i in SCENE_SET {
    if e == .SHADOW_MAPS {
      resources[i] = rhi.TextureView{texture = res.atlas[f], mip = -1}
    } else {
      resources[i] = rhi.BufferRange{buffer = scene_buffer(r, e, u32(f))}
    }
  }
  group := dev.bind_group_create(&r.gpu, {layout = res.scene_layouts[.NONE], resources = resources[:]}) or_return
  for &g in res.scene_groups do g[f] = group
  if old != 0 do dev.bind_group_retire(&r.gpu, old)
  return true
}

// Brings frame `f`'s copy of every table up to date with render's: a region render wrote goes
// stale in every copy and is written into each as its frame comes up.
@(private)
tables_sync :: proc(r: ^Renderer, f: u32) {
  res := &r.res
  for t in Table {
    for &s in res.stale[t] do s |= r.dirty[t]
    stale := &res.stale[t][f]
    if stale^ == 0 do continue
    src := r.tables[t]
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
      if hi > lo do dev.buffer_write(&r.gpu, res.tables[t][f], lo, src[lo:hi])
    }
    stale^ = 0
  }
}

// Binds the scene set (set 0) of `pass` for the frame, and the bindless arrays where there are
// any. After the pipeline is bound.
@(private)
scene_bind :: proc(r: ^Renderer, cmd: rhi.CommandList, pass: ScenePass, f: u32) {
  if r.res.caps.bindless {
    dev.cmd_bind_group(&r.gpu, cmd, 0, r.res.scene_groups[.NONE][f])
    dev.cmd_bind_bindless(&r.gpu, cmd)
  } else {
    dev.cmd_bind_group(&r.gpu, cmd, 0, r.res.scene_groups[pass][f])
  }
}

// The set of texture slots a WebGPU pass binds as set 1; textures reach a bindless shader
// by index instead. Slot 0 takes the default of its kind.
@(private)
texture_bind :: proc(r: ^Renderer, cmd: rhi.CommandList, layout: TextureLayout, textures: ..TextureHandle) {
  res := &r.res
  if res.caps.bindless do return
  key := TextureGroupKey{layout = layout}
  for t, i in textures do key.textures[i] = t
  group, ok := res.texture_groups[key]
  if !ok {
    slots := TEXTURE_LAYOUTS[layout]
    resources := make([]rhi.BindResource, len(slots), context.temp_allocator)
    for slot, i in slots {
      texture := key.textures[i]
      switch slot {
      case .FLOAT, .UNFILTERABLE, .DEPTH:
        if texture == 0 do texture = res.white
      case .CUBE:
        if texture == 0 do texture = res.black_cube
      case .SHADOW_ATLAS:
        texture = res.atlas[0]
      }
      resources[i] = rhi.TextureView{texture = texture, mip = -1}
    }
    group, ok = dev.bind_group_create(&r.gpu, {layout = res.texture_layouts[layout], resources = resources})
    if !ok {
      log.errorf("Texture group %v failed", layout)
      return
    }
    res.texture_groups[key] = group
  }
  dev.cmd_bind_group(&r.gpu, cmd, 1, group)
}

// Binds `pipeline` and what a pass binds after it: the scene set of `scene` for frame `f`, the
// texture group of `layout` (WebGPU) and `push`. WebGPU gives every pipeline a push group, so
// every pass pushes, whether or not its shaders read it.
@(private)
pipeline_bind :: proc(r: ^Renderer, cmd: rhi.CommandList, pipeline: rhi.Pipeline, scene: ScenePass, f: u32, push: ^$T, layout: TextureLayout, textures: ..TextureHandle) {
  dev.cmd_bind_pipeline(&r.gpu, cmd, pipeline)
  scene_bind(r, cmd, scene, f)
  texture_bind(r, cmd, layout, ..textures)
  dev.cmd_push(&r.gpu, cmd, push, size_of(T))
}

// Drops the texture groups: a texture they name changed.
@(private)
texture_groups_clear :: proc(r: ^Renderer) {
  for _, group in r.res.texture_groups do dev.bind_group_retire(&r.gpu, group)
  clear(&r.res.texture_groups)
}

// The layouts of a pipeline of `pass`: the scene set, then on a device without bindless the
// textures (set 1) and the push group (set 2) and `extra`. The shaders' set numbers.
@(private)
pipeline_layout :: proc(r: ^Renderer, pass: ScenePass, textures: TextureLayout = .NONE, extra: rhi.BindLayout = 0) -> rhi.PipelineLayoutDesc {
  res := &r.res
  if res.caps.bindless {
    layouts := make([]rhi.BindLayout, 1, context.temp_allocator)
    layouts[0] = res.scene_layouts[.NONE]
    return {layouts = layouts, push_size = PUSH_SIZE, bindless = true}
  }
  layouts := make([dynamic]rhi.BindLayout, context.temp_allocator)
  append(&layouts, res.scene_layouts[pass], res.texture_layouts[textures], rhi.PUSH_GROUP)
  if extra != 0 do append(&layouts, extra)
  return {layouts = layouts[:], push_size = PUSH_SIZE}
}

// mesh_write uploads data at element `first` of stream's buffer before the next frame.
@(private)
mesh_write :: proc(r: ^Renderer, stream: MeshStream, data: []$T, first: u32) -> bool {
  #assert(size_of(T) % 4 == 0)
  if len(data) == 0 do return true
  buffer: rhi.Buffer
  switch stream {
  case .VERTEX:   buffer = r.res.vertices
  case .INDEX:    buffer = r.res.indices
  case .SKINNING: buffer = r.res.skinning
  }
  return dev.buffer_write(&r.gpu, buffer, int(first) * size_of(T), ([^]u8)(raw_data(data))[:len(data) * size_of(T)])
}

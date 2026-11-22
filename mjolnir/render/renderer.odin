package render

import "../containers"
import "rhi"
import "core:log"
import "core:slice"
import "core:sync"

// direct_light packs camera indices into 16 bits
#assert(MAX_ACTIVE_CAMERAS < 0xFFFF)

// Config is what render reserves at init: room for this many of each resource. Past a reserve
// render grows the storage instead of failing, at the cost of a copy the frame it does: reserve
// what a level needs to keep frames even.
Config :: struct {
  // scene slots (SlotHandle): the highest slot index in use + 1, usually world nodes
  nodes:            u32,
  meshes:           u32,
  materials:        u32,
  lights:           u32,
  emitters:         u32,
  force_fields:     u32,
  // textures of yours and render's (render targets included)
  textures:         u32,
  // bone matrices of every palette together (bones_create)
  bones:            u32,
  // vertices of every skinned mesh attached at once, each slot its own
  skinned_vertices: u32,
  sprite_frames:    u32,
  // the mesh buffers: vertices and indices of every mesh together, and the skinning data (a
  // SkinningData per vertex) of the skinned ones
  vertices:         u32,
  indices:          u32,
  skinning_data:    u32,
  // the overlay's vertices and indices per frame
  overlay_vertices: u32,
  overlay_indices:  u32,
  gpu_buffers:      u32,
  shaders:          u32,
  // fixed, not grown: the particle ring (the oldest particle makes way), the debug line rings
  // (half depth-tested, half drawn over; the oldest segment makes way) and how many point and
  // spot lights cast shadows at once (at most MAX_SHADOW_MAPS)
  particles:        u32,
  debug_lines:      u32,
  shadow_maps:      u32,
  // what the main camera draws and runs (camera_create's filter); no types = FILTER_ALL. A
  // game drawing only forward types (sprites) skips the G-buffer, lighting and their images
  main_filter:      CameraFilter,
}

// DEFAULT_CONFIG reserves for a typical level: a few hundred MB of GPU memory with the camera
// images at 1080p.
DEFAULT_CONFIG :: Config {
  nodes            = 16384,
  meshes           = 1024,
  materials        = 256,
  lights           = 64,
  emitters         = 16,
  force_fields     = 8,
  textures         = 256,
  bones            = 8192,
  skinned_vertices = 1 << 17,
  sprite_frames    = 1024,
  vertices         = 1 << 18,
  indices          = 1 << 20,
  skinning_data    = 1 << 15,
  overlay_vertices = 1 << 14,
  overlay_indices  = 3 << 13,
  gpu_buffers      = 64,
  shaders          = 16,
  particles        = 65536,
  debug_lines      = 1 << 14,
  shadow_maps      = 16,
  main_filter      = FILTER_ALL,
}

// Shadow casters ranked by screen coverage get a map; the rest of the maps go
// to casters that ranked within the last SHADOW_GRACE_FRAMES frames.
@(private)
SHADOW_RANKED_CASTERS :: 12
@(private)
SHADOW_GRACE_FRAMES :: 30
#assert(SHADOW_RANKED_CASTERS <= MAX_SHADOW_MAPS)

// MeshHandle identifies a mesh. Like every render handle, 0 is none.
MeshHandle :: distinct u32
// MaterialHandle identifies a material.
MaterialHandle :: distinct u32
// CameraHandle identifies a camera.
CameraHandle :: distinct u32

// The kinds of handle render hands out, each its own containers.Slots.
@(private)
Pool :: enum {
  MESHES,
  MATERIALS,
  LIGHTS,
  EMITTERS,
  FORCE_FIELDS,
  // where lights, emitters and force fields are attached
  LIGHT_PLACEMENTS,
  EMITTER_PLACEMENTS,
  FORCE_FIELD_PLACEMENTS,
  CAMERAS,
  // render's targets and every other texture (texture.odin)
  TEXTURES,
  // your GPU programs (gpu.odin): buffers, and shaders after render's post shaders
  GPU_BUFFERS,
  SHADERS,
  MATERIAL_SHADERS,
  // draw batches (batches.odin), rows of Table.BATCHES
  BATCHES,
  // the bindless storage-buffer indices of the draw lists (pass_cull.odin)
  DRAW_LISTS,
}

// Each pool's reuse grace, the most indices it grows to and, where `rows`, the table whose rows
// it hands out (pool_alloc grows the table along).
@(private)
POOLS := [Pool]struct {
  grace:   u64,
  ceiling: u32,
  table:   Table,
  rows:    bool,
} {
  .MESHES                 = {RETIRE_GRACE, max(u32), .MESHES, true},
  .MATERIALS              = {RETIRE_GRACE, 1 << 24, .MATERIALS, true},
  .LIGHTS                 = {RETIRE_GRACE, max(u32), .LIGHTS, true},
  .EMITTERS               = {RETIRE_GRACE, max(u32), .EMITTERS, true},
  .FORCE_FIELDS           = {RETIRE_GRACE, max(u32), .FORCE_FIELDS, true},
  // placements have no handle to go stale and each frame reads its own copy of the table,
  // so no grace
  .LIGHT_PLACEMENTS       = {0, max(u32), .LIGHT_PLACEMENTS, true},
  .EMITTER_PLACEMENTS     = {0, max(u32), .EMITTER_PLACEMENTS, true},
  .FORCE_FIELD_PLACEMENTS = {0, max(u32), .FORCE_FIELD_PLACEMENTS, true},
  .CAMERAS                = {RETIRE_GRACE, MAX_ACTIVE_CAMERAS, {}, false},
  // retired, not reclaimed: submitted frames may still sample the slot
  .TEXTURES               = {RETIRE_GRACE, rhi.MAX_TEXTURES, {}, false},
  // the device retires what they hold
  .GPU_BUFFERS            = {0, max(u32), {}, false},
  .SHADERS                = {0, max(u32), {}, false},
  .MATERIAL_SHADERS       = {0, MAX_MATERIAL_SHADERS + 1, {}, false},
  .BATCHES                = {0, 1 << 20, .BATCHES, true},
  // a frame in flight may still read the index of a retired list
  .DRAW_LISTS             = {RETIRE_GRACE, DRAW_LIST_BINDINGS, {}, false},
}

// The indices each pool takes at init.
@(private)
pool_reserves :: proc(config: Config) -> [Pool]u32 {
  return {
    .MESHES                 = config.meshes,
    .MATERIALS              = config.materials,
    .LIGHTS                 = config.lights,
    .EMITTERS               = config.emitters,
    .FORCE_FIELDS           = config.force_fields,
    .LIGHT_PLACEMENTS       = config.lights,
    .EMITTER_PLACEMENTS     = config.emitters,
    .FORCE_FIELD_PLACEMENTS = config.force_fields,
    .CAMERAS                = MAX_ACTIVE_CAMERAS,
    .TEXTURES               = config.textures,
    .GPU_BUFFERS            = config.gpu_buffers,
    .SHADERS                = 1 + config.shaders,
    .MATERIAL_SHADERS       = MAX_MATERIAL_SHADERS + 1,
    .BATCHES                = config.meshes,
    .DRAW_LISTS             = 64,
  }
}

// The entries each table takes at init.
@(private)
table_reserves :: proc(config: Config) -> [Table]int {
  return {
    .VIEWS                  = MAX_ACTIVE_CAMERAS + int(shadow_view_count(config)),
    .NODES                  = int(config.nodes),
    .MESHES                 = int(config.meshes),
    .MATERIALS              = int(config.materials),
    .BONES                  = int(config.bones),
    .EMITTERS               = int(config.emitters),
    .FORCE_FIELDS           = int(config.force_fields),
    .LIGHTS                 = int(config.lights),
    .DEBUG_LINES            = int(config.debug_lines),
    .BATCHES                = int(config.meshes),
    .NODE_BATCH             = int(config.nodes),
    .SKIN_OWNERS            = int(config.skinned_vertices),
    .LIGHT_PLACEMENTS       = int(config.lights),
    .EMITTER_PLACEMENTS     = int(config.emitters),
    .FORCE_FIELD_PLACEMENTS = int(config.force_fields),
    .SPRITE_FRAMES          = int(config.sprite_frames),
  }
}

// pool_alloc hands out an index of the pool, growing the pool and its table past their
// reserve; false at the pool's ceiling. Caller holds the render mutex.
@(private)
pool_alloc :: proc(self: ^Renderer, pool: Pool) -> (index: u32, ok: bool) {
  slots := &self.slots[pool]
  index, ok = containers.slots_alloc(slots)
  if !ok {
    if slots.capacity >= POOLS[pool].ceiling {
      log.warnf("No room for more than %d %v", POOLS[pool].ceiling - 1, pool)
      return 0, false
    }
    containers.slots_grow(slots, u32(min(max(u64(slots.capacity) * 2, 16), u64(POOLS[pool].ceiling))))
    pool_grown(self, pool)
    index = containers.slots_alloc(slots) or_return
  }
  if POOLS[pool].rows && !table_grow(self, POOLS[pool].table, int(index) + 1) {
    containers.slots_free(slots, index)
    return 0, false
  }
  return index, true
}

// Every pool at its reserve (Config).
@(private)
pools_init :: proc(self: ^Renderer) {
  reserves := pool_reserves(self.config)
  for &slots, p in self.slots {
    containers.slots_init(&slots, min(max(reserves[p], 2), POOLS[p].ceiling), POOLS[p].grace)
    pool_grown(self, p)
  }
}

// What follows a pool's capacity besides its table.
@(private = "file")
pool_grown :: proc(self: ^Renderer, pool: Pool) {
  n := int(self.slots[pool].capacity)
  #partial switch pool {
  case .TEXTURES:
    resize(&self.texture_targets, n)
    resize(&self.texture_views, n)
  case .GPU_BUFFERS:
    resize(&self.gpu_buffers, n)
  case .SHADERS:
    resize(&self.shaders, n)
  }
}

// render's own pipelines, by what they run.
@(private)
BuiltinPipeline :: enum {
  // culling (pass_cull.odin); CULL_DRAWS (batched) writes the draw of each batch
  CULL,
  CULL_DRAWS,
  // the pyramid build: compacted builds every mip at once, batched mip by mip
  DEPTH_REDUCE,
  SHADOW,
  AMBIENT_OCCLUSION,
  LIGHTING,
  PARTICLE_EMIT,
  PARTICLE_SIMULATE,
  PARTICLE_DRAW,
  SKIN,
  // debug line rings: depth-tested, drawn over everything
  DEBUG_LINE,
  DEBUG_LINE_OVER,
  OVERLAY,
  // the camera effects (pass_post.odin); bloom's up steps add into their target
  POST_OUTLINE,
  POST_FOG,
  POST_DOF,
  POST_BLOOM,
  POST_BLOOM_ADD,
  POST_FXAA,
  POST_BLUR,
  POST_CROSS_HATCH,
  POST_GRAYSCALE,
  POST_TONE_MAP,
  // a post shader gone since: its input passes through
  POST_COPY,
  // the presented camera's image to the window
  PRESENT,
}

// Renderer is the whole renderer; its fields are the settings an application edits.
// init/shutdown own the GPU backend and what init makes (builtin meshes and
// materials, the main camera): application lifetime. Everything made after init lives for the
// map: teardown frees it in one go.
Renderer :: struct {
  skybox_intensity:       f32,
  skybox_blur:            f32,
  // scales image-based lighting
  ibl_intensity:          f32,
  using _:               Renderer_State,
}

@(private)
Renderer_State :: struct {
  // what primitive hands out
  builtin_materials:      [Color]MaterialHandle,
  builtin_meshes:         [Primitive]MeshHandle,
  gpu:                    Backend,
  capture:                Capture,
  // what init reserved
  config:                 Config,
  // render's tables, the one copy, and what of them the GPU copies lack (tables_sync)
  using cpu_tables:       Tables,
  // cull dispatches cover the slots below this
  node_count:             u32,
  // the skinning dispatch covers skinned vertices below this
  skinned_vertex_count:   u32,
  shadow_view_count:      u32,
  // light placement row + 1 of the sun custom materials see this frame, 0 for none
  // (collect_lights)
  sun:                    u32,
  // what the scene is lit by: init's default until environment_map_load
  environment:            Environment,
  default_environment:    Environment,
  brdf_lut:               TextureHandle,
  particle_params:        ParticleSystemParams,
  // which handles of each kind are live (POOLS)
  slots:                  [Pool]containers.Slots,
  cameras:                []Camera,
  camera_targets:         []CameraTargets,
  // per texture handle: a render target, which teardown keeps
  texture_targets:        [dynamic]bool,
  // per texture handle: the first of a storage texture's views in the bindless storage images
  // (BINDLESS), a mip each, taken from storage_views
  texture_views:          [dynamic]u32,
  storage_views:          containers.Ranges,
  // the mesh buffers' ranges, per stream
  mesh_ranges:            [MeshStream]containers.Ranges,
  // the palettes' ranges of the bone table (BonesHandle is a palette's first bone + 1)
  bone_ranges:            containers.Ranges,
  // the frame sets' ranges of the sprite frame table (SpriteFramesHandle is a set's first + 1)
  sprite_frame_ranges:    containers.Ranges,
  // the skinned vertex ranges of skinned slots (pass_skin.odin)
  skin_ranges:            containers.Ranges,
  // `time` as of the last submitted frame: particles are emitted and simulated up to it, an
  // emitter having emitted floor(rate * particle_time) in total
  particle_time:          f64,
  // particles_reset was called: the next simulation clears the ring
  particles_clear:        bool,
  // emit's queue, and the bursts the last flush placed (row != 0)
  bursts:                 [dynamic]Burst,
  // segments added since the last frame, per ring: [0] depth-tested, [1] drawn over the scene
  debug_lines:            [2][dynamic]DebugLineSegment,
  // segments each ring has taken in total (debug_line.odin)
  debug_filled:           [2]u64,
  // seconds render.update has advanced; shaders read it as View.time and PostPush.time
  time:                   f64,
  debug_mutex:            sync.Mutex,
  shadow_casters:         [MAX_SHADOW_MAPS]Caster,
  // the shadow views the views table holds after the cameras (shadow_view_count)
  max_shadow_views:       u32,
  // the last compute submission, which the next frame's graphics waits for
  // the buffers render owns on the device (resources.odin): a copy per frame in flight of
  // each table, one of the rest
  buffers:                [SceneBuffer][FRAMES_IN_FLIGHT]rhi.Buffer,
  // their sizes in bytes; a table's copy smaller than the table is replaced as its frame comes
  // up (tables_reserve)
  buffer_sizes:           [SceneBuffer][FRAMES_IN_FLIGHT]int,
  // per frame in flight: a buffer its scene groups bind was replaced
  groups_stale:           [FRAMES_IN_FLIGHT]bool,
  // bound where a slot has none: white 2D and black cube
  white, black_cube:      TextureHandle,
  // bound where a depth slot has none (WebGPU's groups)
  default_depth:          TextureHandle,
  // the shadow atlas and its layers (pass_shadow.odin)
  atlas:                  TextureHandle,
  atlas_layers:           u32,
  // a bindless device has one layout and group per frame, at .NONE, which every pass binds
  scene_layouts:          [ScenePass]rhi.BindLayout,
  scene_groups:           [ScenePass][FRAMES_IN_FLIGHT]rhi.BindGroup,
  texture_layouts:        [TextureLayout]rhi.BindLayout,
  // WebGPU's bind groups past the scene set, made on first use (cached_group)
  bind_groups:            map[GroupKey]rhi.BindGroup,
  // render's own pipelines; the per-material ones follow
  pipelines:              [BuiltinPipeline]rhi.Pipeline,
  draw_lists:             [MAX_DRAW_LIST_SLOTS]GpuDrawList,
  // draws are batched per mesh and material where they are not compacted (batches.odin):
  // (material, mesh) -> batch id (slots[.BATCHES]), and whether first_instance is stale
  batch_ids:              map[u64]u32,
  batch_stale:            bool,
  batch_warned:           bool,
  // this frame's live batches by draw list key, material and id: key << 44 | material << 20 | id
  batch_order:            [dynamic]u64,
  // by MaterialType, your shaders' after the built-in ones; 0 where free
  material_pipelines:     [MaterialPass][DRAW_LISTS]rhi.Pipeline,
  // the sprite shader's second draw: its semi-transparent pixels, blended, not writing depth
  sprite_blend_pipelines: [2]rhi.Pipeline, // SPRITE_TYPES' blended draws
  // the 2D overlay (overlay.odin): this frame's vertices and indices, in batches of one
  // scissor and texture; past Config.overlay_* the frame's buffers grow (overlay_upload)
  overlay_vertices:       [dynamic]Vertex2D,
  overlay_indices:        [dynamic]u32,
  overlay_batches:        [dynamic]OverlayBatch,
  // the overlay was drawn or a tick ended since it was staged: the next stage_overlay replaces it
  overlay_stale:          bool,
  // sampled by text commands: each font's uploaded atlas, the least recently used replaced
  overlay_fonts:          [OVERLAY_FONTS]OverlayFont,
  overlay_font_clock:     u64,
  // the window's, as frame last measured it: maps window coordinates to pixels
  dpi_scale:              f32,
  mutex:                  sync.Recursive_Mutex,
  // your GPU programs (gpu.odin), by handle; work staged for the next frame; the draws frames
  // draw, stale once drawn or a tick ended
  gpu_buffers:            [dynamic]GpuBuffer,
  shaders:                [dynamic]Shader,
  gpu_work:               [dynamic]GpuWork,
  gpu_draws:              [dynamic]GpuDraw,
  gpu_draws_stale:        bool,
  gpu_layouts:            map[GpuLayoutKey]rhi.BindLayout,
  // this frame's passes (frame.odin), declared and compiled each frame
  frame_graph:            FrameGraph,
  // the textures the frame graph placed its transients in, by physical index
  transients:             [dynamic]TextureHandle,
  // ready ran init_resources
  initialized:            bool,
}

// init brings the renderer up on a window, sized as it is: the GPU backend, every resource and
// an empty scene with a main camera. Paired with shutdown. A backend whose device arrives
// asynchronously (wgpu on the web) finishes in ready: until it returns true, nothing but ready
// may be called. Main thread.
init :: proc(self: ^Renderer, window: WindowHandle, config := DEFAULT_CONFIG) -> bool {
  config := config
  if config.shadow_maps > MAX_SHADOW_MAPS {
    log.warnf("shadow_maps %d exceeds MAX_SHADOW_MAPS (%d)", config.shadow_maps, MAX_SHADOW_MAPS)
    config.shadow_maps = MAX_SHADOW_MAPS
  }
  config.particles = max((config.particles + COMPUTE_PARTICLE_BATCH - 1) / COMPUTE_PARTICLE_BATCH * COMPUTE_PARTICLE_BATCH, COMPUTE_PARTICLE_BATCH)
  config.debug_lines = max(config.debug_lines &~ 1, 2)
  self.config = config
  self.max_shadow_views = shadow_view_count(config)
  containers.ranges_init(&self.mesh_ranges[.VERTEX], config.vertices)
  containers.ranges_init(&self.mesh_ranges[.INDEX], config.indices)
  containers.ranges_init(&self.mesh_ranges[.SKINNING], max(config.skinning_data, 1))
  containers.ranges_init(&self.storage_views, MAX_STORAGE_VIEWS)
  dev.init(&self.gpu, window, BINDLESS_SIZES) or_return
  tables_init(self, table_reserves(config))
  measure_window(self)
  if dev.ready(&self.gpu) do return ready(self)
  return true
}

// ready reports whether the renderer is up, finishing init once the backend is.
ready :: proc(self: ^Renderer) -> bool {
  if self.initialized do return true
  if !dev.ready(&self.gpu) do return false
  self.initialized = init_resources(self)
  return self.initialized
}

@(private = "file")
init_resources :: proc(self: ^Renderer) -> bool {
  pools_init(self)
  resources_init(self) or_return
  resources_bind(self) or_return
  cull_init(self) or_return
  shadow_init(self) or_return
  material_init(self) or_return
  ambient_occlusion_init(self) or_return
  lighting_init(self) or_return
  post_init(self) or_return
  particles_init(self) or_return
  skin_init(self) or_return
  debug_line_init(self) or_return
  overlay_init(self) or_return
  draw_list_reserve(self, SHADOW_DRAW_SLOT, shadow = true, shadow_views = MIN_ATLAS_LAYERS) or_return
  containers.ranges_init(&self.bone_ranges, u32(table_capacity(self, .BONES)))
  containers.ranges_init(&self.sprite_frame_ranges, u32(table_capacity(self, .SPRITE_FRAMES)))
  containers.ranges_init(&self.skin_ranges, u32(table_capacity(self, .SKIN_OWNERS)))
  self.cameras = make([]Camera, MAX_ACTIVE_CAMERAS)
  self.camera_targets = make([]CameraTargets, MAX_ACTIVE_CAMERAS)
  init_builtin_materials(self)
  init_builtin_meshes(self)
  ambient_init(self) or_return
  for &inbox in self.debug_lines do inbox = make([dynamic]DebugLineSegment, 0, 1024)
  extent := dev.extent(&self.gpu)
  main_filter := self.config.main_filter
  if transmute(u32)(main_filter.types) == 0 do main_filter = FILTER_ALL
  cam, created := camera_create(self, extent, make_camera(MAIN_CAMERA_POSITION), main_filter)
  if !created do return false
  assert(cam == MAIN_CAMERA)
  // what init made outlives teardown
  mark_resources(self)
  return true
}

// Marks what init made, which teardown keeps.
@(private = "file")
mark_resources :: proc(self: ^Renderer) {
  for &slots in self.slots do containers.slots_mark(&slots)
  for &ranges in self.mesh_ranges do containers.ranges_mark(&ranges)
  containers.ranges_mark(&self.bone_ranges)
  containers.ranges_mark(&self.sprite_frame_ranges)
}

// teardown ends a map in one go, waiting for the GPU: the renderer is back to how init left
// it. Everything the application made is freed, its handles stale (cameras, meshes, materials,
// lights, emitters, force fields, textures, buffers and shaders), no particle stays alive, every
// slot forgets its attachment and bone palette, and the settings (skybox, environment map,
// main camera and its effects) are init's again.
teardown :: proc(self: ^Renderer) {
  lock(self)
  // shaders before the buffers they bind; the device retires what they hold
  c := self.slots[.SHADERS].mark
  for i in containers.slots_next(&self.slots[.SHADERS], &c) do shader_destroy(self, ShaderHandle(i))
  c = 0
  for i in containers.slots_next(&self.slots[.GPU_BUFFERS], &c) do buffer_destroy(self, BufferHandle(i))
  c = 0
  for i in containers.slots_next(&self.slots[.MATERIAL_SHADERS], &c) do material_shader_destroy(self, shader_type(i))
  // their render targets and draw lists retire, and go with the flushes below
  c = self.slots[.CAMERAS].mark
  for i in containers.slots_next(&self.slots[.CAMERAS], &c) do free_camera(self, CameraHandle(i))
  // queued uploads may be init's: they land before anything is freed
  dev.wait_idle(&self.gpu)
  textures_teardown(self)
  // the staged overlay may sample what was freed
  overlay_clear(self)
  containers.slots_rewind(&self.slots[.CAMERAS])
  for p in Pool.MESHES ..= Pool.FORCE_FIELD_PLACEMENTS {
    slots := &self.slots[p]
    clear_entry(self, POOLS[p].table, slots.mark, slots.high_water - slots.mark)
    containers.slots_rewind(slots)
  }
  for &ranges in self.mesh_ranges do containers.ranges_rewind(&ranges)
  clear_entry(self, .NODES, 0, self.node_count)
  self.node_count = 0
  when !BINDLESS do batches_reset(self)
  containers.ranges_rewind(&self.bone_ranges)
  containers.ranges_rewind(&self.sprite_frame_ranges)
  containers.ranges_rewind(&self.skin_ranges)
  clear_entry(self, .SKIN_OWNERS, 0, self.skinned_vertex_count)
  self.skinned_vertex_count = 0
  self.shadow_casters = {}
  clear(&self.bursts)
  gpu_reset(self)
  if !particles_reset(self) do log.error("teardown: cannot clear the particles")
  ambient_reset(self)
  self.cameras[MAIN_CAMERA] = make_camera(MAIN_CAMERA_POSITION)
  camera_effects_default(self, u32(MAIN_CAMERA))
}

// environment_map_load replaces the environment map with the equirectangular HDR image encoded
// in `data` and precomputes image-based lighting from it. Until then render lights the scene
// with a default one.
environment_map_load :: proc(self: ^Renderer, data: []u8) -> bool {
  env, ok := ambient_load(self, data)
  if !ok {
    log.warnf("Failed to load environment map")
    return false
  }
  if self.environment != self.default_environment do ambient_free(self, self.environment)
  self.environment = env
  return true
}

// shutdown destroys everything, whatever map is up.
shutdown :: proc(self: ^Renderer) {
  capture_finish(self)
  delete(self.bind_groups)
  dev.shutdown(&self.gpu)
  tables_destroy(self)
  delete(self.batch_ids)
  delete(self.batch_order)
  delete(self.overlay_batches)
  delete(self.overlay_vertices)
  delete(self.overlay_indices)
  gpu_shutdown(self)
  graph_destroy(&self.frame_graph)
  delete(self.transients)
  for inbox in self.debug_lines do delete(inbox)
  delete(self.bursts)
  for &ranges in self.mesh_ranges do containers.ranges_destroy(&ranges)
  containers.ranges_destroy(&self.bone_ranges)
  containers.ranges_destroy(&self.sprite_frame_ranges)
  containers.ranges_destroy(&self.skin_ranges)
  for &slots in self.slots do containers.slots_destroy(&slots)
  delete(self.cameras)
  delete(self.camera_targets)
  delete(self.texture_targets)
  delete(self.texture_views)
  containers.ranges_destroy(&self.storage_views)
}

// Cameras that matched the old extent follow the new one.
@(private)
recreate_swapchain :: proc(self: ^Renderer, framebuffer_size: [2]u32) -> bool {
  old := dev.extent(&self.gpu)
  dev.resize(&self.gpu, framebuffer_size) or_return
  extent := dev.extent(&self.gpu)
  c: u32
  for i in containers.slots_next(&self.slots[.CAMERAS], &c) {
    if self.camera_targets[i].extent != old do continue
    camera_resize(self, CameraHandle(i), extent) or_return
  }
  return true
}

// lock holds off frame until the end of the calling scope, while another thread edits the
// scene. When your simulation runs on its own thread, call it first in each tick's update so
// frame, on the main thread, sees whole ticks. The pointers material, light, emitter,
// force_field and camera return are then valid for the tick. Single-threaded, the lock costs
// nothing; every render proc takes it too.
@(deferred_in = unlock)
lock :: proc(self: ^Renderer) {
  sync.recursive_mutex_lock(&self.mutex)
}

@(private)
unlock :: proc(self: ^Renderer) {
  sync.recursive_mutex_unlock(&self.mutex)
}

// The only place retirement advances; once per frame, so ticks follow frame_serial.
@(private)
tick_resource_pools :: proc(self: ^Renderer) {
  dev.tick(&self.gpu)
  // bind groups name textures by handle: a destroyed one's go
  destroyed := false
  for &slots, p in self.slots {
    for r in containers.slots_tick(&slots) {
      #partial switch p {
      case .TEXTURES:
        texture_free(self, TextureHandle(r.index))
        destroyed = true
      case .MESHES:
        free_mesh(self, write_table(self, .MESHES, MeshData)[r.index])
        clear_entry(self, .MESHES, r.index)
      }
    }
  }
  if destroyed do groups_clear(self)
}

// update advances the render clock (shaders' time, debug line lifetimes) and the particle
// simulation time, and ends the tick's overlay (stage_overlay). Call it once per simulation
// tick, after the tick's stage_* calls; the next frame emits and simulates everything
// accumulated since the previous one.
update :: proc(self: ^Renderer, delta_time: f32) {
  lock(self)
  sync.mutex_lock(&self.debug_mutex)
  self.time += f64(max(delta_time, 0))
  sync.mutex_unlock(&self.debug_mutex)
  self.overlay_stale = true
  self.gpu_draws_stale = true
}

// Writes the render-generated tables. Once per frame under the render mutex.
@(private)
flush :: proc(self: ^Renderer, frame_index: u32) {
  // before the lights: shadow casters are ranked by the camera views
  flush_cameras(self)
  flush_particles(self)
  collect_lights(self, frame_index)
  flush_debug_lines(self)
  batches_flush(self)
  // cull dispatches cover the slots up to the last one holding anything
  nodes := write_table(self, .NODES, Node)
  for self.node_count > 0 && nodes[self.node_count - 1] == {} do self.node_count -= 1
  // the staged overlay draws only with a main camera
  if _, ok := main_camera(self); !ok do overlay_clear(self)
}

// The window's framebuffer size; keeps its DPI scale, 1 where the window reports none.
@(private = "file")
measure_window :: proc(self: ^Renderer) -> [2]u32 {
  size, dpi_scale := dev.window_size(&self.gpu)
  self.dpi_scale = dpi_scale if dpi_scale > 0 else 1
  return size
}

// frame renders and presents one frame at the window's framebuffer size in pixels, measured
// now with its DPI scale (pixels per window unit): an out-of-date swapchain is rebuilt to the
// size. It returns false on a GPU error. Main thread.
frame :: proc(self: ^Renderer) -> bool {
  frame_index := current_frame(self)
  lock(self)
  framebuffer_size := measure_window(self)
  tick_resource_pools(self)
  flush(self, frame_index)
  submitted, status := frame_run(self, framebuffer_size)
  // drawn again each frame until a stage_overlay replaces it
  self.overlay_stale = true
  if submitted {
    gpu_frame_done(self)
    // emitted and simulated up to now
    self.particle_time = self.time
  }
  switch status {
  case .OK:
    return true
  case .RESIZE:
    return recreate_swapchain(self, framebuffer_size)
  case .ERROR:
  }
  return false
}

// destroy frees a resource by its handle, as its *_destroy does.
destroy :: proc {
  mesh_destroy,
  material_destroy,
  texture_destroy,
  camera_destroy,
  light_destroy,
  emitter_destroy,
  force_field_destroy,
  material_shader_destroy,
  bones_destroy,
  buffer_destroy,
  shader_destroy,
}

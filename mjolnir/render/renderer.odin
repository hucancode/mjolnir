package render

import "../containers"
import "rhi"
import "core:log"
import "core:slice"
import "core:sync"

// direct_light packs camera indices into 16 bits
#assert(MAX_ACTIVE_CAMERAS < 0xFFFF)
// MAX_LIGHTS is the capacity of the light buffer.
MAX_LIGHTS :: 256
@(private)
MAX_MESHES :: 65536
@(private)
MAX_MATERIALS :: 4096
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
  // render targets below MAX_RENDER_TARGETS, every other texture above (texture.odin)
  TARGETS,
  TEXTURES,
  // your GPU programs (gpu.odin): buffers, and shaders after render's post shaders
  GPU_BUFFERS,
  SHADERS,
  MATERIAL_SHADERS,
  // draw batches (batches.odin), rows of Table.BATCHES
  BATCHES,
}

// Each pool's capacity, first index and reuse grace. The pools before CAMERAS index the rows
// of `table`.
@(private)
POOLS := [Pool]struct {
  capacity: u32,
  first:    u32,
  grace:    u64,
  table:    Table,
} {
  .MESHES                 = {MAX_MESHES, 1, RETIRE_GRACE, .MESHES},
  .MATERIALS              = {MAX_MATERIALS, 1, RETIRE_GRACE, .MATERIALS},
  .LIGHTS                 = {MAX_LIGHTS, 1, RETIRE_GRACE, .LIGHTS},
  .EMITTERS               = {MAX_EMITTERS, 1, RETIRE_GRACE, .EMITTERS},
  .FORCE_FIELDS           = {MAX_FORCE_FIELDS, 1, RETIRE_GRACE, .FORCE_FIELDS},
  // placements have no handle to go stale and each frame reads its own copy of the table,
  // so no grace
  .LIGHT_PLACEMENTS       = {MAX_LIGHTS, 1, 0, .LIGHT_PLACEMENTS},
  .EMITTER_PLACEMENTS     = {MAX_EMITTERS, 1, 0, .EMITTER_PLACEMENTS},
  .FORCE_FIELD_PLACEMENTS = {MAX_FORCE_FIELDS, 1, 0, .FORCE_FIELD_PLACEMENTS},
  .CAMERAS                = {MAX_ACTIVE_CAMERAS, 1, RETIRE_GRACE, {}},
  // retired, not reclaimed: submitted frames may still sample the slot
  .TARGETS                = {MAX_RENDER_TARGETS, 1, RETIRE_GRACE, {}},
  .TEXTURES               = {MAX_TEXTURES, MAX_RENDER_TARGETS, RETIRE_GRACE, {}},
  // the device retires what they hold
  .GPU_BUFFERS            = {MAX_GPU_BUFFERS, 1, 0, {}},
  .SHADERS                = {1 + BUILTIN_SHADERS + MAX_SHADERS, 1, 0, {}},
  .MATERIAL_SHADERS       = {MAX_MATERIAL_SHADERS + 1, 1, 0, {}},
  .BATCHES                = {MAX_BATCHES, 1, 0, .BATCHES},
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
  ANTI_ALIASING,
  PARTICLE_EMIT,
  PARTICLE_SIMULATE,
  PARTICLE_DRAW,
  SKIN,
  // debug line rings: depth-tested, drawn over everything
  DEBUG_LINE,
  DEBUG_LINE_OVER,
  OVERLAY,
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
  builtin_materials:      [Color]MaterialHandle,
  builtin_meshes:         [Primitive]MeshHandle,
  using _:               Renderer_State,
}

@(private)
Renderer_State :: struct {
  // presented to the swapchain (main_camera)
  main_camera:            CameraHandle,
  gpu:                    Backend,
  capture:                Capture,
  // render's tables, the one copy; bit r of dirty[t] is region r of tables[t]
  // (TABLE_REGION_BYTES), written since the last submitted frame. tables_sync brings the GPU
  // copies up to date.
  tables:                 [Table][]u8,
  dirty:                  [Table][]u64,
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
  mesh_slabs:             [MeshStream]containers.SlabAllocator,
  // the palettes' ranges of the bone table (BonesHandle is a palette's first bone + 1)
  bone_ranges:            containers.Ranges,
  // the skinned vertex ranges of skinned slots (pass_skin.odin)
  skin_ranges:            containers.Ranges,
  // `time` as of the last submitted frame: particles are emitted and simulated up to it, an
  // emitter having emitted floor(rate * particle_time) in total
  particle_time:          f64,
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
  // the last compute submission, which the next frame's graphics waits for
  last_compute:           rhi.SyncPoint,
  // the buffers render owns on the device (resources.odin): a copy per frame in flight of
  // each table, one of the rest
  buffers:                [SceneBuffer][FRAMES_IN_FLIGHT]rhi.Buffer,
  // per table and frame in flight: the regions render wrote that the copy lacks
  table_stale:            [Table][FRAMES_IN_FLIGHT][]u64,
  // bound where a slot has none: white 2D and black cube
  white, black_cube:      TextureHandle,
  // the shadow atlas of each frame in flight (pass_shadow.odin)
  atlas:                  [FRAMES_IN_FLIGHT]TextureHandle,
  atlas_layers:           [FRAMES_IN_FLIGHT]u32,
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
  // the 2D overlay (overlay.odin): this frame's vertices and indices, at most
  // OVERLAY_MAX_VERTICES and OVERLAY_MAX_INDICES, in batches of one scissor and texture
  overlay_vertices:       [dynamic]Vertex2D,
  overlay_indices:        [dynamic]u32,
  overlay_batches:        [dynamic]OverlayBatch,
  // the overlay was drawn or a tick ended since it was staged: the next stage_overlay replaces it
  overlay_stale:          bool,
  // sampled by text commands: the uploaded font.atlas version and its size
  overlay_font_atlas:     TextureHandle,
  overlay_font_version:   u64,
  overlay_font_size:      [2]u32,
  // the window's, as frame last measured it: maps window coordinates to pixels
  dpi_scale:              f32,
  mutex:                  sync.Recursive_Mutex,
  // your GPU programs (gpu.odin), by handle; work staged for the next frame; the draws frames
  // draw, stale once drawn or a tick ended
  gpu_buffers:            [MAX_GPU_BUFFERS]GpuBuffer,
  shaders:                [1 + BUILTIN_SHADERS + MAX_SHADERS]Shader,
  gpu_work:               [dynamic]GpuWork,
  gpu_draws:              [dynamic]GpuDraw,
  gpu_draws_stale:        bool,
  gpu_layouts:            map[GpuLayoutKey]rhi.BindLayout,
  // ready ran init_resources
  initialized:            bool,
}

// init brings the renderer up on a window, sized as it is: the GPU backend, every resource and
// an empty scene with a main camera. Paired with shutdown. A backend whose device arrives
// asynchronously (wgpu on the web) finishes in ready: until it returns true, nothing but ready
// may be called. Main thread.
init :: proc(self: ^Renderer, window: WindowHandle) -> bool {
  for stream, s in MESH_STREAMS do containers.slab_init(&self.mesh_slabs[s], stream.slab)
  dev.init(&self.gpu, window, BINDLESS_SIZES) or_return
  for t, i in TABLES {
    self.tables[i] = make([]u8, t.stride * t.capacity)
    words := (t.stride * t.capacity + TABLE_REGION_BYTES * 64 - 1) / (TABLE_REGION_BYTES * 64)
    self.dirty[i] = make([]u64, words)
    for &s in self.table_stale[i] do s = make([]u64, words)
  }
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
  for &slots, p in self.slots do containers.slots_init(&slots, POOLS[p].capacity, POOLS[p].grace, POOLS[p].first)
  resources_init(self) or_return
  resources_bind(self) or_return
  cull_init(self) or_return
  shadow_init(self) or_return
  material_init(self) or_return
  ambient_occlusion_init(self) or_return
  anti_aliasing_init(self) or_return
  lighting_init(self) or_return
  post_init(self) or_return
  particles_init(self) or_return
  skin_init(self) or_return
  debug_line_init(self) or_return
  overlay_init(self) or_return
  for frame in 0 ..< u32(FRAMES_IN_FLIGHT) {
    draw_list_create(self, SHADOW_DRAW_SLOT_BASE + frame, shadow = true) or_return
  }
  containers.ranges_init(&self.bone_ranges, MAX_BONES)
  containers.ranges_init(&self.skin_ranges, MAX_SKINNED_VERTICES)
  self.cameras = make([]Camera, MAX_ACTIVE_CAMERAS)
  self.camera_targets = make([]CameraTargets, MAX_ACTIVE_CAMERAS)
  init_builtin_materials(self)
  init_builtin_meshes(self)
  ambient_init(self) or_return
  for &inbox in self.debug_lines do inbox = make([dynamic]DebugLineSegment, 0, 1024)
  extent := dev.extent(&self.gpu)
  cam, created := camera_create(self, extent, make_camera(MAIN_CAMERA_POSITION))
  if !created do return false
  self.main_camera = cam
  // what init made outlives teardown
  mark_resources(self)
  return true
}

// Marks what init made, which teardown keeps.
@(private = "file")
mark_resources :: proc(self: ^Renderer) {
  for &slots in self.slots do containers.slots_mark(&slots)
  for &slab in self.mesh_slabs do containers.slab_mark(&slab)
  containers.ranges_mark(&self.bone_ranges)
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
  for r in containers.slots_flush(&self.slots[.TARGETS]) do dev.texture_destroy(&self.gpu, TextureHandle(r.index))
  for i in self.slots[.TEXTURES].mark ..< self.slots[.TEXTURES].high_water {
    dev.texture_destroy(&self.gpu, TextureHandle(i))
  }
  groups_clear(self)
  containers.slots_rewind(&self.slots[.TEXTURES])
  // the staged overlay may sample what was freed
  overlay_clear(self)
  containers.slots_rewind(&self.slots[.CAMERAS])
  for p in Pool.MESHES ..= Pool.FORCE_FIELD_PLACEMENTS {
    slots := &self.slots[p]
    clear_entry(self, POOLS[p].table, slots.mark, slots.high_water - slots.mark)
    containers.slots_rewind(slots)
  }
  for &slab in self.mesh_slabs do containers.slab_rewind(&slab)
  clear_entry(self, .NODES, 0, self.node_count)
  self.node_count = 0
  when !BINDLESS do batches_reset(self)
  containers.ranges_rewind(&self.bone_ranges)
  containers.ranges_rewind(&self.skin_ranges)
  clear_entry(self, .SKIN_OWNERS, 0, self.skinned_vertex_count)
  self.skinned_vertex_count = 0
  self.shadow_casters = {}
  clear(&self.bursts)
  gpu_reset(self)
  if !particles_reset(self) do log.error("teardown: cannot clear the particles")
  ambient_reset(self)
  self.cameras[self.main_camera] = make_camera(MAIN_CAMERA_POSITION)
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
  for table in self.tables do delete(table)
  for bits in self.dirty do delete(bits)
  for frames in self.table_stale do for bits in frames do delete(bits)
  delete(self.batch_ids)
  delete(self.batch_order)
  delete(self.overlay_batches)
  delete(self.overlay_vertices)
  delete(self.overlay_indices)
  gpu_shutdown(self)
  for inbox in self.debug_lines do delete(inbox)
  delete(self.bursts)
  for &slab in self.mesh_slabs do containers.slab_destroy(&slab)
  containers.ranges_destroy(&self.bone_ranges)
  containers.ranges_destroy(&self.skin_ranges)
  for &slots in self.slots do containers.slots_destroy(&slots)
  delete(self.cameras)
  delete(self.camera_targets)
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
      case .TARGETS, .TEXTURES:
        dev.texture_destroy(&self.gpu, TextureHandle(r.index))
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
  flush_cameras(self, frame_index)
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
    // the backend has every write so far
    for bits in self.dirty do slice.zero(bits)
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

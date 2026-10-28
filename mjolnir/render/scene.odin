package render

import "../geometry"
import "../containers"
import "rhi"
import "core:log"
import "core:math"
import "core:math/linalg"
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
  BONES,
  // render targets below MAX_RENDER_TARGETS, every other texture above (texture.odin)
  TARGETS,
  TEXTURES,
  // your GPU programs (gpu.odin) and post shaders, kept through teardown
  GPU_BUFFERS,
  GPU_SHADERS,
  POST_SHADERS,
}

// Each pool's capacity, first index and reuse grace; `kept` pools keep what was made before
// setup through teardown. The pools before CAMERAS index the rows of `table`.
@(private)
POOLS := [Pool]struct {
  capacity: u32,
  first:    u32,
  grace:    u64,
  kept:     bool,
  table:    Table,
} {
  .MESHES                 = {MAX_MESHES, 1, RETIRE_GRACE, true, .MESHES},
  .MATERIALS              = {MAX_MATERIALS, 1, RETIRE_GRACE, true, .MATERIALS},
  .LIGHTS                 = {MAX_LIGHTS, 1, RETIRE_GRACE, true, .LIGHTS},
  .EMITTERS               = {MAX_EMITTERS, 1, RETIRE_GRACE, true, .EMITTERS},
  .FORCE_FIELDS           = {MAX_FORCE_FIELDS, 1, RETIRE_GRACE, true, .FORCE_FIELDS},
  // placements have no handle to go stale and each frame reads its own copy of the table,
  // so no grace; teardown empties every slot, so none is kept
  .LIGHT_PLACEMENTS       = {MAX_LIGHTS, 1, 0, false, .LIGHT_PLACEMENTS},
  .EMITTER_PLACEMENTS     = {MAX_EMITTERS, 1, 0, false, .EMITTER_PLACEMENTS},
  .FORCE_FIELD_PLACEMENTS = {MAX_FORCE_FIELDS, 1, 0, false, .FORCE_FIELD_PLACEMENTS},
  .CAMERAS                = {MAX_ACTIVE_CAMERAS, 1, RETIRE_GRACE, true, {}},
  .BONES                  = {MAX_BONE_PALETTES, 1, RETIRE_GRACE, true, {}},
  // retired, not reclaimed: submitted frames may still sample the slot
  .TARGETS                = {MAX_RENDER_TARGETS, 1, RETIRE_GRACE, false, {}},
  .TEXTURES               = {MAX_TEXTURES, MAX_RENDER_TARGETS, RETIRE_GRACE, true, {}},
  // the device retires what they hold
  .GPU_BUFFERS            = {MAX_GPU_BUFFERS, 1, 0, false, {}},
  .GPU_SHADERS            = {MAX_GPU_SHADERS, 1, 0, false, {}},
  .POST_SHADERS           = {MAX_POST_SHADERS, 1, 0, false, {}},
}

// Renderer is the whole renderer; its fields are the settings an application edits.
// init/shutdown own the GPU backend and what init makes (builtin meshes and
// materials, the main camera): application lifetime. Everything made after the last setup
// (or init) lives for the map: teardown frees it in one go.
Renderer :: struct {
  skybox_intensity:       f32,
  skybox_blur:            f32,
  // scales image-based lighting
  ibl_intensity:          f32,
  // the one directional light of the scene, lit from the start; edit it to run a day/night cycle
  sun:                    Sun,
  builtin_materials:      [Color]MaterialHandle,
  builtin_meshes:         [Primitive]MeshHandle,
  // the main camera runs the stack in order; without a ToneMapEffect it presents HDR as is
  effect_stack:           [dynamic]PostprocessEffect,
  using _:               Renderer_State,
}

@(private)
Renderer_State :: struct {
  // presented to the swapchain (main_camera)
  main_camera:            CameraHandle,
  gpu:                    Backend,
  dump:                   FrameDump,
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
  // view of the sun's first shadow cascade this frame, 0 when it got none (collect_lights)
  sun_shadow_map:         u32,
  environment_map:        TextureHandle,
  brdf_lut:               TextureHandle,
  irradiance_cube:        TextureHandle,
  prefilter_cube:         TextureHandle,
  particle_params:        ParticleSystemParams,
  // which handles of each kind are live (POOLS)
  slots:                  [Pool]containers.Slots,
  cameras:                []Camera,
  camera_targets:         []CameraTargets,
  // pass i writes slot i % POST_PROCESS_RING; its input and original are the two slots before
  post_process_ring:      [FRAMES_IN_FLIGHT][POST_PROCESS_RING]TextureHandle,
  mesh_slabs:             [MeshStream]containers.SlabAllocator,
  // the palettes' ranges of the bone table, and each palette's first bone (by BonesHandle)
  bone_ranges:            containers.Ranges,
  bone_first:             [MAX_BONE_PALETTES]u32,
  // the skinned vertex ranges of skinned slots (pass_skin.odin)
  skin_ranges:            containers.Ranges,
  // simulated seconds; an emitter emits floor(rate * time) particles in total
  particle_time:          f64,
  // emit's queue, and the bursts the last flush placed (row != 0)
  bursts:                 [dynamic]Burst,
  // segments added since the last frame, per ring: [0] depth-tested, [1] drawn over the scene
  debug_lines:            [2][dynamic]DebugLineSegment,
  // segments each ring has taken in total (debug_line.odin)
  debug_filled:           [2]u64,
  // seconds render.update has advanced; shaders read it as View.time and PostPush.time
  time:                   f32,
  debug_mutex:            sync.Mutex,
  shadow_casters:         [MAX_SHADOW_MAPS]Caster,
  // the last compute submission, which the next frame's graphics waits for
  last_compute:           rhi.SyncPoint,
  // the buffers render owns on the device (resources.odin): a copy per frame in flight of
  // each table, one of the rest
  buffers:                [SceneBuffer][FRAMES_IN_FLIGHT]rhi.Buffer,
  // per table and frame in flight: the regions render wrote that the copy lacks
  table_stale:            [Table][FRAMES_IN_FLIGHT][]u64,
  ui_vertex_buffers:      [FRAMES_IN_FLIGHT]rhi.Buffer,
  ui_index_buffers:       [FRAMES_IN_FLIGHT]rhi.Buffer,
  // bound where a slot has none: white 2D and black cube
  white, black_cube:      TextureHandle,
  // the shadow atlas of each frame in flight (pass_shadow.odin)
  atlas:                  [FRAMES_IN_FLIGHT]TextureHandle,
  atlas_layers:           [FRAMES_IN_FLIGHT]u32,
  // a bindless device has one layout and group per frame, at .NONE, which every pass binds
  scene_layouts:          [ScenePass]rhi.BindLayout,
  scene_groups:           [ScenePass][FRAMES_IN_FLIGHT]rhi.BindGroup,
  texture_layouts:        [TextureLayout]rhi.BindLayout,
  texture_groups:         map[TextureGroupKey]rhi.BindGroup,
  // culling (pass_cull.odin)
  cull_pipeline:          rhi.Pipeline,
  // batched: writes the draw of each batch
  cull_draws_pipeline:    rhi.Pipeline,
  // the pyramid build: compacted builds every mip at once, batched mip by mip
  reduce_pipeline:        rhi.Pipeline,
  // batched: group 3 of the cull and of the pyramid build
  cull_layout:            rhi.BindLayout,
  reduce_layout:          rhi.BindLayout,
  cull_groups:            map[CullKey]rhi.BindGroup,
  reduce_groups:          map[ReduceKey]rhi.BindGroup,
  draw_lists:             [MAX_DRAW_LIST_SLOTS]GpuDrawList,
  pyramid_counters:       rhi.Buffer,
  // the main camera's visible opaque draws, copied out per frame in flight
  draw_count_readback:    [FRAMES_IN_FLIGHT]rhi.Buffer,
  // draws are batched per mesh and material where they are not compacted (batches.odin):
  // (material, mesh) -> batch id, the freed ids, the ids below batch_high in use or free,
  // and whether first_instance is stale
  batch_ids:              map[u64]u32,
  batch_free:             [dynamic]u32,
  batch_high:             u32,
  batch_stale:            bool,
  batch_warned:           bool,
  // this frame's live batches by draw list key, material and id: key << 44 | material << 20 | id
  batch_order:            [dynamic]u64,
  // each pass's pipelines
  shadow_pipeline:        rhi.Pipeline,
  material_pipelines:     [MaterialPass][len(MaterialType)]rhi.Pipeline,
  lighting_pipeline:      rhi.Pipeline,
  // WebGPU: group 3 of the lighting dispatch, the image it writes, a group per image
  lighting_output_layout: rhi.BindLayout,
  lighting_output_groups: map[TextureHandle]rhi.BindGroup,
  // [is_last][tag]: every pass writes an HDR ring image but the last, which writes the backbuffer
  post_pipelines:         [2][POST_EFFECT_COUNT]rhi.Pipeline,
  // [PostShader][is_last]
  custom_post_pipelines:  [MAX_POST_SHADERS][2]rhi.Pipeline,
  // [MaterialShader - 1], 0 where free
  custom_material_pipelines: [MAX_MATERIAL_SHADERS]rhi.Pipeline,
  particle_emit_pipeline: rhi.Pipeline,
  particle_sim_pipeline:  rhi.Pipeline,
  particle_draw_pipeline: rhi.Pipeline,
  skin_pipeline:          rhi.Pipeline,
  // by ring
  debug_line_pipelines:   [2]rhi.Pipeline,
  overlay_pipeline:       rhi.Pipeline,
  // the 2D overlay (overlay_renderer.odin): this frame's vertices and indices, at most
  // UI_MAX_VERTICES and UI_MAX_INDICES, in batches of one scissor and texture
  ui_vertices:            [dynamic]Vertex2D,
  ui_indices:             [dynamic]u32,
  ui_batches:             [dynamic]UIBatch,
  // the overlay was drawn or a tick ended since it was staged: the next stage_overlay replaces it
  ui_stale:               bool,
  // sampled by text commands: the uploaded font.atlas version
  ui_font_atlas:          TextureHandle,
  ui_font_version:        u64,
  // the window's, as frame last measured it: maps window coordinates to pixels
  dpi_scale:              f32,
  mutex:                  sync.Recursive_Mutex,
  // your GPU programs (gpu.odin), by handle; work staged for the next frame; the draws frames
  // draw, stale once drawn or a tick ended
  gpu_buffers:            [MAX_GPU_BUFFERS]GpuBuffer,
  gpu_shaders:            [MAX_GPU_SHADERS]GpuShader,
  gpu_work:               [dynamic]GpuWork,
  gpu_draws:              [dynamic]GpuDraw,
  gpu_draws_stale:        bool,
  gpu_layouts:            map[GpuLayoutKey]rhi.BindLayout,
  // per texture, its format when made with texture_create(storage = true), else the zero
  // format, RGBA8_SRGB, which no storage texture takes
  storage_formats:        [MAX_TEXTURES]TextureFormat,
  // ready ran init_resources
  initialized:            bool,
}

// init brings the renderer up on a window, sized as it is: the GPU backend, every resource and
// an empty scene with a main camera. Paired with shutdown. A backend whose device arrives
// asynchronously (wgpu on the web) finishes in ready: until it returns true, nothing but ready
// may be called. Main thread.
init :: proc(self: ^Renderer, window: WindowHandle) -> bool {
  for stream, s in MESH_STREAMS do containers.slab_init(&self.mesh_slabs[s], stream.slab)
  dev.init(&self.gpu, window) or_return
  for t, i in TABLES {
    self.tables[i] = make([]u8, t.stride * t.capacity)
    words := (t.stride * t.capacity + TABLE_REGION_BYTES * 64 - 1) / (TABLE_REGION_BYTES * 64)
    self.dirty[i] = make([]u64, words)
    for &s in self.table_stale[i] do s = make([]u64, words)
  }
  _, self.dpi_scale = dev.window_size(&self.gpu)
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
  self.effect_stack = make([dynamic]PostprocessEffect)
  post_process_create_images(self) or_return
  for &inbox in self.debug_lines do inbox = make([dynamic]DebugLineSegment, 0, 1024)
  extent := dev.extent(&self.gpu)
  cam, created := camera_create(self, extent.x, extent.y, position = {3, 4, 3}, far = 1000.0)
  if !created do return false
  self.main_camera = cam
  self.sun = DEFAULT_SUN
  // what init made outlives teardown
  mark_resources(self)
  return true
}

// setup keeps what the application made so far (since init) through every later teardown,
// as what init makes is kept. Call it once, after making application-lifetime resources and
// before the first map; without it teardown frees everything made since init.
setup :: proc(self: ^Renderer) {
  guard(self)
  mark_resources(self)
}

// teardown frees from the marks on
@(private)
mark_resources :: proc(self: ^Renderer) {
  for &slots, p in self.slots do if POOLS[p].kept do containers.slots_mark(&slots)
  for &slab in self.mesh_slabs do containers.slab_mark(&slab)
  containers.ranges_mark(&self.bone_ranges)
}

// teardown ends a map in one go, waiting for the GPU: no particle stays alive, every slot
// forgets its attachment and bone palette, and every camera, mesh, material, light, emitter, force field and
// texture made since the last setup
// (or init) is freed; an environment map among them gives way to the default one. What came
// before stays:
// what init made (builtin meshes and materials, the main camera, render targets, pipelines)
// and what the application made before setup. Handles to freed resources are stale.
teardown :: proc(self: ^Renderer) {
  guard(self)
  // their render targets and draw lists retire, and go with the flushes below
  c := self.slots[.CAMERAS].mark
  for i in containers.slots_next(&self.slots[.CAMERAS], &c) do camera_destroy(self, CameraHandle(i))
  // queued uploads may be init's: they land before anything is freed
  dev.wait_idle(&self.gpu)
  for r in containers.slots_flush(&self.slots[.TARGETS]) do dev.texture_destroy(&self.gpu, TextureHandle(r.index))
  for i in self.slots[.TEXTURES].mark ..< self.slots[.TEXTURES].high_water {
    dev.texture_destroy(&self.gpu, TextureHandle(i))
    self.storage_formats[i] = {}
  }
  groups_clear(self)
  containers.slots_rewind(&self.slots[.TEXTURES])
  if u32(self.environment_map) >= self.slots[.TEXTURES].mark {
    self.environment_map, self.irradiance_cube, self.prefilter_cube = 0, 0, 0
    if !ambient_load_environment(self) do log.error("teardown: cannot restore the default environment map")
  }
  // the next text staged uploads the font atlas again
  if u32(self.ui_font_atlas) >= self.slots[.TEXTURES].mark do self.ui_font_atlas = 0
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
  containers.slots_rewind(&self.slots[.BONES])
  containers.ranges_rewind(&self.bone_ranges)
  containers.ranges_rewind(&self.skin_ranges)
  clear_entry(self, .SKIN_OWNERS, 0, self.skinned_vertex_count)
  self.skinned_vertex_count = 0
  self.shadow_casters = {}
  clear(&self.bursts)
  gpu_reset(self)
  if !particles_reset(self) do log.error("teardown: cannot clear the particles")
}

// environment_map_load replaces the environment map with the equirectangular HDR image encoded
// in `data` and precomputes image-based lighting from it. Until then render lights the scene
// with a default one.
environment_map_load :: proc(self: ^Renderer, data: []u8) -> bool {
  ok := ambient_load_environment(self, data)
  if !ok do log.warnf("Failed to load environment map")
  return ok
}

// shutdown destroys everything, whatever map is up.
shutdown :: proc(self: ^Renderer) {
  dump_finish(self)
  delete(self.cull_groups)
  delete(self.reduce_groups)
  delete(self.lighting_output_groups)
  delete(self.texture_groups)
  dev.shutdown(&self.gpu)
  for table in self.tables do delete(table)
  for bits in self.dirty do delete(bits)
  for frames in self.table_stale do for bits in frames do delete(bits)
  delete(self.batch_ids)
  delete(self.batch_free)
  delete(self.batch_order)
  delete(self.ui_batches)
  delete(self.ui_vertices)
  delete(self.ui_indices)
  delete(self.effect_stack)
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
    camera_resize(self, CameraHandle(i), extent.x, extent.y) or_return
  }
  post_process_release_images(self)
  post_process_create_images(self) or_return
  return true
}

// POST_PROCESS_RING is the intermediate images per frame in flight the effect stack ping-pongs.
@(private)
POST_PROCESS_RING :: 3

// The post-process ring of every frame in flight, at the swapchain extent;
// recreate_swapchain rebuilds it.
@(private = "file")
post_process_create_images :: proc(self: ^Renderer) -> bool {
  desc := TextureDesc {
    extent = dev.extent(&self.gpu),
    format = HDR_COLOR_FORMAT,
    usage  = {.COLOR_TARGET, .SAMPLED},
  }
  for &frame in self.post_process_ring {
    for &handle in frame do handle = allocate_texture(self, desc, target = true) or_return
  }
  return true
}

@(private = "file")
post_process_release_images :: proc(self: ^Renderer) {
  for &frame in self.post_process_ring {
    for &handle in frame {
      texture_destroy(self, handle)
      handle = 0
    }
  }
}

// lock holds off frame while another thread edits the scene. When your simulation runs on its
// own thread, make its edits of a tick under
//   render.lock(r); defer render.unlock(r)
// so frame, on the main thread, sees whole ticks. The pointers material, light, emitter,
// force_field and camera return are then valid for the tick. Single-threaded, the lock costs
// nothing.
lock :: proc(self: ^Renderer) {
  sync.recursive_mutex_lock(&self.mutex)
}

// unlock releases the lock taken by lock.
unlock :: proc(self: ^Renderer) {
  sync.recursive_mutex_unlock(&self.mutex)
}

// guard holds the lock until the end of the calling scope.
@(private, deferred_in = unlock)
guard :: proc(self: ^Renderer) {
  lock(self)
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
  sync.mutex_lock(&self.debug_mutex)
  self.time += delta_time
  sync.mutex_unlock(&self.debug_mutex)
  guard(self)
  self.ui_stale = true
  self.gpu_draws_stale = true
  if delta_time <= 0 do return
  // flush_particles emits for it; particles_simulate consumes it
  self.particle_params.delta_time += delta_time
}

@(private)
NodeFlag :: enum u32 {
  VISIBLE,
  CASTS_SHADOW,
  // attachment_data_index holds a bone range; only set while the mesh is skinned, so the
  // shaders skin by this flag alone
  SKINNED,
  // a light, emitter or force field is attached: a placement row names the slot
  PLACED,
}

@(private)
NodeFlagSet :: bit_set[NodeFlag;u32]

// the shadow pass draws these; the material type must also be in GBUFFER_TYPES
@(private)
SHADOW_CASTER_FLAGS :: NodeFlagSet{.VISIBLE, .CASTS_SHADOW}

// The zero record is an empty slot: mesh and material 0 are none. When .SKINNED is set,
// attachment_data_index is the first bone of its palette `bones` in the bone table and
// skin_vertex_base the first of its skinned vertices (pass_skin.odin).
@(private)
Node :: struct #packed {
  world_matrix:          matrix[4, 4]f32,
  material_id:           u32,
  mesh_id:               u32,
  attachment_data_index: u32,
  flags:                 NodeFlagSet,
  skin_vertex_base:      u32,
  // the palette attachment_data_index is the first bone of
  bones:                 BonesHandle,
  _:                     [2]u32,
}
#assert(size_of(Node) == 96)

// MeshAttachment draws mesh with material from a slot's transform; a skinned mesh deforms by
// the palette `bones` (bones_create), else draws as modelled.
MeshAttachment :: struct {
  mesh:        MeshHandle,
  material:    MaterialHandle,
  cast_shadow: bool,
  bones:       BonesHandle,
}

// SlotHandle is a scene slot: any u32 below MAX_SLOTS you pick, e.g. a scene graph node's
// index; the cull's cost follows the highest slot in use, so keep them dense. Procs taking a
// slot take a SlotHandle or any handle with an `index` field.
SlotHandle :: distinct u32

@(private)
slot_index :: #force_inline proc(slot: $H) -> u32 {
  when H == SlotHandle {
    return u32(slot)
  } else {
    return u32(slot.index)
  }
}

// What a slot draws: a mesh, or a light, emitter or force field (*_create) placed at the
// slot's transform. One light, emitter or force field may be attached at many slots.
Attachment :: union {
  MeshAttachment,
  LightHandle,
  EmitterHandle,
  ForceFieldHandle,
}

// Grows the slot range to cover `slot`; slots past it are already empty (zero). nil past
// MAX_SLOTS. Caller holds the render mutex and marks what it changes.
@(private)
slot_node :: proc(self: ^Renderer, slot: u32) -> ^Node {
  if slot >= MAX_SLOTS {
    log.errorf("Slot %d exceeds MAX_SLOTS", slot)
    return nil
  }
  self.node_count = max(self.node_count, slot + 1)
  return &write_table(self, .NODES, Node)[slot]
}

// place sets where a slot draws and whether it shows; a slot draws nothing until placed.
place :: proc(self: ^Renderer, slot: $H, world_matrix: matrix[4, 4]f32, visible := true) {
  slot := slot_index(slot)
  guard(self)
  node := slot_node(self, slot)
  if node == nil do return
  node.world_matrix = world_matrix
  if visible do node.flags += {.VISIBLE}
  else do node.flags -= {.VISIBLE}
  mark_dirty(self, .NODES, int(slot))
}

// release empties a slot: it forgets its attachment and bone palette; meshes, materials and
// what was attached stay.
release :: proc(self: ^Renderer, slot: $H) {
  slot := slot_index(slot)
  guard(self)
  unbind(self, slot)
  #reverse for b, i in self.bursts do if b.row == 0 && b.slot == slot do ordered_remove(&self.bursts, i)
  if slot >= self.node_count do return
  release_bones(self, slot)
  batch_leave(self, slot)
  write_table(self, .NODES, Node)[slot] = {}
  mark_dirty(self, .NODES, int(slot))
}

// stage_transforms applies a scene graph's change feed, place or release per entry: `changes` is
// any struct with `index`, `world_matrix`, `visible` and `removed` fields, removals first.
stage_transforms :: proc(self: ^Renderer, changes: []$T) {
  guard(self)
  for &c in changes {
    if c.removed do release(self, SlotHandle(c.index))
    else do place(self, SlotHandle(c.index), c.world_matrix, c.visible)
  }
}

// A placement table holds at most one row per slot. The live row of `table` placed at `slot`.
@(private = "file")
placed_at :: proc(self: ^Renderer, pool: Pool, $T: typeid, slot: u32) -> (index: u32, ok: bool) {
  rows := write_table(self, POOLS[pool].table, T)
  c: u32
  for i in containers.slots_next(&self.slots[pool], &c) {
    // no attachment owns a burst's row
    when T == EmitterPlacement do if rows[i].burst != 0 do continue
    if rows[i].node == slot do return i, true
  }
  return
}

// Frees the slot's placement row of `pool`, if any.
@(private = "file")
unplace :: proc(self: ^Renderer, pool: Pool, $T: typeid, slot: u32) {
  i := placed_at(self, pool, T, slot) or_else 0
  if i == 0 do return
  containers.slots_free(&self.slots[pool], i)
  clear_entry(self, POOLS[pool].table, i)
}

// Drops the slot's light, emitter and force field. Caller holds the render mutex.
@(private = "file")
unbind :: proc(self: ^Renderer, slot: u32) {
  if slot >= self.node_count do return
  node := &write_table(self, .NODES, Node)[slot]
  if .PLACED not_in node.flags do return
  node.flags -= {.PLACED}
  mark_dirty(self, .NODES, int(slot))
  unplace(self, .LIGHT_PLACEMENTS, LightPlacement, slot)
  unplace(self, .EMITTER_PLACEMENTS, EmitterPlacement, slot)
  unplace(self, .FORCE_FIELD_PLACEMENTS, ForceFieldPlacement, slot)
}

// Stores `value` in a free row of the pool's table; the row is the resource's handle (or a
// placement's row).
@(private)
resource_create :: proc(self: ^Renderer, pool: Pool, value: $T) -> (index: u32, ok: bool) {
  guard(self)
  index = containers.slots_alloc(&self.slots[pool]) or_return
  write_table(self, POOLS[pool].table, T)[index] = value
  mark_dirty(self, POOLS[pool].table, int(index))
  return index, true
}

// The row of a live handle, to edit in place: valid until the next frame, as render.material's.
@(private)
resource :: proc(self: ^Renderer, pool: Pool, $T: typeid, index: u32) -> (^T, bool) {
  if !containers.slots_live(&self.slots[pool], index) do return nil, false
  mark_dirty(self, POOLS[pool].table, int(index))
  return &write_table(self, POOLS[pool].table, T)[index], true
}

// Frees a row; what still refers to it reads zeros.
@(private)
resource_destroy :: proc(self: ^Renderer, pool: Pool, index: u32) {
  guard(self)
  if !containers.slots_free(&self.slots[pool], index) do return
  clear_entry(self, POOLS[pool].table, index)
}

// Gives the skinned vertices of the range at `base` to `owner` (slot + 1, 0 for none), for
// the skinning pass.
@(private = "file")
skin_own :: proc(self: ^Renderer, base, owner: u32) {
  size := containers.ranges_size(&self.skin_ranges, base)
  slice.fill(write_table(self, .SKIN_OWNERS, u32)[base:][:size], owner)
  mark_dirty(self, .SKIN_OWNERS, int(base), int(size))
  self.skinned_vertex_count = max(self.skinned_vertex_count, base + size)
}

// Drops the slot's skinned vertices and its link to a palette. Caller holds the render mutex.
@(private = "file")
release_bones :: proc(self: ^Renderer, slot: u32) {
  node := &write_table(self, .NODES, Node)[slot]
  if .SKINNED not_in node.flags do return
  skin_own(self, node.skin_vertex_base, 0)
  containers.ranges_free(&self.skin_ranges, node.skin_vertex_base)
  node.attachment_data_index, node.skin_vertex_base, node.bones = 0, 0, 0
  node.flags -= {.SKINNED}
  mark_dirty(self, .NODES, int(slot))
}

// BonesHandle is a bone palette (bones_create): skinned meshes attached with it deform by it.
BonesHandle :: distinct u32

// MAX_BONE_PALETTES is how many palettes (bones_create) exist at once.
MAX_BONE_PALETTES :: 4096

// bones_create makes a palette of `count` bones (one per animated character, shared by every
// skinned mesh of it, MeshAttachment.bones), at rest until stage_bones; it lives until
// bones_destroy or teardown. false past MAX_BONES bones in all.
bones_create :: proc(self: ^Renderer, count: u32) -> (handle: BonesHandle, ok: bool) #optional_ok {
  guard(self)
  i := containers.slots_alloc(&self.slots[.BONES]) or_return
  first, has_room := containers.ranges_alloc(&self.bone_ranges, count)
  if !has_room {
    containers.slots_free(&self.slots[.BONES], i)
    log.warnf("No room for a %d-bone palette past MAX_BONES (%d)", count, MAX_BONES)
    return 0, false
  }
  self.bone_first[i] = first
  slice.fill(write_table(self, .BONES, matrix[4, 4]f32)[first:][:count], 1)
  mark_dirty(self, .BONES, int(first), int(count))
  return BonesHandle(i), true
}

// stage_bones sets a palette's bone skinning matrices (skeleton-space bone matrix times inverse
// bind, per bone, relative to each slot's world matrix): every skinned mesh attached with it
// deforms by them. The matrices are copied, at most the palette's bone count.
stage_bones :: proc(self: ^Renderer, bones: BonesHandle, matrices: []matrix[4, 4]f32) {
  guard(self)
  if !containers.slots_live(&self.slots[.BONES], u32(bones)) do return
  first := self.bone_first[bones]
  count := min(u32(len(matrices)), containers.ranges_size(&self.bone_ranges, first))
  copy(write_table(self, .BONES, matrix[4, 4]f32)[first:][:count], matrices[:count])
  mark_dirty(self, .BONES, int(first), int(count))
}

// bones_destroy frees the palette; its meshes draw unskinned.
bones_destroy :: proc(self: ^Renderer, bones: BonesHandle) {
  guard(self)
  if !containers.slots_free(&self.slots[.BONES], u32(bones)) do return
  nodes := write_table(self, .NODES, Node)
  for i in 0 ..< self.node_count do if nodes[i].bones == bones do release_bones(self, i)
  containers.ranges_free(&self.bone_ranges, self.bone_first[bones])
}

// attach draws attachment at slot, replacing what the slot drew before; place sets where. A
// skinned mesh with a palette (MeshAttachment.bones) gets the slot's range of skinned vertices,
// kept while later attachments still fit in it.
attach :: proc(self: ^Renderer, slot: $H, attachment: Attachment) {
  slot := slot_index(slot)
  guard(self)
  node := slot_node(self, slot)
  if node == nil do return
  unbind(self, slot)
  batch_leave(self, slot)
  node.mesh_id, node.material_id = 0, 0
  node.flags -= {.CASTS_SHADOW}
  bones: BonesHandle
  switch a in attachment {
  case MeshAttachment:
    node.mesh_id, node.material_id = u32(a.mesh), u32(a.material)
    batch_join(self, slot, node.mesh_id, node.material_id)
    if a.cast_shadow do node.flags += {.CASTS_SHADOW}
    bones = a.bones
  case LightHandle:
    place_row(self, node, .LIGHT_PLACEMENTS, LightPlacement{light = a, node = slot}, "light")
  case EmitterHandle:
    place_row(self, node, .EMITTER_PLACEMENTS, EmitterPlacement{emitter = a, node = slot}, "emitter")
  case ForceFieldHandle:
    place_row(self, node, .FORCE_FIELD_PLACEMENTS, ForceFieldPlacement{force_field = a, node = slot}, "force field")
  }
  skin(self, slot, bones)
  mark_dirty(self, .NODES, int(slot))
}

// Adds a placement row naming the slot.
@(private = "file")
place_row :: proc(self: ^Renderer, node: ^Node, pool: Pool, row: $T, what: string) {
  if _, placed := resource_create(self, pool, row); placed {
    node.flags += {.PLACED}
  } else {
    log.warnf("No room for more than %d placed %ss; the %s is dropped", POOLS[pool].capacity - 1, what, what)
  }
}

// Gives a slot drawing a skinned mesh with a live palette its skinned vertices (keeping a range
// it already holds that fits), else none.
@(private = "file")
skin :: proc(self: ^Renderer, slot: u32, bones: BonesHandle) {
  node := &write_table(self, .NODES, Node)[slot]
  mesh := write_table(self, .MESHES, MeshData)[node.mesh_id]
  if .SKINNED not_in mesh.flags || !containers.slots_live(&self.slots[.BONES], u32(bones)) {
    release_bones(self, slot)
    return
  }
  if .SKINNED not_in node.flags || containers.ranges_size(&self.skin_ranges, node.skin_vertex_base) < mesh.vertex_count {
    release_bones(self, slot)
    base, ok := containers.ranges_alloc(&self.skin_ranges, mesh.vertex_count)
    if !ok {
      log.warnf("No room for %d more skinned vertices past MAX_SKINNED_VERTICES (%d); the mesh draws unskinned", mesh.vertex_count, MAX_SKINNED_VERTICES)
      return
    }
    node.skin_vertex_base = base
    node.flags += {.SKINNED}
    skin_own(self, base, slot + 1)
  }
  node.bones, node.attachment_data_index = bones, self.bone_first[bones]
}

// attachment returns the attachment of type T at slot, e.g. attachment(r, slot, LightHandle).
// Edit a light, emitter or force field through its handle (light, emitter, force_field); a
// MeshAttachment is a copy to pass back to attach.
attachment :: proc(
  self: ^Renderer,
  slot: $H,
  $T: typeid,
) -> (
  att: T,
  ok: bool,
) #optional_ok {
  slot := slot_index(slot)
  guard(self)
  when T == MeshAttachment {
    if slot >= self.node_count do return
    node := write_table(self, .NODES, Node)[slot]
    if node.mesh_id == 0 do return
    return {MeshHandle(node.mesh_id), MaterialHandle(node.material_id), .CASTS_SHADOW in node.flags, node.bones}, true
  } else when T == LightHandle {
    i := placed_at(self, .LIGHT_PLACEMENTS, LightPlacement, slot) or_return
    return write_table(self, .LIGHT_PLACEMENTS, LightPlacement)[i].light, true
  } else when T == EmitterHandle {
    i := placed_at(self, .EMITTER_PLACEMENTS, EmitterPlacement, slot) or_return
    return write_table(self, .EMITTER_PLACEMENTS, EmitterPlacement)[i].emitter, true
  } else when T == ForceFieldHandle {
    i := placed_at(self, .FORCE_FIELD_PLACEMENTS, ForceFieldPlacement, slot) or_return
    return write_table(self, .FORCE_FIELD_PLACEMENTS, ForceFieldPlacement)[i].force_field, true
  }
  return
}

// SPOT_LIGHT_INNER_RATIO is the default ratio of a spot light's full-intensity cone to its falloff cone.
SPOT_LIGHT_INNER_RATIO :: f32(0.75)

// Light shines from every slot it is attached to, along the slot's -Z axis, as a glTF light does
// (make_*_light fill one; light_create stores it). Point lights ignore the angles. The sun is not
// a Light: Renderer.sun.
Light :: struct #align(16) {
  color:              [3]f32,
  // strength at 1 unit away, falling off by inverse square and fading smoothly to zero at radius
  intensity:          f32,
  // range of the light
  radius:             f32,
  angle_inner:        f32, // spot cone angles
  angle_outer:        f32,
  type:               LightType,
  // the light competes for a shadow map
  cast_shadow: b32,
}
#assert(size_of(Light) == 48)

// Sun is the scene's one directional light, owned by the renderer (Renderer.sun) and on by
// default: it needs no node or attachment. Edit its fields any time, e.g. turn direction and
// color over a day.
Sun :: struct {
  enabled:         bool,
  cast_shadow:     bool,
  color:           [3]f32,
  intensity:       f32,
  // the way the light travels; need not be normalized
  direction:       [3]f32,
  // how far in front of the main camera its shadow reaches; needs a main camera
  shadow_distance: f32,
}

// DEFAULT_SUN is what the renderer starts with.
DEFAULT_SUN :: Sun {
  enabled         = true,
  cast_shadow     = true,
  color           = {1, 1, 1},
  intensity       = 1,
  direction       = {-0.4, -1, -0.3},
  shadow_distance = 20,
}

// LightHandle identifies a light (light_create).
LightHandle :: distinct u32

// Where a light is attached. shadow_map is the view of the placement's first shadow face
// this frame, 0 when it got none (collect_lights).
@(private)
LightPlacement :: struct {
  light:      LightHandle,
  node:       u32,
  shadow_map: u32,
}

// light_create stores `l`; attach places it at slots. It lives until light_destroy or teardown.
light_create :: proc(self: ^Renderer, l: Light) -> (handle: LightHandle, ok: bool) #optional_ok {
  i := resource_create(self, .LIGHTS, l) or_return
  return LightHandle(i), true
}

// light returns the light of `handle`, to edit in place; every slot it is attached to follows.
// The pointer is valid for this tick: getting it marks the data for upload, so get it again
// next tick.
light :: proc(self: ^Renderer, handle: LightHandle) -> (^Light, bool) #optional_ok {
  return resource(self, .LIGHTS, Light, u32(handle))
}

// light_destroy frees the light; slots it stays attached to shine nothing.
light_destroy :: proc(self: ^Renderer, handle: LightHandle) {
  resource_destroy(self, .LIGHTS, u32(handle))
}

// Where a light at a node's transform sits and shines: its translation and normalized forward
// (-Z) axis. The lighting shaders read a placed light the same way.
@(private)
light_pose :: proc(world_matrix: matrix[4, 4]f32) -> (position, direction: [3]f32) {
  forward := -world_matrix[2].xyz
  return world_matrix[3].xyz, linalg.normalize(forward) if linalg.dot(forward, forward) > 1e-6 else {0, -1, 0}
}

// make_point_light returns an omnidirectional Light for light_create.
make_point_light :: proc(
  color: [3]f32 = {1, 1, 1},
  intensity: f32 = 1.0,
  radius: f32 = 10.0,
  cast_shadow: bool = true,
) -> Light {
  return {type = .POINT, color = color, intensity = intensity, radius = radius, cast_shadow = b32(cast_shadow)}
}

// make_spot_light returns a cone Light of the given half angle for light_create.
make_spot_light :: proc(
  color: [3]f32 = {1, 1, 1},
  intensity: f32 = 1.0,
  radius: f32 = 10.0,
  angle: f32 = math.PI * 0.2,
  cast_shadow: bool = true,
) -> Light {
  return {
    type        = .SPOT,
    color       = color,
    intensity   = intensity,
    radius      = radius,
    angle_inner = angle * SPOT_LIGHT_INNER_RATIO,
    angle_outer = angle,
    cast_shadow = b32(cast_shadow),
  }
}

// matches SHADOW_CASCADES in the lighting shader
@(private)
SHADOW_CASCADES :: 4
// 0 splits uniformly, 1 logarithmically
@(private)
SHADOW_CASCADE_LOG_WEIGHT :: 0.75

// One shadow view and atlas layer per face.
@(private)
SHADOW_FACE_COUNT := [LightType]u32 {
  .POINT = len(CUBE_FACES),
  .SPOT        = 1,
}

// (forward, up) per face, in the order the lighting shader's shadowFace picks them
@(private)
CUBE_FACES := [6][2][3]f32 {
  {{1, 0, 0}, {0, -1, 0}},
  {{-1, 0, 0}, {0, -1, 0}},
  {{0, 1, 0}, {0, 0, 1}},
  {{0, -1, 0}, {0, 0, -1}},
  {{0, 0, 1}, {0, -1, 0}},
  {{0, 0, -1}, {0, -1, 0}},
}

// A shadow-casting light this frame, or the holder of a shadow map.
@(private)
Caster :: struct {
  owner:       u32, // light placement row + 1; 0 for a free map
  score:       f32,
  // frame serial when the owner last ranked in the top SHADOW_RANKED_CASTERS
  last_ranked: u64,
}

// How much of a camera's view a light's shadow bounds cover, weighted by
// intensity: r²/(d²−r²) grows like the sphere's projected area, and a camera
// inside the sphere scores highest.
@(private)
shadow_score :: proc(bounds: [4]f32, intensity: f32, camera_position: [3]f32) -> f32 {
  offset := bounds.xyz - camera_position
  r2 := bounds.w * bounds.w
  return intensity * r2 / max(linalg.dot(offset, offset) - r2, 1e-6)
}

// `casters` is sorted by descending score; `maps` is the previous selection, rewritten.
@(private)
select_shadow_casters :: proc(casters: []Caster, maps: ^[MAX_SHADOW_MAPS]Caster, serial: u64) -> (count: int) {
  selected: [MAX_SHADOW_MAPS]Caster
  for c, rank in casters {
    if count == MAX_SHADOW_MAPS do break
    c := c
    c.last_ranked = serial
    if rank >= SHADOW_RANKED_CASTERS {
      held := false
      for m in maps do if m.owner == c.owner {c.last_ranked = m.last_ranked; held = true}
      if !held || serial - c.last_ranked > SHADOW_GRACE_FRAMES do continue
    }
    selected[count] = c
    count += 1
  }
  maps^ = selected
  return
}

@(private = "file")
light_look :: proc(position, direction: [3]f32) -> matrix[4, 4]f32 {
  up := [3]f32{0, 0, 1} if math.abs(direction.y) > 0.95 else {0, 1, 0}
  return linalg.matrix4_look_at(position, position + direction, up)
}

@(private)
shadow_face_matrices :: proc(l: Light, position, direction: [3]f32, face: int) -> (view, projection: matrix[4, 4]f32) {
  perspective :: proc(fovy, radius: f32) -> matrix[4, 4]f32 {
    near :: 0.1
    return geometry.make_perspective_matrix(max(fovy, 0.001), 1.0, near, max(near + 0.1, radius))
  }
  switch l.type {
  case .POINT:
    rotation := linalg.matrix4_look_at([3]f32{}, CUBE_FACES[face][0], CUBE_FACES[face][1])
    return rotation * linalg.matrix4_translate(-position), perspective(math.PI * 0.5, l.radius)
  case .SPOT:
    return light_look(position, direction), perspective(l.angle_outer * 2, l.radius)
  }
  return
}

// Orthographic box around the bounding sphere of the cascade's camera-frustum slice: the
// sphere keeps the size fixed as the camera turns, texel snapping holds edges still as it moves.
@(private)
cascade_matrices :: proc(shadow_distance: f32, direction: [3]f32, cascade: int, camera: ^View) -> (view, projection: matrix[4, 4]f32) {
  near := camera.near
  far := max(min(max(shadow_distance, 0.5), camera.far), near + 0.01)
  split :: proc(near, far: f32, i: int) -> f32 {
    t := f32(i) / SHADOW_CASCADES
    return math.lerp(near + (far - near) * t, near * math.pow(far / near, t), f32(SHADOW_CASCADE_LOG_WEIGHT))
  }
  depth_range := max(camera.far - camera.near, 1e-6)
  from := (split(near, far, cascade) - camera.near) / depth_range
  to := (split(near, far, cascade + 1) - camera.near) / depth_range
  corners: [8][3]f32
  center: [3]f32
  for i in 0 ..< 4 {
    ndc := [2]f32{f32(i & 1) * 2 - 1, f32(i >> 1) * 2 - 1}
    a := camera.inv_view_projection * [4]f32{ndc.x, ndc.y, 0, 1}
    b := camera.inv_view_projection * [4]f32{ndc.x, ndc.y, 1, 1}
    // view depth is linear along the corner ray, for both projections
    a_world, b_world := a.xyz / a.w, b.xyz / b.w
    corners[i] = linalg.lerp(a_world, b_world, from)
    corners[i + 4] = linalg.lerp(a_world, b_world, to)
    center += corners[i] + corners[i + 4]
  }
  center /= 8
  r: f32
  for c in corners do r = max(r, linalg.distance(c, center))
  // rounded up, so float noise can't change the texel size
  r = math.ceil(r * 16) / 16
  texel := 2 * r / SHADOW_MAP_SIZE
  rotation := light_look({}, direction)
  c := (rotation * [4]f32{center.x, center.y, center.z, 1}).xyz
  c.xy = linalg.floor(c.xy / texel) * texel
  // the eye sits r towards the light from the center, the box 2r deep
  view = linalg.matrix4_translate([3]f32{-c.x, -c.y, -(c.z + r)}) * rotation
  return view, geometry.make_ortho_matrix(-r, r, -r, r, 0, 2 * r)
}

// The picked placements get consecutive shadow views in table order from first_layer on (view i
// renders atlas layer i), the rest none. Returns the layer after the last.
@(private)
assign_shadow_views :: proc(placements: []LightPlacement, lights: []Light, picked: []bool, first_layer: u32 = 0) -> (layers: u32) {
  layers = first_layer
  for &p, i in placements {
    p.shadow_map = 0
    if !picked[i] do continue
    p.shadow_map = SHADOW_VIEW_BASE + layers
    layers += SHADOW_FACE_COUNT[lights[p.light].type]
  }
  return
}

// Picks this frame's shadow casters among the visible placed lights and writes their shadow
// views, after the sun's cascades. The sun casts shadows only with a main camera to fit to.
// Caller holds the render mutex.
@(private)
collect_lights :: proc(self: ^Renderer, frame_index: u32) {
  views := write_table(self, .VIEWS, View)
  cameras := views[CAMERA_VIEW_BASE:][:self.slots[.CAMERAS].high_water]
  casters: [MAX_LIGHTS]Caster
  caster_count := 0
  _, has_eye := main_camera(self)
  eye := &views[CAMERA_VIEW_BASE + u32(self.main_camera)]
  nodes := write_table(self, .NODES, Node)
  lights := write_table(self, .LIGHTS, Light)
  placements := write_table(self, .LIGHT_PLACEMENTS, LightPlacement)[:self.slots[.LIGHT_PLACEMENTS].high_water]
  for p, i in placements {
    if p.light == 0 do continue
    light := lights[p.light]
    if !light.cast_shadow || .VISIBLE not_in nodes[p.node].flags do continue
    // a spot light reuses the point light's sphere: loose but simple
    position, _ := light_pose(nodes[p.node].world_matrix)
    bounds := [4]f32{position.x, position.y, position.z, light.radius}
    // -1: no camera sees the light
    score: f32 = -1
    for &v in cameras {
      if v.type_mask == 0 do continue
      if !geometry.frustum_test_sphere({v.planes}, bounds.xyz, bounds.w) do continue
      score = max(score, shadow_score(bounds, light.intensity, v.position.xyz))
    }
    if score < 0 do continue
    casters[caster_count] = {owner = u32(i) + 1, score = score}
    caster_count += 1
  }
  slice.sort_by(casters[:caster_count], proc(a, b: Caster) -> bool {return a.score > b.score})
  sun_layers: u32 = SHADOW_CASCADES if sun_casts_shadow(self.sun) && has_eye else 0
  self.sun_shadow_map = SHADOW_VIEW_BASE if sun_layers > 0 else 0
  maps := &self.shadow_casters
  selected := select_shadow_casters(casters[:caster_count], maps, dev.frame_serial(&self.gpu))
  picked: [MAX_LIGHTS]bool
  for c in maps[:selected] do picked[c.owner - 1] = true
  self.shadow_view_count = assign_shadow_views(placements, lights, picked[:len(placements)], sun_layers)
  mark_dirty(self, .LIGHT_PLACEMENTS, 0, len(placements))
  mark_dirty(self, .VIEWS, SHADOW_VIEW_BASE, int(self.shadow_view_count))
  shadow_view :: proc(self: ^Renderer, views: []View, v: u32, view, projection: matrix[4, 4]f32, sun: bool, frame_index: u32) {
    view_projection := projection * view
    planes := geometry.make_frustum(view_projection).planes
    // casters between the sun and its cascade's box still shadow it (the shadow pipeline
    // clamps their depth)
    if sun do planes[4] = {0, 0, 0, 1}
    views[v] = {
      view            = view,
      projection      = projection,
      view_projection = view_projection,
      planes          = planes,
      type_mask       = GBUFFER_TYPES,
      require_flags   = SHADOW_CASTER_FLAGS,
      instance_tag    = v << 16,
      layer           = v - SHADOW_VIEW_BASE,
      draw_list       = SHADOW_DRAW_SLOT_BASE + frame_index,
      list_capacity   = SHADOW_LIST_CAPACITY,
      time            = self.time,
    }
  }
  if sun_layers > 0 {
    direction := sun_direction(self.sun)
    for f in 0 ..< int(sun_layers) {
      view, projection := cascade_matrices(self.sun.shadow_distance, direction, f, eye)
      shadow_view(self, views, self.sun_shadow_map + u32(f), view, projection, true, frame_index)
    }
  }
  for p in placements {
    if p.shadow_map == 0 do continue
    light := lights[p.light]
    position, direction := light_pose(nodes[p.node].world_matrix)
    for f in 0 ..< SHADOW_FACE_COUNT[light.type] {
      view, projection := shadow_face_matrices(light, position, direction, int(f))
      shadow_view(self, views, p.shadow_map + f, view, projection, false, frame_index)
    }
  }
}

// The sun's normalized direction of travel; straight down when it is zero.
@(private)
sun_direction :: proc(sun: Sun) -> [3]f32 {
  d := sun.direction
  return linalg.normalize(d) if linalg.dot(d, d) > 1e-12 else {0, -1, 0}
}

// The sun's radiance (color * intensity, 0 when off) and the direction towards it.
@(private)
sun_light :: proc(sun: Sun) -> (radiance, toward: [4]f32) {
  if !sun.enabled || sun.intensity <= 0 do return
  radiance.rgb = sun.color * sun.intensity
  toward.xyz = -sun_direction(sun)
  return
}

@(private)
sun_casts_shadow :: proc(sun: Sun) -> bool {
  return sun.enabled && sun.cast_shadow && sun.intensity > 0
}

// Frees the rows of the bursts the last frame emitted and gives the queued ones a row each.
@(private = "file")
place_bursts :: proc(self: ^Renderer) {
  kept := 0
  for b in self.bursts {
    if b.row != 0 {
      containers.slots_free(&self.slots[.EMITTER_PLACEMENTS], b.row)
      clear_entry(self, .EMITTER_PLACEMENTS, b.row)
      continue
    }
    row, ok := containers.slots_alloc(&self.slots[.EMITTER_PLACEMENTS])
    if !ok {
      log.warnf("No room for more than %d placed emitters; the burst is dropped", MAX_EMITTERS - 1)
      continue
    }
    write_table(self, .EMITTER_PLACEMENTS, EmitterPlacement)[row] = {emitter = b.emitter, node = b.slot, burst = b.count}
    mark_dirty(self, .EMITTER_PLACEMENTS, int(row))
    self.bursts[kept] = b
    self.bursts[kept].row = row
    kept += 1
  }
  resize(&self.bursts, kept)
}

// Emitter placements take consecutive ranges of the frame's new particles, which take
// consecutive ring slots after the previous frame's. A placement emits what
// floor(rate * particle_time) grew by, so it carries no fraction from frame to frame.
@(private = "file")
flush_particles :: proc(self: ^Renderer) {
  place_bursts(self)
  emitters := write_table(self, .EMITTERS, Emitter)
  placements := write_table(self, .EMITTER_PLACEMENTS, EmitterPlacement)[:self.slots[.EMITTER_PLACEMENTS].high_water]
  p := &self.particle_params
  p.emit_cursor = (p.emit_cursor + p.emit_total) % MAX_PARTICLES
  t0 := self.particle_time
  t1 := t0 + f64(p.delta_time)
  self.particle_time = t1
  total: u32
  for &pl in placements {
    // a free row reads emitter 0, whose rate is 0
    rate := f64(max(emitters[pl.emitter].emission_rate, 0))
    emit := pl.burst if pl.burst != 0 else u32(u64(rate * t1) - u64(rate * t0))
    pl.emit_first = total
    total += emit
  }
  mark_dirty(self, .EMITTER_PLACEMENTS, 0, len(placements))
  // a ring slot takes at most one new particle per frame
  p.emit_total = min(total, MAX_PARTICLES)
  p.emitter_placement_count = u32(len(placements))
  p.force_field_placement_count = self.slots[.FORCE_FIELD_PLACEMENTS].high_water
  p.frame_counter += 1
}

// Writes the camera views, in slot order.
@(private = "file")
flush_cameras :: proc(self: ^Renderer, frame_index: u32) {
  views := write_table(self, .VIEWS, View)
  // a slot without a camera keeps an empty view that draws no type
  slot_count := self.slots[.CAMERAS].high_water
  slice.zero(views[CAMERA_VIEW_BASE:][:slot_count])
  mark_dirty(self, .VIEWS, CAMERA_VIEW_BASE, int(slot_count))
  all_types := u32(1 << len(MaterialType) - 1)
  c: u32
  for i in containers.slots_next(&self.slots[.CAMERAS], &c) {
    cam, targets := &self.cameras[i], &self.camera_targets[i]
    view := camera_view_matrix(cam)
    projection := camera_projection_matrix(cam, targets.extent)
    view_projection := projection * view
    v := &views[CAMERA_VIEW_BASE + i]
    v^ = {
      view                = view,
      projection          = projection,
      view_projection     = view_projection,
      inv_view_projection = linalg.inverse(view_projection),
      planes              = geometry.make_frustum(view_projection).planes,
      position            = {cam.position.x, cam.position.y, cam.position.z, 1},
      extent              = {f32(targets.extent[0]), f32(targets.extent[1])},
      near                = cam.near,
      far                 = cam.far,
      pyramid             = u32(targets.pyramid[frame_index]),
      occlusion_mask      = GBUFFER_TYPES if camera_ready(self, i) else 0,
      list_stride         = 1,
      type_mask           = all_types,
      require_flags       = {.VISIBLE},
      // frame N builds pyramid N from N-1's depth and culls into N+1's lists
      draw_list           = camera_next_slot(i, frame_index),
      list_capacity       = CAMERA_LIST_CAPACITY,
      time                = self.time,
    }
    v.sun_radiance, v.sun_direction = sun_light(self.sun)
    for a in CameraImage do v.images[a] = u32(targets.images[a][frame_index])
  }
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
  overlay_flush(self)
}

// frame renders and presents one frame at the window's framebuffer size in pixels and its DPI
// scale (pixels per window unit), as the window reports them: an out-of-date swapchain is
// rebuilt to the size. It returns false on a GPU error. Main thread.
frame :: proc(self: ^Renderer, framebuffer_size: [2]u32, dpi_scale: f32) -> bool {
  frame_index := current_frame(self)
  guard(self)
  self.dpi_scale = dpi_scale if dpi_scale > 0 else 1
  tick_resource_pools(self)
  flush(self, frame_index)
  submitted, status := frame_run(self, framebuffer_size)
  // drawn again each frame until a stage_overlay replaces it
  self.ui_stale = true
  if submitted {
    gpu_frame_done(self)
    // simulated: the next frame's time accumulates from zero
    self.particle_params.delta_time = 0
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
  post_shader_destroy,
  buffer_destroy,
  compute_shader_destroy,
  draw_shader_destroy,
  model_looks_destroy,
}

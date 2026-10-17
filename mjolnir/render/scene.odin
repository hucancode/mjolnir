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

// Renderer is the whole renderer; its fields are the settings an application edits.
// init/shutdown own the GPU backend and what init makes (builtin meshes and
// materials, the main camera): application lifetime. Everything made after the last setup
// (or init) lives for the map: teardown frees it in one go.
Renderer :: struct {
  skybox_intensity:       f32,
  skybox_blur:            f32,
  // scales image-based lighting
  ibl_intensity:          f32,
  builtin_materials:      [Color]MaterialHandle,
  builtin_meshes:         [Primitive]MeshHandle,
  // every camera runs the stack in order
  effect_stack:           [dynamic]PostprocessEffect,
  using _:               Renderer_State,
}

@(private)
Renderer_State :: struct {
  // presented to the swapchain (main_camera)
  main_camera:            CameraHandle,
  gpu:                    Backend,
  // render's tables, the one copy; bit r of dirty[t] is region r of tables[t] (TABLE_REGIONS),
  // written since the last submitted frame. tables_sync brings the GPU copies up to date.
  tables:                 [Table][]u8,
  dirty:                  [Table]u64,
  // cull dispatches cover the slots below this
  node_count:             u32,
  // the skinning dispatch covers skinned vertices below this
  skinned_vertex_count:   u32,
  shadow_view_count:      u32,
  environment_map:        TextureHandle,
  brdf_lut:               TextureHandle,
  irradiance_cube:        TextureHandle,
  prefilter_cube:         TextureHandle,
  particle_params:        ParticleSystemParams,
  mesh_slots:             containers.Slots,
  material_slots:         containers.Slots,
  // lights, emitters and force fields: their tables' rows
  light_slots:            containers.Slots,
  emitter_slots:          containers.Slots,
  force_field_slots:       containers.Slots,
  // where they are attached: the rows of the *_PLACEMENTS tables
  light_placement_slots:      containers.Slots,
  emitter_placement_slots:    containers.Slots,
  force_field_placement_slots: containers.Slots,
  cameras:                []Camera,
  camera_targets:         []CameraTargets,
  camera_slots:           containers.Slots,
  // pass i writes slot i % POST_PROCESS_RING; its input and original are the two slots before
  post_process_ring:      [FRAMES_IN_FLIGHT][POST_PROCESS_RING]TextureHandle,
  // render targets below MAX_RENDER_TARGETS, every other texture above (bindless_textures.odin)
  target_slots:           containers.Slots,
  texture_slots:          containers.Slots,
  mesh_slabs:             [MeshStream]containers.SlabAllocator,
  bone_matrix_slab:       containers.SlabAllocator,
  // the skinned vertex ranges of skinned slots (pass_skin.odin)
  skin_slab:              containers.SlabAllocator,
  // simulated seconds; an emitter emits floor(rate * time) particles in total
  particle_time:          f64,
  // segments added since the last frame, per ring: [0] depth-tested, [1] drawn over the scene
  debug_lines:            [2][dynamic]DebugLineSegment,
  // segments each ring has taken in total (debug_line.odin)
  debug_filled:           [2]u64,
  // seconds render.update has advanced; shaders read it as View.time and PostPush.time
  time:                   f32,
  debug_mutex:            sync.Mutex,
  shadow_casters:         [MAX_SHADOW_MAPS]Caster,
  // per pyramid slot: the depth pyramid camera_slot(c) + frame of camera c
  pyramids:               [MAX_PYRAMID_SLOTS]TextureHandle,
  // the last compute submission, which the next frame's graphics waits for
  last_compute:           rhi.SyncPoint,
  // the buffers render owns on the device (resources.odin): a copy per frame in flight of
  // each table, one of the rest
  buffers:                [SceneBuffer][FRAMES_IN_FLIGHT]rhi.Buffer,
  // per table and frame in flight: the regions render wrote that the copy lacks
  table_stale:            [Table][FRAMES_IN_FLIGHT]u64,
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
  // the slot's storage views are in the bindless array
  pyramid_bound:          [MAX_PYRAMID_SLOTS]bool,
  pyramid_counters:       rhi.Buffer,
  // the main camera's visible opaque draws, copied out per frame in flight
  draw_count_readback:    [FRAMES_IN_FLIGHT]rhi.Buffer,
  // draws are batched per mesh and material where they are not compacted (batches.odin):
  // (material, mesh) -> batch id, the nodes in each batch, the freed ids, the ids below
  // batch_high in use or free, and whether first_instance and capacity are stale
  batch_ids:              map[u64]u32,
  batch_members:          [MAX_BATCHES]u32,
  batch_free:             [dynamic]u32,
  batch_high:             u32,
  batch_stale:            bool,
  batch_warned:           bool,
  // each pass's pipelines
  shadow_pipeline:        rhi.Pipeline,
  material_pipelines:     [MaterialPass][len(MaterialType)]rhi.Pipeline,
  lighting_pipeline:      rhi.Pipeline,
  // WebGPU: group 3 of the lighting dispatch, the image it writes, a group per image
  lighting_output_layout: rhi.BindLayout,
  lighting_output_groups: map[TextureHandle]rhi.BindGroup,
  // [is_last][tag]: every pass writes an HDR ring image but the last, which writes the backbuffer
  post_pipelines:         [2][POST_EFFECT_COUNT]rhi.Pipeline,
  // [PostShader - 1][is_last]; a destroyed shader's slot is zero until reused
  custom_post_pipelines:  [dynamic][2]rhi.Pipeline,
  // [MaterialShader - 1], 0 where free
  custom_material_pipelines: [MAX_MATERIAL_SHADERS]rhi.Pipeline,
  particle_emit_pipeline: rhi.Pipeline,
  particle_sim_pipeline:  rhi.Pipeline,
  particle_draw_pipeline: rhi.Pipeline,
  skin_pipeline:          rhi.Pipeline,
  // by ring
  debug_line_pipelines:   [2]rhi.Pipeline,
  overlay_pipeline:       rhi.Pipeline,
  // the 2D overlay (overlay_renderer.odin): UI_MAX_VERTICES and UI_MAX_INDICES, the first
  // ui_vertex_count and ui_index_count this frame's, in batches of one scissor and texture
  ui_vertices:            []Vertex2D,
  ui_indices:             []u32,
  ui_vertex_count:        u32,
  ui_index_count:         u32,
  ui_batches:             [dynamic]UIBatch,
  // sampled by text commands
  ui_font_atlas:          TextureHandle,
  ui_font_atlas_size:     [2]f32,
  dpi_scale:              f32,
  mutex:                  sync.Recursive_Mutex,
  // ready ran init_resources
  initialized:            bool,
}

// init brings the renderer up on a window: the GPU backend, every resource and an empty scene
// with a main camera. Paired with shutdown. A backend whose device arrives asynchronously
// (wgpu on the web) finishes in ready: until it returns true, nothing but ready may be called.
init :: proc(
  self: ^Renderer,
  app_name: string,
  window: WindowHandle,
  framebuffer_size: [2]u32,
  dpi_scale: f32,
) -> bool {
  for stream, s in MESH_STREAMS do containers.slab_init(&self.mesh_slabs[s], stream.slab)
  dev.init(&self.gpu, app_name, window, framebuffer_size) or_return
  for t, i in TABLES do self.tables[i] = make([]u8, t.stride * t.capacity)
  self.dpi_scale = dpi_scale
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
  containers.slots_init(&self.camera_slots, MAX_ACTIVE_CAMERAS, RETIRE_GRACE)
  containers.slots_init(&self.mesh_slots, MAX_MESHES, RETIRE_GRACE)
  containers.slots_init(&self.material_slots, MAX_MATERIALS, RETIRE_GRACE)
  // retired, not reclaimed: submitted frames may still sample the slot
  containers.slots_init(&self.target_slots, MAX_RENDER_TARGETS, RETIRE_GRACE)
  containers.slots_init(&self.texture_slots, MAX_TEXTURES, RETIRE_GRACE, first = MAX_RENDER_TARGETS)
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
  overlay_init_pass(self) or_return
  for frame in 0 ..< u32(FRAMES_IN_FLIGHT) {
    lists, capacity := draw_list_shape(self, shadow = true)
    draw_list_create(self, SHADOW_DRAW_SLOT_BASE + frame, lists, capacity) or_return
  }
  containers.slots_init(&self.light_slots, MAX_LIGHTS, RETIRE_GRACE)
  containers.slots_init(&self.emitter_slots, MAX_EMITTERS, RETIRE_GRACE)
  containers.slots_init(&self.force_field_slots, MAX_FORCE_FIELDS, RETIRE_GRACE)
  // placements have no handle to go stale and each frame reads its own copy of the
  // table, so no grace
  containers.slots_init(&self.light_placement_slots, MAX_LIGHTS)
  containers.slots_init(&self.emitter_placement_slots, MAX_EMITTERS)
  containers.slots_init(&self.force_field_placement_slots, MAX_FORCE_FIELDS)
  containers.slab_init(&self.bone_matrix_slab, BONE_SLAB_CONFIG)
  containers.slab_init(&self.skin_slab, SKIN_SLAB_CONFIG)
  self.cameras = make([]Camera, MAX_ACTIVE_CAMERAS)
  self.camera_targets = make([]CameraTargets, MAX_ACTIVE_CAMERAS)
  init_builtin_materials(self)
  init_builtin_meshes(self)
  ambient_init(self) or_return
  self.effect_stack = make([dynamic]PostprocessEffect)
  post_process_create_images(self) or_return
  for &inbox in self.debug_lines do inbox = make([dynamic]DebugLineSegment, 0, 1024)
  overlay_init(self) or_return
  extent := dev.extent(&self.gpu)
  cam, created := camera_create(self, extent.x, extent.y, position = {3, 4, 3}, far_plane = 1000.0)
  if !created do return false
  self.main_camera = cam
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
  containers.slots_mark(&self.mesh_slots)
  for &slab in self.mesh_slabs do containers.slab_mark(&slab)
  containers.slots_mark(&self.material_slots)
  containers.slots_mark(&self.light_slots)
  containers.slots_mark(&self.emitter_slots)
  containers.slots_mark(&self.force_field_slots)
  containers.slots_mark(&self.texture_slots)
  containers.slots_mark(&self.camera_slots)
}

// teardown ends a map in one go, waiting for the GPU: no particle stays alive, every slot
// forgets its attachment and bone palette, and every camera, mesh, material, light, emitter, force field and
// texture made since the last setup
// (or init) is freed, the environment map too if it is one of them. What came before stays:
// what init made (builtin meshes and materials, the main camera, render targets, pipelines)
// and what the application made before setup. Handles to freed resources are stale.
teardown :: proc(self: ^Renderer) {
  guard(self)
  // their render targets and draw lists retire, and go with the flushes below
  c := self.camera_slots.mark
  for i in containers.slots_next(&self.camera_slots, &c) do camera_destroy(self, CameraHandle(i))
  // queued uploads may be init's: they land before anything is freed
  dev.wait_idle(&self.gpu)
  for r in containers.slots_flush(&self.target_slots) do dev.texture_destroy(&self.gpu, TextureHandle(r.index))
  for i in self.texture_slots.mark ..< self.texture_slots.high_water do dev.texture_destroy(&self.gpu, TextureHandle(i))
  groups_clear(self)
  containers.slots_rewind(&self.texture_slots)
  if u32(self.environment_map) >= self.texture_slots.mark {
    self.environment_map, self.irradiance_cube, self.prefilter_cube = 0, 0, 0
  }
  containers.slots_rewind(&self.camera_slots)
  clear_entry(self, .MESHES, self.mesh_slots.mark, self.mesh_slots.high_water - self.mesh_slots.mark)
  containers.slots_rewind(&self.mesh_slots)
  for &slab in self.mesh_slabs do containers.slab_rewind(&slab)
  clear_entry(self, .MATERIALS, self.material_slots.mark, self.material_slots.high_water - self.material_slots.mark)
  containers.slots_rewind(&self.material_slots)
  slice.zero(write_table(self, .NODES, Node)[:self.node_count])
  mark_dirty(self, .NODES, 0, int(self.node_count))
  self.node_count = 0
  when !BINDLESS do batches_reset(self)
  containers.slab_rewind(&self.bone_matrix_slab)
  containers.slab_rewind(&self.skin_slab)
  clear_entry(self, .SKIN_OWNERS, 0, self.skinned_vertex_count)
  self.skinned_vertex_count = 0
  rewind :: proc(self: ^Renderer, slots: ^containers.Slots, table: Table) {
    clear_entry(self, table, slots.mark, slots.high_water - slots.mark)
    containers.slots_rewind(slots)
  }
  rewind(self, &self.light_slots, .LIGHTS)
  rewind(self, &self.emitter_slots, .EMITTERS)
  rewind(self, &self.force_field_slots, .FORCE_FIELDS)
  rewind(self, &self.light_placement_slots, .LIGHT_PLACEMENTS)
  rewind(self, &self.emitter_placement_slots, .EMITTER_PLACEMENTS)
  rewind(self, &self.force_field_placement_slots, .FORCE_FIELD_PLACEMENTS)
  self.shadow_casters = {}
  if !particles_reset(self) do log.error("teardown: cannot clear the particles")
}

// environment_map_load replaces the environment map with the equirectangular HDR image encoded
// in `data` and precomputes image-based lighting from it. Without one, IBL and the skybox are black.
environment_map_load :: proc(self: ^Renderer, data: []u8) -> bool {
  ok := ambient_load_environment(self, data)
  if !ok do log.warnf("Failed to load environment map")
  return ok
}

// shutdown destroys everything, whatever map is up.
shutdown :: proc(self: ^Renderer) {
  delete(self.cull_groups)
  delete(self.reduce_groups)
  delete(self.lighting_output_groups)
  delete(self.texture_groups)
  dev.shutdown(&self.gpu)
  for table in self.tables do delete(table)
  delete(self.batch_ids)
  delete(self.batch_free)
  delete(self.ui_batches)
  delete(self.ui_vertices)
  delete(self.ui_indices)
  delete(self.effect_stack)
  delete(self.custom_post_pipelines)
  for inbox in self.debug_lines do delete(inbox)
  for &slab in self.mesh_slabs do containers.slab_destroy(&slab)
  containers.slab_destroy(&self.bone_matrix_slab)
  containers.slab_destroy(&self.skin_slab)
  containers.slots_destroy(&self.camera_slots)
  containers.slots_destroy(&self.mesh_slots)
  containers.slots_destroy(&self.material_slots)
  containers.slots_destroy(&self.light_slots)
  containers.slots_destroy(&self.emitter_slots)
  containers.slots_destroy(&self.force_field_slots)
  containers.slots_destroy(&self.light_placement_slots)
  containers.slots_destroy(&self.emitter_placement_slots)
  containers.slots_destroy(&self.force_field_placement_slots)
  containers.slots_destroy(&self.texture_slots)
  containers.slots_destroy(&self.target_slots)
  delete(self.cameras)
  delete(self.camera_targets)
}

// Cameras that matched the old extent follow the new one.
@(private)
recreate_swapchain :: proc(self: ^Renderer, framebuffer_size: [2]u32, dpi_scale: f32) -> bool {
  old := dev.extent(&self.gpu)
  dev.resize(&self.gpu, framebuffer_size) or_return
  extent := dev.extent(&self.gpu)
  c: u32
  for i in containers.slots_next(&self.camera_slots, &c) {
    if self.camera_targets[i].extent != old do continue
    camera_resize(self, CameraHandle(i), extent.x, extent.y) or_return
  }
  post_process_release_images(self)
  post_process_create_images(self) or_return
  self.dpi_scale = dpi_scale
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

// lock holds off frame while another thread edits through the pointers material, light,
// emitter and force_field return; stage_*, *_create and *_destroy lock themselves.
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
  for r in containers.slots_tick(&self.target_slots) {
    dev.texture_destroy(&self.gpu, TextureHandle(r.index))
    destroyed = true
  }
  for r in containers.slots_tick(&self.texture_slots) {
    dev.texture_destroy(&self.gpu, TextureHandle(r.index))
    destroyed = true
  }
  if destroyed do groups_clear(self)
  for r in containers.slots_tick(&self.mesh_slots) {
    free_mesh(self, write_table(self, .MESHES, MeshData)[r.index])
    clear_entry(self, .MESHES, r.index)
  }
  containers.slots_tick(&self.material_slots)
  containers.slots_tick(&self.camera_slots)
}

// Advance the render clock (shaders' time, debug line lifetimes) and the particle
// simulation time. Call once per update tick; the next frame emits and
// simulates everything accumulated since the previous one.
update :: proc(self: ^Renderer, delta_time: f32) {
  sync.mutex_lock(&self.debug_mutex)
  self.time += delta_time
  sync.mutex_unlock(&self.debug_mutex)
  if delta_time <= 0 do return
  guard(self)
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
}

@(private)
NodeFlagSet :: bit_set[NodeFlag;u32]

// the shadow pass draws these; the material type must also be in GBUFFER_TYPES
@(private)
SHADOW_CASTER_FLAGS :: NodeFlagSet{.VISIBLE, .CASTS_SHADOW}

// The zero record is an empty slot: mesh and material 0 are none. When .SKINNED is set,
// attachment_data_index is the first entry of the slot's bone table range and
// skin_vertex_base the first of its skinned vertices (pass_skin.odin).
@(private)
Node :: struct #packed {
  world_matrix:          matrix[4, 4]f32,
  material_id:           u32,
  mesh_id:               u32,
  attachment_data_index: u32,
  flags:                 NodeFlagSet,
  skin_vertex_base:      u32,
  _:                     [3]u32,
}
#assert(size_of(Node) == 96)

// MeshAttachment draws mesh with material from a slot's transform.
MeshAttachment :: struct {
  mesh:        MeshHandle,
  material:    MaterialHandle,
  cast_shadow: bool,
}

// SlotHandle is a scene slot: a world node's index (NodeHandle.index), whose transform
// stage_transforms feeds.
SlotHandle :: distinct u32

// What a slot draws: a mesh, or a light, emitter or force field (*_create) placed at the
// slot's transform. One light, emitter or force field may be attached at many slots.
Attachment :: union {
  MeshAttachment,
  LightHandle,
  EmitterHandle,
  ForceFieldHandle,
}

// Grows the slot range to cover `slot`; slots past it are already empty (zero). Caller
// holds the render mutex and marks what it changes.
@(private)
slot_node :: proc(self: ^Renderer, slot: u32) -> ^Node {
  assert(slot < MAX_SLOTS, "slot exceeds MAX_SLOTS")
  self.node_count = max(self.node_count, slot + 1)
  return &write_table(self, .NODES, Node)[slot]
}

// stage_transforms applies a change feed: sets each slot's world matrix and visibility,
// and forgets slots marked removed. `changes` is any struct with `index`, `world_matrix`,
// `visible` and `removed` fields (world.NodeChange), removals first.
stage_transforms :: proc(self: ^Renderer, changes: []$T) {
  guard(self)
  for &c in changes {
    if c.removed {
      stage_slot_removal(self, c.index)
      continue
    }
    node := slot_node(self, c.index)
    node.world_matrix = c.world_matrix
    if c.visible do node.flags += {.VISIBLE}
    else do node.flags -= {.VISIBLE}
    mark_dirty(self, .NODES, int(c.index))
  }
}

// A placement table holds at most one row per slot. The live row of `table` placed at `slot`.
@(private = "file")
placed_at :: proc(self: ^Renderer, slots: ^containers.Slots, table: Table, $T: typeid, slot: u32) -> (index: u32, ok: bool) {
  rows := write_table(self, table, T)
  c: u32
  for i in containers.slots_next(slots, &c) do if rows[i].node == slot do return i, true
  return
}

// Takes a placement row of `table` for `row`.
@(private = "file")
place :: proc(self: ^Renderer, slots: ^containers.Slots, table: Table, row: $T) -> bool {
  i := containers.slots_alloc(slots) or_return
  write_table(self, table, T)[i] = row
  mark_dirty(self, table, int(i))
  return true
}

// Frees the slot's placement row of `table`, if any.
@(private = "file")
unplace :: proc(self: ^Renderer, slots: ^containers.Slots, table: Table, $T: typeid, slot: u32) {
  i := placed_at(self, slots, table, T, slot) or_else 0
  if i == 0 do return
  containers.slots_free(slots, i)
  clear_entry(self, table, i)
}

// Drops the slot's light, emitter and force field. Caller holds the render mutex.
@(private = "file")
unbind :: proc(self: ^Renderer, slot: u32) {
  unplace(self, &self.light_placement_slots, .LIGHT_PLACEMENTS, LightPlacement, slot)
  unplace(self, &self.emitter_placement_slots, .EMITTER_PLACEMENTS, EmitterPlacement, slot)
  unplace(self, &self.force_field_placement_slots, .FORCE_FIELD_PLACEMENTS, ForceFieldPlacement, slot)
}

// Stores `value` in a free row of `table`; the row is the resource's handle.
@(private)
resource_create :: proc(self: ^Renderer, slots: ^containers.Slots, table: Table, value: $T) -> (index: u32, ok: bool) {
  guard(self)
  index = containers.slots_alloc(slots) or_return
  write_table(self, table, T)[index] = value
  mark_dirty(self, table, int(index))
  return index, true
}

// The row of a live handle, to edit in place: valid until the next frame, as render.material's.
@(private)
resource :: proc(self: ^Renderer, slots: ^containers.Slots, table: Table, $T: typeid, index: u32) -> (^T, bool) {
  if !containers.slots_live(slots, index) do return nil, false
  mark_dirty(self, table, int(index))
  return &write_table(self, table, T)[index], true
}

// Frees a row; what still refers to it reads zeros.
@(private)
resource_destroy :: proc(self: ^Renderer, slots: ^containers.Slots, table: Table, index: u32) {
  guard(self)
  if !containers.slots_free(slots, index) do return
  clear_entry(self, table, index)
}

// Forget everything drawn at a slot; meshes and materials are shared and stay.
@(private)
stage_slot_removal :: proc(self: ^Renderer, slot: u32) {
  guard(self)
  unbind(self, slot)
  if slot >= self.node_count do return
  release_bones(self, slot)
  batch_leave(self, slot)
  write_table(self, .NODES, Node)[slot] = {}
  mark_dirty(self, .NODES, int(slot))
}

// whether mesh_id carries skinning data, so a bone palette may deform it
@(private = "file")
skinned_mesh :: proc(self: ^Renderer, mesh_id: u32) -> bool {
  return .SKINNED in write_table(self, .MESHES, MeshData)[mesh_id].flags
}

// Gives the skinned vertices of the range at `base` to `owner` (slot + 1, 0 for none), for
// the skinning pass. The whole block: the pass skips vertices past the owner's mesh.
@(private = "file")
skin_own :: proc(self: ^Renderer, base, owner: u32) {
  size := containers.slab_block_size(&self.skin_slab, base)
  slice.fill(write_table(self, .SKIN_OWNERS, u32)[base:][:size], owner)
  mark_dirty(self, .SKIN_OWNERS, int(base), int(size))
  self.skinned_vertex_count = max(self.skinned_vertex_count, base + size)
}

// Drops the slot's bone palette and skinned vertices. Caller holds the render mutex.
@(private = "file")
release_bones :: proc(self: ^Renderer, slot: u32) {
  node := &write_table(self, .NODES, Node)[slot]
  if .SKINNED not_in node.flags do return
  containers.slab_free(&self.bone_matrix_slab, node.attachment_data_index)
  skin_own(self, node.skin_vertex_base, 0)
  containers.slab_free(&self.skin_slab, node.skin_vertex_base)
  node.attachment_data_index, node.skin_vertex_base = 0, 0
  node.flags -= {.SKINNED}
  mark_dirty(self, .NODES, int(slot))
}

// whether the slot's skinned vertex range holds mesh_id's vertices
@(private = "file")
skin_fits :: proc(self: ^Renderer, node: Node, mesh_id: u32) -> bool {
  vertex_count := write_table(self, .MESHES, MeshData)[mesh_id].vertex_count
  return containers.slab_block_size(&self.skin_slab, node.skin_vertex_base) >= vertex_count
}

// stage_bones sets the skin palette (bone skinning matrices, animation.Animator.palette) of
// the skinned mesh attached at `slot`. The matrices are copied.
stage_bones :: proc(self: ^Renderer, slot: SlotHandle, matrices: []matrix[4, 4]f32) {
  slot := u32(slot)
  count := u32(len(matrices))
  if count == 0 do return
  guard(self)
  node := slot_node(self, slot)
  if !skinned_mesh(self, node.mesh_id) {
    log.warnf("Slot %d has no skinned mesh; its bone palette is dropped", slot)
    return
  }
  if .SKINNED not_in node.flags || containers.slab_block_size(&self.bone_matrix_slab, node.attachment_data_index) < count {
    release_bones(self, slot)
    offset, ok := containers.slab_alloc(&self.bone_matrix_slab, count)
    if !ok {
      log.warnf("No bone range for a %d-bone palette; the mesh draws unskinned", count)
      return
    }
    vertex_count := write_table(self, .MESHES, MeshData)[node.mesh_id].vertex_count
    base, skin_ok := containers.slab_alloc(&self.skin_slab, vertex_count)
    if !skin_ok {
      containers.slab_free(&self.bone_matrix_slab, offset)
      log.warnf("No skinned vertex range for %d vertices; the mesh draws unskinned", vertex_count)
      return
    }
    node.attachment_data_index, node.skin_vertex_base = offset, base
    node.flags += {.SKINNED}
    skin_own(self, base, slot + 1)
    mark_dirty(self, .NODES, int(slot))
  }
  offset := node.attachment_data_index
  copy(write_table(self, .BONES, matrix[4, 4]f32)[offset:][:count], matrices)
  mark_dirty(self, .BONES, int(offset), int(count))
}

// attach draws attachment at slot (a world node's index), replacing what the slot drew before. A bone palette
// stays while the slot draws a skinned mesh whose vertices fit the slot's skinned range.
attach :: proc(self: ^Renderer, slot: SlotHandle, attachment: Attachment) {
  slot := u32(slot)
  guard(self)
  node := slot_node(self, slot)
  unbind(self, slot)
  batch_leave(self, slot)
  node.mesh_id, node.material_id = 0, 0
  node.flags -= {.CASTS_SHADOW}
  switch a in attachment {
  case MeshAttachment:
    node.mesh_id, node.material_id = u32(a.mesh), u32(a.material)
    batch_join(self, slot, node.mesh_id, node.material_id)
    if a.cast_shadow do node.flags += {.CASTS_SHADOW}
  case LightHandle:
    if !place(self, &self.light_placement_slots, .LIGHT_PLACEMENTS, LightPlacement{light = a, node = slot}) {
      log.warnf("No room for more than %d placed lights; the light is dropped", MAX_LIGHTS - 1)
    }
  case EmitterHandle:
    if !place(self, &self.emitter_placement_slots, .EMITTER_PLACEMENTS, EmitterPlacement{emitter = a, node = slot}) {
      log.warnf("No room for more than %d placed emitters; the emitter is dropped", MAX_EMITTERS - 1)
    }
  case ForceFieldHandle:
    if !place(self, &self.force_field_placement_slots, .FORCE_FIELD_PLACEMENTS, ForceFieldPlacement{force_field = a, node = slot}) {
      log.warnf("No room for more than %d placed force fields; the force field is dropped", MAX_FORCE_FIELDS - 1)
    }
  }
  if !skinned_mesh(self, node.mesh_id) || !skin_fits(self, node^, node.mesh_id) do release_bones(self, slot)
  mark_dirty(self, .NODES, int(slot))
}

// attachment returns the attachment of type T at slot, e.g. attachment(r, slot, LightHandle).
// Edit a light, emitter or force field through its handle (light, emitter, force_field); a
// MeshAttachment is a copy to pass back to attach.
attachment :: proc(
  self: ^Renderer,
  slot: SlotHandle,
  $T: typeid,
) -> (
  att: T,
  ok: bool,
) #optional_ok {
  slot := u32(slot)
  guard(self)
  when T == MeshAttachment {
    if slot >= self.node_count do return
    node := write_table(self, .NODES, Node)[slot]
    if node.mesh_id == 0 do return
    return {MeshHandle(node.mesh_id), MaterialHandle(node.material_id), .CASTS_SHADOW in node.flags}, true
  } else when T == LightHandle {
    i := placed_at(self, &self.light_placement_slots, .LIGHT_PLACEMENTS, LightPlacement, slot) or_return
    return write_table(self, .LIGHT_PLACEMENTS, LightPlacement)[i].light, true
  } else when T == EmitterHandle {
    i := placed_at(self, &self.emitter_placement_slots, .EMITTER_PLACEMENTS, EmitterPlacement, slot) or_return
    return write_table(self, .EMITTER_PLACEMENTS, EmitterPlacement)[i].emitter, true
  } else when T == ForceFieldHandle {
    i := placed_at(self, &self.force_field_placement_slots, .FORCE_FIELD_PLACEMENTS, ForceFieldPlacement, slot) or_return
    return write_table(self, .FORCE_FIELD_PLACEMENTS, ForceFieldPlacement)[i].force_field, true
  }
  return
}

// SPOT_LIGHT_INNER_RATIO is the default ratio of a spot light's full-intensity cone to its falloff cone.
SPOT_LIGHT_INNER_RATIO :: f32(0.75)

// Light shines from every slot it is attached to, along the slot's forward axis
// (make_*_light fill one; light_create stores it). Point lights ignore the angles.
Light :: struct #align(16) {
  color:              [4]f32, // RGB + intensity
  // range of a point or spot light; shadow distance of a directional light from the main camera
  radius:             f32,
  angle_inner:        f32, // spot cone angles
  angle_outer:        f32,
  type:               LightType,
  // the light competes for a shadow map
  cast_shadow: b32,
}
#assert(size_of(Light) == 48)

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
  i := resource_create(self, &self.light_slots, .LIGHTS, l) or_return
  return LightHandle(i), true
}

// light returns the light of `handle`, to edit in place; every slot it is attached to follows.
light :: proc(self: ^Renderer, handle: LightHandle) -> (^Light, bool) #optional_ok {
  return resource(self, &self.light_slots, .LIGHTS, Light, u32(handle))
}

// light_destroy frees the light; slots it stays attached to shine nothing.
light_destroy :: proc(self: ^Renderer, handle: LightHandle) {
  resource_destroy(self, &self.light_slots, .LIGHTS, u32(handle))
}

// Where a light at a node's transform sits and shines: its translation and normalized forward
// (+Z) axis. The lighting shaders read a placed light the same way.
@(private)
light_pose :: proc(world_matrix: matrix[4, 4]f32) -> (position, direction: [3]f32) {
  forward := world_matrix[2].xyz
  return world_matrix[3].xyz, linalg.normalize(forward) if linalg.dot(forward, forward) > 1e-6 else {0, -1, 0}
}

// make_point_light returns an omnidirectional Light for light_create.
make_point_light :: proc(
  color: [4]f32 = {1, 1, 1, 1},
  radius: f32 = 10.0,
  cast_shadow: bool = true,
) -> Light {
  return {type = .POINT, color = color, radius = radius, cast_shadow = b32(cast_shadow)}
}

// make_directional_light returns a sun-like Light for light_create; shadow_radius is its shadow distance.
make_directional_light :: proc(
  color: [4]f32 = {1, 1, 1, 1},
  shadow_radius: f32 = 10.0,
  cast_shadow: bool = false,
) -> Light {
  return {type = .DIRECTIONAL, color = color, radius = shadow_radius, cast_shadow = b32(cast_shadow)}
}

// make_spot_light returns a cone Light of the given half angle for light_create.
make_spot_light :: proc(
  color: [4]f32 = {1, 1, 1, 1},
  radius: f32 = 10.0,
  angle: f32 = math.PI * 0.2,
  cast_shadow: bool = true,
) -> Light {
  return {
    type        = .SPOT,
    color       = color,
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
  .POINT       = len(CUBE_FACES),
  .SPOT        = 1,
  .DIRECTIONAL = SHADOW_CASCADES,
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
  light:       int, // light placement row
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
shadow_face_matrices :: proc(l: Light, position, direction: [3]f32, face: int, camera: ^View) -> (view, projection: matrix[4, 4]f32) {
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
  case .DIRECTIONAL:
    return cascade_matrices(l, direction, face, camera)
  }
  return
}

// Orthographic box around the bounding sphere of the cascade's camera-frustum slice: the
// sphere keeps the size fixed as the camera turns, texel snapping holds edges still as it moves.
@(private = "file")
cascade_matrices :: proc(l: Light, direction: [3]f32, cascade: int, camera: ^View) -> (view, projection: matrix[4, 4]f32) {
  near := camera.near
  far := max(min(directional_shadow_radius(l), camera.far), near + 0.01)
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

// How far in front of the main camera a directional light's shadow map reaches.
@(private = "file")
directional_shadow_radius :: proc(l: Light) -> f32 {
  return max(l.radius, 0.5)
}

// The picked placements get consecutive shadow views in table order (view i renders atlas
// layer i), the rest none.
@(private)
assign_shadow_views :: proc(placements: []LightPlacement, lights: []Light, picked: []bool) -> (layers: u32) {
  for &p, i in placements {
    p.shadow_map = 0
    if !picked[i] do continue
    p.shadow_map = SHADOW_VIEW_BASE + layers
    layers += SHADOW_FACE_COUNT[lights[p.light].type]
  }
  return
}

// Picks this frame's shadow casters among the visible placed lights and writes their shadow
// views. Directional lights cast shadows only with a main camera to fit to. Caller holds the
// render mutex.
@(private)
collect_lights :: proc(self: ^Renderer, frame_index: u32) {
  views := write_table(self, .VIEWS, View)
  cameras := views[CAMERA_VIEW_BASE:][:self.camera_slots.high_water]
  casters: [MAX_LIGHTS]Caster
  caster_count := 0
  _, has_eye := main_camera(self)
  eye := &views[CAMERA_VIEW_BASE + u32(self.main_camera)]
  nodes := write_table(self, .NODES, Node)
  lights := write_table(self, .LIGHTS, Light)
  placements := write_table(self, .LIGHT_PLACEMENTS, LightPlacement)[:self.light_placement_slots.high_water]
  for p, i in placements {
    if p.light == 0 do continue
    light := lights[p.light]
    if !light.cast_shadow || .VISIBLE not_in nodes[p.node].flags do continue
    if light.type == .DIRECTIONAL && !has_eye do continue
    // a spot light reuses the point light's sphere: loose but simple
    position, _ := light_pose(nodes[p.node].world_matrix)
    bounds := [4]f32{position.x, position.y, position.z, light.radius}
    if light.type == .DIRECTIONAL do bounds = {eye.position.x, eye.position.y, eye.position.z, directional_shadow_radius(light)}
    // -1: no camera sees the light
    score: f32 = -1
    for &v in cameras {
      if v.type_mask == 0 do continue
      if !geometry.frustum_test_sphere({v.planes}, bounds.xyz, bounds.w) do continue
      score = max(score, shadow_score(bounds, light.color.a, v.position.xyz))
    }
    if score < 0 do continue
    casters[caster_count] = {light = i, owner = u32(i) + 1, score = score}
    caster_count += 1
  }
  slice.sort_by(casters[:caster_count], proc(a, b: Caster) -> bool {return a.score > b.score})
  maps := &self.shadow_casters
  selected := select_shadow_casters(casters[:caster_count], maps, dev.frame_serial(&self.gpu))
  picked: [MAX_LIGHTS]bool
  for c in maps[:selected] do picked[c.light] = true
  self.shadow_view_count = assign_shadow_views(placements, lights, picked[:len(placements)])
  mark_dirty(self, .LIGHT_PLACEMENTS, 0, len(placements))
  mark_dirty(self, .VIEWS, SHADOW_VIEW_BASE, int(self.shadow_view_count))
  for p in placements {
    if p.shadow_map == 0 do continue
    light := lights[p.light]
    position, direction := light_pose(nodes[p.node].world_matrix)
    for f in 0 ..< SHADOW_FACE_COUNT[light.type] {
      v := p.shadow_map + f
      view, projection := shadow_face_matrices(light, position, direction, int(f), eye)
      view_projection := projection * view
      planes := geometry.make_frustum(view_projection).planes
      // casters between a directional light and its cascade's box still
      // shadow it (the shadow pipeline clamps their depth)
      if light.type == .DIRECTIONAL do planes[4] = {0, 0, 0, 1}
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
  }
}

// Emitter placements take consecutive ranges of the frame's new particles, which take
// consecutive ring slots after the previous frame's. A placement emits what
// floor(rate * particle_time) grew by, so it carries no fraction from frame to frame.
@(private = "file")
flush_particles :: proc(self: ^Renderer) {
  emitters := write_table(self, .EMITTERS, Emitter)
  placements := write_table(self, .EMITTER_PLACEMENTS, EmitterPlacement)[:self.emitter_placement_slots.high_water]
  p := &self.particle_params
  p.emit_cursor = (p.emit_cursor + p.emit_total) % MAX_PARTICLES
  t0 := self.particle_time
  t1 := t0 + f64(p.delta_time)
  self.particle_time = t1
  total: u32
  for &pl in placements {
    // a free row reads emitter 0, whose rate is 0
    rate := f64(max(emitters[pl.emitter].emission_rate, 0))
    emit := u32(u64(rate * t1) - u64(rate * t0))
    pl.emit_first = total
    total += emit
  }
  mark_dirty(self, .EMITTER_PLACEMENTS, 0, len(placements))
  // a ring slot takes at most one new particle per frame
  p.emit_total = min(total, MAX_PARTICLES)
  p.emitter_placement_count = u32(len(placements))
  p.force_field_placement_count = self.force_field_placement_slots.high_water
  p.frame_counter += 1
}

// Writes the camera views, in slot order.
@(private = "file")
flush_cameras :: proc(self: ^Renderer, frame_index: u32) {
  views := write_table(self, .VIEWS, View)
  // a slot without a camera keeps an empty view that draws no type
  slot_count := self.camera_slots.high_water
  slice.zero(views[CAMERA_VIEW_BASE:][:slot_count])
  mark_dirty(self, .VIEWS, CAMERA_VIEW_BASE, int(slot_count))
  all_types := u32(1 << len(MaterialType) - 1)
  c: u32
  for i in containers.slots_next(&self.camera_slots, &c) {
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
      pyramid             = u32(self.pyramids[camera_slot(i) + frame_index]),
      occlusion_mask      = GBUFFER_TYPES if camera_ready(self, i) else 0,
      list_stride         = 1,
      type_mask           = all_types,
      require_flags       = {.VISIBLE},
      // frame N builds pyramid N from N-1's depth and culls into N+1's lists
      draw_list           = camera_next_slot(i, frame_index),
      list_capacity       = CAMERA_LIST_CAPACITY,
      time                = self.time,
    }
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

// frame renders and presents one frame. An out-of-date swapchain is rebuilt at
// framebuffer_size. It returns false on a GPU error.
frame :: proc(self: ^Renderer, framebuffer_size: [2]u32, dpi_scale: f32) -> bool {
  frame_index := current_frame(self)
  guard(self)
  tick_resource_pools(self)
  flush(self, frame_index)
  submitted, status := frame_run(self, framebuffer_size)
  // the staged overlay is this frame's only
  overlay_clear(self)
  if submitted {
    // simulated: the next frame's time accumulates from zero
    self.particle_params.delta_time = 0
    // the backend has every write so far
    self.dirty = {}
  }
  switch status {
  case .OK:
    return true
  case .RESIZE:
    return recreate_swapchain(self, framebuffer_size, dpi_scale)
  case .ERROR:
  }
  return false
}

// destroy frees a resource by its handle (or a Geometry), as its *_destroy does.
destroy :: proc {
  mesh_destroy,
  material_destroy,
  texture_destroy,
  camera_destroy,
  light_destroy,
  emitter_destroy,
  force_field_destroy,
  material_shader_destroy,
  post_shader_destroy,
  geometry_destroy,
}

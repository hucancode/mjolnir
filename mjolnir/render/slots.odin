package render

import "../containers"
import "core:log"
import "core:slice"

// Scene slots: what each draws (attach) and where (place).

@(private)
NodeFlag :: enum u32 {
  VISIBLE,
  CASTS_SHADOW,
  // attachment_data_index holds a bone range; only set while the mesh is skinned, so the
  // shaders skin by this flag alone
  SKINNED,
  // a light, emitter or force field is attached: attachment_data_index is its placement row
  LIGHT,
  EMITTER,
  FORCE_FIELD,
}

@(private)
NodeFlagSet :: bit_set[NodeFlag;u32]

// What a slot may have placed at it instead of a mesh, each a placement table naming the slot.
@(private)
PlacedKind :: enum {
  LIGHT,
  EMITTER,
  FORCE_FIELD,
}

// Per kind: the node flag saying it is placed, its placement pool and its name in warnings.
@(private)
PLACED := [PlacedKind]struct {
  flag: NodeFlag,
  pool: Pool,
  name: string,
} {
  .LIGHT       = {.LIGHT, .LIGHT_PLACEMENTS, "light"},
  .EMITTER     = {.EMITTER, .EMITTER_PLACEMENTS, "emitter"},
  .FORCE_FIELD = {.FORCE_FIELD, .FORCE_FIELD_PLACEMENTS, "force field"},
}

// Every placement row starts with its resource's handle, then its slot.
#assert(offset_of(LightPlacement, node) == 4 && offset_of(EmitterPlacement, node) == 4 && offset_of(ForceFieldPlacement, node) == 4)

@(private = "file")
placed_row :: proc(self: ^Renderer, kind: PlacedKind, row: u32) -> ^[2]u32 {
  t := POOLS[PLACED[kind].pool].table
  return (^[2]u32)(&self.tables[t][int(row) * TABLES[t].stride])
}

// the shadow pass draws these; the material type must also be in GBUFFER_TYPES
@(private)
SHADOW_CASTER_FLAGS :: NodeFlagSet{.VISIBLE, .CASTS_SHADOW}

// The zero record is an empty slot: mesh and material 0 are none. When .SKINNED is set,
// attachment_data_index is the first bone of its palette in the bone table and
// skin_vertex_base the first of its skinned vertices (pass_skin.odin); when .LIGHT, .EMITTER or
// .FORCE_FIELD is, attachment_data_index is the placement row.
@(private)
Node :: struct #packed {
  world_matrix:          matrix[4, 4]f32,
  material_id:           u32,
  mesh_id:               u32,
  attachment_data_index: u32,
  flags:                 NodeFlagSet,
  skin_vertex_base:      u32,
  layer:                 u32,
  _:                     [2]u32,
}
#assert(size_of(Node) == 96)

// MeshAttachment draws mesh with material from a slot's transform; a skinned mesh deforms by
// the palette `bones` (bones_create), else draws as modelled. Cameras with `layer` in
// Camera.hidden_layers skip it; shadows still cast it.
MeshAttachment :: struct {
  mesh:        MeshHandle,
  material:    MaterialHandle,
  cast_shadow: bool,
  bones:       BonesHandle,
  // below MAX_LAYERS
  layer:       u32,
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
  lock(self)
  place_slot(self, slot_index(slot), world_matrix, visible)
}

// release empties a slot: it forgets its attachment and bone palette; meshes, materials and
// what was attached stay.
release :: proc(self: ^Renderer, slot: $H) {
  lock(self)
  release_slot(self, slot_index(slot))
}

// stage_transforms applies a scene graph's change feed, place or release per entry: `changes` is
// any struct with `index`, `world_matrix`, `visible` and `removed` fields, removals first.
stage_transforms :: proc(self: ^Renderer, changes: []$T) {
  lock(self)
  for &c in changes {
    if c.removed do release_slot(self, u32(c.index))
    else do place_slot(self, u32(c.index), c.world_matrix, c.visible)
  }
}

// place and release, the caller holding the render mutex.
@(private = "file")
place_slot :: proc(self: ^Renderer, slot: u32, world_matrix: matrix[4, 4]f32, visible: bool) {
  node := slot_node(self, slot)
  if node == nil do return
  node.world_matrix = world_matrix
  if visible do node.flags += {.VISIBLE}
  else do node.flags -= {.VISIBLE}
  mark_dirty(self, .NODES, int(slot))
}

@(private = "file")
release_slot :: proc(self: ^Renderer, slot: u32) {
  unbind(self, slot)
  #reverse for b, i in self.bursts do if b.row == 0 && b.slot == slot do ordered_remove(&self.bursts, i)
  if slot >= self.node_count do return
  release_bones(self, slot)
  batch_leave(self, slot)
  write_table(self, .NODES, Node)[slot] = {}
  mark_dirty(self, .NODES, int(slot))
}

// Drops the slot's light, emitter or force field, freeing its placement row. Caller holds the
// render mutex.
@(private = "file")
unbind :: proc(self: ^Renderer, slot: u32) {
  if slot >= self.node_count do return
  node := &write_table(self, .NODES, Node)[slot]
  for p in PLACED do if p.flag in node.flags {
    containers.slots_free(&self.slots[p.pool], node.attachment_data_index)
    clear_entry(self, POOLS[p.pool].table, node.attachment_data_index)
    node.flags -= {p.flag}
    node.attachment_data_index = 0
    mark_dirty(self, .NODES, int(slot))
  }
}

// Stores `value` in a free row of the pool's table; the row is the resource's handle (or a
// placement's row).
@(private)
resource_create :: proc(self: ^Renderer, pool: Pool, value: $T) -> (index: u32, ok: bool) {
  lock(self)
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
  lock(self)
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
@(private)
release_bones :: proc(self: ^Renderer, slot: u32) {
  node := &write_table(self, .NODES, Node)[slot]
  if .SKINNED not_in node.flags do return
  skin_own(self, node.skin_vertex_base, 0)
  containers.ranges_free(&self.skin_ranges, node.skin_vertex_base)
  node.attachment_data_index, node.skin_vertex_base = 0, 0
  node.flags -= {.SKINNED}
  mark_dirty(self, .NODES, int(slot))
}

// attach draws attachment at slot, replacing what the slot drew before; place sets where. A
// slot is any index below MAX_SLOTS the application picks, usually a world node's index. A
// skinned mesh with a palette (MeshAttachment.bones) gets the slot's range of skinned vertices,
// kept while later attachments still fit in it.
attach :: proc(self: ^Renderer, slot: $H, attachment: Attachment) {
  slot := slot_index(slot)
  lock(self)
  node := slot_node(self, slot)
  if node == nil do return
  unbind(self, slot)
  batch_leave(self, slot)
  node.mesh_id, node.material_id, node.layer = 0, 0, 0
  node.flags -= {.CASTS_SHADOW}
  switch a in attachment {
  case MeshAttachment:
    node.mesh_id, node.material_id = u32(a.mesh), u32(a.material)
    if a.layer < MAX_LAYERS do node.layer = a.layer
    else do log.errorf("Layer %d exceeds MAX_LAYERS", a.layer)
    batch_join(self, slot, node.mesh_id, node.material_id)
    if a.cast_shadow do node.flags += {.CASTS_SHADOW}
    skin(self, slot, a.bones)
  case LightHandle:
    place_row(self, slot, .LIGHT, u32(a))
  case EmitterHandle:
    place_row(self, slot, .EMITTER, u32(a))
  case ForceFieldHandle:
    place_row(self, slot, .FORCE_FIELD, u32(a))
  }
  mark_dirty(self, .NODES, int(slot))
}

// Adds a placement row naming the slot and links the slot to it.
@(private = "file")
place_row :: proc(self: ^Renderer, slot: u32, kind: PlacedKind, resource: u32) {
  release_bones(self, slot)
  p := PLACED[kind]
  row, ok := containers.slots_alloc(&self.slots[p.pool])
  if !ok {
    log.warnf("No room for more than %d placed %ss; the %s is dropped", POOLS[p.pool].capacity - 1, p.name, p.name)
    return
  }
  clear_entry(self, POOLS[p.pool].table, row)
  placed_row(self, kind, row)^ = {resource, slot}
  node := &write_table(self, .NODES, Node)[slot]
  node.flags += {p.flag}
  node.attachment_data_index = row
}

// Gives a slot drawing a skinned mesh with a live palette its skinned vertices (keeping a range
// it already holds that fits), else none.
@(private = "file")
skin :: proc(self: ^Renderer, slot: u32, bones: BonesHandle) {
  node := &write_table(self, .NODES, Node)[slot]
  mesh := write_table(self, .MESHES, MeshData)[node.mesh_id]
  first, live := bones_first(self, bones)
  if .SKINNED not_in mesh.flags || !live {
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
  node.attachment_data_index = first
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
  lock(self)
  if slot >= self.node_count do return
  node := write_table(self, .NODES, Node)[slot]
  when T == MeshAttachment {
    if node.mesh_id == 0 do return
    att = {mesh = MeshHandle(node.mesh_id), material = MaterialHandle(node.material_id), cast_shadow = .CASTS_SHADOW in node.flags, layer = node.layer}
    if .SKINNED not_in node.flags do return att, true
    att.bones = BonesHandle(node.attachment_data_index + 1)
    return att, true
  } else {
    kind: PlacedKind = .LIGHT when T == LightHandle else .EMITTER when T == EmitterHandle else .FORCE_FIELD
    #assert(T == LightHandle || T == EmitterHandle || T == ForceFieldHandle)
    if PLACED[kind].flag not_in node.flags do return
    return T(placed_row(self, kind, node.attachment_data_index)[0]), true
  }
}

package render

import "core:log"

// Where draws are not compacted by multi-draw (WebGPU), nodes are grouped into batches: the
// nodes drawing one mesh with one material. The GPU cull counts visible nodes per batch and
// lists them, so the CPU issues one indirect draw per batch instead of one per node.
// render keeps the groups as nodes attach and detach, never per frame: Table.BATCHES holds
// each batch's mesh, material and its range of instances, Table.NODE_BATCH each node's batch.
// Where multi-draw is there (Vulkan) none of it is maintained.

// A Batch is a Table.BATCHES entry, mirrored by the shaders. `capacity` is the nodes in the
// batch and `first_instance` where its instances start in a draw list's instance array: the
// capacities, summed in id order.
@(private)
Batch :: struct {
  mesh_id:        u32,
  material_id:    u32,
  first_instance: u32,
  capacity:       u32,
}
#assert(size_of(Batch) == 16)

@(private)
BatchState :: struct {
  // (material, mesh) -> batch id
  ids:        map[u64]u32,
  // nodes in each batch
  members:    [MAX_BATCHES]u32,
  free:       [dynamic]u32,
  // ids below this are in use or free
  high:       u32,
  // members changed: first_instance and capacity are stale
  stale:      bool,
  warned:     bool,
}

@(private = "file")
batch_key :: #force_inline proc(mesh, material: u32) -> u64 {
  return u64(material) << 32 | u64(mesh)
}

// Puts the node at `slot` into the batch of (mesh, material). Past MAX_BATCHES distinct
// batches the node is not drawn.
@(private)
batch_join :: proc(self: ^Renderer, slot, mesh, material: u32) {
  if !self.batched do return
  s := &self.batches
  s.high = max(s.high, 1)
  key := batch_key(mesh, material)
  id, found := s.ids[key]
  if !found {
    if len(s.free) > 0 {
      id = pop(&s.free)
    } else if s.high < MAX_BATCHES {
      id = s.high
      s.high += 1
    } else {
      if !s.warned do log.warnf("More than %d distinct (mesh, material) pairs; the nodes past them are not drawn", MAX_BATCHES - 1)
      s.warned = true
      return
    }
    s.ids[key] = id
    write_table(self, .BATCHES, Batch)[id] = {mesh_id = mesh, material_id = material}
  }
  s.members[id] += 1
  s.stale = true
  write_table(self, .NODE_BATCH, u32)[slot] = id
  mark_dirty(self, .NODE_BATCH, int(slot))
}

// Takes the node at `slot` out of its batch; an emptied batch is freed.
@(private)
batch_leave :: proc(self: ^Renderer, slot: u32) {
  if !self.batched do return
  s := &self.batches
  node_batch := write_table(self, .NODE_BATCH, u32)
  id := node_batch[slot]
  if id == 0 do return
  node_batch[slot] = 0
  mark_dirty(self, .NODE_BATCH, int(slot))
  s.members[id] -= 1
  s.stale = true
  if s.members[id] > 0 do return
  entry := &write_table(self, .BATCHES, Batch)[id]
  delete_key(&s.ids, batch_key(entry.mesh_id, entry.material_id))
  entry^ = {}
  append(&s.free, id)
}

// Forgets every batch, with every node's membership already zeroed.
@(private)
batches_reset :: proc(self: ^Renderer) {
  s := &self.batches
  clear(&s.ids)
  clear(&s.free)
  s.members = {}
  s.high = 0
  s.stale = false
  clear_entry(self, .BATCHES, 0, MAX_BATCHES)
  clear_entry(self, .NODE_BATCH, 0, MAX_NODES_IN_SCENE)
}

@(private)
batches_destroy :: proc(self: ^Renderer) {
  delete(self.batches.ids)
  delete(self.batches.free)
}

// Before a frame: lays the batches' instance ranges end to end when membership changed.
@(private)
batches_flush :: proc(self: ^Renderer) {
  s := &self.batches
  self.frame.batch_count = s.high
  if !s.stale do return
  s.stale = false
  entries := write_table(self, .BATCHES, Batch)
  first: u32
  for id in 1 ..< s.high {
    entries[id].first_instance = first
    entries[id].capacity = s.members[id]
    first += s.members[id]
  }
  mark_dirty(self, .BATCHES, 0, int(s.high))
}

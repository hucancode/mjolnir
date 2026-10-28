package render

import "core:log"
import "core:slice"

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

@(private = "file")
batch_key :: #force_inline proc(mesh, material: u32) -> u64 {
  return u64(material) << 32 | u64(mesh)
}

// Puts the node at `slot` into the batch of (mesh, material). Past MAX_BATCHES distinct
// batches the node is not drawn.
@(private)
batch_join :: proc(self: ^Renderer, slot, mesh, material: u32) {
  when BINDLESS do return
  self.batch_high = max(self.batch_high, 1)
  key := batch_key(mesh, material)
  id, found := self.batch_ids[key]
  if !found {
    if len(self.batch_free) > 0 {
      id = pop(&self.batch_free)
    } else if self.batch_high < MAX_BATCHES {
      id = self.batch_high
      self.batch_high += 1
    } else {
      if !self.batch_warned do log.warnf("More than %d distinct (mesh, material) pairs; the nodes past them are not drawn", MAX_BATCHES - 1)
      self.batch_warned = true
      return
    }
    self.batch_ids[key] = id
    write_table(self, .BATCHES, Batch)[id] = {mesh_id = mesh, material_id = material}
  }
  write_table(self, .BATCHES, Batch)[id].capacity += 1
  self.batch_stale = true
  write_table(self, .NODE_BATCH, u32)[slot] = id
  mark_dirty(self, .NODE_BATCH, int(slot))
}

// Takes the node at `slot` out of its batch; an emptied batch is freed.
@(private)
batch_leave :: proc(self: ^Renderer, slot: u32) {
  when BINDLESS do return
  node_batch := write_table(self, .NODE_BATCH, u32)
  id := node_batch[slot]
  if id == 0 do return
  node_batch[slot] = 0
  mark_dirty(self, .NODE_BATCH, int(slot))
  entry := &write_table(self, .BATCHES, Batch)[id]
  entry.capacity -= 1
  self.batch_stale = true
  if entry.capacity > 0 do return
  delete_key(&self.batch_ids, batch_key(entry.mesh_id, entry.material_id))
  entry^ = {}
  append(&self.batch_free, id)
}

// Forgets every batch, with every node's membership already zeroed.
@(private)
batches_reset :: proc(self: ^Renderer) {
  clear(&self.batch_ids)
  clear(&self.batch_free)
  self.batch_high = 0
  self.batch_stale = false
  clear_entry(self, .BATCHES, 0, MAX_BATCHES)
  clear_entry(self, .NODE_BATCH, 0, MAX_SLOTS)
}

// Before a frame: lays the batches' instance ranges end to end when membership changed, and
// sorts the live batches by draw list key (material_list), then material, then id, for the
// draw loop (materials may change their type or shader any tick).
@(private)
batches_flush :: proc(self: ^Renderer) {
  when BINDLESS do return
  entries := write_table(self, .BATCHES, Batch)
  if self.batch_stale {
    self.batch_stale = false
    first: u32
    for id in 1 ..< self.batch_high {
      entries[id].first_instance = first
      first += entries[id].capacity
    }
    mark_dirty(self, .BATCHES, 0, int(self.batch_high))
  }
  materials := write_table(self, .MATERIALS, Material)
  clear(&self.batch_order)
  #assert(MAX_MATERIALS <= 1 << 24 && MAX_BATCHES <= 1 << 20)
  for id in 1 ..< self.batch_high do if entries[id].capacity > 0 {
    key := material_list(materials[entries[id].material_id])
    // a custom material without a shader is drawn by no one
    if key == NO_DRAW_LIST do continue
    append(&self.batch_order, u64(key) << 44 | u64(entries[id].material_id) << 20 | u64(id))
  }
  slice.sort(self.batch_order[:])
}

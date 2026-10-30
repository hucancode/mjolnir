package render

import "../containers"
import "core:log"
import "core:slice"

// BonesHandle is a bone palette (bones_create): skinned meshes attached with it deform by it.
BonesHandle :: distinct u32

// The first bone of a live palette.
@(private)
bones_first :: proc(self: ^Renderer, bones: BonesHandle) -> (first: u32, ok: bool) {
  first = u32(bones) - 1
  return first, bones != 0 && containers.ranges_size(&self.bone_ranges, first) > 0
}

// bones_create makes a palette of `count` bones (one per animated character, shared by every
// skinned mesh of it, MeshAttachment.bones), at rest until stage_bones; it lives until
// bones_destroy or teardown. false for no bones or past MAX_BONES bones in all.
bones_create :: proc(self: ^Renderer, count: u32) -> (handle: BonesHandle, ok: bool) #optional_ok {
  lock(self)
  if count == 0 do return 0, false
  first, has_room := containers.ranges_alloc(&self.bone_ranges, count)
  if !has_room {
    log.warnf("No room for a %d-bone palette past MAX_BONES (%d)", count, MAX_BONES)
    return 0, false
  }
  slice.fill(write_table(self, .BONES, matrix[4, 4]f32)[first:][:count], 1)
  mark_dirty(self, .BONES, int(first), int(count))
  return BonesHandle(first + 1), true
}

// stage_bones sets a palette's bone skinning matrices (skeleton-space bone matrix times inverse
// bind, per bone, relative to each slot's world matrix): every skinned mesh attached with it
// deforms by them. The matrices are copied, at most the palette's bone count.
stage_bones :: proc(self: ^Renderer, bones: BonesHandle, matrices: []matrix[4, 4]f32) {
  lock(self)
  first, live := bones_first(self, bones)
  if !live do return
  count := min(u32(len(matrices)), containers.ranges_size(&self.bone_ranges, first))
  copy(write_table(self, .BONES, matrix[4, 4]f32)[first:][:count], matrices[:count])
  mark_dirty(self, .BONES, int(first), int(count))
}

// bones_destroy frees the palette; its meshes draw unskinned.
bones_destroy :: proc(self: ^Renderer, bones: BonesHandle) {
  lock(self)
  first, live := bones_first(self, bones)
  if !live do return
  // a live palette is the only one starting at its first bone
  nodes := write_table(self, .NODES, Node)
  for i in 0 ..< self.node_count do if .SKINNED in nodes[i].flags && nodes[i].attachment_data_index == first do release_bones(self, i)
  containers.ranges_free(&self.bone_ranges, first)
}

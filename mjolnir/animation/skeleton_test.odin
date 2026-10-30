#+build !js
#+private
package animation

import "core:math/linalg"
import "core:slice"
import "core:testing"

// Synthetic 5-bone skeleton stored deliberately out of order (children before
// parents):
//   root (3)
//     ├─ hip (2)
//     │   └─ knee (0)
//     │       └─ ankle (1)
//     └─ tail (4)   rotated 0.5 rad about X
SKEL_NAMES := [5]string{"knee", "ankle", "hip", "root", "tail"}
SKEL_PARENTS := [5]i32{2, 0, 3, -1, 3}
SKEL_POS := [5][3]f32{{0, 2, 0}, {0, 3, 0}, {0, 1, 0}, {0, 0, 0}, {0, 0.5, 1}}

make_unsorted_skeleton :: proc(skel: ^Skeleton) -> bool {
  inv: [5]matrix[4, 4]f32
  for p, i in SKEL_POS {
    bind := linalg.matrix4_translate_f32(p)
    if i == 4 do bind = bind * linalg.matrix4_rotate_f32(0.5, {1, 0, 0})
    inv[i] = linalg.matrix4_inverse(bind)
  }
  parents := SKEL_PARENTS
  names := SKEL_NAMES
  return skeleton_init(skel, parents[:], inv[:], names[:])
}

matrix_almost_equal :: proc(a, b: matrix[4, 4]f32, eps: f32 = 1e-4) -> bool {
  for c in 0 ..< 4 do for r in 0 ..< 4 do if abs(a[c][r] - b[c][r]) > eps do return false
  return true
}

@(test)
test_skeleton_init_unsorted_order :: proc(t: ^testing.T) {
  skel: Skeleton
  testing.expect(t, make_unsorted_skeleton(&skel), "init")
  defer skeleton_destroy(&skel)
  testing.expect_value(t, bone_count(&skel), 5)
  testing.expect_value(t, len(skel.order), 5)
  // every parent appears before its children
  seen: [5]bool
  for b in skel.order {
    p := skel.parents[b]
    testing.expectf(t, p < 0 || seen[p], "bone %d visited before parent %d", b, p)
    seen[b] = true
  }
  for s in seen do testing.expect(t, s, "every bone in order")
  testing.expect_value(t, skel.order[0], 3)
  // depths
  testing.expect(t, slice.equal(skel.depths, []u32{2, 3, 1, 0, 1}), "depths")
  testing.expect_value(t, skel.names[3], "root")
}

@(test)
test_skeleton_lengths_and_rest :: proc(t: ^testing.T) {
  skel: Skeleton
  testing.expect(t, make_unsorted_skeleton(&skel))
  defer skeleton_destroy(&skel)
  expected := [5]f32{1, 1, 1, 0, linalg.length([3]f32{0, 0.5, 1})}
  for e, i in expected {
    testing.expectf(t, abs(skel.lengths[i] - e) < 1e-5, "length[%d]=%f want %f", i, skel.lengths[i], e)
  }
  testing.expect(t, almost_equal_vec3(skel.rest[0].position, {0, 1, 0}), "knee rest local offset")
  // rest local transforms composed along parents reproduces bind
  model: [5]matrix[4, 4]f32
  for i in skel.order {
    m := linalg.matrix4_from_trs(skel.rest[i].position, skel.rest[i].rotation, skel.rest[i].scale)
    if p := skel.parents[i]; p >= 0 do m = model[p] * m
    model[i] = m
    testing.expectf(t, matrix_almost_equal(m, skel.bind[i]), "bone %d rest composes to bind", i)
    testing.expect(t, matrix_almost_equal(m * skel.inverse_bind[i], linalg.MATRIX4F32_IDENTITY))
  }
}

@(test)
test_skeleton_init_rejects_bad_parents :: proc(t: ^testing.T) {
  inv := []matrix[4, 4]f32{linalg.MATRIX4F32_IDENTITY, linalg.MATRIX4F32_IDENTITY, linalg.MATRIX4F32_IDENTITY}
  skel: Skeleton
  testing.expect(t, !skeleton_init(&skel, []i32{-1, 2, 1}, inv), "cycle 1<->2 rejected")
  testing.expect(t, skel.parents == nil, "failed init leaves skeleton empty")
  testing.expect(t, !skeleton_init(&skel, []i32{1, 2, 0}, inv), "full cycle, no root")
  testing.expect(t, !skeleton_init(&skel, []i32{-1, 3, 0}, inv), "out of range")
  testing.expect(t, !skeleton_init(&skel, []i32{-1, -2, 0}, inv), "negative out of range")
  testing.expect(t, !skeleton_init(&skel, []i32{-1, 0}, inv), "inverse_bind length mismatch")
}

@(test)
test_skeleton_find_bone :: proc(t: ^testing.T) {
  skel: Skeleton
  testing.expect(t, make_unsorted_skeleton(&skel))
  defer skeleton_destroy(&skel)
  idx, ok := bone_find(&skel, "knee")
  testing.expect(t, ok && idx == 0)
  idx, ok = bone_find(&skel, "root")
  testing.expect(t, ok && idx == 3)
  _, ok = bone_find(&skel, "ghost")
  testing.expect(t, !ok)
  empty: Skeleton
  _, ok = bone_find(&empty, "any")
  testing.expect(t, !ok, "empty skeleton misses")
}

@(test)
test_skeleton_find_bones :: proc(t: ^testing.T) {
  skel: Skeleton
  testing.expect(t, make_unsorted_skeleton(&skel))
  defer skeleton_destroy(&skel)
  indices, ok := bones_find(&skel, []string{"hip", "ankle", "tail"})
  defer delete(indices)
  testing.expect(t, ok && indices[0] == 2 && indices[1] == 1 && indices[2] == 4)
  bad, ok2 := bones_find(&skel, []string{"hip", "ghost"})
  testing.expect(t, !ok2 && bad == nil, "any miss fails")
}

@(test)
test_skeleton_bone_chain :: proc(t: ^testing.T) {
  skel: Skeleton
  testing.expect(t, make_unsorted_skeleton(&skel))
  defer skeleton_destroy(&skel)
  chain, ok := bone_chain(&skel, "root", "ankle")
  defer delete(chain)
  testing.expect(t, ok)
  testing.expect(t, slice.equal(chain, []u32{3, 2, 0, 1}), "root->hip->knee->ankle")
  single, ok1 := bone_chain(&skel, "knee", "knee")
  defer delete(single)
  testing.expect(t, ok1 && len(single) == 1 && single[0] == 0, "root == tip")
  _, ok2 := bone_chain(&skel, "tail", "ankle")
  testing.expect(t, !ok2, "ankle not under tail")
  _, ok3 := bone_chain(&skel, "missing", "ankle")
  testing.expect(t, !ok3, "missing root")
  _, ok4 := bone_chain(&skel, "root", "missing")
  testing.expect(t, !ok4, "missing tip")
}

@(test)
test_skeleton_bone_chain_down :: proc(t: ^testing.T) {
  skel: Skeleton
  testing.expect(t, make_unsorted_skeleton(&skel))
  defer skeleton_destroy(&skel)
  chain, ok := bone_chain_down(&skel, "hip", 10)
  defer delete(chain)
  testing.expect(t, ok && slice.equal(chain, []u32{2, 0, 1}), "stops at leaf")
  short, ok2 := bone_chain_down(&skel, "hip", 2)
  defer delete(short)
  testing.expect(t, ok2 && slice.equal(short, []u32{2, 0}), "length limit")
  _, ok3 := bone_chain_down(&skel, "tail", 4)
  testing.expect(t, !ok3, "leaf alone is < 2 bones")
  _, ok4 := bone_chain_down(&skel, "ghost", 4)
  testing.expect(t, !ok4)
}

@(test)
test_skeleton_subtree :: proc(t: ^testing.T) {
  skel: Skeleton
  testing.expect(t, make_unsorted_skeleton(&skel))
  defer skeleton_destroy(&skel)
  sub, ok := bone_subtree(&skel, "hip")
  defer delete(sub)
  slice.sort(sub)
  testing.expect(t, ok && slice.equal(sub, []u32{0, 1, 2}), "hip subtree")
  all, ok2 := bone_subtree(&skel, "root")
  defer delete(all)
  testing.expect(t, ok2 && len(all) == 5 && all[0] == 3, "root subtree, parents first")
  _, ok3 := bone_subtree(&skel, "ghost")
  testing.expect(t, !ok3)
}

@(test)
test_skeleton_rest_position_and_offset :: proc(t: ^testing.T) {
  skel: Skeleton
  testing.expect(t, make_unsorted_skeleton(&skel))
  defer skeleton_destroy(&skel)
  pos, ok := rest_position(&skel, "knee")
  testing.expect(t, ok && almost_equal_vec3(pos, {0, 2, 0}), "knee at y=2")
  off, ok2 := rest_offset(&skel, "hip", "ankle")
  testing.expect(t, ok2 && almost_equal_vec3(off, {0, 2, 0}), "hip->ankle")
  _, miss := rest_position(&skel, "ghost")
  testing.expect(t, !miss)
  _, miss2 := rest_offset(&skel, "hip", "ghost")
  testing.expect(t, !miss2)
}

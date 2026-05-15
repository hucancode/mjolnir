package world

import "core:math/linalg"
import "core:testing"

// Build a synthetic 5-bone skeleton:
//   root (0)
//     ├─ hip (1)
//     │   └─ knee (2)
//     │       └─ ankle (3)
//     └─ tail (4)
make_test_skeleton :: proc() -> ^Mesh {
	mesh := new(Mesh)
	bones := make([]Bone, 5)
	bones[0] = Bone{name = "root", children = make_clone([]u32{1, 4})}
	bones[1] = Bone{name = "hip", children = make_clone([]u32{2})}
	bones[2] = Bone{name = "knee", children = make_clone([]u32{3})}
	bones[3] = Bone{name = "ankle", children = make([]u32, 0)}
	bones[4] = Bone{name = "tail", children = make([]u32, 0)}

	// Bind matrices: identity translation chain along Y, descending
	bind_mats := make([]matrix[4, 4]f32, 5)
	bind_mats[0] = linalg.matrix4_translate_f32({0, 0, 0})
	bind_mats[1] = linalg.matrix4_translate_f32({0, 1, 0})
	bind_mats[2] = linalg.matrix4_translate_f32({0, 2, 0})
	bind_mats[3] = linalg.matrix4_translate_f32({0, 3, 0})
	bind_mats[4] = linalg.matrix4_translate_f32({0, 0.5, 1})
	for &b, i in bones do b.inverse_bind_matrix = linalg.matrix4_inverse(bind_mats[i])

	mesh.skinning = Skinning {
		root_bone_index = 0,
		bones           = bones,
		bind_matrices   = bind_mats,
	}
	return mesh
}

destroy_test_skeleton :: proc(mesh: ^Mesh) {
	mesh_destroy(mesh)
	free(mesh)
}

make_clone :: proc(s: []u32) -> []u32 {
	out := make([]u32, len(s))
	copy(out, s)
	return out
}

@(test)
test_find_bone_by_name_hits_and_misses :: proc(t: ^testing.T) {
	mesh := make_test_skeleton()
	defer destroy_test_skeleton(mesh)

	idx, ok := find_bone_by_name(mesh, "knee")
	testing.expect(t, ok && idx == 2, "knee at index 2")

	_, ok2 := find_bone_by_name(mesh, "nonexistent")
	testing.expect(t, !ok2, "nonexistent must miss")

	mesh_no_skin: Mesh
	_, ok3 := find_bone_by_name(&mesh_no_skin, "any")
	testing.expect(t, !ok3, "no skin must miss")
}

@(test)
test_find_bone_chain_root_to_tip :: proc(t: ^testing.T) {
	mesh := make_test_skeleton()
	defer destroy_test_skeleton(mesh)

	chain, ok := find_bone_chain(mesh, "root", "ankle")
	testing.expect(t, ok, "chain found")
	defer delete(chain)
	testing.expectf(t, len(chain) == 4, "expected 4 bones, got %d", len(chain))
	testing.expect(t, chain[0] == 0 && chain[1] == 1 && chain[2] == 2 && chain[3] == 3,
		"chain order root→hip→knee→ankle")

	// invalid: tip not under root sibling chain
	_, ok2 := find_bone_chain(mesh, "tail", "ankle")
	testing.expect(t, !ok2, "ankle is not under tail")

	// invalid: unknown name
	_, ok3 := find_bone_chain(mesh, "missing", "ankle")
	testing.expect(t, !ok3, "missing root rejected")
}

@(test)
test_bone_rest_position_and_offset :: proc(t: ^testing.T) {
	mesh := make_test_skeleton()
	defer destroy_test_skeleton(mesh)

	pos, ok := bone_rest_position(mesh, "knee")
	testing.expect(t, ok && pos == [3]f32{0, 2, 0}, "knee at y=2")

	off, ok2 := bone_rest_offset(mesh, "hip", "ankle")
	testing.expect(t, ok2 && off == [3]f32{0, 2, 0}, "hip→ankle offset = (0,2,0)")

	_, miss := bone_rest_position(mesh, "ghost")
	testing.expect(t, !miss, "missing bone rejected")
}

@(test)
test_build_bone_parent_map :: proc(t: ^testing.T) {
	mesh := make_test_skeleton()
	defer destroy_test_skeleton(mesh)
	skin := &mesh.skinning.?
	parents := build_bone_parent_map(skin)
	defer delete(parents)
	testing.expect(t, parents[1] == 0 && parents[2] == 1 && parents[3] == 2 && parents[4] == 0,
		"parent map mismatch")
	_, root_has_parent := parents[0]
	testing.expect(t, !root_has_parent, "root should have no parent")
}

@(test)
test_find_bone_chain_to_root :: proc(t: ^testing.T) {
	mesh := make_test_skeleton()
	defer destroy_test_skeleton(mesh)
	skin := &mesh.skinning.?

	chain, ok := find_bone_chain_to_root(skin, "ankle", "root")
	testing.expect(t, ok, "chain found")
	defer delete(chain)
	testing.expectf(t, len(chain) == 4, "expected 4 names, got %d", len(chain))
	testing.expect(t, chain[0] == "root" && chain[3] == "ankle", "endpoints correct")

	_, ok2 := find_bone_chain_to_root(skin, "ankle", "tail")
	testing.expect(t, !ok2, "ankle is not under tail")
}

@(test)
test_find_bones_by_names :: proc(t: ^testing.T) {
	mesh := make_test_skeleton()
	defer destroy_test_skeleton(mesh)

	indices, ok := find_bones_by_names(mesh, []string{"hip", "ankle", "tail"})
	testing.expect(t, ok, "all found")
	defer delete(indices)
	testing.expect(t, indices[0] == 1 && indices[1] == 3 && indices[2] == 4, "indices correct")

	_, ok2 := find_bones_by_names(mesh, []string{"hip", "ghost"})
	testing.expect(t, !ok2, "any miss → fail")
}

@(test)
test_compute_bone_lengths :: proc(t: ^testing.T) {
	mesh := make_test_skeleton()
	defer destroy_test_skeleton(mesh)
	skin := &mesh.skinning.?
	compute_bone_lengths(skin)
	testing.expect(t, len(skin.bone_lengths) == 5, "lengths array sized")
	// knee→ankle is 1.0 (y diff). knee should report length to its child = 1.0
	testing.expectf(t, skin.bone_lengths[2] > 0.99 && skin.bone_lengths[2] < 1.01,
		"knee bone_length expected ~1.0, got %f", skin.bone_lengths[2])
}

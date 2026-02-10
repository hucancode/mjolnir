package data

import "../animation"
import "../geometry"
import "core:math/linalg"

MeshFlag :: enum u32 {
	SKINNED,
}

MeshFlagSet :: bit_set[MeshFlag;u32]

MeshData :: struct {
	aabb_min:        [3]f32,
	index_count:     u32,
	aabb_max:        [3]f32,
	first_index:     u32,
	vertex_offset:   i32,
	skinning_offset: u32,
	flags:           MeshFlagSet,
	padding:         u32,
}

Bone :: struct {
	children:            []u32,
	inverse_bind_matrix: matrix[4, 4]f32,
	name:                string,
}

bone_destroy :: proc(bone: ^Bone) {
	delete(bone.children)
	bone.children = nil
}

BufferAllocation :: struct {
	offset: u32,
	count:  u32,
}

Skinning :: struct {
	root_bone_index: u32,
	bones:           []Bone,
	allocation:      BufferAllocation,
	bone_lengths:    []f32, // Length from parent to this bone
}

Mesh :: struct {
	using data:        MeshData,
	vertex_allocation: BufferAllocation,
	index_allocation:  BufferAllocation,
	skinning:          Maybe(Skinning),
	using meta:        ResourceMetadata,
}

prepare_mesh_data :: proc(mesh: ^Mesh) {
	mesh.index_count = mesh.index_allocation.count
	mesh.first_index = mesh.index_allocation.offset
	mesh.vertex_offset = cast(i32)mesh.vertex_allocation.offset
	mesh.flags = {}
	skin, has_skin := mesh.skinning.?
	if has_skin && skin.allocation.count > 0 {
		mesh.flags |= {.SKINNED}
		mesh.skinning_offset = skin.allocation.offset
	}
}

Primitive :: enum {
	CUBE,
	SPHERE,
	QUAD_XZ,
	QUAD_XY,
	CONE,
	CAPSULE,
	CYLINDER,
	TORUS,
}

find_bone_by_name :: proc(
	self: ^Mesh,
	name: string,
) -> (
	index: u32,
	ok: bool,
) #optional_ok {
	skin, has_skin := &self.skinning.?
	if !has_skin do return
	for bone, i in skin.bones {
		if bone.name == name {
			return u32(i), true
		}
	}
	return 0, false
}

// Compute all bone lengths from bind pose
// Traverses skeleton hierarchy and stores distance from parent to each bone
compute_bone_lengths :: proc(skin: ^Skinning) {
	bone_count := len(skin.bones)
	if bone_count == 0 do return
	// Allocate bone lengths array
	skin.bone_lengths = make([]f32, bone_count)
	// Get bind pose positions (inverse of inverse_bind_matrix)
	bind_positions := make([][3]f32, bone_count, context.temp_allocator)
	for bone, i in skin.bones {
		bind_matrix := linalg.matrix4_inverse(bone.inverse_bind_matrix)
		bind_positions[i] = bind_matrix[3].xyz
	}
	// Traverse hierarchy and compute distances
	TraverseEntry :: struct {
		bone_idx:   u32,
		parent_pos: [3]f32,
	}
	stack := make([dynamic]TraverseEntry, 0, bone_count, context.temp_allocator)
	// Root has no parent, length = 0
	root_pos := bind_positions[skin.root_bone_index]
	skin.bone_lengths[skin.root_bone_index] = 0
	// Queue root's children
	root_bone := &skin.bones[skin.root_bone_index]
	for child_idx in root_bone.children {
		append(&stack, TraverseEntry{child_idx, root_pos})
	}
	// Process all bones
	for len(stack) > 0 {
		entry := pop(&stack)
		bone := &skin.bones[entry.bone_idx]
		bone_pos := bind_positions[entry.bone_idx]
		// Compute and store length from parent
		skin.bone_lengths[entry.bone_idx] = linalg.distance(
			entry.parent_pos,
			bone_pos,
		)
		// Queue children with this bone's position
		for child_idx in bone.children {
			append(&stack, TraverseEntry{child_idx, bone_pos})
		}
	}
}

// Sample animation clip to produce bone matrices
sample_clip :: proc(
	self: ^Mesh,
	clip: ^animation.Clip,
	t: f32,
	out_bone_matrices: []matrix[4, 4]f32,
) {
	skin, has_skin := &self.skinning.?
	if !has_skin do return
	if len(out_bone_matrices) < len(skin.bones) {
		return
	}
	if clip == nil do return
	TraverseEntry :: struct {
		transform: matrix[4, 4]f32,
		bone:      u32,
	}
	stack := make(
		[dynamic]TraverseEntry,
		0,
		len(skin.bones),
		context.temp_allocator,
	)
	append(
		&stack,
		TraverseEntry{linalg.MATRIX4F32_IDENTITY, skin.root_bone_index},
	)
	for len(stack) > 0 {
		entry := pop(&stack)
		bone := &skin.bones[entry.bone]
		local_matrix := linalg.MATRIX4F32_IDENTITY
		if entry.bone < u32(len(clip.channels)) {
			position, rotation, scale := animation.channel_sample_all(
				clip.channels[entry.bone],
				t,
			)
			local_matrix = linalg.matrix4_from_trs(position, rotation, scale)
		}
		world_transform := entry.transform * local_matrix
		out_bone_matrices[entry.bone] = world_transform * bone.inverse_bind_matrix
		for child_index in bone.children {
			append(&stack, TraverseEntry{world_transform, child_index})
		}
	}
}

// Sample animation clip with IK corrections applied
// This version first computes FK, then applies IK targets, then outputs skinning matrices
sample_clip_with_ik :: proc(
	self: ^Mesh,
	clip: ^animation.Clip,
	t: f32,
	ik_targets: []animation.IKTarget,
	out_bone_matrices: []matrix[4, 4]f32,
) {
	skin, has_skin := &self.skinning.?
	if !has_skin do return
	if len(out_bone_matrices) < len(skin.bones) {
		return
	}
	if clip == nil do return
	bone_count := len(skin.bones)
	// Allocate temporary storage for world transforms
	world_transforms := make(
		[]animation.BoneTransform,
		bone_count,
		context.temp_allocator,
	)
	// Phase 1: FK pass - compute world transforms from animation
	TraverseEntry :: struct {
		parent_world: matrix[4, 4]f32,
		bone_index:   u32,
	}
	stack := make([dynamic]TraverseEntry, 0, bone_count, context.temp_allocator)
	append(
		&stack,
		TraverseEntry{linalg.MATRIX4F32_IDENTITY, skin.root_bone_index},
	)
	for len(stack) > 0 {
		entry := pop(&stack)
		bone := &skin.bones[entry.bone_index]
		bone_idx := entry.bone_index
		// Sample animation for local transform
		local_matrix := linalg.MATRIX4F32_IDENTITY
		if bone_idx < u32(len(clip.channels)) {
			position, rotation, scale := animation.channel_sample_all(
				clip.channels[bone_idx],
				t,
			)
			local_matrix = linalg.matrix4_from_trs(position, rotation, scale)
		}
		// Compute world transform
		world_matrix := entry.parent_world * local_matrix
		// Store world transform
		world_transforms[bone_idx].world_matrix = world_matrix
		world_transforms[bone_idx].world_position = world_matrix[3].xyz
		world_transforms[bone_idx].world_rotation = linalg.to_quaternion(
			world_matrix,
		)
		// Push children
		for child_idx in bone.children {
			append(&stack, TraverseEntry{world_matrix, child_idx})
		}
	}
	// Phase 2: Apply IK corrections
	for &target in ik_targets {
		if !target.enabled do continue
		// Fallback: compute bone_lengths if not cached (for external callers)
		if len(target.bone_lengths) == 0 {
			chain_length := len(target.bone_indices)
			bone_lengths := make([]f32, chain_length - 1, context.temp_allocator)
			for i in 0 ..< chain_length - 1 {
				child_bone_idx := target.bone_indices[i + 1]
				bone_lengths[i] = skin.bone_lengths[child_bone_idx]
			}
			target.bone_lengths = bone_lengths
		}
		animation.fabrik_solve(world_transforms[:], target)
	}
	// Phase 2.5: Update child bones after IK modifications
	if len(ik_targets) > 0 {
		// Collect all bones affected by IK
		affected_bones := make(map[u32]bool, bone_count, context.temp_allocator)
		for target in ik_targets {
			if !target.enabled do continue
			for bone_idx in target.bone_indices {
				affected_bones[bone_idx] = true
			}
		}
		// Recompute world transforms for children of affected bones
		update_stack := make(
			[dynamic]TraverseEntry,
			0,
			bone_count,
			context.temp_allocator,
		)
		for bone_idx in affected_bones {
			bone := &skin.bones[bone_idx]
			parent_world := world_transforms[bone_idx].world_matrix
			for child_idx in bone.children {
				if child_idx in affected_bones do continue
				append(&update_stack, TraverseEntry{parent_world, child_idx})
			}
		}
		for len(update_stack) > 0 {
			entry := pop(&update_stack)
			bone := &skin.bones[entry.bone_index]
			bone_idx := entry.bone_index
			local_matrix := linalg.MATRIX4F32_IDENTITY
			if bone_idx < u32(len(clip.channels)) {
				position, rotation, scale := animation.channel_sample_all(
					clip.channels[bone_idx],
					t,
				)
				local_matrix = linalg.matrix4_from_trs(position, rotation, scale)
			}
			world_matrix := entry.parent_world * local_matrix
			world_transforms[bone_idx].world_matrix = world_matrix
			world_transforms[bone_idx].world_position = world_matrix[3].xyz
			world_transforms[bone_idx].world_rotation = linalg.to_quaternion(
				world_matrix,
			)
			for child_idx in bone.children {
				append(&update_stack, TraverseEntry{world_matrix, child_idx})
			}
		}
	}
	// Phase 3: Compute final skinning matrices = world * inverse_bind
	for i in 0 ..< bone_count {
		world_matrix := world_transforms[i].world_matrix
		out_bone_matrices[i] = world_matrix * skin.bones[i].inverse_bind_matrix
	}
}

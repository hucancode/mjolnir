package world

import "../animation"
import cont "../containers"
import d "../data"
import "../geometry"
import "core:log"
import "core:math/linalg"

// Re-export types from data module
Bone :: d.Bone
bone_destroy :: d.bone_destroy
MAX_MESHES :: d.MAX_MESHES
MeshFlag :: d.MeshFlag
MeshFlagSet :: d.MeshFlagSet
MeshData :: d.MeshData
Skinning :: d.Skinning
Mesh :: d.Mesh
BufferAllocation :: d.BufferAllocation
Primitive :: d.Primitive
find_bone_by_name :: d.find_bone_by_name
compute_bone_lengths :: d.compute_bone_lengths
sample_clip :: d.sample_clip
sample_clip_with_ik :: d.sample_clip_with_ik
prepare_mesh_data :: d.prepare_mesh_data

mesh_destroy :: proc(self: ^Mesh, world: ^World) {
	_ = world
	skin, has_skin := &self.skinning.?
	if has_skin {
		for &bone in skin.bones do d.bone_destroy(&bone)
		delete(skin.bones)
		delete(skin.bone_lengths)
	}
}

// Initialize mesh CPU data only.
mesh_init :: proc(
	self: ^Mesh,
	geometry_data: geometry.Geometry,
) {
	self.aabb_min = geometry_data.aabb.min
	self.aabb_max = geometry_data.aabb.max
	// Allocations are filled in outside this module after creation.
	if len(geometry_data.skinnings) > 0 {
		self.skinning = Skinning {
			bones      = make([]Bone, 0),
			allocation = {},
		}
	}
}

// Sample and blend multiple animation layers (FK + IK)
// Layers are evaluated in order, with their weights controlling blending
sample_layers :: proc(
	self: ^Mesh,
	world: ^World,
	layers: []animation.Layer,
	ik_targets: []animation.IKTarget,
	out_bone_matrices: []matrix[4, 4]f32,
	delta_time: f32,
	node_world_matrix: matrix[4, 4]f32 = linalg.MATRIX4F32_IDENTITY,
	debug_enabled: bool = false,
) {
	TraverseEntry :: struct {
		parent_transform: matrix[4, 4]f32,
		bone_index:       u32,
	}
	skin, has_skin := &self.skinning.?
	if !has_skin do return
	bone_count := len(skin.bones)
	if len(out_bone_matrices) < bone_count do return
	if len(layers) == 0 do return
	// Temporary storage for accumulating transforms
	accumulated_positions := make([][3]f32, bone_count, context.temp_allocator)
	accumulated_rotations := make(
		[]quaternion128,
		bone_count,
		context.temp_allocator,
	)
	accumulated_scales := make([][3]f32, bone_count, context.temp_allocator)
	accumulated_weights := make([]f32, bone_count, context.temp_allocator)
	for i in 0 ..< bone_count {
		accumulated_positions[i] = {0, 0, 0}
		accumulated_rotations[i] = linalg.QUATERNIONF32_IDENTITY
		accumulated_scales[i] = {0, 0, 0}
		accumulated_weights[i] = 0
	}
	// Sample and accumulate FK layers
	for &layer in layers {
		if layer.weight <= 0 do continue
		#partial switch &layer_data in layer.data {
		case animation.FKLayer:
			// Resolve clip handle at runtime
			clip_handle := transmute(d.ClipHandle)layer_data.clip_handle
			clip := cont.get(world.animation_clips, clip_handle) or_continue
			stack := make(
				[dynamic]TraverseEntry,
				0,
				bone_count,
				context.temp_allocator,
			)
			append(
				&stack,
				TraverseEntry{linalg.MATRIX4F32_IDENTITY, skin.root_bone_index},
			)
			for len(stack) > 0 {
				entry := pop(&stack)
				bone := &skin.bones[entry.bone_index]
				local_transform: geometry.Transform
				if entry.bone_index < u32(len(clip.channels)) {
					local_transform.position, local_transform.rotation, local_transform.scale =
						animation.channel_sample_all(
							clip.channels[entry.bone_index],
							layer_data.time,
						)
				} else {
					local_transform.scale = [3]f32{1, 1, 1}
					local_transform.rotation = linalg.QUATERNIONF32_IDENTITY
				}

				// Check bone mask - skip if bone is masked out
				if mask, has_mask := layer.bone_mask.?; has_mask {
					if entry.bone_index >= u32(len(mask)) || !mask[entry.bone_index] {
						// Skip this bone - continue to children
						for child_index in bone.children {
							append(&stack, TraverseEntry{entry.parent_transform, child_index})
						}
						continue
					}
				}

				// Accumulate weighted transform using blend mode
				w := layer.weight
				accumulated_positions[entry.bone_index] = animation.blend_position(
					accumulated_positions[entry.bone_index],
					local_transform.position,
					w,
					layer.blend_mode,
				)
				accumulated_rotations[entry.bone_index] = animation.blend_rotation(
					accumulated_rotations[entry.bone_index],
					accumulated_weights[entry.bone_index],
					local_transform.rotation,
					w,
					layer.blend_mode,
				)
				accumulated_scales[entry.bone_index] = animation.blend_scale(
					accumulated_scales[entry.bone_index],
					local_transform.scale,
					w,
					layer.blend_mode,
				)
				accumulated_weights[entry.bone_index] += w
				for child_index in bone.children {
					append(&stack, TraverseEntry{entry.parent_transform, child_index})
				}
			}
		case animation.IKLayer:
			// IK layers are applied after FK as post-process (handled below)
			continue
		}
	}
	// Normalize accumulated transforms and compute world transforms
	world_transforms := make(
		[]animation.BoneTransform,
		bone_count,
		context.temp_allocator,
	)
	stack := make([dynamic]TraverseEntry, 0, bone_count, context.temp_allocator)
	append(
		&stack,
		TraverseEntry{linalg.MATRIX4F32_IDENTITY, skin.root_bone_index},
	)
	for len(stack) > 0 {
		entry := pop(&stack)
		bone := &skin.bones[entry.bone_index]
		bone_idx := entry.bone_index
		// Normalize accumulated transforms
		local_matrix := linalg.MATRIX4F32_IDENTITY
		if accumulated_weights[bone_idx] > 0 {
			weight := accumulated_weights[bone_idx]
			position := accumulated_positions[bone_idx] / weight
			rotation := linalg.normalize(accumulated_rotations[bone_idx])
			scale := accumulated_scales[bone_idx] / weight
			local_matrix = linalg.matrix4_from_trs(position, rotation, scale)
		} else {
			bind_world_matrix := linalg.matrix4_inverse(bone.inverse_bind_matrix)
			parent_inv := linalg.matrix4_inverse(entry.parent_transform)
			local_matrix = parent_inv * bind_world_matrix
		}

		// Compute world transform
		world_matrix := entry.parent_transform * local_matrix
		world_transforms[bone_idx].world_matrix = world_matrix
		world_transforms[bone_idx].world_position = world_matrix[3].xyz
		world_transforms[bone_idx].world_rotation = linalg.to_quaternion(
			world_matrix,
		)

		for child_idx in bone.children {
			append(&stack, TraverseEntry{world_matrix, child_idx})
		}
	}

	// Apply procedural modifiers
	procedural_affected_bones := make(
		map[u32]bool,
		bone_count,
		context.temp_allocator,
	)
	for &layer in layers {
		if layer.weight <= 0 do continue
		switch &layer_data in layer.data {
		case animation.ProceduralLayer:
			layer_data.state.accumulated_time += delta_time

			switch &modifier in layer_data.state.modifier {
			case animation.TailModifier:
				animation.tail_modifier_update(
					&layer_data.state,
					&modifier,
					delta_time,
					world_transforms[:],
					layer.weight,
					skin.bone_lengths,
				)
			case animation.PathModifier:
				animation.path_modifier_update(
					&layer_data.state,
					&modifier,
					delta_time,
					world_transforms[:],
					layer.weight,
					skin.bone_lengths,
				)
			case animation.SpiderLegModifier:
				animation.spider_leg_modifier_update(
					&layer_data.state,
					&modifier,
					delta_time,
					world_transforms[:],
					layer.weight,
					skin.bone_lengths,
					node_world_matrix,
					debug_enabled,
				)
			case animation.SingleBoneRotationModifier:
				animation.single_bone_rotation_modifier_update(
					&layer_data.state,
					&modifier,
					delta_time,
					world_transforms[:],
					layer.weight,
					skin.bone_lengths,
				)
			}

			// Track affected bones for child update
			if layer_data.state.bone_indices != nil {
				for bone_idx in layer_data.state.bone_indices {
					procedural_affected_bones[bone_idx] = true
				}
			} else {
				// SingleBoneRotationModifier stores bone_index directly
				#partial switch &modifier in layer_data.state.modifier {
				case animation.SingleBoneRotationModifier:
					procedural_affected_bones[modifier.bone_index] = true
				}
			}
		case animation.FKLayer, animation.IKLayer:
			continue
		}
	}

	// Update child bones after procedural modifiers
	if len(procedural_affected_bones) > 0 {
		update_stack := make(
			[dynamic]TraverseEntry,
			0,
			bone_count,
			context.temp_allocator,
		)
		for bone_idx in procedural_affected_bones {
			bone := &skin.bones[bone_idx]
			parent_world := world_transforms[bone_idx].world_matrix
			for child_idx in bone.children {
				if child_idx in procedural_affected_bones do continue
				append(&update_stack, TraverseEntry{parent_world, child_idx})
			}
		}

		for len(update_stack) > 0 {
			entry := pop(&update_stack)
			bone := &skin.bones[entry.bone_index]
			bone_idx := entry.bone_index

			local_matrix := linalg.MATRIX4F32_IDENTITY
			if accumulated_weights[bone_idx] > 0 {
				weight := accumulated_weights[bone_idx]
				position := accumulated_positions[bone_idx] / weight
				rotation := linalg.normalize(accumulated_rotations[bone_idx])
				scale := accumulated_scales[bone_idx] / weight
				local_matrix = linalg.matrix4_from_trs(position, rotation, scale)
			}
			world_matrix := entry.parent_transform * local_matrix
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

	// Apply IK targets (from both layer-embedded IK and external IK targets)
	all_ik_targets := make(
		[dynamic]animation.IKTarget,
		0,
		context.temp_allocator,
	)

	// Collect IK from layers
	for &layer in layers {
		if layer.weight <= 0 do continue
		#partial switch &layer_data in layer.data {
		case animation.IKLayer:
			target := layer_data.target
			target.weight = layer.weight
			append(&all_ik_targets, target)
		case animation.FKLayer:
			continue
		}
	}

	// Add external IK targets
	for target in ik_targets {
		append(&all_ik_targets, target)
	}

	// Apply all IK
	for target in all_ik_targets {
		if !target.enabled do continue
		animation.fabrik_solve(world_transforms[:], target)
	}

	// Update child bones after IK (same as sample_clip_with_ik)
	if len(all_ik_targets) > 0 {
		affected_bones := make(map[u32]bool, bone_count, context.temp_allocator)
		for target in all_ik_targets {
			if !target.enabled do continue
			for bone_idx in target.bone_indices {
				affected_bones[bone_idx] = true
			}
		}

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
			if accumulated_weights[bone_idx] > 0 {
				weight := accumulated_weights[bone_idx]
				position := accumulated_positions[bone_idx] / weight
				rotation := linalg.normalize(accumulated_rotations[bone_idx])
				scale := accumulated_scales[bone_idx] / weight
				local_matrix = linalg.matrix4_from_trs(position, rotation, scale)
			}
			world_matrix := entry.parent_transform * local_matrix
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

	// Compute final skinning matrices
	for i in 0 ..< bone_count {
		out_bone_matrices[i] = world_transforms[i].world_matrix * skin.bones[i].inverse_bind_matrix
	}
}

// Creates mesh in resource pool - geometry allocation handled by caller.
// Creates mesh in resource pool WITHOUT geometry allocation
// Geometry buffers are allocated outside this module.
// This is now an internal function used by higher-level allocation paths.
create_mesh :: proc(
	world: ^World,
	geometry_data: geometry.Geometry,
	auto_purge: bool = false,
) -> (
	handle: d.MeshHandle,
	mesh: ^Mesh,
	ok: bool,
) {
	handle, mesh, ok = cont.alloc(&world.meshes, d.MeshHandle)
	if !ok do return
	mesh_init(mesh, geometry_data)
	mesh.auto_purge = auto_purge
	return handle, mesh, true
}

@(private = "file")
sync_mesh_data :: proc(
	mesh: ^Mesh,
) {
	d.prepare_mesh_data(mesh)
}

destroy_mesh :: proc(self: ^World, handle: d.MeshHandle) {
	if mesh, ok := cont.free(&self.meshes, handle); ok {
		mesh_destroy(mesh, self)
	}
}

// Reference counting functions
mesh_ref :: proc(world: ^World, handle: d.MeshHandle) -> bool {
	mesh := cont.get(world.meshes, handle) or_return
	mesh.ref_count += 1
	return true
}

mesh_unref :: proc(
	world: ^World,
	handle: d.MeshHandle,
) -> (
	ref_count: u32,
	ok: bool,
) #optional_ok {
	mesh := cont.get(world.meshes, handle) or_return
	if mesh.ref_count == 0 {
		return 0, true
	}
	mesh.ref_count -= 1
	return mesh.ref_count, true
}

purge_unused_meshes :: proc(
	world: ^World,
) -> (
	purged_count: int,
) {
	for &entry, i in world.meshes.entries do if entry.active {
		if entry.item.auto_purge && entry.item.ref_count == 0 {
			handle := cont.Handle {
				index      = u32(i),
				generation = entry.generation,
			}
			mesh, freed := cont.free(&world.meshes, handle)
			if freed {
				mesh_destroy(mesh, world)
				purged_count += 1
			}
		}
	}
	if purged_count > 0 {
		log.infof("Purged %d unused meshes", purged_count)
	}
	return
}

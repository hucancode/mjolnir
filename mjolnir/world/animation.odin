package world

import cont "../containers"
import anim "../animation"
import "../geometry"
import "../gpu"
import "../resources"
import "core:math/linalg"
import "core:slice"

// Update all skeletal animations for nodes with mesh attachments
update_skeletal_animations :: proc(
	world: ^World,
	rm: ^resources.Manager,
	delta_time: f32,
) {
	if delta_time <= 0 {
		return
	}
	bone_buffer := &rm.bone_buffer
	if bone_buffer.mapped == nil {
		return
	}

	for &entry in world.nodes.entries do if entry.active {
		node := &entry.item
		mesh_attachment, has_mesh := node.attachment.(MeshAttachment)
		if !has_mesh do continue
		skinning, has_skin := mesh_attachment.skinning.?
		if !has_skin do continue
		if len(skinning.layers) == 0 do continue

		mesh := cont.get(rm.meshes, mesh_attachment.handle) or_continue
		mesh_skinning, mesh_has_skin := mesh.skinning.?
		if !mesh_has_skin do continue

		bone_count := len(mesh_skinning.bones)
		if bone_count == 0 do continue
		if skinning.bone_matrix_buffer_offset == 0xFFFFFFFF do continue

		// Update all layers
		for &layer in skinning.layers {
			anim.layer_update(&layer, delta_time)
		}

		matrices_ptr := gpu.mutable_buffer_get(bone_buffer, skinning.bone_matrix_buffer_offset)
		matrices := slice.from_ptr(matrices_ptr, bone_count)

		// Resolve IK configs into runtime IK targets (legacy support)
		ik_targets: [dynamic]anim.IKTarget
		if len(mesh_attachment.ik_configs) > 0 {
			ik_targets = _resolve_ik_targets(
				&mesh_attachment.ik_configs,
				mesh,
				&node.transform,
			)
		}

		// Sample and blend all layers
		resources.sample_layers(mesh, skinning.layers[:], ik_targets[:], matrices)

		// Write back updated skinning state
		mesh_attachment.skinning = skinning
		node.attachment = mesh_attachment
	}
}

// Update all sprite animations
update_sprite_animations :: proc(
	rm: ^resources.Manager,
	delta_time: f32,
) {
	if delta_time <= 0 do return

	active_count := len(rm.sprites.entries) - len(rm.sprites.free_indices)
	if active_count == 0 do return

	for &entry, i in rm.sprites.entries {
		if !entry.active do continue
		sprite := &entry.item
		anim_inst, has_anim := &sprite.animation.?
		if !has_anim do continue

		resources.sprite_animation_update(anim_inst, delta_time)

		handle := resources.Handle {
			index      = u32(i),
			generation = entry.generation,
		}
		resources.sprite_write_to_gpu(rm, handle, sprite)
	}
}

// Resolve IK configs (world-space) into runtime IK targets (skeleton-local space)
@(private = "file")
_resolve_ik_targets :: proc(
	configs: ^[dynamic]IKConfig,
	mesh: ^resources.Mesh,
	node_transform: ^geometry.Transform,
) -> [dynamic]anim.IKTarget {
	ik_targets := make(
		[dynamic]anim.IKTarget,
		0,
		len(configs),
		context.temp_allocator,
	)

	// Get node's world transform inverse to convert IK targets to skeleton-local space
	node_world_inv := linalg.matrix4_inverse(node_transform.world_matrix)

	for &config in configs {
		if !config.enabled do continue

		// Resolve all bone names to indices
		bone_indices := make([]u32, len(config.bone_names), context.temp_allocator)
		all_found := true
		for name, i in config.bone_names {
			idx, ok := resources.find_bone_by_name(mesh, name)
			if !ok {
				all_found = false
				break
			}
			bone_indices[i] = idx
		}

		if !all_found do continue

		// Transform IK target from world space to skeleton-local space
		target_world_h := linalg.Vector4f32 {
			config.target_position.x,
			config.target_position.y,
			config.target_position.z,
			1.0,
		}
		pole_world_h := linalg.Vector4f32 {
			config.pole_position.x,
			config.pole_position.y,
			config.pole_position.z,
			1.0,
		}

		target_local_h := node_world_inv * target_world_h
		pole_local_h := node_world_inv * pole_world_h

		target_local := target_local_h.xyz
		pole_local := pole_local_h.xyz

		// Build runtime IK target in skeleton-local space
		ik_target := anim.IKTarget {
			bone_indices    = bone_indices,
			target_position = target_local,
			pole_vector     = pole_local,
			max_iterations  = config.max_iterations,
			tolerance       = config.tolerance,
			weight          = config.weight,
			enabled         = true,
		}

		append(&ik_targets, ik_target)
	}

	return ik_targets
}

package main

import "../../../mjolnir"
import "../../../mjolnir/resources"
import "../../../mjolnir/world"
import anim "../../../mjolnir/animation"
import cont "../../../mjolnir/containers"
import "../../../mjolnir/gpu"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:slice"

root_nodes: [dynamic]resources.NodeHandle
markers: [dynamic]resources.NodeHandle
animation_time: f32 = 0
spider_leg_nodes: [8]resources.NodeHandle
target_markers: [8]resources.NodeHandle
ground_plane: resources.NodeHandle

main :: proc() {
	context.logger = log.create_console_logger()
	engine := new(mjolnir.Engine)
	engine.setup_proc = proc(engine: ^mjolnir.Engine) {
		using mjolnir
		if camera := get_main_camera(engine); camera != nil {
			camera_look_at(camera, {0, 80, 120}, {0, 0, 0})
			sync_active_camera_controller(engine)
		}
		// Load 8 spider leg models
		leg_offsets := [8][3]f32{
			{3, 0, 2},   // Front right
			{1, 0, 3},   // Mid-front right
			{-1, 0, 3},  // Mid-back right
			{-3, 0, 2},  // Back right
			{3, 0, -2},  // Front left
			{1, 0, -3},  // Mid-front left
			{-1, 0, -3}, // Mid-back left
			{-3, 0, -2}, // Back left
		}

		lift_frequency :: 0.8
		for i in 0..<8 {
			leg_roots := load_gltf(engine, "assets/spider_leg.glb")
			for handle in leg_roots {
				node := get_node(engine, handle) or_continue
				node.transform.position = {0, 2, 0}
				node.transform.is_dirty = true

				for child in node.children {
					spider_leg_nodes[i] = child

					leg_root_names := []string{"root"}
					leg_chain_lengths := []u32{7}

					leg_configs := []anim.SpiderLegConfig{
						{
							initial_offset = leg_offsets[i],
							lift_height = 2.0,
							lift_frequency = lift_frequency,
							lift_duration = 0.6,
							time_offset = f32(i) * (lift_frequency / 8.0),
						},
					}

					success := world.add_spider_leg_modifier_layer(
						&engine.world,
						&engine.rm,
						child,
						leg_root_names,
						leg_chain_lengths,
						leg_configs,
						weight = 1.0,
						layer_index = -1,
					)
					if success {
						log.infof("Added spider leg modifier %d", i)
					}
				}
			}
			append(&root_nodes, ..leg_roots[:])
		}

		// Create cone markers for each bone
		cone_mesh := engine.rm.builtin_meshes[resources.Primitive.CONE]
		mat := engine.rm.builtin_materials[resources.Color.YELLOW]

		// Find the skinned mesh and create markers for bones
		for handle in root_nodes {
			node := get_node(engine, handle) or_continue
			log.infof("Root node found")
			for child in node.children {
				child_node := get_node(engine, child) or_continue
				log.infof("Child node found")
				mesh_attachment, has_mesh := &child_node.attachment.(world.MeshAttachment)
				if !has_mesh {
					log.infof("Child has no mesh attachment")
					continue
				}

				mesh := cont.get(engine.rm.meshes, mesh_attachment.handle) or_continue
				log.infof("Mesh found")

				skin, has_skin := mesh.skinning.?
				if !has_skin {
					log.infof("Mesh has no skinning data")
					continue
				}

				log.infof("Found skinned mesh with %d bones", len(skin.bones))

				// Debug: print bone names to understand hierarchy
				for bone, idx in skin.bones {
					log.infof("Bone[%d]: name='%s'", idx, bone.name)
				}

				// Create one marker per bone
				for i in 0 ..< len(skin.bones) {
					marker := spawn(
						engine,
						attachment = world.MeshAttachment{
							handle = cone_mesh,
							material = mat,
						},
					)
					scale(engine, marker, 0.15)
					append(&markers, marker)
					log.infof("Created marker %d at default position", i)
				}

				log.infof("Total markers created: %d", len(markers))
			}
		}

		// Create visual markers for each leg target (red spheres)
		sphere_mesh := engine.rm.builtin_meshes[resources.Primitive.SPHERE]
		red_mat := engine.rm.builtin_materials[resources.Color.RED]
		for i in 0..<8 {
			target_markers[i] = spawn(
				engine,
				attachment = world.MeshAttachment{
					handle = sphere_mesh,
					material = red_mat,
				},
			)
			scale(engine, target_markers[i], 0.2)
		}

		// Ground plane for reference
		cube_mesh := engine.rm.builtin_meshes[resources.Primitive.CUBE]
		gray_mat := engine.rm.builtin_materials[resources.Color.GRAY]
		ground_plane = spawn(
			engine,
			attachment = world.MeshAttachment{
				handle = cube_mesh,
				material = gray_mat,
			},
		)
		world.scale_xyz(&engine.world, ground_plane, 20, 0.2, 20)
		spawn_directional_light(engine, {1.0, 1.0, 1.0, 1.0})
	}
	engine.update_proc = proc(engine: ^mjolnir.Engine, delta_time: f32) {
		using mjolnir

		// Move the spider body back and forth along the X axis
		animation_time += delta_time
		amplitude :: 10.0 // How far to move left/right
		speed :: 0.1 // Oscillation speed (Hz)

		body_x := amplitude * math.sin(animation_time * speed * 2 * math.PI)
		body_pos := [3]f32{body_x, 2, 0}

		// Move the spider body
		for handle in root_nodes {
			if node := get_node(engine, handle); node != nil {
				node.transform.position = body_pos
				node.transform.is_dirty = true
			}
		}

		// Target is now automatically computed from leg root + offset in world space
		// Fetch and display the world-space target for each leg
		for i in 0..<8 {
			if target, ok := world.get_spider_leg_target(
				&engine.world,
				spider_leg_nodes[i],
				layer_index = 0,
				leg_index = 0,
			); ok {
				if marker_node := get_node(engine, target_markers[i]); marker_node != nil {
					marker_node.transform.position = target^
					marker_node.transform.is_dirty = true
				}
			}
		}

		// Update bone markers
		marker_idx := 0
		for handle in root_nodes {
			node := get_node(engine, handle) or_continue
			for child in node.children {
				child_node := get_node(engine, child) or_continue
				mesh_attachment, has_mesh := &child_node.attachment.(world.MeshAttachment)
				if !has_mesh {
					continue
				}
				skinning, has_skinning := mesh_attachment.skinning.?
				if !has_skinning {
					continue
				}

				mesh := cont.get(engine.rm.meshes, mesh_attachment.handle) or_continue
				skin := mesh.skinning.? or_continue

				// Get bone matrices from GPU buffer
				frame_index := engine.frame_index
				bone_buffer := &engine.rm.bone_buffer.buffers[frame_index]
				if bone_buffer.mapped == nil {
					continue
				}
				bone_count := len(skin.bones)
				if skinning.bone_matrix_buffer_offset == 0xFFFFFFFF {
					continue
				}
				matrices_ptr := gpu.get(bone_buffer, skinning.bone_matrix_buffer_offset)
				bone_matrices := slice.from_ptr(matrices_ptr, bone_count)
				for i in 0 ..< bone_count {
					if marker_idx >= len(markers) do break
					// Read skinning matrix from GPU buffer
					skinning_matrix := bone_matrices[i]
					// Convert skinning matrix to world matrix
					// skinning_matrix = world_matrix * inverse_bind_matrix
					// world_matrix = skinning_matrix * bind_matrix
					bind_matrix := linalg.matrix4_inverse(skin.bones[i].inverse_bind_matrix)
					bone_local_world := skinning_matrix * bind_matrix
					// Apply node's world transform
					node_world := child_node.transform.world_matrix
					bone_world := node_world * bone_local_world
					bone_pos := bone_world[3].xyz
					bone_rot := linalg.to_quaternion(bone_world)
					// Update marker transform
					marker := get_node(engine, markers[marker_idx]) or_continue
					marker.transform.position = bone_pos
					marker.transform.rotation = bone_rot
					marker.transform.is_dirty = true

					marker_idx += 1
				}
			}
		}
	}
	mjolnir.run(engine, 800, 600, "visual-spider-leg-modifier")
}

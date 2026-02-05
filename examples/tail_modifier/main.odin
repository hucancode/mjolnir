package main

import "../../mjolnir"
import "../../mjolnir/resources"
import "../../mjolnir/world"
import anim "../../mjolnir/animation"
import cont "../../mjolnir/containers"
import "../../mjolnir/gpu"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:slice"

root_nodes: [dynamic]resources.NodeHandle
markers: [dynamic]resources.NodeHandle
animation_time: f32 = 0
snake_child_node: resources.NodeHandle
root_bone_modifier: ^anim.SingleBoneRotationModifier

main :: proc() {
  context.logger = log.create_console_logger()
  engine := new(mjolnir.Engine)
  engine.setup_proc = proc(engine: ^mjolnir.Engine) {
    if camera := mjolnir.get_main_camera(engine); camera != nil {
      mjolnir.camera_look_at(camera, {0, 100, 150}, {0, 30, 0})
      mjolnir.sync_active_camera_controller(engine)
    }
    root_nodes = mjolnir.load_gltf(engine, "assets/stuffed_snake_rigged.glb")
    for handle in root_nodes {
      node := mjolnir.get_node(engine, handle) or_continue
      for child in node.children {
        snake_child_node = child // Store for animation

        // Add single bone rotation modifier to control the root bone
        root_bone_modifier = world.add_single_bone_rotation_modifier_layer(
          &engine.world,
          &engine.rm,
          child,
          bone_name = "root",
          weight = 1.0,
          layer_index = -1,
        ) or_else nil
        if root_bone_modifier != nil {
          log.infof("Added root bone rotation modifier")
        }

        // Add tail modifier layer (reacts to root bone rotation)
        // propagation_speed: how strongly bones react to parent changes (0-1)
        //   Higher = stronger immediate reaction to parent
        // damping: how quickly bones return to rest pose (0-1, higher = slower)
        //   Higher = slower return, longer wave propagation
        // reverse_chain: if true, reverses bone order so bone[0] is driver
        //   Use true when root bone is at tail end (need head→tail order)
        success := world.add_tail_modifier_layer(
          &engine.world,
          &engine.rm,
          child,
          root_bone_name = "root",
          tail_length = 10,
          propagation_speed = 0.85, // Strong counter-rotation creates visible drag
          damping = 0.1, // Slow return creates wave propagation
          weight = 1.0,
          reverse_chain = false,
        )
        if success {
          log.infof("Added tail modifier to node")
        }
      }
    }

    // Create cone markers for each bone
    cone_mesh := engine.rm.builtin_meshes[resources.Primitive.CONE]
    mat := engine.rm.builtin_materials[resources.Color.YELLOW]

    // Find the skinned mesh and create markers for bones
    for handle in root_nodes {
      node := mjolnir.get_node(engine, handle) or_continue
      log.infof("Root node found")
      for child in node.children {
        child_node := mjolnir.get_node(engine, child) or_continue
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
          marker := mjolnir.spawn(
            engine,
            attachment = world.MeshAttachment {
              handle = cone_mesh,
              material = mat,
            },
          )
          mjolnir.scale(engine, marker, 0.2)
          append(&markers, marker)
          log.infof("Created marker %d at default position", i)
        }

        log.infof("Total markers created: %d", len(markers))
      }
    }

    mjolnir.spawn_directional_light(engine, {1.0, 1.0, 1.0, 1.0})
    mjolnir.spawn_point_light(
      engine,
      {1.0, 0.9, 0.8, 1.0},
      1000.0,
      position = {0, 50, 50},
    )
  }
  engine.update_proc = proc(engine: ^mjolnir.Engine, delta_time: f32) {
    // Animate the root bone directly via the single bone rotation modifier
    // This creates motion that the tail modifier will react to
    animation_time += delta_time
    frequency :: 0.5 // Hz - oscillation speed
    amplitude :: math.PI * 0.35 // Radians - swing angle
    target_angle := amplitude * math.sin(animation_time * frequency * 2 * math.PI)

    // Update the root bone rotation via the modifier
    if root_bone_modifier != nil {
      axis := linalg.Vector3f32{0, 1, 0}
      root_bone_modifier.rotation = linalg.quaternion_angle_axis_f32(target_angle, axis)
    }

    marker_idx := 0
    for handle in root_nodes {
      node := mjolnir.get_node(engine, handle) or_continue
      for child in node.children {
        child_node := mjolnir.get_node(engine, child) or_continue
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
          marker := mjolnir.get_node(engine, markers[marker_idx]) or_continue
          marker.transform.position = bone_pos
          marker.transform.rotation = bone_rot
          marker.transform.is_dirty = true

          marker_idx += 1
        }
      }
    }
  }
  mjolnir.run(engine, 800, 600, "visual-tail-modifier")
}

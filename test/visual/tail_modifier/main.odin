package main

import "../../../mjolnir"
import "../../../mjolnir/resources"
import "../../../mjolnir/world"
import cont "../../../mjolnir/containers"
import "../../../mjolnir/gpu"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:slice"

root_nodes: [dynamic]resources.NodeHandle
markers: [dynamic]resources.NodeHandle

main :: proc() {
  context.logger = log.create_console_logger()
  engine := new(mjolnir.Engine)
  engine.setup_proc = proc(engine: ^mjolnir.Engine) {
    using mjolnir
    if camera := get_main_camera(engine); camera != nil {
      camera_look_at(camera, {0, 100, 150}, {0, 30, 0})
      sync_active_camera_controller(engine)
    }
    root_nodes = load_gltf(engine, "assets/stuffed_snake_rigged.glb")
    for handle in root_nodes {
      node := get_node(engine, handle) or_continue
      for child in node.children {
        success := world.add_tail_modifier_layer(
          &engine.world,
          &engine.rm,
          child,
          root_bone_name = "root",
          tail_length = 10,
          frequency = 0.8,
          amplitude = 1.4,
          propagation_speed = 0.5,
          damping = 0.5,
          weight = 1.0,
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

        // Create one marker per bone
        for i in 0 ..< len(skin.bones) {
          marker := spawn(
            engine,
            attachment = world.MeshAttachment {
              handle = cone_mesh,
              material = mat,
            },
          )
          scale(engine, marker, 0.08)
          append(&markers, marker)
          log.infof("Created marker %d at default position", i)
        }

        log.infof("Total markers created: %d", len(markers))
      }
    }

    spawn_directional_light(engine, {1.0, 1.0, 1.0, 1.0})
    spawn_point_light(
      engine,
      {1.0, 0.9, 0.8, 1.0},
      1000.0,
      position = {0, 50, 50},
    )
  }
  engine.update_proc = proc(engine: ^mjolnir.Engine, delta_time: f32) {
    using mjolnir
    rotation := delta_time * math.PI * 0.1
    for handle in root_nodes {
      mjolnir.rotate_by(engine, handle, rotation)
    }

    // Update marker positions to match bone transforms
    if engine.frame_index < 5 {
      log.infof("Frame %d: Starting marker update, total markers: %d", engine.frame_index, len(markers))

      // Debug: Print first few marker positions
      for i in 0 ..< min(5, len(markers)) {
        marker := get_node(engine, markers[i]) or_continue
        log.infof("  Marker %d position: %v", i, marker.transform.position)
      }
    }

    marker_idx := 0
    for handle in root_nodes {
      node := get_node(engine, handle) or_continue
      for child in node.children {
        child_node := get_node(engine, child) or_continue

        if engine.frame_index < 5 {
          log.infof("Frame %d: Processing child node, attachment type: %v", engine.frame_index, child_node.attachment)
        }

        mesh_attachment, has_mesh := &child_node.attachment.(world.MeshAttachment)
        if !has_mesh {
          if engine.frame_index < 5 {
            log.warnf("Frame %d: Child has no mesh attachment in update (type is %v)", engine.frame_index, child_node.attachment)
          }
          continue
        }

        skinning, has_skinning := mesh_attachment.skinning.?
        if !has_skinning {
          if engine.frame_index < 5 {
            log.warnf("Frame %d: No skinning data in mesh_attachment", engine.frame_index)
          }
          continue
        }

        mesh := cont.get(engine.rm.meshes, mesh_attachment.handle) or_continue
        skin := mesh.skinning.? or_continue

        // Get bone matrices from GPU buffer
        frame_index := engine.frame_index
        bone_buffer := &engine.rm.bone_buffer.buffers[frame_index]
        if bone_buffer.mapped == nil {
          if engine.frame_index < 5 {
            log.warnf("Frame %d: Bone buffer not mapped", engine.frame_index)
          }
          continue
        }

        bone_count := len(skin.bones)
        if skinning.bone_matrix_buffer_offset == 0xFFFFFFFF {
          if engine.frame_index < 5 {
            log.warnf("Frame %d: Invalid bone matrix buffer offset", engine.frame_index)
          }
          continue
        }

        if engine.frame_index < 5 {
          log.infof("Frame %d: Updating %d markers from bone data", engine.frame_index, bone_count)
        }

        // Get bone matrices using gpu.get
        matrices_ptr := gpu.get(bone_buffer, skinning.bone_matrix_buffer_offset)
        bone_matrices := slice.from_ptr(matrices_ptr, bone_count)

        // Read bone transforms
        for i in 0 ..< bone_count {
          if marker_idx >= len(markers) do break

          // Read skinning matrix from GPU buffer
          skinning_matrix := bone_matrices[i]

          if engine.frame_index < 3 && i < 3 {
            log.infof("Frame %d Bone %d: skinning_matrix[3] = %v", engine.frame_index, i, skinning_matrix[3])
            log.infof("Frame %d Bone %d: inverse_bind[3] = %v", engine.frame_index, i, skin.bones[i].inverse_bind_matrix[3])
          }

          // Convert skinning matrix to world matrix
          // skinning_matrix = world_matrix * inverse_bind_matrix
          // world_matrix = skinning_matrix * bind_matrix
          bind_matrix := linalg.matrix4_inverse(skin.bones[i].inverse_bind_matrix)

          if engine.frame_index < 3 && i < 3 {
            log.infof("Frame %d Bone %d: bind_matrix[3] = %v", engine.frame_index, i, bind_matrix[3])
          }

          bone_local_world := skinning_matrix * bind_matrix

          if engine.frame_index < 3 && i < 3 {
            log.infof("Frame %d Bone %d: bone_local_world[3] = %v", engine.frame_index, i, bone_local_world[3])
          }

          // Apply node's world transform
          node_world := child_node.transform.world_matrix
          bone_world := node_world * bone_local_world

          bone_pos := bone_world[3].xyz
          bone_rot := linalg.to_quaternion(bone_world)

          if engine.frame_index < 3 && i < 3 {
            log.infof("Frame %d Bone %d: final pos = %v", engine.frame_index, i, bone_pos)
          }

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
  mjolnir.run(engine, 800, 600, "visual-tail-modifier")
}

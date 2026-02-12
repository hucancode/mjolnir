package main

import "../../mjolnir"
import anim "../../mjolnir/animation"
import cont "../../mjolnir/containers"
import "../../mjolnir/gpu"
import "../../mjolnir/world"
import "../../mjolnir/render"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:slice"

root_nodes: [dynamic]mjolnir.NodeHandle
markers: [dynamic]mjolnir.NodeHandle
animation_time: f32 = 0
spider_root_node: mjolnir.NodeHandle
target_markers: [6]mjolnir.NodeHandle
ground_plane: mjolnir.NodeHandle

main :: proc() {
  context.logger = log.create_console_logger()
  engine := new(mjolnir.Engine)
  engine.setup_proc = proc(engine: ^mjolnir.Engine) {
    // Enable IK debug drawing
    // engine.world.debug_draw_ik = true // Removed: debug_draw_ik no longer available

    if camera := mjolnir.get_main_camera(engine); camera != nil {
      mjolnir.camera_look_at(camera, {0, 80, 120}, {0, 0, 0})
      mjolnir.sync_active_camera_controller(engine)
    }
    // Load spider model with 6 legs
    spider_roots := mjolnir.load_gltf(engine, "assets/spider.glb")
    append(&root_nodes, ..spider_roots[:])

    // Position the spider
    for handle in spider_roots {
      spider_root_node = handle
      mjolnir.translate(engine, handle, y=5)
    }

    // Configure 6 legs with spider leg modifiers
    // Each leg has 6 bones (bone_0 to bone_5)
    // Time offsets arranged for diagonal alternating pairs:
    // - Pair 1 (0.0): Front right + Back left
    // - Pair 2 (0.33): Middle right + Middle left
    // - Pair 3 (0.67): Front left + Back right
    leg_configs := []struct {
      root_name:      string,
      tip_name:       string,
      initial_offset: [3]f32,
      time_offset:    f32,
    } {
      {"leg_front_r_0", "leg_front_r_5", {0, 0, 0}, 0.0}, // Front right
      {"leg_middle_r_0", "leg_middle_r_5", {0, 0, 0}, 0.33}, // Middle right
      {"leg_back_r_0", "leg_back_r_5", {0, 0, 0}, 0.67}, // Back right
      {"leg_front_l_0", "leg_front_l_5", {0, 0, 0}, 0.67}, // Front left
      {"leg_middle_l_0", "leg_middle_l_5", {0, 0, 0}, 0.33}, // Middle left
      {"leg_back_l_0", "leg_back_l_5", {0, 0, 0}, 0.0}, // Back left
    }

    lift_frequency :: 0.8

    // Find the skinned mesh node and calculate initial offsets from rest pose
    for handle in spider_roots {
      root_node := mjolnir.get_node(engine, handle) or_continue

      // Find the child with the mesh attachment
      for child in root_node.children {
        child_node := mjolnir.get_node(engine, child) or_continue
        mesh_attachment, has_mesh := &child_node.attachment.(world.MeshAttachment)
        if !has_mesh {
          continue
        }

        // Get the mesh and skin data to calculate rest pose positions
        mesh := cont.get(engine.world.meshes, mesh_attachment.handle) or_continue
        skin, has_skin := mesh.skinning.?
        if !has_skin {
          continue
        }

        // Calculate initial offsets from rest pose
        for i in 0 ..< 6 {
          root_bone_idx := -1
          tip_bone_idx := -1

          // Find root and tip bones for this leg
          for bone, idx in skin.bones {
            if bone.name == leg_configs[i].root_name {
              root_bone_idx = idx
            }
            if bone.name == leg_configs[i].tip_name {
              tip_bone_idx = idx
            }
          }

          if root_bone_idx >= 0 && tip_bone_idx >= 0 {
            // Get bind matrices (rest pose)
            root_bind := linalg.matrix4_inverse(
              skin.bones[root_bone_idx].inverse_bind_matrix,
            )
            tip_bind := linalg.matrix4_inverse(
              skin.bones[tip_bone_idx].inverse_bind_matrix,
            )

            // Extract positions
            root_pos := root_bind[3].xyz
            tip_pos := tip_bind[3].xyz

            // Calculate offset from root to tip in local space
            offset := tip_pos - root_pos
            leg_configs[i].initial_offset = offset

            log.infof(
              "Leg %s: calculated offset = %v (root at %v, tip at %v)",
              leg_configs[i].root_name,
              offset,
              root_pos,
              tip_pos,
            )
          } else {
            log.warnf(
              "Could not find bones for leg %s (root_idx=%d, tip_idx=%d)",
              leg_configs[i].root_name,
              root_bone_idx,
              tip_bone_idx,
            )
          }
        }

        // Build arrays for all 6 leg roots and configurations
        leg_root_names := make([]string, 6)
        leg_chain_lengths := make([]u32, 6)
        spider_leg_configs := make([]anim.SpiderLegConfig, 6)

        for i in 0 ..< 6 {
          leg_root_names[i] = leg_configs[i].root_name
          leg_chain_lengths[i] = 6 // Each leg has 6 bones

          spider_leg_configs[i] = anim.SpiderLegConfig {
            initial_offset = leg_configs[i].initial_offset,
            lift_height    = 0.5,
            lift_frequency = lift_frequency,
            lift_duration  = 0.6,
            time_offset    = leg_configs[i].time_offset,
          }
        }

        success := world.add_spider_leg_modifier_layer(
          &engine.world,
          child,
          leg_root_names,
          leg_chain_lengths,
          spider_leg_configs,
          weight = 1.0,
          layer_index = -1,
        )

        if success {
          log.infof("Added spider leg modifiers for all 6 legs")
        }

        break
      }
    }

    // Create cone markers for each bone
    cone_mesh := mjolnir.get_builtin_mesh(engine, .CONE)
    mat := mjolnir.get_builtin_material(engine, .YELLOW)

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

        mesh := cont.get(engine.world.meshes, mesh_attachment.handle) or_continue
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
          mjolnir.scale(engine, marker, 0.15)
          append(&markers, marker)
          log.infof("Created marker %d at default position", i)
        }

        log.infof("Total markers created: %d", len(markers))
      }
    }

    // Create visual markers for each leg target (red spheres)
    sphere_mesh := mjolnir.get_builtin_mesh(engine, .SPHERE)
    red_mat := mjolnir.get_builtin_material(engine, .RED)
    for i in 0 ..< 6 {
      target_markers[i] = mjolnir.spawn(
        engine,
        attachment = world.MeshAttachment {
          handle = sphere_mesh,
          material = red_mat,
        },
      )
      mjolnir.scale(engine, target_markers[i], 0.2)
    }

    // Ground plane for reference
    cube_mesh := mjolnir.get_builtin_mesh(engine, .CUBE)
    gray_mat := mjolnir.get_builtin_material(engine, .GRAY)
    ground_plane = mjolnir.spawn(
      engine,
      attachment = world.MeshAttachment {
        handle = cube_mesh,
        material = gray_mat,
      },
    )
    world.scale_xyz(&engine.world, ground_plane, 20, 0.2, 20)
    mjolnir.spawn_directional_light(engine, {1.0, 1.0, 1.0, 1.0})
  }
  engine.update_proc = proc(engine: ^mjolnir.Engine, delta_time: f32) {
    // Move the spider body back and forth along the X axis
    animation_time += delta_time
    amplitude :: 8.0 // How far to move left/right
    speed :: 0.1 // Oscillation speed (Hz)

    body_x := amplitude * math.sin(animation_time * speed * 2 * math.PI)
    body_pos := [3]f32{body_x, 2, 0}

    // Move the spider body
    if node := mjolnir.get_node(engine, spider_root_node); node != nil {
      node.transform.position = body_pos
      node.transform.is_dirty = true
    }

    // Target is now automatically computed from leg root + offset in world space
    // Fetch and display the world-space target for each leg
    // Find the skinned mesh child to query leg targets
    if root_node := mjolnir.get_node(engine, spider_root_node); root_node != nil {
      for child in root_node.children {
        child_node := mjolnir.get_node(engine, child) or_continue
        _, has_mesh := &child_node.attachment.(world.MeshAttachment)
        if !has_mesh {
          continue
        }

        for i in 0 ..< 6 {
          if target, ok := world.get_spider_leg_target(
            &engine.world,
            child,
            layer_index = 0,
            leg_index = i,
          ); ok {
            if marker_node := mjolnir.get_node(engine, target_markers[i]);
               marker_node != nil {
              marker_node.transform.position = target^
              marker_node.transform.is_dirty = true
            }
          }
        }

        break
      }
    }

    // Update bone markers
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

        mesh := cont.get(engine.world.meshes, mesh_attachment.handle) or_continue
        skin := mesh.skinning.? or_continue

        // Get bone matrices from GPU buffer
        frame_index := engine.frame_index
        bone_buffer := &engine.render.bone_buffer.buffers[frame_index]
        if bone_buffer.mapped == nil {
          continue
        }
        bone_count := len(skin.bones)
        bone_matrix_buffer_offset, has_offset := engine.render.bone_matrix_offsets[transmute(render.NodeHandle)child]
        if !has_offset {
          continue
        }
        matrices_ptr := gpu.get(
          bone_buffer,
          bone_matrix_buffer_offset,
        )
        bone_matrices := slice.from_ptr(matrices_ptr, bone_count)
        for i in 0 ..< bone_count {
          if marker_idx >= len(markers) do break
          // Read skinning matrix from GPU buffer
          skinning_matrix := bone_matrices[i]
          // Convert skinning matrix to world matrix
          // skinning_matrix = world_matrix * inverse_bind_matrix
          // world_matrix = skinning_matrix * bind_matrix
          bind_matrix := linalg.matrix4_inverse(
            skin.bones[i].inverse_bind_matrix,
          )
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
  mjolnir.run(engine, 800, 600, "spider-leg-modifier")
}

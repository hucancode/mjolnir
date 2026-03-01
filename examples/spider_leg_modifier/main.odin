package main

import "../../mjolnir"
import anim "../../mjolnir/animation"
import cont "../../mjolnir/containers"
import "../../mjolnir/gpu"
import "../../mjolnir/render"
import "../../mjolnir/world"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:slice"

root_nodes: [dynamic]world.NodeHandle
animation_time: f32 = 0
spider_root_node: world.NodeHandle
target_markers: [6]world.NodeHandle
ground_plane: world.NodeHandle

main :: proc() {
  context.logger = log.create_console_logger()
  engine := new(mjolnir.Engine)
  engine.setup_proc = proc(engine: ^mjolnir.Engine) {
    world.main_camera_look_at(
      &engine.world,
      {0, 80, 120},
      {0, 0, 0},
    )
    // Load spider model with 6 legs
    spider_roots := mjolnir.load_gltf(engine, "assets/spider.glb")
    append(&root_nodes, ..spider_roots[:])

    // Position the spider
    for handle in spider_roots {
      spider_root_node = handle
      world.translate(&engine.world, handle, y = 5)
    }

    // Configure 6 legs with spider leg modifiers
    // Each leg has 6 bones (bone_0 to bone_5)
    // Time offsets arranged for diagonal alternating pairs:
    lift_frequency :: 1.5
    half_frequency :: lift_frequency * 0.5
    leg_configs := []struct {
      root_name:      string,
      tip_name:       string,
      initial_offset: [3]f32,
      time_offset:    f32,
    } {
      {"leg_front_r_0", "leg_front_r_5", {0, 0, 0}, 0.0}, // Front right
      {"leg_middle_r_0", "leg_middle_r_5", {0, 0, 0}, half_frequency }, // Middle right
      {"leg_back_r_0", "leg_back_r_5", {0, 0, 0}, 0.0}, // Back right
      {"leg_front_l_0", "leg_front_l_5", {0, 0, 0}, half_frequency }, // Front left
      {"leg_middle_l_0", "leg_middle_l_5", {0, 0, 0}, 0.0}, // Middle left
      {"leg_back_l_0", "leg_back_l_5", {0, 0, 0}, half_frequency }, // Back left
    }


    // Find the skinned mesh node and calculate initial offsets from rest pose
    for handle in spider_roots {
      root_node := cont.get(engine.world.nodes, handle) or_continue

      // Find the child with the mesh attachment
      for child in root_node.children {
        child_node := cont.get(engine.world.nodes, child) or_continue
        mesh_attachment, has_mesh := &child_node.attachment.(world.MeshAttachment)
        if !has_mesh {
          continue
        }

        // Get the mesh and skin data to calculate rest pose positions
        mesh := cont.get(
          engine.world.meshes,
          mesh_attachment.handle,
        ) or_continue
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

    // Create visual markers for each leg target (red spheres)
    sphere_mesh := world.get_builtin_mesh(&engine.world, .SPHERE)
    red_mat := world.get_builtin_material(&engine.world, .RED)
    for i in 0 ..< 6 {
      target_markers[i] =
        world.spawn(
          &engine.world,
          {0, 0, 0},
          attachment = world.MeshAttachment {
            handle = sphere_mesh,
            material = red_mat,
          },
        ) or_else {}
      world.scale(&engine.world, target_markers[i], 0.2)
    }

    // Ground plane for reference
    cube_mesh := world.get_builtin_mesh(&engine.world, .CUBE)
    gray_mat := world.get_builtin_material(&engine.world, .GRAY)
    ground_plane =
      world.spawn(
        &engine.world,
        {0, 0, 0},
        attachment = world.MeshAttachment {
          handle = cube_mesh,
          material = gray_mat,
        },
      ) or_else {}
    world.scale_xyz(&engine.world, ground_plane, 20, 0.2, 20)
    light_handle :=
      world.spawn(
        &engine.world,
        {0, 0, 0},
        world.create_directional_light_attachment(
          {1.0, 1.0, 1.0, 1.0},
          10.0,
          false,
        ),
      ) or_else {}
  }
  engine.update_proc = proc(engine: ^mjolnir.Engine, delta_time: f32) {
    // Move the spider body back and forth along the X axis
    animation_time += delta_time
    amplitude :: 8.0 // How far to move left/right
    speed :: 0.05 // Oscillation speed (Hz)

    body_x := amplitude * math.sin(animation_time * speed * 2 * math.PI)
    body_pos := [3]f32{body_x, 2, 0}

    // Move the spider body
    if node := cont.get(engine.world.nodes, spider_root_node); node != nil {
      node.transform.position = body_pos
      node.transform.is_dirty = true
    }

    // Target is now automatically computed from leg root + offset in world space
    // Fetch and display the world-space target for each leg
    // Find the skinned mesh child to query leg targets
    if root_node := cont.get(engine.world.nodes, spider_root_node);
       root_node != nil {
      for child in root_node.children {
        child_node := cont.get(engine.world.nodes, child) or_continue
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
            if marker_node := cont.get(engine.world.nodes, target_markers[i]);
               marker_node != nil {
              marker_node.transform.position = target^
              marker_node.transform.is_dirty = true
            }
          }
        }

        break
      }
    }
  }

  mjolnir.run(engine, 800, 600, "Spider Leg")
}

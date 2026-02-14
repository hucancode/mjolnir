package main

import "../../mjolnir"
import cont "../../mjolnir/containers"
import "../../mjolnir/gpu"
import "../../mjolnir/world"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:slice"

root_nodes: [dynamic]world.NodeHandle
animation_time: f32 = 0
spider_root_node: world.NodeHandle
mesh_node: world.NodeHandle
target_markers: [6]world.NodeHandle
ground_plane: world.NodeHandle

// Fixed ground targets for each leg (computed from initial pose)
leg_targets: [6][3]f32

main :: proc() {
  context.logger = log.create_console_logger()
  engine := new(mjolnir.Engine)
  engine.setup_proc = setup
  engine.update_proc = update
  mjolnir.run(engine, 800, 600, "spider-ik")
}

setup :: proc(engine: ^mjolnir.Engine) {
  // engine.world.debug_draw_ik = true // Removed: debug_draw_ik no longer available
  world.main_camera_look_at(
    &engine.world,
    transmute(world.CameraHandle)engine.render.main_camera,
    {0, 80, 120},
    {0, 0, 0},
  )

  // Load spider model
  spider_roots := mjolnir.load_gltf(engine, "assets/spider.glb")
  append(&root_nodes, ..spider_roots[:])

  // Position the spider
  for handle in spider_roots {
    node := cont.get(engine.world.nodes, handle) or_continue
    spider_root_node = handle
    node.transform.position = {0, 5, 0}
    node.transform.is_dirty = true
  }

  // Leg configurations: root bone, tip bone
  leg_configs := []struct {
    root_name: string,
    tip_name:  string,
  } {
    {"leg_front_r_0", "leg_front_r_5"},
    {"leg_middle_r_0", "leg_middle_r_5"},
    {"leg_back_r_0", "leg_back_r_5"},
    {"leg_front_l_0", "leg_front_l_5"},
    {"leg_middle_l_0", "leg_middle_l_5"},
    {"leg_back_l_0", "leg_back_l_5"},
  }

  // Find the skinned mesh node and set up IK for each leg
  for handle in spider_roots {
    root_node := cont.get(engine.world.nodes, handle) or_continue

    for child in root_node.children {
      child_node := cont.get(engine.world.nodes, child) or_continue
      mesh_attachment, has_mesh := &child_node.attachment.(world.MeshAttachment)
      if !has_mesh {
        continue
      }

      mesh_node = child

      mesh := cont.get(engine.world.meshes, mesh_attachment.handle) or_continue
      skin, has_skin := mesh.skinning.?
      if !has_skin {
        continue
      }

      // Get initial body position
      body_pos := [3]f32{0, 5, 0}

      // For each leg, find all bones in the chain and calculate initial target
      for i in 0 ..< 6 {
        root_name := leg_configs[i].root_name
        tip_name := leg_configs[i].tip_name

        // Find all bones in the chain from root to tip
        bone_names := find_bone_chain(skin, root_name, tip_name)
        if len(bone_names) == 0 {
          log.warnf("Could not find bone chain for leg %d", i)
          continue
        }

        log.infof("Leg %d chain: %v", i, bone_names)

        // Calculate initial tip position in world space from bind pose
        tip_bone_idx := -1
        for bone, idx in skin.bones {
          if bone.name == tip_name {
            tip_bone_idx = idx
            break
          }
        }

        if tip_bone_idx >= 0 {
          // Get bind matrix (rest pose) and compute world position
          tip_bind := linalg.matrix4_inverse(
            skin.bones[tip_bone_idx].inverse_bind_matrix,
          )
          tip_local_pos := tip_bind[3].xyz

          // Transform to world space (apply body position)
          tip_world_pos := tip_local_pos + body_pos
          // Set Y to ground level (0) so legs stick to ground
          leg_targets[i] = {tip_world_pos.x, 0, tip_world_pos.z}

          log.infof(
            "Leg %d target: %v (tip local: %v)",
            i,
            leg_targets[i],
            tip_local_pos,
          )
        }

        // Calculate pole position (above and behind the leg root for natural bending)
        root_bone_idx := -1
        for bone, idx in skin.bones {
          if bone.name == root_name {
            root_bone_idx = idx
            break
          }
        }

        pole_pos := [3]f32{0, 10, 0}
        if root_bone_idx >= 0 {
          root_bind := linalg.matrix4_inverse(
            skin.bones[root_bone_idx].inverse_bind_matrix,
          )
          root_local_pos := root_bind[3].xyz
          root_world_pos := root_local_pos + body_pos
          // Pole is above and slightly toward center
          pole_pos = {
            root_world_pos.x * 0.5,
            root_world_pos.y + 10,
            root_world_pos.z * 0.5,
          }
        }

        // Add IK layer for this leg
        world.add_ik_layer(
          &engine.world,
          child,
          bone_names,
          leg_targets[i],
          pole_pos,
          weight = 1.0,
          layer_index = -1, // Append new layer
        )
      }

      break
    }
  }

  mat := world.get_builtin_material(&engine.world, .YELLOW)

  // Find the skinned mesh and create markers for bones
  for handle in root_nodes {
    node := cont.get(engine.world.nodes, handle) or_continue
    for child in node.children {
      child_node := cont.get(engine.world.nodes, child) or_continue
      mesh_attachment, has_mesh := &child_node.attachment.(world.MeshAttachment)
      if !has_mesh {
        continue
      }

      mesh := cont.get(engine.world.meshes, mesh_attachment.handle) or_continue
      skin, has_skin := mesh.skinning.?
      if !has_skin {
        continue
      }
      log.infof("Found skinned mesh with %d bones", len(skin.bones))
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
    world.scale(&engine.world, target_markers[i], 0.5)
    // Position at the fixed target
    if marker_node := cont.get(engine.world.nodes, target_markers[i]);
       marker_node != nil {
      marker_node.transform.position = leg_targets[i]
      marker_node.transform.is_dirty = true
    }
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
  world.scale_xyz(&engine.world, ground_plane, 40, 0.2, 40)

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
  world.register_active_light(&engine.world, light_handle)
}

update :: proc(engine: ^mjolnir.Engine, delta_time: f32) {
  // Move the spider body back and forth along the X axis
  animation_time += delta_time
  amplitude: f32 = 2.5
  speed: f32 = 0.15

  body_x := amplitude * math.sin(animation_time * speed * 2 * math.PI)
  body_pos := [3]f32{body_x, 0, 0}

  // Move the spider body
  if node := cont.get(engine.world.nodes, spider_root_node); node != nil {
    node.transform.position = body_pos
    node.transform.is_dirty = true
  }

  // Update IK targets for each leg - targets stay fixed at ground positions
  // Each leg has its own IK layer (0-5)
  for i in 0 ..< 6 {
    // Calculate pole position for this leg (above the target, toward the body)
    pole_pos := [3]f32 {
      leg_targets[i].x * 0.5 + body_pos.x * 0.5,
      5,
      leg_targets[i].z * 0.5,
    }

    target_pos := leg_targets[i]
    target_pos.y +=
      amplitude * math.max(math.sin(animation_time * speed * math.PI), 0)
    world.set_ik_layer_target(
      &engine.world,
      mesh_node,
      i, // IK layer index (0-5 for the 6 legs)
      target_pos, // Fixed ground target
      pole_pos,
    )
    // Debug draw pole position
    pole_transform := linalg.matrix4_translate(pole_pos)
    pole_transform *= linalg.matrix4_scale([3]f32{0.2, 0.2, 0.2})
  }
}

// Find all bone names in a chain from root to tip
find_bone_chain :: proc(
  skin: world.Skinning,
  root_name: string,
  tip_name: string,
) -> []string {
  // Build parent map from children arrays
  parent_map := make(map[int]int)
  defer delete(parent_map)

  name_to_idx := make(map[string]int)
  defer delete(name_to_idx)

  for bone, idx in skin.bones {
    name_to_idx[bone.name] = idx
    // Build parent map by iterating children
    for child_idx in bone.children {
      parent_map[int(child_idx)] = idx
    }
  }

  root_idx, has_root := name_to_idx[root_name]
  tip_idx, has_tip := name_to_idx[tip_name]

  if !has_root || !has_tip {
    return nil
  }

  // Walk from tip to root to find the chain
  chain_indices := make([dynamic]int)
  defer delete(chain_indices)

  current := tip_idx
  for {
    append(&chain_indices, current)
    if current == root_idx {
      break
    }
    parent, has_parent := parent_map[current]
    if !has_parent {
      // Couldn't reach root - invalid chain
      return nil
    }
    current = parent
  }

  // Reverse to get root-to-tip order
  result := make([]string, len(chain_indices))
  for i in 0 ..< len(chain_indices) {
    idx := chain_indices[len(chain_indices) - 1 - i]
    result[i] = skin.bones[idx].name
  }

  return result
}

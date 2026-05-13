package main

import "../../mjolnir"
import anim "../../mjolnir/animation"
import "../../mjolnir/world"
import "core:log"
import "core:math"
import "core:math/linalg"

root_nodes: [dynamic]world.NodeHandle
animation_time: f32 = 0
spider_root_node: world.NodeHandle
mesh_node: world.NodeHandle
target_markers: [6]world.NodeHandle
pole_markers: [6]world.NodeHandle
ground_plane: world.NodeHandle

// Fixed ground targets for each leg (computed from initial pose)
leg_targets: [6][3]f32

main :: proc() {
  context.logger = log.create_console_logger()
  engine := new(mjolnir.Engine)
  engine.setup_proc = setup
  engine.update_proc = update
  mjolnir.run(engine, 800, 600, "IK")
}

setup :: proc(engine: ^mjolnir.Engine) {
  // engine.world.debug_draw_ik = true // Removed: debug_draw_ik no longer available
  world.main_camera_look_at(
    &engine.world,
    {0, 80, 120},
    {0, 0, 0},
  )

  // Load spider model
  spider_roots := mjolnir.load_gltf(engine, "assets/spider.glb")
  append(&root_nodes, ..spider_roots[:])

  // Position the spider
  for handle in spider_roots {
    node := world.node(&engine.world, handle) or_continue
    spider_root_node = handle
    world.translate(&node.transform, 0, 5, 0)
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
    root_node := world.node(&engine.world, handle) or_continue

    for child in root_node.children {
      child_node := world.node(&engine.world, child) or_continue
      mesh_attachment, has_mesh := &child_node.attachment.(world.MeshAttachment)
      if !has_mesh {
        continue
      }

      mesh_node = child

      mesh := world.mesh(&engine.world, mesh_attachment.handle) or_continue
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

        bone_indices, chain_ok := world.find_bone_chain(mesh, root_name, tip_name)
        if !chain_ok {
          log.warnf("Could not find bone chain for leg %d", i)
          continue
        }

        log.infof("Leg %d chain: %v bones", i, len(bone_indices))

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

        // Build per-bone rotation constraints.
        // Root (index 0): swing X/Z <= 30deg, twist Y <= 90deg.
        // Others: X/Y/Z <= 45deg.
        constraints := make([]anim.IKBoneConstraint, len(bone_indices))
        deg30 := f32(math.PI / 6.0)
        deg90 := f32(math.PI / 2.0)
        constraints[0] = anim.IKBoneConstraint{max_angle = {deg30, deg90, deg30}}
        for j in 1 ..< len(bone_indices) {
          constraints[j] = anim.IKBoneConstraint{max_angle = {deg90, deg90, deg90}}
        }

        // Add IK layer for this leg
        if err := world.add_ik_layer_by_indices(
          &engine.world,
          child,
          bone_indices,
          leg_targets[i],
          pole_pos,
          weight = 1.0,
          constraints = constraints,
        ); err != .NONE {
          log.errorf("IK layer add failed leg %d: %v", i, err)
        }
      }

      break
    }
  }

  mat := world.get_builtin_material(&engine.world, .YELLOW)

  // Find the skinned mesh and create markers for bones
  for handle in root_nodes {
    node := world.node(&engine.world, handle) or_continue
    for child in node.children {
      child_node := world.node(&engine.world, child) or_continue
      mesh_attachment, has_mesh := &child_node.attachment.(world.MeshAttachment)
      if !has_mesh {
        continue
      }

      mesh := world.mesh(&engine.world, mesh_attachment.handle) or_continue
      skin, has_skin := mesh.skinning.?
      if !has_skin {
        continue
      }
      log.infof("Found skinned mesh with %d bones", len(skin.bones))
    }
  }

  // Create visual markers for each leg target (red spheres) and pole (blue)
  for i in 0 ..< 6 {
    target_markers[i] = world.spawn_primitive_mesh(&engine.world, .SPHERE, .RED)
    world.scale(&engine.world, target_markers[i], 0.5)
    tgt := leg_targets[i]
    world.translate(&engine.world, target_markers[i], tgt.x, tgt.y, tgt.z)

    pole_markers[i] = world.spawn_primitive_mesh(&engine.world, .SPHERE, .BLUE)
    world.scale(&engine.world, pole_markers[i], 0.3)
  }

  ground_plane = world.spawn_primitive_mesh(&engine.world, .CUBE, .GRAY)
  world.scale_xyz(&engine.world, ground_plane, 40, 0.2, 40)

  world.spawn_light_directional(
    &engine.world,
    color  = {1, 1, 1, 1},
    radius = 10.0,
  )
}

update :: proc(engine: ^mjolnir.Engine, delta_time: f32) {
  // Move the spider body back and forth along the X axis
  animation_time += delta_time
  amplitude: f32 = 2.5
  speed: f32 = 0.15

  body_x := amplitude * math.sin(animation_time * speed * 2 * math.PI)
  body_pos := [3]f32{body_x, 0, 0}

  // Move the spider body
  if node := world.node(&engine.world, spider_root_node); node != nil {
    world.translate(&node.transform, body_pos.x, body_pos.y, body_pos.z)
  }

  // Update IK targets for each leg - targets stay fixed at ground positions
  for i in 0 ..< 6 {
    pole_pos := [3]f32 {
      leg_targets[i].x * 0.5 + body_pos.x * 0.5,
      5,
      leg_targets[i].z * 0.5,
    }
    target_pos := leg_targets[i]
    target_pos.y += amplitude * math.max(math.sin(animation_time * speed * math.PI), 0)
    world.set_ik_layer_target(&engine.world, mesh_node, i, target_pos, pole_pos)
    world.translate(&engine.world, target_markers[i], target_pos.x, target_pos.y, target_pos.z)
    world.translate(&engine.world, pole_markers[i], pole_pos.x, pole_pos.y, pole_pos.z)
  }
}

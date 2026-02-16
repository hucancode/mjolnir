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
markers: [dynamic]world.NodeHandle
animation_time: f32 = 0
snake_child_node: world.NodeHandle
root_bone_modifier: ^anim.SingleBoneRotationModifier

main :: proc() {
  context.logger = log.create_console_logger()
  engine := new(mjolnir.Engine)
  engine.setup_proc = proc(engine: ^mjolnir.Engine) {
    world.main_camera_look_at(
      &engine.world,
      {0, 100, 150},
      {0, 30, 0},
    )
    root_nodes = mjolnir.load_gltf(engine, "assets/stuffed_snake_rigged.glb")
    for handle in root_nodes {
      node := cont.get(engine.world.nodes, handle) or_continue
      for child in node.children {
        snake_child_node = child // Store for animation

        // Add single bone rotation modifier to control the root bone
        root_bone_modifier =
          world.add_single_bone_rotation_modifier_layer(
            &engine.world,
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
    cone_mesh := world.get_builtin_mesh(&engine.world, .CONE)
    mat := world.get_builtin_material(&engine.world, .YELLOW)

    // Find the skinned mesh and create markers for bones
    for handle in root_nodes {
      node := cont.get(engine.world.nodes, handle) or_continue
      log.infof("Root node found")
      for child in node.children {
        child_node := cont.get(engine.world.nodes, child) or_continue
        log.infof("Child node found")
        mesh_attachment, has_mesh := &child_node.attachment.(world.MeshAttachment)
        if !has_mesh {
          log.infof("Child has no mesh attachment")
          continue
        }

        mesh := cont.get(
          engine.world.meshes,
          mesh_attachment.handle,
        ) or_continue
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
          marker :=
            world.spawn(
              &engine.world,
              {0, 0, 0},
              attachment = world.MeshAttachment {
                handle = cone_mesh,
                material = mat,
              },
            ) or_else {}
          world.scale(&engine.world, marker, 0.2)
          append(&markers, marker)
          log.infof("Created marker %d at default position", i)
        }

        log.infof("Total markers created: %d", len(markers))
      }
    }

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
    point_light_handle :=
      world.spawn(
        &engine.world,
        {0, 50, 50},
        world.create_point_light_attachment(
          {1.0, 0.9, 0.8, 1.0},
          1000.0,
          true,
        ),
      ) or_else {}
  }
  engine.update_proc = proc(engine: ^mjolnir.Engine, delta_time: f32) {
    // Animate the root bone directly via the single bone rotation modifier
    // This creates motion that the tail modifier will react to
    animation_time += delta_time
    frequency :: 0.5 // Hz - oscillation speed
    amplitude :: math.PI * 0.35 // Radians - swing angle
    target_angle :=
      amplitude * math.sin(animation_time * frequency * 2 * math.PI)

    // Update the root bone rotation via the modifier
    if root_bone_modifier != nil {
      axis := linalg.Vector3f32{0, 1, 0}
      root_bone_modifier.rotation = linalg.quaternion_angle_axis_f32(
        target_angle,
        axis,
      )
    }

    marker_idx := 0
    for handle in root_nodes {
      node := cont.get(engine.world.nodes, handle) or_continue
      for child in node.children {
        matrices, skin, child_node := world.get_bone_matrices(&engine.world, child) or_continue
        for i in 0 ..< len(skin.bones) {
          if marker_idx >= len(markers) do break
          t := world.get_bone_world_transform(&engine.world, child, u32(i)) or_continue
          marker := cont.get(engine.world.nodes, markers[marker_idx]) or_continue
          marker.transform.position = t.position
          marker.transform.rotation = t.rotation
          marker.transform.is_dirty = true
          marker_idx += 1
        }
      }
    }
  }
  mjolnir.run(engine, 800, 600, "Tail Modifier")
}

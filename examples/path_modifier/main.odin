package main

import "../../mjolnir"
import "../../mjolnir/animation"
import cont "../../mjolnir/containers"
import "../../mjolnir/geometry"
import "../../mjolnir/gpu"
import "../../mjolnir/render"
import "../../mjolnir/world"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:slice"

root_nodes: [dynamic]world.NodeHandle
markers: [dynamic]world.NodeHandle

main :: proc() {
  context.logger = log.create_console_logger()
  engine := new(mjolnir.Engine)
  engine.setup_proc = proc(engine: ^mjolnir.Engine) {
    world.main_camera_look_at(
      &engine.world,
      engine.world.main_camera,
      {5, 15, 8},
      {0, 3, 0},
    )
    root_nodes = mjolnir.load_gltf(engine, "assets/stuffed_snake_rigged.glb")

    CONTROL_POINTS :: 8
    path := make([][3]f32, CONTROL_POINTS)
    defer delete(path)

    // Create a compact S-curve that matches snake's natural length
    for i in 0 ..< CONTROL_POINTS {
      t := f32(i) / f32(CONTROL_POINTS - 1)
      x := f32(3.0 * math.sin(t * math.PI * 2.0))
      y := f32(t * 5.0) // Vertical progression
      z := f32(0.0)
      path[i] = [3]f32{x, y, z}
    }

    for handle in root_nodes {
      node := cont.get(engine.world.nodes, handle) or_continue
      for child in node.children {
        world.add_path_modifier_layer(
          &engine.world,
          child,
          root_bone_name = "root",
          tail_length = 14,
          path = path,
          offset = 0.0,
          length = 3.0, // Fit skeleton to a 20-unit segment of the path
          speed = 5.0, // Disabled animation
          loop = true,
          weight = 1.0,
        )
      }
    }

    // Create cone markers for each bone
    cone_mesh := world.get_builtin_mesh(&engine.world, .CONE)
    mat := world.get_builtin_material(&engine.world, .YELLOW)

    // Find the skinned mesh and create markers for bones
    for handle in root_nodes {
      node := cont.get(engine.world.nodes, handle) or_continue
      for child in node.children {
        child_node := cont.get(engine.world.nodes, child) or_continue
        mesh_attachment, has_mesh := &child_node.attachment.(world.MeshAttachment)
        if !has_mesh do continue

        mesh := cont.get(
          engine.world.meshes,
          mesh_attachment.handle,
        ) or_continue
        skin := mesh.skinning.? or_continue

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
          world.scale(&engine.world, marker, 0.08)
          append(&markers, marker)
        }
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
    world.register_active_light(&engine.world, light_handle)
    point_light_handle :=
      world.spawn(
        &engine.world,
        {20, 20, 40},
        world.create_point_light_attachment({1.0, 0.9, 0.8, 1.0}, 500.0, true),
      ) or_else {}
    world.register_active_light(&engine.world, point_light_handle)
  }

  engine.update_proc = proc(engine: ^mjolnir.Engine, delta_time: f32) {
    // Update marker positions to match bone transforms
    marker_idx := 0
    for handle in root_nodes {
      node := cont.get(engine.world.nodes, handle) or_continue
      for child in node.children {
        child_node := cont.get(engine.world.nodes, child) or_continue
        mesh_attachment, has_mesh := &child_node.attachment.(world.MeshAttachment)
        if !has_mesh do continue

        skinning, has_skinning := mesh_attachment.skinning.?
        if !has_skinning do continue

        mesh := cont.get(
          engine.world.meshes,
          mesh_attachment.handle,
        ) or_continue
        skin := mesh.skinning.? or_continue

        // Get bone matrices from GPU buffer
        frame_index := engine.frame_index
        bone_buffer := &engine.render.bone_buffer.buffers[frame_index]
        if bone_buffer.mapped == nil do continue

        bone_count := len(skin.bones)
        bone_matrix_buffer_offset, has_offset :=
          engine.render.bone_matrix_offsets[child.index]
        if !has_offset do continue

        // Get bone matrices using gpu.get
        matrices_ptr := gpu.get(bone_buffer, bone_matrix_buffer_offset)
        bone_matrices := slice.from_ptr(matrices_ptr, bone_count)

        // Read bone transforms
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
          marker := cont.get(
            engine.world.nodes,
            markers[marker_idx],
          ) or_continue
          marker.transform.position = bone_pos
          marker.transform.rotation = bone_rot
          marker.transform.is_dirty = true

          marker_idx += 1
        }
      }
    }
  }

  mjolnir.run(engine, 800, 600, "visual-path-modifier")
}

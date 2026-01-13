package main

import "../../../mjolnir"
import "../../../mjolnir/animation"
import "../../../mjolnir/geometry"
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
      camera_look_at(camera, {5, 15, 8}, {0, 3, 0})
      sync_active_camera_controller(engine)
    }
    root_nodes = load_gltf(engine, "assets/stuffed_snake_rigged.glb")

    CONTROL_POINTS :: 8
    path := make([][3]f32, CONTROL_POINTS)
    defer delete(path)

    // Create a compact S-curve that matches snake's natural length
    for i in 0 ..< CONTROL_POINTS {
      t := f32(i) / f32(CONTROL_POINTS - 1)
      x := f32(3.0 * math.sin(t * math.PI * 2.0))
      y := f32(t * 5.0)  // Vertical progression
      z := f32(0.0)
      path[i] = [3]f32{x, y, z}
    }

    for handle in root_nodes {
      node := get_node(engine, handle) or_continue
      for child in node.children {
        world.add_path_modifier_layer(
          &engine.world,
          &engine.rm,
          child,
          root_bone_name = "root",
          tail_length = 14,
          path = path,
          offset = 0.0,
          length = 3.0,  // Fit skeleton to a 20-unit segment of the path
          speed = 5.0,    // Disabled animation
          loop = true,
          weight = 1.0,
        )
      }
    }

    // Create cone markers for each bone
    cone_mesh := engine.rm.builtin_meshes[resources.Primitive.CONE]
    mat := engine.rm.builtin_materials[resources.Color.YELLOW]

    // Find the skinned mesh and create markers for bones
    for handle in root_nodes {
      node := get_node(engine, handle) or_continue
      for child in node.children {
        child_node := get_node(engine, child) or_continue
        mesh_attachment, has_mesh := &child_node.attachment.(world.MeshAttachment)
        if !has_mesh do continue

        mesh := cont.get(engine.rm.meshes, mesh_attachment.handle) or_continue
        skin := mesh.skinning.? or_continue

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
        }
      }
    }

    spawn_directional_light(engine, {1.0, 1.0, 1.0, 1.0})
    spawn_point_light(
      engine,
      {1.0, 0.9, 0.8, 1.0},
      500.0,
      position = {20, 20, 40},
    )
  }

  engine.update_proc = proc(engine: ^mjolnir.Engine, delta_time: f32) {
    using mjolnir
    // Update marker positions to match bone transforms
    marker_idx := 0
    for handle in root_nodes {
      node := get_node(engine, handle) or_continue
      for child in node.children {
        child_node := get_node(engine, child) or_continue
        mesh_attachment, has_mesh := &child_node.attachment.(world.MeshAttachment)
        if !has_mesh do continue

        skinning, has_skinning := mesh_attachment.skinning.?
        if !has_skinning do continue

        mesh := cont.get(engine.rm.meshes, mesh_attachment.handle) or_continue
        skin := mesh.skinning.? or_continue

        // Get bone matrices from GPU buffer
        frame_index := engine.frame_index
        bone_buffer := &engine.rm.bone_buffer.buffers[frame_index]
        if bone_buffer.mapped == nil do continue

        bone_count := len(skin.bones)
        if skinning.bone_matrix_buffer_offset == 0xFFFFFFFF do continue

        // Get bone matrices using gpu.get
        matrices_ptr := gpu.get(bone_buffer, skinning.bone_matrix_buffer_offset)
        bone_matrices := slice.from_ptr(matrices_ptr, bone_count)

        // Read bone transforms
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

  mjolnir.run(engine, 800, 600, "visual-path-modifier")
}

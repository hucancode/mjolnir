package main

import "../../../mjolnir"
import "../../../mjolnir/resources"
import "../../../mjolnir/world"
import "core:log"
import "core:math"

fox_handle: resources.Handle
target_cube: resources.Handle
blend_factor: f32 = 0.0 // 0.0 = Walk, 1.0 = Run
blend_direction: f32 = 1.0

main :: proc() {
  context.logger = log.create_console_logger()
  engine := new(mjolnir.Engine)
  engine.setup_proc = setup
  engine.update_proc = update
  engine.key_press_proc = on_key_press
  mjolnir.run(engine, 1280, 720, "Fox Animation Blending + IK")
}

setup :: proc(engine: ^mjolnir.Engine) {
  using mjolnir

  // Setup camera - try a closer view first
  if camera := get_main_camera(engine); camera != nil {
    camera_look_at(camera, {3, 2, 3}, {0, 1, 0})
  }

  // Load Fox model
  root_nodes := load_gltf(engine, "assets/Fox2.glb")
  log.infof("Loaded Fox with %d root nodes", len(root_nodes))

  if len(root_nodes) == 0 {
    log.error("Failed to load Fox.glb - no root nodes!")
    return
  }

  for handle in root_nodes {
    node := get_node(engine, handle) or_continue
    log.infof("Root node has %d children", len(node.children))
    for child in node.children {
      child_node := get_node(engine, child) or_continue
      log.infof("Child node attachment: %v", child_node.attachment)
      // Check if this is a mesh
      mesh_attachment, has_mesh := child_node.attachment.(world.MeshAttachment)
      if has_mesh {
        log.info("Found mesh node")
        fox_handle = child

        // Layer 0: Walk animation (starts at full weight)
        if !add_animation_layer(engine, child, "Walk", weight = 1.0) {
          log.error("Failed to add Walk animation")
        } else {
          log.info("Added Walk animation on layer 0")
        }

        // Layer 1: Run animation (starts at zero weight)
        if !add_animation_layer(engine, child, "Run", weight = 0.0) {
          log.error("Failed to add Run animation")
        } else {
          log.info("Added Run animation on layer 1")
        }

        // Layer 2: IK for spine/neck/head to track target
        // Target position in world space (scaled coordinates)
        target_pos := [3]f32{0.0, 4.0, 5.0} // scaled from {0, 80, 100}
        pole_pos := [3]f32{0.0, 5.0, 2.5} // scaled from {0, 100, 50}

        if !add_ik_layer(
          engine,
          child,
          bone_names = []string {
            "b_Spine01_02",
            "b_Spine02_03",
            "b_Neck_04",
            "b_Head_05",
          },
          target_pos = target_pos,
          pole_pos = pole_pos,
          weight = 1.0,
        ) {
          log.error("Failed to add IK layer")
        } else {
          log.info("Added IK layer on layer 2")
        }

        break
      }
    }
  }

  // Create target cube for IK visualization
  cube_mesh := get_builtin_mesh(engine, .CUBE)
  cube_material := get_builtin_material(engine, .RED)
  target_cube = spawn_at(
  engine,
  {0.0, 4.0, 5.0}, // Initial IK target position
  world.MeshAttachment {
    handle = cube_mesh,
    material = cube_material,
    cast_shadow = false,
  },
  )
  scale(engine, target_cube, 0.25) // Make it smaller for the scaled scene

  // Add lighting
  spawn_directional_light(
    engine,
    {1.0, 1.0, 1.0, 1.0},
    cast_shadow = true,
    position = {5.0, 10.0, 5.0},
  )

  log.info("Setup complete!")
}

update :: proc(engine: ^mjolnir.Engine, dt: f32) {
  using mjolnir

  // Animate blend factor between Walk and Run
  blend_factor += blend_direction * dt * 0.5
  if blend_factor >= 1.0 {
    blend_factor = 1.0
    blend_direction = -1.0
  } else if blend_factor <= 0.0 {
    blend_factor = 0.0
    blend_direction = 1.0
  }

  // Update animation layer weights
  // Layer 0 (Walk): weight goes from 1.0 to 0.0
  // Layer 1 (Run): weight goes from 0.0 to 1.0
  if fox_handle.index != 0 {
    set_animation_layer_weight(engine, fox_handle, 0, 1.0 - blend_factor)
    set_animation_layer_weight(engine, fox_handle, 1, blend_factor)
  }

  // Move target cube in a circle (scaled coordinates: 80->4, 100->5)
  t := time_since_start(engine)
  radius: f32 = 4.0 // scaled from 80
  target_x := math.cos(t) * radius
  target_z := math.sin(t) * radius
  target_y := 4.0 + math.sin(t * 2.0) * 1.0 // scaled from 80 + 20
  new_target := [3]f32{target_x, target_y, target_z}
  pole := [3]f32{0.0, 5.0, 0.0} // scaled from {0, 100, 0}

  // Update IK target (layer 2)
  if fox_handle.index != 0 {
    set_ik_layer_target(engine, fox_handle, 2, new_target, pole)
  }

  // Move the visual cube
  if target_cube.index != 0 {
    translate(engine, target_cube, target_x, target_y, target_z)
  }
}

on_key_press :: proc(engine: ^mjolnir.Engine, key, action, mods: int) {
  using mjolnir
  if action == 1 {   // Key press
    switch key {
    case 32:
      // Space - toggle IK
      // Toggle IK layer enabled state (not implemented in API yet, so this is placeholder)
      log.info("Space pressed - IK toggle (not yet implemented)")
    }
  }
}

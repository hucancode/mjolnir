package main

import "../../mjolnir"
import "../../mjolnir/animation"
import cont "../../mjolnir/containers"
import "../../mjolnir/world"
import "core:log"
import "core:math"

// Example demonstrating animation layering features:
// - Layer 0: Base walk animation (FK, REPLACE mode)
// - Layer 1: Run animation (FK, REPLACE mode) - blends with walk
// - Layer 2: Survey animation (FK, REPLACE mode) - upper body layer
// - Layer 3: IK layer for head tracking
//
// Note: Standard animation clips should use REPLACE mode for blending.
// ADD mode is only for animations specifically authored as additive deltas.
//
// Keyboard controls:
// - 1: Toggle walk/run blend
// - 2: Toggle survey animation (upper body)
// - 3: Toggle IK head tracking
// - Space: Reset all

fox_handle: world.NodeHandle
target_cube: world.NodeHandle

// Layer weights
walk_weight: f32
run_weight: f32
survey_weight: f32
ik_weight: f32

// Animation state
blend_walk_run: bool
enable_survey: bool
enable_ik: bool

main :: proc() {
  context.logger = log.create_console_logger()
  engine := new(mjolnir.Engine)
  engine.setup_proc = setup
  engine.update_proc = update
  engine.key_press_proc = on_key_press
  mjolnir.run(engine, 1280, 720, "Animation Layering")
}

setup :: proc(engine: ^mjolnir.Engine) {
  log.info("Controls:")
  log.info("  1 - Toggle Walk/Run blend")
  log.info("  2 - Toggle Survey animation (upper body)")
  log.info("  3 - Toggle IK head tracking")
  log.info("  Space - Reset all")
  log.info("")

  // Initialize state
  walk_weight = 1.0
  run_weight = 0.0
  survey_weight = 0.0
  ik_weight = 0.0
  blend_walk_run = false
  enable_survey = false
  enable_ik = false

  // Setup camera
  world.main_camera_look_at(
    &engine.world,
    engine.world.main_camera,
    {3, 2, 3},
    {0, 1, 0},
  )

  // Load Fox model
  root_nodes := mjolnir.load_gltf(engine, "assets/Fox2.glb")
  log.infof("Loaded Fox with %d root nodes", len(root_nodes))

  if len(root_nodes) == 0 {
    log.error("Failed to load Fox.glb")
    return
  }

  // Find the mesh node and setup animation layers
  for handle in root_nodes {
    node := cont.get(engine.world.nodes, handle) or_continue
    for child in node.children {
      child_node := cont.get(engine.world.nodes, child) or_continue
      _, has_mesh := child_node.attachment.(world.MeshAttachment)
      if has_mesh {
        fox_handle = child

        // === Layer 0: Walk animation (base layer, REPLACE mode) ===
        if !world.add_animation_layer(
          &engine.world,
          child,
          "Walk",
          weight = 1.0,
          blend_mode = .REPLACE,
        ) {
          log.error("Failed to add Walk animation")
        } else {
          log.info("✓ Layer 0: Walk (REPLACE) - Base animation")
        }

        // === Layer 1: Run animation (REPLACE mode, starts at 0 weight) ===
        if !world.add_animation_layer(
          &engine.world,
          child,
          "Run",
          weight = 0.0,
          blend_mode = .REPLACE,
        ) {
          log.error("Failed to add Run animation")
        } else {
          log.info("✓ Layer 1: Run (REPLACE) - Blends with Walk")
        }

        // === Layer 2: Survey animation (REPLACE mode with bone mask for upper body) ===
        // Note: Standard animation clips should use REPLACE mode, not ADD
        if !world.add_animation_layer(
          &engine.world,
          child,
          "Survey",
          weight = 0.0,
          mode = .LOOP,
          speed = 0.5,
          blend_mode = .REPLACE, // Use REPLACE for standard animation clips
        ) {
          log.warn("Survey animation not found, upper body layer disabled")
        } else {
          log.info("✓ Layer 2: Survey (REPLACE) - Upper body animation")
          // TODO: Apply bone mask to limit Survey to upper body bones
          // (bone masks not yet shown in this example)
        }

        // === Layer 3: IK layer for head tracking ===
        target_pos := [3]f32{0.0, 4.0, 5.0}
        pole_pos := [3]f32{0.0, 5.0, 2.5}

        if !world.add_ik_layer(
          &engine.world,
          child,
          []string{"b_Spine01_02", "b_Spine02_03", "b_Neck_04", "b_Head_05"},
          target_pos,
          pole_pos,
          weight = 0.0, // Start disabled
        ) {
          log.error("Failed to add IK layer")
        } else {
          log.info("✓ Layer 3: IK (REPLACE) - Head tracking")
        }

        log.info("")
        log.info("All layers initialized! Press keys to toggle features.")
        break
      }
    }
  }

  // Create target cube for IK visualization
  cube_mesh := world.get_builtin_mesh(&engine.world, .CUBE)
  cube_material := world.get_builtin_material(&engine.world, .RED)
  target_cube =
    world.spawn(
      &engine.world,
      {0.0, 4.0, 5.0},
      world.MeshAttachment {
        handle = cube_mesh,
        material = cube_material,
        cast_shadow = false,
      },
    ) or_else {}
  world.scale(&engine.world, target_cube, 0.25)
  // Add lighting
  light_handle :=
    world.spawn(
      &engine.world,
      {0, 0, 0},
      world.create_directional_light_attachment(
        {1.0, 1.0, 1.0, 1.0},
        10.0,
        true,
      ),
    ) or_else {}
}

update :: proc(engine: ^mjolnir.Engine, dt: f32) {
  if fox_handle.index == 0 do return

  // === Update Walk/Run blend ===
  if blend_walk_run {
    // Smoothly transition to run
    target_walk := f32(0.0)
    target_run := f32(1.0)
    walk_weight = math.lerp(walk_weight, target_walk, dt * 0.2)
    run_weight = math.lerp(run_weight, target_run, dt * 0.2)
  } else {
    // Smoothly transition to walk
    target_walk := f32(1.0)
    target_run := f32(0.0)
    walk_weight = math.lerp(walk_weight, target_walk, dt * 0.2)
    run_weight = math.lerp(run_weight, target_run, dt * 0.2)
  }

  world.set_animation_layer_weight(&engine.world, fox_handle, 0, walk_weight)
  world.set_animation_layer_weight(&engine.world, fox_handle, 1, run_weight)

  // === Update survey animation (upper body) ===
  target_survey := enable_survey ? f32(1.0) : f32(0.0)
  survey_weight = math.lerp(survey_weight, target_survey, dt)
  world.set_animation_layer_weight(&engine.world, fox_handle, 2, survey_weight)

  // === Update IK layer ===
  target_ik := enable_ik ? f32(1.0) : f32(0.0)
  ik_weight = math.lerp(ik_weight, target_ik, dt * 2.0)
  world.set_animation_layer_weight(&engine.world, fox_handle, 3, ik_weight)

  // Move IK target in a circle
  if enable_ik {
    t := mjolnir.time_since_start(engine)
    radius: f32 = 4.0
    target_x := math.cos(t) * radius
    target_z := math.sin(t) * radius
    target_y := 4.0 + math.sin(t * 2.0) * 1.0
    new_target := [3]f32{target_x, target_y, target_z}
    pole := [3]f32{0.0, 5.0, 0.0}

    world.set_ik_layer_target(&engine.world, fox_handle, 3, new_target, pole)

    // Move the visual cube
    if target_cube.index != 0 {
      world.translate(&engine.world, target_cube, target_x, target_y, target_z)
    }
  }
  // Debug output every 60 frames
  frame := int(mjolnir.time_since_start(engine) * 60)
  if frame % 60 == 0 {
    log.infof(
      "Weights - Walk: %.2f, Run: %.2f, Survey: %.2f, IK: %.2f",
      walk_weight,
      run_weight,
      survey_weight,
      ik_weight,
    )
  }
}

on_key_press :: proc(engine: ^mjolnir.Engine, key, action, mods: int) {
  if action != 1 do return // Only handle press events

  switch key {
  case '1':
    // '1' key
    blend_walk_run = !blend_walk_run
    if blend_walk_run {
      log.info("Blending to RUN animation")
    } else {
      log.info("Blending to WALK animation")
    }

  case '2':
    // '2' key
    enable_survey = !enable_survey
    if enable_survey {
      log.info("SURVEY animation ENABLED (upper body layer)")
    } else {
      log.info("SURVEY animation DISABLED")
    }

  case '3':
    // '3' key
    enable_ik = !enable_ik
    if enable_ik {
      log.info("IK head tracking ENABLED")
    } else {
      log.info("IK head tracking DISABLED")
    }

  case 32:
    // Space key
    blend_walk_run = false
    enable_survey = false
    enable_ik = false
    log.info("RESET: All layers reset to defaults")
  }
}

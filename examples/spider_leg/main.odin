package main

import "../../mjolnir"
import anim "../../mjolnir/animation"
import "../../mjolnir/world"
import "core:log"
import "core:math"

// Visual markers
leg_root_node: world.NodeHandle
target_markers: [8]world.NodeHandle
feet_markers: [8]world.NodeHandle
ground_plane_node: world.NodeHandle

// Core spider leg state - 8 legs (4 per side)
spider_legs: [8]anim.SpiderLeg
animation_time: f32 = 0

main :: proc() {
  context.logger = log.create_console_logger()
  engine := new(mjolnir.Engine)
  engine.setup_proc = proc(engine: ^mjolnir.Engine) {
    if camera := mjolnir.get_main_camera(engine); camera != nil {
      world.camera_look_at(camera, {0, 50, 100}, {0, 0, 0})
      mjolnir.sync_active_camera_controller(engine)
    }

    // Initialize 8 spider legs (4 per side)
    // Arranged like a real spider with staggered timing
    leg_offsets := [8][3]f32 {
      // Right side (positive Z)
      {3, -10, 12}, // Front right
      {1, -10, 14}, // Mid-front right
      {-1, -10, 14}, // Mid-back right
      {-3, -10, 12}, // Back right
      // Left side (negative Z)
      {3, -10, -12}, // Front left
      {1, -10, -14}, // Mid-front left
      {-1, -10, -14}, // Mid-back left
      {-3, -10, -12}, // Back left
    }

    // Stagger timing for natural gait (each leg 1/8 of cycle apart)
    lift_frequency :: 2.0
    for i in 0 ..< 8 {
      anim.spider_leg_init(
        &spider_legs[i],
        initial_offset = leg_offsets[i],
        lift_height = 4.0,
        lift_frequency = lift_frequency,
        lift_duration = 0.5,
        time_offset = f32(i) * (lift_frequency / 8.0),
      )
    }

    // Create visual markers
    cube_mesh := world.get_builtin_mesh(&engine.world, .CUBE)
    sphere_mesh := world.get_builtin_mesh(&engine.world, .SPHERE)

    // Leg root (blue cube) - represents spider body
    blue_mat := world.get_builtin_material(&engine.world, .BLUE)
    leg_root_node = mjolnir.spawn(
      engine,
      attachment = world.MeshAttachment {
        handle = cube_mesh,
        material = blue_mat,
      },
      position = {0, 10, 0},
    )
    world.scale(&engine.world, leg_root_node, 2.0)

    // Create markers for each leg
    yellow_mat := world.get_builtin_material(&engine.world, .YELLOW)
    green_mat := world.get_builtin_material(&engine.world, .GREEN)

    for i in 0 ..< 8 {
      // Target marker (small yellow cube) - shows computed target position
      target_markers[i] = mjolnir.spawn(
        engine,
        attachment = world.MeshAttachment {
          handle = cube_mesh,
          material = yellow_mat,
        },
      )
      world.scale(&engine.world, target_markers[i], 0.3)

      // Feet marker (green sphere) - shows actual feet position
      feet_markers[i] = mjolnir.spawn(
        engine,
        attachment = world.MeshAttachment {
          handle = sphere_mesh,
          material = green_mat,
        },
      )
      world.scale(&engine.world, feet_markers[i], 0.8)
    }

    // Ground plane (gray, large and flat)
    gray_mat := world.get_builtin_material(&engine.world, .GRAY)
    ground_plane_node = mjolnir.spawn(
      engine,
      attachment = world.MeshAttachment {
        handle = cube_mesh,
        material = gray_mat,
      },
    )
    world.scale_xyz(&engine.world, ground_plane_node, 100, 0.2, 100)

    // Lighting
    mjolnir.spawn_directional_light(engine, {1.0, 1.0, 1.0, 1.0})
    mjolnir.spawn_point_light(
      engine,
      {1.0, 0.9, 0.8, 1.0},
      1000.0,
      position = {0, 50, 50},
    )

    log.infof("Visual Test: Spider Leg Core Algorithm - 8 Legs")
    log.infof("Blue cube = Spider body (leg root)")
    log.infof("Yellow cubes = Computed targets (root + offset)")
    log.infof("Green spheres = Actual feet positions")
    log.infof("Watch the legs lift in sequence creating a walking gait!")
  }

  engine.update_proc = proc(engine: ^mjolnir.Engine, delta_time: f32) {
    // Move the leg root (spider body) back and forth along X axis
    animation_time += delta_time
    amplitude :: 30.0
    speed :: 0.1

    root_x := amplitude * math.sin(animation_time * speed * 2 * math.PI)
    root_pos := [3]f32{root_x, 10, 0}

    // Update leg root visual
    if node := mjolnir.get_node(engine, leg_root_node); node != nil {
      node.transform.position = root_pos
      node.transform.is_dirty = true
    }

    // Update all 8 spider legs
    for i in 0 ..< 8 {
      // Update spider leg algorithm with root position
      anim.spider_leg_update_with_root(&spider_legs[i], delta_time, root_pos)

      // Update target marker (should follow root + offset immediately)
      if node := mjolnir.get_node(engine, target_markers[i]); node != nil {
        node.transform.position = spider_legs[i].feet_target
        node.transform.is_dirty = true
      }

      // Update feet marker (should lift in parabolic arc periodically)
      if node := mjolnir.get_node(engine, feet_markers[i]); node != nil {
        node.transform.position = spider_legs[i].feet_position
        node.transform.is_dirty = true
      }
    }
  }

  mjolnir.run(engine, 800, 600, "visual-spider-leg-core")
}

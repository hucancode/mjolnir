package main

import "core:log"
import "core:math"
import "core:math/linalg"
import "core:os"
import "mjolnir"
import "mjolnir/geometry"
import "mjolnir/render/text"
import "mjolnir/resources"
import "mjolnir/world"
import "vendor:glfw"
import mu "vendor:microui"

LIGHT_COUNT :: 1
ALL_SPOT_LIGHT :: false
ALL_POINT_LIGHT :: false
light_handles: [LIGHT_COUNT]resources.Handle
light_cube_handles: [LIGHT_COUNT]resources.Handle
brick_wall_mat_handle: resources.Handle
hammer_handle: resources.Handle
forcefield_handle: resources.Handle

portal_render_target_index: int = -1
portal_material_handle: resources.Handle
portal_quad_handle: resources.Handle

orbit_controller: geometry.CameraController
free_controller: geometry.CameraController
current_controller: ^geometry.CameraController
tab_was_pressed: bool

main :: proc() {
  context.logger = log.create_console_logger()
  args := os.args
  log.infof("Starting with %d arguments", len(args))
  if len(args) > 1 {
    log.infof("Running mode: %s", args[1])
  }
  engine := new(mjolnir.Engine)
  engine.setup_proc = setup
  engine.update_proc = update
  engine.key_press_proc = on_key_pressed
  engine.render2d_proc = render_2d
  mjolnir.run(engine, 1280, 720, "Mjolnir")
}

setup :: proc(engine: ^mjolnir.Engine) {
  using mjolnir, geometry
  log.info("Setup function called!")
  plain_material_handle, plain_material_ok := create_material(engine)
  cube_geom := make_cube()
  cube_mesh_handle, cube_mesh_ok := create_mesh(engine, cube_geom)
  sphere_mesh_handle, sphere_mesh_ok := create_mesh(engine, make_sphere())
  cone_mesh_handle, cone_mesh_ok := create_mesh(engine, make_cone())
  if true {
    log.info("spawning cubes in a grid")
    space: f32 = 4.1
    size: f32 = 0.3
    nx, ny, nz := 240, 2, 240
    mat_handle, mat_ok := create_material(
      engine,
      metallic_value = 0.5,
      roughness_value = 0.8,
    )
    if cube_mesh_ok && sphere_mesh_ok && cone_mesh_ok && mat_ok {
      spawn_loop: for x in 1 ..< nx {
        for y in 1 ..< ny {
          for z in 1 ..< nz {
            world_x := (f32(x) - f32(nx) * 0.5) * space
            world_y := (f32(y) - f32(ny) * 0.5) * space + 0.5
            world_z := (f32(z) - f32(nz)) * space
            node_handle: resources.Handle
            node_ok := false
            if x % 3 == 0 {
              node_handle, _, node_ok = spawn(
                engine,
                world.MeshAttachment {
                  handle = cube_mesh_handle,
                  material = mat_handle,
                  // cast_shadow = true,
                },
              )
            } else if x % 3 == 1 {
              node_handle, _, node_ok = spawn(
                engine,
                world.MeshAttachment {
                  handle = cone_mesh_handle,
                  material = mat_handle,
                  // cast_shadow = true,
                },
              )
            } else {
              node_handle, _, node_ok = spawn(
                engine,
                world.MeshAttachment {
                  handle = sphere_mesh_handle,
                  material = mat_handle,
                  // cast_shadow = true,
                },
              )
            }
            if !node_ok do break spawn_loop
            translate(engine, node_handle, world_x, world_y, world_z)
            scale(engine, node_handle, size)
          }
        }
      }
    }
  }
  when true {
    // Create ground plane
    brick_wall_mat_handle = {}
    brick_wall_mat_ok := false
    brick_albedo_handle, brick_albedo_ok := create_texture(
      engine,
      "assets/t_brick_floor_002_diffuse_1k.jpg",
    )
    if brick_albedo_ok {
      brick_wall_mat_handle, brick_wall_mat_ok = create_material(
        engine,
        {.ALBEDO_TEXTURE},
        albedo_handle = brick_albedo_handle,
      )
    }
    ground_mesh_handle, ground_mesh_ok := create_mesh(
      engine,
      geometry.make_quad(),
    )
    log.info("spawning ground and walls")
    // Ground node
    size: f32 = 15.0
    if brick_wall_mat_ok && ground_mesh_ok {
      _, ground_node, ground_ok := spawn(
        engine,
        world.MeshAttachment {
          handle = ground_mesh_handle,
          material = brick_wall_mat_handle,
        },
      )
      if ground_ok do scale(ground_node, size)
      // Left wall
      _, left_wall, left_ok := spawn(
        engine,
        world.MeshAttachment {
          handle = ground_mesh_handle,
          material = brick_wall_mat_handle,
        },
      )
      if left_ok {
        translate(left_wall, x = size, y = size)
        rotate(left_wall, math.PI * 0.5, linalg.VECTOR3F32_Z_AXIS)
        scale(left_wall, size)
      }
      // Right wall
      _, right_wall, right_ok := spawn(
        engine,
        world.MeshAttachment {
          handle = ground_mesh_handle,
          material = brick_wall_mat_handle,
        },
      )
      if right_ok {
        translate(right_wall, x = -size, y = size)
        rotate(right_wall, -math.PI * 0.5, linalg.VECTOR3F32_Z_AXIS)
        scale(right_wall, size)
      }
      // Back wall
      _, back_wall, back_ok := spawn(
        engine,
        world.MeshAttachment {
          handle = ground_mesh_handle,
          material = brick_wall_mat_handle,
        },
      )
      if back_ok {
        translate(back_wall, y = size, z = -size)
        rotate(back_wall, math.PI * 0.5, linalg.VECTOR3F32_X_AXIS)
        scale(back_wall, size)
      }
      // Ceiling
      _, ceiling, ceiling_ok := spawn(
        engine,
        world.MeshAttachment {
          handle = ground_mesh_handle,
          material = brick_wall_mat_handle,
        },
      )
      if ceiling_ok {
        translate(ceiling, y = 2 * size)
        rotate(ceiling, -math.PI, linalg.VECTOR3F32_X_AXIS)
        scale(ceiling, size)
      }
    }
  }
  if true {
    log.info("loading Hammer GLTF...")
    gltf_nodes := load_gltf(engine, "assets/Mjolnir.glb") or_else {}
    log.infof("Loaded GLTF nodes: %v", gltf_nodes)
    for handle in gltf_nodes {
      hammer_handle = handle
      translate(engine, handle, 3, 1, -2)
      scale(engine, handle, 0.2)
    }
  }
  if true {
    log.info("loading Damaged Helmet GLTF...")
    gltf_nodes := load_gltf(engine, "assets/DamagedHelmet.glb") or_else {}
    log.infof("Loaded GLTF nodes: %v", gltf_nodes)
    for handle in gltf_nodes {
      translate(engine, handle, 0, 1, 3)
      scale(engine, handle, 0.5)
    }
  }
  if true {
    log.info("loading Suzanne GLTF...")
    gltf_nodes := load_gltf(engine, "assets/Suzanne.glb") or_else {}
    log.infof("Loaded GLTF nodes: %v", gltf_nodes)
    for handle in gltf_nodes {
      translate(engine, handle, -3, 1, -17)
    }
  }
  if false {
    log.info("loading Warrior GLTF...")
    gltf_nodes := load_gltf(engine, "assets/Warrior.glb") or_else {}
    log.infof("Loaded GLTF nodes: %v", gltf_nodes)
    for armature in gltf_nodes {
      armature_ptr := get_node(engine, armature)
      if armature_ptr == nil do continue
      for i in 1 ..< len(armature_ptr.children) {
        play_animation(engine, armature_ptr.children[i], "idle")
      }
      translate_node(armature_ptr, 0, 0, 1)
      // Attach a cube to the hand.L bone
      for child_handle in armature_ptr.children {
        child_node := get_node(engine, child_handle)
        if child_node == nil do continue

        if mesh_attachment, has_mesh := child_node.attachment.(world.MeshAttachment);
           has_mesh {
          if _, has_skin := mesh_attachment.skinning.?; has_skin {
            if plain_material_ok && cube_mesh_ok {
              _, cube_node, cube_ok := spawn_child(
                engine,
                child_handle,
                world.MeshAttachment {
                  handle = cube_mesh_handle,
                  material = plain_material_handle,
                  cast_shadow = true,
                },
              )
              if cube_ok {
                cube_node.bone_socket = "hand.L"
                scale(cube_node, 0.1)
              }
            }
            break
          }
        }
      }
    }
  }
  when true {
    log.infof("creating %d lights", LIGHT_COUNT)
    // Create lights and light cubes
    for i in 0 ..< LIGHT_COUNT {
      color := [4]f32 {
        math.sin(f32(i)),
        math.cos(f32(i)),
        math.sin(f32(i)),
        1.0,
      }
      should_make_spot_light := i % 2 != 1
      if ALL_SPOT_LIGHT {
        should_make_spot_light = true
      } else if ALL_POINT_LIGHT {
        should_make_spot_light = false
      }
      light: ^world.Node
      light_spawn_ok: bool
      if should_make_spot_light {
        light_handles[i], light, light_spawn_ok = spawn_spot_light(
          engine,
          color,
          10,
          math.PI * 0.25,
          {6, 2, -1},
        )
        if !light_spawn_ok do continue
        rotate(light, math.PI * 0.4, linalg.VECTOR3F32_X_AXIS)
      } else {
        light_handles[i], light, light_spawn_ok = spawn_point_light(
          engine,
          color,
          14,
          {6, 2, -1},
        )
        if !light_spawn_ok do continue
      }
      if plain_material_ok && cube_mesh_ok {
        cube_node: ^world.Node
        cube_ok: bool
        light_cube_handles[i], cube_node, cube_ok = spawn_child(
          engine,
          light_handles[i],
          world.MeshAttachment {
            handle = cube_mesh_handle,
            material = plain_material_handle,
            cast_shadow = false,
          },
        )
        if cube_ok {
          scale(cube_node, 0.1)
        }
      }
    }
    if false {
      _, dir_node, ok := spawn_directional_light(
        engine,
        {0.2, 0.5, 0.9, 1.0},
        true,
        {0, 10, 0},
      )
      if ok {
        rotate(dir_node, math.PI * 0.25, linalg.VECTOR3F32_X_AXIS)
      }
    }
  }
  when false {
    log.info("Setting up bloom...")
    // add_bloom(&engine.postprocess, 0.8, 0.5, 16.0)
    // Create a bright white ball to test bloom effect
    emissive_handle, emissive_ok := create_material(
      engine,
      emissive_value = 30.0,
    )
    if emissive_ok && sphere_mesh_ok {
      _, bright_ball_node, bright_ok := spawn(
        engine,
        world.MeshAttachment {
          handle      = sphere_mesh_handle,
          material    = emissive_handle,
          cast_shadow = false, // Emissive objects don't need shadows
        },
      )
      if bright_ok {
        translate(bright_ball_node, x = 1.0)
        scale(bright_ball_node, 0.2)
      }
    }
  }
  when true {
    log.info("Setting up particles...")
    black_circle_texture_handle, black_circle_ok := create_texture(
      engine,
      "assets/black-circle.png",
    )
    goldstar_texture_handle, goldstar_texture_ok := create_texture(
      engine,
      "assets/gold-star.png",
    )
    goldstar_material_handle: resources.Handle
    goldstar_material_ok := false
    if goldstar_texture_ok {
      goldstar_material_handle, goldstar_material_ok = create_material(
        engine,
        {.ALBEDO_TEXTURE},
        type = .TRANSPARENT,
        albedo_handle = goldstar_texture_handle,
      )
    }
    psys_handle1, _, psys1_ok := spawn_at(engine, {-2.0, 1.9, 0.3})
    if psys1_ok && goldstar_texture_ok {
      emitter_handle1, emitter1_ok := create_emitter(
        engine,
        psys_handle1,
        resources.Emitter {
          emission_rate = 7,
          particle_lifetime = 5.0,
          position_spread = 1.5,
          initial_velocity = {0, -0.1, 0, 0},
          velocity_spread = 0.1,
          color_start = {1, 1, 0, 1},
          color_end = {1, 0.5, 0, 0},
          size_start = 200.0,
          size_end = 100.0,
          weight = 0.1,
          weight_spread = 0.05,
          texture_handle = goldstar_texture_handle,
          enabled = true,
          aabb_min = {-2, -2, -2},
          aabb_max = {2, 2, 2},
        },
      )
      if emitter1_ok {
        _, _, _ = spawn_child(
          engine,
          psys_handle1,
          world.EmitterAttachment{emitter_handle1},
        )
      }
    }
    psys_handle2, _, psys2_ok := spawn_at(engine, {2.0, 1.9, 0.3})
    if psys2_ok && black_circle_ok {
      emitter_handle2, emitter2_ok := create_emitter(
        engine,
        psys_handle2,
        resources.Emitter {
          emission_rate = 7,
          particle_lifetime = 3.0,
          position_spread = 0.3,
          initial_velocity = {0, 0.2, 0, 0},
          velocity_spread = 0.15,
          color_start = {0, 0, 1, 1},
          color_end = {0, 1, 1, 0},
          size_start = 350.0,
          size_end = 175.0,
          weight = 0.1,
          weight_spread = 0.3,
          texture_handle = black_circle_texture_handle,
          enabled = true,
          aabb_min = {-1, -1, -1},
          aabb_max = {1, 1, 1},
        },
      )
      if emitter2_ok {
        _, _, _ = spawn_child(
          engine,
          psys_handle2,
          world.EmitterAttachment{emitter_handle2},
        )
      }
    }
    if psys1_ok {
      forcefield_ok: bool
      forcefield_handle, _, forcefield_ok = spawn_child(
        engine,
        psys_handle1,
        world.ForceFieldAttachment{},
      )
      if forcefield_ok {
        translate(engine, forcefield_handle, 5.0, 0.0, 0.0)
        forcefield_resource, ff_ok := create_forcefield(
          engine,
          forcefield_handle,
          resources.ForceField {
            tangent_strength = 2.0,
            strength = 20.0,
            area_of_effect = 5.0,
          },
        )
        if ff_ok {
          ff_node := get_node(engine, forcefield_handle)
          if ff_node != nil {
            ff_attachment := &ff_node.attachment.(world.ForceFieldAttachment)
            ff_attachment.handle = forcefield_resource
          }
        }
        if goldstar_material_ok && sphere_mesh_ok {
          _, forcefield_visual, visual_ok := spawn_child(
            engine,
            forcefield_handle,
            world.MeshAttachment {
              handle = sphere_mesh_handle,
              material = goldstar_material_handle,
              cast_shadow = false,
            },
          )
          if visual_ok do world.scale(forcefield_visual, 0.2)
        }
      }
    }
  }
  add_fog(engine, [3]f32{0.4, 0.0, 0.8}, 0.02, 5.0, 20.0)
  // add_bloom(engine)
  add_crosshatch(engine, [2]f32{1280, 720})
  // add_blur(engine, 18.0)
  // add_tonemap(engine, 1.5, 1.3)
  // add_dof(engine)
  // add_grayscale(engine, 0.9)
  // add_outline(engine, 2.0, [3]f32{1.0, 0.0, 0.0})
  setup_camera_controller_callbacks(engine.window)
  main_camera := get_main_camera(engine)
  orbit_controller = camera_controller_orbit_init(engine.window)
  free_controller = camera_controller_free_init(engine.window)
  if main_camera != nil {
    camera_controller_sync(&orbit_controller, main_camera)
    camera_controller_sync(&free_controller, main_camera)
  }
  current_controller = &orbit_controller
  when false {
    log.info("Setting up portal...")
    idx, portal_ok := create_render_target(
      engine,
      512,
      512,
      .R8G8B8A8_UNORM,
      .D32_SFLOAT,
      camera_position = {5, 15, 7},
      camera_target = {0, 0, 0},
    )
    portal_render_target_index = idx
    if !portal_ok {
      log.error("Failed to create portal scene capture")
    }
    log.infof(
      "Portal scene capture created at index: %d",
      portal_render_target_index,
    )
    portal_material_handle = {}
    portal_material_ok := false
    portal_material_handle, portal_material_ok = create_material(
      engine,
      {.ALBEDO_TEXTURE},
    )
    log.infof(
      "Portal material created with handle: %v",
      portal_material_handle,
    )
    portal_mesh_handle, portal_mesh_ok := create_mesh(
      engine,
      geometry.make_quad(),
    )
    if portal_material_ok && portal_mesh_ok {
      _, portal_node, portal_spawn_ok := spawn(
        engine,
        world.MeshAttachment {
          handle = portal_mesh_handle,
          material = portal_material_handle,
          cast_shadow = false,
        },
      )
      if portal_spawn_ok {
        translate(portal_node, 0, 3, -5)
        rotate(portal_node, math.PI * 0.5, linalg.VECTOR3F32_X_AXIS)
        scale(portal_node, 2.0)
      }
    }
  }
  log.info("setup complete")
}

update :: proc(engine: ^mjolnir.Engine, delta_time: f32) {
  using mjolnir, geometry
  if main_camera := get_main_camera(engine); main_camera != nil {
    if current_controller == &orbit_controller {
      camera_controller_orbit_update(
        current_controller,
        main_camera,
        delta_time,
      )
    } else {
      camera_controller_free_update(
        current_controller,
        main_camera,
        delta_time,
      )
    }
  }
  t := time_since_start(engine) * 0.5
  translate(
    engine,
    forcefield_handle,
    math.cos(t) * 2.0,
    2.0,
    math.sin(t) * 2.0,
  )
  // Animate lights
  for handle, i in light_handles {
    if i == 0 {
      // Rotate light 0 around Y axis
      t := time_since_start(engine)
      rotate(engine, handle, t, linalg.VECTOR3F32_Y_AXIS)
      rotate_by(engine, handle, math.PI * 0.3, linalg.VECTOR3F32_X_AXIS)
      continue
    }
    offset := f32(i) / f32(LIGHT_COUNT) * math.PI * 2.0
    t := time_since_start(engine) + offset
    // log.infof("getting light %d %v", i, handle)
    rx := math.sin(t)
    ry := (math.sin(t) + 1.0) * 0.5 * 1.5 + 0.5
    rz := math.cos(t)
    v := linalg.normalize([3]f32{rx, ry, rz})
    radius: f32 = 15.0
    v = v * radius + linalg.VECTOR3F32_Y_AXIS * -1.0
    translate(engine, handle, v.x, v.y, v.z)
    rotate_by(
      engine,
      light_cube_handles[i],
      math.PI * time_since_start(engine) * 0.5,
      linalg.VECTOR3F32_Y_AXIS,
    )
  }
  if portal_render_target_index >= 0 {
    portal_rt, rt_ok := get_render_target_camera(
      engine,
      portal_render_target_index,
    )
    if rt_ok {
      portal_camera, camera_ok := get_camera(engine, portal_rt)
      if camera_ok {
        // Animate portal camera - orbit around the scene center
        portal_t := time_since_start(engine) * 0.3
        radius: f32 = 12.0
        height: f32 = 8.0
        camera_x := math.cos(portal_t) * radius
        camera_z := math.sin(portal_t) * radius
        camera_pos := [3]f32{camera_x, height, camera_z}
        target := [3]f32{0, 0, 0}
        geometry.camera_look_at(portal_camera, camera_pos, target, {0, 1, 0})
      }
      // Update portal material to use render target output
      // Use previous frame's output since current frame hasn't been rendered yet
      prev_frame :=
        (engine.frame_index + resources.MAX_FRAMES_IN_FLIGHT - 1) %
        resources.MAX_FRAMES_IN_FLIGHT
      portal_mat, mat_ok := get_material(engine, portal_material_handle)
      if mat_ok {
        portal_output, output_ok := renderer_get_render_target_output(
          &engine.render,
          portal_render_target_index,
          &engine.resource_manager,
          prev_frame,
        )
        if output_ok {
          portal_mat.albedo = portal_output
          resources.material_write_to_gpu(
            &engine.resource_manager,
            portal_material_handle,
            portal_mat,
          )
        }
      }
    }
  }
}

on_key_pressed :: proc(engine: ^mjolnir.Engine, key, action, mods: int) {
  using mjolnir, geometry
  log.infof("key pressed key %d action %d mods %x", key, action, mods)
  if action != glfw.PRESS do return
  if key == glfw.KEY_LEFT {
    translate_by(engine, light_handles[0], 0.1, 0.0, 0.0)
  } else if key == glfw.KEY_RIGHT {
    translate_by(engine, light_handles[0], -0.1, 0.0, 0.0)
  } else if key == glfw.KEY_UP {
    translate_by(engine, light_handles[0], 0.0, 0.1, 0.0)
  } else if key == glfw.KEY_DOWN {
    translate_by(engine, light_handles[0], 0.0, -0.1, 0.0)
  } else if key == glfw.KEY_Z {
    translate_by(engine, light_handles[0], 0.0, 0.0, 0.1)
  } else if key == glfw.KEY_X {
    translate_by(engine, light_handles[0], 0.0, 0.0, -0.1)
  } else if key == glfw.KEY_TAB {
    main_camera_for_sync := get_main_camera(engine)
    if current_controller == &orbit_controller {
      current_controller = &free_controller
      log.info("Switched to free camera")
    } else {
      current_controller = &orbit_controller
      log.info("Switched to orbit camera")
    }
    // Sync new controller with current camera state to prevent jumps
    if main_camera_for_sync != nil {
      camera_controller_sync(current_controller, main_camera_for_sync)
    }
  }
}

render_2d :: proc(engine: ^mjolnir.Engine, ctx: ^mu.Context) {
  text.draw_text(
    &engine.render.text,
    "Mjolnir",
    600,
    60,
    48,
    {255, 255, 255, 255},
  )
}

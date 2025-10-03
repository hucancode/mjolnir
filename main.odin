package main

import "core:log"
import "core:math"
import "core:math/linalg"
import "core:os"
import "mjolnir"
import "mjolnir/geometry"
import "mjolnir/render/post_process"
import "mjolnir/render/text"
import "mjolnir/resources"
import "mjolnir/world"
import "vendor:glfw"
import mu "vendor:microui"
import vk "vendor:vulkan"

LIGHT_COUNT :: 10
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
  plain_material_handle, plain_material_ok := resources.create_material_handle(
    &engine.resource_manager,
  )
  cube_geom := make_cube()
  cube_mesh_handle, cube_mesh_ok := resources.create_mesh_handle(
    &engine.gpu_context,
    &engine.resource_manager,
    cube_geom,
  )
  sphere_mesh_handle, sphere_mesh_ok := resources.create_mesh_handle(
    &engine.gpu_context,
    &engine.resource_manager,
    make_sphere(),
  )
  cone_mesh_handle, cone_mesh_ok := resources.create_mesh_handle(
    &engine.gpu_context,
    &engine.resource_manager,
    make_cone(),
  )
  if true {
    log.info("spawning cubes in a grid")
    space: f32 = 2.1
    size: f32 = 0.3
    nx, ny, nz := 40, 2, 40
    mat_handle, mat_ok := resources.create_material_handle(
      &engine.resource_manager,
      metallic_value = 0.5,
      roughness_value = 0.8,
    )
    if cube_mesh_ok && sphere_mesh_ok && cone_mesh_ok && mat_ok {
      spawn_failed := false
      for x in 1 ..< nx {
        if spawn_failed do break
        for y in 1 ..< ny {
          if spawn_failed do break
          for z in 1 ..< nz {
            if spawn_failed do break
            world_x := (f32(x) - f32(nx) * 0.5) * space
            world_y := (f32(y) - f32(ny) * 0.5) * space + 0.5
            world_z := (f32(z) - f32(nz) * 0.5) * space
            node: ^world.Node
            node_ok := false
            if x % 3 == 0 {
              _, node, node_ok = world.spawn(
                &engine.world,
                world.MeshAttachment {
                  handle = cube_mesh_handle,
                  material = mat_handle,
                  cast_shadow = true,
                },
              )
            } else if x % 3 == 1 {
              _, node, node_ok = world.spawn(
                &engine.world,
                world.MeshAttachment {
                  handle = cone_mesh_handle,
                  material = mat_handle,
                  cast_shadow = true,
                },
              )
            } else {
              _, node, node_ok = world.spawn(
                &engine.world,
                world.MeshAttachment {
                  handle = sphere_mesh_handle,
                  material = mat_handle,
                  cast_shadow = true,
                },
              )
            }
            if !node_ok {
              spawn_failed = true
              break
            }
            world.translate(node, world_x, world_y, world_z)
            world.scale(node, size)
          }
        }
      }
    }
  }
  when true {
    // Create ground plane
    brick_wall_mat_handle = {}
    brick_wall_mat_ok := false
    brick_albedo_handle, brick_albedo_ok := resources.create_texture_handle(
      &engine.gpu_context,
      &engine.resource_manager,
      "assets/t_brick_floor_002_diffuse_1k.jpg",
    )
    if brick_albedo_ok {
      brick_wall_mat_handle, brick_wall_mat_ok = resources.create_material_handle(
        &engine.resource_manager,
        {.ALBEDO_TEXTURE},
        albedo_handle = brick_albedo_handle,
      )
    }
    ground_mesh_handle, ground_mesh_ok := resources.create_mesh_handle(
      &engine.gpu_context,
      &engine.resource_manager,
      make_quad(),
    )
    log.info("spawning ground and walls")
    // Ground node
    size: f32 = 15.0
    if brick_wall_mat_ok && ground_mesh_ok {
      _, ground_node, ground_ok := world.spawn(
        &engine.world,
        world.MeshAttachment {
          handle = ground_mesh_handle,
          material = brick_wall_mat_handle,
        },
      )
      if ground_ok do world.scale(ground_node, size)
      // Left wall
      _, left_wall, left_ok := world.spawn(
        &engine.world,
        world.MeshAttachment {
          handle = ground_mesh_handle,
          material = brick_wall_mat_handle,
        },
      )
      if left_ok {
        world.translate(left_wall, x = size, y = size)
        world.rotate(left_wall, math.PI * 0.5, linalg.VECTOR3F32_Z_AXIS)
        world.scale(left_wall, size)
      }
      // Right wall
      _, right_wall, right_ok := world.spawn(
        &engine.world,
        world.MeshAttachment {
          handle = ground_mesh_handle,
          material = brick_wall_mat_handle,
        },
      )
      if right_ok {
        world.translate(right_wall, x = -size, y = size)
        world.rotate(right_wall, -math.PI * 0.5, linalg.VECTOR3F32_Z_AXIS)
        world.scale(right_wall, size)
      }
      // Back wall
      _, back_wall, back_ok := world.spawn(
        &engine.world,
        world.MeshAttachment {
          handle = ground_mesh_handle,
          material = brick_wall_mat_handle,
        },
      )
      if back_ok {
        world.translate(back_wall, y = size, z = -size)
        world.rotate(back_wall, math.PI * 0.5, linalg.VECTOR3F32_X_AXIS)
        world.scale(back_wall, size)
      }
      // Ceiling
      _, ceiling, ceiling_ok := world.spawn(
        &engine.world,
        world.MeshAttachment {
          handle = ground_mesh_handle,
          material = brick_wall_mat_handle,
        },
      )
      if ceiling_ok {
        world.translate(ceiling, y = 2 * size)
        world.rotate(ceiling, -math.PI, linalg.VECTOR3F32_X_AXIS)
        world.scale(ceiling, size)
      }
    }
  }
  if true {
    log.info("loading Hammer GLTF...")
    gltf_nodes :=
      world.load_gltf(
        &engine.world,
        &engine.resource_manager,
        &engine.gpu_context,
        "assets/Mjolnir.glb",
      ) or_else {}
    log.infof("Loaded GLTF nodes: %v", gltf_nodes)
    for handle in gltf_nodes {
      hammer_handle = handle
      world.translate(&engine.world, handle, 3, 1, -2)
      world.scale(&engine.world, handle, 0.2)
    }
  }
  if true {
    log.info("loading Damaged Helmet GLTF...")
    gltf_nodes :=
      world.load_gltf(
        &engine.world,
        &engine.resource_manager,
        &engine.gpu_context,
        "assets/DamagedHelmet.glb",
      ) or_else {}
    log.infof("Loaded GLTF nodes: %v", gltf_nodes)
    for handle in gltf_nodes {
      world.translate(&engine.world, handle, 0, 1, 3)
      world.scale(&engine.world, handle, 0.5)
    }
  }
  if true {
    log.info("loading Suzanne GLTF...")
    gltf_nodes :=
      world.load_gltf(
        &engine.world,
        &engine.resource_manager,
        &engine.gpu_context,
        "assets/Suzanne.glb",
      ) or_else {}
    log.infof("Loaded GLTF nodes: %v", gltf_nodes)
    for handle in gltf_nodes {
      world.translate(&engine.world, handle, -3, 1, -2)
    }
  }
  if true {
    log.info("loading Warrior GLTF...")
    gltf_nodes :=
      world.load_gltf(
        &engine.world,
        &engine.resource_manager,
        &engine.gpu_context,
        "assets/Warrior.glb",
      ) or_else {}
    log.infof("Loaded GLTF nodes: %v", gltf_nodes)
    for armature in gltf_nodes {
      armature_ptr := world.get_node(&engine.world, armature)
      if armature_ptr == nil do continue
      for i in 1 ..< len(armature_ptr.children) {
        world.play_animation(
          &engine.world,
          &engine.resource_manager,
          armature_ptr.children[i],
          "idle",
        )
      }
      world.translate(armature_ptr, 0, 0, 1)
      // Attach a cube to the hand.L bone
      for child_handle in armature_ptr.children {
        child_node := world.get_node(&engine.world, child_handle)
        if child_node == nil do continue

        if mesh_attachment, has_mesh := child_node.attachment.(world.MeshAttachment);
           has_mesh {
          if _, has_skin := mesh_attachment.skinning.?; has_skin {
            if plain_material_ok && cube_mesh_ok {
              _, cube_node, cube_ok := world.spawn_child(
                &engine.world,
                child_handle,
                world.MeshAttachment {
                  handle = cube_mesh_handle,
                  material = plain_material_handle,
                  cast_shadow = true,
                },
              )
              if cube_ok {
                cube_node.bone_socket = "hand.L"
                world.scale(cube_node, 0.1)
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
      light: ^world.Node
      should_make_spot_light := i % 2 != 1
      if ALL_SPOT_LIGHT {
        should_make_spot_light = true
      } else if ALL_POINT_LIGHT {
        should_make_spot_light = false
      }
      light_spawn_ok: bool
      if should_make_spot_light {
        attachment := world.create_spot_light_attachment(
          light_handles[i],
          &engine.resource_manager,
          &engine.gpu_context,
          color,
          10, // radius
          math.PI * 0.25, // angle
        ) or_continue
        light_handles[i], light, light_spawn_ok = world.spawn(
          &engine.world,
          attachment,
          &engine.resource_manager,
        )
        if !light_spawn_ok {
          continue
        }
        world.rotate(light, math.PI * 0.4, linalg.VECTOR3F32_X_AXIS)
      } else {
        attachment := world.create_point_light_attachment(
          light_handles[i],
          &engine.resource_manager,
          &engine.gpu_context,
          color,
          14, // radius
        ) or_continue
        light_handles[i], light, light_spawn_ok = world.spawn(
          &engine.world,
          attachment,
          &engine.resource_manager,
        )
        if !light_spawn_ok {
          continue
        }
      }
      world.translate(light, 6, 2, -1)
      if plain_material_ok && cube_mesh_ok {
        cube_node: ^world.Node
        cube_ok: bool
        light_cube_handles[i], cube_node, cube_ok = world.spawn_child(
          &engine.world,
          light_handles[i],
          world.MeshAttachment {
            handle = cube_mesh_handle,
            material = plain_material_handle,
            cast_shadow = false,
          },
        )
        if cube_ok {
          world.scale(cube_node, 0.1)
        }
      }
    }
    if false {
      dir_handle, dir_node, ok := world.spawn(
        &engine.world,
        nil,
        &engine.resource_manager,
      )
      if ok {
        attachment := world.create_directional_light_attachment(
          dir_handle,
          &engine.resource_manager,
          &engine.gpu_context,
          {0.2, 0.5, 0.9, 1.0},
          true,
        )
        if attachment.handle.generation == 0 {
          world.despawn(&engine.world, dir_handle)
        } else {
          dir_node.attachment = attachment
          world.translate(dir_node, 0, 10, 0)
          world.rotate(dir_node, math.PI * 0.25, linalg.VECTOR3F32_X_AXIS)
        }
      }
    }
  }
  when false {
    log.info("Setting up bloom...")
    // add_bloom(&engine.postprocess, 0.8, 0.5, 16.0)
    // Create a bright white ball to test bloom effect
    emissive_handle, emissive_ok := resources.create_material_handle(
      &engine.resource_manager,
      emissive_value = 30.0,
    )
    if emissive_ok && sphere_mesh_ok {
      _, bright_ball_node, bright_ok := world.spawn(
        &engine.world,
        world.MeshAttachment {
          handle      = sphere_mesh_handle,
          material    = emissive_handle,
          cast_shadow = false, // Emissive objects don't need shadows
        },
      )
      if bright_ok {
        world.translate(bright_ball_node, x = 1.0)
        world.scale(bright_ball_node, 0.2)
      }
    }
  }
  when true {
    log.info("Setting up particles...")
    black_circle_texture_handle, black_circle_ok := resources.create_texture_handle(
      &engine.gpu_context,
      &engine.resource_manager,
      "assets/black-circle.png",
    )
    goldstar_texture_handle, goldstar_texture_ok := resources.create_texture_handle(
      &engine.gpu_context,
      &engine.resource_manager,
      "assets/gold-star.png",
    )
    goldstar_material_handle: resources.Handle
    goldstar_material_ok := false
    if goldstar_texture_ok {
      goldstar_material_handle, goldstar_material_ok = resources.create_material_handle(
        &engine.resource_manager,
        {.ALBEDO_TEXTURE},
        type = .TRANSPARENT,
        albedo_handle = goldstar_texture_handle,
      )
    }
    psys_handle1, _, psys1_ok := world.spawn_at(&engine.world, {-2.0, 1.9, 0.3})
    if psys1_ok && goldstar_texture_ok {
      emitter_handle1, emitter1_ok := resources.create_emitter_handle(
        &engine.resource_manager,
        psys_handle1,
        resources.Emitter {
          emission_rate     = 7,
          particle_lifetime = 5.0,
          position_spread   = 1.5,
          initial_velocity  = {0, -0.1, 0, 0},
          velocity_spread   = 0.1,
          color_start       = {1, 1, 0, 1},
          color_end         = {1, 0.5, 0, 0},
          size_start        = 200.0,
          size_end          = 100.0,
          weight            = 0.1,
          weight_spread     = 0.05,
          texture_handle    = goldstar_texture_handle,
          enabled           = true,
          aabb_min          = {-2, -2, -2},
          aabb_max          = {2, 2, 2},
        },
      )
      if emitter1_ok {
        _, _, _ = world.spawn_child(
          &engine.world,
          psys_handle1,
          world.EmitterAttachment{emitter_handle1},
          &engine.resource_manager,
        )
      }
    }
    psys_handle2, _, psys2_ok := world.spawn_at(&engine.world, {2.0, 1.9, 0.3})
    if psys2_ok && black_circle_ok {
      emitter_handle2, emitter2_ok := resources.create_emitter_handle(
        &engine.resource_manager,
        psys_handle2,
        resources.Emitter {
          emission_rate     = 7,
          particle_lifetime = 3.0,
          position_spread   = 0.3,
          initial_velocity  = {0, 0.2, 0, 0},
          velocity_spread   = 0.15,
          color_start       = {0, 0, 1, 1},
          color_end         = {0, 1, 1, 0},
          size_start        = 350.0,
          size_end          = 175.0,
          weight            = 0.1,
          weight_spread     = 0.3,
          texture_handle    = black_circle_texture_handle,
          enabled           = true,
          aabb_min          = {-1, -1, -1},
          aabb_max          = {1, 1, 1},
        },
      )
      if emitter2_ok {
        _, _, _ = world.spawn_child(
          &engine.world,
          psys_handle2,
          world.EmitterAttachment{emitter_handle2},
          &engine.resource_manager,
        )
      }
    }
    if psys1_ok {
      forcefield_ok: bool
      forcefield_handle, _, forcefield_ok = world.spawn_child(
        &engine.world,
        psys_handle1,
        world.ForceFieldAttachment{},
      )
      if forcefield_ok {
        world.translate(&engine.world, forcefield_handle, 5.0, 0.0, 0.0)
        forcefield_resource, ff_ok := resources.create_forcefield_handle(
          &engine.resource_manager,
          forcefield_handle,
          resources.ForceField {
            tangent_strength = 2.0,
            strength = 20.0,
            area_of_effect = 5.0,
          },
        )
        if ff_ok {
          ff_node := world.get_node(&engine.world, forcefield_handle)
          if ff_node != nil {
            ff_attachment := &ff_node.attachment.(world.ForceFieldAttachment)
            ff_attachment.handle = forcefield_resource
          }
        }
        if goldstar_material_ok && sphere_mesh_ok {
          _, forcefield_visual, visual_ok := world.spawn_child(
            &engine.world,
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
  post_process.add_fog(
    &engine.render.post_process,
    [3]f32{0.4, 0.0, 0.8},
    0.02,
    5.0,
    20.0,
  )
  // post_process.add_bloom(&engine.render.post_process)
  post_process.add_crosshatch(&engine.render.post_process, [2]f32{1280, 720})
  // post_process.add_blur(&engine.render.post_process, 18.0)
  // post_process.add_tonemap(&engine.render.post_process, 1.5, 1.3)
  // post_process.add_dof(&engine.render.post_process)
  // post_process.add_grayscale(&engine.render.post_process, 0.9)
  // post_process.add_outline(&engine.render.post_process, 2.0, [3]f32{1.0, 0.0, 0.0})
  setup_camera_controller_callbacks(engine.window)
  main_camera := get_main_camera(engine)
  orbit_controller = camera_controller_orbit_init(engine.window)
  free_controller = camera_controller_free_init(engine.window)
  if main_camera != nil {
    camera_controller_sync(&orbit_controller, main_camera)
    camera_controller_sync(&free_controller, main_camera)
  }
  current_controller = &orbit_controller
  when true {
    log.info("Setting up portal...")
    idx, portal_ok := mjolnir.renderer_add_render_target(
      &engine.render,
      &engine.gpu_context,
      &engine.resource_manager,
      512,
      512,
      vk.Format.R8G8B8A8_UNORM,
      vk.Format.D32_SFLOAT,
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
    portal_material_handle, portal_material_ok = resources.create_material_handle(
      &engine.resource_manager,
      {.ALBEDO_TEXTURE},
    )
    log.infof(
      "Portal material created with handle: %v",
      portal_material_handle,
    )
    portal_mesh_handle, portal_mesh_ok := resources.create_mesh_handle(
      &engine.gpu_context,
      &engine.resource_manager,
      make_quad(),
    )
    if portal_material_ok && portal_mesh_ok {
      _, portal_node, portal_spawn_ok := world.spawn(
        &engine.world,
        world.MeshAttachment {
          handle = portal_mesh_handle,
          material = portal_material_handle,
          cast_shadow = false,
        },
      )
      if portal_spawn_ok {
        world.translate(portal_node, 0, 3, -5)
        world.rotate(portal_node, math.PI * 0.5, linalg.VECTOR3F32_X_AXIS)
        world.scale(portal_node, 2.0)
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
  world.translate(
    &engine.world,
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
      world.rotate(&engine.world, handle, t, linalg.VECTOR3F32_Y_AXIS)
      world.rotate_by(
        &engine.world,
        handle,
        math.PI * 0.3,
        linalg.VECTOR3F32_X_AXIS,
      )
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
    world.translate(&engine.world, handle, v.x, v.y, v.z)
    world.rotate(
      &engine.world,
      light_cube_handles[i],
      math.PI * time_since_start(engine) * 0.5,
    )
  }
  if portal_render_target_index >= 0 {
    portal_rt, rt_ok := renderer_get_render_target(
      &engine.render,
      portal_render_target_index,
    )
    if rt_ok {
      portal_camera, camera_ok := resources.get_camera(
        &engine.resource_manager,
        portal_rt.camera,
      )
      if camera_ok {
        // Animate portal camera - orbit around the scene center
        portal_t := time_since_start(engine) * 0.3
        radius: f32 = 12.0
        height: f32 = 8.0
        camera_x := math.cos(portal_t) * radius
        camera_z := math.sin(portal_t) * radius
        camera_pos := [3]f32{camera_x, height, camera_z}
        target := [3]f32{0, 0, 0}
        camera_look_at(portal_camera, camera_pos, target, {0, 1, 0})
      }
      // Update portal material to use render target output
      // Use previous frame's output since current frame hasn't been rendered yet
      prev_frame :=
        (engine.frame_index + resources.MAX_FRAMES_IN_FLIGHT - 1) %
        resources.MAX_FRAMES_IN_FLIGHT
      portal_mat, mat_ok := resources.get_material(
        &engine.resource_manager,
        portal_material_handle,
      )
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
    world.translate_by(&engine.world, light_handles[0], 0.1, 0, 0)
  } else if key == glfw.KEY_RIGHT {
    world.translate_by(&engine.world, light_handles[0], -0.1, 0, 0)
  } else if key == glfw.KEY_UP {
    world.translate_by(&engine.world, light_handles[0], 0, 0, 0.1)
  } else if key == glfw.KEY_DOWN {
    world.translate_by(&engine.world, light_handles[0], 0, 0, -0.1)
  } else if key == glfw.KEY_Z {
    world.translate_by(&engine.world, light_handles[0], 0, 0.1, 0)
  } else if key == glfw.KEY_X {
    world.translate_by(&engine.world, light_handles[0], 0, -0.1, 0)
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

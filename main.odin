package main

import "core:fmt"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:os"
import "mjolnir"
import "mjolnir/geometry"
import "mjolnir/gpu"
import "mjolnir/resources"
import world "mjolnir/world"
import post_process "mjolnir/render/post_process"
import geometry_pass "mjolnir/render/geometry"
import "vendor:glfw"
import mu "vendor:microui"
import vk "vendor:vulkan"

LIGHT_COUNT :: 5
ALL_SPOT_LIGHT :: false
ALL_POINT_LIGHT :: true
light_handles: [LIGHT_COUNT]mjolnir.Handle
light_cube_handles: [LIGHT_COUNT]mjolnir.Handle
brick_wall_mat_handle: mjolnir.Handle
hammer_handle: mjolnir.Handle
forcefield_handle: mjolnir.Handle

// Portal render target and related data
portal_render_target_handle: mjolnir.Handle
portal_material_handle: mjolnir.Handle
portal_quad_handle: mjolnir.Handle

// Camera controllers
orbit_controller: geometry.CameraController
free_controller: geometry.CameraController
current_controller: ^geometry.CameraController
tab_was_pressed: bool

main :: proc() {
  // Initialize logging
  context.logger = log.create_console_logger()
  args := os.args
  log.infof("Starting with %d arguments", len(args))
  // Check command line arguments
  if len(args) > 1 {
    log.infof("Running mode: %s", args[1])
    switch args[1] {
    case "navmesh":
      demo_main()
      return
    }
  }
  engine:= new(mjolnir.Engine)
  engine.setup_proc = setup
  engine.update_proc = update
  engine.key_press_proc = on_key_pressed
  engine.custom_render_proc = custom_render
  mjolnir.run(engine, 1280, 720, "Mjolnir")
}

setup :: proc(engine: ^mjolnir.Engine) {
  using mjolnir, geometry
  log.info("Setup function called!")
  plain_material_handle := resources.create_material_handle(&engine.resource_manager)
  wireframe_material_handle := resources.create_material_handle(
    &engine.resource_manager,
    type = .WIREFRAME,
  )
  cube_geom := make_cube()
  cube_mesh_handle := resources.create_mesh_handle(
    &engine.gpu_context,
    &engine.resource_manager,
    cube_geom,
  )
  sphere_mesh_handle := resources.create_mesh_handle(
    &engine.gpu_context,
    &engine.resource_manager,
    make_sphere(),
  )
  cone_mesh_handle := resources.create_mesh_handle(
    &engine.gpu_context,
    &engine.resource_manager,
    make_cone(),
  )
  if true {
    log.info("spawning cubes in a grid")
    space: f32 = 2.1
    size: f32 = 0.3
    nx, ny, nz := 40, 2, 40

    for x in 1 ..< nx {
      for y in 1 ..< ny {
        for z in 1 ..< nz {
          // Calculate world position
          world_x := (f32(x) - f32(nx) * 0.5) * space
          world_y := (f32(y) - f32(ny) * 0.5) * space + 0.5
          world_z := (f32(z) - f32(nz) * 0.5) * space
          mat_handle := resources.create_material_handle(
            &engine.resource_manager,
            metallic_value = f32(x - 1) / f32(nx - 1),
            roughness_value = f32(z - 1) / f32(nz - 1),
          )
          node: ^Node
          if x % 3 == 0 {
            _, node = world.spawn(
              &engine.world,
              world.MeshAttachment {
                handle = cube_mesh_handle,
                material = mat_handle,
                cast_shadow = true,
              },
            )
          } else if x % 3 == 1 {
            _, node = world.spawn(
              &engine.world,
              MeshAttachment {
                handle = cone_mesh_handle,
                material = mat_handle,
                cast_shadow = true,
              },
            )
          } else {
            _, node = world.spawn(
              &engine.world,
              MeshAttachment {
                handle = sphere_mesh_handle,
                material = mat_handle,
                cast_shadow = true,
              },
            )
          }
          world.translate(node, world_x, world_y, world_z)
          world.scale(node, size)
        }
      }
    }
  }
  when true {
      // Create ground plane
      brick_wall_mat_handle = resources.create_material_handle(
        &engine.resource_manager,
        {.ALBEDO_TEXTURE},
        albedo_handle = resources.create_texture_handle(
          &engine.gpu_context,
          &engine.resource_manager,
          "assets/t_brick_floor_002_diffuse_1k.jpg",
        ),
      )
      ground_mesh_handle := resources.create_mesh_handle(
        &engine.gpu_context,
        &engine.resource_manager,
        make_quad(),
      )
    log.info("spawning ground and walls")
    // Ground node
    size: f32 = 15.0
    _, ground_node := world.spawn(
      &engine.world,
      MeshAttachment {
        handle = ground_mesh_handle,
        material = brick_wall_mat_handle,
      },
    )
    world.scale(ground_node, size)
    // Left wall
    _, left_wall := world.spawn(
      &engine.world,
      MeshAttachment {
        handle = ground_mesh_handle,
        material = brick_wall_mat_handle,
      },
    )
    world.translate(left_wall, x = size, y = size)
    world.rotate(left_wall, math.PI * 0.5, linalg.VECTOR3F32_Z_AXIS)
    world.scale(left_wall, size)
    // Right wall
    _, right_wall := world.spawn(
      &engine.world,
      MeshAttachment {
        handle = ground_mesh_handle,
        material = brick_wall_mat_handle,
      },
    )
    world.translate(right_wall, x = -size, y = size)
    world.rotate(right_wall, -math.PI * 0.5, linalg.VECTOR3F32_Z_AXIS)
    world.scale(right_wall, size)
    // Back wall
    _, back_wall := world.spawn(
      &engine.world,
      MeshAttachment {
        handle = ground_mesh_handle,
        material = brick_wall_mat_handle,
      },
    )
    world.translate(back_wall, y = size, z = -size)
    world.rotate(back_wall, math.PI * 0.5, linalg.VECTOR3F32_X_AXIS)
    world.scale(back_wall, size)
    // // Ceiling
    _, ceiling := world.spawn(
      &engine.world,
      MeshAttachment {
        handle = ground_mesh_handle,
        material = brick_wall_mat_handle,
      },
    )
    world.translate(ceiling, y = 2*size)
    world.rotate(ceiling, -math.PI, linalg.VECTOR3F32_X_AXIS)
    world.scale(ceiling, size)
  }
  if true {
    log.info("loading Hammer GLTF...")
    gltf_nodes := world.load_gltf(&engine.world, &engine.resource_manager, &engine.gpu_context, "assets/Mjolnir.glb") or_else {}
    log.infof("Loaded GLTF nodes: %v", gltf_nodes)
    for handle in gltf_nodes {
      hammer_handle = handle
      world.translate(&engine.world, handle, 3, 1, -2)
      world.scale(&engine.world, handle, 0.2)
    }
  }
  if true {
    log.info("loading Damaged Helmet GLTF...")
    gltf_nodes := world.load_gltf(&engine.world, &engine.resource_manager, &engine.gpu_context, "assets/DamagedHelmet.glb") or_else {}
    log.infof("Loaded GLTF nodes: %v", gltf_nodes)
    for handle in gltf_nodes {
      world.translate(&engine.world, handle, 0, 1, 3)
      world.scale(&engine.world, handle, 0.5)
    }
  }
  if true {
    log.info("loading Suzanne GLTF...")
    gltf_nodes := world.load_gltf(&engine.world, &engine.resource_manager, &engine.gpu_context, "assets/Suzanne.glb") or_else {}
    log.infof("Loaded GLTF nodes: %v", gltf_nodes)
    for handle in gltf_nodes {
      world.translate(&engine.world, handle, -3, 1, -2)
    }
  }
  if true {
    log.info("loading Warrior GLTF...")
    gltf_nodes := world.load_gltf(&engine.world, &engine.resource_manager, &engine.gpu_context, "assets/Warrior.glb") or_else {}
    log.infof("Loaded GLTF nodes: %v", gltf_nodes)
    for armature in gltf_nodes {
      armature_ptr := world.get_node(&engine.world, armature)
      if armature_ptr == nil do continue
      for i in 1 ..< len(armature_ptr.children) {
        world.play_animation(&engine.world, &engine.resource_manager, armature_ptr.children[i], "idle")
      }
      world.translate(armature_ptr, 0, 0, 1)
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
      light: ^Node
      should_make_spot_light := i % 2 != 0
      if ALL_SPOT_LIGHT {
        should_make_spot_light = true
      } else if ALL_POINT_LIGHT {
        should_make_spot_light = false
      }
      if should_make_spot_light {
        light_handles[i], light = world.spawn(&engine.world, nil, &engine.resource_manager)
        light.attachment = world.create_spot_light_attachment(
          light_handles[i],
          &engine.resource_manager,
          &engine.gpu_context,
          color,
          10,  // radius
          math.PI * 0.2,  // angle
        )
        world.rotate(light, math.PI * 0.2, linalg.VECTOR3F32_X_AXIS)
      } else {
        light_handles[i], light = world.spawn(&engine.world, nil, &engine.resource_manager)
        attachment := world.create_point_light_attachment(
          light_handles[i],
          &engine.resource_manager,
          &engine.gpu_context,
          color,
          10,  // radius
        )
        light.attachment = attachment
      }
      world.translate(light, 6, 2, -1)
      cube_node: ^Node
      light_cube_handles[i], cube_node = world.spawn_child(
        &engine.world,
        light_handles[i],
        MeshAttachment {
          handle = cube_mesh_handle,
          material = plain_material_handle,
          cast_shadow = false,
        },
      )
      world.scale(cube_node, 0.1)
    }
    // spawn(
    //   &engine.world,
    //   DirectionalLightAttachment {
    //     color = {0.3, 0.3, 0.3, 1.0},
    //     cast_shadow = true,
    //   },
    // )
  }
  when false {
    log.info("Setting up bloom...")
    // add_bloom(&engine.postprocess, 0.8, 0.5, 16.0)
    // Create a bright white ball to test bloom effect
    _, bright_ball_node := spawn(
    &engine.world,
    MeshAttachment {
      handle      = sphere_mesh_handle,
      material    = resources.create_material_handle(
        &engine.resource_manager,
        emissive_value = 30.0,
      ),
      cast_shadow = false, // Emissive objects don't need shadows
    },
    )
    world.translate(bright_ball_node, x = 1.0) // Position it above the ground
    world.scale(bright_ball_node, 0.2) // Make it a reasonable size
  }
  when true {
    log.info("Setting up particles...")
    black_circle_texture_handle := resources.create_texture_handle(
      &engine.gpu_context,
      &engine.resource_manager,
      "assets/black-circle.png",
    )
    goldstar_texture_handle := resources.create_texture_handle(
      &engine.gpu_context,
      &engine.resource_manager,
      "assets/gold-star.png",
    )
    goldstar_material_handle := resources.create_material_handle(
      &engine.resource_manager,
      {.ALBEDO_TEXTURE},
      type = .TRANSPARENT,
      albedo_handle = goldstar_texture_handle,
    )
    psys_handle1, _ := world.spawn_at(
      &engine.world,
      {-2.0, 1.9, 0.3},
    )
    emitter_handle1 := resources.create_emitter_handle(
      &engine.resource_manager,
      resources.Emitter {
        emission_rate = 7,
        particle_lifetime = 5.0,
        position_spread = 1.5,
        initial_velocity = {0, -0.1, 0, 0},
        velocity_spread = 0.1,
        color_start = {1, 1, 0, 1}, // Yellow particles
        color_end = {1, 0.5, 0, 0},
        size_start = 200.0,
        size_end = 100.0,
        weight = 0.1,
        weight_spread = 0.05,
        texture_handle = goldstar_texture_handle,
        enabled = true,
        bounding_box = Aabb{min = {-2, -2, -2}, max = {2, 2, 2}},
        is_dirty = true,
      },
    )
    world.spawn_child(
      &engine.world,
      psys_handle1,
      world.EmitterAttachment {emitter_handle1},
      &engine.resource_manager,
    )
    psys_handle2, _ := world.spawn_at(
      &engine.world,
      {2.0, 1.9, 0.3},
    )
    // Create an emitter for the second particle system
    emitter_handle2 := resources.create_emitter_handle(
      &engine.resource_manager,
      resources.Emitter {
        emission_rate = 7,
        particle_lifetime = 3.0,
        position_spread = 0.3,
        initial_velocity = {0, 0.2, 0, 0},
        velocity_spread = 0.15,
        color_start = {0, 0, 1, 1}, // Blue particles
        color_end = {0, 1, 1, 0},
        size_start = 350.0,
        size_end = 175.0,
        weight = 0.1,
        weight_spread = 0.3,
        texture_handle = black_circle_texture_handle,
        enabled = true,
        bounding_box = Aabb{min = {-1, -1, -1}, max = {1, 1, 1}},
        is_dirty = true,
      },
    )
    world.spawn_child(
      &engine.world,
      psys_handle2,
      world.EmitterAttachment {emitter_handle2},
      &engine.resource_manager,
    )
    // Create a force field that affects both particle systems
    forcefield_handle, _ = world.spawn_child(
      &engine.world,
      psys_handle1, // Attach to first particle system
      world.ForceFieldAttachment {
        tangent_strength = 2.0,
        strength = 20.0,
        area_of_effect = 5.0,
      },
    )
    world.translate(&engine.world, forcefield_handle, 5.0, 4.0, 0.0)
    _, forcefield_visual := world.spawn_child(
      &engine.world,
      forcefield_handle,
      MeshAttachment {
        handle = sphere_mesh_handle,
        material = goldstar_material_handle,
        cast_shadow = false,
      },
    )
    world.scale(forcefield_visual, 0.2)
  }
  post_process.add_fog(
    &engine.render.post_process,
    [3]f32{0.4, 0.0, 0.8},
    0.02,
    5.0,
    20.0,
  )
  // post_process.add_bloom(&engine.render.post_process)
  post_process.add_crosshatch(
    &engine.render.post_process,
    [2]f32{1280, 720},
  )
  // post_process.add_blur(&engine.render.post_process, 18.0)
  // post_process.add_tonemap(&engine.render.post_process, 1.5, 1.3)
  // post_process.add_dof(&engine.render.post_process)
  // post_process.add_grayscale(&engine.render.post_process, 0.9)
  // post_process.add_outline(&engine.render.post_process, 2.0, [3]f32{1.0, 0.0, 0.0})
  // Initialize camera controllers
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
    // Create portal render target via global pool
    portal_render_target: ^resources.RenderTarget
    portal_render_target_handle, portal_render_target = resources.alloc(
      &engine.resource_manager.render_targets,
    )
    resources.render_target_init(
      portal_render_target,
      &engine.gpu_context,
      &engine.resource_manager,
      512, // Portal texture resolution
      512,
      vk.Format.R8G8B8A8_UNORM,
      vk.Format.D32_SFLOAT,
    )
    log.infof(
      "Portal render target created: handle=%v, extent=%v",
      portal_render_target_handle,
      portal_render_target.extent,
    )
    // Configure the portal camera to look down from above at a steep angle
    portal_camera, portal_camera_found := resources.get_camera(
      &engine.resource_manager,
      portal_render_target.camera,
    )
    if !portal_camera_found {
      log.error("Failed to fetch portal camera")
    } else {
      camera_look_at(portal_camera, {5, 15, 7}, {0, 0, 0}, {0, 1, 0})
    }
    portal_material_handle = resources.create_material_handle(
      &engine.resource_manager,
      {.ALBEDO_TEXTURE},
    )
    log.infof(
      "Portal material created with handle: %v",
      portal_material_handle,
    )
    // Create portal quad mesh and spawn it
    _, portal_node := world.spawn(
      &engine.world,
      MeshAttachment {
        handle = resources.create_mesh_handle(
          &engine.gpu_context,
          &engine.resource_manager,
          make_quad(),
        ),
        material = portal_material_handle,
        cast_shadow = false,
      },
    )
    // Position the portal vertically
    world.translate(portal_node, 0, 3, -5)
    world.rotate(portal_node, math.PI * 0.5, linalg.VECTOR3F32_X_AXIS)
    world.scale(portal_node, 2.0)
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
    if i == 0 do continue // manual control light #0
    offset := f32(i) / f32(LIGHT_COUNT) * math.PI * 2.0
    t := time_since_start(engine) + offset
    // log.infof("getting light %d %v", i, handle)
    rx := math.sin(t)
    ry := (math.sin(t) + 1.0) * 0.5 * 1.5 + 1.0
    rz := math.cos(t)
    v := linalg.normalize([3]f32{rx, ry, rz})
    radius: f32 = 6
    v = v * radius + linalg.VECTOR3F32_Y_AXIS * -1.0
    world.translate(&engine.world, handle, v.x, v.y, v.z)
    world.rotate(
      &engine.world,
      light_cube_handles[i],
      math.PI * time_since_start(engine) * 0.5,
    )
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

custom_render :: proc(
  engine: ^mjolnir.Engine,
  command_buffer: vk.CommandBuffer,
) {
  using mjolnir, geometry
  portal_rt: ^resources.RenderTarget
  ok: bool
  portal_rt, ok = resources.get_render_target(
    &engine.resource_manager,
    portal_render_target_handle,
  )
  if !ok do return
  portal_camera: ^Camera
  // Animate portal camera - orbit around the scene center
  portal_camera, ok = resources.get_camera(&engine.resource_manager, portal_rt.camera)
  if !ok do return
  t := time_since_start(engine) * 0.3 // Slow orbit speed
  radius: f32 = 12.0
  height: f32 = 8.0
  // Calculate circular orbit position
  camera_x := math.cos(t) * radius
  camera_z := math.sin(t) * radius
  camera_pos := [3]f32{camera_x, height, camera_z}
  target := [3]f32{0, 0, 0} // Always look at scene center
  // Update camera position and orientation
  camera_look_at(portal_camera, camera_pos, target, {0, 1, 0})
  // Update portal camera uniform
  resources.render_target_upload_camera_data(&engine.resource_manager, portal_rt)
  camera_data := resources.get_camera_data(
    &engine.resource_manager,
    portal_rt.camera.index,
  )
  vis_result := world.query_visibility(
    &engine.world,
    &engine.gpu_context,
    command_buffer,
    engine.frame_index,
    world.DrawCommandRequest {
      camera_handle  = {index = portal_rt.camera.index},
      include_flags = {.VISIBLE},
      exclude_flags = {.MATERIAL_TRANSPARENT, .MATERIAL_WIREFRAME},
      category      = .CUSTOM0,
    },
  )
  portal_draw_buffer := vis_result.draw_buffer
  portal_draw_count := vis_result.max_draws
  // Render G-buffer pass with self-managed depth
  geometry_pass.begin_pass(
    portal_rt,
    command_buffer,
    &engine.resource_manager,
    engine.frame_index,
    self_manage_depth = true,
  )
  geometry_pass.render(
    &engine.render.geometry,
    portal_rt,
    command_buffer,
    &engine.resource_manager,
    engine.frame_index,
    portal_draw_buffer,
    portal_draw_count,
    vis_result.command_stride,
  )
  geometry_pass.end_pass(
    portal_rt,
    command_buffer,
    &engine.resource_manager,
    engine.frame_index,
  )
  // Update portal material to use the rendered texture (from current frame)
  portal_mat: ^resources.Material
  portal_mat, ok = resources.get_material(
    &engine.resource_manager,
    portal_material_handle,
  )
  if !ok do return
  portal_mat.albedo = resources.get_albedo_texture(portal_rt, engine.frame_index)
  sync_result := resources.sync_material_gpu_data(
    &engine.resource_manager,
    portal_material_handle,
  )
  if sync_result != vk.Result.SUCCESS {
    log.error("Failed to sync portal material GPU data", sync_result)
  }
}

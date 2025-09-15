package main

import "core:fmt"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:os"
import "mjolnir"
import "mjolnir/geometry"
import "mjolnir/gpu"
import "mjolnir/resource"
import "vendor:glfw"
import mu "vendor:microui"
import vk "vendor:vulkan"

LIGHT_COUNT :: 5
ALL_SPOT_LIGHT :: false
ALL_POINT_LIGHT :: false
light_handles: [LIGHT_COUNT]mjolnir.Handle
light_cube_handles: [LIGHT_COUNT]mjolnir.Handle
ground_mat_handle: mjolnir.Handle
hammer_handle: mjolnir.Handle
engine: mjolnir.Engine
forcefield_handle: mjolnir.Handle
forcefield_node: ^mjolnir.Node

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
      navmesh_visual_main()
      return
    }
  }
  engine.setup_proc = setup
  engine.update_proc = update
  engine.render2d_proc = render_2d
  engine.key_press_proc = on_key_pressed
  engine.custom_render_proc = custom_render
  mjolnir.run(&engine, 1280, 720, "Mjolnir Odin")
}

setup :: proc(engine: ^mjolnir.Engine) {
  using mjolnir, geometry
  log.info("Setup function called!")
  goldstar_texture_handle, _, _ := create_texture(
    &engine.gpu_context,
    &engine.warehouse,
    "assets/gold-star.png",
  )
  plain_material_handle := create_material_handle(&engine.warehouse)
  wireframe_material_handle := create_material_handle(
    &engine.warehouse,
    type = .WIREFRAME,
  )
  goldstar_material_handle := create_material_handle(
    &engine.warehouse,
    {.ALBEDO_TEXTURE},
    type = .TRANSPARENT,
    albedo_handle = goldstar_texture_handle,
  )
  cube_geom := make_cube()
  cube_mesh_handle := create_mesh_handle(
    &engine.gpu_context,
    &engine.warehouse,
    cube_geom,
  )
  sphere_mesh_handle := create_mesh_handle(
    &engine.gpu_context,
    &engine.warehouse,
    make_sphere(),
  )
  // Create ground plane
  ground_mat_handle = create_material_handle(
    &engine.warehouse,
    {.ALBEDO_TEXTURE},
    albedo_handle = create_texture_handle(
      &engine.gpu_context,
      &engine.warehouse,
      "assets/t_brick_floor_002_diffuse_1k.jpg",
    ),
  )
  ground_mesh_handle := create_mesh_handle(
    &engine.gpu_context,
    &engine.warehouse,
    make_quad(),
  )
  cone_mesh_handle := create_mesh_handle(
    &engine.gpu_context,
    &engine.warehouse,
    make_cone(),
  )
  if true {
    log.info("spawning cubes in a grid")
    space: f32 = 2.1
    size: f32 = 0.3
    nx, ny, nz := 30, 2, 30

    for x in 1 ..< nx {
      for y in 1 ..< ny {
        for z in 1 ..< nz {
          // Calculate world position
          world_x := (f32(x) - f32(nx) * 0.5) * space
          world_y := (f32(y) - f32(ny) * 0.5) * space + 0.5
          world_z := (f32(z) - f32(nz) * 0.5) * space
          mat_handle := create_material_handle(
            &engine.warehouse,
            metallic_value = f32(x - 1) / f32(nx - 1),
            roughness_value = f32(z - 1) / f32(nz - 1),
          )
          node: ^Node
          if x % 3 == 0 {
            _, node = spawn(
              &engine.scene,
              MeshAttachment {
                handle = cube_mesh_handle,
                material = mat_handle,
                cast_shadow = true,
              },
            )
          } else if x % 3 == 1 {
            _, node = spawn(
              &engine.scene,
              MeshAttachment {
                handle = cone_mesh_handle,
                material = mat_handle,
                cast_shadow = true,
              },
            )
          } else {
            _, node = spawn(
              &engine.scene,
              MeshAttachment {
                handle = sphere_mesh_handle,
                material = mat_handle,
                cast_shadow = true,
              },
            )
          }
          translate(&node.transform, world_x, world_y, world_z)
          scale(&node.transform, size)
        }
      }
    }
  }
  if true {
    log.info("spawning ground and walls")
    // Ground node
    size: f32 = 15.0
    _, ground_node := spawn(
      &engine.scene,
      MeshAttachment {
        handle = ground_mesh_handle,
        material = ground_mat_handle,
        cast_shadow = true,
      },
    )
    scale(&ground_node.transform, size)
    // Left wall
    _, left_wall := spawn(
      &engine.scene,
      MeshAttachment {
        handle = ground_mesh_handle,
        material = ground_mat_handle,
        cast_shadow = true,
      },
    )
    translate(&left_wall.transform, x = size)
    rotate(&left_wall.transform, math.PI * 0.5, linalg.VECTOR3F32_Z_AXIS)
    scale(&left_wall.transform, size)
    // Right wall
    _, right_wall := spawn(
      &engine.scene,
      MeshAttachment {
        handle = ground_mesh_handle,
        material = ground_mat_handle,
        cast_shadow = true,
      },
    )
    translate(&right_wall.transform, x = -size)
    rotate(&right_wall.transform, -math.PI * 0.5, linalg.VECTOR3F32_Z_AXIS)
    scale(&right_wall.transform, size)
    // Back wall
    _, back_wall := spawn(
      &engine.scene,
      MeshAttachment {
        handle = ground_mesh_handle,
        material = ground_mat_handle,
        cast_shadow = false,
      },
    )
    translate(&back_wall.transform, y = size, z = -size)
    rotate(&back_wall.transform, math.PI * 0.5, linalg.VECTOR3F32_X_AXIS)
    scale(&back_wall.transform, size)
    // // Ceiling
    // _, ceiling := spawn(
    //   &engine.scene,
    //   MeshAttachment {
    //     handle = ground_mesh_handle,
    //     material = ground_mat_handle,
    //     cast_shadow = true,
    //   },
    // )
    // translate(&ceiling.transform, y = size)
    // rotate(&ceiling.transform, -math.PI, linalg.VECTOR3F32_X_AXIS)
    // scale(&ceiling.transform, size)
  }
  if true {
    log.info("loading GLTF...")
    gltf_nodes := load_gltf(engine, "assets/Mjolnir.glb") or_else {}
    log.infof("Loaded GLTF nodes: %v", gltf_nodes)
    for handle in gltf_nodes {
      hammer_handle = handle
      node := resource.get(engine.scene.nodes, handle) or_continue
      translate(&node.transform, 3, 1, -2)
      scale(&node.transform, 0.2)
    }
  }
  if true {
    log.info("loading GLTF...")
    gltf_nodes := load_gltf(engine, "assets/DamagedHelmet.glb") or_else {}
    log.infof("Loaded GLTF nodes: %v", gltf_nodes)
    for handle in gltf_nodes {
      helm := resource.get(engine.scene.nodes, handle) or_continue
      translate(&helm.transform, 0, 1, 3)
      scale(&helm.transform, 0.5)
    }
  }
  if true {
    log.info("loading GLTF...")
    gltf_nodes := load_gltf(engine, "assets/Suzanne.glb") or_else {}
    log.infof("Loaded GLTF nodes: %v", gltf_nodes)
    for handle in gltf_nodes {
      monkey := resource.get(engine.scene.nodes, handle) or_continue
      translate(&monkey.transform, -3, 1, -2)
    }
  }
  if true {
    log.info("loading GLTF...")
    gltf_nodes := load_gltf(engine, "assets/Warrior.glb") or_else {}
    log.infof("Loaded GLTF nodes: %v", gltf_nodes)
    for armature in gltf_nodes {
      armature_ptr := resource.get(engine.scene.nodes, armature) or_continue
      for i in 1 ..< len(armature_ptr.children) {
        play_animation(engine, armature_ptr.children[i], "idle")
      }
      translate(&armature_ptr.transform, 0, 0, 1)
    }
  }
  if true {
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
        light_handles[i], light = spawn(
          &engine.scene,
          SpotLightAttachment {
            color = color,
            angle = math.PI * 0.4,
            radius = 10,
            cast_shadow = true,
          },
        )
        rotate(&light.transform, math.PI * 0.2, linalg.VECTOR3F32_X_AXIS)
      } else {
        light_handles[i], light = spawn(
          &engine.scene,
          PointLightAttachment{color = color, radius = 10, cast_shadow = true},
        )
      }
      translate(&light.transform, 6, 2, -1)
      cube_node: ^Node
      light_cube_handles[i], cube_node = spawn_child(
        &engine.scene,
        light_handles[i],
        MeshAttachment {
          handle = cube_mesh_handle,
          material = plain_material_handle,
          cast_shadow = false,
        },
      )
      scale(&cube_node.transform, 0.1)
    }
    // spawn(
    //   &engine.scene,
    //   DirectionalLightAttachment {
    //     color = {0.3, 0.3, 0.3, 1.0},
    //     cast_shadow = true,
    //   },
    // )
  }

  if false {
    // effect_add_bloom(&engine.postprocess, 0.8, 0.5, 16.0)
    // Create a bright white ball to test bloom effect
    _, bright_ball_node := spawn(
    &engine.scene,
    MeshAttachment {
      handle      = sphere_mesh_handle,
      material    = create_material_handle(
        &engine.warehouse,
        emissive_value = 30.0,
      ),
      cast_shadow = false, // Emissive objects don't need shadows
    },
    )
    translate(&bright_ball_node.transform, x = 1.0) // Position it above the ground
    scale(&bright_ball_node.transform, 0.2) // Make it a reasonable size
  }

  if true {
    black_circle_texture_handle := create_texture_handle(
      &engine.gpu_context,
      &engine.warehouse,
      "assets/black-circle.png",
    )
    psys_handle1, _ := spawn_at(
      &engine.scene,
      {-2.0, 1.9, 0.3},
      ParticleSystemAttachment {
        bounding_box = Aabb{min = {-1, -1, -1}, max = {1, 1, 1}},
        texture_handle = goldstar_texture_handle,
      },
    )
    spawn_child(
      &engine.scene,
      psys_handle1,
      EmitterAttachment {
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
      },
    )
    psys_handle2, _ := spawn_at(
      &engine.scene,
      {2.0, 1.9, 0.3},
      ParticleSystemAttachment {
        bounding_box = Aabb{min = {-1, -1, -1}, max = {1, 1, 1}},
        texture_handle = black_circle_texture_handle,
      },
    )
    // Create an emitter for the second particle system
    spawn_child(
      &engine.scene,
      psys_handle2,
      EmitterAttachment {
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
      },
    )
    // Create a force field that affects both particle systems
    forcefield_handle, forcefield_node = spawn_child(
      &engine.scene,
      psys_handle1, // Attach to first particle system
      ForceFieldAttachment {
        tangent_strength = 2.0,
        strength = 20.0,
        area_of_effect = 5.0,
      },
    )
    translate(&forcefield_node.transform, x = 5.0, y = 4.0, z = 0.0)
    _, forcefield_visual := spawn_child(
      &engine.scene,
      forcefield_handle,
      MeshAttachment {
        handle = sphere_mesh_handle,
        material = goldstar_material_handle,
        cast_shadow = false,
      },
    )
    scale(&forcefield_visual.transform, 0.2)
  }
  effect_add_fog(&engine.postprocess, {0.4, 0.0, 0.8}, 0.02, 5.0, 20.0)
  // effect_add_bloom(&engine.postprocess)
  effect_add_crosshatch(&engine.postprocess, {1280, 720})
  // effect_add_blur(&engine.postprocess, 18.0)
  // effect_add_tonemap(&engine.postprocess, 1.5, 1.3)
  // effect_add_dof(&engine.postprocess)
  // effect_add_grayscale(&engine.postprocess, 0.9)
  // effect_add_outline(&engine.postprocess, 2.0, {1.0, 0.0, 0.0})
  // Initialize camera controllers
  setup_camera_controller_callbacks(engine.window)
  main_camera := get_main_camera(engine)
  orbit_controller = camera_controller_orbit_init(
    engine.window,
    {0, 0, 0}, // dummy target
    1.0, // dummy distance
    0, // dummy yaw
    0, // dummy pitch
  )
  // Initialize free controller
  free_controller = camera_controller_free_init(engine.window, 5.0, 2.0)
  if main_camera != nil {
    camera_controller_sync(&orbit_controller, main_camera)
    camera_controller_sync(&free_controller, main_camera)
  }
  current_controller = &orbit_controller
  // Portal setup
  if true {
    log.info("Setting up portal...")

    // Create portal render target via global pool
    portal_render_target: ^RenderTarget
    portal_render_target_handle, portal_render_target = resource.alloc(
      &engine.warehouse.render_targets,
    )
    render_target_init(
      portal_render_target,
      &engine.gpu_context,
      &engine.warehouse,
      512, // Portal texture resolution
      512,
      .R8G8B8A8_UNORM, // Color format
      .D32_SFLOAT, // Depth format
    )
    log.infof(
      "Portal render target created: handle=%v, extent=%v",
      portal_render_target_handle,
      portal_render_target.extent,
    )
    // Configure the portal camera to look down from above at a steep angle
    portal_camera := get_camera(
      &engine.warehouse,
      portal_render_target,
    )
    camera_look_at(portal_camera, {5, 15, 7}, {0, 0, 0}, {0, 1, 0})
    portal_material_handle = create_material_handle(
      &engine.warehouse,
      {.ALBEDO_TEXTURE},
    )
    log.infof(
      "Portal material created with handle: %v",
      portal_material_handle,
    )
    // Create portal quad mesh and spawn it
    _, portal_node := spawn(
      &engine.scene,
      MeshAttachment {
        handle = create_mesh_handle(
          &engine.gpu_context,
          &engine.warehouse,
          make_quad(),
        ),
        material = portal_material_handle,
        cast_shadow = false,
      },
    )
    // Position the portal vertically
    translate(&portal_node.transform, 0, 3, -5)
    rotate(&portal_node.transform, math.PI * 0.5, linalg.VECTOR3F32_X_AXIS)
    scale(&portal_node.transform, 2.0)
  }

  log.info("setup complete")
}

render_2d :: proc(engine: ^mjolnir.Engine, ctx: ^mu.Context) {
  using mjolnir
  if mu.window(ctx, "Particle System", {40, 360, 300, 200}, {.NO_CLOSE}) {
    rendered, max_particles := get_particle_render_stats(&engine.particle)
    mu.label(ctx, fmt.tprintf("Rendered %d", rendered))
    mu.label(ctx, fmt.tprintf("Max Particles %d", max_particles))
    efficiency := f32(rendered) / f32(max_particles) * 100.0
    mu.label(ctx, fmt.tprintf("Efficiency %.1f%%", efficiency))
  }
  if mu.window(ctx, "Shadow Debug", {990, 40, 280, 150}, {.NO_CLOSE}) {
    mu.label(ctx, "Shadow Map Information:")
    mu.label(
      ctx,
      fmt.tprintf("Shadow Map Size: %dx%d", SHADOW_MAP_SIZE, SHADOW_MAP_SIZE),
    )
    mu.label(ctx, fmt.tprintf("Max Shadow Maps: %d", MAX_SHADOW_MAPS))
    mu.text(ctx, "Check console for detailed")
    mu.text(ctx, "shadow rendering debug info")
  }
  when mjolnir.USE_GPU_CULLING {
    if mu.window(ctx, "GPU Culling", {990, 200, 280, 240}, {.NO_CLOSE}) {
      mu.label(ctx, fmt.tprintf("Max Nodes: %d", mjolnir.MAX_NODES_IN_SCENE))
      mu.label(ctx, fmt.tprintf("Max Cameras: %d", mjolnir.MAX_ACTIVE_CAMERAS))
      total_nodes :=
        len(engine.scene.nodes.entries) - len(engine.scene.nodes.free_indices)
      mu.label(ctx, fmt.tprintf("Active Nodes: %d", total_nodes))
    }
  }
}

update :: proc(engine: ^mjolnir.Engine, delta_time: f32) {
  using mjolnir, geometry
  // Handle camera controller switching with Tab key
  tab_pressed := glfw.GetKey(engine.window, glfw.KEY_TAB) == glfw.PRESS
  if tab_pressed && !tab_was_pressed {
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
  tab_was_pressed = tab_pressed

  main_camera := get_main_camera(engine)
  if main_camera != nil {
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

  t := time_since_app_start(engine) * 0.5
  if forcefield_node != nil {
    translate(
      &forcefield_node.transform,
      math.cos(t) * 2.0,
      2.0,
      math.sin(t) * 2.0,
    )
  }
  // Animate lights
  for handle, i in light_handles {
    if i == 0 do continue // manual control light #0
    offset := f32(i) / f32(LIGHT_COUNT) * math.PI * 2.0
    t := time_since_app_start(engine) + offset
    // log.infof("getting light %d %v", i, light_handles[i])
    light_ptr := resource.get(engine.scene.nodes, handle)
    rx := math.sin(t)
    ry := (math.sin(t) + 1.0) * 0.5 * 1.5 + 1.0
    rz := math.cos(t)
    v := linalg.normalize([3]f32{rx, ry, rz})
    radius: f32 = 6
    v = v * radius + linalg.VECTOR3F32_Y_AXIS * -1.0
    translate(&light_ptr.transform, v.x, v.y, v.z)
    // log.infof("Light %d position: %v", i, light_ptr.transform.position)
    cube_ptr := resource.get(engine.scene.nodes, light_cube_handles[i])
    rotate(
      &cube_ptr.transform,
      math.PI * time_since_app_start(engine) * 0.5,
    )
    // log.infof( "Light cube %d rotation: %v", i, light_cube_ptr.transform.rotation,)
  }
}

on_key_pressed :: proc(engine: ^mjolnir.Engine, key, action, mods: int) {
  using mjolnir, geometry
  log.infof("key pressed key %d action %d mods %x", key, action, mods)
  if key == glfw.KEY_LEFT && action == glfw.PRESS {
    light := resource.get(engine.scene.nodes, light_handles[0])
    translate_by(&light.transform, x = 0.1)
  } else if key == glfw.KEY_RIGHT && action == glfw.PRESS {
    light := resource.get(engine.scene.nodes, light_handles[0])
    translate_by(&light.transform, x = -0.1)
  } else if key == glfw.KEY_UP && action == glfw.PRESS {
    light := resource.get(engine.scene.nodes, light_handles[0])
    translate_by(&light.transform, z = 0.1)
  } else if key == glfw.KEY_DOWN && action == glfw.PRESS {
    light := resource.get(engine.scene.nodes, light_handles[0])
    translate_by(&light.transform, z = -0.1)
  } else if key == glfw.KEY_Z && action == glfw.PRESS {
    light := resource.get(engine.scene.nodes, light_handles[0])
    translate_by(&light.transform, y = 0.1)
  } else if key == glfw.KEY_X && action == glfw.PRESS {
    light := resource.get(engine.scene.nodes, light_handles[0])
    translate_by(&light.transform, y = -0.1)
  }
}

custom_render :: proc(
  engine: ^mjolnir.Engine,
  command_buffer: vk.CommandBuffer,
) {
  using mjolnir, geometry
  portal_rt : ^RenderTarget
  ok: bool
  portal_rt, ok = resource.get(
    engine.warehouse.render_targets,
    portal_render_target_handle,
  )
  if !ok do return
  portal_camera : ^Camera
  // Animate portal camera - orbit around the scene center
  portal_camera, ok = resource.get(
    engine.warehouse.cameras,
    portal_rt.camera,
  )
  if !ok do return
  t := time_since_app_start(engine) * 0.3 // Slow orbit speed
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
  render_target_update_camera_uniform(&engine.warehouse, portal_rt)
  camera_uniform := get_camera_uniform(
    &engine.warehouse,
    portal_rt.camera.index,
  )
  portal_render_input := generate_render_input(
    engine,
    make_frustum(camera_uniform.projection * camera_uniform.view),
    portal_rt.camera,
  )
  // Render G-buffer pass with self-managed depth
  gbuffer_begin(
    portal_rt,
    command_buffer,
    &engine.warehouse,
    engine.frame_index,
    self_manage_depth = true,
  )
  gbuffer_render(
    &engine.gbuffer,
    &portal_render_input,
    portal_rt,
    command_buffer,
    &engine.warehouse,
    engine.frame_index,
  )
  gbuffer_end(
    portal_rt,
    command_buffer,
    &engine.warehouse,
    engine.frame_index,
  )
  // Update portal material to use the rendered texture (from current frame)
  portal_mat : ^Material
  portal_mat, ok = resource.get(
    engine.warehouse.materials,
    portal_material_handle,
  )
  if !ok do return
  portal_mat.albedo = get_albedo_texture(
    portal_rt,
    engine.frame_index,
  )
}

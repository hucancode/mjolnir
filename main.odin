package main

import "core:log"
import "core:math"
import "core:math/linalg"
import "mjolnir"
import "mjolnir/geometry"
import "mjolnir/resources"
import "mjolnir/world"
import "vendor:glfw"

LIGHT_COUNT :: 10
ALL_SPOT_LIGHT :: false
ALL_POINT_LIGHT :: false
light_handles: [LIGHT_COUNT]resources.Handle
light_cube_handles: [LIGHT_COUNT]resources.Handle
forcefield_handle: resources.Handle
portal_camera_handle: resources.Handle
portal_material_handle: resources.Handle

main :: proc() {
  context.logger = log.create_console_logger()
  engine := new(mjolnir.Engine)
  engine.setup_proc = setup
  engine.update_proc = update
  engine.key_press_proc = on_key_pressed
  engine.post_render_proc = on_post_render
  mjolnir.run(engine, 1280, 720, "Mjolnir")
}

setup :: proc(engine: ^mjolnir.Engine) {
  using mjolnir, geometry
  log.info("Setup function called!")
  set_visibility_stats(engine, false)
  // engine.debug_ui_enabled = true
  plain_material_handle, plain_material_ok := create_material(engine)
  cube_geom := make_cube()
  cube_mesh_handle, cube_mesh_ok := create_mesh(engine, cube_geom)
  sphere_mesh_handle, sphere_mesh_ok := create_mesh(engine, make_sphere())
  cone_mesh_handle, cone_mesh_ok := create_mesh(engine, make_cone())
  if true {
    log.info("spawning cubes in a grid")
    space: f32 = 4.1
    size: f32 = 0.3
    nx, ny, nz := 240, 1, 240
    mat_handle, mat_ok := create_material(
      engine,
      metallic_value = 0.5,
      roughness_value = 0.8,
    )
    if cube_mesh_ok && sphere_mesh_ok && cone_mesh_ok && mat_ok {
      spawn_loop: for x in 0 ..< nx {
        for y in 0 ..< ny {
          for z in 0 ..< nz {
            world_x := (f32(x) - f32(nx) * 0.5) * space
            world_y := (f32(y) - f32(ny) * 0.5) * space + 2.25
            world_z := (f32(z) - f32(nz) * 0.5) * space
            node_handle: resources.Handle
            node_ok := false
            if x % 3 == 0 {
              node_handle, _, node_ok = spawn(
                engine,
                world.MeshAttachment {
                  handle = cube_mesh_handle,
                  material = mat_handle,
                  cast_shadow = true,
                },
              )
            } else if x % 3 == 1 {
              node_handle, _, node_ok = spawn(
                engine,
                world.MeshAttachment {
                  handle = cone_mesh_handle,
                  material = mat_handle,
                  cast_shadow = true,
                },
              )
            } else {
              node_handle, _, node_ok = spawn(
                engine,
                world.MeshAttachment {
                  handle = sphere_mesh_handle,
                  material = mat_handle,
                  cast_shadow = true,
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
    brick_wall_mat_handle: resources.Handle
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
      make_quad(),
    )
    log.info("spawning ground and walls")
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
    gltf_nodes, gltf_ok := load_gltf(engine, "assets/Mjolnir.glb")
    if gltf_ok {
      log.infof("Loaded GLTF nodes: %v", gltf_nodes)
      for handle in gltf_nodes {
        translate(engine, handle, 3, 1, -2)
        scale(engine, handle, 0.2)
      }
    }
  }
  if true {
    log.info("loading Warrior GLTF...")
    gltf_nodes, gltf_ok := load_gltf(engine, "assets/Warrior.glb")
    if !gltf_ok do gltf_nodes = {}
    log.infof("Loaded GLTF nodes: %v", gltf_nodes)
    for armature in gltf_nodes {
      armature_ptr := get_node(engine, armature)
      if armature_ptr == nil do continue
      for i in 1 ..< len(armature_ptr.children) {
        play_animation(engine, armature_ptr.children[i], "idle")
      }
      translate_node(armature_ptr, 0, 0, 1)
      for child_handle in armature_ptr.children {
        child_node := get_node(engine, child_handle) or_continue
        mesh_attachment, has_mesh := child_node.attachment.(world.MeshAttachment)
        if !has_mesh do continue
        _, has_skin := mesh_attachment.skinning.?
        if !has_skin do continue
        if plain_material_ok && cube_mesh_ok {
          _, hand_cube_node := spawn_child(
            engine,
            child_handle,
            world.MeshAttachment {
              handle = cube_mesh_handle,
              material = plain_material_handle,
              cast_shadow = true,
            },
          ) or_continue
          // Attach a cube to the hand.L bone
          hand_cube_node.bone_socket = "hand.L"
          scale(hand_cube_node, 0.1)
        }
        break
      }
    }
  }
  if true {
    log.info("loading Damaged Helmet GLTF...")
    gltf_nodes, gltf_ok := load_gltf(engine, "assets/DamagedHelmet.glb")
    if !gltf_ok do gltf_nodes = {}
    log.infof("Loaded GLTF nodes: %v", gltf_nodes)
    for handle in gltf_nodes {
      translate(engine, handle, 0, 1, 3)
      scale(engine, handle, 0.5)
    }
  }
  if true {
    log.info("loading Suzanne GLTF...")
    gltf_nodes, gltf_ok := load_gltf(engine, "assets/Suzanne.glb")
    if !gltf_ok do gltf_nodes = {}
    log.infof("Loaded GLTF nodes: %v", gltf_nodes)
    for handle in gltf_nodes {
      translate(engine, handle, -3, 1, 0)
    }
  }
  when true {
    log.infof("creating %d lights", LIGHT_COUNT)
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
          14,
          math.PI * 0.15,
          true,
          {0, 6, -1},
        )
        if !light_spawn_ok do continue
        rotate(light, math.PI * 0.5, linalg.VECTOR3F32_X_AXIS)
      } else {
        light_handles[i], light, light_spawn_ok = spawn_point_light(
          engine,
          color,
          14,
          true,
          {0, 2, -1},
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
          scale(cube_node, 0.05)
          translate(cube_node, y=0.5)
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
          cast_shadow = false,
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
  when true {
    // create portal camera with its own render target
    portal_camera_ok: bool
    portal_camera_handle, portal_camera_ok = create_camera(
      engine,
      512,  // width
      512,  // height
      {.GEOMETRY, .LIGHTING, .TRANSPARENCY, .PARTICLES},  // enabled passes (no post-process for performance)
      {5, 15, 7},  // camera position
      {0, 0, 0},   // looking at origin
      math.PI * 0.5,  // FOV
      0.1,  // near plane
      100.0,  // far plane
    )
    if !portal_camera_ok {
      log.error("Failed to create portal camera")
    }
    portal_material_ok: bool
    portal_material_handle, portal_material_ok = create_material(
      engine,
      {.ALBEDO_TEXTURE},
    )
    portal_quad_handle, portal_mesh_ok := create_mesh(
      engine,
      make_quad(),
    )
    if portal_material_ok && portal_mesh_ok {
      _, portal_node, portal_spawn_ok := spawn(
        engine,
        world.MeshAttachment {
          handle = portal_quad_handle,
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
  when true {
    log.info("spawning Warrior effect sprite with animation (99 frames @ 24fps)...")
    warrior_sprite_texture, warrior_sprite_ok := create_texture(
      engine,
      "assets/Warrior_Sheet-Effect.png",
    )
    if warrior_sprite_ok {
      sprite_quad := engine.render.transparency.sprite_quad_mesh
      // 6x17 sprite sheet: 6 columns, 17 rows, using frames 0-98 (99 total)
      // Create animation: 99 frames at 24fps, looping
      warrior_animation := resources.sprite_animation_init(
        frame_count = 99,
        fps = 24.0,
        mode = .LOOP,
      )
      sprite_handle, sprite_ok := resources.create_sprite(
        &engine.rm,
        warrior_sprite_texture,
        frame_columns = 6,   // 6 columns in sprite sheet
        frame_rows = 17,     // 17 rows in sprite sheet
        frame_index = 0,     // Starting frame (animation will override this)
        color = {1.0, 1.0, 1.0, 1.0},
        animation = warrior_animation,
      )
      if sprite_ok {
        sprite_material, mat_ok := create_material(
          engine,
          {.ALBEDO_TEXTURE},
          type = .TRANSPARENT,
          albedo_handle = warrior_sprite_texture,
        )
        if mat_ok {
          sprite_attachment := world.SpriteAttachment {
            sprite_handle = sprite_handle,
            mesh_handle   = sprite_quad,
            material      = sprite_material,
          }
          _, sprite_node, spawn_ok := world.spawn_at(
            &engine.world,
            {4, 1.5, 0},
            sprite_attachment,
            &engine.rm,
          )
          if spawn_ok {
            world.scale(sprite_node, 3.0)
            // sprite_node.culling_enabled = false
          }
        }
      }
    }
  }
  log.info("setup complete")
}

update :: proc(engine: ^mjolnir.Engine, delta_time: f32) {
  using mjolnir, geometry
  // Camera controller is automatically updated by engine
  t := time_since_start(engine) * 0.5
  translate(
    engine,
    forcefield_handle,
    math.cos(t) * 2.0,
    2.0,
    math.sin(t) * 2.0,
  )
  for handle, i in light_handles {
    if i == 0 {
      // rotate light 0 around Y axis
      t := time_since_start(engine)
      rotate(engine, handle, t, linalg.VECTOR3F32_Y_AXIS)
      spread := (math.sin(t*0.2) + 1.0)
      rotate_by(engine, handle, math.PI * 0.4 * spread, linalg.VECTOR3F32_X_AXIS)
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
    v = v * radius - linalg.VECTOR3F32_Y_AXIS * 4.0
    translate(engine, handle, v.x, v.y, v.z)
    rotate_by(
      engine,
      light_cube_handles[i],
      math.PI * time_since_start(engine) * 0.5,
      linalg.VECTOR3F32_Y_AXIS,
    )
  }
}

on_key_pressed :: proc(engine: ^mjolnir.Engine, key, action, mods: int) {
  using mjolnir, geometry
  log.infof("key pressed key %d action %d mods %x", key, action, mods)
  if action == glfw.RELEASE do return
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
    current_type := get_active_camera_controller_type(engine)
    if current_type == .ORBIT {
      switch_camera_controller(engine, .FREE)
    } else {
      switch_camera_controller(engine, .ORBIT)
    }
  }
}

on_post_render :: proc(engine: ^mjolnir.Engine) {
  using mjolnir
  portal_texture_handle := get_camera_attachment(
    engine,
    portal_camera_handle,
    resources.AttachmentType.FINAL_IMAGE,
    engine.frame_index,
  )
  update_material_texture(engine, portal_material_handle, .ALBEDO_TEXTURE, portal_texture_handle)
}

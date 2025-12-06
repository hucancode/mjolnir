package main

import "core:log"
import "core:math"
import "core:math/linalg"
import "mjolnir"
import "mjolnir/animation"
import "mjolnir/geometry"
import "mjolnir/resources"
import "mjolnir/world"
import "vendor:glfw"

LIGHT_COUNT :: 10
ALL_SPOT_LIGHT :: false
ALL_POINT_LIGHT :: false
portal_camera_handle: mjolnir.CameraHandle
portal_material_handle: mjolnir.MaterialHandle

main :: proc() {
  context.logger = log.create_console_logger()
  engine := new(mjolnir.Engine)
  engine.setup_proc = setup
  engine.key_press_proc = on_key_pressed
  engine.post_render_proc = on_post_render
  mjolnir.run(engine, 1280, 720, "Mjolnir")
}

setup :: proc(engine: ^mjolnir.Engine) {
  using mjolnir
  log.info("Setup function called!")
  set_visibility_stats(engine, false)
  // engine.debug_ui_enabled = true
  plain_material_handle := engine.rm.builtin_materials[resources.Color.WHITE]
  cube_mesh_handle := engine.rm.builtin_meshes[resources.Primitive.CUBE]
  sphere_mesh_handle := engine.rm.builtin_meshes[resources.Primitive.SPHERE]
  cone_mesh_handle := engine.rm.builtin_meshes[resources.Primitive.CONE]
  when true {
    log.info("spawning cubes in a grid")
    space: f32 = 4.1
    cube_size: f32 = 0.3
    nx, ny, nz := 240, 1, 240
    mat_handle := engine.rm.builtin_materials[resources.Color.CYAN]
    spawn_loop: for x in 0 ..< nx {
      for y in 0 ..< ny {
        for z in 0 ..< nz {
          world_x := (f32(x) - f32(nx) * 0.5) * space
          world_y := (f32(y) - f32(ny) * 0.5) * space + 2.25
          world_z := (f32(z) - f32(nz) * 0.5) * space
          node_handle: NodeHandle
          node_ok := false
          if x % 3 == 0 {
            node_handle, node_ok = spawn(
              engine,
              attachment = world.MeshAttachment {
                handle = cube_mesh_handle,
                material = mat_handle,
                cast_shadow = true,
              },
            )
          } else if x % 3 == 1 {
            node_handle, node_ok = spawn(
              engine,
              attachment = world.MeshAttachment {
                handle = cone_mesh_handle,
                material = mat_handle,
                cast_shadow = true,
              },
            )
          } else {
            node_handle, node_ok = spawn(
              engine,
              attachment = world.MeshAttachment {
                handle = sphere_mesh_handle,
                material = mat_handle,
                cast_shadow = true,
              },
            )
          }
          if !node_ok do break spawn_loop
          translate(engine, node_handle, world_x, world_y, world_z)
          scale(engine, node_handle, cube_size)
        }
      }
    }
  }
  when true {
    brick_wall_mat_handle: MaterialHandle
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
    ground_mesh_handle := engine.rm.builtin_meshes[resources.Primitive.QUAD]
    log.info("spawning ground and walls")
    size: f32 = 15.0
    if brick_wall_mat_ok {
      ground_handle := spawn(
        engine,
        attachment = world.MeshAttachment {
          handle = ground_mesh_handle,
          material = brick_wall_mat_handle,
        },
      )
      scale(engine, ground_handle, size)
      left_wall_handle := spawn(
        engine,
        attachment = world.MeshAttachment {
          handle = ground_mesh_handle,
          material = brick_wall_mat_handle,
        },
      )
      translate(engine, left_wall_handle, x = size, y = size)
      rotate(engine, left_wall_handle, math.PI * 0.5, linalg.VECTOR3F32_Z_AXIS)
      scale(engine, left_wall_handle, size)
      right_wall_handle := spawn(
        engine,
        attachment = world.MeshAttachment {
          handle = ground_mesh_handle,
          material = brick_wall_mat_handle,
        },
      )
      translate(engine, right_wall_handle, x = -size, y = size)
      rotate(
        engine,
        right_wall_handle,
        -math.PI * 0.5,
        linalg.VECTOR3F32_Z_AXIS,
      )
      scale(engine, right_wall_handle, size)
      back_wall_handle := spawn(
        engine,
        attachment = world.MeshAttachment {
          handle = ground_mesh_handle,
          material = brick_wall_mat_handle,
        },
      )
      translate(engine, back_wall_handle, y = size, z = -size)
      rotate(engine, back_wall_handle, math.PI * 0.5, linalg.VECTOR3F32_X_AXIS)
      scale(engine, back_wall_handle, size)
      ceiling_handle := spawn(
        engine,
        attachment = world.MeshAttachment {
          handle = ground_mesh_handle,
          material = brick_wall_mat_handle,
        },
      )
      translate(engine, ceiling_handle, y = 2 * size)
      rotate(engine, ceiling_handle, -math.PI, linalg.VECTOR3F32_X_AXIS)
      scale(engine, ceiling_handle, size)
    }
  }
  when true {
    log.info("loading Hammer GLTF...")
    if gltf_nodes, ok := load_gltf(engine, "assets/Mjolnir.glb"); ok {
      log.infof("Loaded GLTF nodes: %v", gltf_nodes)
      for handle in gltf_nodes {
        translate(engine, handle, 3, 1, -2)
        scale(engine, handle, 0.2)
      }
    }
  }
  when true {
    log.info("loading Warrior GLTF...")
    if gltf_nodes, ok := load_gltf(engine, "assets/Warrior.glb"); ok {
      log.infof("Loaded GLTF nodes: %v", gltf_nodes)
      for armature in gltf_nodes {
        armature_ptr := get_node(engine, armature)
        for i in 1 ..< len(armature_ptr.children) {
          play_animation(engine, armature_ptr.children[i], "idle")
        }
        translate(engine, armature, 0, 0, 1)
        for child_handle in armature_ptr.children {
          child_node := get_node(engine, child_handle) or_continue
          mesh_attachment, has_mesh := child_node.attachment.(world.MeshAttachment)
          if !has_mesh do continue
          _, has_skin := mesh_attachment.skinning.?
          if !has_skin do continue
          hand_cube_handle := spawn_child(
            engine,
            child_handle,
            attachment = world.MeshAttachment {
              handle = cube_mesh_handle,
              material = plain_material_handle,
              cast_shadow = true,
            },
          ) or_continue
          hand_cube_node := get_node(engine, hand_cube_handle)
          // Attach a cube to the hand.L bone
          hand_cube_node.bone_socket = "hand.L"
          scale(engine, hand_cube_handle, 0.1)
          // Create a spinning animation
          spin_duration: f32 = 2.0
          if spin_clip_handle, spin_ok := create_animation_clip(
            engine,
            channel_count = 1,
            duration = spin_duration,
            name = "cube_spin",
          ); spin_ok {
            rotation_fn :: proc(i: int) -> quaternion128 {
              angles := [3]f32{0, math.PI, 0} // identity, 180deg, identity
              return linalg.quaternion_angle_axis(
                angles[i],
                linalg.VECTOR3F32_Y_AXIS,
              )
            }
            init_animation_channel(
              engine,
              spin_clip_handle,
              channel_idx = 0,
              rotation_count = 3,
              rotation_fn = rotation_fn,
              rotation_interpolation = .CUBICSPLINE,
            )
            if node, ok := get_node(engine, hand_cube_handle); ok {
              node.animation = world.AnimationInstance {
                clip_handle = spin_clip_handle,
                mode        = .LOOP,
                status      = .PLAYING,
                time        = 0.0,
                duration    = spin_duration,
                speed       = 1.0,
              }
              world.register_animatable_node(&engine.world, hand_cube_handle)
            }
          }
          break
        }
      }
    }
  }
  when true {
    log.info("loading Damaged Helmet GLTF...")
    if gltf_nodes, ok := load_gltf(engine, "assets/DamagedHelmet.glb"); ok {
      log.infof("Loaded GLTF nodes: %v", gltf_nodes)
      for handle in gltf_nodes {
        translate(engine, handle, 0, 1, 3)
        scale(engine, handle, 0.5)
      }
    }
  }
  when true {
    log.info("loading Suzanne GLTF...")
    if gltf_nodes, ok := load_gltf(engine, "assets/Suzanne.glb"); ok {
      log.infof("Loaded GLTF nodes: %v", gltf_nodes)
      for handle in gltf_nodes {
        translate(engine, handle, -3, 1, 0)
      }
    }
  }
  when true {
    log.info("loading Fox GLTF...")
    if gltf_nodes, ok := load_gltf(engine, "assets/Fox2.glb"); ok {
      log.infof("Loaded GLTF nodes: %v", gltf_nodes)
      for handle in gltf_nodes {
        translate(engine, handle, 6, 0, 0)
        armature_ptr := get_node(engine, handle)
        for i in 1 ..< len(armature_ptr.children) {
          play_animation(engine, armature_ptr.children[i], "Run")
        }
      }
    }
  }
  when true {
    log.infof("creating %d lights with animated root", LIGHT_COUNT)
    // Create root node for all lights with rotation animation
    lights_root_handle := spawn(engine, {0, 2, 0})
    // Create rotation animation
    rotation_duration: f32 = 10.0
    if rotation_clip_handle, rotation_ok := create_animation_clip(
      engine,
      channel_count = 1,
      duration = rotation_duration,
      name = "lights_rotation",
    ); rotation_ok {
      rotation_fn :: proc(i: int) -> quaternion128 {
        angle := f32(i) * math.PI * 0.5 // 0, 90, 180, 270, 360 degrees
        return linalg.quaternion_angle_axis(angle, linalg.VECTOR3F32_Y_AXIS)
      }

      init_animation_channel(
        engine,
        rotation_clip_handle,
        channel_idx = 0,
        rotation_count = 5,
        rotation_fn = rotation_fn,
        rotation_interpolation = .LINEAR,
      )

      if lights_root_node, ok := get_node(engine, lights_root_handle); ok {
        lights_root_node.animation = world.AnimationInstance {
          clip_handle = rotation_clip_handle,
          mode        = .LOOP,
          status      = .PLAYING,
          time        = 0.0,
          duration    = rotation_duration,
          speed       = 1.0,
        }
        world.register_animatable_node(&engine.world, lights_root_handle)
        log.info("created light rotating animation with 5 keyframes")
      }
    }
    // Create lights as children of the root, arranged in a circle
    radius: f32 = 10.0
    for i in 0 ..< LIGHT_COUNT {
      color := [4]f32 {
        math.sin(f32(i)),
        math.cos(f32(i)),
        math.sin(f32(i)),
        1.0,
      }
      // Calculate fixed local position in a circle
      angle := f32(i) / f32(LIGHT_COUNT) * math.PI * 2.0
      local_x := math.cos(angle) * radius
      local_z := math.sin(angle) * radius
      local_y: f32 = 4.0
      should_make_spot_light := i % 2 != 1
      if ALL_SPOT_LIGHT {
        should_make_spot_light = true
      } else if ALL_POINT_LIGHT {
        should_make_spot_light = false
      }
      light_handle: NodeHandle
      if should_make_spot_light {
        light_handle =
        spawn_child_spot_light(
          engine,
          color,
          14.0,
          math.PI * 0.25,
          lights_root_handle,
        ) or_continue
        translate(engine, light_handle, local_x, local_y, local_z)
        rotate(engine, light_handle, math.PI * 0.5, linalg.VECTOR3F32_X_AXIS)
      } else {
        light_handle =
        spawn_child_point_light(
          engine,
          color,
          14.0,
          lights_root_handle,
        ) or_continue
        translate(engine, light_handle, local_x, local_y, local_z)
      }
      cube_handle := spawn_child(
        engine,
        light_handle,
        attachment = world.MeshAttachment {
          handle = cube_mesh_handle,
          material = plain_material_handle,
          cast_shadow = false,
        },
      )
      scale(engine, cube_handle, 0.05)
      translate(engine, cube_handle, y = 0.5)
    }
    when false {
      dir_light_handle := spawn_directional_light(
        engine,
        {0.2, 0.5, 0.9, 1.0},
        true,
        {0, 10, 0},
      )
      rotate(
        engine,
        dir_light_handle,
        math.PI * 0.25,
        linalg.VECTOR3F32_X_AXIS,
      )
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
    if emissive_ok {
      _, bright_ball_node, bright_ok := spawn(
        engine,
        world.MeshAttachment {
          handle = sphere_mesh_handle,
          material = emissive_handle,
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
    goldstar_material_handle: MaterialHandle
    goldstar_material_ok := false
    if goldstar_texture_ok {
      goldstar_material_handle, goldstar_material_ok = create_material(
        engine,
        {.ALBEDO_TEXTURE},
        type = .TRANSPARENT,
        albedo_handle = goldstar_texture_handle,
      )
    }
    psys_handle1 := spawn(engine, {-2.0, 1.9, 0.3})
    if goldstar_texture_ok {
      emitter_handle1, emitter1_ok := create_emitter(
        engine,
        psys_handle1,
        texture_handle = goldstar_texture_handle,
        emission_rate = 7,
        particle_lifetime = 5.0,
        position_spread = 1.5,
        initial_velocity = {0, -0.1, 0},
        velocity_spread = 0.1,
        color_start = {1, 1, 0, 1},
        color_end = {1, 0.5, 0, 0},
        size_start = 200.0,
        size_end = 100.0,
        weight = 0.1,
        weight_spread = 0.05,
        aabb_min = {-2, -2, -2},
        aabb_max = {2, 2, 2},
      )
      if emitter1_ok {
        spawn_child(
          engine,
          psys_handle1,
          attachment = world.EmitterAttachment{emitter_handle1},
        )
      }
    }
    psys_handle2 := spawn(engine, {2.0, 1.9, 0.3})
    if black_circle_ok {
      emitter_handle2, emitter2_ok := create_emitter(
        engine,
        psys_handle2,
        texture_handle = black_circle_texture_handle,
        emission_rate = 7,
        particle_lifetime = 3.0,
        position_spread = 0.3,
        initial_velocity = {0, 0.2, 0},
        velocity_spread = 0.15,
        color_start = {0, 0, 1, 1},
        color_end = {0, 1, 1, 0},
        size_start = 350.0,
        size_end = 175.0,
        weight = 0.1,
        weight_spread = 0.3,
        aabb_min = {-1, -1, -1},
        aabb_max = {1, 1, 1},
      )
      if emitter2_ok {
        spawn_child(
          engine,
          psys_handle2,
          attachment = world.EmitterAttachment{emitter_handle2},
        )
      }
    }
    forcefield_root_handle := spawn(engine, {0, 4, 0})
    if forcefield_clip_handle, ok := create_animation_clip(
      engine,
      channel_count = 1,
      duration = 8,
      name = "forcefield_rotation",
    ); ok {
      rotation_fn :: proc(i: int) -> quaternion128 {
        angle := f32(i) * math.PI * 0.5 // 0, 90, 180, 270, 360 degrees
        return linalg.quaternion_angle_axis(angle, linalg.VECTOR3F32_Y_AXIS)
      }
      init_animation_channel(
        engine,
        forcefield_clip_handle,
        channel_idx = 0,
        rotation_count = 5,
        rotation_fn = rotation_fn,
        rotation_interpolation = .LINEAR,
      )
      if node, ok := get_node(engine, forcefield_root_handle); ok {
        node.animation = world.AnimationInstance {
          clip_handle = forcefield_clip_handle,
          mode        = .LOOP,
          status      = .PLAYING,
          time        = 0.0,
          duration    = rotation_duration,
          speed       = 1.0,
        }
        world.register_animatable_node(&engine.world, forcefield_root_handle)
      }
    }
    forcefield_handle := spawn_child(engine, forcefield_root_handle)
    translate(engine, forcefield_handle, 3.0, 0.0, 0.0)
    if node, ok := get_node(engine, forcefield_handle); ok {
      node.attachment = world.ForceFieldAttachment {
        handle = create_forcefield(
          engine,
          forcefield_handle,
          tangent_strength = 2.0,
          strength = 20.0,
          area_of_effect = 5.0,
        ),
      }
    }
    handle := spawn_child(
      engine,
      forcefield_handle,
      attachment = world.MeshAttachment {
        handle = sphere_mesh_handle,
        material = goldstar_material_handle,
        cast_shadow = false,
      },
    )
    scale(engine, handle, 0.2)
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
    portal_camera_handle = create_camera(
      engine,
      512, // width
      512, // height
      {.GEOMETRY, .LIGHTING, .TRANSPARENCY, .PARTICLES}, // enabled passes (no post-process for performance)
      {5, 15, 7}, // camera position
      {0, 0, 0}, // looking at origin
      math.PI * 0.5, // FOV
      0.1, // near plane
      100.0, // far plane
    )
    portal_material_ok: bool
    portal_material_handle, portal_material_ok = create_material(
      engine,
      {.ALBEDO_TEXTURE},
    )
    portal_quad_handle := engine.rm.builtin_meshes[resources.Primitive.QUAD]
    portal_mesh_ok := true
    if portal_material_ok && portal_mesh_ok {
      handle := spawn(
        engine,
        attachment = world.MeshAttachment {
          handle = portal_quad_handle,
          material = portal_material_handle,
          cast_shadow = false,
        },
      )
      translate(engine, handle, 0, 3, -5)
      rotate(engine, handle, math.PI * 0.5, linalg.VECTOR3F32_X_AXIS)
      scale(engine, handle, 2.0)
    }
  }
  when true {
    log.info(
      "spawning Warrior effect sprite with animation (99 frames @ 24fps)...",
    )
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
        frame_columns = 6, // 6 columns in sprite sheet
        frame_rows = 17, // 17 rows in sprite sheet
        frame_index = 0, // Starting frame (animation will override this)
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
          handle, spawn_ok := world.spawn(
            &engine.world,
            {4, 1.5, 0},
            sprite_attachment,
            &engine.rm,
          )
          if spawn_ok {
            scale(engine, handle, 3.0)
            // sprite_node.culling_enabled = false
          }
        }
      }
    }
  }
  log.info("setup complete")
}

on_key_pressed :: proc(engine: ^mjolnir.Engine, key, action, mods: int) {
  using mjolnir
  log.infof("key pressed key %d action %d mods %x", key, action, mods)
  if action == glfw.RELEASE do return
  if key == glfw.KEY_TAB {
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
  update_material_texture(
    engine,
    portal_material_handle,
    .ALBEDO_TEXTURE,
    get_camera_attachment(
      engine,
      portal_camera_handle,
      .FINAL_IMAGE,
      engine.frame_index,
    ),
  )
}

package main

import "core:log"
import "core:math"
import "core:math/linalg"
import "mjolnir"
import "mjolnir/animation"
import "mjolnir/input"
import "mjolnir/render"
import "mjolnir/world"

LIGHT_COUNT :: 10
ALL_SPOT_LIGHT :: false
ALL_POINT_LIGHT :: false
ENABLE_DIRECTIONAL_LIGHT :: true
portal_camera_handle: render.CameraHandle
portal_material_handle: render.MaterialHandle
warrior_sprite: render.SpriteHandle
warrior_time: f32

// A loaded glTF and one animator per skinned node in it.
Character :: struct {
  scene:     mjolnir.GltfScene,
  animators: [dynamic]animation.Animator,
}

// A node whose local transform plays a one-channel clip on top of `rest`.
// With a socket, the result is placed in the space of a character's bone.
NodeClip :: struct {
  node:      world.NodeHandle,
  clip:      animation.Clip,
  rest:      animation.TRS,
  time:      f32,
  speed:     f32,
  status:    animation.Status,
  socket:    bool,
  character: int, // index into characters
  skinned:   int, // index into characters[character].animators
  bone:      u32,
}

characters: [dynamic]Character
node_clips: [dynamic]NodeClip

add_character :: proc(scene: mjolnir.GltfScene, clip: string) -> int {
  c := Character{scene = scene}
  for s in scene.skinned {
    rig := &c.scene.rigs[s.rig]
    a: animation.Animator
    animation.animator_init(&a, rig)
    animation.play(&a, rig, clip)
    append(&c.animators, a)
  }
  append(&characters, c)
  return len(characters) - 1
}

// One-channel clip rotating about Y through `angles`, keys evenly spaced over `duration`.
spin_clip :: proc(name: string, duration: f32, angles: []f32, interpolation: animation.Interpolation) -> (clip: animation.Clip) {
  animation.clip_init(&clip, 1, name, duration)
  times := make([]f32, len(angles), context.temp_allocator)
  per_key := 3 if interpolation == .CUBIC else 1
  values := make([]quaternion128, len(angles) * per_key, context.temp_allocator)
  for a, i in angles {
    times[i] = f32(i) * duration / f32(len(angles) - 1) if len(angles) > 1 else 0
    // CUBIC keys carry zero in/out tangents around the value
    values[i * per_key + per_key / 2] = linalg.quaternion_angle_axis(a, linalg.VECTOR3F32_Y_AXIS)
  }
  animation.clip_set_rotations(&clip, 0, times, values, interpolation)
  return
}

add_node_clip :: proc(engine: ^mjolnir.Engine, node: world.NodeHandle, clip: animation.Clip) -> ^NodeClip {
  n := world.node(&engine.world, node)
  rest := animation.TRS_IDENTITY
  if n != nil do rest = {n.transform.position, n.transform.rotation, n.transform.scale}
  append(&node_clips, NodeClip{node = node, clip = clip, rest = rest, speed = 1, status = .PLAYING})
  return &node_clips[len(node_clips) - 1]
}

update :: proc(engine: ^mjolnir.Engine, dt: f32) {
  if !engine.keyboard_captured {
    it := 0
    for key, pressed in input.next_key_edge(&engine.input, &it) do on_key(engine, key, pressed)
  }
  for &c in characters {
    for s, i in c.scene.skinned do animation.animator_update(&c.animators[i], &c.scene.rigs[s.rig], dt)
  }
  for &nc in node_clips {
    animation.playback_advance(&nc.time, &nc.speed, &nc.status, .LOOP, nc.clip.duration, dt)
    trs := nc.rest
    animation.clip_sample_trs(&nc.clip, 0, nc.time, &trs)
    m := animation.trs_matrix(trs)
    if nc.socket do m = animation.bone_matrix(&characters[nc.character].animators[nc.skinned], nc.bone) * m
    world.set_local_matrix(&engine.world, nc.node, m)
  }
  // 99-frame sprite sheet looping at 24 fps
  warrior_time += dt
  render.set_sprite_frame(&engine.render, warrior_sprite, u32(warrior_time * 24) % 99)
  world.update(&engine.world)
  for i in world.removed_nodes(&engine.world) do render.stage_slot_removal(&engine.render, i)
  for n in world.changed_nodes(&engine.world) do render.stage_transform(&engine.render, n.index, n.world_matrix, n.visible)
  for &c in characters {
    for s, i in c.scene.skinned do render.stage_bones(&engine.render, s.node.index, c.animators[i].palette)
  }
}

main :: proc() {
  context.logger = log.create_console_logger()
  engine := new(mjolnir.Engine)
  engine.setup_proc = setup
  engine.post_render_proc = on_post_render
  engine.update_proc = update
  defer for &c in characters do mjolnir.gltf_scene_destroy(&c.scene)
  mjolnir.run(engine, 1280, 720, "Mjolnir")
}

setup :: proc(engine: ^mjolnir.Engine) {
  engine.debug_ui_enabled = true
  plain_material_handle := engine.render.builtin_materials[render.Color.WHITE]
  cube_mesh_handle := engine.render.builtin_meshes[render.Primitive.CUBE]
  sphere_mesh_handle := engine.render.builtin_meshes[render.Primitive.SPHERE]
  cone_mesh_handle := engine.render.builtin_meshes[render.Primitive.CONE]
  when true {
    log.info("spawning cubes in a grid")
    space: f32 = 4.1
    cube_size: f32 = 0.3
    nx, ny, nz := 240, 1, 240
    mat_handle := engine.render.builtin_materials[render.Color.CYAN]
    spawn_loop: for x in 0 ..< nx {
      for y in 0 ..< ny {
        for z in 0 ..< nz {
          world_x := (f32(x) - f32(nx) * 0.5) * space
          world_y := (f32(y) - f32(ny) * 0.5) * space + 2.25
          world_z := (f32(z) - f32(nz) * 0.5) * space
          node_handle: world.NodeHandle
          node_ok := false
          if x % 3 == 0 {
            node_handle, node_ok = mjolnir.spawn(
              engine,
              attachment = render.MeshAttachment {
                handle = cube_mesh_handle,
                material = mat_handle,
                cast_shadow = true,
              },
            )
          } else if x % 3 == 1 {
            node_handle, node_ok = mjolnir.spawn(
              engine,
              attachment = render.MeshAttachment {
                handle = cone_mesh_handle,
                material = mat_handle,
                cast_shadow = true,
              },
            )
          } else {
            node_handle, node_ok = mjolnir.spawn(
              engine,
              attachment = render.MeshAttachment {
                handle = sphere_mesh_handle,
                material = mat_handle,
                cast_shadow = true,
              },
            )
          }
          if !node_ok do break spawn_loop
          world.translate(
            &engine.world,
            node_handle,
            world_x,
            world_y,
            world_z,
          )
          world.scale(&engine.world, node_handle, cube_size)
        }
      }
    }
  }
  when true {
    brick_wall_mat_handle: render.MaterialHandle
    brick_wall_mat_ok := false
    brick_albedo_handle, brick_albedo_ret := render.create_texture_from_path(&engine.render, "assets/t_brick_floor_002_diffuse_1k.jpg",
    )
    if brick_albedo_ret == .SUCCESS {
      brick_wall_mat_handle, brick_wall_mat_ok = render.create_material(
        &engine.render,
        {.ALBEDO_TEXTURE},
        albedo_handle = brick_albedo_handle,
      )
    }
    ground_mesh_handle := engine.render.builtin_meshes[render.Primitive.QUAD_XZ]
    log.info("spawning ground and walls")
    size: f32 = 15.0
    if brick_wall_mat_ok {
      ground_handle := mjolnir.spawn(
        engine,
        {0, 0, 0},
        render.MeshAttachment {
          handle = ground_mesh_handle,
          material = brick_wall_mat_handle,
        },
      )
      world.scale(&engine.world, ground_handle, size)
      left_wall_handle := mjolnir.spawn(
        engine,
        {0, 0, 0},
        attachment = render.MeshAttachment {
          handle = ground_mesh_handle,
          material = brick_wall_mat_handle,
        },
      )
      world.translate(&engine.world, left_wall_handle, x = size, y = size)
      world.rotate(
        &engine.world,
        left_wall_handle,
        math.PI * 0.5,
        linalg.VECTOR3F32_Z_AXIS,
      )
      world.scale(&engine.world, left_wall_handle, size)
      right_wall_handle := mjolnir.spawn(
        engine,
        {0, 0, 0},
        attachment = render.MeshAttachment {
          handle = ground_mesh_handle,
          material = brick_wall_mat_handle,
        },
      )
      world.translate(&engine.world, right_wall_handle, x = -size, y = size)
      world.rotate(
        &engine.world,
        right_wall_handle,
        -math.PI * 0.5,
        linalg.VECTOR3F32_Z_AXIS,
      )
      world.scale(&engine.world, right_wall_handle, size)
      back_wall_handle := mjolnir.spawn(
        engine,
        {0, 0, 0},
        attachment = render.MeshAttachment {
          handle = ground_mesh_handle,
          material = brick_wall_mat_handle,
        },
      )
      world.translate(&engine.world, back_wall_handle, y = size, z = -size)
      world.rotate(
        &engine.world,
        back_wall_handle,
        math.PI * 0.5,
        linalg.VECTOR3F32_X_AXIS,
      )
      world.scale(&engine.world, back_wall_handle, size)
      ceiling_handle := mjolnir.spawn(
        engine,
        {0, 0, 0},
        attachment = render.MeshAttachment {
          handle = ground_mesh_handle,
          material = brick_wall_mat_handle,
        },
      )
      world.translate(&engine.world, ceiling_handle, y = 2 * size)
      world.rotate(
        &engine.world,
        ceiling_handle,
        -math.PI,
        linalg.VECTOR3F32_X_AXIS,
      )
      world.scale(&engine.world, ceiling_handle, size)
    }
  }
  when true {
    log.info("loading Hammer GLTF...")
    if gltf_nodes, ok := mjolnir.load_gltf(engine, "assets/Mjolnir.glb"); ok {
      defer mjolnir.gltf_scene_destroy(&gltf_nodes)
      log.infof("Loaded GLTF nodes: %v", gltf_nodes.roots)
      for handle in gltf_nodes.roots {
        world.translate(&engine.world, handle, 3, 1, -2)
        world.scale(&engine.world, handle, 0.2)
      }
    }
  }
  when true {
    log.info("loading Warrior GLTF...")
    if gltf_nodes, ok := mjolnir.load_gltf(engine, "assets/Warrior.glb"); ok {
      for armature in gltf_nodes.roots do world.translate(&engine.world, armature, 0, 0, 1)
      character := add_character(gltf_nodes, "idle")
      // Attach a spinning cube to the hand.L bone of the first skinned mesh
      for s, i in gltf_nodes.skinned {
        bone := animation.find_bone(&gltf_nodes.rigs[s.rig].skeleton, "hand.L") or_continue
        hand_cube_handle := mjolnir.spawn(
          engine,
          parent = s.node,
          attachment = render.MeshAttachment {
            handle = cube_mesh_handle,
            material = plain_material_handle,
            cast_shadow = true,
          },
        ) or_continue
        world.scale(&engine.world, hand_cube_handle, 0.1)
        nc := add_node_clip(engine, hand_cube_handle, spin_clip("cube_spin", 2.0, {0, math.PI, 0}, .CUBIC))
        nc.socket = true
        nc.character = character
        nc.skinned = i
        nc.bone = bone
        break
      }
    }
  }
  when true {
    log.info("loading Damaged Helmet GLTF...")
    if gltf_nodes, ok := mjolnir.load_gltf(engine, "assets/DamagedHelmet.glb");
       ok {
      defer mjolnir.gltf_scene_destroy(&gltf_nodes)
      log.infof("Loaded GLTF nodes: %v", gltf_nodes.roots)
      for handle in gltf_nodes.roots {
        world.translate(&engine.world, handle, 0, 1, 3)
        world.scale(&engine.world, handle, 0.5)
      }
    }
  }
  when true {
    log.info("loading Suzanne GLTF...")
    if gltf_nodes, ok := mjolnir.load_gltf(engine, "assets/Suzanne.glb"); ok {
      defer mjolnir.gltf_scene_destroy(&gltf_nodes)
      log.infof("Loaded GLTF nodes: %v", gltf_nodes.roots)
      for handle in gltf_nodes.roots {
        world.translate(&engine.world, handle, -3, 1, 0)
      }
    }
  }
  when true {
    log.info("loading SciFiHelmet GLTF...")
    if gltf_nodes, ok := mjolnir.load_gltf(engine, "assets/SciFiHelmet.glb");
       ok {
      defer mjolnir.gltf_scene_destroy(&gltf_nodes)
      log.infof("Loaded GLTF nodes: %v", gltf_nodes.roots)
      for handle in gltf_nodes.roots {
        world.translate(&engine.world, handle, 3, 0, 3)
        world.scale(&engine.world, handle, 0.5)
      }
    }
  }
  when true {
    log.info("loading Fox GLTF...")
    if gltf_nodes, ok := mjolnir.load_gltf(engine, "assets/Fox2.glb"); ok {
      log.infof("Loaded GLTF nodes: %v", gltf_nodes.roots)
      for handle in gltf_nodes.roots {
        world.translate(&engine.world, handle, 6, 0, 0)
      }
      add_character(gltf_nodes, "Run")
    }
  }
  when true {
    log.infof("creating %d lights with animated root", LIGHT_COUNT)
    // Create root node for all lights with rotation animation
    lights_root_handle := world.spawn(&engine.world, {0, 2, 0})
    add_node_clip(engine, lights_root_handle, spin_clip("lights_rotation", 10.0, {0, math.PI * 0.5, math.PI, math.PI * 1.5, math.PI * 2}, .LINEAR))
    when LIGHT_COUNT > 0 {
      // Create lights as children of the root, arranged in a circle
      radius: f32 = 8.0
      for i in 0 ..< LIGHT_COUNT {
        color := [4]f32 {
          math.sin(f32(i)),
          math.cos(f32(i)),
          math.sin(f32(i)),
          0.2,
        }
        // Calculate fixed local position in a circle
        angle := f32(i) / f32(LIGHT_COUNT) * math.PI * 2.0
        local_x := math.cos(angle) * radius
        local_z := math.sin(angle) * radius
        local_y: f32 = 5.0
        should_make_spot_light := i % 2 != 1
        if ALL_SPOT_LIGHT {
          should_make_spot_light = true
        } else if ALL_POINT_LIGHT {
          should_make_spot_light = false
        }
        light_handle: world.NodeHandle
        if should_make_spot_light {
          light_handle =
          mjolnir.spawn(
            engine,
            parent = lights_root_handle,
            attachment = render.SpotLightAttachment{
              color       = color,
              radius      = 14.0,
              angle_inner = math.PI * 0.25 * 0.8,
              angle_outer = math.PI * 0.25,
              cast_shadow = true,
            },
          ) or_continue
          world.translate(
            &engine.world,
            light_handle,
            local_x,
            local_y,
            local_z,
          )
          world.rotate(
            &engine.world,
            light_handle,
            math.PI * 0.5,
            linalg.VECTOR3F32_X_AXIS,
          )
        } else {
          light_handle =
          mjolnir.spawn(
            engine,
            parent = lights_root_handle,
            attachment = render.PointLightAttachment{color = color, radius = 14.0, cast_shadow = true},
          ) or_continue
          world.translate(
            &engine.world,
            light_handle,
            local_x,
            local_y,
            local_z,
          )
        }
        cube_handle := mjolnir.spawn(
          engine,
          parent = light_handle,
          attachment = render.MeshAttachment {
            handle = cube_mesh_handle,
            material = plain_material_handle,
            cast_shadow = false,
          },
        )
        world.scale(&engine.world, cube_handle, 0.05)
        world.translate(&engine.world, cube_handle, y = 0.5)
      }
    }
    when ENABLE_DIRECTIONAL_LIGHT {
      dir_light_handle, _ := mjolnir.spawn(engine, attachment = render.directional_light_attachment(color = {0.2, 0.5, 0.9, 3.0}, radius = 20, cast_shadow = true))
      world.rotate(&engine.world, dir_light_handle, math.PI * 0.2, linalg.VECTOR3F32_X_AXIS)
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
    black_circle_texture_handle, black_circle_ret := render.create_texture_from_path(&engine.render, "assets/particles/circle_05.png",
    )
    black_circle_ok := black_circle_ret == .SUCCESS
    goldstar_texture_handle, goldstar_texture_ret := render.create_texture_from_path(&engine.render, "assets/particles/star_07.png",
    )
    goldstar_texture_ok := goldstar_texture_ret == .SUCCESS
    goldstar_material_handle: render.MaterialHandle
    goldstar_material_ok := false
    if goldstar_texture_ok {
      goldstar_material_handle, goldstar_material_ok = render.create_material(
        &engine.render,
        {.ALBEDO_TEXTURE},
        type = .TRANSPARENT,
        albedo_handle = goldstar_texture_handle,
      )
    }
    psys_handle1 := world.spawn(&engine.world, {-2.0, 1.9, 0.3})
    if goldstar_texture_ok {
      emitter_handle1, emitter1_ok := render.create_emitter(
        &engine.render,
        texture_handle = goldstar_texture_handle,
        emission_rate = 70,
        particle_lifetime = 2.0,
        position_spread = 0.1,
        initial_velocity = {0, -0.1, 0},
        velocity_spread = 0.1,
        color_start = {1, 1, 0, 1},
        color_end = {1, 0.5, 0, 0},
        size_start = 200.0,
        size_end = 100.0,
        weight = 0.1,
        weight_spread = 0.05,
      )
      if emitter1_ok {
        mjolnir.spawn(
          engine,
          parent = psys_handle1,
          attachment = render.EmitterAttachment{emitter_handle1},
        )
      }
    }
    psys_handle2 := world.spawn(&engine.world, {2.0, 1.9, 0.3})
    if black_circle_ok {
      emitter_handle2, emitter2_ok := render.create_emitter(
        &engine.render,
        texture_handle = black_circle_texture_handle,
        emission_rate = 70,
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
      )
      if emitter2_ok {
        mjolnir.spawn(
          engine,
          parent = psys_handle2,
          attachment = render.EmitterAttachment{emitter_handle2},
        )
      }
    }
    forcefield_root_handle := world.spawn(&engine.world, {0, 4, 0})
    add_node_clip(engine, forcefield_root_handle, spin_clip("forcefield_rotation", 8, {0, math.PI * 0.5, math.PI, math.PI * 1.5, math.PI * 2}, .LINEAR))
    forcefield_handle := world.spawn_child(
      &engine.world,
      forcefield_root_handle,
    )
    world.translate(&engine.world, forcefield_handle, 3.0, 0.0, 0.0)
    if ff, ok := render.create_forcefield(
      &engine.render,
      tangent_strength = 2.0,
      strength = 20.0,
      area_of_effect = 5.0,
    ); ok {
      render.attach(&engine.render, forcefield_handle.index, render.ForceFieldAttachment{ff})
    }
    handle := mjolnir.spawn(
      engine,
      parent = forcefield_handle,
      attachment = render.MeshAttachment {
        handle = sphere_mesh_handle,
        material = goldstar_material_handle,
        cast_shadow = false,
      },
    )
    world.scale(&engine.world, handle, 0.2)
  }
  when false {
    render.debug_sphere(&engine.render, {0, 5, 0}, 5, render.debug_color(.WHITE), life = 5)
    render.debug_cube(&engine.render, {2, 3, 0}, size = {1, 1, 1}, color = render.debug_color(.CYAN), life = 5)
    render.debug_arrow(&engine.render, {0, 0, 0}, {3, 3, 0}, render.debug_color(.YELLOW), life = 5)
    render.debug_axes(&engine.render, {0, 0, 0}, scale = 2)
  }
  // post_process.add_fog(&engine.render.post_process, [3]f32{0.4, 0.0, 0.8}, 0.02, 5.0, 20.0)
  // add_bloom(engine)
  // post_process.add_crosshatch(&engine.render.post_process)
  // add_blur(engine, 18.0)
  // add_tonemap(engine, 1.5, 1.3)
  // add_dof(engine)
  // add_grayscale(engine, 0.9)
  // add_outline(engine, 2.0, [3]f32{1.0, 0.0, 0.0})
  when true {
    portal_camera_handle = render.create_camera(
      &engine.render,
      512, // width
      512, // height
      {5, 15, 7}, // camera position
      {0, 0, 0}, // looking at origin
      math.PI * 0.5, // FOV
      0.1, // near plane
      100.0, // far plane
    )
    portal_material_ok: bool
    portal_material_handle, portal_material_ok = render.create_material(
      &engine.render,
      {.ALBEDO_TEXTURE},
    )
    portal_quad_handle := engine.render.builtin_meshes[render.Primitive.QUAD_XY]
    portal_mesh_ok := true
    if portal_material_ok && portal_mesh_ok {
      handle := mjolnir.spawn(
        engine,
        {0, 0, 0},
        attachment = render.MeshAttachment {
          handle = portal_quad_handle,
          material = portal_material_handle,
          cast_shadow = false,
        },
      )
      world.translate(&engine.world, handle, 0, 3, -5)
      world.scale(&engine.world, handle, 2.0)
    }
  }
  when true {
    log.info(
      "spawning Warrior effect sprite with animation (99 frames @ 24fps)...",
    )
    warrior_sprite_texture, warrior_sprite_ret := render.create_texture_from_path(&engine.render, "assets/Warrior_Sheet-Effect.png",
    )
    if warrior_sprite_ret == .SUCCESS {
      sprite_quad := engine.render.builtin_meshes[render.Primitive.QUAD_XY]
      // 6x17 sprite sheet using frames 0-98, animated in update
      sprite_handle, sprite_ok := render.create_sprite(
        &engine.render,
        warrior_sprite_texture,
        frame_columns = 6,
        frame_rows = 17,
      )
      warrior_sprite = sprite_handle
      if sprite_ok {
        sprite_material, mat_ok := render.create_material(
          &engine.render,
          {.ALBEDO_TEXTURE},
          type = .TRANSPARENT,
          albedo_handle = warrior_sprite_texture,
        )
        if mat_ok {
          sprite_attachment := render.SpriteAttachment {
            sprite_handle = sprite_handle,
            mesh_handle   = sprite_quad,
            material      = sprite_material,
          }
          handle, spawn_ok := mjolnir.spawn(
            engine,
            {4, 1.5, 0},
            sprite_attachment,
          )
          if spawn_ok {
            world.scale(&engine.world, handle, 3.0)
          }
        }
      }
    }
  }
  log.info("setup complete")
}

on_key :: proc(engine: ^mjolnir.Engine, key: input.Key, pressed: bool) {
  log.infof("key %v %v", key, "PRESS" if pressed else "RELEASE")
  if !pressed do return
  if key == .TAB {
    if _, is_free := engine.camera_controller.data.(render.FreeCameraData); is_free {
      engine.camera_controller = render.orbit_controller()
    } else {
      engine.camera_controller = render.free_controller()
    }
  }
}

on_post_render :: proc(engine: ^mjolnir.Engine) {
  if material, ok := render.material(&engine.render, portal_material_handle);
     ok {
    material.albedo = render.camera_attachment(
      &engine.render,
      portal_camera_handle,
      .FINAL_IMAGE,
    )
    render.mark_material_dirty(&engine.render, portal_material_handle)
  }
}

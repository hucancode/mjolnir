package main

import "core:log"
import "core:math"
import "core:math/linalg"
import "mjolnir"
import "mjolnir/animation"
import "mjolnir/geometry"
import "mjolnir/input"
import "mjolnir/platform"
import "mjolnir/render"
import "mjolnir/world"

App :: struct {
  window:   platform.Platform,
  scene:    world.World,
  renderer: render.Renderer,
  free_cam: bool,
  input:    input.State,
}

LIGHT_COUNT :: 10
ALL_SPOT_LIGHT :: false
ALL_POINT_LIGHT :: false
ENABLE_DIRECTIONAL_LIGHT :: true
portal_camera_handle: render.CameraHandle
portal_material_handle: render.MaterialHandle
warrior_sprite: render.MaterialHandle
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
  player:    animation.ClipPlayer,
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

add_node_clip :: proc(app: ^App, node: world.NodeHandle, clip: animation.Clip) -> ^NodeClip {
  t := world.node(&app.scene, node).transform
  rest := animation.TRS{t.position, t.rotation, t.scale}
  append(&node_clips, NodeClip{node = node, clip = clip, rest = rest, player = {speed = 1}})
  return &node_clips[len(node_clips) - 1]
}

// WASD/QE fly, mouse look.
fly_camera :: proc(app: ^App, dt: f32) {
  cam := render.main_camera(&app.renderer)
  if cam == nil || app.input.keyboard_captured do return
  s := &app.input
  move := geometry.qx(cam.rotation) * input.axis(s, .A, .D) + {0, 1, 0} * input.axis(s, .Q, .E) - geometry.qz(cam.rotation) * input.axis(s, .S, .W)
  cam.position += move * 5 * dt
  d := s.mouse_delta * 0.002
  cam.rotation = linalg.quaternion_angle_axis(-d.x, linalg.VECTOR3F32_Y_AXIS) * cam.rotation
  cam.rotation = linalg.quaternion_angle_axis(-d.y, geometry.qx(cam.rotation)) * cam.rotation
}

update :: proc(app: ^App, dt: f32) {
  platform.read_input(&app.window, &app.input)
  if app.free_cam do fly_camera(app, dt)
  else {
    if cam, ok := render.main_camera(&app.renderer); ok && !app.input.mouse_captured {
      yaw, pitch, dist := render.camera_orbit_state(cam)
      if input.mouse_down(&app.input, .LEFT) {
        yaw += app.input.mouse_delta.x * 0.02
        pitch = clamp(pitch + app.input.mouse_delta.y * 0.02, -1.5, 1.5)
      }
      render.camera_orbit(cam, yaw, pitch, clamp(dist - app.input.scroll.y * 2, 1, 200))
    }
  }
  if !app.input.keyboard_captured {
    it := 0
    for key, pressed in input.next_key_edge(&app.input, &it) do on_key(app, key, pressed)
  }
  for &c in characters {
    for s, i in c.scene.skinned do animation.animator_update(&c.animators[i], &c.scene.rigs[s.rig], dt)
  }
  for &nc in node_clips {
    m := animation.clip_player_update(&nc.player, &nc.clip, dt, nc.rest)
    if nc.socket do m = animation.bone_matrix(&characters[nc.character].animators[nc.skinned], nc.bone) * m
    world.set_local_matrix(&app.scene, nc.node, m)
  }
  // 99-frame sprite sheet looping at 24 fps
  warrior_time += dt
  render.set_sprite_frame(&app.renderer, warrior_sprite, u32(warrior_time * 24) % 99)
  world.update(&app.scene)
  render.stage_transforms(&app.renderer, world.changes(&app.scene))
  for &c in characters {
    for s, i in c.scene.skinned do render.stage_bones(&app.renderer, s.node.index, c.animators[i].palette)
  }
  render.update(&app.renderer, dt)
}

main :: proc() {
  context.logger = log.create_console_logger()
  app := new(App)
  defer free(app)
  w := &app.window
  if !platform.init(w, 1280, 720, "Mjolnir") do return
  defer platform.shutdown(w)
  if !render.init(&app.renderer, "Mjolnir", w.window, platform.framebuffer_size(w), platform.dpi_scale(w)) do return
  defer render.shutdown(&app.renderer)
  if !world.init(&app.scene) do return
  defer world.shutdown(&app.scene)
  render.load_environment_map(&app.renderer, "assets/Cannon_Exterior.hdr")
  defer for &c in characters do mjolnir.gltf_scene_destroy(&c.scene)
  setup(app)
  mjolnir.run(mjolnir.Loop(App){app = app, should_close = should_close, update = update, frame = frame})
}

should_close :: proc(app: ^App) -> bool {
  return platform.should_close(&app.window)
}

frame :: proc(app: ^App) -> bool {
  platform.poll_events(&app.window)
  ok := render.frame(&app.renderer, platform.framebuffer_size(&app.window), platform.dpi_scale(&app.window))
  on_post_render(app)
  return ok
}

// Spawn a node under `parent` (the world root by default) and attach `attachment` to it.
spawn :: proc(
  app: ^App,
  position: [3]f32 = {0, 0, 0},
  attachment: render.Attachment = nil,
  parent: world.NodeHandle = {},
) -> (
  handle: world.NodeHandle,
  ok: bool,
) #optional_ok {
  handle = world.spawn_child(&app.scene, parent if parent != {} else app.scene.root, position) or_return
  if attachment != nil do render.attach(&app.renderer, handle.index, attachment)
  return handle, true
}

setup :: proc(app: ^App) {
  app.renderer.ibl_intensity = 0.3
  plain_material_handle := app.renderer.builtin_materials[render.Color.WHITE]
  cube_mesh_handle := app.renderer.builtin_meshes[render.Primitive.CUBE]
  sphere_mesh_handle := app.renderer.builtin_meshes[render.Primitive.SPHERE]
  cone_mesh_handle := app.renderer.builtin_meshes[render.Primitive.CONE]
  when true {
    log.info("spawning cubes in a grid")
    space: f32 = 4.1
    cube_size: f32 = 0.3
    nx, ny, nz := 240, 1, 240
    mat_handle := app.renderer.builtin_materials[render.Color.CYAN]
    spawn_loop: for x in 0 ..< nx {
      for y in 0 ..< ny {
        for z in 0 ..< nz {
          world_x := (f32(x) - f32(nx) * 0.5) * space
          world_y := (f32(y) - f32(ny) * 0.5) * space + 2.25
          world_z := (f32(z) - f32(nz) * 0.5) * space
          node_handle: world.NodeHandle
          node_ok := false
          if x % 3 == 0 {
            node_handle, node_ok = spawn(
              app,
              attachment = render.MeshAttachment {
                handle = cube_mesh_handle,
                material = mat_handle,
                cast_shadow = true,
              },
            )
          } else if x % 3 == 1 {
            node_handle, node_ok = spawn(
              app,
              attachment = render.MeshAttachment {
                handle = cone_mesh_handle,
                material = mat_handle,
                cast_shadow = true,
              },
            )
          } else {
            node_handle, node_ok = spawn(
              app,
              attachment = render.MeshAttachment {
                handle = sphere_mesh_handle,
                material = mat_handle,
                cast_shadow = true,
              },
            )
          }
          if !node_ok do break spawn_loop
          world.translate(
            &app.scene,
            node_handle,
            world_x,
            world_y,
            world_z,
          )
          world.scale(&app.scene, node_handle, cube_size)
        }
      }
    }
  }
  when true {
    brick_wall_mat_handle: render.MaterialHandle
    brick_wall_mat_ok := false
    brick_albedo_handle, brick_albedo_ok := render.create_texture_from_path(&app.renderer, "assets/t_brick_floor_002_diffuse_1k.jpg",
    )
    if brick_albedo_ok {
      brick_wall_mat_handle, brick_wall_mat_ok = render.create_material(
        &app.renderer,
        albedo_handle = brick_albedo_handle,
      )
    }
    ground_mesh_handle := app.renderer.builtin_meshes[render.Primitive.QUAD_XZ]
    log.info("spawning ground and walls")
    size: f32 = 15.0
    if brick_wall_mat_ok {
      ground_handle := spawn(
        app,
        {0, 0, 0},
        render.MeshAttachment {
          handle = ground_mesh_handle,
          material = brick_wall_mat_handle,
        },
      )
      world.scale(&app.scene, ground_handle, size)
      left_wall_handle := spawn(
        app,
        {0, 0, 0},
        attachment = render.MeshAttachment {
          handle = ground_mesh_handle,
          material = brick_wall_mat_handle,
        },
      )
      world.translate(&app.scene, left_wall_handle, x = size, y = size)
      world.rotate(
        &app.scene,
        left_wall_handle,
        math.PI * 0.5,
        linalg.VECTOR3F32_Z_AXIS,
      )
      world.scale(&app.scene, left_wall_handle, size)
      right_wall_handle := spawn(
        app,
        {0, 0, 0},
        attachment = render.MeshAttachment {
          handle = ground_mesh_handle,
          material = brick_wall_mat_handle,
        },
      )
      world.translate(&app.scene, right_wall_handle, x = -size, y = size)
      world.rotate(
        &app.scene,
        right_wall_handle,
        -math.PI * 0.5,
        linalg.VECTOR3F32_Z_AXIS,
      )
      world.scale(&app.scene, right_wall_handle, size)
      back_wall_handle := spawn(
        app,
        {0, 0, 0},
        attachment = render.MeshAttachment {
          handle = ground_mesh_handle,
          material = brick_wall_mat_handle,
        },
      )
      world.translate(&app.scene, back_wall_handle, y = size, z = -size)
      world.rotate(
        &app.scene,
        back_wall_handle,
        math.PI * 0.5,
        linalg.VECTOR3F32_X_AXIS,
      )
      world.scale(&app.scene, back_wall_handle, size)
      ceiling_handle := spawn(
        app,
        {0, 0, 0},
        attachment = render.MeshAttachment {
          handle = ground_mesh_handle,
          material = brick_wall_mat_handle,
        },
      )
      world.translate(&app.scene, ceiling_handle, y = 2 * size)
      world.rotate(
        &app.scene,
        ceiling_handle,
        -math.PI,
        linalg.VECTOR3F32_X_AXIS,
      )
      world.scale(&app.scene, ceiling_handle, size)
    }
  }
  when true {
    log.info("loading Hammer GLTF...")
    if gltf_nodes, ok := mjolnir.load_gltf(&app.scene, &app.renderer, "assets/Mjolnir.glb"); ok {
      defer mjolnir.gltf_scene_destroy(&gltf_nodes)
      log.infof("Loaded GLTF nodes: %v", gltf_nodes.roots)
      for handle in gltf_nodes.roots {
        world.translate(&app.scene, handle, 3, 1, -2)
        world.scale(&app.scene, handle, 0.2)
      }
    }
  }
  when true {
    log.info("loading Warrior GLTF...")
    if gltf_nodes, ok := mjolnir.load_gltf(&app.scene, &app.renderer, "assets/Warrior.glb"); ok {
      for armature in gltf_nodes.roots do world.translate(&app.scene, armature, 0, 0, 1)
      character := add_character(gltf_nodes, "idle")
      // Attach a spinning cube to the hand.L bone of the first skinned mesh
      for s, i in gltf_nodes.skinned {
        bone := animation.find_bone(&gltf_nodes.rigs[s.rig].skeleton, "hand.L") or_continue
        hand_cube_handle := spawn(
          app,
          parent = s.node,
          attachment = render.MeshAttachment {
            handle = cube_mesh_handle,
            material = plain_material_handle,
            cast_shadow = true,
          },
        ) or_continue
        world.scale(&app.scene, hand_cube_handle, 0.1)
        nc := add_node_clip(app, hand_cube_handle, spin_clip("cube_spin", 2.0, {0, math.PI, 0}, .CUBIC))
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
    if gltf_nodes, ok := mjolnir.load_gltf(&app.scene, &app.renderer, "assets/DamagedHelmet.glb");
       ok {
      defer mjolnir.gltf_scene_destroy(&gltf_nodes)
      log.infof("Loaded GLTF nodes: %v", gltf_nodes.roots)
      for handle in gltf_nodes.roots {
        world.translate(&app.scene, handle, 0, 1, 3)
        world.scale(&app.scene, handle, 0.5)
      }
    }
  }
  when true {
    log.info("loading Suzanne GLTF...")
    if gltf_nodes, ok := mjolnir.load_gltf(&app.scene, &app.renderer, "assets/Suzanne.glb"); ok {
      defer mjolnir.gltf_scene_destroy(&gltf_nodes)
      log.infof("Loaded GLTF nodes: %v", gltf_nodes.roots)
      for handle in gltf_nodes.roots {
        world.translate(&app.scene, handle, -3, 1, 0)
      }
    }
  }
  when true {
    log.info("loading SciFiHelmet GLTF...")
    if gltf_nodes, ok := mjolnir.load_gltf(&app.scene, &app.renderer, "assets/SciFiHelmet.glb");
       ok {
      defer mjolnir.gltf_scene_destroy(&gltf_nodes)
      log.infof("Loaded GLTF nodes: %v", gltf_nodes.roots)
      for handle in gltf_nodes.roots {
        world.translate(&app.scene, handle, 3, 0, 3)
        world.scale(&app.scene, handle, 0.5)
      }
    }
  }
  when true {
    log.info("loading Fox GLTF...")
    if gltf_nodes, ok := mjolnir.load_gltf(&app.scene, &app.renderer, "assets/Fox2.glb"); ok {
      log.infof("Loaded GLTF nodes: %v", gltf_nodes.roots)
      for handle in gltf_nodes.roots {
        world.translate(&app.scene, handle, 6, 0, 0)
      }
      add_character(gltf_nodes, "Run")
    }
  }
  when true {
    log.infof("creating %d lights with animated root", LIGHT_COUNT)
    // Create root node for all lights with rotation animation
    lights_root_handle := world.spawn(&app.scene, {0, 2, 0})
    add_node_clip(app, lights_root_handle, spin_clip("lights_rotation", 10.0, {0, math.PI * 0.5, math.PI, math.PI * 1.5, math.PI * 2}, .LINEAR))
    when LIGHT_COUNT > 0 {
      // Create lights as children of the root, arranged in a circle
      radius: f32 = 8.0
      for i in 0 ..< LIGHT_COUNT {
        color := [4]f32 {
          0.5 + 0.5 * math.sin(f32(i)),
          0.5 + 0.5 * math.cos(f32(i)),
          0.5 + 0.5 * math.sin(f32(i)),
          0.5,
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
          spawn(
            app,
            parent = lights_root_handle,
            attachment = render.Light{
              type        = .SPOT,
              color       = color,
              radius      = 14.0,
              angle_inner = math.PI * 0.25 * 0.8,
              angle_outer = math.PI * 0.25,
              should_cast_shadow = true,
            },
          ) or_continue
          world.translate(
            &app.scene,
            light_handle,
            local_x,
            local_y,
            local_z,
          )
          world.rotate(
            &app.scene,
            light_handle,
            math.PI * 0.5,
            linalg.VECTOR3F32_X_AXIS,
          )
        } else {
          light_handle =
          spawn(
            app,
            parent = lights_root_handle,
            attachment = render.Light{type = .POINT, color = color, radius = 14.0, should_cast_shadow = true},
          ) or_continue
          world.translate(
            &app.scene,
            light_handle,
            local_x,
            local_y,
            local_z,
          )
        }
        cube_handle := spawn(
          app,
          parent = light_handle,
          attachment = render.MeshAttachment {
            handle = cube_mesh_handle,
            material = plain_material_handle,
            cast_shadow = false,
          },
        )
        world.scale(&app.scene, cube_handle, 0.05)
        world.translate(&app.scene, cube_handle, y = 0.5)
      }
    }
    when ENABLE_DIRECTIONAL_LIGHT {
      dir_light_handle, _ := spawn(app, attachment = render.directional_light_attachment(color = {0.2, 0.5, 0.9, 3.0}, shadow_radius = 20, cast_shadow = true))
      world.rotate(&app.scene, dir_light_handle, math.PI * 0.2, linalg.VECTOR3F32_X_AXIS)
    }
  }
  when false {
    log.info("Setting up bloom...")
    append(&app.renderer.effect_stack, render.BloomEffect{threshold = 0.8, intensity = 0.5, blur_radius = 16.0})
    // A bright white ball to test the bloom effect
    if emissive_handle, emissive_ok := render.create_material(&app.renderer, emissive_value = 30.0); emissive_ok {
      bright_ball := spawn(
        app,
        attachment = render.MeshAttachment {
          handle = sphere_mesh_handle,
          material = emissive_handle,
          cast_shadow = false,
        },
      )
      world.translate(&app.scene, bright_ball, x = 1.0)
      world.scale(&app.scene, bright_ball, 0.2)
    }
  }
  when true {
    log.info("Setting up particles...")
    black_circle_texture_handle, black_circle_ok := render.create_texture_from_path(&app.renderer, "assets/particles/circle_05.png",
    )
    goldstar_texture_handle, goldstar_texture_ok := render.create_texture_from_path(&app.renderer, "assets/particles/star_07.png",
    )
    goldstar_material_handle: render.MaterialHandle
    goldstar_material_ok := false
    if goldstar_texture_ok {
      goldstar_material_handle, goldstar_material_ok = render.create_material(
        &app.renderer,
        type = .TRANSPARENT,
        albedo_handle = goldstar_texture_handle,
      )
    }
    psys_handle1 := world.spawn(&app.scene, {-2.0, 1.9, 0.3})
    if goldstar_texture_ok {
      spawn(
        app,
        parent = psys_handle1,
        attachment = render.emitter_attachment(
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
        ),
      )
    }
    psys_handle2 := world.spawn(&app.scene, {2.0, 1.9, 0.3})
    if black_circle_ok {
      spawn(
        app,
        parent = psys_handle2,
        attachment = render.emitter_attachment(
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
        ),
      )
    }
    forcefield_root_handle := world.spawn(&app.scene, {0, 4, 0})
    add_node_clip(app, forcefield_root_handle, spin_clip("forcefield_rotation", 8, {0, math.PI * 0.5, math.PI, math.PI * 1.5, math.PI * 2}, .LINEAR))
    forcefield_handle := world.spawn_child(
      &app.scene,
      forcefield_root_handle,
    )
    world.translate(&app.scene, forcefield_handle, 3.0, 0.0, 0.0)
    render.attach(&app.renderer, forcefield_handle.index, render.forcefield_attachment(
      tangent_strength = 2.0,
      strength = 20.0,
      area_of_effect = 5.0,
    ))
    handle := spawn(
      app,
      parent = forcefield_handle,
      attachment = render.MeshAttachment {
        handle = sphere_mesh_handle,
        material = goldstar_material_handle,
        cast_shadow = false,
      },
    )
    world.scale(&app.scene, handle, 0.2)
  }
  when false {
    render.debug_sphere(&app.renderer, {0, 5, 0}, 5, render.DEBUG_WHITE, life = 5)
    render.debug_cube(&app.renderer, {2, 3, 0}, size = {1, 1, 1}, color = render.DEBUG_CYAN, life = 5)
    render.debug_arrow(&app.renderer, {0, 0, 0}, {3, 3, 0}, render.DEBUG_YELLOW, life = 5)
    render.debug_axes(&app.renderer, {0, 0, 0}, scale = 2)
  }
  // append(&app.renderer.effect_stack, render.FogEffect{color = {0.4, 0.0, 0.8}, density = 0.02, start = 5.0, end = 20.0})
  // append(&app.renderer.effect_stack, render.BloomEffect{threshold = 0.2, intensity = 1.0, blur_radius = 4.0})
  append(&app.renderer.effect_stack, render.CrossHatchEffect{hatch_offset_y = 1.0, lum_thresholds = {0.6, 0.3, 0.15, 0.07}})
  // append(&app.renderer.effect_stack, render.BlurEffect{radius = 18.0, weight_falloff = 1.0})
  // append(&app.renderer.effect_stack, render.ToneMapEffect{exposure = 1.5, gamma = 1.3})
  // append(&app.renderer.effect_stack, render.DoFEffect{focus_distance = 3.0, focus_range = 2.0, blur_strength = 20.0, bokeh_intensity = 0.5})
  // append(&app.renderer.effect_stack, render.GrayscaleEffect{strength = 0.9})
  append(&app.renderer.effect_stack, render.OutlineEffect{thickness = 0.8, color = {0.0, 0.0, 0.01}})
  when true {
    portal_camera_handle = render.create_camera(
      &app.renderer,
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
      &app.renderer,
    )
    portal_quad_handle := app.renderer.builtin_meshes[render.Primitive.QUAD_XY]
    portal_mesh_ok := true
    if portal_material_ok && portal_mesh_ok {
      handle := spawn(
        app,
        {0, 0, 0},
        attachment = render.MeshAttachment {
          handle = portal_quad_handle,
          material = portal_material_handle,
          cast_shadow = false,
        },
      )
      world.translate(&app.scene, handle, 0, 3, -5)
      world.scale(&app.scene, handle, 2.0)
    }
  }
  when true {
    log.info(
      "spawning Warrior effect sprite with animation (99 frames @ 24fps)...",
    )
    warrior_sprite_texture, warrior_sprite_ok := render.create_texture_from_path(&app.renderer, "assets/Warrior_Sheet-Effect.png",
    )
    if warrior_sprite_ok {
      // 6x17 sprite sheet using frames 0-98, animated in update
      sprite_material, sprite_ok := render.material_sprite(
        &app.renderer,
        warrior_sprite_texture,
        frame_columns = 6,
        frame_rows = 17,
      )
      warrior_sprite = sprite_material
      if sprite_ok {
        sprite_attachment := render.MeshAttachment {
          handle   = app.renderer.builtin_meshes[.QUAD_XY],
          material = sprite_material,
        }
        handle, spawn_ok := spawn(app, {4, 1.5, 0}, sprite_attachment)
        if spawn_ok {
          world.scale(&app.scene, handle, 3.0)
        }
      }
    }
  }
  log.info("setup complete")
}

on_key :: proc(app: ^App, key: input.Key, pressed: bool) {
  log.infof("key %v %v", key, "PRESS" if pressed else "RELEASE")
  if !pressed do return
  if key == .TAB {
    app.free_cam = !app.free_cam
  }
}

on_post_render :: proc(app: ^App) {
  if material, ok := render.material(&app.renderer, portal_material_handle);
     ok {
    material.albedo_index = render.camera_attachment(&app.renderer, portal_camera_handle, .FINAL_IMAGE)
  }
}

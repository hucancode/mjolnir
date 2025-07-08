package main

import "core:fmt"
import "core:log"
import "core:math"
import linalg "core:math/linalg"
import "mjolnir"
import "mjolnir/geometry"
import "mjolnir/resource"
import glfw "vendor:glfw"
import mu "vendor:microui"

LIGHT_COUNT :: 10
light_handles: [LIGHT_COUNT]mjolnir.Handle
light_cube_handles: [LIGHT_COUNT]mjolnir.Handle
ground_mat_handle: mjolnir.Handle
hammer_handle: mjolnir.Handle
engine: mjolnir.Engine
forcefield_handle: mjolnir.Handle
forcefield_node: ^mjolnir.Node

main :: proc() {
  context.logger = log.create_console_logger()
  engine.setup_proc = setup
  engine.update_proc = update
  engine.render2d_proc = render_2d
  engine.key_press_proc = on_key_pressed
  mjolnir.run(&engine, 1280, 720, "Mjolnir Odin")
}

setup :: proc(engine: ^mjolnir.Engine) {
  using mjolnir, geometry
  plain_material_handle, _, _ := create_material()
  wireframe_material_handle, _, _ := create_wireframe_material()
  cube_geom := make_cube()
  cube_mesh_handle, _, _ := create_mesh(cube_geom)
  sphere_mesh_handle, _, _ := create_mesh(make_sphere())
  // Create ground plane
  ground_albedo_handle, _, _ := create_texture_from_path(
    "assets/t_brick_floor_002_diffuse_1k.jpg",
  )
  ground_mat_handle, _, _ = create_material(
    {.ALBEDO_TEXTURE},
    ground_albedo_handle,
  )
  ground_mesh_handle, _, _ := create_mesh(make_quad())
  if true {
    log.info("spawning cubes in a grid")
    space: f32 = 1.0
    size: f32 = 0.3
    nx, ny, nz := 5, 2, 5
    for x in 1 ..< nx {
      for y in 1 ..< ny {
        for z in 1 ..< nz {
          mat_handle, _ := create_material(
            metallic_value = f32(x - 1) / f32(nx - 1),
            roughness_value = f32(z - 1) / f32(nz - 1),
          ) or_continue
          _, node := spawn(
            &engine.scene,
            MeshAttachment {
              handle = sphere_mesh_handle,
              material = mat_handle,
              cast_shadow = true,
            },
          )
          translate(
            &node.transform,
            (f32(x) - f32(nx) * 0.5) * space,
            (f32(y) - f32(ny) * 0.5) * space + 0.5,
            (f32(z) - f32(nz) * 0.5) * space,
          )
          scale(&node.transform, size)
        }
      }
    }
  }
  if true {
    log.info("spawning ground quad and walls")
    // Ground node
    size: f32 = 15.0
    _, ground_node := spawn(
      &engine.scene,
      MeshAttachment {
        handle = ground_mesh_handle,
        material = ground_mat_handle,
      },
    )
    translate(&ground_node.transform, x = -0.5 * size, z = -0.5 * size)
    scale(&ground_node.transform, size)

    // Left wall
    _, left_wall := spawn(
      &engine.scene,
      MeshAttachment {
        handle = ground_mesh_handle,
        material = ground_mat_handle,
      },
    )
    translate(&left_wall.transform, x = size * 0.5, y = 0, z = -0.5 * size)
    rotate(&left_wall.transform, math.PI * 0.5, linalg.VECTOR3F32_Z_AXIS)
    scale(&left_wall.transform, size)

    // Right wall
    _, right_wall := spawn(
      &engine.scene,
      MeshAttachment {
        handle = ground_mesh_handle,
        material = ground_mat_handle,
      },
    )
    translate(
      &right_wall.transform,
      x = -size * 0.5,
      y = size * 1.0,
      z = -0.5 * size,
    )
    rotate(&right_wall.transform, -math.PI * 0.5, linalg.VECTOR3F32_Z_AXIS)
    scale(&right_wall.transform, size)

    // Back wall
    _, back_wall := spawn(
      &engine.scene,
      MeshAttachment {
        handle = ground_mesh_handle,
        material = ground_mat_handle,
      },
    )
    translate(
      &back_wall.transform,
      x = -0.5 * size,
      y = size * 1.0,
      z = -size * 0.5,
    )
    rotate(&back_wall.transform, math.PI * 0.5, linalg.VECTOR3F32_X_AXIS)
    scale(&back_wall.transform, size)

    // Ceiling
    _, ceiling := spawn(
      &engine.scene,
      MeshAttachment {
        handle = ground_mesh_handle,
        material = ground_mat_handle,
      },
    )
    translate(&ceiling.transform, x = -0.5 * size, y = size, z = 0.5 * size)
    rotate(&ceiling.transform, -math.PI, linalg.VECTOR3F32_X_AXIS)
    scale(&ceiling.transform, size)
  }
  if true {
    log.info("loading GLTF...")
    gltf_nodes := load_gltf(engine, "assets/Mjolnir.glb") or_else {}
    log.infof("Loaded GLTF nodes: %v", gltf_nodes)
    for handle in gltf_nodes {
      hammer_handle = handle
      node := resource.get(engine.scene.nodes, handle) or_continue
      translate(&node.transform, 0, 2, -2)
      scale(&node.transform, 0.2)
    }
  }
  if true {
    log.info("loading GLTF...")
    gltf_nodes := load_gltf(engine, "assets/DamagedHelmet.glb") or_else {}
    log.infof("Loaded GLTF nodes: %v", gltf_nodes)
    for handle in gltf_nodes {
      helm := resource.get(engine.scene.nodes, handle) or_continue
      translate(&helm.transform, 0, 1, 2)
      scale(&helm.transform, 0.5)
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
    }
  }
  log.infof("creating %d lights", LIGHT_COUNT)
  // Create lights and light cubes
  for i in 0 ..< LIGHT_COUNT {
    color := linalg.Vector4f32 {
      math.sin(f32(i)),
      math.cos(f32(i)),
      math.sin(f32(i)),
      1.0,
    }
    light: ^Node
    should_make_spot_light := false
    should_make_spot_light = i % 2 != 0
    // should_make_spot_light = true
    if should_make_spot_light {
      light_handles[i], light = spawn(
        &engine.scene,
        SpotLightAttachment {
          color = color,
          angle = math.PI * 0.3,
          radius = 5,
          cast_shadow = true,
        },
      )
      rotate(&light.transform, math.PI * 0.2, linalg.VECTOR3F32_X_AXIS)
    } else {
      light_handles[i], light = spawn(
        &engine.scene,
        PointLightAttachment{color = color, radius = 5, cast_shadow = true},
      )
    }
    translate(&light.transform, 0, 3, -1)
    cube_node: ^Node
    light_cube_handles[i], cube_node = spawn_child(
      &engine.scene,
      light_handles[i],
      MeshAttachment {
        handle = cube_mesh_handle,
        material = plain_material_handle,
      },
    )
    translate(&cube_node.transform, 0, 0.3, 0)
    scale(&cube_node.transform, 0.1)
  }
  spawn(
    &engine.scene,
    DirectionalLightAttachment {
      color = {0.3, 0.3, 0.3, 1.0},
      cast_shadow = true,
    },
  )

  if false {
    // effect_add_bloom(&engine.postprocess, 0.8, 0.5, 16.0)
    // Create a bright white ball to test bloom effect
    bright_material_handle, _, _ := create_material(emissive_value = 30.0)
    _, bright_ball_node := spawn(
      &engine.scene,
      MeshAttachment {
        handle      = sphere_mesh_handle,
        material    = bright_material_handle,
        cast_shadow = false, // Emissive objects don't need shadows
      },
    )
    translate(&bright_ball_node.transform, x = 1.0) // Position it above the ground
    scale(&bright_ball_node.transform, 0.2) // Make it a reasonable size
  }

  if true {
    // Create particle system 1 with gold star texture
    particle_texture1_handle, _, _ := mjolnir.create_texture_from_path(
      "assets/gold-star.png",
    )
    // Create particle system 2 with black circle texture
    particle_texture2_handle, _, _ := mjolnir.create_texture_from_path(
      "assets/black-circle.png",
    )
    psys_handle1, _ := spawn_at(
      &engine.scene,
      {-2.0, 1.9, 0.3},
      mjolnir.ParticleSystemAttachment {
        bounding_box = geometry.Aabb{min = {-1, -1, -1}, max = {1, 1, 1}},
        texture_handle = particle_texture1_handle,
      },
    )
    spawn_child(
      &engine.scene,
      psys_handle1,
      EmitterAttachment {
        emission_rate     = 7,
        particle_lifetime = 5.0,
        position_spread   = 1.5,
        initial_velocity  = {0, -0.1, 0, 0},
        velocity_spread   = 0.1,
        color_start       = {1, 1, 0, 1}, // Yellow particles
        color_end         = {1, 0.5, 0, 0},
        size_start        = 200.0,
        size_end          = 100.0,
        weight            = 0.1,
        weight_spread     = 0.05,
        texture_handle    = particle_texture1_handle,
        enabled           = true,
      },
    )

    psys_handle2, _ := spawn_at(
      &engine.scene,
      {2.0, 1.9, 0.3},
      mjolnir.ParticleSystemAttachment {
        bounding_box = geometry.Aabb{min = {-1, -1, -1}, max = {1, 1, 1}},
        texture_handle = particle_texture2_handle,
      },
    )

    // Create an emitter for the second particle system
    spawn_child(
      &engine.scene,
      psys_handle2,
      EmitterAttachment {
        emission_rate     = 7,
        particle_lifetime = 3.0,
        position_spread   = 0.3,
        initial_velocity  = {0, 0.2, 0, 0},
        velocity_spread   = 0.15,
        color_start       = {0, 0, 1, 1}, // Blue particles
        color_end         = {0, 1, 1, 0},
        size_start        = 350.0,
        size_end          = 175.0,
        weight            = 0.1,
        weight_spread     = 0.3,
        texture_handle    = particle_texture2_handle,
        enabled           = true,
      },
    )
    // Create a force field that affects both particle systems
    forcefield_handle, forcefield_node = spawn_child(
      &engine.scene,
      psys_handle1, // Attach to first particle system
      mjolnir.ForceFieldAttachment {
        tangent_strength = 2.0,
        strength = 20.0,
        area_of_effect = 5.0,
      },
    )
    geometry.translate(&forcefield_node.transform, x = 5.0, y = 4.0, z = 0.0)
    _, forcefield_visual := spawn_child(
      &engine.scene,
      forcefield_handle,
      MeshAttachment {
        handle = sphere_mesh_handle,
        material = wireframe_material_handle,
        cast_shadow = false,
      },
    )
    geometry.scale(&forcefield_visual.transform, 0.2)
  }
  effect_add_tonemap(&engine.postprocess, 1.5, 1.3)
  effect_add_fog(&engine.postprocess, {0.2, 0.5, 0.9}, 0.02, 50.0, 200.0)
  effect_add_crosshatch(&engine.postprocess, {1280, 720}) // Add cross-hatch effect
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
}

update :: proc(engine: ^mjolnir.Engine, delta_time: f32) {
  using mjolnir, geometry
  t := time_since_app_start(engine) * 0.5
  if forcefield_node != nil {
    geometry.translate(
      &forcefield_node.transform,
      math.cos(t) * 2.0,
      2.0,
      math.sin(t) * 2.0,
    )
  }
  // Animate lights
  for handle, i in light_handles {
    if i == 0 {
      // manual control light #0
      continue
    }
    offset := f32(i) / f32(LIGHT_COUNT) * math.PI * 2.0
    t := time_since_app_start(engine) + offset
    // log.infof("getting light %d %v", i, light_handles[i])
    light_ptr := resource.get(engine.scene.nodes, handle)
    rx := math.sin(t)
    ry := (math.sin(t) + 1.0) * 0.5 * 1.5 + 1.0
    rz := math.cos(t)
    v := linalg.vector_normalize(linalg.Vector3f32{rx, ry, rz})
    radius: f32 = 6
    v = v * radius + linalg.VECTOR3F32_Y_AXIS * -1.0
    translate(&light_ptr.transform, v.x, v.y, v.z)
    // log.infof("Light %d position: %v", i, light_ptr.transform.position)
    light_cube_ptr := resource.get(engine.scene.nodes, light_cube_handles[i])
    rotate(
      &light_cube_ptr.transform,
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

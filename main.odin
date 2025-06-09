package main

import "core:log"
import "core:math"
import linalg "core:math/linalg"
import mu "vendor:microui"

import "mjolnir"
import "mjolnir/geometry"
import "mjolnir/resource"
import glfw "vendor:glfw"

LIGHT_COUNT :: 3
light_handles: [LIGHT_COUNT]mjolnir.Handle
light_cube_handles: [LIGHT_COUNT]mjolnir.Handle

engine: mjolnir.Engine

main :: proc() {
  context.logger = log.create_console_logger()
  engine.setup_proc = setup
  engine.update_proc = update
  engine.key_press_proc = on_key_pressed
  mjolnir.run(&engine, 1280, 720, "Mjolnir Odin")
}

setup :: proc(engine: ^mjolnir.Engine) {
  using mjolnir, geometry
  plain_material_handle, _, _ := create_material(engine)
  cube_geom := make_cube()
  cube_mesh_handle, _, _ := create_mesh(engine, cube_geom)
  sphere_mesh_handle, _, _ := create_mesh(engine, make_sphere())
  // Create ground plane
  ground_albedo_handle, _, _ := create_texture_from_path(
    engine,
    "assets/t_brick_floor_002_diffuse_1k.jpg",
  )
  ground_metallic_roughness_handle, _, _ := create_texture_from_path(
    engine,
    "assets/t_brick_floor_002_rough_1k.jpg",
  )
  ground_mat_handle, _, _ := create_material(
    engine,
    {.ALBEDO_TEXTURE},
    ground_albedo_handle,
  )
  ground_mesh_handle, _, _ := create_mesh(engine, make_quad())
  if true {
    log.info("spawning cubes in a grid")
    space: f32 = 1.0
    size: f32 = 0.3
    nx, ny, nz := 5, 2, 5
    for x in 1 ..< nx {
      for y in 1 ..< ny {
        for z in 1 ..< nz {
          mat_handle, _ := create_material(
            engine = engine,
            metallic_value = f32(x) / f32(nx),
            roughness_value = f32(y) / f32(ny),
          ) or_continue
          node_handle, node := spawn(
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
    log.info("spawning ground quad")
    // Ground node
    size: f32 = 15.0
    ground_handle, ground_node := spawn(
      &engine.scene,
      MeshAttachment {
        handle = ground_mesh_handle,
        material = ground_mat_handle,
      },
    )
    translate(&ground_node.transform, x = -0.5 * size, z = -0.5 * size)
    scale(&ground_node.transform, size)
  }
  if false {
    log.info("loading GLTF...")
    gltf_nodes := load_gltf(engine, "assets/Suzanne.glb") or_else {}
    log.infof("Loaded GLTF nodes: %v", gltf_nodes)
    for handle in gltf_nodes {
      duck, found := resource.get(engine.scene.nodes, handle)
      if !found {
        continue
      }
      translate(&duck.transform, 0, 2, -2)
    }
  }
  if true {
    log.info("loading GLTF...")
    gltf_nodes := load_gltf(engine, "assets/DamagedHelmet.glb") or_else {}
    log.infof("Loaded GLTF nodes: %v", gltf_nodes)
    for handle in gltf_nodes {
      helm, found := resource.get(engine.scene.nodes, handle)
      if !found {
        continue
      }
      translate(&helm.transform, 0, 1, 2)
      scale(&helm.transform, 0.5)
    }
  }
  if true {
    log.info("loading GLTF...")
    gltf_nodes := load_gltf(engine, "assets/Warrior.glb") or_else {}
    log.infof("Loaded GLTF nodes: %v", gltf_nodes)
    for armature in gltf_nodes {
      armature_ptr := resource.get(engine.scene.nodes, armature)
      if armature_ptr == nil || len(armature_ptr.children) == 0 {
        continue
      }
      for i in 1 ..< len(armature_ptr.children) {
        skeleton := armature_ptr.children[i]
        skeleton_ptr := resource.get(engine.scene.nodes, skeleton)
        if skeleton_ptr == nil {
          continue
        }
        // skeleton_ptr.transform.scale = {0.5, 0.5, 0.5}
        play_animation(engine, skeleton, "idle")
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
      spot_angle := math.PI / 1.2
      light_handles[i], light = spawn(
        &engine.scene,
        SpotLightAttachment {
          color = color,
          angle = f32(spot_angle),
          radius = 4,
          cast_shadow = true,
        },
      )
    } else {
      light_handles[i], light = spawn(
        &engine.scene,
        PointLightAttachment{color = color, radius = 20, cast_shadow = true},
      )
    }
    translate(&light.transform, 0, 3, -1)
    rotate(&light.transform, math.PI * 0.45, linalg.VECTOR3F32_X_AXIS)
    cube_node: ^Node
    light_cube_handles[i], cube_node = spawn_child(
      &engine.scene,
      light_handles[i],
      MeshAttachment {
        handle = cube_mesh_handle,
        material = plain_material_handle,
      },
    )
    scale(&cube_node.transform, 0.1)
  }
  spawn(
    &engine.scene,
    DirectionalLightAttachment {
      color = {0.3, 0.3, 0.3, 1.0},
      cast_shadow = true,
    },
  )
  renderer_tonemap(&engine.renderer, 1.5, 1.3)
  renderer_grayscale(&engine.renderer, 0.3)
  emitter := mjolnir.Emitter{
      transform = geometry.Transform{
          position = {0, 3, 3},
          rotation = linalg.QUATERNIONF32_IDENTITY,
          scale = {1, 1, 1},
      },
      emission_rate = 10,
      particle_lifetime = 5.0,
      initial_velocity = {0, -0.1, 0, 0},
      velocity_spread = 0.5,
      color_start = {1, 0, 0, 1},
      color_end = {0, 0, 1, 0},
      size_start = 300.0,
      size_end = 100.0,
      enabled = true,
  }
  add_emitter(&engine.renderer.particle.pipeline_comp, emitter)
}

update :: proc(engine: ^mjolnir.Engine, delta_time: f32) {
  using mjolnir, geometry
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

package main

import "core:fmt"
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
  engine.setup_proc = setup
  engine.update_proc = update
  engine.key_press_proc = on_key_pressed
  mjolnir.run(&engine, 1280, 720, "Mjolnir Odin")
}

setup :: proc(engine: ^mjolnir.Engine) {
  using mjolnir, geometry
  plain_material_handle, _, _ := create_material(engine)
  cube_geom := make_cube()
  cube_mesh_handle, _, _ := create_mesh(
    engine,
    cube_geom,
    plain_material_handle,
  )
  sphere_mesh_handle, _, _ := create_mesh(
    engine,
    make_sphere(),
    plain_material_handle,
  )
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
  ground_mesh_handle, _, _ := create_mesh(
    engine,
    make_quad(),
    ground_mat_handle,
  )
  if true {
    // Spawn cubes in a grid
    space: f32 = 1.0
    size: f32 = 0.3
    nx, ny, nz := 5, 2, 5
    for x in 1 ..< nx {
      for y in 1 ..< ny {
        for z in 1 ..< nz {
          node_handle, node := spawn(
            &engine.scene,
            MeshAttachment{handle = sphere_mesh_handle, cast_shadow = true},
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
    // Ground node
    size: f32 = 10.0
    ground_handle, ground_node := spawn(
      &engine.scene,
      MeshAttachment{handle = ground_mesh_handle},
    )
    translate(&ground_node.transform, x = -0.5 * size, z = -0.5 * size)
    scale(&ground_node.transform, size)
  }
  if true {
    gltf_nodes := load_gltf(engine, "assets/Suzanne.glb") or_else {}
    fmt.printfln("Loaded GLTF nodes: %v", gltf_nodes)
    for handle in gltf_nodes {
      duck := resource.get(engine.scene.nodes, handle)
      if duck == nil {
        continue
      }
      translate(&duck.transform, 0, 2, -2)
    }
  }
  if true {
    gltf_nodes := load_gltf(engine, "assets/DamagedHelmet.glb") or_else {}
    fmt.printfln("Loaded GLTF nodes: %v", gltf_nodes)
    for handle in gltf_nodes {
      helm := resource.get(engine.scene.nodes, handle)
      if helm == nil {
        continue
      }
      translate(&helm.transform, 0, 1, 2)
      scale(&helm.transform, 0.5)
    }
  }
  if true {
    gltf_nodes := load_gltf(engine, "assets/Warrior.glb") or_else {}
    fmt.printfln("Loaded GLTF nodes: %v", gltf_nodes)
    for armature in gltf_nodes {
      armature_ptr := resource.get(engine.scene.nodes, armature)
      if armature_ptr == nil || len(armature_ptr.children) == 0 {
        continue
      }
      skeleton := armature_ptr.children[len(armature_ptr.children) - 1]
      skeleton_ptr := resource.get(engine.scene.nodes, skeleton)
      if skeleton_ptr == nil {
        continue
      }
      // skeleton_ptr.transform.scale = {0.5, 0.5, 0.5}
      play_animation(engine, skeleton, "idle")
    }
  }

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
    translate(&light.transform, 0, 2, -2)
    rotate_angle(&light.transform, math.PI * 0.45, linalg.VECTOR3F32_X_AXIS)
    cube_node: ^Node
    light_cube_handles[i], cube_node = spawn_child(
      &engine.scene,
      light_handles[i],
      MeshAttachment{handle = cube_mesh_handle},
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
    // fmt.printfln("getting light %d %v", i, light_handles[i])
    light_ptr := resource.get(engine.scene.nodes, handle)
    if light_ptr == nil {
      continue
    }
    rx := math.sin(t)
    ry := (math.sin(t) + 1.0) * 0.5 * 1.5 + 1.0
    rz := math.cos(t)
    v := linalg.vector_normalize(linalg.Vector3f32{rx, ry, rz})
    radius: f32 = 4
    v = v * radius + linalg.VECTOR3F32_Y_AXIS * -1.0
    translate(&light_ptr.transform, v.x, v.y, v.z)
    // fmt.printfln("Light %d position: %v", i, light_ptr.transform.position)
    light_cube_ptr := resource.get(engine.scene.nodes, light_cube_handles[i])
    if light_cube_ptr == nil {
      continue
    }
    rotate_angle(
      &light_cube_ptr.transform,
      math.PI * time_since_app_start(engine) * 0.5,
    )
    // fmt.printfln( "Light cube %d rotation: %v", i, light_cube_ptr.transform.rotation,)
  }
}

on_key_pressed :: proc(engine: ^mjolnir.Engine, key, action, mods: int) {
  using mjolnir, geometry
  fmt.printfln("key pressed key %d action %d mods %x", key, action, mods)
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

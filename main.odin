package main

import "core:fmt"
import "core:math"
import linalg "core:math/linalg"
import mu "vendor:microui"

import "mjolnir"
import "mjolnir/geometry"
import "mjolnir/resource"
import glfw "vendor:glfw"

WIDTH :: 1280
HEIGHT :: 720
TITLE :: "Mjolnir Odin"
LIGHT_COUNT :: 3
light_handles: [LIGHT_COUNT]mjolnir.Handle
light_cube_handles: [LIGHT_COUNT]mjolnir.Handle

engine: mjolnir.Engine

main :: proc() {
  engine.setup_proc = setup
  engine.update_proc = update
  engine.key_press_proc = on_key_pressed
  defer mjolnir.deinit(&engine)
  if mjolnir.init(&engine, WIDTH, HEIGHT, TITLE) != .SUCCESS {
    fmt.eprintf("Failed to initialize engine\n")
    return
  }
  mjolnir.run(&engine)
}

setup :: proc(engine: ^mjolnir.Engine) {
    using mjolnir
    // Load texture and create material
    tex_handle, texture, _ := create_texture_from_path(
      engine,
      "assets/statue-1275469_1280.jpg",
    )
    fmt.printfln("Loaded texture: %v", texture)
    mat_handle, _, _ := create_material_untextured(
      engine,
      SHADER_FEATURE_LIT | SHADER_FEATURE_RECEIVE_SHADOW,
    )
    // Create mesh
    cube_geom := geometry.make_cube()
    cube_mesh_handle := create_static_mesh(engine, &cube_geom, mat_handle)
    sphere_geom := geometry.make_sphere()
    sphere_mesh_handle := create_static_mesh(engine, &sphere_geom, mat_handle)

    // Create ground plane
    ground_mat_handle, _, _ := create_material_textured(
      engine,
      SHADER_FEATURE_LIT | SHADER_FEATURE_RECEIVE_SHADOW,
      tex_handle,
      tex_handle,
      tex_handle,
    )
    quad_geom := geometry.make_quad()
    ground_mesh_handle := create_static_mesh(
      engine,
      &quad_geom,
      ground_mat_handle,
    )
    if true {
      // Spawn cubes in a grid
      space :f32 = 1.0
      size :f32 = 0.3
      nx, ny, nz := 5, 2, 5
      for x in 1 ..< nx {
        for y in 1 ..< ny {
          for z in 1 ..< nz {
            if x == nx / 2 && y == ny / 2 && z == nz / 2 {
              continue
            }
            node_handle, node := spawn_node(engine)
            attach(&engine.nodes, engine.scene.root, node_handle)
            node.attachment = NodeStaticMeshAttachment{sphere_mesh_handle, true}
            node.transform.position = {
              (f32(x) - f32(nx) * 0.5),
              (f32(y) - f32(ny) * 0.5),
              (f32(z) - f32(nz) * 0.5),
            } * space
            node.transform.position.y += 0.5
            node.transform.scale = {1, 1, 1} * size
          }
        }
      }
    }
    if true {
      // Ground node
      size :f32 = 40.0
      ground_handle, ground_node := spawn_node(engine)
      attach(&engine.nodes, engine.scene.root, ground_handle)
      ground_node.attachment = NodeStaticMeshAttachment{ground_mesh_handle, false}
      ground_node.transform.position = {-0.5, 0.0, -0.5} * size
      ground_node.transform.scale = {1.0, 1.0, 1.0} * size
    }
    if true {
      // Load GLTF and play animation
      gltf_nodes, _ := load_gltf(engine, "assets/CesiumMan.glb")
      fmt.printfln("Loaded GLTF nodes: %v", gltf_nodes)
      for armature in gltf_nodes {
        armature_ptr := resource.get(&engine.nodes, armature)
        if armature_ptr == nil || len(armature_ptr.children) == 0 {
          continue
        }
        skeleton := armature_ptr.children[len(armature_ptr.children) - 1]
        skeleton_ptr := resource.get(&engine.nodes, skeleton)
        if skeleton_ptr == nil {
          continue
        }
        // skeleton_ptr.transform.position = {2.0, 0.0, 0.0}
        play_animation(engine, skeleton, "Anim_0", .Loop)
        attachment, ok := skeleton_ptr.attachment.(NodeSkeletalMeshAttachment)
        if ok {
          attachment.cast_shadow = true
          pose := attachment.pose
          for i in 0 ..< min(4, len(pose.bone_matrices)) {
            fmt.printfln("Bone %d matrix: %v", i, pose.bone_matrices[i])
          }
        }
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
      should_make_spot_light = i%2 != 0
      // should_make_spot_light = true
      if should_make_spot_light {
        spot_angle := math.PI / 1.2
        light_handles[i], light = spawn_spot_light(
          engine,
          color,
          f32(spot_angle),
          4.0,
        )
      } else {
        light_handles[i], light = spawn_point_light(engine, color, 20.0)
      }
      light.transform.position = {0, 2, -2}
      light.transform.rotation = linalg.quaternion_angle_axis(
        math.PI * 0.45,
        linalg.VECTOR3F32_X_AXIS,
      )
      light_cube_handle, light_cube_node := spawn_node(engine)
      light_cube_handles[i] = light_cube_handle
      attach(&engine.nodes, light_handles[i], light_cube_handles[i])
      light_cube_node.attachment = NodeStaticMeshAttachment{cube_mesh_handle, false}
      light_cube_node.transform.scale = {0.1, 0.1, 0.1}
    }
    // Directional light
    spawn_directional_light(engine, {0.3, 0.3, 0.3, 0.0})
}

update :: proc(engine: ^mjolnir.Engine, delta_time: f32) {
  using mjolnir

  // Animate lights
  for handle, i in light_handles {
    if i == 0 {
      // manual control light #0
      continue
    }
    offset := f32(i) / f32(LIGHT_COUNT) * math.PI * 2.0
    t := time_since_app_start(engine) + offset
    // fmt.printfln("getting light %d %v", i, light_handles[i])
    light_ptr := resource.get(&engine.nodes, handle)
    if light_ptr == nil {continue}
    rx := math.sin(t)
    ry := (math.sin(t) + 1.0) * 0.5*1.5 + 1.0
    rz := math.cos(t)
    v := linalg.vector_normalize(linalg.Vector3f32{rx, ry, rz})
    radius: f32 = 4
    light_ptr.transform.position = v * radius + linalg.VECTOR3F32_Y_AXIS * -1.0
    // fmt.printfln("Light %d position: %v", i, light_ptr.transform.position)
    light_ptr.transform.is_dirty = true
    light_cube_ptr := resource.get(&engine.nodes, light_cube_handles[i])
    if light_cube_ptr == nil {
      continue
    }
    light_cube_ptr.transform.rotation = linalg.quaternion_angle_axis(
      math.PI * time_since_app_start(engine) * 0.5,
      linalg.VECTOR3F32_Y_AXIS,
    )
    light_cube_ptr.transform.is_dirty = true
    // fmt.printfln( "Light cube %d rotation: %v", i, light_cube_ptr.transform.rotation,)
  }
}

on_key_pressed :: proc(engine: ^mjolnir.Engine, key, action, mods: int) {
    fmt.printfln("key pressed key %d action %d mods %x", key, action, mods)
    if key == glfw.KEY_LEFT && action == glfw.PRESS {
      light := resource.get(&engine.nodes, light_handles[0])
      light.transform.position.x += 0.1
      light.transform.is_dirty = true
    } else if key == glfw.KEY_RIGHT && action == glfw.PRESS {
      light := resource.get(&engine.nodes, light_handles[0])
      light.transform.position.x -= 0.1
      light.transform.is_dirty = true
    } else if key == glfw.KEY_UP && action == glfw.PRESS {
      light := resource.get(&engine.nodes, light_handles[0])
      light.transform.position.z += 0.1
      light.transform.is_dirty = true
    } else if key == glfw.KEY_DOWN && action == glfw.PRESS {
      light := resource.get(&engine.nodes, light_handles[0])
      light.transform.position.z -= 0.1
      light.transform.is_dirty = true
    } else if key == glfw.KEY_Z && action == glfw.PRESS {
      light := resource.get(&engine.nodes, light_handles[0])
      light.transform.position.y += 0.1
      light.transform.is_dirty = true
    } else if key == glfw.KEY_X && action == glfw.PRESS {
      light := resource.get(&engine.nodes, light_handles[0])
      light.transform.position.y -= 0.1
      light.transform.is_dirty = true
    }
}

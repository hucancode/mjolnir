package main

import "core:fmt"
import "core:math"
import linalg "core:math/linalg"
import mu "vendor:microui"

import "mjolnir"
import "mjolnir/geometry"
import "mjolnir/resource"

WIDTH :: 1280
HEIGHT :: 720
TITLE :: "Mjolnir Odin"
LIGHT_COUNT :: 5
light_handles: [LIGHT_COUNT]mjolnir.Handle
light_cube_handles: [LIGHT_COUNT]mjolnir.Handle

engine: mjolnir.Engine

main :: proc() {
  using mjolnir
  engine.setup_proc = setup
  engine.update_proc = update
  engine.render2d_proc = render2d
  engine.render3d_proc = render3d
  g_context = context
  defer engine_deinit(&engine)
  if engine_init(&engine, WIDTH, HEIGHT, TITLE) != .SUCCESS {
    fmt.eprintf("Failed to initialize engine\n")
    return
  }
  run(&engine)
}

setup :: proc(engine: ^mjolnir.Engine) {
    using mjolnir
    // Load texture and create material
    tex_handle, texture, _ := create_texture_from_path(
      engine,
      "assets/statue-1275469_1280.jpg",
    )
    mat_handle, _, _ := create_material_untextured(
      engine,
      SHADER_FEATURE_LIT | SHADER_FEATURE_RECEIVE_SHADOW,
    )
    // Create mesh
    cube_geom := geometry.cube()
    cube_mesh_handle := create_static_mesh(engine, &cube_geom, mat_handle)
    sphere_geom := geometry.sphere()
    sphere_mesh_handle := create_static_mesh(engine, &sphere_geom, mat_handle)

    // Create ground plane
    ground_mat_handle, _, _ := create_material_textured(
      engine,
      SHADER_FEATURE_LIT | SHADER_FEATURE_RECEIVE_SHADOW,
      tex_handle,
      tex_handle,
      tex_handle,
    )
    quad_geom := geometry.quad()
    ground_mesh_handle := create_static_mesh(
      engine,
      &quad_geom,
      ground_mat_handle,
    )
    if true {
      // Spawn cubes in a grid
      nx, ny, nz := 4, 4, 4
      for x in 0 ..< nx {
        for y in 0 ..< ny {
          for z in 0 ..< nz {
            if x == nx / 2 && y == ny / 2 && z == nz / 2 {
              continue
            }
            node_handle, node := spawn(engine)
            attach(&engine.nodes, engine.scene.root, node_handle)
            node.attachment = NodeStaticMeshAttachment{sphere_mesh_handle}
            node.transform.position = {
              (f32(x) - f32(nx) / 2.0) * 3.0,
              (f32(y) - f32(ny) / 2.0) * 3.0,
              (f32(z) - f32(nz) / 2.0) * 3.0,
            }
            node.transform.scale = {0.3, 0.3, 0.3}
          }
        }
      }
    }
    if true {
      // Ground node
      ground_handle, ground_node := spawn(engine)
      attach(&engine.nodes, engine.scene.root, ground_handle)
      ground_node.attachment = NodeStaticMeshAttachment{ground_mesh_handle}
      ground_node.transform.position = {-3.0, 0.0, -3.0}
      ground_node.transform.scale = {6.0, 1.0, 6.0}
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
        fmt.printfln("found skeleton:", skeleton_ptr)
        // skeleton_ptr.transform.position = {2.0, 0.0, 0.0}
        play_animation(engine, skeleton, "Anim_0", .Loop)
        attachment, ok := skeleton_ptr.attachment.(NodeSkeletalMeshAttachment)
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
      if i % 2 == 0 {
        spot_angle := math.PI / 4.0
        light_handles[i], light = spawn_spot_light(
          engine,
          color,
          f32(spot_angle),
          15.0,
        )
      } else {
        light_handles[i], light = spawn_point_light(engine, color, 15.0)
      }
      light.transform.rotation = linalg.quaternion_angle_axis(
        math.PI * 0.3,
        linalg.VECTOR3F32_X_AXIS,
      )
      light.transform.position = {0.0, 3.0, 0.0}
      light_cube_handle, light_cube_node := spawn(engine)
      light_cube_handles[i] = light_cube_handle
      attach(&engine.nodes, light_handles[i], light_cube_handles[i])
      light_cube_node.attachment = NodeStaticMeshAttachment{cube_mesh_handle}
      light_cube_node.transform.scale = {0.1, 0.1, 0.1}
      light_cube_node.transform.position = {0.0, 0.1, 0.0}
    }
    // Directional light
    spawn_directional_light(engine, {0.3, 0.3, 0.3, 0.0})
}

update :: proc(engine: ^mjolnir.Engine, delta_time: f32) {
  using mjolnir
  // Animate lights
  for i in 0 ..< LIGHT_COUNT {
    offset := f32(i) / f32(LIGHT_COUNT) * math.PI * 2.0
    t := time_since_start(engine) + offset
    // fmt.printfln("getting light %d %v", i, light_handles[i])
    light_ptr := resource.get(&engine.nodes, light_handles[i])
    if light_ptr == nil {continue}
    rx := math.sin(t)
    ry := (math.sin(t * 0.2) + 1.0) * 0.5 + 2.0
    rz := math.cos(t)
    v := linalg.vector_normalize(linalg.Vector3f32{rx, ry, rz})
    radius: f32 = 8.0
    light_ptr.transform.position =
      v * radius + linalg.Vector3f32{0.0, 2.0, 0.0}
    light_ptr.transform.position.y = 4.0
    // fmt.printfln("Light %d position: %v", i, light_ptr.transform.position)
    light_ptr.transform.is_dirty = true
    light_cube_ptr := resource.get(&engine.nodes, light_cube_handles[i])
    if light_cube_ptr == nil {
      continue
    }
    light_cube_ptr.transform.rotation = linalg.quaternion_angle_axis(
      math.PI * time_since_start(engine) * 0.5,
      linalg.VECTOR3F32_Y_AXIS,
    )
    light_cube_ptr.transform.is_dirty = true
    // fmt.printfln( "Light cube %d rotation: %v", i, light_cube_ptr.transform.rotation,)
  }
}

render2d :: proc(engine: ^mjolnir.Engine, ctx: ^mu.Context) {
    if mu.window(ctx, "User data", {40, 240, 300, 100}, {.NO_CLOSE}) {
        mu.label(ctx, fmt.tprintf("Spot lights %d", LIGHT_COUNT))
    }
}

render3d :: proc(engine: ^mjolnir.Engine) {
    mjolnir.draw_debug_grid(engine)
}

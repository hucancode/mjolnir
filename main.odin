package main

import "base:runtime"
import "core:fmt"
import "core:math"
import linalg "core:math/linalg"
import "core:mem"
import "core:os"
import "core:strings"
import glfw "vendor:glfw"

import "mjolnir"
import "mjolnir/geometry"
import "mjolnir/resource"

when ODIN_OS == .Darwin {
  // NOTE: just a bogus import of the system library,
  // needed so we can add a linker flag to point to /usr/local/lib (where vulkan is installed by default)
  // when trying to load vulkan.
  // Credit goes to : https://gist.github.com/laytan/ba57af3e5a59ab5cb2fca9e25bcfe262
  @(require, extra_linker_flags = "-rpath /usr/local/lib")
  foreign import __ "system:System.framework"
}
WIDTH :: 1280
HEIGHT :: 720
TITLE :: "Mjolnir Odin"
LIGHT_COUNT :: 5
light_handles: [LIGHT_COUNT]mjolnir.Handle
light_cube_handles: [LIGHT_COUNT]mjolnir.Handle

g_context: runtime.Context
engine: mjolnir.Engine

main :: proc() {
  using mjolnir
  g_context = context
  if init_engine(&engine, WIDTH, HEIGHT, TITLE) != .SUCCESS {
    fmt.eprintf("Failed to initialize engine\n")
    return
  }
  defer deinit_engine(&engine)

  // Load texture and create material
  tex_handle, texture, res := create_texture_from_path(
    &engine,
    "assets/statue-1275469_1280.jpg",
  )
  fmt.printfln("Loaded texture: %v", texture)
  mat_handle, _, _ := create_material(&engine, tex_handle, tex_handle, tex_handle)
  // Create mesh
  cube_geom := geometry.make_cube({1.0, 1.0, 1.0, 1.0})
  mesh_handle := create_static_mesh(&engine, &cube_geom, mat_handle)

  // Create ground plane
  ground_mat_handle, _, _ := create_material(
    &engine,
    tex_handle,
    tex_handle,
    tex_handle,
  )
  quad_geom := geometry.make_quad({1.0, 1.0, 1.0, 1.0})
  ground_mesh_handle := create_static_mesh(
    &engine,
    &quad_geom,
    ground_mat_handle,
  )
if true {
  // Spawn cubes in a grid
  nx, ny, nz := 10, 10, 10
  for x in 0 ..< nx {
    for y in 0 ..< ny {
      for z in 0 ..< nz {
        if x == nx / 2 && y == ny / 2 && z == nz / 2 {
          continue
        }
        node_handle, node := spawn_node(&engine)
        parent_node(&engine.nodes, engine.scene.root, node_handle)
        node.attachment = NodeStaticMeshAttachment{mesh_handle}
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
  ground_handle, ground_node := spawn_node(&engine)
  parent_node(&engine.nodes, engine.scene.root, ground_handle)
  ground_node.attachment = NodeStaticMeshAttachment{ground_mesh_handle}
  ground_node.transform.position = {-3.0, 0.0, -3.0}
  ground_node.transform.scale = {6.0, 1.0, 6.0}
}
if true {
  // Load GLTF and play animation
  gltf_nodes, _ := gltf_loader_submit(
    &GLTFLoader{
      engine_ptr = &engine,
      gltf_path = "assets/CesiumMan.glb"
    },
  )
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
    play_animation_engine(&engine, skeleton, "Anim_0", .Loop)
    attachment, ok := skeleton_ptr.attachment.(NodeSkeletalMeshAttachment)
    if ok {
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
    light : ^Node
    if i % 2 == 0 {
      spot_angle := math.PI / 4.0
      light_handles[i], light = spawn_spot_light(
        &engine,
        color,
        f32(spot_angle),
        15.0,
        true,
      )
      light.transform.rotation = linalg.quaternion_angle_axis_f32(
        math.PI * 0.5,
        linalg.VECTOR3F32_X_AXIS,
      )
      light.transform.position = {0.0, 3.0, 0.0}
    } else {
      light_handles[i], light = spawn_point_light(&engine, color, 15.0, true)
      light.transform.rotation = linalg.quaternion_angle_axis_f32(
        math.PI * 0.5,
        linalg.VECTOR3F32_X_AXIS,
      )
      light.transform.position = {0.0, 3.0, 0.0}
    }
    light_cube_handle, light_cube_node := spawn_node(&engine)
    light_cube_handles[i] = light_cube_handle
    parent_node(&engine.nodes, light_handles[i], light_cube_handles[i])
    light_cube_node.attachment = NodeStaticMeshAttachment{mesh_handle}
    light_cube_node.transform.scale = {0.1, 0.1, 0.1}
    light_cube_node.transform.position = {0.0, 0.1, 0.0}
  }

  // Directional light
  _, _ = spawn_directional_light(&engine, {0.3, 0.3, 0.3, 0.0}, true)

  // Mouse scroll callback for camera zoom
  glfw.SetScrollCallback(
    engine.window,
    proc "c" (window: glfw.WindowHandle, xoffset: f64, yoffset: f64) {
      context = g_context
      SCROLL_SENSITIVITY :: 0.5
      camera_orbit_zoom(
        &engine.scene.camera,
        -f32(yoffset) * SCROLL_SENSITIVITY,
      )
    },
  )

  // Main loop
  for !should_close_engine(&engine) {
    if update_engine(&engine) {
      update(&engine)
    }
    render_engine(&engine)
  }
}

_dragging: bool = false
_last_mouse_x: f64 = 0
_last_mouse_y: f64 = 0
update :: proc(engine: ^mjolnir.Engine) {
  using mjolnir
  // Camera orbit controls (mouse drag)
  movement, is_orbit := engine.scene.camera.movement_data.(CameraOrbitMovement)
  if is_orbit {
    mouse_x, mouse_y := glfw.GetCursorPos(engine.window)
    mouse_button := glfw.GetMouseButton(engine.window, glfw.MOUSE_BUTTON_1)
    MOUSE_SENSITIVITY_X :: 0.005
    MOUSE_SENSITIVITY_Y :: 0.005
    if mouse_button == glfw.PRESS {
      if !_dragging {
        _last_mouse_x = mouse_x
        _last_mouse_y = mouse_y
        _dragging = true
      }
      delta_x := f32(mouse_x - _last_mouse_x)
      delta_y := f32(mouse_y - _last_mouse_y)
      camera_orbit_rotate(
        &engine.scene.camera,
        delta_x * MOUSE_SENSITIVITY_X,
        delta_y * MOUSE_SENSITIVITY_Y,
      )
      _last_mouse_x = mouse_x
      _last_mouse_y = mouse_y
    } else {
      _dragging = false
    }
  }
  // Animate lights
  for i in 0 ..< LIGHT_COUNT {
    offset := f32(i) / f32(LIGHT_COUNT) * math.PI * 2.0
    t := get_time_engine(engine) + offset
    fmt.printfln("getting light %d %v", i, light_handles[i])
    light_ptr := resource.get(
      &engine.nodes,
      light_handles[i],
    )
    if light_ptr == nil {continue}
    rx := math.sin_f32(t)
    ry := (math.sin_f32(t * 0.2) + 1.0) * 0.5 + 2.0
    rz := math.cos_f32(t)
    v := linalg.vector_normalize(linalg.Vector3f32{rx, ry, rz})
    radius: f32 = 8.0
    light_ptr.transform.position = v * radius + linalg.Vector3f32{0.0, 2.0, 0.0}
    light_ptr.transform.position.y = 4.0
    fmt.printfln("Light %d position: %v", i, light_ptr.transform.position)
    light_ptr.transform.is_dirty = true
    light_cube_ptr := resource.get(
      &engine.nodes,
      light_cube_handles[i],
    )
    if light_cube_ptr == nil {
      continue
    }
    light_cube_ptr.transform.rotation = linalg.quaternion_angle_axis_f32(
      math.PI * get_time_engine(engine) * 0.5,
      linalg.VECTOR3F32_Y_AXIS,
    )
    light_cube_ptr.transform.is_dirty = true
    fmt.printfln("Light cube %d rotation: %v", i, light_cube_ptr.transform.rotation)
  }
}

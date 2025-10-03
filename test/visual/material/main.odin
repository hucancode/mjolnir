package main

import "core:log"
import "core:math"
import "core:math/linalg"
import "core:time"
import "vendor:glfw"
import "../../../mjolnir"
import "../../../mjolnir/geometry"
import "../../../mjolnir/resources"
import "../../../mjolnir/world"

MaterialSceneState :: struct {
  cube_handle: resources.Handle,
  run_seconds: f32,
  start_time:  time.Time,
}

state := MaterialSceneState{run_seconds = 4.0}

main :: proc() {
  engine := new(mjolnir.Engine)
  engine.setup_proc = setup_scene
  engine.update_proc = update_scene
  mjolnir.run(engine, 1280, 720, "visual-material-textured-cube")
}

setup_scene :: proc(engine: ^mjolnir.Engine) {
  state.start_time = time.now()
  camera := mjolnir.get_main_camera(engine)
  if camera != nil {
    geometry.camera_perspective(camera, math.PI * 0.3, 1280.0 / 720.0, 0.05, 100.0)
    geometry.camera_look_at(camera, {2.4, 1.8, 2.4}, {0.0, 0.0, 0.0})
  }

  cube_geom := geometry.make_cube()

  cube_mesh, mesh_ok := resources.create_mesh_handle(
    &engine.gpu_context,
    &engine.resource_manager,
    cube_geom,
  )
  if !mesh_ok {
    log.error("material textured cube: mesh creation failed")
    return
  }

  albedo_texture, texture_ok := resources.create_texture_from_data_handle(
    &engine.gpu_context,
    &engine.resource_manager,
    #load("statue-1275469_1280.jpg"),
    generate_mips = true,
  )
  if !texture_ok {
    log.error("material textured cube: texture load failed")
    return
  }

  material_handle, material_ok := resources.create_material_handle(
    &engine.resource_manager,
    {.ALBEDO_TEXTURE},
    type = resources.MaterialType.PBR,
    albedo_handle = albedo_texture,
    roughness_value = 0.35,
    metallic_value = 0.1,
  )
  if !material_ok {
    log.error("material textured cube: material creation failed")
    return
  }

  cube_handle, cube_node, spawned := world.spawn(
    &engine.world,
    world.MeshAttachment {
      handle      = cube_mesh,
      material    = material_handle,
      cast_shadow = true,
    },
    &engine.resource_manager,
  )
  if spawned {
    world.scale(cube_node, 0.75)
    state.cube_handle = cube_handle
  }

  light_handle, light_node, light_ok := world.spawn(&engine.world, nil, &engine.resource_manager)
  if light_ok {
    light_attachment, attach_ok := world.create_directional_light_attachment(
      light_handle,
      &engine.resource_manager,
      &engine.gpu_context,
      {1.0, 1.0, 1.0, 1.0},
      cast_shadow = false,
    )
    if attach_ok {
      light_node.attachment = light_attachment
      world.translate(light_node, 3.0, 5.0, 2.0)
      world.rotate(light_node, -math.PI * 0.35, linalg.VECTOR3F32_X_AXIS)
    }
  }
}

update_scene :: proc(engine: ^mjolnir.Engine, delta_time: f32) {
  if state.cube_handle.generation != 0 {
    rotation := delta_time * math.PI * 0.25
    world.node_handle_rotate_angle(
      &engine.world,
      state.cube_handle,
      rotation,
      linalg.VECTOR3F32_Y_AXIS,
    )
  }

  elapsed := f32(time.duration_seconds(time.since(state.start_time)))
  if elapsed >= state.run_seconds {
    glfw.SetWindowShouldClose(engine.window, true)
  }
}

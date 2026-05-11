package main

import "../../mjolnir"
import "../../mjolnir/world"
import "core:fmt"
import "core:log"
import "core:math"
import mu "vendor:microui"

spinner: world.NodeHandle

ortho_width: mu.Real = 12.0
ortho_height: mu.Real = 12.0
cam_height: mu.Real = 10.0
cam_yaw: mu.Real = 0.0
phase: f32

main :: proc() {
  context.logger = log.create_console_logger()
  engine := new(mjolnir.Engine)
  engine.setup_proc = setup
  engine.update_proc = update
  engine.pre_render_proc = debug_ui
  mjolnir.run(engine, 1000, 700, "Orthographic Camera")
}

setup :: proc(engine: ^mjolnir.Engine) {
  engine.debug_ui_enabled = true

  // Lit subjects — varying heights so ortho top-down view is informative
  world.spawn_primitive_mesh(
    &engine.world,
    .CUBE,
    .RED,
    position = {-2.5, 0.5, 0},
  )
  world.spawn_primitive_mesh(
    &engine.world,
    .SPHERE,
    .GREEN,
    position = {2.5, 0.5, 0},
    scale_factor = 0.7,
  )
  world.spawn_primitive_mesh(
    &engine.world,
    .CYLINDER,
    .BLUE,
    position = {0, 1.0, 2.5},
    scale_factor = 0.5,
  )
  world.spawn_primitive_mesh(
    &engine.world,
    .CONE,
    .YELLOW,
    position = {0, 0.8, -2.5},
    scale_factor = 0.5,
  )

  spinner = world.spawn_primitive_mesh(
    &engine.world,
    .CUBE,
    .MAGENTA,
    position = {0, 1.5, 0},
    scale_factor = 0.4,
  )

  ground_mesh := world.get_builtin_mesh(&engine.world, .QUAD_XZ)
  ground_mat := world.get_builtin_material(&engine.world, .GRAY)
  ground :=
    world.spawn(
      &engine.world,
      {0, 0, 0},
      world.MeshAttachment {
        handle = ground_mesh,
        material = ground_mat,
        cast_shadow = false,
      },
    ) or_else {}
  world.scale(&engine.world, ground, 6.0)

  world.spawn(
    &engine.world,
    {3, 8, 3},
    world.create_point_light_attachment({1.0, 0.95, 0.8, 1.0}, 25.0, false),
  )

  // Directional light too — test that shadow projection survives
  // orthographic main camera (engine shadow_matrices_directional builds its
  // own ortho frustum from light radius, independent of main cam).
  world.spawn(
    &engine.world,
    {-6, 10, -4},
    world.create_directional_light_attachment(
      {1.0, 0.95, 0.9, 4.0},
      15.0,
      true,
    ),
  )

  // Switch the main camera to orthographic top-down
  if cam, ok := world.camera(&engine.world, engine.world.main_camera); ok {
    extent := cam.extent
    world.camera_init_orthographic(
      cam,
      extent[0],
      extent[1],
      camera_position = {0, f32(cam_height), 0.01},
      camera_target = {0, 0, 0},
      ortho_width = f32(ortho_width),
      ortho_height = f32(ortho_height),
      near_plane = 0.1,
      far_plane = 100.0,
    )
    world.stage_camera_data(&engine.world.staging, engine.world.main_camera)
  }

  log.info("=========================================")
  log.info("Orthographic Main Camera — top-down view")
  log.info("=========================================")
}

update :: proc(engine: ^mjolnir.Engine, delta_time: f32) {
  phase += delta_time * 1.0
  if sn, ok := world.node(&engine.world, spinner); ok {
    world.rotate(&sn.transform, quat_y(phase))
  }
  apply_camera(&engine.world)
}

apply_camera :: proc(w: ^world.World) {
  cam, ok := world.camera(w, w.main_camera)
  if !ok do return
  if proj, ok := &cam.projection.(world.OrthographicProjection); ok {
    proj.width = f32(ortho_width)
    proj.height = f32(ortho_height)
  }
  yaw := f32(cam_yaw)
  // Slight tilt so user can still tell which side is forward
  pos := [3]f32 {
    math.sin(yaw) * 0.5,
    f32(cam_height),
    math.cos(yaw) * 0.5,
  }
  cam.position = pos
  world.camera_look_at(cam, pos, {0, 0, 0})
  world.stage_camera_data(&w.staging, w.main_camera)
}

quat_y :: proc(angle: f32) -> quaternion128 {
  half := angle * 0.5
  return quaternion(w = math.cos(half), x = 0, y = math.sin(half), z = 0)
}

debug_ui :: proc(engine: ^mjolnir.Engine) {
  ctx := &engine.render.debug_ui.ctx
  if mu.window(ctx, "Ortho Main", {700, 20, 280, 280}, {.NO_CLOSE}) {
    mu.label(ctx, fmt.tprintf("Ortho width: %.1f", ortho_width))
    mu.slider(ctx, &ortho_width, 2.0, 30.0)
    mu.label(ctx, fmt.tprintf("Ortho height: %.1f", ortho_height))
    mu.slider(ctx, &ortho_height, 2.0, 30.0)
    mu.label(ctx, fmt.tprintf("Cam height: %.1f", cam_height))
    mu.slider(ctx, &cam_height, 2.0, 30.0)
    mu.label(ctx, fmt.tprintf("Cam yaw: %.2f rad", cam_yaw))
    mu.slider(ctx, &cam_yaw, -math.PI, math.PI)
  }
}

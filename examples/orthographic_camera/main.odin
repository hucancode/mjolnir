package main

import "../../mjolnir"
import "../../mjolnir/world"
import "core:fmt"
import "core:log"
import "core:math"
import mu "vendor:microui"

spinner: mjolnir.NodeHandle

ortho_width: mu.Real = 12.0
ortho_height: mu.Real = 12.0
cam_height: mu.Real = 10.0
cam_yaw: mu.Real = 0.0
phase: f32

main :: proc() {
  mjolnir.run_app({
    title = "Orthographic Camera", width = 1000, height = 700,
    debug_ui = true, setup = setup, update = update, pre_render = debug_ui,
  })
}

setup :: proc(engine: ^mjolnir.Engine) {
  mjolnir.spawn_primitive_mesh(engine, .CUBE,     .RED,    position = {-2.5, 0.5, 0})
  mjolnir.spawn_primitive_mesh(engine, .SPHERE,   .GREEN,  position = {2.5, 0.5, 0},  scale_factor = 0.7)
  mjolnir.spawn_primitive_mesh(engine, .CYLINDER, .BLUE,   position = {0, 1.0, 2.5},  scale_factor = 0.5)
  mjolnir.spawn_primitive_mesh(engine, .CONE,     .YELLOW, position = {0, 0.8, -2.5}, scale_factor = 0.5)
  spinner = mjolnir.spawn_primitive_mesh(engine, .CUBE, .MAGENTA, position = {0, 1.5, 0}, scale_factor = 0.4)

  ground := mjolnir.spawn_primitive_mesh(engine, .QUAD_XZ, .GRAY, cast_shadow = false)
  mjolnir.scale(engine, ground, 6.0)

  mjolnir.spawn_light_point(engine, {3, 8, 3}, {1.0, 0.95, 0.8, 1.0}, 25.0, false)
  mjolnir.spawn_light_directional(engine, {-6, 10, -4}, {1.0, 0.95, 0.9, 4.0}, 15.0, true)

  if cam, ok := mjolnir.main_camera(engine); ok {
    extent := cam.extent
    world.camera_init_orthographic(
      cam, extent[0], extent[1],
      camera_position = {0, f32(cam_height), 0.01}, camera_target = {0, 0, 0},
      ortho_width = f32(ortho_width), ortho_height = f32(ortho_height),
      near_plane = 0.1, far_plane = 100.0,
    )
    mjolnir.mark_camera_dirty(engine, mjolnir.main_camera_handle(engine))
  }
  log.info("Orthographic Main Camera — top-down view")
}

update :: proc(engine: ^mjolnir.Engine, dt: f32) {
  phase += dt
  mjolnir.rotate(engine, spinner, quat_y(phase))
  apply_camera(engine)
}

apply_camera :: proc(engine: ^mjolnir.Engine) {
  cam, ok := mjolnir.main_camera(engine)
  if !ok do return
  if proj, ok := &cam.projection.(world.OrthographicProjection); ok {
    proj.width = f32(ortho_width)
    proj.height = f32(ortho_height)
  }
  yaw := f32(cam_yaw)
  pos := [3]f32{math.sin(yaw) * 0.5, f32(cam_height), math.cos(yaw) * 0.5}
  cam.position = pos
  world.camera_look_at(cam, pos, {0, 0, 0})
  mjolnir.mark_camera_dirty(engine, mjolnir.main_camera_handle(engine))
}

quat_y :: proc(angle: f32) -> quaternion128 {
  half := angle * 0.5
  return quaternion(w = math.cos(half), x = 0, y = math.sin(half), z = 0)
}

debug_ui :: proc(engine: ^mjolnir.Engine) {
  ctx := mjolnir.ui_ctx(engine)
  if mu.window(ctx, "Ortho Main", {700, 20, 280, 280}, {.NO_CLOSE}) {
    mu.label(ctx, fmt.tprintf("Ortho width: %.1f", ortho_width));   mu.slider(ctx, &ortho_width, 2.0, 30.0)
    mu.label(ctx, fmt.tprintf("Ortho height: %.1f", ortho_height)); mu.slider(ctx, &ortho_height, 2.0, 30.0)
    mu.label(ctx, fmt.tprintf("Cam height: %.1f", cam_height));     mu.slider(ctx, &cam_height, 2.0, 30.0)
    mu.label(ctx, fmt.tprintf("Cam yaw: %.2f rad", cam_yaw));       mu.slider(ctx, &cam_yaw, -math.PI, math.PI)
  }
}

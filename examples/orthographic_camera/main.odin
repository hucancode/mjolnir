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
  mjolnir.run_app({
    title = "Orthographic Camera", width = 1000, height = 700,
    debug_ui = true, setup = setup, update = update, pre_render = debug_ui,
  })
}

setup :: proc(engine: ^mjolnir.Engine) {
  world.spawn_primitive_mesh(&engine.world, .CUBE,     .RED,    position = {-2.5, 0.5, 0})
  world.spawn_primitive_mesh(&engine.world, .SPHERE,   .GREEN,  position = {2.5, 0.5, 0},  scale_factor = 0.7)
  world.spawn_primitive_mesh(&engine.world, .CYLINDER, .BLUE,   position = {0, 1.0, 2.5},  scale_factor = 0.5)
  world.spawn_primitive_mesh(&engine.world, .CONE,     .YELLOW, position = {0, 0.8, -2.5}, scale_factor = 0.5)
  spinner = world.spawn_primitive_mesh(&engine.world, .CUBE, .MAGENTA, position = {0, 1.5, 0}, scale_factor = 0.4)

  world.spawn_ground(&engine.world, 6.0)

  world.spawn_light_point(&engine.world, {3, 8, 3}, {1.0, 0.95, 0.8, 1.0}, 25.0, false)
  world.spawn_light_directional(&engine.world, {-6, 10, -4}, {1.0, 0.95, 0.9, 4.0}, 15.0, true)

  world.main_camera_set_orthographic(&engine.world,
    ortho_width = f32(ortho_width), ortho_height = f32(ortho_height),
    from = {0, f32(cam_height), 0.01}, to = {0, 0, 0},
  )
  log.info("Orthographic Main Camera — top-down view")
}

update :: proc(engine: ^mjolnir.Engine, dt: f32) {
  phase += dt
  world.rotate(&engine.world, spinner, phase)
  yaw := f32(cam_yaw)
  pos := [3]f32{math.sin(yaw) * 0.5, f32(cam_height), math.cos(yaw) * 0.5}
  world.main_camera_set_orthographic(&engine.world,
    ortho_width = f32(ortho_width), ortho_height = f32(ortho_height),
    from = pos, to = {0, 0, 0},
  )
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

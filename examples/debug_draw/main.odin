package main

import "../../mjolnir"
import "../../mjolnir/input"
import "../../mjolnir/platform"
import "../../mjolnir/render"
import "../../mjolnir/world"
import "core:log"
import "core:math"
import "core:math/linalg"

elapsed: f32 = 0

App :: struct {
  window:   platform.Platform,
  scene:    world.World,
  renderer: render.Manager,
  camera:   mjolnir.CameraController,
  input:    input.State,
}

main :: proc() {
  context.logger = log.create_console_logger()
  app := new(App)
  defer free(app)
  w := &app.window
  if !platform.init(w, 1024, 768, "Debug Draw") do return
  defer platform.shutdown(w)
  if !render.init(&app.renderer, "Debug Draw", platform.vulkan_instance_extensions(), platform.vulkan_get_instance_proc_addr(), platform.create_surface, w, platform.framebuffer_size(w), platform.dpi_scale(w)) do return
  defer render.shutdown(&app.renderer)
  if !world.init(&app.scene) do return
  defer world.shutdown(&app.scene)
  render.load_environment_map(&app.renderer, "assets/Cannon_Exterior.hdr")
  app.camera = mjolnir.orbit_controller()

  light := world.spawn(&app.scene, {10, 18, 10})
  render.attach(&app.renderer, light.index, render.directional_light_attachment({1, 0.97, 0.92, 2.0}, 60.0, false))
  world.rotate(&app.scene, light, math.PI * 0.5, linalg.VECTOR3F32_X_AXIS)

  tiny := world.spawn(&app.scene, {0, -0.5, 0})
  render.attach(&app.renderer, tiny.index, render.primitive(&app.renderer, .CUBE, .GRAY))
  world.scale(&app.scene, tiny, 0.01)
  ground := world.spawn(&app.scene, {0, -1, 0})
  render.attach(&app.renderer, ground.index, render.primitive(&app.renderer, .QUAD_XZ, .GRAY))
  world.scale(&app.scene, ground, 20.0)

  // Real cube provides depth-occlusion contrast for the adjacent debug cube.
  occluder := world.spawn(&app.scene, {-6, 0, 0})
  render.attach(&app.renderer, occluder.index, render.primitive(&app.renderer, .CUBE, .BLUE))
  world.scale(&app.scene, occluder, 0.8)

  render.main_camera_look_at(&app.renderer, {12, 8, 14}, {0, 0, 0})

  mjolnir.run(mjolnir.Loop(App){app = app, should_close = should_close, update = update, frame = frame})
}

should_close :: proc(app: ^App) -> bool {
  return platform.should_close(&app.window)
}

update :: proc(app: ^App, dt: f32) {
  platform.read_input(&app.window, &app.input)
  mjolnir.camera_controller_update(&app.camera, &app.renderer, &app.input, dt)
  elapsed += dt
  t := elapsed
  white := render.DEBUG_WHITE

  render.debug_axes(&app.renderer, {0, 0, 0}, scale = 2)

  render.debug_segment(&app.renderer, {-8, 0, -8}, {8, 0, -8}, white)
  render.debug_segment(&app.renderer, {-8, 0, -8}, {-8, 6, -8}, white)
  render.debug_segment(&app.renderer, {8, 0, -8}, {8, 6, -8}, white)
  render.debug_segment(&app.renderer, {-8, 6, -8}, {8, 6, -8}, white)

  render.debug_aabb(&app.renderer, {-7, -1, -1}, {-5, 1, 1}, render.DEBUG_GREEN)

  rot := linalg.quaternion_angle_axis_f32(t, {0, 1, 0})
  render.debug_cube(&app.renderer, {-2, 1, 0}, rotation = rot, size = {1.5, 1.5, 1.5}, color = render.DEBUG_MAGENTA)

  r := 1.0 + 0.3 * math.sin(t * 2)
  render.debug_sphere(&app.renderer, {2, 1, 0}, radius = r, color = render.DEBUG_CYAN)

  render.debug_circle(&app.renderer, {6, 0.01, 0}, normal = {0, 1, 0}, radius = 1.5, color = render.DEBUG_YELLOW)
  render.debug_circle(&app.renderer, {6, 2, 0}, normal = linalg.normalize([3]f32{1, 1, 0}), radius = 1.0, color = render.DEBUG_ORANGE)

  target := [3]f32{4 * math.cos(t), 3, 4 * math.sin(t)}
  render.debug_arrow(&app.renderer, {0, 3, 0}, target, render.DEBUG_RED)
  render.debug_point(&app.renderer, target, size = 0.3, color = white)

  trail_period :: 0.25
  trail_count_total := int(t / trail_period)
  if trail_count_total > 0 {
    last := f32(trail_count_total) * trail_period
    if last > elapsed - dt && last <= elapsed {
      angle := last * 1.5
      pos := [3]f32{5 * math.cos(angle), 0.5, 5 * math.sin(angle)}
      render.debug_sphere(&app.renderer, pos, 0.25, render.DEBUG_GREEN, life = 3.0)
    }
  }

  // bypass_depth = renders over the real cube.
  render.debug_axes(&app.renderer, {-6, 0, 0}, scale = 1.5, bypass_depth = true)
  world.update(&app.scene)
  for i in world.removed_nodes(&app.scene) do render.stage_slot_removal(&app.renderer, i)
  render.stage_transforms(&app.renderer, world.changed_nodes(&app.scene))
  render.update(&app.renderer, dt)
}

frame :: proc(app: ^App) -> bool {
  platform.poll_events(&app.window)
  render.debug_sphere(&app.renderer, {0, 5, 0}, 0.4, render.DEBUG_CYAN)
  ok := render.frame(&app.renderer, platform.framebuffer_size(&app.window), platform.dpi_scale(&app.window))
  // Drawn after the frame is recorded; these segments appear next frame.
  render.debug_sphere(&app.renderer, {0, 6, 0}, 0.4, render.DEBUG_MAGENTA)
  render.debug_arrow(&app.renderer, {0, 5, 0}, {0, 6, 0}, render.DEBUG_WHITE)
  return ok
}

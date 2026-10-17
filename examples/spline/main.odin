// Spline evaluation and visualization.
package main

import "../../mjolnir"
import "../../mjolnir/animation"
import "../../mjolnir/input"
import "../../mjolnir/platform"
import "../../mjolnir/render"
import "../../mjolnir/world"
import "core:log"
import "core:math"
import "core:math/ease"

CUBE_COUNT :: 50
ANIMATION_DURATION :: 8.0

App :: struct {
  window:   platform.Platform,
  scene:    world.World,
  renderer: render.Renderer,
  input:    input.State,
  time:     f32,
  // orbit controller state, owned by the app
  yaw, pitch, dist: f32,
}

cubes: [CUBE_COUNT]world.NodeHandle
spline: animation.Spline([3]f32)

main :: proc() {
  context.logger = log.create_console_logger()
  app := new(App)
  w := &app.window
  if !platform.init(w, 800, 600, "Spline") do return
  if !render.init(&app.renderer, "Spline", w.window, platform.framebuffer_size(w), platform.dpi_scale(w)) do return
  if !world.init(&app.scene) do return
  mjolnir.run(
    mjolnir.Loop(App) {
      app = app,
      setup = setup,
      shutdown = shutdown,
      should_close = should_close,
      update = update,
      frame = frame,
    },
  )
}

shutdown :: proc(app: ^App) {
  animation.spline_destroy(&spline)
  world.shutdown(&app.scene)
  render.shutdown(&app.renderer)
  platform.shutdown(&app.window)
  free(app)
}

should_close :: proc(app: ^App) -> bool {
  return platform.should_close(&app.window)
}

// On the web the renderer's device arrives after main returns: build the scene once it is up.
setup :: proc(app: ^App) -> bool {
  if !render.ready(&app.renderer) do return false
  render.environment_map_load(&app.renderer, #load("../../assets/Cannon_Exterior.hdr"))
  render.camera_look_at(render.main_camera(&app.renderer), {0, 10, 0}, {0, 0, 0})
  app.yaw, app.pitch, app.dist = render.camera_orbit_state(render.main_camera(&app.renderer))

  CONTROL_POINTS :: 10
  points: [CONTROL_POINTS][3]f32
  times: [CONTROL_POINTS]f32
  for i in 0 ..< CONTROL_POINTS {
    t := f32(i) * 2.0 * math.PI / f32(CONTROL_POINTS - 1)
    scale :: 5.0
    points[i] = {scale * math.sin(t), 0, scale * math.sin(2.0 * t) * 0.5}
    times[i] = f32(i) * ANIMATION_DURATION / f32(CONTROL_POINTS - 1)
  }
  if !animation.spline_init(&spline, points[:], times[:]) do log.error("Spline validation failed!")

  mats := [?]render.MaterialHandle{
    app.renderer.builtin_materials[.RED], app.renderer.builtin_materials[.GREEN],
    app.renderer.builtin_materials[.BLUE], app.renderer.builtin_materials[.YELLOW],
    app.renderer.builtin_materials[.CYAN], app.renderer.builtin_materials[.MAGENTA],
    app.renderer.builtin_materials[.WHITE], app.renderer.builtin_materials[.GRAY],
    app.renderer.builtin_materials[.BLACK],
  }
  cube := app.renderer.builtin_meshes[.CUBE]
  for i in 0 ..< CUBE_COUNT {
    cubes[i] = world.spawn(&app.scene, {0, 0, 0})
    render.attach(&app.renderer, cubes[i].index, render.MeshAttachment{handle = cube, material = mats[i % len(mats)]})
    world.scale(&app.scene, cubes[i], 0.3)
  }
  ground := world.spawn(&app.scene, {0, -2, 0})
  render.attach(&app.renderer, ground.index, render.primitive(&app.renderer, .QUAD_XZ, .GRAY, cast_shadow = false))
  world.scale(&app.scene, ground, 20.0)
  light := world.spawn(&app.scene, {0, 10, 0})
  render.attach(&app.renderer, light.index, render.light_create(&app.renderer, render.make_point_light({1, 1, 1, 1}, 20.0, true)))
  return true
}

update :: proc(app: ^App, dt: f32) {
  app.time += dt
  platform.read_input(&app.window, &app.input)
  if !app.input.mouse_captured {
    if input.mouse_down(&app.input, .LEFT) {
      app.yaw += app.input.mouse_delta.x * 0.02
      app.pitch = clamp(app.pitch + app.input.mouse_delta.y * 0.02, -1.5, 1.5)
    }
    app.dist = clamp(app.dist - app.input.scroll.y * 2, 1, 200)
  }
  render.camera_orbit(render.main_camera(&app.renderer), app.yaw, app.pitch, app.dist)
  total_length := animation.spline_arc_length(spline)
  for i in 0 ..< CUBE_COUNT {
    offset := f32(i) / f32(CUBE_COUNT) * total_length
    elapsed := app.time
    current_s := math.mod_f32(elapsed * (total_length / ANIMATION_DURATION) + offset, total_length)
    normalized := current_s / total_length
    tweened := ease.ease(.Quadratic_In_Out, normalized) * total_length
    world.translate(&app.scene, cubes[i], animation.spline_sample_uniform(spline, tweened))
  }
  world.update(&app.scene)
  render.stage_transforms(&app.renderer, world.changes(&app.scene))
  render.update(&app.renderer, dt)
}

frame :: proc(app: ^App) -> bool {
  platform.poll_events(&app.window)
  return render.frame(&app.renderer, platform.framebuffer_size(&app.window), platform.dpi_scale(&app.window))
}

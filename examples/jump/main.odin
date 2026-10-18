// Character controller, movement are powered by physics engine.
package main

import "../../mjolnir"
import "../../mjolnir/debugui"
import "../../mjolnir/input"
import "../../mjolnir/platform"
import "../../mjolnir/render"
import "../../mjolnir/world"
import "../../mjolnir/physics"
import "core:log"
import "core:math/linalg"
import mu "vendor:microui"

GROUND_HALF_EXTENTS :: [3]f32{40.0, 0.5, 40.0}
CUBE_HALF_EXTENTS :: [3]f32{0.5, 0.5, 0.5}
CUBE_START :: [3]f32{0, 3, 0}

App :: struct {
  window:          platform.Platform,
  scene:           world.World,
  renderer:        render.Renderer,
  debug:           debugui.Context,
  input:           input.State,
  orbit:           render.Orbit,
  phys:            physics.World,
  cube:            physics.BodyHandle,
  time_since_jump: f32,
  jump_force:      mu.Real,
  move_force:      mu.Real,
  jump_interval:   mu.Real,
  mass:            mu.Real,
  auto_jump:       bool,
}

main :: proc() {
  context.logger = log.create_console_logger()
  app := new(App)
  app.jump_force, app.move_force, app.jump_interval, app.mass = 20.0, 20.0, 5.0, 2.0
  app.auto_jump = true
  physics.init(&app.phys, gravity = {0, -10, 0})
  w := &app.window
  if !platform.init(w, 1000, 700, "Character Controller") do return
  if !render.init(&app.renderer, "Character Controller", w.window, platform.framebuffer_size(w), platform.dpi_scale(w)) do return
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

setup :: proc(app: ^App) -> mjolnir.Setup {
  if !render.ready(&app.renderer) do return .WAIT
  if !debugui.init(&app.debug, &app.renderer) do return .FAIL

  ground_position := [3]f32{0, -GROUND_HALF_EXTENTS.y, 0}
  ground := world.spawn(&app.scene, ground_position)
  physics.body_create(&app.phys, ground_position, collider = physics.BoxCollider{half_extents = GROUND_HALF_EXTENTS}, user = world.Handle(ground))
  ground_visual := world.spawn(&app.scene, parent = ground)
  render.attach(&app.renderer, render.SlotHandle(ground_visual.index), render.primitive(&app.renderer, .CUBE, .GRAY))
  world.scale(&app.scene, ground_visual, GROUND_HALF_EXTENTS)

  cube := world.spawn(&app.scene, CUBE_START)
  app.cube = physics.body_create(&app.phys, CUBE_START, mass = f32(app.mass), collider = physics.BoxCollider{half_extents = CUBE_HALF_EXTENTS}, user = world.Handle(cube))
  cube_visual := world.spawn(&app.scene, parent = cube)
  render.attach(&app.renderer, render.SlotHandle(cube_visual.index), render.primitive(&app.renderer, .CUBE, .CYAN))
  world.scale(&app.scene, cube_visual, CUBE_HALF_EXTENTS)

  render.camera_look_at(render.main_camera(&app.renderer), {8, 5, 8}, {0, 2, 0})
  app.orbit = render.orbit_from_camera(render.main_camera(&app.renderer))
  return .READY
}

shutdown :: proc(app: ^App) {
  world.shutdown(&app.scene)
  debugui.shutdown(&app.debug)
  render.shutdown(&app.renderer)
  platform.shutdown(&app.window)
  physics.shutdown(&app.phys)
  free(app)
}

should_close :: proc(app: ^App) -> bool {
  return platform.should_close(&app.window)
}

jump :: proc(app: ^App) {
  physics.apply_impulse(&app.phys, app.cube, {0, f32(app.jump_force), 0})
  app.time_since_jump = 0
}

update :: proc(app: ^App, dt: f32) {
  platform.read_input(&app.window, &app.input)
  debugui.feed(&app.debug, &app.input)
  if !app.input.mouse_captured do render.orbit_drag(&app.orbit, 0, app.input.scroll.y)
  render.camera_orbit(render.main_camera(&app.renderer), app.orbit)
  app.time_since_jump += dt
  force := [3]f32{input.axis(&app.input, .A, .D), 0, input.axis(&app.input, .W, .S)} * f32(app.move_force)
  if linalg.length(force) > 0.1 do physics.apply_force(&app.phys, app.cube, force)
  if input.key_pressed(&app.input, .SPACE) do jump(app)
  if app.auto_jump && app.time_since_jump >= f32(app.jump_interval) do jump(app)
  physics.step(&app.phys, dt)
  world.set_world_poses(&app.scene, physics.body_poses(&app.phys))
  world.update(&app.scene)
  render.stage_transforms(&app.renderer, world.changes(&app.scene))
  render.update(&app.renderer, dt)
}

frame :: proc(app: ^App) -> bool {
  platform.poll_events(&app.window)
  ctx := debugui.begin(&app.debug)
  if mu.window(ctx, "Jump", {720, 20, 260, 350}, {.NO_CLOSE}) {
    mu.layout_row(ctx, {-1}, 0)
    mu.label(ctx, "Mass (kg)")
    if .CHANGE in mu.slider(ctx, &app.mass, 1.0, 10.0) do physics.set_mass(&app.phys, app.cube, f32(app.mass))
    mu.label(ctx, "Jump force")
    mu.slider(ctx, &app.jump_force, 5.0, 50.0)
    mu.label(ctx, "Move force")
    mu.slider(ctx, &app.move_force, 1.0, 20.0)
    mu.checkbox(ctx, "Auto-jump", &app.auto_jump)
    mu.label(ctx, "Auto-jump interval (s)")
    mu.slider(ctx, &app.jump_interval, 0.5, 10.0)
    mu.label(ctx, "")
    if .SUBMIT in mu.button(ctx, "Jump now") do jump(app)
    mu.label(ctx, "W/A/S/D moves, Space jumps")
  }
  render.stage_overlay(&app.renderer, debugui.end(&app.debug))
  return render.frame(&app.renderer, platform.framebuffer_size(&app.window), platform.dpi_scale(&app.window))
}

// Character controller, movement are powered by physics engine.
package main

import "../../mjolnir"
import "../../mjolnir/input"
import "../../mjolnir/platform"
import "../../mjolnir/render"
import "../../mjolnir/world"
import "../../mjolnir/physics"
import "core:fmt"
import "core:log"
import "core:math/linalg"
import mu "vendor:microui"

cube_handle: world.NodeHandle
cube_body: physics.BodyHandle
box_collider := physics.BoxCollider{half_extents = {0.5, 0.5, 0.5}}
time_since_jump: f32

jump_force: mu.Real = 20.0
move_force: mu.Real = 20.0
jump_interval: mu.Real = 5.0
mass: mu.Real = 2.0
last_mass: mu.Real = 2.0
auto_jump: bool = true

phys: physics.World

App :: struct {
  window:   platform.Platform,
  scene:    world.World,
  renderer: render.Renderer,
  input:    input.State,
  // orbit controller state, owned by the app
  yaw, pitch, dist: f32,
}

main :: proc() {
  context.logger = log.create_console_logger()
  physics.init(&phys, gravity = {0, -10, 0})
  app := new(App)
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

// On the web the renderer's device arrives after main returns: build the scene once it is up.
setup :: proc(app: ^App) -> bool {
  if !render.ready(&app.renderer) do return false
  render.load_environment_map(&app.renderer, #load("../../assets/Cannon_Exterior.hdr"))

  ground := world.spawn(&app.scene, {0, -0.5, 0})
  physics.create_body(&phys, {0, -0.5, 0}, collider = physics.BoxCollider{half_extents = {40.0, 0.5, 40.0}}, user = world.Handle(ground))
  ground_visual := world.spawn_child(&app.scene, ground)
  render.attach(&app.renderer, ground_visual.index, render.primitive(&app.renderer, .CUBE, .GRAY))
  world.scale_xyz(&app.scene, ground_visual, 40.0, 0.5, 40.0)
  cube_handle = world.spawn(&app.scene, {0, 3, 0})
  cube_body = physics.create_body(&phys, {0, 3, 0}, mass = f32(mass), collider = box_collider, user = world.Handle(cube_handle))
  cube_visual := world.spawn_child(&app.scene, cube_handle)
  render.attach(&app.renderer, cube_visual.index, render.primitive(&app.renderer, .CUBE, .CYAN))
  s := box_collider.half_extents
  world.scale_xyz(&app.scene, cube_visual, s.x, s.y, s.z)
  render.main_camera_look_at(&app.renderer, {8, 5, 8}, {0, 2, 0})
  app.yaw, app.pitch, app.dist = render.camera_orbit_state(render.main_camera(&app.renderer))
  return true
}

shutdown :: proc(app: ^App) {
  world.shutdown(&app.scene)
  render.shutdown(&app.renderer)
  platform.shutdown(&app.window)
  free(app)
  physics.shutdown(&phys)
}

should_close :: proc(app: ^App) -> bool {
  return platform.should_close(&app.window)
}

update :: proc(app: ^App, dt: f32) {
  platform.read_input(&app.window, &app.input)
  input.feed_microui(&app.input, render.debug_ctx(&app.renderer))
  if !app.input.mouse_captured do app.dist = clamp(app.dist - app.input.scroll.y * 2, 1, 200)
  render.main_camera_orbit(&app.renderer, app.yaw, app.pitch, app.dist)
  time_since_jump += dt
  if mass != last_mass {
    physics.set_mass(&phys, cube_body, f32(mass))
    last_mass = mass
  }
  f := [3]f32 {
    input.axis(&app.input, .A, .D),
    0,
    input.axis(&app.input, .W, .S),
  } * f32(move_force)
  if linalg.length(f) > 0.1 do physics.apply_force(&phys, cube_body, f)
  if input.key_pressed(&app.input, .SPACE) {
    physics.apply_impulse(&phys, cube_body, {0, f32(jump_force), 0})
    time_since_jump = 0.0
  }
  if auto_jump && time_since_jump >= f32(jump_interval) {
    time_since_jump = 0.0
    physics.apply_impulse(&phys, cube_body, {0, f32(jump_force), 0})
  }
  physics.step(&phys, dt)
  world.set_world_poses(&app.scene, physics.body_poses(&phys))
  world.update(&app.scene)
  render.stage_transforms(&app.renderer, world.changes(&app.scene))
  render.update(&app.renderer, dt)
}

frame :: proc(app: ^App) -> bool {
  platform.poll_events(&app.window)
  ctx := render.debug_ui(&app.renderer)
  if mu.window(ctx, "Jump", {720, 20, 260, 350}, {.NO_CLOSE}) {
    mu.layout_row(ctx, {-1}, 0)
    mu.label(ctx, fmt.tprintf("Mass: %.1f kg", mass))
    mu.slider(ctx, &mass, 1.0, 10.0)
    mu.label(ctx, fmt.tprintf("Jump force: %.0f", jump_force))
    mu.slider(ctx, &jump_force, 5.0, 50.0)
    mu.label(ctx, fmt.tprintf("Move force: %.1f", move_force))
    mu.slider(ctx, &move_force, 1.0, 20.0)
    mu.checkbox(ctx, "Auto-jump", &auto_jump)
    mu.label(ctx, fmt.tprintf("Auto-jump interval: %.1f s", jump_interval))
    mu.slider(ctx, &jump_interval, 0.5, 10.0)
    mu.label(ctx, "")
    if .SUBMIT in mu.button(ctx, "Jump now") {
      physics.apply_impulse(&phys, cube_body, {0, f32(jump_force), 0})
      time_since_jump = 0
    }
    mu.label(ctx, "W/A/S/D moves, Space jumps")
  }
  return render.frame(&app.renderer, platform.framebuffer_size(&app.window), platform.dpi_scale(&app.window))
}

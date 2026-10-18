// Fast projectiles don't tunnel through thin walls.
package main

import "../../mjolnir"
import "../../mjolnir/debugui"
import "../../mjolnir/input"
import "../../mjolnir/platform"
import "../../mjolnir/render"
import "../../mjolnir/world"
import "../../mjolnir/physics"
import "core:fmt"
import "core:log"
import "core:math/linalg"
import mu "vendor:microui"

WALL_COUNT :: 3
WALL_X :: f32(0.0)
WALL_THICKNESS :: [WALL_COUNT]f32{0.05, 0.2, 0.8}
WALL_COLORS :: [WALL_COUNT]render.Color{.RED, .YELLOW, .GREEN}
WALL_HALF_HEIGHT :: f32(1.5)
WALL_HALF_WIDTH :: f32(2.0)
WALL_SPACING :: f32(5.0)
GROUND_HALF_EXTENTS :: [3]f32{30.0, 0.5, 12.0}
BULLET_RADIUS :: f32(0.15)
BULLET_MASS :: f32(0.05)
START_POS :: [3]f32{-15.0, 1.5, 0.0}
BULLET_MIN_X :: f32(-25.0)
BULLET_MAX_X :: f32(20.0)
AUTO_FIRE_INTERVAL :: f32(2.0)

App :: struct {
  window:          platform.Platform,
  scene:           world.World,
  renderer:        render.Renderer,
  debug:           debugui.Context,
  input:           input.State,
  orbit:           render.Orbit,
  phys:            physics.World,
  bullet:          physics.BodyHandle,
  target_wall:     int,
  bullet_speed:    mu.Real,
  auto_fire:       bool,
  auto_fire_timer: f32,
}

main :: proc() {
  context.logger = log.create_console_logger()
  app := new(App)
  app.target_wall = 1
  app.bullet_speed = 60.0
  physics.init(&app.phys, gravity = {0, 0, 0})
  w := &app.window
  if !platform.init(w, 1000, 700, "Bullet vs Thin Wall (CCD)") do return
  if !render.init(&app.renderer, "Bullet vs Thin Wall (CCD)", w.window, platform.framebuffer_size(w), platform.dpi_scale(w)) do return
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

spawn_box :: proc(app: ^App, position, half_extents: [3]f32, color: render.Color) {
  node := world.spawn(&app.scene, position)
  physics.body_create(&app.phys, position, collider = physics.BoxCollider{half_extents = half_extents}, user = world.Handle(node))
  visual := world.spawn(&app.scene, parent = node)
  render.attach(&app.renderer, render.SlotHandle(visual.index), render.primitive(&app.renderer, .CUBE, color))
  world.scale(&app.scene, visual, half_extents)
}

setup :: proc(app: ^App) -> bool {
  if !render.ready(&app.renderer) do return false
  if !debugui.init(&app.debug, &app.renderer) do return false
  render.environment_map_load(&app.renderer, #load("../../assets/Cannon_Exterior.hdr"))
  render.camera_look_at(render.main_camera(&app.renderer), {-14, 8, 14}, {0, 1, 0})
  app.orbit = render.orbit_from_camera(render.main_camera(&app.renderer))
  light := world.spawn(&app.scene, {-5, 12, 5})
  render.attach(&app.renderer, render.SlotHandle(light.index), render.light_create(&app.renderer, render.make_directional_light({1, 0.95, 0.9}, 1, 6.0)))

  spawn_box(app, {0, -GROUND_HALF_EXTENTS.y, 0}, GROUND_HALF_EXTENTS, .GRAY)
  thickness := WALL_THICKNESS
  colors := WALL_COLORS
  for i in 0 ..< WALL_COUNT {
    spawn_box(app, {WALL_X, WALL_HALF_HEIGHT, wall_z(i)}, {thickness[i] * 0.5, WALL_HALF_HEIGHT, WALL_HALF_WIDTH}, colors[i])
  }

  bullet_node := world.spawn(&app.scene, START_POS)
  app.bullet = physics.body_create(&app.phys, START_POS, mass = BULLET_MASS, collider = physics.SphereCollider{radius = BULLET_RADIUS}, user = world.Handle(bullet_node))
  bullet_visual := world.spawn(&app.scene, parent = bullet_node)
  render.attach(&app.renderer, render.SlotHandle(bullet_visual.index), render.primitive(&app.renderer, .SPHERE, .CYAN))
  world.scale(&app.scene, bullet_visual, BULLET_RADIUS)
  params := physics.body_params(&app.phys, app.bullet)
  params.linear_damping = 0
  params.angular_damping = 0
  params.restitution = 0.1
  params.friction = 0.2
  return true
}

wall_z :: proc(wall: int) -> f32 {
  return (f32(wall) - f32(WALL_COUNT - 1) * 0.5) * WALL_SPACING
}

reset_bullet :: proc(app: ^App) {
  physics.set_pose(&app.phys, app.bullet, {START_POS.x, START_POS.y, wall_z(app.target_wall)}, linalg.QUATERNIONF32_IDENTITY)
  physics.set_velocity(&app.phys, app.bullet, {})
  physics.set_angular_velocity(&app.phys, app.bullet, {})
}

fire_bullet :: proc(app: ^App) {
  reset_bullet(app)
  physics.set_velocity(&app.phys, app.bullet, {f32(app.bullet_speed), 0, 0})
}

update :: proc(app: ^App, dt: f32) {
  platform.read_input(&app.window, &app.input)
  debugui.feed(&app.debug, &app.input)
  if !app.input.mouse_captured {
    drag := app.input.mouse_delta if input.mouse_down(&app.input, .LEFT) else 0
    render.orbit_drag(&app.orbit, drag, app.input.scroll.y)
  }
  render.camera_orbit(render.main_camera(&app.renderer), app.orbit)
  if app.auto_fire {
    app.auto_fire_timer += dt
    if app.auto_fire_timer >= AUTO_FIRE_INTERVAL {
      app.auto_fire_timer = 0
      fire_bullet(app)
    }
  }
  if body, ok := physics.body(&app.phys, app.bullet); ok && (body.position.x > BULLET_MAX_X || body.position.x < BULLET_MIN_X) {
    reset_bullet(app)
  }
  physics.step(&app.phys, dt)
  world.set_world_poses(&app.scene, physics.body_poses(&app.phys))
  world.update(&app.scene)
  render.stage_transforms(&app.renderer, world.changes(&app.scene))
  render.update(&app.renderer, dt)
}

frame :: proc(app: ^App) -> bool {
  platform.poll_events(&app.window)
  debug_ui(app)
  render.stage_overlay(&app.renderer, {commands = debugui.end(&app.debug, platform.dpi_scale(&app.window))})
  return render.frame(&app.renderer, platform.framebuffer_size(&app.window), platform.dpi_scale(&app.window))
}

debug_ui :: proc(app: ^App) {
  ctx := debugui.begin(&app.debug)
  if mu.window(ctx, "Bullet CCD", {700, 20, 280, 380}, {.NO_CLOSE}) {
    mu.layout_row(ctx, {-1}, 0)
    mu.label(ctx, "Target wall:")
    mu.layout_row(ctx, {90, 90, 90}, 0)
    if .SUBMIT in mu.button(ctx, "Red 0.05")   do app.target_wall = 0
    if .SUBMIT in mu.button(ctx, "Yellow 0.2") do app.target_wall = 1
    if .SUBMIT in mu.button(ctx, "Green 0.8")  do app.target_wall = 2

    perf := physics.perf(&app.phys)
    mu.layout_row(ctx, {-1}, 0)
    mu.label(ctx, "Velocity (m/s)")
    mu.slider(ctx, &app.bullet_speed, 1.0, 400.0)
    mu.label(ctx, "CCD: ON" if perf.ccd_bodies_tested > 0 else "CCD: OFF")

    mu.layout_row(ctx, {130, -1}, 0)
    if .SUBMIT in mu.button(ctx, "Fire") do fire_bullet(app)
    mu.checkbox(ctx, "Auto-fire (2s)", &app.auto_fire)

    mu.layout_row(ctx, {-1}, 0)
    mu.label(ctx, "Stats")
    mu.label(ctx, fmt.tprintf("CCD bodies tested: %d", perf.ccd_bodies_tested))
    mu.label(ctx, fmt.tprintf("CCD swept candidates: %d", perf.ccd_total_candidates))
    mu.label(ctx, fmt.tprintf("CCD time: %.3f ms", perf.ccd_ms))
    mu.label(ctx, fmt.tprintf("Contacts: %d", perf.contact_count))
    if body, ok := physics.body(&app.phys, app.bullet); ok {
      mu.label(ctx, fmt.tprintf("Bullet x: %.2f  vel: %.1f", body.position.x, linalg.length(body.velocity)))
    }
  }
}

// Fast projectiles don't tunnel through thin walls.
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

App :: struct {
  window:   platform.Platform,
  scene:    world.World,
  renderer: render.Renderer,
  input:    input.State,
  // orbit controller state, owned by the app
  yaw, pitch, dist: f32,
}

WALL_COUNT :: 3
WALL_X :: f32(0.0)
wall_heights := [3]f32{0.05, 0.2, 0.8}
WALL_SPACING :: f32(5.0)
BULLET_RADIUS :: f32(0.15)
BULLET_MASS :: f32(0.05)
START_POS :: [3]f32{-15.0, 1.5, 0.0}

bullet_body: physics.BodyHandle
bullet_node: world.NodeHandle
wall_nodes: [WALL_COUNT]world.NodeHandle
target_wall: i32 = 1
bullet_speed: mu.Real = 60.0
auto_fire: bool = false
auto_fire_timer: f32

phys: physics.World

main :: proc() {
  context.logger = log.create_console_logger()
  physics.init(&phys)
  app := new(App)
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
  render.shutdown(&app.renderer)
  platform.shutdown(&app.window)
  free(app)
  physics.shutdown(&phys)
}

should_close :: proc(app: ^App) -> bool {
  return platform.should_close(&app.window)
}

// On the web the renderer's device arrives after main returns: build the scene once it is up.
setup :: proc(app: ^App) -> bool {
  if !render.ready(&app.renderer) do return false
  render.load_environment_map(&app.renderer, #load("../../assets/Cannon_Exterior.hdr"))
  phys.gravity = {0, 0, 0}
  render.main_camera_look_at(&app.renderer, {-14, 8, 14}, {0, 1, 0})
  app.yaw, app.pitch, app.dist = render.camera_orbit_state(render.main_camera(&app.renderer))
  light := world.spawn(&app.scene, {-5, 12, 5})
  render.attach(&app.renderer, light.index, render.directional_light_attachment({1, 0.95, 0.9, 1}, 6.0, true))

  cube_mesh := app.renderer.builtin_meshes[.CUBE]
  ground := world.spawn(&app.scene, {0, -0.5, 0})
  physics.create_body(&phys, {0, -0.5, 0}, collider = physics.BoxCollider{half_extents = {30.0, 0.5, 12.0}}, user = world.Handle(ground))
  ground_visual := world.spawn_child(&app.scene, ground)
  render.attach(&app.renderer, ground_visual.index, render.MeshAttachment{handle = cube_mesh, material = app.renderer.builtin_materials[.GRAY], cast_shadow = true})
  world.scale_xyz(&app.scene, ground_visual, 30.0, 0.5, 12.0)

  wall_colors := [WALL_COUNT]render.Color{.RED, .YELLOW, .GREEN}
  for i in 0 ..< WALL_COUNT {
    half_thick := wall_heights[i] * 0.5
    wall_z := (f32(i) - f32(WALL_COUNT - 1) * 0.5) * WALL_SPACING
    wall_pos := [3]f32{WALL_X, 1.5, wall_z}
    wall_nodes[i] = world.spawn(&app.scene, wall_pos)
    physics.create_body(&phys, wall_pos, collider = physics.BoxCollider{half_extents = {half_thick, 1.5, 2.0}}, user = world.Handle(wall_nodes[i]))
    wall_visual := world.spawn_child(&app.scene, wall_nodes[i])
    render.attach(&app.renderer, wall_visual.index, render.MeshAttachment{handle = cube_mesh, material = app.renderer.builtin_materials[wall_colors[i]], cast_shadow = true})
    world.scale_xyz(&app.scene, wall_visual, half_thick, 1.5, 2.0)
  }

  bullet_node = world.spawn(&app.scene, START_POS)
  bullet_body = physics.create_body(&phys, START_POS, mass = BULLET_MASS, collider = physics.SphereCollider{radius = BULLET_RADIUS}, user = world.Handle(bullet_node))
  bullet_visual := world.spawn_child(&app.scene, bullet_node)
  render.attach(&app.renderer, bullet_visual.index, render.primitive(&app.renderer, .SPHERE, .CYAN))
  world.scale_xyz(&app.scene, bullet_visual, BULLET_RADIUS, BULLET_RADIUS, BULLET_RADIUS)
  body := physics.get_body(&phys, bullet_body)
  body.linear_damping = 0
  body.angular_damping = 0
  body.restitution = 0.1
  body.friction = 0.2
  return true
}

target_z :: proc() -> f32 {
  return (f32(target_wall) - f32(WALL_COUNT - 1) * 0.5) * WALL_SPACING
}

fire_bullet :: proc(app: ^App) {
  physics.set_pose(&phys, bullet_body, {START_POS.x, START_POS.y, target_z()}, linalg.QUATERNIONF32_IDENTITY)
  physics.set_velocity(&phys, bullet_body, {f32(bullet_speed), 0, 0})
  physics.set_angular_velocity(&phys, bullet_body, {})
}

update :: proc(app: ^App, dt: f32) {
  platform.read_input(&app.window, &app.input)
  input.feed_microui(&app.input, render.debug_ctx(&app.renderer))
  if !app.input.mouse_captured {
    if input.mouse_down(&app.input, .LEFT) {
      app.yaw += app.input.mouse_delta.x * 0.02
      app.pitch = clamp(app.pitch + app.input.mouse_delta.y * 0.02, -1.5, 1.5)
    }
    app.dist = clamp(app.dist - app.input.scroll.y * 2, 1, 200)
  }
  render.main_camera_orbit(&app.renderer, app.yaw, app.pitch, app.dist)
  if auto_fire {
    auto_fire_timer += dt
    if auto_fire_timer >= 2.0 { auto_fire_timer = 0; fire_bullet(app) }
  }
  if body, ok := physics.get_body(&phys, bullet_body); ok && (body.position.x > 20.0 || body.position.x < -25.0) {
    physics.set_velocity(&phys, bullet_body, {})
    physics.set_pose(&phys, bullet_body, {START_POS.x, START_POS.y, target_z()}, body.rotation)
  }
  physics.step(&phys, dt)
  world.set_world_poses(&app.scene, physics.body_poses(&phys))
  world.update(&app.scene)
  render.stage_transforms(&app.renderer, world.changes(&app.scene))
  render.update(&app.renderer, dt)
}

frame :: proc(app: ^App) -> bool {
  platform.poll_events(&app.window)
  debug_ui(app)
  return render.frame(&app.renderer, platform.framebuffer_size(&app.window), platform.dpi_scale(&app.window))
}

debug_ui :: proc(app: ^App) {
  ctx := render.debug_ui(&app.renderer)
  if mu.window(ctx, "Bullet CCD", {700, 20, 280, 380}, {.NO_CLOSE}) {
    mu.layout_row(ctx, {-1}, 0)
    mu.label(ctx, "Target wall:")
    mu.layout_row(ctx, {90, 90, 90}, 0)
    if .SUBMIT in mu.button(ctx, "Red 0.05")   do target_wall = 0
    if .SUBMIT in mu.button(ctx, "Yellow 0.2") do target_wall = 1
    if .SUBMIT in mu.button(ctx, "Green 0.8")  do target_wall = 2

    mu.layout_row(ctx, {-1}, 0)
    mu.label(ctx, fmt.tprintf("Velocity: %.1f m/s", bullet_speed))
    mu.slider(ctx, &bullet_speed, 1.0, 400.0)
    mu.label(ctx, "CCD: ACTIVE (>=5 m/s threshold)" if bullet_speed >= 5.0 else "CCD: off (low velocity)")

    mu.layout_row(ctx, {130, -1}, 0)
    if .SUBMIT in mu.button(ctx, "Fire") do fire_bullet(app)
    mu.checkbox(ctx, "Auto-fire (2s)", &auto_fire)

    mu.layout_row(ctx, {-1}, 0)
    mu.label(ctx, "--- Last Frame Stats ---")
    perf := phys.last_perf
    mu.label(ctx, fmt.tprintf("CCD bodies tested: %d", perf.ccd_bodies_tested))
    mu.label(ctx, fmt.tprintf("CCD swept candidates: %d", perf.ccd_total_candidates))
    mu.label(ctx, fmt.tprintf("CCD time: %.3f ms", perf.ccd_ms))
    mu.label(ctx, fmt.tprintf("Contacts: %d", perf.contact_count))
    if body, ok := physics.get_body(&phys, bullet_body); ok {
      mu.label(ctx, fmt.tprintf("Bullet x: %.2f  vel: %.1f", body.position.x, linalg.length(body.velocity)))
    }
  }
}

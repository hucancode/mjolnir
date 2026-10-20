// User vertex and fragment shaders: a cartoon snake whose body is shaped on the GPU along the
// path its head slithers.
package main

import "mjolnir"
import "mjolnir/animation"
import "mjolnir/debugui"
import "mjolnir/input"
import "mjolnir/platform"
import "mjolnir/render"
import "mjolnir/world"
import "core:log"
import "core:math"
import "core:math/linalg"
import mu "vendor:microui"

SNAKE_LENGTH :: f32(6)
// the body hangs on this many points behind the neck, two halves to a param float
SPINE_POINTS :: 8
// the neck's path is remembered every TRAIL_STEP of travel
TRAIL_STEP :: f32(0.05)
// the tightest the snake can turn, as 1 / radius
MAX_CURVATURE :: f32(1.2)
// how far the head turns off its course toward where it is told to go
LOOK :: f32(0.9)
// the snake weaves WEAVE radians either side of its course, once every WAVELENGTH of travel
WEAVE :: f32(0.6)
WAVELENGTH :: f32(4)
ARENA :: f32(14)

App :: struct {
  window:   platform.Platform,
  scene:    world.World,
  renderer: render.Renderer,
  debug:    debugui.Context,
  input:    input.State,
  orbit:    render.Orbit,
  body:     world.NodeHandle,
  head:     world.NodeHandle,
  skin:     render.MaterialHandle,
  head_skin: render.MaterialHandle,
  focus:    [2]f32, // what the camera looks at, follows the neck loosely so the weave doesn't shake it
  heading:  f32,
  look:     f32,
  lean:     f32,
  speed:    f32,
  phase:    f32,
  goal:     [2]f32, // where auto move is heading
  goals:    int,
  trail:    animation.Trail([2]f32), // the neck's path on the ground, (x, z)
}

cruise_speed: mu.Real = 5.0
color: [3]mu.Real = {0.3, 0.75, 0.25}
auto_move := true

main :: proc() {
  context.logger = log.create_console_logger()
  app := new(App)
  w := &app.window
  if !platform.init(w, 1000, 700, "Cartoon Snake") do return
  if !render.init(&app.renderer, "Cartoon Snake", w.window, platform.framebuffer_size(w), platform.dpi_scale(w)) do return
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
  r := &app.renderer
  if !render.ready(r) do return .WAIT
  if !debugui.init(&app.debug, r, {1000, 700}) do return .FAIL
  render.camera_look_at(render.main_camera(r), {3, 6, 9}, {0, 0, 0})
  app.orbit = render.orbit_from_camera(render.main_camera(r), {0, 0, 0})

  body_shader, body_ok := render.material_shader_create(r, #load("snake_body." + render.SHADER_EXT), blend = .NONE)
  head_shader, head_ok := render.material_shader_create(r, #load("snake_head." + render.SHADER_EXT), blend = .NONE)
  if !body_ok || !head_ok do return .FAIL
  app.skin = render.material_create(r, render.make_material(.CUSTOM, shader = body_shader))
  app.head_skin = render.material_create(r, render.make_material(.CUSTOM, shader = head_shader))
  body := render.mesh_create(r, render.make_sphere(segments = 24, rings = 120, radius = SNAKE_LENGTH + 1))
  head := render.mesh_create(r, render.make_sphere(segments = 32, rings = 32))
  app.body = world.spawn(&app.scene)
  render.attach(r, render.SlotHandle(app.body.index), render.MeshAttachment{mesh = body, material = app.skin})
  app.head = world.spawn(&app.scene)
  render.attach(r, render.SlotHandle(app.head.index), render.MeshAttachment{mesh = head, material = app.head_skin})
  for side in ([2]f32{-1, 1}) {
    eye := world.spawn(&app.scene, {side * 0.27, 0.44, -0.92}, parent = app.head)
    render.attach(r, render.SlotHandle(eye.index), render.primitive(r, .SPHERE, .WHITE))
    world.scale(&app.scene, eye, 0.12)
    pupil := world.spawn(&app.scene, {side * 0.42, 0.12, -0.39}, parent = eye)
    render.attach(r, render.SlotHandle(pupil.index), render.primitive(r, .SPHERE, .BLACK))
    world.scale(&app.scene, pupil, 0.5)
  }
  animation.trail_init(&app.trail, {0, 0}, {0, 1}, SNAKE_LENGTH, TRAIL_STEP)

  grass := render.material_create(r, render.make_material(base_color_factor = {0.45, 0.7, 0.35, 1}, roughness_value = 0.9))
  ground := world.spawn(&app.scene)
  render.attach(r, render.SlotHandle(ground.index), render.primitive(r, .QUAD_XZ, grass, cast_shadow = false))
  world.scale(&app.scene, ground, ARENA + 4)
  for i in 0 ..< 6 {
    angle := f32(i) / 6 * math.TAU + 0.4
    rock := world.spawn(&app.scene, {math.cos(angle) * 9, 0.4, math.sin(angle) * 9})
    render.attach(r, render.SlotHandle(rock.index), render.primitive(r, .SPHERE, .GRAY))
    world.scale(&app.scene, rock, 0.8)
  }
  return .READY
}

shutdown :: proc(app: ^App) {
  animation.trail_destroy(&app.trail)
  world.shutdown(&app.scene)
  debugui.shutdown(&app.debug)
  render.shutdown(&app.renderer)
  platform.shutdown(&app.window)
  free(app)
}

should_close :: proc(app: ^App) -> bool {
  return platform.should_close(&app.window)
}

update :: proc(app: ^App, dt: f32) {
  render.lock(&app.renderer)
  defer render.unlock(&app.renderer)
  platform.read_input(&app.window, &app.input)
  debugui.feed(&app.debug, &app.input, &app.renderer)
  debug_ui(app)
  render.stage_overlay(&app.renderer, debugui.end(&app.debug))
  if !app.input.mouse_captured {
    drag := app.input.mouse_delta if input.mouse_down(&app.input, .LEFT) else 0
    render.orbit_drag(&app.orbit, drag, app.input.scroll.y)
  }
  steer(app, dt)
  pose(app)
  render.camera_orbit(render.main_camera(&app.renderer), app.orbit)
  world.update(&app.scene)
  render.stage_transforms(&app.renderer, world.changes(&app.scene))
  render.update(&app.renderer, dt)
}

// Turns the head toward where the keys point, seen from the camera, and slithers the neck along
// a course that weaves either side of the heading, recording where it went.
steer :: proc(app: ^App, dt: f32) {
  move: [2]f32
  if input.key_down(&app.input, .UP) || input.key_down(&app.input, .W) do move.y += 1
  if input.key_down(&app.input, .DOWN) || input.key_down(&app.input, .S) do move.y -= 1
  if input.key_down(&app.input, .RIGHT) || input.key_down(&app.input, .D) do move.x += 1
  if input.key_down(&app.input, .LEFT) || input.key_down(&app.input, .A) do move.x -= 1
  ahead := linalg.normalize0(render.camera_forward(render.main_camera(&app.renderer)).xz)
  want := ahead * move.y + [2]f32{-ahead.y, ahead.x} * move.x
  aim, target := f32(0), f32(0)
  if want != 0 {
    auto_move = false
    aim = wrap(math.atan2(-want.x, -want.y) - app.heading)
    target = f32(cruise_speed)
  } else if auto_move {
    if linalg.distance(app.trail.head, app.goal) < 2 {
      app.goals += 1
      app.goal = [2]f32{math.cos(f32(app.goals) * 2.4), math.sin(f32(app.goals) * 2.4)} * ARENA * (0.5 + 0.4 * math.mod(f32(app.goals) * 0.618, 1))
    }
    to := app.goal - app.trail.head
    aim = wrap(math.atan2(-to.x, -to.y) - app.heading)
    target = f32(cruise_speed)
  }
  app.speed += (target - app.speed) * min(dt * 4, 1)
  ds := app.speed * dt
  turn := clamp(aim, -MAX_CURVATURE * ds, MAX_CURVATURE * ds)
  app.heading = wrap(app.heading + turn)
  app.look += (clamp(aim - turn, -LOOK, LOOK) - app.look) * min(dt * 12, 1)
  app.lean += (clamp(turn / max(dt, 1e-4) * 0.12, -0.35, 0.35) - app.lean) * min(dt * 6, 1)

  app.phase = math.mod(app.phase + ds * math.TAU / WAVELENGTH, math.TAU)
  course := app.heading + WEAVE * math.sin(app.phase)
  neck := app.trail.head + [2]f32{-math.sin(course), -math.cos(course)} * ds
  if linalg.length(neck) > ARENA do neck = linalg.normalize(neck) * ARENA
  animation.trail_move(&app.trail, neck)
  app.focus += (neck - app.focus) * min(dt * 5, 1)
}

// Places the head and hangs the body behind the head along the neck's path.
pose :: proc(app: ^App) {
  yaw := app.heading + app.look + 0.5 * WEAVE * math.sin(app.phase)
  neck := app.trail.head
  world.translate(&app.scene, app.head, {neck.x, 0, neck.y})
  world.rotate(
    &app.scene,
    app.head,
    linalg.quaternion_angle_axis(yaw, [3]f32{0, 1, 0}) *
    linalg.quaternion_angle_axis(app.lean, [3]f32{0, 0, 1}),
  )
  app.orbit.target = {app.focus.x, 0.3, app.focus.y}

  head_skin := render.material(&app.renderer, app.head_skin)
  head_skin.base_color_factor = {f32(color.r), f32(color.g), f32(color.b), 1}

  world.translate(&app.scene, app.body, {neck.x, 0, neck.y})
  skin := render.material(&app.renderer, app.skin)
  skin.base_color_factor = head_skin.base_color_factor
  for i in 0 ..< SPINE_POINTS {
    p := animation.trail_sample(app.trail, f32(i + 1) * SNAKE_LENGTH / SPINE_POINTS) - neck
    // the z half is the float's top; off zero it never makes a denormal
    p.y = math.copy_sign(max(abs(p.y), 1e-3), p.y)
    skin.params[i / 4][i % 4] = transmute(f32)[2]f16{f16(p.x), f16(p.y)}
  }
}

wrap :: proc(angle: f32) -> f32 {
  return math.atan2(math.sin(angle), math.cos(angle))
}

frame :: proc(app: ^App) -> bool {
  platform.poll_events(&app.window)
  return render.frame(&app.renderer, platform.framebuffer_size(&app.window), platform.dpi_scale(&app.window))
}

debug_ui :: proc(app: ^App) {
  ctx := debugui.begin(&app.debug)
  if debugui.window(&app.debug, "Cartoon Snake", {20, 20, 260, 250}, {}, {.NO_CLOSE}) {
    mu.layout_row(ctx, {-1}, 0)
    mu.label(ctx, "WASD / arrows slither")
    mu.checkbox(ctx, "Auto move", &auto_move)
    mu.label(ctx, "Speed"); mu.slider(ctx, &cruise_speed, 2.0, 10.0)
    mu.label(ctx, "Skin")
    mu.layout_row(ctx, {74, 74, 74}, 0)
    mu.slider(ctx, &color.r, 0, 1)
    mu.slider(ctx, &color.g, 0, 1)
    mu.slider(ctx, &color.b, 0, 1)
  }
}

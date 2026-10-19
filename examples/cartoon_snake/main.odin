// User vertex and fragment shaders: a cartoon snake whose body is shaped on the GPU along the
// path its head slithers.
package main

import "../../mjolnir"
import "../../mjolnir/debugui"
import "../../mjolnir/input"
import "../../mjolnir/platform"
import "../../mjolnir/render"
import "../../mjolnir/world"
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
STRIKE_TIME :: f32(0.5)
STRIKE_REACH :: f32(0.7)
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
  eyes:     [2]world.NodeHandle,
  tongue:   world.NodeHandle,
  skin:     render.MaterialHandle,
  head_skin: render.MaterialHandle,
  neck:     [2]f32, // on the ground, (x, z)
  heading:  f32,
  look:     f32,
  lean:     f32,
  speed:    f32,
  phase:    f32,
  distance: f32,
  recorded: f32,
  history:  [int(SNAKE_LENGTH / TRAIL_STEP) + 2][2]f32, // the neck's path, newest first
  strike:   f32,
  clock:    f32,
}

cruise_speed: mu.Real = 2.5
color: [3]mu.Real = {0.3, 0.75, 0.25}

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

  when render.RENDER_BACKEND == "vulkan" {
    body_spirv, head_spirv, skin_spirv := #load("snake.vert.spv"), #load("snake_head.vert.spv"), #load("snake.frag.spv")
    body_wgsl, head_wgsl, skin_wgsl := "", "", ""
  } else {
    body_spirv, head_spirv, skin_spirv := ([]u8)(nil), ([]u8)(nil), ([]u8)(nil)
    body_wgsl, head_wgsl, skin_wgsl := #load("snake_vert.wgsl", string), #load("snake_head_vert.wgsl", string), #load("snake_frag.wgsl", string)
  }
  body_shader, body_ok := render.material_shader_create(r, skin_spirv, skin_wgsl, blend = .NONE, vert_spirv = body_spirv, vert_wgsl = body_wgsl)
  head_shader, head_ok := render.material_shader_create(r, skin_spirv, skin_wgsl, blend = .NONE, vert_spirv = head_spirv, vert_wgsl = head_wgsl)
  if !body_ok || !head_ok do return .FAIL
  app.skin = render.material_create(r, render.make_material(.CUSTOM, shader = body_shader))
  app.head_skin = render.material_create(r, render.make_material(.CUSTOM, shader = head_shader))
  body := render.mesh_create(r, render.make_sphere(segments = 24, rings = 120, radius = SNAKE_LENGTH + 1))
  head := render.mesh_create(r, render.make_sphere(segments = 32, rings = 32))
  app.body = world.spawn(&app.scene)
  render.attach(r, render.SlotHandle(app.body.index), render.MeshAttachment{mesh = body, material = app.skin})
  app.head = world.spawn(&app.scene)
  render.attach(r, render.SlotHandle(app.head.index), render.MeshAttachment{mesh = head, material = app.head_skin})
  for side, i in ([2]f32{-1, 1}) {
    eye := world.spawn(&app.scene, {side * 0.27, 0.44, -0.92}, parent = app.head)
    render.attach(r, render.SlotHandle(eye.index), render.primitive(r, .SPHERE, .WHITE))
    pupil := world.spawn(&app.scene, {side * 0.42, 0.12, -0.39}, parent = eye)
    render.attach(r, render.SlotHandle(pupil.index), render.primitive(r, .SPHERE, .BLACK))
    world.scale(&app.scene, pupil, 0.5)
    app.eyes[i] = eye
  }
  app.tongue = world.spawn(&app.scene, parent = app.head)
  render.attach(r, render.SlotHandle(app.tongue.index), render.primitive(r, .CUBE, .RED))
  for &p, i in app.history do p = {0, f32(i) * TRAIL_STEP}
  app.strike = STRIKE_TIME

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
    aim = wrap(math.atan2(-want.x, -want.y) - app.heading)
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
  before := app.neck
  app.neck += [2]f32{-math.sin(course), -math.cos(course)} * ds
  if linalg.length(app.neck) > ARENA do app.neck = linalg.normalize(app.neck) * ARENA
  moved := linalg.length(app.neck - before)
  start := app.distance
  app.distance += moved
  for app.recorded + TRAIL_STEP <= app.distance {
    app.recorded += TRAIL_STEP
    copy(app.history[1:], app.history[:])
    app.history[0] = linalg.lerp(before, app.neck, (app.recorded - start) / moved)
  }

  if input.key_pressed(&app.input, .SPACE) && app.strike >= STRIKE_TIME do app.strike = 0
  app.strike = min(app.strike + dt, STRIKE_TIME)
  app.clock += dt
}

// Places the head, eyes and tongue, and hangs the body behind the head along the neck's path.
pose :: proc(app: ^App) {
  s := app.strike / STRIKE_TIME
  lunge := math.smoothstep(f32(0), 0.25, s) * (1 - math.smoothstep(f32(0.35), 1, s))
  yaw := app.heading + app.look + 0.5 * WEAVE * math.sin(app.phase)
  neck := app.neck + [2]f32{-math.sin(yaw), -math.cos(yaw)} * lunge * STRIKE_REACH
  world.translate(&app.scene, app.head, {neck.x, 0, neck.y})
  world.rotate(
    &app.scene,
    app.head,
    linalg.quaternion_angle_axis(yaw, [3]f32{0, 1, 0}) *
    linalg.quaternion_angle_axis(app.lean, [3]f32{0, 0, 1}) *
    linalg.quaternion_angle_axis(0.25 * lunge, [3]f32{1, 0, 0}),
  )
  app.orbit.target = {neck.x, 0.3, neck.y}

  blink := f32(0.15) if math.mod(app.clock, 3.3) < 0.12 else 1
  for eye in app.eyes do world.scale(&app.scene, eye, 0.12, 0.12 * blink, 0.12)
  flick := max(math.sin(math.PI * min(math.mod(app.clock, 2.6) / 0.4, 1)), lunge)
  reach := 0.35 * flick
  world.set_visible(&app.scene, app.tongue, reach > 0.01)
  world.translate(&app.scene, app.tongue, {0, 0.27, -1.2 - reach / 2})
  world.scale(&app.scene, app.tongue, 0.025, 0.01, max(reach, 0.01) / 2)

  head_skin := render.material(&app.renderer, app.head_skin)
  head_skin.base_color_factor = {f32(color.r), f32(color.g), f32(color.b), 1}
  head_skin.params[0].x = 0.8 * lunge

  world.translate(&app.scene, app.body, {neck.x, 0, neck.y})
  skin := render.material(&app.renderer, app.skin)
  skin.base_color_factor = head_skin.base_color_factor
  for i in 0 ..< SPINE_POINTS {
    p := point_behind(app, f32(i + 1) * SNAKE_LENGTH / SPINE_POINTS) - neck
    // the z half is the float's top; off zero it never makes a denormal
    p.y = math.copy_sign(max(abs(p.y), 1e-3), p.y)
    skin.params[i / 4][i % 4] = transmute(f32)[2]f16{f16(p.x), f16(p.y)}
  }
}

// Where the neck was `back` of travel ago, blending between recorded steps.
point_behind :: proc(app: ^App, back: f32) -> [2]f32 {
  lag := app.distance - app.recorded
  if back <= lag do return linalg.lerp(app.neck, app.history[0], back / max(lag, 1e-6))
  at := (back - lag) / TRAIL_STEP
  i := min(int(at), len(app.history) - 2)
  return linalg.lerp(app.history[i], app.history[i + 1], at - f32(i))
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
  if debugui.window(&app.debug, "Cartoon Snake", {20, 20, 260, 220}, {}, {.NO_CLOSE}) {
    mu.layout_row(ctx, {-1}, 0)
    mu.label(ctx, "WASD / arrows slither, Space strikes")
    mu.label(ctx, "Speed"); mu.slider(ctx, &cruise_speed, 0.5, 5)
    mu.label(ctx, "Skin")
    mu.layout_row(ctx, {74, 74, 74}, 0)
    mu.slider(ctx, &color.r, 0, 1)
    mu.slider(ctx, &color.g, 0, 1)
    mu.slider(ctx, &color.b, 0, 1)
  }
}

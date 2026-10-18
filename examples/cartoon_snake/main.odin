// A user vertex and fragment shader: a cartoon snake that slithers by itself as it moves.
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
SNAKE_RADIUS :: f32(0.55)
TURN_SPEED :: f32(2.2)
// the tightest turn, as 1 / radius
MAX_CURVATURE :: f32(0.5)
// the head's heading is remembered every TRAIL_STEP of travel; the shader bends the body along the
// last TRAIL_SAMPLES stretches of it, each turn an i8 of TRAIL_SCALE radians, packed three to a float
TRAIL_STEP :: f32(0.05)
TRAIL_SAMPLES :: 15
TRAIL_SCALE :: MAX_CURVATURE * SNAKE_LENGTH / TRAIL_SAMPLES / 127
// how fast steering takes hold, per unit of travel: the head's bend builds up over about 1 / this
CURVATURE_EASE :: f32(3)
ARENA :: f32(14)

App :: struct {
  window:    platform.Platform,
  scene:     world.World,
  renderer:  render.Renderer,
  debug:     debugui.Context,
  input:     input.State,
  orbit:     render.Orbit,
  snake:     world.NodeHandle,
  skin:      render.MaterialHandle,
  position:  [3]f32, // the head
  heading:   f32,
  speed:     f32,
  distance:  f32,
  curvature: f32,
  recorded:  f32,
  history:   [int(SNAKE_LENGTH / TRAIL_STEP) + 2]f32, // heading, newest first
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
  if !debugui.init(&app.debug, r) do return .FAIL
  render.camera_look_at(render.main_camera(r), {0, 5, 8}, {0, 0, 0})
  app.orbit = render.orbit_from_camera(render.main_camera(r), {0, 0, 0})

  when render.RENDER_BACKEND == "vulkan" {
    vert_spirv, frag_spirv, vert_wgsl, frag_wgsl := #load("snake.vert.spv"), #load("snake.frag.spv"), "", ""
  } else {
    vert_spirv, frag_spirv, vert_wgsl, frag_wgsl := ([]u8)(nil), ([]u8)(nil), #load("snake_vert.wgsl", string), #load("snake_frag.wgsl", string)
  }
  shader, ok := render.material_shader_create(r, frag_spirv, frag_wgsl, blend = .NONE, vert_spirv = vert_spirv, vert_wgsl = vert_wgsl)
  if !ok do return .FAIL
  app.skin = render.material_create(r, render.make_material(.CUSTOM, shader = shader))
  body := render.mesh_create(r, render.make_sphere(segments = 24, rings = 120, radius = SNAKE_LENGTH / 2))
  app.snake = world.spawn(&app.scene)
  render.attach(r, render.SlotHandle(app.snake.index), render.MeshAttachment{mesh = body, material = app.skin})

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
  debugui.feed(&app.debug, &app.input)
  debug_ui(app)
  render.stage_overlay(&app.renderer, debugui.end(&app.debug))
  if !app.input.mouse_captured {
    drag := app.input.mouse_delta if input.mouse_down(&app.input, .LEFT) else 0
    render.orbit_drag(&app.orbit, drag, app.input.scroll.y)
  }
  steer(app, dt)
  app.orbit.target = app.position
  render.camera_orbit(render.main_camera(&app.renderer), app.orbit)
  world.update(&app.scene)
  render.stage_transforms(&app.renderer, world.changes(&app.scene))
  render.update(&app.renderer, dt)
}

steer :: proc(app: ^App, dt: f32) {
  forward := input.key_down(&app.input, .UP) || input.key_down(&app.input, .W)
  turn := f32(0)
  if input.key_down(&app.input, .LEFT) || input.key_down(&app.input, .A) do turn += 1
  if input.key_down(&app.input, .RIGHT) || input.key_down(&app.input, .D) do turn -= 1
  target := f32(cruise_speed) if forward else 0
  app.speed += (target - app.speed) * min(dt * 3, 1)
  tightest := min(MAX_CURVATURE, TURN_SPEED / max(app.speed, 0.01))
  // eased over distance, not time, so a change in steering is spread over the body at any speed
  ds := app.speed * dt
  before, heading := app.curvature, app.heading
  app.curvature += (turn * tightest - app.curvature) * min(ds * CURVATURE_EASE, 1)
  app.heading += (before + app.curvature) / 2 * ds
  mid := (heading + app.heading) / 2
  app.position += [3]f32{-math.sin(mid), 0, -math.cos(mid)} * ds
  if linalg.length(app.position) > ARENA do app.position = linalg.normalize(app.position) * ARENA
  start := app.distance
  app.distance += ds
  for app.recorded + TRAIL_STEP <= app.distance {
    app.recorded += TRAIL_STEP
    copy(app.history[1:], app.history[:])
    app.history[0] = linalg.lerp(heading, app.heading, (app.recorded - start) / ds)
  }
  // the node sits mid-body; the shader hangs the body behind the head from there
  back := [3]f32{math.sin(app.heading), 0, math.cos(app.heading)}
  world.translate(&app.scene, app.snake, app.position + back * (SNAKE_LENGTH / 2))
  world.rotate(&app.scene, app.snake, app.heading)

  skin := render.material(&app.renderer, app.skin)
  skin.base_color_factor = {f32(color.r), f32(color.g), f32(color.b), 1}
  size := u32(transmute(u16)f16(SNAKE_LENGTH)) | u32(transmute(u16)f16(SNAKE_RADIUS)) << 16
  skin.params[0] = {app.distance, app.speed, transmute(f32)size, trail(app, 0)}
  skin.params[1] = {trail(app, 1), trail(app, 2), trail(app, 3), trail(app, 4)}
}

// The head's heading when it was `back` of travel ago, blending between recorded steps.
heading_behind :: proc(app: ^App, back: f32) -> f32 {
  lag := app.distance - app.recorded
  if back <= lag do return linalg.lerp(app.heading, app.history[0], back / max(lag, 1e-6))
  at := (back - lag) / TRAIL_STEP
  i := int(at)
  return linalg.lerp(app.history[i], app.history[i + 1], at - f32(i))
}

// How far the body turns over each of its TRAIL_SAMPLES stretches, a byte each, three to a float
// whose fixed top byte keeps it a finite number. Rounding is carried on so it never adds up.
trail :: proc(app: ^App, i: int) -> f32 {
  turned: f32
  for n in 0 ..< i * 3 {
    turned += f32(trail_turn(app, n, turned)) * TRAIL_SCALE
  }
  word := u32(0x3F000000)
  for k in 0 ..< 3 {
    q := trail_turn(app, i * 3 + k, turned)
    turned += f32(q) * TRAIL_SCALE
    word |= u32(transmute(u8)q) << u32(k * 8)
  }
  return transmute(f32)word
}

trail_turn :: proc(app: ^App, n: int, turned: f32) -> i8 {
  end := app.heading - heading_behind(app, f32(n + 1) * SNAKE_LENGTH / TRAIL_SAMPLES)
  return i8(clamp(math.round((end - turned) / TRAIL_SCALE), -127, 127))
}

frame :: proc(app: ^App) -> bool {
  platform.poll_events(&app.window)
  return render.frame(&app.renderer, platform.framebuffer_size(&app.window), platform.dpi_scale(&app.window))
}

debug_ui :: proc(app: ^App) {
  ctx := debugui.begin(&app.debug)
  if mu.window(ctx, "Cartoon Snake", {20, 20, 260, 220}, {.NO_CLOSE}) {
    mu.layout_row(ctx, {-1}, 0)
    mu.label(ctx, "Up / W slithers, Left / Right turn")
    mu.label(ctx, "Speed"); mu.slider(ctx, &cruise_speed, 0.5, 5)
    mu.label(ctx, "Skin")
    mu.layout_row(ctx, {74, 74, 74}, 0)
    mu.slider(ctx, &color.r, 0, 1)
    mu.slider(ctx, &color.g, 0, 1)
    mu.slider(ctx, &color.b, 0, 1)
  }
}

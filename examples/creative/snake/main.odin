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
import "mjolnir/geometry"

SNAKE_LENGTH :: f32(6)
SPINE_POINTS :: 8
CHAIN_STEP :: f32(0.05)
MAX_CURVATURE :: f32(1.2)
LOOK :: f32(0.9)
WEAVE :: f32(0.6)
WAVELENGTH :: f32(4)
ARENA :: f32(14)

App :: struct {
  platform:  platform.Platform,
  scene:     world.World,
  renderer:  render.Renderer,
  debug:     debugui.Context,
  input:     input.State,
  orbit:     render.Orbit,
  body:      world.NodeHandle,
  head:      world.NodeHandle,
  skin:      render.MaterialHandle,
  head_skin: render.MaterialHandle,
  focus:     [2]f32,
  heading:   f32,
  look:      f32,
  lean:      f32,
  speed:     f32,
  phase:     f32,
  goal:      [2]f32,
  goals:     int,
  chain:     animation.Chain([2]f32),
}

cruise_speed: f32 = 5.0
color: [3]f32 = {0.3, 0.75, 0.25}
auto_move := true

main :: proc() {
  context.logger = log.create_console_logger()
  app := new(App)
  if !platform.init(&app.platform, 1280, 720, "Cartoon Snake") do return
  if !render.init(&app.renderer, app.platform.window) do return
  if !world.init(&app.scene) do return
  mjolnir.run(
    mjolnir.Loop(App) {
      app = app,
      setup = setup,
      shutdown = shutdown,
      update = update,
      render = draw,
    },
  )
}

setup :: proc(app: ^App) -> mjolnir.Setup {
  r := &app.renderer
  if !render.ready(r) do return .WAIT
  if !debugui.init(&app.debug, r) do return .FAIL
  app.orbit = render.make_orbit({3, 6, 9}, {0, 0, 0})
  render.camera_orbit(render.main_camera(r), app.orbit)

  body_shader, body_ok := render.material_shader_create(r, #load("snake_body." + render.SHADER_EXT), blend = .NONE)
  head_shader, head_ok := render.material_shader_create(r, #load("snake_head." + render.SHADER_EXT), blend = .NONE)
  if !body_ok || !head_ok do return .FAIL
  app.skin = render.material_create(r, render.make_material(.CUSTOM, shader = body_shader))
  app.head_skin = render.material_create(r, render.make_material(.CUSTOM, shader = head_shader))
  body := render.mesh_create(r, geometry.make_sphere(segments = 24, rings = 120, radius = SNAKE_LENGTH + 1))
  head := render.mesh_create(r, geometry.make_sphere(segments = 32, rings = 32))
  app.body = world.spawn(&app.scene)
  render.attach(r, app.body, render.MeshAttachment{mesh = body, material = app.skin})
  app.head = world.spawn(&app.scene)
  render.attach(r, app.head, render.MeshAttachment{mesh = head, material = app.head_skin})
  for side in ([2]f32{-1, 1}) {
    eye := mjolnir.spawn_mesh(&app.scene, r, render.primitive(r, .SPHERE, .WHITE), {side * 0.27, 0.44, -0.92}, parent = app.head, scale = 0.12)
    mjolnir.spawn_mesh(&app.scene, r, render.primitive(r, .SPHERE, .BLACK), {side * 0.42, 0.12, -0.39}, parent = eye, scale = 0.5)
  }
  animation.chain_init(&app.chain, {0, 0}, {0, 1}, SNAKE_LENGTH, CHAIN_STEP)

  grass := render.material_create(r, render.make_material(base_color_factor = {0.45, 0.7, 0.35, 1}, roughness_value = 0.9))
  mjolnir.spawn_mesh(&app.scene, r, render.primitive(r, .QUAD_XZ, grass, cast_shadow = false), scale = ARENA + 4)
  for i in 0 ..< 6 {
    angle := f32(i) / 6 * math.TAU + 0.4
    mjolnir.spawn_mesh(&app.scene, r, render.primitive(r, .SPHERE, .GRAY), {math.cos(angle) * 9, 0.4, math.sin(angle) * 9}, scale = 0.8)
  }
  return .READY
}

shutdown :: proc(app: ^App) {
  animation.chain_destroy(&app.chain)
  world.shutdown(&app.scene)
  debugui.shutdown(&app.debug)
  render.shutdown(&app.renderer)
  platform.shutdown(&app.platform)
  free(app)
}

update :: proc(app: ^App, dt: f32) {
  render.lock(&app.renderer)
  defer render.unlock(&app.renderer)
  platform.read_input(&app.platform, &app.input)
  debugui.feed(&app.debug, &app.input, &app.renderer)
  debug_ui(app)
  render.stage_overlay(&app.renderer, debugui.end(&app.debug))
  steer(app, dt)
  pose(app)
  render.orbit_drag(&app.orbit, render.main_camera(&app.renderer), &app.input)
  mjolnir.update(&app.scene, &app.renderer, dt)
}

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
    target = cruise_speed
  } else if auto_move {
    if linalg.distance(app.chain.head, app.goal) < 2 {
      app.goals += 1
      app.goal = [2]f32{math.cos(f32(app.goals) * 2.4), math.sin(f32(app.goals) * 2.4)} * ARENA * (0.5 + 0.4 * math.mod(f32(app.goals) * 0.618, 1))
    }
    to := app.goal - app.chain.head
    aim = wrap(math.atan2(-to.x, -to.y) - app.heading)
    target = cruise_speed
  }
  app.speed += (target - app.speed) * min(dt * 4, 1)
  ds := app.speed * dt
  turn := clamp(aim, -MAX_CURVATURE * ds, MAX_CURVATURE * ds)
  app.heading = wrap(app.heading + turn)
  app.look += (clamp(aim - turn, -LOOK, LOOK) - app.look) * min(dt * 12, 1)
  app.lean += (clamp(turn / max(dt, 1e-4) * 0.12, -0.35, 0.35) - app.lean) * min(dt * 6, 1)

  app.phase = math.mod(app.phase + ds * math.TAU / WAVELENGTH, math.TAU)
  course := app.heading + WEAVE * math.sin(app.phase)
  neck := app.chain.head + [2]f32{-math.sin(course), -math.cos(course)} * ds
  if linalg.length(neck) > ARENA do neck = linalg.normalize(neck) * ARENA
  animation.chain_move(&app.chain, neck)
  app.focus += (neck - app.focus) * min(dt * 5, 1)
}

pose :: proc(app: ^App) {
  yaw := app.heading + app.look + 0.5 * WEAVE * math.sin(app.phase)
  neck := app.chain.head
  world.translate(&app.scene, app.head, {neck.x, 0, neck.y})
  world.rotate(
    &app.scene,
    app.head,
    linalg.quaternion_angle_axis(yaw, [3]f32{0, 1, 0}) *
    linalg.quaternion_angle_axis(app.lean, [3]f32{0, 0, 1}),
  )
  app.orbit.target = {app.focus.x, 0.3, app.focus.y}

  head_skin := render.material(&app.renderer, app.head_skin)
  head_skin.base_color_factor = {color.r, color.g, color.b, 1}

  world.translate(&app.scene, app.body, {neck.x, 0, neck.y})
  skin := render.material(&app.renderer, app.skin)
  skin.base_color_factor = head_skin.base_color_factor
  for i in 0 ..< SPINE_POINTS {
    p := animation.chain_sample(app.chain, f32(i + 1) * SNAKE_LENGTH / SPINE_POINTS) - neck
    p.y = math.copy_sign(max(abs(p.y), 1e-3), p.y)
    skin.params[i / 4][i % 4] = transmute(f32)[2]f16{f16(p.x), f16(p.y)}
  }
}

wrap :: proc(angle: f32) -> f32 {
  return math.atan2(math.sin(angle), math.cos(angle))
}

draw :: proc(app: ^App) -> bool {
  return mjolnir.frame(&app.platform, &app.renderer)
}

debug_ui :: proc(app: ^App) {
  ctx := debugui.begin(&app.debug)
  if debugui.window(&app.debug, "Cartoon Snake", {20, 20, 260, 250}, {}) {
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

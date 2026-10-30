// Point and spot lights, the sun + shadows.
package main

import "core:fmt"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:math/rand"
import mu "vendor:microui"
import "mjolnir"
import "mjolnir/debugui"
import "mjolnir/input"
import "mjolnir/platform"
import "mjolnir/render"
import "mjolnir/world"

App :: struct {
  platform:        platform.Platform,
  scene:           world.World,
  renderer:        render.Renderer,
  debug:           debugui.Context,
  input:           input.State,
  orbit:           render.Orbit,
  lights:          [dynamic]MovingLight,
  marker_material: render.MaterialHandle,
  elapsed:         f32,
  groups:          [LightKind]LightGroup,
  sun:             render.LightHandle,
  sun_node:        world.NodeHandle,
  sun_enabled:     bool,
}

LightKind :: enum {
  POINT,
  SPOT,
}

LightGroup :: struct {
  enabled:   bool,
  intensity: f32,
  radius:    f32,
  cone_deg:  f32,
}

MovingLight :: struct {
  node:  world.NodeHandle,
  light: render.LightHandle,
  kind:  LightKind,
  color: [3]f32,
  base:  [3]f32,
  amp:   [3]f32,
  freq:  [3]f32,
  phase: [3]f32,
}

STARTUP_LIGHTS :: 3
MARKER_SCALE :: 0.15
MIN_LIGHT_HEIGHT :: 0.5
SPOT_TARGET :: [3]f32{0, 0.5, 0}

main :: proc() {
  context.logger = log.create_console_logger()
  rand.reset(1)
  app := new(App)
  if !platform.init(&app.platform, 1280, 720, "Lights") do return
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
  if !render.ready(&app.renderer) do return .WAIT
  if !debugui.init(&app.debug, &app.renderer) do return .FAIL
  app.orbit = render.make_orbit({9, 8, 9}, {0, 1, 0})
  app.renderer.ibl_intensity = 0.3

  mjolnir.spawn(&app.scene, &app.renderer, render.primitive(&app.renderer, .QUAD_XZ, .GRAY, cast_shadow = false), scale = 10.0)

  for x in 0 ..< 3 do for z in 0 ..< 3 {
    color: render.Color
    switch (x + z) % 3 {
    case 0: color = .WHITE
    case 1: color = .RED
    case 2: color = .CYAN
    }
    mjolnir.spawn(&app.scene, &app.renderer, render.primitive(&app.renderer, .SPHERE, color), {f32(x - 1) * 2.5, 0.7, f32(z - 1) * 2.5}, scale = 0.7)
  }
  mjolnir.spawn(&app.scene, &app.renderer, render.primitive(&app.renderer, .CUBE, .YELLOW), {0, 1.5, 0}, scale = 0.6)

  app.sun = render.light_create(&app.renderer, render.make_directional_light(shadow_distance = 12))
  app.sun_node = mjolnir.spawn(&app.scene, &app.renderer, app.sun, rotation = linalg.quaternion_from_forward_and_up([3]f32{-6, -10, -6}, [3]f32{0, 1, 0}))
  app.sun_enabled = true
  app.groups = {.POINT = {true, 25, 20, 0}, .SPOT = {true, 25, 20, 28}}

  app.marker_material = render.material_create(&app.renderer, render.make_material(emissive_factor = 4.0))

  for i in 0 ..< STARTUP_LIGHTS do spawn_light(app, .SPOT if i == STARTUP_LIGHTS - 1 else .POINT)
  log.info("Lights: P spawns a point light, O a spot light, DELETE removes a random one")
  return .READY
}

shutdown :: proc(app: ^App) {
  delete(app.lights)
  world.shutdown(&app.scene)
  debugui.shutdown(&app.debug)
  render.shutdown(&app.renderer)
  platform.shutdown(&app.platform)
  free(app)
}

spawn_light :: proc(app: ^App, kind: LightKind) {
  l := MovingLight {
    kind  = kind,
    color = random_color(),
  }
  base_y: [2]f32 = {1.5, 3.5} if kind == .POINT else {4.0, 6.0}
  l.base = {rand.float32_range(-5, 5), rand.float32_range(base_y.x, base_y.y), rand.float32_range(-5, 5)}
  for i in 0 ..< 3 {
    l.amp[i] = rand.float32_range(0.5, 3.0)
    l.freq[i] = rand.float32_range(0.3, 1.5)
    l.phase[i] = rand.float32_range(0, 2 * math.PI)
  }
  l.amp.y = min(l.amp.y, l.base.y - MIN_LIGHT_HEIGHT)
  ok: bool
  l.light, ok = render.light_create(&app.renderer, light_settings(app, l))
  if !ok do return
  l.node = mjolnir.spawn(&app.scene, &app.renderer, l.light, light_position(l, app.elapsed))
  mjolnir.spawn(&app.scene, &app.renderer, render.primitive(&app.renderer, .CUBE, app.marker_material, cast_shadow = false), parent = l.node, scale = MARKER_SCALE)
  append(&app.lights, l)
}

remove_random_light :: proc(app: ^App) {
  if len(app.lights) == 0 do return
  i := rand.int_max(len(app.lights))
  world.destroy(&app.scene, app.lights[i].node)
  render.destroy(&app.renderer, app.lights[i].light)
  unordered_remove(&app.lights, i)
}

random_color :: proc() -> [3]f32 {
  h := rand.float32() * 6
  x := 1 - abs(math.mod(h, 2) - 1)
  switch int(h) {
  case 0: return {1, x, 0}
  case 1: return {x, 1, 0}
  case 2: return {0, 1, x}
  case 3: return {0, x, 1}
  case 4: return {x, 0, 1}
  }
  return {1, 0, x}
}

light_position :: proc(l: MovingLight, t: f32) -> [3]f32 {
  return l.base + l.amp * [3]f32{math.sin(l.freq.x * t + l.phase.x), math.sin(l.freq.y * t + l.phase.y), math.sin(l.freq.z * t + l.phase.z)}
}

light_settings :: proc(app: ^App, l: MovingLight) -> render.Light {
  g := app.groups[l.kind]
  if l.kind == .SPOT do return render.make_spot_light(l.color, g.intensity, g.radius, math.to_radians(g.cone_deg))
  return render.make_point_light(l.color, g.intensity, g.radius)
}

apply_light_settings :: proc(app: ^App) {
  world.set_visible(&app.scene, app.sun_node, app.sun_enabled)
  for l in app.lights {
    world.set_visible(&app.scene, l.node, app.groups[l.kind].enabled)
    render.light(&app.renderer, l.light)^ = light_settings(app, l)
  }
}

update :: proc(app: ^App, dt: f32) {
  render.lock(&app.renderer)
  platform.read_input(&app.platform, &app.input)
  debug_ui(app)
  mjolnir.orbit_drag(&app.orbit, render.main_camera(&app.renderer), &app.input)
  if input.key_pressed(&app.input, .P) do spawn_light(app, .POINT)
  if input.key_pressed(&app.input, .O) do spawn_light(app, .SPOT)
  if input.key_pressed(&app.input, .DELETE) do remove_random_light(app)

  app.elapsed += dt
  for l in app.lights {
    pos := light_position(l, app.elapsed)
    world.translate(&app.scene, l.node, pos)
    if l.kind == .SPOT {
      dir := linalg.normalize(SPOT_TARGET - pos)
      world.rotate(&app.scene, l.node, linalg.quaternion_between_two_vector3(-linalg.VECTOR3F32_Z_AXIS, dir))
    }
  }
  apply_light_settings(app)
  mjolnir.update(&app.scene, &app.renderer, dt)
}

draw :: proc(app: ^App) -> bool {
  return mjolnir.frame(&app.platform, &app.renderer)
}

debug_ui :: proc(app: ^App) {
  ctx := debugui.begin(&app.debug, &app.input, &app.renderer)
  defer debugui.end(&app.debug, &app.renderer)
  if debugui.window(&app.debug, "Lights", {20, 20, 280, 480}) {
    point_count, spot_count: int
    for l in app.lights {
      if l.kind == .POINT do point_count += 1
      else do spot_count += 1
    }
    mu.layout_row(ctx, {-1}, 0)
    mu.label(ctx, fmt.tprintf("%d point, %d spot", point_count, spot_count))
    mu.layout_row(ctx, {85, 85, -1}, 0)
    if .SUBMIT in mu.button(ctx, "+Point [P]") do spawn_light(app, .POINT)
    if .SUBMIT in mu.button(ctx, "+Spot [O]") do spawn_light(app, .SPOT)
    if .SUBMIT in mu.button(ctx, "Remove [Del]") do remove_random_light(app)
    light_block(ctx, "Sun light", &app.sun_enabled, &render.light(&app.renderer, app.sun).intensity, 5, nil, nil)
    point, spot := &app.groups[.POINT], &app.groups[.SPOT]
    light_block(ctx, "Point lights", &point.enabled, &point.intensity, 500, &point.radius, nil)
    light_block(ctx, "Spot lights", &spot.enabled, &spot.intensity, 500, &spot.radius, &spot.cone_deg)
  }
}

light_block :: proc(ctx: ^mu.Context, name: string, enabled: ^bool, intensity: ^f32, max_intensity: f32, radius: ^f32, cone: ^f32) {
  mu.layout_row(ctx, {-1}, 0)
  mu.checkbox(ctx, name, enabled)
  mu.label(ctx, "Intensity:")
  mu.slider(ctx, intensity, 0.0, max_intensity)
  if radius != nil {
    mu.label(ctx, "Range:")
    mu.slider(ctx, radius, 1.0, 30.0)
  }
  if cone != nil {
    mu.label(ctx, "Cone angle")
    mu.slider(ctx, cone, 5.0, 80.0)
  }
}

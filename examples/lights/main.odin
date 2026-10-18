// Point, spot, directional lights + shadows.
package main

import "../../mjolnir"
import "../../mjolnir/debugui"
import "../../mjolnir/input"
import "../../mjolnir/platform"
import "../../mjolnir/render"
import "../../mjolnir/world"
import "core:fmt"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:math/rand"
import mu "vendor:microui"

App :: struct {
  window:          platform.Platform,
  scene:           world.World,
  renderer:        render.Renderer,
  debug:           debugui.Context,
  input:           input.State,
  orbit:           render.Orbit,
  sun_node:        world.NodeHandle,
  sun:             render.LightHandle,
  lights:          [dynamic]MovingLight,
  marker_material: render.MaterialHandle,
  elapsed:         f32,
}

LightKind :: enum {
  POINT,
  SPOT,
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

dir_enabled: bool = true
dir_intensity: mu.Real = 1.0

point_enabled: bool = true
point_intensity: mu.Real = 25.0
point_radius: mu.Real = 20.0

spot_enabled: bool = true
spot_intensity: mu.Real = 25.0
spot_radius: mu.Real = 20.0
spot_outer_deg: mu.Real = 28.0

main :: proc() {
  context.logger = log.create_console_logger()
  rand.reset(1)
  app := new(App)
  w := &app.window
  if !platform.init(w, 1000, 700, "Lights") do return
  if !render.init(&app.renderer, "Lights", w.window, platform.framebuffer_size(w), platform.dpi_scale(w)) do return
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

should_close :: proc(app: ^App) -> bool {
  return platform.should_close(&app.window)
}

setup :: proc(app: ^App) -> mjolnir.Setup {
  if !render.ready(&app.renderer) do return .WAIT
  if !debugui.init(&app.debug, &app.renderer) do return .FAIL
  render.camera_look_at(render.main_camera(&app.renderer), {9, 8, 9}, {0, 1, 0})
  app.orbit = render.orbit_from_camera(render.main_camera(&app.renderer))
  app.renderer.ibl_intensity = 0.3

  ground := world.spawn(&app.scene)
  render.attach(&app.renderer, render.SlotHandle(ground.index), render.primitive(&app.renderer, .QUAD_XZ, .GRAY, cast_shadow = false))
  world.scale(&app.scene, ground, 10.0)

  for x in 0 ..< 3 do for z in 0 ..< 3 {
    color: render.Color
    switch (x + z) % 3 {
    case 0: color = .WHITE
    case 1: color = .RED
    case 2: color = .CYAN
    }
    sphere := world.spawn(&app.scene, {f32(x - 1) * 2.5, 0.7, f32(z - 1) * 2.5})
    render.attach(&app.renderer, render.SlotHandle(sphere.index), render.primitive(&app.renderer, .SPHERE, color))
    world.scale(&app.scene, sphere, 0.7)
  }
  cube := world.spawn(&app.scene, {0, 1.5, 0})
  render.attach(&app.renderer, render.SlotHandle(cube.index), render.primitive(&app.renderer, .CUBE, .YELLOW))
  world.scale(&app.scene, cube, 0.6)

  app.sun_node = world.spawn(&app.scene, {6, 10, 6})
  world.rotate(&app.scene, app.sun_node, linalg.quaternion_between_two_vector3_f32({0, 0, 1}, linalg.normalize([3]f32{-6, -10, -6})))
  app.sun = render.light_create(&app.renderer, render.make_directional_light(intensity = f32(dir_intensity), shadow_radius = 12.0))
  render.attach(&app.renderer, render.SlotHandle(app.sun_node.index), app.sun)

  app.marker_material = render.material_create(&app.renderer, render.make_material(emissive_value = 4.0))

  for i in 0 ..< STARTUP_LIGHTS do spawn_light(app, .SPOT if i == STARTUP_LIGHTS - 1 else .POINT)
  log.info("Lights: P spawns a point light, O a spot light, DELETE removes a random one")
  return .READY
}

shutdown :: proc(app: ^App) {
  world.shutdown(&app.scene)
  debugui.shutdown(&app.debug)
  render.shutdown(&app.renderer)
  platform.shutdown(&app.window)
  delete(app.lights)
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
  l.light, ok = render.light_create(&app.renderer, light_settings(l))
  if !ok do return
  l.node = world.spawn(&app.scene, light_position(l, app.elapsed))
  render.attach(&app.renderer, render.SlotHandle(l.node.index), l.light)
  marker := world.spawn(&app.scene, parent = l.node)
  render.attach(&app.renderer, render.SlotHandle(marker.index), render.MeshAttachment{mesh = app.renderer.builtin_meshes[.CUBE], material = app.marker_material})
  world.scale(&app.scene, marker, MARKER_SCALE)
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

light_settings :: proc(l: MovingLight) -> render.Light {
  switch l.kind {
  case .POINT:
    return render.make_point_light(l.color, f32(point_intensity), f32(point_radius))
  case .SPOT:
    return render.make_spot_light(l.color, f32(spot_intensity), f32(spot_radius), math.to_radians(f32(spot_outer_deg)))
  }
  return {}
}

apply_light_settings :: proc(app: ^App) {
  world.set_visible(&app.scene, app.sun_node, dir_enabled)
  render.light(&app.renderer, app.sun).intensity = f32(dir_intensity)
  for l in app.lights {
    world.set_visible(&app.scene, l.node, point_enabled if l.kind == .POINT else spot_enabled)
    render.light(&app.renderer, l.light)^ = light_settings(l)
  }
}

update :: proc(app: ^App, dt: f32) {
  platform.read_input(&app.window, &app.input)
  debugui.feed(&app.debug, &app.input)
  if !app.input.mouse_captured {
    drag := app.input.mouse_delta if input.mouse_down(&app.input, .LEFT) else 0
    render.orbit_drag(&app.orbit, drag, app.input.scroll.y)
  }
  render.camera_orbit(render.main_camera(&app.renderer), app.orbit)
  if input.key_pressed(&app.input, .P) do spawn_light(app, .POINT)
  if input.key_pressed(&app.input, .O) do spawn_light(app, .SPOT)
  if input.key_pressed(&app.input, .DELETE) do remove_random_light(app)

  app.elapsed += dt
  for l in app.lights {
    pos := light_position(l, app.elapsed)
    world.translate(&app.scene, l.node, pos)
    if l.kind == .SPOT {
      dir := linalg.normalize(SPOT_TARGET - pos)
      world.rotate(&app.scene, l.node, linalg.quaternion_between_two_vector3(linalg.VECTOR3F32_Z_AXIS, dir))
    }
  }
  apply_light_settings(app)
  world.update(&app.scene)
  render.stage_transforms(&app.renderer, world.changes(&app.scene))
  render.update(&app.renderer, dt)
}

frame :: proc(app: ^App) -> bool {
  platform.poll_events(&app.window)
  debug_ui(app)
  render.stage_overlay(&app.renderer, debugui.end(&app.debug))
  return render.frame(&app.renderer, platform.framebuffer_size(&app.window), platform.dpi_scale(&app.window))
}

debug_ui :: proc(app: ^App) {
  ctx := debugui.begin(&app.debug)
  if mu.window(ctx, "Lights", {700, 20, 280, 620}, {.NO_CLOSE}) {
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
    light_block(ctx, "Directional", &dir_enabled, &dir_intensity, 5, nil, nil)
    light_block(ctx, "Point lights", &point_enabled, &point_intensity, 500, &point_radius, nil)
    light_block(ctx, "Spot lights", &spot_enabled, &spot_intensity, 500, &spot_radius, &spot_outer_deg)
  }
}

light_block :: proc(ctx: ^mu.Context, name: string, enabled: ^bool, intensity: ^mu.Real, max_intensity: mu.Real, radius: ^mu.Real, cone: ^mu.Real) {
  mu.layout_row(ctx, {-1}, 0)
  mu.checkbox(ctx, name, enabled)
  mu.label(ctx, "Intensity:")
  mu.slider(ctx, intensity, 0.0, max_intensity)
  if radius != nil {
    mu.label(ctx, "Range:")
    mu.slider(ctx, radius, 1.0, 30.0)
  }
  if cone != nil {
    mu.label(ctx, "Cone angle (deg):")
    mu.slider(ctx, cone, 5.0, 80.0)
  }
}

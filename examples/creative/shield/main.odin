// User vertex and fragment shaders: a forcefield of glowing panels popping out of a sphere, over
// a ring of fire, seen from above and below, from eroding layers of procedural noise.
package main

import "mjolnir"
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

SEGMENTS :: 24
RINGS :: 12
RADIUS :: f32(1.4)
DISC_SEGMENTS :: 32
DISC_RADIUS :: f32(4)

App :: struct {
  platform: platform.Platform,
  scene:    world.World,
  renderer: render.Renderer,
  debug:    debugui.Context,
  input:    input.State,
  orbit:    render.Orbit,
  field:    render.MaterialHandle,
  ring:     render.MaterialHandle,
}

wireframe := false
pop := true
threshold: f32 = 0.1
fade: f32 = 0.01
tone1: [3]f32 = {0.0, 0.0, 0.0}
tone2: [3]f32 = {0.9, 0.35, 1.2}
tone3: [3]f32 = {0.5, 0.2, 2.0}
field: [3]f32 = {0.15, 0.75, 0.3}

main :: proc() {
  context.logger = log.create_console_logger()
  app := new(App)
  if !platform.init(&app.platform, 1000, 700, "Shield") do return
  if !render.init(&app.renderer, app.platform.window) do return
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
  app.orbit = render.make_orbit({0, 3.5, 6.5}, {0, 1.4, 0})
  render.camera_orbit(render.main_camera(r), app.orbit)

  ring_shader, ring_ok := render.material_shader_create(r, #load("ring." + render.SHADER_EXT))
  field_shader, field_ok := render.material_shader_create(r, #load("field." + render.SHADER_EXT), blend = .NONE, cull = .NONE)
  if !field_ok || !ring_ok do return .FAIL
  app.field = render.material_create(r, render.make_material(.CUSTOM, shader = field_shader))
  app.ring = render.material_create(r, render.make_material(.CUSTOM, shader = ring_shader))

  sphere := world.spawn(&app.scene, {0, RADIUS, 0})
  sphere_mesh := render.mesh_create(r, geometry.make_sphere(segments = SEGMENTS, rings = RINGS, radius = RADIUS, faceted = true))
  render.attach(r, sphere, render.MeshAttachment{mesh = sphere_mesh, material = app.field})
  disc := world.spawn(&app.scene, {0, RADIUS, 0})
  disc_mesh := render.mesh_create(r, geometry.make_circle(segments = DISC_SEGMENTS, radius = DISC_RADIUS))
  render.attach(r, disc, render.MeshAttachment{mesh = disc_mesh, material = app.ring})
  flipped := world.spawn(&app.scene, {0, RADIUS, 0})
  world.rotate(&app.scene, flipped, math.PI, linalg.VECTOR3F32_X_AXIS)
  render.attach(r, flipped, render.MeshAttachment{mesh = disc_mesh, material = app.ring})

  return .READY
}

shutdown :: proc(app: ^App) {
  world.shutdown(&app.scene)
  debugui.shutdown(&app.debug)
  render.shutdown(&app.renderer)
  platform.shutdown(&app.platform)
  free(app)
}

should_close :: proc(app: ^App) -> bool {
  return platform.should_close(&app.platform)
}

update :: proc(app: ^App, dt: f32) {
  render.lock(&app.renderer)
  defer render.unlock(&app.renderer)
  platform.read_input(&app.platform, &app.input)
  debugui.feed(&app.debug, &app.input, &app.renderer)
  debug_ui(app)
  render.stage_overlay(&app.renderer, debugui.end(&app.debug))
  render.orbit_drag(&app.orbit, render.main_camera(&app.renderer), &app.input)
  if input.key_pressed(&app.input, .W) do wireframe = !wireframe
  if input.key_pressed(&app.input, .P) do pop = !pop
  lines := f32(1) if wireframe else 0
  sphere := render.material(&app.renderer, app.field)
  sphere.params[0] = {f32(1) if pop else 0, lines, SEGMENTS, RINGS}
  sphere.params[2].rgb = field
  ring := render.material(&app.renderer, app.ring)
  ring.params[0] = {lines, DISC_SEGMENTS, RADIUS / DISC_RADIUS, threshold}
  ring.params[1] = {tone2.r, tone2.g, tone2.b, fade}
  ring.params[2].rgb = tone1
  ring.params[3].rgb = tone3
  mjolnir.update(&app.scene, &app.renderer, dt)
}

frame :: proc(app: ^App) -> bool {
  return mjolnir.frame(&app.platform, &app.renderer)
}

debug_ui :: proc(app: ^App) {
  ctx := debugui.begin(&app.debug)
  if debugui.window(&app.debug, "Shield", {20, 20, 260, 400}, {}, {.NO_CLOSE}) {
    mu.layout_row(ctx, {-1}, 0)
    mu.checkbox(ctx, "Wireframe (W)", &wireframe)
    mu.checkbox(ctx, "Pop panels (P)", &pop)
    mu.label(ctx, "Threshold"); mu.slider(ctx, &threshold, 0, 0.3)
    mu.label(ctx, "Fade range"); mu.slider(ctx, &fade, 0.005, 0.2)
    color_sliders(ctx, "Tone 1", &tone1)
    color_sliders(ctx, "Tone 2", &tone2)
    color_sliders(ctx, "Tone 3", &tone3)
    color_sliders(ctx, "Field color", &field)
  }
}

color_sliders :: proc(ctx: ^mu.Context, label: string, color: ^[3]f32) {
  mu.layout_row(ctx, {-1}, 0)
  mu.label(ctx, label)
  mu.layout_row(ctx, {74, 74, 74}, 0)
  for &c in color do mu.slider(ctx, &c, 0, 2)
}

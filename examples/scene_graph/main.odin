// Hierarchical transforms and traversal.
package main

import "../../mjolnir"
import "../../mjolnir/debugui"
import "../../mjolnir/input"
import "../../mjolnir/platform"
import "../../mjolnir/render"
import "../../mjolnir/world"
import "core:log"
import mu "vendor:microui"

sun_handle: world.NodeHandle
planet_handles: [3]world.NodeHandle
moon_handle: world.NodeHandle

orbit_speed: mu.Real = 1.0
spin_speed: mu.Real = 2.0
phase: f32

App :: struct {
  window:   platform.Platform,
  scene:    world.World,
  renderer: render.Renderer,
  debug:    debugui.Context,
  input:    input.State,
  // orbit controller state, owned by the app
  yaw, pitch, dist: f32,
}

main :: proc() {
  context.logger = log.create_console_logger()
  app := new(App)
  w := &app.window
  if !platform.init(w, 1000, 700, "Scene Graph") do return
  if !render.init(&app.renderer, "Scene Graph", w.window, platform.framebuffer_size(w), platform.dpi_scale(w)) do return
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
  if !debugui.init(&app.debug, &app.renderer) do return false
  render.environment_map_load(&app.renderer, #load("../../assets/Cannon_Exterior.hdr"))

  render.camera_look_at(render.main_camera(&app.renderer), {0, 14, 18}, {0, 0, 0})

  app.yaw, app.pitch, app.dist = render.camera_orbit_state(render.main_camera(&app.renderer))

  light := world.spawn(&app.scene, {8, 14, 8})
  render.attach(&app.renderer, render.SlotHandle(light.index), render.light_create(&app.renderer, render.make_directional_light(
    color         = {1, 0.97, 0.92, 1},
    shadow_radius = 8.0,
    cast_shadow   = true,
  )))

  ground := world.spawn(&app.scene, {0, -2, 0})
  render.attach(&app.renderer, render.SlotHandle(ground.index), render.primitive(&app.renderer, .QUAD_XZ, .GRAY, cast_shadow = false))
  world.scale(&app.scene, ground, 20.0)

  // Sun — root of the rotating subtree
  sun_mat := render.material_create(&app.renderer, render.make_material(base_color_factor = {1.0, 0.8, 0.2, 1.0}, emissive_value = 2.0))
  sun_handle = world.spawn(&app.scene)
  render.attach(&app.renderer, render.SlotHandle(sun_handle.index), render.MeshAttachment{mesh = app.renderer.builtin_meshes[.SPHERE], material = sun_mat, cast_shadow = true})
  world.scale(&app.scene, sun_handle, 1.2)

  // Planets — children of sun, each at fixed local offset
  planet_colors := [3]render.Color{.CYAN, .GREEN, .MAGENTA}
  planet_radii := [3]f32{3.5, 6.0, 9.0}
  for i in 0 ..< 3 {
    planet_handles[i] = world.spawn(&app.scene, {planet_radii[i], 0, 0}, parent = sun_handle)
    render.attach(&app.renderer, render.SlotHandle(planet_handles[i].index), render.primitive(&app.renderer, .SPHERE, planet_colors[i]))
    world.scale(&app.scene, planet_handles[i], 0.5)
  }

  // Moon — child of outermost planet
  moon_handle = world.spawn(&app.scene, {1.5, 0, 0}, parent = planet_handles[2])
  render.attach(&app.renderer, render.SlotHandle(moon_handle.index), render.primitive(&app.renderer, .CUBE, .WHITE))
  world.scale(&app.scene, moon_handle, 0.3)
  return true
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
  platform.read_input(&app.window, &app.input)
  debugui.feed(&app.debug, &app.input)
  if !app.input.mouse_captured {
    if input.mouse_down(&app.input, .LEFT) {
      app.yaw += app.input.mouse_delta.x * 0.02
      app.pitch = clamp(app.pitch + app.input.mouse_delta.y * 0.02, -1.5, 1.5)
    }
    app.dist = clamp(app.dist - app.input.scroll.y * 2, 1, 200)
  }
  render.camera_orbit(render.main_camera(&app.renderer), app.yaw, app.pitch, app.dist)
  phase += dt * f32(orbit_speed)
  world.rotate(&app.scene, sun_handle, phase * 0.3)
  for h, i in planet_handles {
    world.rotate(&app.scene, h, phase * f32(spin_speed) * f32(i + 1) * 0.5)
  }
  world.rotate(&app.scene, moon_handle, phase * 4.0)
  world.update(&app.scene)
  render.stage_transforms(&app.renderer, world.changes(&app.scene))
  render.update(&app.renderer, dt)
}

frame :: proc(app: ^App) -> bool {
  platform.poll_events(&app.window)
  ctx := debugui.begin(&app.debug)
  if mu.window(ctx, "Scene Graph", {720, 20, 260, 240}, {.NO_CLOSE}) {
    mu.label(ctx, "Hierarchy: sun > planets > moon")
    mu.label(ctx, "Each planet inherits sun rotation.")
    mu.label(ctx, "Moon inherits outer planet too.")
    mu.label(ctx, "")
    mu.label(ctx, "Orbit speed")
    mu.slider(ctx, &orbit_speed, 0.0, 4.0)
    mu.label(ctx, "Spin speed")
    mu.slider(ctx, &spin_speed, 0.0, 6.0)
  }
  render.stage_overlay(&app.renderer, {commands = debugui.end(&app.debug, platform.dpi_scale(&app.window))})
  return render.frame(&app.renderer, platform.framebuffer_size(&app.window), platform.dpi_scale(&app.window))
}

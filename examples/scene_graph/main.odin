// Hierarchical transforms and traversal.
package main

import "../../mjolnir"
import "../../mjolnir/input"
import "../../mjolnir/platform"
import "../../mjolnir/render"
import "../../mjolnir/world"
import "core:fmt"
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
  input:    input.State,
}

main :: proc() {
  context.logger = log.create_console_logger()
  app := new(App)
  defer free(app)
  w := &app.window
  if !platform.init(w, 1000, 700, "Scene Graph") do return
  defer platform.shutdown(w)
  if !render.init(&app.renderer, "Scene Graph", platform.vulkan_instance_extensions(), platform.vulkan_get_instance_proc_addr(), platform.create_surface, w, platform.framebuffer_size(w), platform.dpi_scale(w)) do return
  defer render.shutdown(&app.renderer)
  if !world.init(&app.scene) do return
  defer world.shutdown(&app.scene)
  render.load_environment_map(&app.renderer, "assets/Cannon_Exterior.hdr")

  render.main_camera_look_at(&app.renderer, {0, 14, 18}, {0, 0, 0})

  light := world.spawn(&app.scene, {8, 14, 8})
  render.attach(&app.renderer, light.index, render.directional_light_attachment(
    color         = {1, 0.97, 0.92, 1},
    shadow_radius = 8.0,
    cast_shadow   = true,
  ))

  ground := world.spawn(&app.scene, {0, -2, 0})
  render.attach(&app.renderer, ground.index, render.primitive(&app.renderer, .QUAD_XZ, .GRAY, cast_shadow = false))
  world.scale(&app.scene, ground, 20.0)

  // Sun — root of the rotating subtree
  sun_mat := render.material_pbr(&app.renderer, base_color = {1.0, 0.8, 0.2, 1.0}, emissive = 2.0)
  sun_handle = world.spawn(&app.scene)
  render.attach(&app.renderer, sun_handle.index, render.MeshAttachment{handle = app.renderer.builtin_meshes[.SPHERE], material = sun_mat, cast_shadow = true})
  world.scale(&app.scene, sun_handle, 1.2)

  // Planets — children of sun, each at fixed local offset
  planet_colors := [3]render.Color{.CYAN, .GREEN, .MAGENTA}
  planet_radii := [3]f32{3.5, 6.0, 9.0}
  for i in 0 ..< 3 {
    planet_handles[i] = world.spawn_child(&app.scene, sun_handle, {planet_radii[i], 0, 0})
    render.attach(&app.renderer, planet_handles[i].index, render.primitive(&app.renderer, .SPHERE, planet_colors[i]))
    world.scale(&app.scene, planet_handles[i], 0.5)
  }

  // Moon — child of outermost planet
  moon_handle = world.spawn_child(&app.scene, planet_handles[2], {1.5, 0, 0})
  render.attach(&app.renderer, moon_handle.index, render.primitive(&app.renderer, .CUBE, .WHITE))
  world.scale(&app.scene, moon_handle, 0.3)

  mjolnir.run(mjolnir.Loop(App){app = app, should_close = should_close, update = update, frame = frame})
}

should_close :: proc(app: ^App) -> bool {
  return platform.should_close(&app.window)
}

update :: proc(app: ^App, dt: f32) {
  platform.read_input(&app.window, &app.input)
  render.debug_ui_input(&app.renderer, &app.input)
  if cam, ok := render.main_camera(&app.renderer); ok && !app.input.mouse_captured {
    yaw, pitch, dist := render.camera_orbit_state(cam)
    if input.mouse_down(&app.input, .LEFT) {
      yaw += app.input.mouse_delta.x * 0.02
      pitch = clamp(pitch + app.input.mouse_delta.y * 0.02, -1.5, 1.5)
    }
    render.camera_orbit(cam, yaw, pitch, clamp(dist - app.input.scroll.y * 2, 1, 200))
  }
  phase += dt * f32(orbit_speed)
  world.rotate(&app.scene, sun_handle, phase * 0.3)
  for h, i in planet_handles {
    world.rotate(&app.scene, h, phase * f32(spin_speed) * f32(i + 1) * 0.5)
  }
  world.rotate(&app.scene, moon_handle, phase * 4.0)
  world.update(&app.scene)
  for i in world.removed_nodes(&app.scene) do render.stage_slot_removal(&app.renderer, i)
  render.stage_transforms(&app.renderer, world.changed_nodes(&app.scene))
  render.update(&app.renderer, dt)
}

frame :: proc(app: ^App) -> bool {
  platform.poll_events(&app.window)
  ctx := render.debug_ui(&app.renderer)
  if mu.window(ctx, "Scene Graph", {720, 20, 260, 240}, {.NO_CLOSE}) {
    mu.label(ctx, "Hierarchy: sun > planets > moon")
    mu.label(ctx, "Each planet inherits sun rotation.")
    mu.label(ctx, "Moon inherits outer planet too.")
    mu.label(ctx, "")
    mu.label(ctx, fmt.tprintf("Orbit speed: %.2f", orbit_speed))
    mu.slider(ctx, &orbit_speed, 0.0, 4.0)
    mu.label(ctx, fmt.tprintf("Spin speed: %.2f", spin_speed))
    mu.slider(ctx, &spin_speed, 0.0, 6.0)
  }
  return render.frame(&app.renderer, platform.framebuffer_size(&app.window), platform.dpi_scale(&app.window))
}

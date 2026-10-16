// A user material shader: cel-shaded meshes beside PBR ones.
package main

import "../../mjolnir"
import "../../mjolnir/debugui"
import "../../mjolnir/input"
import "../../mjolnir/platform"
import "../../mjolnir/render"
import "../../mjolnir/world"
import "core:log"
import mu "vendor:microui"

App :: struct {
  window:    platform.Platform,
  scene:     world.World,
  renderer:  render.Renderer,
  debug:     debugui.Context,
  input:     input.State,
  // orbit controller state, owned by the app
  yaw, pitch, dist: f32,
  toon:      render.MaterialShader,
  materials: [dynamic]render.MaterialHandle,
}

bands: mu.Real = 3
rim: mu.Real = 0.35
shade: mu.Real = 0.35

main :: proc() {
  context.logger = log.create_console_logger()
  app := new(App)
  w := &app.window
  if !platform.init(w, 1000, 700, "Toon Material") do return
  if !render.init(&app.renderer, "Toon Material", w.window, platform.framebuffer_size(w), platform.dpi_scale(w)) do return
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
  render.camera_look_at(render.main_camera(&app.renderer), {0, 4, 10}, {0, 1, 0})
  app.yaw, app.pitch, app.dist = render.camera_orbit_state(render.main_camera(&app.renderer))

  // each backend embeds only its own source
  when render.RENDER_BACKEND == "vulkan" {
    toon_spirv, toon_wgsl := #load("toon.frag.spv"), ""
  } else {
    toon_spirv, toon_wgsl := ([]u8)(nil), #load("toon.wgsl", string)
  }
  ok: bool
  app.toon, ok = render.material_shader_create(&app.renderer, toon_spirv, toon_wgsl, blend = .NONE)
  if !ok {
    log.error("Failed to node_create the toon shader")
    return true
  }

  ground := world.spawn(&app.scene)
  render.attach(&app.renderer, ground.index, render.primitive(&app.renderer, .QUAD_XZ, .GRAY, cast_shadow = false))
  world.scale(&app.scene, ground, 20.0)

  meshes := app.renderer.builtin_meshes
  colors := [?][4]f32{{1.0, 0.45, 0.3, 1}, {0.35, 0.8, 0.45, 1}, {0.35, 0.55, 1.0, 1}, {1.0, 0.85, 0.3, 1}}
  shapes := [?]render.MeshHandle{meshes[.SPHERE], meshes[.CUBE], meshes[.SPHERE], meshes[.CUBE]}
  for color, i in colors {
    mat := render.material_create(&app.renderer, .CUSTOM, base_color_factor = color, shader = app.toon)
    append(&app.materials, mat)
    spawn_mesh(app, shapes[i], mat, {f32(i) * 2.5 - 3.75, 1.0, 0})
  }
  // PBR for comparison, behind
  pbr := render.material_create(&app.renderer, base_color_factor = {0.9, 0.9, 0.95, 1}, roughness_value = 0.4)
  spawn_mesh(app, meshes[.SPHERE], pbr, {0, 1.0, -3.0})

  sun := world.spawn(&app.scene, {-3, 8, 6})
  render.attach(&app.renderer, sun.index, render.make_directional_light(color = {1.0, 0.95, 0.9, 3}, shadow_radius = 8.0, cast_shadow = true))
  return true
}

spawn_mesh :: proc(app: ^App, mesh: render.MeshHandle, material: render.MaterialHandle, position: [3]f32) {
  n := world.spawn(&app.scene, position)
  render.attach(&app.renderer, n.index, render.MeshAttachment{handle = mesh, material = material, cast_shadow = true})
}

shutdown :: proc(app: ^App) {
  delete(app.materials)
  world.shutdown(&app.scene)
  debugui.destroy(&app.debug)
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
  for h in app.materials {
    m := render.material(&app.renderer, h) or_continue
    m.frame_columns = u32(bands)
    m.emissive_value = f32(rim)
    m.metallic_value = f32(shade)
  }
  world.update(&app.scene)
  render.stage_transforms(&app.renderer, world.changes(&app.scene))
  render.update(&app.renderer, dt)
}

frame :: proc(app: ^App) -> bool {
  platform.poll_events(&app.window)
  ctx := debugui.begin(&app.debug)
  if mu.window(ctx, "Toon", {700, 20, 280, 230}, {.NO_CLOSE}) {
    mu.layout_row(ctx, {-1}, 0)
    mu.label(ctx, "Bands"); mu.slider(ctx, &bands, 1, 8, 1)
    mu.label(ctx, "Rim");   mu.slider(ctx, &rim, 0, 1)
    mu.label(ctx, "Shade"); mu.slider(ctx, &shade, 0, 1)
  }
  render.stage_overlay(&app.renderer, {commands = debugui.end(&app.debug, platform.dpi_scale(&app.window))})
  return render.frame(&app.renderer, platform.framebuffer_size(&app.window), platform.dpi_scale(&app.window))
}

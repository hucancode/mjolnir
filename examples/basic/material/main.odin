// PBR material parameter sweep.
package main

import "core:log"
import "core:math"
import "core:math/linalg"
import mu "vendor:microui"
import "mjolnir"
import "mjolnir/debugui"
import "mjolnir/input"
import "mjolnir/platform"
import "mjolnir/render"
import "mjolnir/world"

GRID :: 6
SPACING :: 2.5

skybox_on: bool = true
metallic_min: f32 = 0.0
metallic_max: f32 = 1.0
roughness_min: f32 = 0.0
roughness_max: f32 = 1.0

App :: struct {
  platform:         platform.Platform,
  scene:            world.World,
  renderer:         render.Renderer,
  debug:            debugui.Context,
  input:            input.State,
  orbit:            render.Orbit,
  sphere_materials: [GRID][GRID]render.MaterialHandle,
  sun:              render.LightHandle,
}

main :: proc() {
  context.logger = log.create_console_logger()
  app := new(App)
  if !platform.init(&app.platform, 1280, 720, "Material") do return
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

  half := f32(GRID - 1) * 0.5 * SPACING
  app.orbit = render.make_orbit({0, 0, half * 2.4}, {0, 0, 0})

  base_color: [4]f32 = {0.85, 0.85, 0.9, 1}
  for row in 0 ..< GRID do for col in 0 ..< GRID {
    m, r := axis_values(row, col)
    mat := render.material_create(&app.renderer, render.make_material(type = .PBR, base_color_factor = base_color,
      metallic_factor = m, roughness_factor = r,
    ))
    app.sphere_materials[row][col] = mat
    x := f32(col) * SPACING - half
    y := f32(row) * SPACING - half
    mjolnir.spawn(&app.scene, &app.renderer, render.primitive(&app.renderer, .SPHERE, mat), {x, y, 0})
  }

  app.sun = render.light_create(&app.renderer, render.make_directional_light({1, 0.97, 0.92}, 5, 12))
  mjolnir.spawn(&app.scene, &app.renderer, app.sun, rotation = linalg.quaternion_from_forward_and_up([3]f32{-0.3, -1, -0.5}, [3]f32{0, 1, 0}))
  return .READY
}

shutdown :: proc(app: ^App) {
  world.shutdown(&app.scene)
  debugui.shutdown(&app.debug)
  render.shutdown(&app.renderer)
  platform.shutdown(&app.platform)
  free(app)
}

axis_values :: proc(row, col: int) -> (metallic, roughness: f32) {
  t_row := f32(row) / f32(GRID - 1)
  t_col := f32(col) / f32(GRID - 1)
  metallic = math.lerp(metallic_min, metallic_max, t_row)
  roughness = math.lerp(roughness_min, roughness_max, t_col)
  return
}

update :: proc(app: ^App, dt: f32) {
  render.lock(&app.renderer)
  platform.read_input(&app.platform, &app.input)
  debug_ui(app)
  mjolnir.orbit_drag(&app.orbit, render.main_camera(&app.renderer), &app.input)
  app.renderer.skybox_intensity = skybox_on ? 1 : 0
  for row in 0 ..< GRID do for col in 0 ..< GRID {
    m, r := axis_values(row, col)
    mat := render.material(&app.renderer, app.sphere_materials[row][col]) or_continue
    mat.metallic_factor = m
    mat.roughness_factor = r
  }
  mjolnir.update(&app.scene, &app.renderer, dt)
}

draw :: proc(app: ^App) -> bool {
  return mjolnir.frame(&app.platform, &app.renderer)
}

debug_ui :: proc(app: ^App) {
  ctx := debugui.begin(&app.debug, &app.input, &app.renderer)
  defer debugui.end(&app.debug, &app.renderer)
  if debugui.window(&app.debug, "Material", {20, 20, 220, 360}) {
    mu.layout_row(ctx, {-1}, 0)
    mu.label(ctx, "Sun intensity")
    mu.slider(ctx, &render.light(&app.renderer, app.sun).intensity, 0, 20)
    mu.label(ctx, "IBL intensity")
    mu.slider(ctx, &app.renderer.ibl_intensity, 0, 2)
    mu.checkbox(ctx, "Skybox", &skybox_on)
    mu.label(ctx, "Metallic (bottom to top)")
    mu.slider(ctx, &metallic_min, 0, 1)
    mu.slider(ctx, &metallic_max, 0, 1)
    mu.label(ctx, "Roughness (left to right)")
    mu.slider(ctx, &roughness_min, 0, 1)
    mu.slider(ctx, &roughness_max, 0, 1)
  }
}

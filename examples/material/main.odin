// PBR material parameter sweep.
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

GRID :: 6
SPACING :: 2.5

ibl_intensity: mu.Real = 1.0
sun_intensity: mu.Real = 5.0
skybox_on: bool = true
metallic_min: mu.Real = 0.0
metallic_max: mu.Real = 1.0
roughness_min: mu.Real = 0.0
roughness_max: mu.Real = 1.0

App :: struct {
  window:           platform.Platform,
  scene:            world.World,
  renderer:         render.Renderer,
  debug:            debugui.Context,
  input:            input.State,
  orbit:            render.Orbit,
  sphere_materials: [GRID][GRID]render.MaterialHandle,
}

main :: proc() {
  context.logger = log.create_console_logger()
  app := new(App)
  w := &app.window
  if !platform.init(w, 1000, 700, "Material PBR Knobs") do return
  if !render.init(&app.renderer, "Material PBR Knobs", w.window, platform.framebuffer_size(w), platform.dpi_scale(w)) do return
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
  if !render.ready(&app.renderer) do return .WAIT
  if !debugui.init(&app.debug, &app.renderer) do return .FAIL

  half := f32(GRID - 1) * 0.5 * SPACING
  render.camera_look_at(render.main_camera(&app.renderer), {0, 0, half * 2.4}, {0, 0, 0})
  app.orbit = render.orbit_from_camera(render.main_camera(&app.renderer))

  sphere_mesh := app.renderer.builtin_meshes[.SPHERE]

  base_color: [4]f32 = {0.85, 0.85, 0.9, 1}
  for row in 0 ..< GRID do for col in 0 ..< GRID {
    m, r := axis_values(row, col)
    mat := render.material_create(&app.renderer, render.make_material(type = .PBR, base_color_factor = base_color,
      metallic_value = m, roughness_value = r,
    ))
    app.sphere_materials[row][col] = mat
    x := f32(col) * SPACING - half
    y := f32(row) * SPACING - half
    sphere := world.spawn(&app.scene, {x, y, 0})
    render.attach(&app.renderer, render.SlotHandle(sphere.index), render.MeshAttachment{mesh = sphere_mesh, material = mat, cast_shadow = true})
  }

  sun_heading := linalg.quaternion_angle_axis(math.PI * 0.65, linalg.VECTOR3F32_Y_AXIS)
  sun_elevation := linalg.quaternion_angle_axis(-math.PI * 0.45, linalg.VECTOR3F32_Y_AXIS)
  app.renderer.sun = {enabled = true, cast_shadow = true, color = {1, 0.97, 0.92}, intensity = f32(sun_intensity), direction = linalg.quaternion_mul_vector3(sun_elevation * sun_heading, [3]f32{0, 0, -1}), shadow_distance = 12}
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

axis_values :: proc(row, col: int) -> (metallic, roughness: f32) {
  t_row := f32(row) / f32(GRID - 1)
  t_col := f32(col) / f32(GRID - 1)
  m_lo, m_hi := f32(metallic_min), f32(metallic_max)
  r_lo, r_hi := f32(roughness_min), f32(roughness_max)
  metallic = math.lerp(m_lo, m_hi, t_row)
  roughness = math.lerp(r_lo, r_hi, t_col)
  return
}

update :: proc(app: ^App, dt: f32) {
  platform.read_input(&app.window, &app.input)
  debugui.feed(&app.debug, &app.input)
  if !app.input.mouse_captured {
    drag := app.input.mouse_delta if input.mouse_down(&app.input, .LEFT) else 0
    render.orbit_drag(&app.orbit, drag, app.input.scroll.y)
  }
  render.camera_orbit(render.main_camera(&app.renderer), app.orbit)
  app.renderer.sun.intensity = f32(sun_intensity)
  app.renderer.ibl_intensity = f32(ibl_intensity)
  app.renderer.skybox_intensity = skybox_on ? 1 : 0
  for row in 0 ..< GRID do for col in 0 ..< GRID {
    m, r := axis_values(row, col)
    mat := render.material(&app.renderer, app.sphere_materials[row][col]) or_continue
    mat.metallic_value = m
    mat.roughness_value = r
  }
  world.update(&app.scene)
  render.stage_transforms(&app.renderer, world.changes(&app.scene))
  render.update(&app.renderer, dt)
}

frame :: proc(app: ^App) -> bool {
  platform.poll_events(&app.window)
  ctx := debugui.begin(&app.debug)
  if mu.window(ctx, "Environment", {700, 20, 280, 180}, {.NO_CLOSE}) {
    mu.label(ctx, "Sun intensity")
    mu.slider(ctx, &sun_intensity, 0.0, 5.0)
    mu.label(ctx, "IBL intensity")
    mu.slider(ctx, &ibl_intensity, 0.0, 2.0)
    mu.checkbox(ctx, "Skybox", &skybox_on)
  }
  if mu.window(ctx, "PBR Range", {700, 210, 280, 220}, {.NO_CLOSE}) {
    mu.label(ctx, "Metallic min (rows bottom)")
    mu.slider(ctx, &metallic_min, 0.0, 1.0)
    mu.label(ctx, "Metallic max (rows top)")
    mu.slider(ctx, &metallic_max, 0.0, 1.0)
    mu.label(ctx, "Roughness min (cols left)")
    mu.slider(ctx, &roughness_min, 0.0, 1.0)
    mu.label(ctx, "Roughness max (cols right)")
    mu.slider(ctx, &roughness_max, 0.0, 1.0)
  }
  render.stage_overlay(&app.renderer, debugui.end(&app.debug))
  return render.frame(&app.renderer, platform.framebuffer_size(&app.window), platform.dpi_scale(&app.window))
}

// PBR material parameter sweep.
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
sun_light: world.NodeHandle
grid_materials: [GRID][GRID]render.MaterialHandle

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

// On the web the renderer's device arrives after main returns: build the scene once it is up.
setup :: proc(app: ^App) -> bool {
  if !render.ready(&app.renderer) do return false
  if !debugui.init(&app.debug, &app.renderer) do return false
  render.environment_map_load(&app.renderer, #load("../../assets/Cannon_Exterior.hdr"))

  half := f32(GRID - 1) * 0.5 * SPACING
  render.camera_look_at(render.main_camera(&app.renderer), {half + 2, half + 4, half * 2.4}, {0, half - 1, 0})
  app.yaw, app.pitch, app.dist = render.camera_orbit_state(render.main_camera(&app.renderer))

  sphere_mesh := app.renderer.builtin_meshes[.SPHERE]
  plane_mesh := app.renderer.builtin_meshes[.QUAD_XZ]
  ground_albedo, _ := render.texture_load(&app.renderer, #load("statue-1275469_1280.jpg"), generate_mips = true)
  plane_material := render.material_create(&app.renderer, .PBR,
    albedo_texture = ground_albedo, roughness_value = 0.7, metallic_value = 0.0,
  )

  plane := world.spawn(&app.scene, {0, -1, 0})
  render.attach(&app.renderer, plane.index, render.MeshAttachment{handle = plane_mesh, material = plane_material, cast_shadow = false})
  world.scale(&app.scene, plane, f32(GRID) * SPACING * 1.5)

  base_color: [4]f32 = {0.85, 0.85, 0.9, 1}
  for row in 0 ..< GRID do for col in 0 ..< GRID {
    m, r := axis_values(row, col)
    mat := render.material_create(&app.renderer, type = .PBR, base_color_factor = base_color,
      metallic_value = m, roughness_value = r,
    )
    grid_materials[row][col] = mat
    x := f32(col) * SPACING - half
    y := f32(row) * SPACING
    sphere := world.spawn(&app.scene, {x, y, 0})
    render.attach(&app.renderer, sphere.index, render.MeshAttachment{handle = sphere_mesh, material = mat, cast_shadow = true})
  }

  q1 := linalg.quaternion_angle_axis(-math.PI * 0.35, linalg.VECTOR3F32_Y_AXIS)
  q2 := linalg.quaternion_angle_axis(-math.PI * 0.45, linalg.VECTOR3F32_X_AXIS)
  sun_light = world.spawn(&app.scene, {0, 10, 0})
  render.attach(&app.renderer, sun_light.index, render.light_create(&app.renderer, render.make_directional_light({1, 0.97, 0.92, f32(sun_intensity)}, 12.0)))
  world.rotate(&app.scene, sun_light, q2 * q1)
  return true
}

shutdown :: proc(app: ^App) {
  world.shutdown(&app.scene)
  debugui.destroy(&app.debug)
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
    if input.mouse_down(&app.input, .LEFT) {
      app.yaw += app.input.mouse_delta.x * 0.02
      app.pitch = clamp(app.pitch + app.input.mouse_delta.y * 0.02, -1.5, 1.5)
    }
    app.dist = clamp(app.dist - app.input.scroll.y * 2, 1, 200)
  }
  render.camera_orbit(render.main_camera(&app.renderer), app.yaw, app.pitch, app.dist)
  if l, ok := render.light(&app.renderer, render.attachment(&app.renderer, sun_light.index, render.LightHandle)); ok {
    l.color[3] = f32(sun_intensity)
  }
  app.renderer.ibl_intensity = f32(ibl_intensity)
  app.renderer.skybox_intensity = skybox_on ? 1 : 0
  for row in 0 ..< GRID do for col in 0 ..< GRID {
    m, r := axis_values(row, col)
    mat := render.material(&app.renderer, grid_materials[row][col]) or_continue
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
    mu.label(ctx, fmt.tprintf("Sun intensity: %.2f", sun_intensity))
    mu.slider(ctx, &sun_intensity, 0.0, 5.0)
    mu.label(ctx, fmt.tprintf("IBL intensity: %.2f", ibl_intensity))
    mu.slider(ctx, &ibl_intensity, 0.0, 2.0)
    mu.checkbox(ctx, "Skybox", &skybox_on)
  }
  if mu.window(ctx, "PBR Range", {700, 210, 280, 220}, {.NO_CLOSE}) {
    mu.label(ctx, fmt.tprintf("Metallic min: %.2f (rows bottom)", metallic_min))
    mu.slider(ctx, &metallic_min, 0.0, 1.0)
    mu.label(ctx, fmt.tprintf("Metallic max: %.2f (rows top)", metallic_max))
    mu.slider(ctx, &metallic_max, 0.0, 1.0)
    mu.label(ctx, fmt.tprintf("Roughness min: %.2f (cols left)", roughness_min))
    mu.slider(ctx, &roughness_min, 0.0, 1.0)
    mu.label(ctx, fmt.tprintf("Roughness max: %.2f (cols right)", roughness_max))
    mu.slider(ctx, &roughness_max, 0.0, 1.0)
  }
  render.stage_overlay(&app.renderer, {commands = debugui.end(&app.debug, platform.dpi_scale(&app.window))})
  return render.frame(&app.renderer, platform.framebuffer_size(&app.window), platform.dpi_scale(&app.window))
}

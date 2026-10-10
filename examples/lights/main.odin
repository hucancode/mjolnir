package main

import "../../mjolnir"
import "../../mjolnir/input"
import "../../mjolnir/platform"
import "../../mjolnir/render"
import "../../mjolnir/world"
import "core:fmt"
import "core:log"
import "core:math"
import "core:math/linalg"
import mu "vendor:microui"

App :: struct {
  window:   platform.Platform,
  scene:    world.World,
  renderer: render.Manager,
  camera:   render.CameraController,
  input:    input.State,
}

dir_light: world.NodeHandle
point_light: world.NodeHandle
spot_light: world.NodeHandle

dir_enabled: bool = true
point_enabled: bool = true
spot_enabled: bool = true

dir_intensity: mu.Real = 1.0
point_intensity: mu.Real = 1.0
spot_intensity: mu.Real = 1.0

point_radius: mu.Real = 10.0
spot_radius: mu.Real = 20.0
spot_outer_deg: mu.Real = 28.0

dir_color: mu.Real = 0.0
point_color: mu.Real = 0.0
spot_color: mu.Real = 1.0

point_orbit_phase: f32
spot_sweep_phase: f32

main :: proc() {
  context.logger = log.create_console_logger()
  app := new(App)
  defer free(app)
  w := &app.window
  if !platform.init(w, 1000, 700, "Lights") do return
  defer platform.shutdown(w)
  if !render.init(&app.renderer, "Lights", platform.vulkan_instance_extensions(), platform.vulkan_get_instance_proc_addr(), platform.create_surface, w, platform.framebuffer_size(w), platform.dpi_scale(w)) do return
  defer render.shutdown(&app.renderer)
  if !world.init(&app.scene) do return
  defer world.shutdown(&app.scene)
  render.load_environment_map(&app.renderer, "assets/Cannon_Exterior.hdr")
  app.camera = render.orbit_controller()
  setup(app)
  mjolnir.run(mjolnir.Loop(App){app = app, should_close = should_close, update = update, frame = frame})
}

should_close :: proc(app: ^App) -> bool {
  return platform.should_close(&app.window)
}

color_preset :: proc(idx: mu.Real, intensity: f32) -> [4]f32 {
  switch int(idx + 0.5) {
  case 0: return {1.0, 0.65, 0.35, intensity}
  case 1: return {1.0, 1.0, 1.0, intensity}
  case 2: return {0.45, 0.7, 1.0, intensity}
  }
  return {1.0, 1.0, 1.0, intensity}
}

setup :: proc(app: ^App) {
  render.main_camera_look_at(&app.renderer, {7, 6, 7}, {0, 1, 0})

  ground := world.spawn(&app.scene)
  render.attach(&app.renderer, ground.index, render.primitive(&app.renderer, .QUAD_XZ, .GRAY, cast_shadow = false))
  world.scale(&app.scene, ground, 10.0)

  for x in 0 ..< 3 do for z in 0 ..< 3 {
    color: render.Color
    switch (x + z) % 3 {
    case 0: color = .WHITE
    case 1: color = .RED
    case 2: color = .CYAN
    }
    sphere := world.spawn(&app.scene, {f32(x - 1) * 2.5, 0.7, f32(z - 1) * 2.5})
    render.attach(&app.renderer, sphere.index, render.primitive(&app.renderer, .SPHERE, color))
    world.scale(&app.scene, sphere, 0.7)
  }
  cube := world.spawn(&app.scene, {0, 1.5, 0})
  render.attach(&app.renderer, cube.index, render.primitive(&app.renderer, .CUBE, .YELLOW))
  world.scale(&app.scene, cube, 0.6)

  dir_light = world.spawn(&app.scene, {6, 10, 6})
  render.attach(&app.renderer, dir_light.index, render.directional_light_attachment(color = color_preset(dir_color, f32(dir_intensity)), radius = 12.0, cast_shadow = true))
  point_light = world.spawn(&app.scene, {3, 2, 3})
  render.attach(&app.renderer, point_light.index, render.point_light_attachment(color = color_preset(point_color, f32(point_intensity)), radius = f32(point_radius)))
  spot_light = world.spawn(&app.scene, {-4, 5, 0})
  render.attach(&app.renderer, spot_light.index, render.spot_light_attachment(color = color_preset(spot_color, f32(spot_intensity)), radius = f32(spot_radius), angle = math.PI * f32(spot_outer_deg) / 180.0))

  log.info("Lights — toggle each via UI, live tune color/intensity")
}

apply_light_settings :: proc(app: ^App) {
  if l, ok := render.attachment(&app.renderer, dir_light.index, render.DirectionalLightAttachment); ok {
    l.disabled = !dir_enabled
    l.color = color_preset(dir_color, f32(dir_intensity))
    render.attach(&app.renderer, dir_light.index, l)
  }
  if l, ok := render.attachment(&app.renderer, point_light.index, render.PointLightAttachment); ok {
    l.disabled = !point_enabled
    l.color = color_preset(point_color, f32(point_intensity))
    l.radius = f32(point_radius)
    render.attach(&app.renderer, point_light.index, l)
  }
  if l, ok := render.attachment(&app.renderer, spot_light.index, render.SpotLightAttachment); ok {
    l.disabled = !spot_enabled
    l.color = color_preset(spot_color, f32(spot_intensity))
    l.radius = f32(spot_radius)
    l.angle_outer = math.PI * f32(spot_outer_deg) / 180.0
    l.angle_inner = l.angle_outer * render.SPOT_LIGHT_INNER_RATIO
    render.attach(&app.renderer, spot_light.index, l)
  }
}

update :: proc(app: ^App, dt: f32) {
  platform.read_input(&app.window, &app.input)
  render.debug_ui_input(&app.renderer, &app.input)
  render.camera_controller_update(&app.camera, &app.renderer, &app.input, dt)
  point_orbit_phase += dt * 0.7
  world.translate(&app.scene, point_light, math.cos(point_orbit_phase) * 4.0, 2.5 + math.sin(point_orbit_phase * 1.3) * 0.8, math.sin(point_orbit_phase) * 4.0)

  spot_sweep_phase += dt * 0.5
  pos := [3]f32{math.cos(spot_sweep_phase) * 6.0, 5.0 + math.sin(spot_sweep_phase * 0.7) * 1.5, math.sin(spot_sweep_phase) * 6.0}
  world.translate(&app.scene, spot_light, pos)
  dir := linalg.normalize([3]f32{0, 0.5, 0} - pos)
  world.rotate(&app.scene, spot_light, linalg.quaternion_between_two_vector3(linalg.VECTOR3F32_Z_AXIS, dir))
  apply_light_settings(app)
  world.update(&app.scene)
  for i in world.removed_nodes(&app.scene) do render.stage_slot_removal(&app.renderer, i)
  for n in world.changed_nodes(&app.scene) do render.stage_transform(&app.renderer, n.index, n.world_matrix, n.visible)
  render.update(&app.renderer, dt)
}

frame :: proc(app: ^App) -> bool {
  platform.poll_events(&app.window)
  debug_ui(app)
  return render.frame(&app.renderer, platform.framebuffer_size(&app.window), platform.dpi_scale(&app.window))
}

debug_ui :: proc(app: ^App) {
  ctx := render.debug_ui(&app.renderer)
  if mu.window(ctx, "Lights", {700, 20, 280, 600}, {.NO_CLOSE}) {
    light_block(ctx, "Directional", &dir_enabled, &dir_intensity, nil, nil, &dir_color)
    light_block(ctx, "Point (orbit)", &point_enabled, &point_intensity, &point_radius, nil, &point_color)
    light_block(ctx, "Spot", &spot_enabled, &spot_intensity, &spot_radius, &spot_outer_deg, &spot_color)
  }
}

light_block :: proc(ctx: ^mu.Context, name: string, enabled: ^bool, intensity: ^mu.Real, radius: ^mu.Real, cone: ^mu.Real, color: ^mu.Real) {
  mu.layout_row(ctx, {-1}, 0)
  mu.checkbox(ctx, fmt.tprintf("%s", name), enabled)
  mu.label(ctx, "Intensity:")
  mu.slider(ctx, intensity, 0.0, 20.0)
  if radius != nil {
    mu.label(ctx, "Range:")
    mu.slider(ctx, radius, 1.0, 30.0)
  }
  if cone != nil {
    mu.label(ctx, "Cone angle (deg):")
    mu.slider(ctx, cone, 5.0, 80.0)
  }
  mu.label(ctx, "Color: 0=warm 1=neutral 2=cool")
  mu.slider(ctx, color, 0.0, 2.0, 1.0)
}

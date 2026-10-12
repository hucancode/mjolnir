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
import "core:math/rand"
import mu "vendor:microui"

App :: struct {
  window:   platform.Platform,
  scene:    world.World,
  renderer: render.Manager,
  camera:   render.CameraController,
  input:    input.State,
}

LightKind :: enum {
  POINT,
  SPOT,
}

// A moving light: each axis follows base + amp * sin(freq * t + phase).
MovingLight :: struct {
  node:  world.NodeHandle,
  kind:  LightKind,
  color: [3]f32,
  base:  [3]f32,
  amp:   [3]f32,
  freq:  [3]f32,
  phase: [3]f32,
}

STARTUP_LIGHTS :: 3
MARKER_SCALE :: 0.15

lights: [dynamic]MovingLight
marker_material: render.MaterialHandle
elapsed: f32

dir_light: world.NodeHandle
dir_enabled: bool = true
dir_intensity: mu.Real = 0.5

point_enabled: bool = true
point_intensity: mu.Real = 2.0
point_radius: mu.Real = 8.0

spot_enabled: bool = true
spot_intensity: mu.Real = 3.0
spot_radius: mu.Real = 15.0
spot_outer_deg: mu.Real = 28.0

main :: proc() {
  context.logger = log.create_console_logger()
  // fixed seed keeps the startup lights reproducible for golden-image capture
  rand.reset(1)
  app := new(App)
  defer free(app)
  defer delete(lights)
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

setup :: proc(app: ^App) {
  render.main_camera_look_at(&app.renderer, {9, 8, 9}, {0, 1, 0})
  app.renderer.ambient.ibl_intensity = 0.3

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
  render.attach(&app.renderer, dir_light.index, render.directional_light_attachment(color = {1, 1, 1, f32(dir_intensity)}, shadow_radius = 12.0, cast_shadow = true))

  // Glowing marker so each light's position is visible.
  marker_material = render.create_material(&app.renderer, emissive_value = 4.0)

  for i in 0 ..< STARTUP_LIGHTS do spawn_light(app, .SPOT if i == STARTUP_LIGHTS - 1 else .POINT)
  log.info("Lights: P spawns a point light, O a spot light, DELETE removes a random one")
}

spawn_light :: proc(app: ^App, kind: LightKind) {
  if len(lights) >= render.MAX_LIGHTS - 1 do return
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
  // keep the light above the ground
  l.amp.y = min(l.amp.y, l.base.y - 0.5)
  node, ok := world.spawn(&app.scene, light_position(l))
  if !ok do return
  l.node = node
  switch kind {
  case .POINT:
    render.attach(&app.renderer, node.index, render.point_light_attachment(radius = f32(point_radius)))
  case .SPOT:
    render.attach(&app.renderer, node.index, render.spot_light_attachment(radius = f32(spot_radius), angle = math.to_radians(f32(spot_outer_deg))))
  }
  // A slot holds one attachment, so the marker mesh lives on a child node.
  marker := world.spawn_child(&app.scene, node)
  render.attach(&app.renderer, marker.index, render.MeshAttachment{handle = app.renderer.builtin_meshes[.CUBE], material = marker_material, cast_shadow = false})
  world.scale(&app.scene, marker, MARKER_SCALE)
  append(&lights, l)
}

remove_random_light :: proc(app: ^App) {
  if len(lights) == 0 do return
  i := rand.int_max(len(lights))
  world.despawn(&app.scene, lights[i].node)
  unordered_remove(&lights, i)
}

random_color :: proc() -> [3]f32 {
  // random hue at full saturation
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

light_position :: proc(l: MovingLight) -> [3]f32 {
  return l.base + l.amp * [3]f32{math.sin(l.freq.x * elapsed + l.phase.x), math.sin(l.freq.y * elapsed + l.phase.y), math.sin(l.freq.z * elapsed + l.phase.z)}
}

apply_light_settings :: proc(app: ^App) {
  if l, ok := render.attachment(&app.renderer, dir_light.index, render.LightAttachment); ok {
    world.set_visible(&app.scene, dir_light, dir_enabled)
    l.color = {1, 1, 1, f32(dir_intensity)}
    render.attach(&app.renderer, dir_light.index, l)
  }
  for ml in lights {
    color := [4]f32{ml.color.r, ml.color.g, ml.color.b, 0}
    switch ml.kind {
    case .POINT:
      l := render.attachment(&app.renderer, ml.node.index, render.LightAttachment) or_continue
      world.set_visible(&app.scene, ml.node, point_enabled)
      l.color = color
      l.color.a = f32(point_intensity)
      l.radius = f32(point_radius)
      render.attach(&app.renderer, ml.node.index, l)
    case .SPOT:
      l := render.attachment(&app.renderer, ml.node.index, render.LightAttachment) or_continue
      world.set_visible(&app.scene, ml.node, spot_enabled)
      l.color = color
      l.color.a = f32(spot_intensity)
      l.radius = f32(spot_radius)
      l.angle_outer = math.to_radians(f32(spot_outer_deg))
      l.angle_inner = l.angle_outer * render.SPOT_LIGHT_INNER_RATIO
      render.attach(&app.renderer, ml.node.index, l)
    }
  }
}

update :: proc(app: ^App, dt: f32) {
  platform.read_input(&app.window, &app.input)
  render.debug_ui_input(&app.renderer, &app.input)
  render.camera_controller_update(&app.camera, &app.renderer, &app.input, dt)
  if input.key_pressed(&app.input, .P) do spawn_light(app, .POINT)
  if input.key_pressed(&app.input, .O) do spawn_light(app, .SPOT)
  if input.key_pressed(&app.input, .DELETE) do remove_random_light(app)

  elapsed += dt
  for l in lights {
    pos := light_position(l)
    world.translate(&app.scene, l.node, pos)
    if l.kind == .SPOT {
      dir := linalg.normalize([3]f32{0, 0.5, 0} - pos)
      world.rotate(&app.scene, l.node, linalg.quaternion_between_two_vector3(linalg.VECTOR3F32_Z_AXIS, dir))
    }
  }
  apply_light_settings(app)
  world.update(&app.scene)
  for i in world.removed_nodes(&app.scene) do render.stage_slot_removal(&app.renderer, i)
  render.stage_transforms(&app.renderer, world.changed_nodes(&app.scene))
  render.update(&app.renderer, dt)
}

frame :: proc(app: ^App) -> bool {
  platform.poll_events(&app.window)
  debug_ui(app)
  return render.frame(&app.renderer, platform.framebuffer_size(&app.window), platform.dpi_scale(&app.window))
}

debug_ui :: proc(app: ^App) {
  ctx := render.debug_ui(&app.renderer)
  if mu.window(ctx, "Lights", {700, 20, 280, 620}, {.NO_CLOSE}) {
    point_count, spot_count: int
    for l in lights {
      if l.kind == .POINT do point_count += 1
      else do spot_count += 1
    }
    mu.layout_row(ctx, {-1}, 0)
    mu.label(ctx, fmt.tprintf("%d point, %d spot", point_count, spot_count))
    mu.layout_row(ctx, {85, 85, -1}, 0)
    if .SUBMIT in mu.button(ctx, "+Point [P]") do spawn_light(app, .POINT)
    if .SUBMIT in mu.button(ctx, "+Spot [O]") do spawn_light(app, .SPOT)
    if .SUBMIT in mu.button(ctx, "Remove [Del]") do remove_random_light(app)
    light_block(ctx, "Directional", &dir_enabled, &dir_intensity, nil, nil)
    light_block(ctx, "Point lights", &point_enabled, &point_intensity, &point_radius, nil)
    light_block(ctx, "Spot lights", &spot_enabled, &spot_intensity, &spot_radius, &spot_outer_deg)
  }
}

light_block :: proc(ctx: ^mu.Context, name: string, enabled: ^bool, intensity: ^mu.Real, radius: ^mu.Real, cone: ^mu.Real) {
  mu.layout_row(ctx, {-1}, 0)
  mu.checkbox(ctx, name, enabled)
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
}

// Thunder: lightning bolts strike out of the night onto Mjolnir. Click to strike, drag to look around. Ported from the storm on hucancode.com.
package main

import "mjolnir"
import "mjolnir/debugui"
import "mjolnir/geometry"
import "mjolnir/gltf"
import "mjolnir/input"
import "mjolnir/platform"
import "mjolnir/render"
import "mjolnir/world"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:math/rand"
import mu "vendor:microui"

MOONLIGHT :: f32(0.5)
FLASH_GAIN :: f32(1.5)
FILL_POSITION :: [3]f32{3, 4, 5}
FILL_COLOR :: [3]f32{1, 1, 1}
FILL_INTENSITY :: f32(100)
CLICK_DISTANCE :: f32(6)
FIELD_RADIUS :: f32(60)
HAMMER_RADIUS :: f32(1.2)

App :: struct {
  platform: platform.Platform,
  scene:    world.World,
  renderer: render.Renderer,
  debug:    debugui.Context,
  input:    input.State,
  orbit:    render.Orbit,
  storm:    Storm,
  model:    gltf.Model,
  hammer:   gltf.Instance,
  bolts:    render.BufferHandle,
  bolt:     render.DrawShader,
  lamps:    [MAX_LIGHTS]world.NodeHandle,
  lights:   [MAX_LIGHTS]render.LightHandle,
  pressed:  bool,
  dragged:  f32,
  instances: [MAX_BOLTS]BoltInstance,
}

bloom: f32 = 1
orbiting := true

main :: proc() {
  context.logger = log.create_console_logger()
  app := new(App)
  if !platform.init(&app.platform, 1100, 720, "Thunder") do return
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
  if !debugui.init(&app.debug, r, {1100, 720}) do return .FAIL
  app.orbit = render.make_orbit({7, 3, 5}, {0, 1.6, 0})
  render.camera_orbit(render.main_camera(r), app.orbit)
  render.camera_set_perspective(render.main_camera(r), math.to_radians(f32(50)), 0.3, 600)

  app.model = gltf.model_create(r, #load("assets/Mjolnir.glb"))
  app.hammer = gltf.instance_create(&app.model, &app.scene, r)
  if len(app.hammer.roots) == 0 do return .FAIL
  world.translate(&app.scene, app.hammer.roots[0], {0, 0.106, 0})

  floor_material := render.material_create(r, render.make_material(base_color_factor = {0.02, 0.02, 0.035, 1}, roughness_value = 0.35))
  floor := world.spawn(&app.scene)
  render.attach(r, render.SlotHandle(floor.index), render.primitive(r, .QUAD_XZ, floor_material, cast_shadow = false))
  world.scale(&app.scene, floor, 400)

  for i in 0 ..< MAX_LIGHTS {
    app.lamps[i] = world.spawn(&app.scene)
    app.lights[i] = render.light_create(r, render.make_point_light(color = color_a, intensity = 0, radius = 40, cast_shadow = false))
    render.attach(r, render.SlotHandle(app.lamps[i].index), app.lights[i])
  }

  fill := world.spawn(&app.scene)
  world.translate(&app.scene, fill, FILL_POSITION)
  render.attach(r, render.SlotHandle(fill.index), render.light_create(r, render.make_point_light(color = FILL_COLOR, intensity = FILL_INTENSITY, radius = 30)))

  if !rod_create(r) do return .FAIL
  app.bolts = render.buffer_create(r, make([]BoltInstance, MAX_BOLTS, context.temp_allocator))
  ok: bool
  app.bolt, ok = render.draw_shader_create(
    r,
    #load("bolt." + render.SHADER_EXT),
    render.DrawState{mesh_vertices = true, topology = .TRIANGLE_LIST, cull = .NONE, blend = .ADDITIVE, depth_test = true},
    app.bolts,
  )
  if !ok do return .FAIL

  app.storm.tint = color_a
  r.skybox_intensity = 0
  r.ibl_intensity = 0
  r.sun = render.Sun{enabled = true, color = color_a, intensity = MOONLIGHT, direction = {-0.3, -1, -0.2}}
  append(&r.effect_stack, render.BloomEffect{threshold = 1, intensity = bloom, blur_radius = 32})
  return .READY
}

shutdown :: proc(app: ^App) {
  storm_destroy(&app.storm)
  rod_destroy(&app.renderer)
  gltf.destroy(&app.hammer, &app.scene)
  gltf.destroy(&app.model, &app.renderer)
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
  r := &app.renderer
  render.lock(r)
  defer render.unlock(r)
  platform.read_input(&app.platform, &app.input)
  debugui.feed(&app.debug, &app.input, r)
  debug_ui(app)
  render.stage_overlay(r, debugui.end(&app.debug))
  click_to_strike(app)
  render.orbit_drag(&app.orbit, &app.input)
  if orbiting && !app.pressed do app.orbit.yaw += dt * 0.04
  camera := render.main_camera(r)
  render.camera_orbit(camera, app.orbit)
  eye, _ := render.camera_pose(camera)

  lights := advance(&app.storm, min(dt, 0.05), eye)
  for sample, i in lights {
    world.translate(&app.scene, app.lamps[i], sample.position)
    lamp := render.light(r, app.lights[i])
    lamp.intensity = sample.intensity
    lamp.color = sample.color
  }
  r.sun.color = app.storm.tint
  r.sun.intensity = MOONLIGHT + min(app.storm.flash, 1) * FLASH_GAIN
  r.effect_stack[0] = render.BloomEffect{threshold = 1, intensity = bloom, blur_radius = 32}

  stage_bolts(app)

  world.update(&app.scene)
  render.stage_transforms(r, world.changes(&app.scene))
  render.update(r, dt)
}

BoltParams :: struct {
  first: u32,
}

stage_bolts :: proc(app: ^App) {
  r := &app.renderer
  bolts := 0
  for &b in app.storm.bolts {
    for rod in 0 ..< rod_count(&b) {
      if bolts >= MAX_BOLTS do break
      app.instances[bolts] = instance(&b, rod, app.storm.time - b.born)
      bolts += 1
    }
  }
  if bolts == 0 do return
  render.buffer_write(r, app.bolts, app.instances[:bolts])
  render.stage_draw(r, app.bolt, rod, u32(bolts), BoltParams{})
}

click_to_strike :: proc(app: ^App) {
  s := &app.input
  if s.mouse_captured do return
  if input.mouse_pressed(s, .LEFT) {
    app.pressed = true
    app.dragged = 0
  }
  if app.pressed do app.dragged += linalg.length(s.mouse_delta)
  if input.mouse_released(s, .LEFT) {
    if app.pressed && app.dragged < CLICK_DISTANCE do strike_at_cursor(app)
    app.pressed = false
  }
}

strike_at_cursor :: proc(app: ^App) {
  ray, ok := render.cursor_ray(&app.renderer, app.input.cursor)
  if !ok do return
  t := FIELD_RADIUS
  if ray.direction.y < -1e-3 do t = min(-ray.origin.y / ray.direction.y, FIELD_RADIUS)
  hit := ray.origin + ray.direction * t
  hit.y = 0
  strike(&app.storm, hit, 1 + rand.float32() * 0.5, hits_hammer(ray, hit))
}

hits_hammer :: proc(ray: geometry.Ray, hit: [3]f32) -> bool {
  if math.hypot(hit.x, hit.z) < HAMMER_RADIUS + 0.4 do return true
  o, d := ray.origin, ray.direction
  a := d.x * d.x + d.z * d.z
  b := o.x * d.x + o.z * d.z
  disc := b * b - a * (o.x * o.x + o.z * o.z - HAMMER_RADIUS * HAMMER_RADIUS)
  if a < 1e-6 || disc < 0 do return false
  root := math.sqrt(disc)
  s0 := max((-b - root) / a, 0)
  s1 := (-b + root) / a
  if s0 > s1 do return false
  return min(o.y + d.y * s0, o.y + d.y * s1) < HAMMER_TIP.y + 0.8
}

frame :: proc(app: ^App) -> bool {
  platform.poll_events(&app.platform)
  return render.frame(&app.renderer)
}

debug_ui :: proc(app: ^App) {
  ctx := debugui.begin(&app.debug)
  if debugui.window(&app.debug, "Thunder", {20, 20, 280, 520}, {}, {.NO_CLOSE}) {
    mu.layout_row(ctx, {-1}, 0)
    mu.label(ctx, "Click: strike   Drag: look around")
    mu.label(ctx, "Strike rate"); mu.slider(ctx, &rate, 0, 4)
    mu.label(ctx, "Raging thunder"); mu.slider(ctx, &rage, 0, 0.8)
    mu.label(ctx, "Jaggedness"); mu.slider(ctx, &jag, 0.1, 1)
    mu.label(ctx, "Thin / thick")
    mu.layout_row(ctx, {125, -1}, 0)
    mu.slider(ctx, &thickness_min, 0.05, 5)
    mu.slider(ctx, &thickness_max, 0.05, 20)
    mu.layout_row(ctx, {-1}, 0)
    mu.label(ctx, "Width tones"); mu.slider(ctx, &tones, 2, 8, 1)
    mu.label(ctx, "Halo"); mu.slider(ctx, &halo, 0, 1)
    mu.label(ctx, "Color A / color B")
    mu.layout_row(ctx, {85, 85, -1}, 0)
    for &channel in color_a do mu.slider(ctx, &channel, 0, 1)
    for &channel in color_b do mu.slider(ctx, &channel, 0, 1)
    mu.layout_row(ctx, {-1}, 0)
    mu.label(ctx, "Re-strikes"); mu.slider(ctx, &restrikes, 0, 10, 1)
    mu.label(ctx, "Bloom"); mu.slider(ctx, &bloom, 0, 5)
    mu.checkbox(ctx, "Auto rotate", &orbiting)
  }
}

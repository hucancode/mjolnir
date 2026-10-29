// GPU programming: a school of fish simulated by a compute shader, drawn by a draw shader.
package main

import "mjolnir"
import "mjolnir/debugui"
import "mjolnir/geometry"
import "mjolnir/input"
import "mjolnir/platform"
import "mjolnir/render"
import "mjolnir/world"
import "core:fmt"
import "core:log"
import "core:math"
import "core:math/rand"
import mu "vendor:microui"

MAX_FISH :: 4096
FISH_VERTICES :: render.VertexCount(16 * 10 * 6)
TANK_MIN :: [3]f32{-12, 0.6, -12}
TANK_MAX :: [3]f32{12, 7, 12}

Fish :: struct {
  position: [3]f32,
  phase:    f32,
  velocity: [3]f32,
  size:     f32,
}

Counters :: struct {
  vertex_count:   u32,
  instance_count: u32,
  first_vertex:   u32,
  first_instance: u32,
  feeding:        u32,
  speed_milli:    u32,
  _:              [2]u32,
}

SchoolParams :: struct {
  count:      u32,
  src:        u32,
  dt:         f32,
  vertices:   u32,
  food:       [4]f32,
  predator:   [4]f32,
  weights:    [4]f32,
  tank_min:   [4]f32,
  tank_max:   [4]f32,
}

FishParams :: struct {
  first: u32,
}

App :: struct {
  platform: platform.Platform,
  scene:    world.World,
  renderer: render.Renderer,
  debug:    debugui.Context,
  input:    input.State,
  orbit:    render.Orbit,
  fish:     render.BufferHandle,
  counters: render.BufferHandle,
  school:   render.ComputeShader,
  draw:     render.DrawShader,
  shark:    world.NodeHandle,
  food:     [3]f32,
  feeding:  f32,
  time:     f32,
  tick:     u32,
  stats:    [1]Counters,
}

fish_count: f32 = 2048
separation: f32 = 1.6
alignment: f32 = 0.8
cohesion: f32 = 0.6
max_speed: f32 = 3.5
shark_on := true

main :: proc() {
  context.logger = log.create_console_logger()
  app := new(App)
  if !platform.init(&app.platform, 1280, 720, "Fish School") do return
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
  r := &app.renderer
  if !render.ready(r) do return .WAIT
  if !debugui.init(&app.debug, r) do return .FAIL
  app.orbit = render.make_orbit({0, 9, 22}, {0, 3, 0})
  render.camera_orbit(render.main_camera(r), app.orbit)

  fish := make([]Fish, 2 * MAX_FISH, context.temp_allocator)
  for &f in fish[:MAX_FISH] {
    f.position = {rand.float32_range(TANK_MIN.x, TANK_MAX.x), rand.float32_range(TANK_MIN.y, TANK_MAX.y), rand.float32_range(TANK_MIN.z, TANK_MAX.z)}
    f.velocity = {rand.float32_range(-1, 1), 0, rand.float32_range(-1, 1)}
    f.phase = rand.float32_range(0, math.TAU)
    f.size = rand.float32_range(0.25, 0.45)
  }
  copy(fish[MAX_FISH:], fish[:MAX_FISH])
  app.fish = render.buffer_create(r, fish)
  app.counters = render.buffer_create(r, []Counters{{}}, {.INDIRECT, .READBACK})
  ok: bool
  app.school, ok = render.compute_shader_create(r, #load("school." + render.SHADER_EXT), app.fish, app.counters)
  if !ok do return .FAIL
  app.draw, ok = render.draw_shader_create(r, #load("fish." + render.SHADER_EXT), render.DEFAULT_DRAW_STATE, app.fish)
  if !ok do return .FAIL

  sand := render.material_create(r, render.make_material(base_color_factor = {0.76, 0.66, 0.45, 1}, roughness_value = 0.9))
  mjolnir.spawn(&app.scene, r, render.primitive(r, .QUAD_XZ, sand, cast_shadow = false), scale = 40)
  rock := render.material_create(r, render.make_material(base_color_factor = {0.35, 0.38, 0.4, 1}, roughness_value = 0.8))
  for i in 0 ..< 7 {
    angle := f32(i) / 7 * math.TAU
    mjolnir.spawn(&app.scene, r, render.primitive(r, .SPHERE, rock), {math.cos(angle) * 9, 0, math.sin(angle) * 9}, scale = {1.6, 1.1 + f32(i % 3) * 0.6, 1.4})
  }
  app.shark = mjolnir.spawn(&app.scene, r, render.primitive(r, .SPHERE, .RED), scale = 0.6)

  sun := &r.sun
  sun.color = {0.75, 0.9, 1}
  sun.intensity = 2.5
  r.skybox_intensity = 0
  append(&r.effect_stack, render.FogEffect{color = {0.05, 0.25, 0.35}, start = 2, end = 45})
  return .READY
}

shutdown :: proc(app: ^App) {
  world.shutdown(&app.scene)
  debugui.shutdown(&app.debug)
  render.shutdown(&app.renderer)
  platform.shutdown(&app.platform)
  free(app)
}

update :: proc(app: ^App, dt: f32) {
  render.lock(&app.renderer)
  defer render.unlock(&app.renderer)
  platform.read_input(&app.platform, &app.input)
  debug_ui(app)
  mjolnir.orbit_drag(&app.orbit, render.main_camera(&app.renderer), &app.input, {.RIGHT})
  if !app.input.mouse_captured && input.mouse_pressed(&app.input, .LEFT) do drop_food(app)
  app.time += dt
  app.feeding = max(app.feeding - dt, 0)
  shark := [3]f32{math.cos(app.time * 0.4) * 8, 3 + math.sin(app.time * 0.9) * 1.5, math.sin(app.time * 0.4) * 8}
  world.translate(&app.scene, app.shark, shark)
  world.set_visible(&app.scene, app.shark, shark_on)
  simulate(app, dt, shark)
  render.buffer_read(&app.renderer, app.counters, app.stats[:])
  mjolnir.update(&app.scene, &app.renderer, dt)
}

drop_food :: proc(app: ^App) {
  ray, ok := render.cursor_ray(&app.renderer, app.input.cursor)
  if !ok do return
  at, hit := geometry.ray_plane_intersection(ray, 0, {0, 1, 0})
  if !hit do return
  app.food = at + {0, 2, 0}
  app.feeding = 8
}

simulate :: proc(app: ^App, dt: f32, shark: [3]f32) {
  count := u32(fish_count)
  src := app.tick % 2
  app.tick += 1
  params := SchoolParams {
    count    = count,
    src      = src,
    dt       = min(dt, 0.05),
    vertices = u32(FISH_VERTICES),
    food     = {app.food.x, app.food.y, app.food.z, 1 if app.feeding > 0 else 0},
    predator = {shark.x, shark.y, shark.z, 1 if shark_on else 0},
    weights  = {separation, alignment, cohesion, max_speed},
    tank_min = {TANK_MIN.x, TANK_MIN.y, TANK_MIN.z, 0},
    tank_max = {TANK_MAX.x, TANK_MAX.y, TANK_MAX.z, 0},
  }
  render.stage_clear(&app.renderer, app.counters)
  render.stage_dispatch(&app.renderer, app.school, {(count + 63) / 64, 1, 1}, params)
  render.stage_draw_indirect(&app.renderer, app.draw, FISH_VERTICES, app.counters, 0, FishParams{first = (1 - src) * MAX_FISH})
}

draw :: proc(app: ^App) -> bool {
  return mjolnir.frame(&app.platform, &app.renderer)
}

debug_ui :: proc(app: ^App) {
  ctx := debugui.begin(&app.debug, &app.input, &app.renderer)
  defer debugui.end(&app.debug, &app.renderer)
  if debugui.window(&app.debug, "Fish School", {20, 20, 300, 420}) {
    mu.layout_row(ctx, {-1}, 0)
    mu.label(ctx, "Left click: drop food   Right drag: orbit")
    mu.label(ctx, fmt.tprintf("Drawn: %d   feeding: %d", app.stats[0].instance_count, app.stats[0].feeding))
    average := f32(app.stats[0].speed_milli) / 1000 / max(f32(app.stats[0].instance_count), 1)
    mu.label(ctx, fmt.tprintf("Average speed: %.2f", average))
    mu.label(ctx, "Fish"); mu.slider(ctx, &fish_count, 64, MAX_FISH, 64)
    mu.label(ctx, "Separation"); mu.slider(ctx, &separation, 0, 4)
    mu.label(ctx, "Alignment"); mu.slider(ctx, &alignment, 0, 4)
    mu.label(ctx, "Cohesion"); mu.slider(ctx, &cohesion, 0, 4)
    mu.label(ctx, "Max speed"); mu.slider(ctx, &max_speed, 1, 8)
    mu.checkbox(ctx, "Shark", &shark_on)
  }
}

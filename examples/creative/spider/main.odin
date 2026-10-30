// Procedural spider legs — IK + parabolic foot lift. Drive the spider with WASD.
package main

import "core:log"
import "core:math"
import "core:math/linalg"
import mu "vendor:microui"
import "mjolnir"
import "mjolnir/animation"
import "mjolnir/debugui"
import "mjolnir/gltf"
import "mjolnir/input"
import "mjolnir/platform"
import "mjolnir/render"
import "mjolnir/world"

LEG_COUNT :: 6
LEG_CHAINS := [LEG_COUNT]struct {
  root, tip: string,
} {
  {"leg_front_r_0", "leg_front_r_5"},
  {"leg_middle_r_0", "leg_middle_r_5"},
  {"leg_back_r_0", "leg_back_r_5"},
  {"leg_front_l_0", "leg_front_l_5"},
  {"leg_middle_l_0", "leg_middle_l_5"},
  {"leg_back_l_0", "leg_back_l_5"},
}
HIP_LIMIT :: animation.JointLimit{{math.PI / 6, math.PI / 2, math.PI / 6}}
JOINT_LIMIT :: animation.JointLimit{{math.PI / 2, math.PI / 2, math.PI / 2}}
STRIDE :: 4.5
MIN_PERIOD :: 0.3
MAX_PERIOD :: 3.0
GROUND_TOP :: 0.1
GROUND_SIZE :: 60
BODY_RANGE :: GROUND_SIZE / 2 - 1

App :: struct {
  platform:       platform.Platform,
  scene:          world.World,
  renderer:       render.Renderer,
  input:          input.State,
  debug:          debugui.Context,
  orbit:          render.Orbit,
  spider_model:   gltf.Model,
  spider:         gltf.Instance,
  spider_mesh:    world.NodeHandle,
  rig:            gltf.RigHandle,
  legs:           [LEG_COUNT]animation.LayerHandle,
  time:           f32,
  lift_height:    f32,
  lift_period:    f32,
  autopilot:      bool,
  lap_time:       f32,
  body_speed_max: f32,
  body_position:  [3]f32,
  body_height:    f32,
  grounded:       bool,
}

main :: proc() {
  context.logger = log.create_console_logger()
  app := new(App)
  app.autopilot = true
  app.lift_height = 0.5
  app.lap_time = 2
  app.body_speed_max = 5
  app.body_height = 2
  app.body_position = {0, app.body_height, 0}
  if !platform.init(&app.platform, 1280, 720, "Spider") do return
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

shutdown :: proc(app: ^App) {
  gltf.destroy(&app.spider, &app.scene, &app.renderer)
  gltf.destroy(&app.spider_model, &app.renderer)
  world.shutdown(&app.scene)
  debugui.shutdown(&app.debug)
  render.shutdown(&app.renderer)
  platform.shutdown(&app.platform)
  free(app)
}

setup :: proc(app: ^App) -> mjolnir.Setup {
  if !render.ready(&app.renderer) do return .WAIT
  sun := render.light_create(&app.renderer, render.make_directional_light())
  mjolnir.spawn(&app.scene, &app.renderer, sun, rotation = linalg.quaternion_from_forward_and_up([3]f32{-0.4, -1, -0.3}, [3]f32{0, 1, 0}))
  if !debugui.init(&app.debug, &app.renderer) do return .FAIL
  app.orbit = render.make_orbit({0, 20, 20}, {0, 0, 0})

  mjolnir.spawn(&app.scene, &app.renderer, render.primitive(&app.renderer, .CUBE, .GRAY), scale = {GROUND_SIZE, 0.2, GROUND_SIZE})
  mjolnir.spawn(&app.scene, &app.renderer, render.light_create(&app.renderer, render.make_point_light(intensity = 1200, radius = 80)), {0, 8, 0})

  app.spider_model = gltf.model_create(&app.renderer, #load("assets/spider.glb"))
  app.spider = gltf.instance_create(&app.spider_model, &app.scene, &app.renderer)
  if len(app.spider.skinned) == 0 do return .FAIL
  app.spider_mesh = app.spider.skinned[0].node
  app.rig = app.spider.skinned[0].rig
  rig, animator := &app.spider_model.rigs[app.rig], &app.spider.animators[app.rig]
  skel := &rig.skeleton
  limits := animation.bone_limits(animator)
  for chain, i in LEG_CHAINS {
    offset, _ := animation.rest_offset(skel, chain.root, chain.tip)
    bones, _ := animation.bone_chain(skel, chain.root, chain.tip, context.temp_allocator)
    for b, k in bones do limits[b] = HIP_LIMIT if k == 0 else JOINT_LIMIT
    leg := animation.LegParams{offset = offset}
    tripod_step(app, &leg, i)
    app.legs[i] = animation.layer_create(animator, rig, leg, bones)
  }
  return .READY
}

tripod_step :: proc(app: ^App, leg: ^animation.LegParams, index: int) {
  leg.lift_height = app.lift_height
  leg.lift_frequency = app.lift_period
  leg.lift_duration = leg.lift_frequency / 2
  leg.time_offset = leg.lift_frequency / 2 if index % 2 == 1 else 0
}

update :: proc(app: ^App, dt: f32) {
  render.lock(&app.renderer)
  platform.read_input(&app.platform, &app.input)
  debug_ui(app)
  mjolnir.orbit_drag(&app.orbit, render.main_camera(&app.renderer), &app.input)
  walk(app, dt)
  mjolnir.update(&app.scene, &app.renderer, dt)
  if app.grounded do pose_legs(app, dt)
  else do ground_body(app)
}

ground_body :: proc(app: ^App) {
  skel := &app.spider_model.rigs[app.rig].skeleton
  mesh_m := world.world_matrix(&app.scene, app.spider_mesh)
  lowest := f32(1e9)
  for chain in LEG_CHAINS {
    offset, _ := animation.rest_offset(skel, chain.root, chain.tip)
    p, _ := animation.rest_position(skel, chain.root)
    lowest = min(lowest, (mesh_m * [4]f32{p.x, p.y, p.z, 1}).y + offset.y)
  }
  app.body_height += GROUND_TOP - lowest
  app.grounded = true
}

walk :: proc(app: ^App, dt: f32) {
  move_body(app, dt)
  app.lift_period = clamp(STRIDE / app.body_speed_max, MIN_PERIOD, MAX_PERIOD)
  world.transform(&app.scene, app.spider.root).position = app.body_position
  for layer, i in app.legs {
    if leg, ok := animation.layer_params(&app.spider.animators[app.rig], layer, animation.LegParams); ok do tripod_step(app, leg, i)
  }
}

pose_legs :: proc(app: ^App, dt: f32) {
  gltf.animate(&app.spider, &app.spider_model, &app.scene, &app.renderer, dt)
  for layer in app.legs {
    if foot, ok := animation.leg_foot(&app.spider.animators[app.rig], layer); ok do render.debug_sphere(&app.renderer, foot, 0.2, {1, 0.2, 0.2, 1})
  }
}

move_body :: proc(app: ^App, dt: f32) {
  for key in ([?]input.Key{.W, .A, .S, .D}) {
    if input.key_down(&app.input, key) {
      app.autopilot = false
      app.time = 0
    }
  }
  if app.autopilot {
    lap := app.lap_time
    app.time = math.mod(app.time + dt, 2 * lap)
    direction: f32 = 1 if app.time < lap else -1
    app.body_position.x = clamp(app.body_position.x + direction * app.body_speed_max * dt, -BODY_RANGE, BODY_RANGE)
    app.body_position.y = app.body_height
    return
  }
  forward := linalg.normalize0([3]f32{-math.cos(app.orbit.yaw), 0, -math.sin(app.orbit.yaw)})
  right := [3]f32{-forward.z, 0, forward.x}
  dir := forward * input.axis(&app.input, .S, .W) + right * input.axis(&app.input, .A, .D)
  app.body_position += linalg.normalize0(dir) * app.body_speed_max * dt
  app.body_position.y = app.body_height
  app.body_position.x = clamp(app.body_position.x, -BODY_RANGE, BODY_RANGE)
  app.body_position.z = clamp(app.body_position.z, -BODY_RANGE, BODY_RANGE)
}

draw :: proc(app: ^App) -> bool {
  return mjolnir.frame(&app.platform, &app.renderer)
}

debug_ui :: proc(app: ^App) {
  ctx := debugui.begin(&app.debug, &app.input, &app.renderer)
  defer debugui.end(&app.debug, &app.renderer)
  if debugui.window(&app.debug, "Spider Legs", {20, 20, 300, 350}) {
    mu.layout_row(ctx, {-1}, 0)
    mu.label(ctx, "Move: WASD")
    mu.checkbox(ctx, "Autopilot", &app.autopilot)
    mu.label(ctx, "Walk speed"); mu.slider(ctx, &app.body_speed_max, 3, 15)
    mu.label(ctx, "Lift height"); mu.slider(ctx, &app.lift_height, 0.2, 1.5)
    if app.autopilot {
      mu.label(ctx, "Lap time (s)"); mu.slider(ctx, &app.lap_time, 0.5, 10)
    }
  }
}

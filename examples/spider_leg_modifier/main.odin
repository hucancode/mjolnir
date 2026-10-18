// Procedural spider legs — IK + parabolic foot lift.
package main

import "core:log"
import "core:math"
import "core:math/linalg"
import mu "vendor:microui"
import "../../mjolnir"
import "../../mjolnir/debugui"
import "../../mjolnir/animation"
import "../../mjolnir/gltf"
import "../../mjolnir/input"
import "../../mjolnir/platform"
import "../../mjolnir/render"
import "../../mjolnir/world"

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
BODY_HEIGHT :: 2

Tripod :: struct {
  lift_height:   mu.Real,
  lift_duration: mu.Real,
  phase:         mu.Real,
}

App :: struct {
  window:         platform.Platform,
  scene:          world.World,
  renderer:       render.Renderer,
  debug:          debugui.Context,
  input:          input.State,
  orbit:          render.Orbit,
  spider:         gltf.Scene,
  spider_root:    world.NodeHandle,
  spider_mesh:    world.NodeHandle,
  rig:            ^animation.Rig,
  animator:       animation.Animator,
  legs:           [LEG_COUNT]animation.LayerHandle,
  time:           f32,
  tripods:        [2]Tripod,
  lift_period:    mu.Real,
  animate_body:   bool,
  body_amplitude: mu.Real,
  body_speed:     mu.Real,
  body_target:    [2]mu.Real,
  body_lerp_rate: f32,
  body_max_speed: f32,
  body_position:  [3]f32,
}

main :: proc() {
  context.logger = log.create_console_logger()
  app := new(App)
  app.lift_period = 1.5
  app.tripods = {{0.5, 0.6, 0}, {0.5, 0.6, 0.75}}
  app.animate_body = true
  app.body_amplitude = 8
  app.body_speed = 0.05
  app.body_lerp_rate = 2
  app.body_max_speed = 4
  app.body_position = {0, BODY_HEIGHT, 0}
  w := &app.window
  if !platform.init(w, 900, 700, "Spider Leg") do return
  if !render.init(&app.renderer, "Spider Leg", w.window, platform.framebuffer_size(w), platform.dpi_scale(w)) do return
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

shutdown :: proc(app: ^App) {
  animation.destroy(&app.animator)
  gltf.destroy(&app.spider, &app.scene, &app.renderer)
  world.shutdown(&app.scene)
  debugui.shutdown(&app.debug)
  render.shutdown(&app.renderer)
  platform.shutdown(&app.window)
  free(app)
}

should_close :: proc(app: ^App) -> bool {
  return platform.should_close(&app.window)
}

setup :: proc(app: ^App) -> mjolnir.Setup {
  if !render.ready(&app.renderer) do return .WAIT
  if !debugui.init(&app.debug, &app.renderer) do return .FAIL
  render.camera_look_at(render.main_camera(&app.renderer), {0, 30, 15}, {0, 0, 0})
  app.orbit = render.orbit_from_camera(render.main_camera(&app.renderer))

  ground := world.spawn(&app.scene)
  render.attach(&app.renderer, render.SlotHandle(ground.index), render.primitive(&app.renderer, .CUBE, .GRAY))
  world.scale(&app.scene, ground, [3]f32{20, 0.2, 20})
  light := world.spawn(&app.scene, {0, 10, 0})
  render.attach(&app.renderer, render.SlotHandle(light.index), render.light_create(&app.renderer, render.make_point_light(intensity = 400, radius = 15)))

  app.spider = gltf.scene_create(&app.scene, &app.renderer, #load("../../assets/spider.glb"))
  if len(app.spider.roots) == 0 || len(app.spider.skinned) == 0 do return .FAIL
  app.spider_root = app.spider.roots[0]
  app.spider_mesh = app.spider.skinned[0].node
  app.rig = &app.spider.rigs[app.spider.skinned[0].rig]
  skel := &app.rig.skeleton
  animation.animator_init(&app.animator, app.rig)
  limits := animation.bone_limits(&app.animator)
  for chain, i in LEG_CHAINS {
    offset, _ := animation.rest_offset(skel, chain.root, chain.tip)
    bones, _ := animation.bone_chain(skel, chain.root, chain.tip, context.temp_allocator)
    for b, k in bones do limits[b] = HIP_LIMIT if k == 0 else JOINT_LIMIT
    leg := animation.LegParams{offset = offset}
    tripod_step(app, &leg, i)
    app.legs[i] = animation.layer_create(&app.animator, app.rig, leg, bones)
  }
  return .READY
}

tripod_step :: proc(app: ^App, leg: ^animation.LegParams, index: int) {
  tripod := app.tripods[index % 2]
  leg.lift_height = f32(tripod.lift_height)
  leg.lift_duration = f32(tripod.lift_duration)
  leg.lift_frequency = f32(app.lift_period)
  leg.time_offset = f32(tripod.phase)
}

update :: proc(app: ^App, dt: f32) {
  platform.read_input(&app.window, &app.input)
  debugui.feed(&app.debug, &app.input)
  if !app.input.mouse_captured {
    drag := app.input.mouse_delta if input.mouse_down(&app.input, .LEFT) else 0
    render.orbit_drag(&app.orbit, drag, app.input.scroll.y)
  }
  render.camera_orbit(render.main_camera(&app.renderer), app.orbit)
  if app.rig != nil do walk(app, dt)
  world.update(&app.scene)
  render.stage_transforms(&app.renderer, world.changes(&app.scene))
  if app.rig != nil do render.stage_bones(&app.renderer, render.SlotHandle(app.spider_mesh.index), app.animator.palette)
  render.update(&app.renderer, dt)
}

walk :: proc(app: ^App, dt: f32) {
  move_body(app, dt)
  world.translate(&app.scene, app.spider_root, app.body_position)
  for layer, i in app.legs {
    if leg, ok := animation.layer_params(&app.animator, layer, animation.LegParams); ok do tripod_step(app, leg, i)
  }
  animation.animator_update(&app.animator, app.rig, dt, world.world_matrix(&app.scene, app.spider_mesh))
  for layer in app.legs {
    if foot, ok := animation.leg_foot(&app.animator, layer); ok do render.debug_sphere(&app.renderer, foot, 0.2, {1, 0.2, 0.2, 1})
  }
}

move_body :: proc(app: ^App, dt: f32) {
  if app.animate_body {
    app.time += dt
    x := f32(app.body_amplitude) * math.sin(app.time * f32(app.body_speed) * 2 * math.PI)
    app.body_position = {x, BODY_HEIGHT, 0}
    app.body_target = {mu.Real(x), 0}
    return
  }
  target := [3]f32{f32(app.body_target.x), BODY_HEIGHT, f32(app.body_target.y)}
  step := linalg.lerp(app.body_position, target, 1 - math.exp(-app.body_lerp_rate * dt)) - app.body_position
  max_step := app.body_max_speed * dt
  if length := linalg.length(step); length > max_step do step *= max_step / length
  app.body_position += step
}

frame :: proc(app: ^App) -> bool {
  platform.poll_events(&app.window)
  ctx := debugui.begin(&app.debug)
  if mu.window(ctx, "Spider Legs", {500, 20, 340, 480}, {.NO_CLOSE}) {
    mu.layout_row(ctx, {-1}, 0)
    mu.label(ctx, "Body motion")
    mu.checkbox(ctx, "Animate body", &app.animate_body)
    if app.animate_body {
      mu.label(ctx, "Amplitude"); mu.slider(ctx, &app.body_amplitude, 0, 30)
      mu.label(ctx, "Speed (Hz)"); mu.slider(ctx, &app.body_speed, 0, 1)
    } else {
      mu.label(ctx, "Body X"); mu.slider(ctx, &app.body_target.x, -30, 30)
      mu.label(ctx, "Body Z"); mu.slider(ctx, &app.body_target.y, -30, 30)
    }
    mu.label(ctx, "Shared lift frequency (period s)"); mu.slider(ctx, &app.lift_period, 0.1, 4)
    mu.label(ctx, "Group B phase offset (s)"); mu.slider(ctx, &app.tripods[1].phase, 0, 4)
    mu.label(ctx, "Group A (legs 0, 2, 4)")
    mu.label(ctx, "Lift height"); mu.slider(ctx, &app.tripods[0].lift_height, 0, 5)
    mu.label(ctx, "Lift duration (s)"); mu.slider(ctx, &app.tripods[0].lift_duration, 0.05, 2)
    mu.label(ctx, "Group B (legs 1, 3, 5)")
    mu.label(ctx, "Lift height"); mu.slider(ctx, &app.tripods[1].lift_height, 0, 5)
    mu.label(ctx, "Lift duration (s)"); mu.slider(ctx, &app.tripods[1].lift_duration, 0.05, 2)
  }
  render.stage_overlay(&app.renderer, debugui.end(&app.debug))
  return render.frame(&app.renderer, platform.framebuffer_size(&app.window), platform.dpi_scale(&app.window))
}

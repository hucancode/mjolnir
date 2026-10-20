// Procedural spider legs — IK + parabolic foot lift. Drive the spider with WASD.
package main

import "core:log"
import "core:math"
import "core:math/linalg"
import mu "vendor:microui"
import "mjolnir"
import "mjolnir/debugui"
import "mjolnir/animation"
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
GROUND_TOP :: 0.1
BODY_RANGE :: 9

App :: struct {
  window:         platform.Platform,
  scene:          world.World,
  renderer:       render.Renderer,
  debug:          debugui.Context,
  input:          input.State,
  orbit:          render.Orbit,
  spider_model:   gltf.Model,
  spider:         gltf.Instance,
  spider_root:    world.NodeHandle,
  spider_mesh:    world.NodeHandle,
  rig:            ^animation.Rig,
  animator:       animation.Animator,
  legs:           [LEG_COUNT]animation.LayerHandle,
  time:           f32,
  lift_height:    mu.Real,
  lift_duration:  mu.Real,
  group_b_phase:  mu.Real,
  lift_period:    mu.Real,
  autopilot:      bool,
  body_amplitude: mu.Real,
  body_speed:     mu.Real,
  body_speed_max: f32,
  body_position:  [3]f32,
  body_height:    f32,
  grounded:       bool,
}

main :: proc() {
  context.logger = log.create_console_logger()
  app := new(App)
  app.lift_period = 1.5
  app.lift_height = 0.5
  app.lift_duration = 0.6
  app.group_b_phase = 0.75
  app.body_amplitude = 8
  app.body_speed = 0.05
  app.body_speed_max = 3
  app.body_height = 2
  app.body_position = {0, app.body_height, 0}
  w := &app.window
  if !platform.init(w, 900, 700, "Spider") do return
  if !render.init(&app.renderer, "Spider", w.window, platform.framebuffer_size(w), platform.dpi_scale(w)) do return
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
  gltf.destroy(&app.spider, &app.scene)
  gltf.destroy(&app.spider_model, &app.renderer)
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
  if !debugui.init(&app.debug, &app.renderer, {900, 700}) do return .FAIL
  render.camera_look_at(render.main_camera(&app.renderer), {0, 20, 20}, {0, 0, 0})
  app.orbit = render.orbit_from_camera(render.main_camera(&app.renderer), {0, 0, 0})

  ground := world.spawn(&app.scene)
  render.attach(&app.renderer, render.SlotHandle(ground.index), render.primitive(&app.renderer, .CUBE, .GRAY))
  world.scale(&app.scene, ground, [3]f32{20, 0.2, 20})
  light := world.spawn(&app.scene, {0, 8, 0})
  render.attach(&app.renderer, render.SlotHandle(light.index), render.light_create(&app.renderer, render.make_point_light(intensity = 400, radius = 35)))

  app.spider_model = gltf.model_create(&app.renderer, #load("assets/spider.glb"))
  app.spider = gltf.instance_create(&app.spider_model, &app.scene, &app.renderer)
  if len(app.spider.roots) == 0 || len(app.spider.skinned) == 0 do return .FAIL
  app.spider_root = app.spider.roots[0]
  app.spider_mesh = app.spider.skinned[0].node
  app.rig = &app.spider_model.rigs[app.spider.skinned[0].rig]
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
  leg.lift_height = f32(app.lift_height)
  leg.lift_duration = f32(app.lift_duration)
  leg.lift_frequency = f32(app.lift_period)
  leg.time_offset = f32(app.group_b_phase) if index % 2 == 1 else 0
}

update :: proc(app: ^App, dt: f32) {
  render.lock(&app.renderer)
  defer render.unlock(&app.renderer)
  platform.read_input(&app.window, &app.input)
  debugui.feed(&app.debug, &app.input, &app.renderer)
  debug_ui(app)
  render.stage_overlay(&app.renderer, debugui.end(&app.debug))
  if !app.input.mouse_captured {
    drag := app.input.mouse_delta if input.mouse_down(&app.input, .LEFT) else 0
    render.orbit_drag(&app.orbit, drag, app.input.scroll.y)
  }
  render.camera_orbit(render.main_camera(&app.renderer), app.orbit)
  if app.rig != nil do walk(app, dt)
  world.update(&app.scene)
  calibrating := app.rig != nil && !app.grounded
  if calibrating do ground_body(app)
  if app.rig != nil && !calibrating do pose_legs(app, dt)
  render.stage_transforms(&app.renderer, world.changes(&app.scene))
  if app.rig != nil && !calibrating do for s in app.spider.skinned do render.stage_bones(&app.renderer, render.SlotHandle(s.node.index), app.animator.palette)
  render.update(&app.renderer, dt)
}

// ground_body lowers the body so the lowest foot rest position touches the ground.
// Runs once, on the first frame, before any leg is posed (needs world matrices).
ground_body :: proc(app: ^App) {
  skel := &app.rig.skeleton
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
  world.translate(&app.scene, app.spider_root, app.body_position)
  for layer, i in app.legs {
    if leg, ok := animation.layer_params(&app.animator, layer, animation.LegParams); ok do tripod_step(app, leg, i)
  }
}

pose_legs :: proc(app: ^App, dt: f32) {
  animation.animator_update(&app.animator, app.rig, dt, world.world_matrix(&app.scene, app.spider_mesh))
  for layer in app.legs {
    if foot, ok := animation.leg_foot(&app.animator, layer); ok do render.debug_sphere(&app.renderer, foot, 0.2, {1, 0.2, 0.2, 1})
  }
}

move_body :: proc(app: ^App, dt: f32) {
  if app.autopilot {
    app.time += dt
    x := f32(app.body_amplitude) * math.sin(app.time * f32(app.body_speed) * 2 * math.PI)
    app.body_position = {x, app.body_height, 0}
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

frame :: proc(app: ^App) -> bool {
  platform.poll_events(&app.window)
  return render.frame(&app.renderer, platform.framebuffer_size(&app.window), platform.dpi_scale(&app.window))
}

debug_ui :: proc(app: ^App) {
  ctx := debugui.begin(&app.debug)
  if debugui.window(&app.debug, "Spider Legs", {580, 20, 300, 350}, {.RIGHT, .TOP}, {.NO_CLOSE}) {
    mu.layout_row(ctx, {-1}, 0)
    mu.label(ctx, "Move: WASD")
    mu.checkbox(ctx, "Autopilot", &app.autopilot)
    if app.autopilot {
      mu.label(ctx, "Amplitude"); mu.slider(ctx, &app.body_amplitude, 0, 30)
      mu.label(ctx, "Speed (Hz)"); mu.slider(ctx, &app.body_speed, 0, 1)
    } else {
      mu.label(ctx, "Walk speed"); mu.slider(ctx, &app.body_speed_max, 1, 5)
    }
    mu.label(ctx, "Shared lift frequency (period s)"); mu.slider(ctx, &app.lift_period, 0.1, 4)
    mu.label(ctx, "Group B phase offset (s)"); mu.slider(ctx, &app.group_b_phase, 0, 4)
    mu.label(ctx, "Lift height"); mu.slider(ctx, &app.lift_height, 0, 5)
    mu.label(ctx, "Lift duration (s)"); mu.slider(ctx, &app.lift_duration, 0.05, 2)
  }
}

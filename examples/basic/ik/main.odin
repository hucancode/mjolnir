// FABRIK on a single leg chain under different conditions: reachable, out of reach, too close, pole, joint limits, weight.
package main

import "core:fmt"
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

Scenario :: enum {
  CIRCLE,
  OUT_OF_REACH,
  TOO_CLOSE,
  POLE_ORBIT,
}

SCENARIO_NAMES := [Scenario]string {
  .CIRCLE       = "Circle",
  .OUT_OF_REACH = "Far",
  .TOO_CLOSE    = "Near",
  .POLE_ORBIT   = "Pole",
}

RED :: [4]f32{1, 0.2, 0.2, 1}
BLUE :: [4]f32{0.3, 0.5, 1, 1}
DIM :: [4]f32{0.5, 0.5, 0.5, 1}

App :: struct {
  platform:    platform.Platform,
  scene:       world.World,
  renderer:    render.Renderer,
  debug:       debugui.Context,
  input:       input.State,
  orbit:       render.Orbit,
  model:       gltf.Model,
  leg:         gltf.Instance,
  rig:         gltf.RigHandle,
  ik:          animation.LayerHandle,
  bones:       []u32,
  root:        [3]f32,
  reach:       f32,
  time:        f32,
  scenario:    Scenario,
  paused:      bool,
  was_paused:  bool,
  limit_deg:   f32,
  ik_weight:   f32,
  pole_weight: f32,
  iterations:  f32,
  manual:      [3]f32,
}

main :: proc() {
  context.logger = log.create_console_logger()
  app := new(App)
  app.limit_deg = 180
  app.ik_weight = 1
  app.pole_weight = 1
  app.iterations = 10
  if !platform.init(&app.platform, 1280, 720, "IK") do return
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

  mjolnir.spawn_mesh(&app.scene, &app.renderer, render.primitive(&app.renderer, .CUBE, .GRAY), scale = {20, 0.2, 20})
  light := world.spawn(&app.scene, {0, 12, 6})
  render.attach(&app.renderer, light, render.light_create(&app.renderer, render.make_point_light(intensity = 500, radius = 25)))

  app.model = gltf.model_create(&app.renderer, #load("assets/spider_leg.glb"))
  app.leg = gltf.instance_create(&app.model, &app.scene, &app.renderer)
  if len(app.leg.skinned) == 0 do return .FAIL
  app.rig = app.leg.skinned[0].rig
  rig := &app.model.rigs[app.rig]
  skel := &rig.skeleton
  app.bones, _ = animation.bone_chain(skel, "root", "leg_tip")
  if len(app.bones) < 3 do return .FAIL
  base, _ := animation.rest_position(skel, "root")
  tip, _ := animation.rest_position(skel, "leg_tip")
  app.root = base
  for b in app.bones[1:] {
    p, _ := animation.rest_position(skel, skel.names[b])
    app.reach += linalg.length(p - base)
    base = p
  }
  ik := animation.IKParams{target = tip, pole = app.root + {0, 0, app.reach}, pole_weight = 1, space = .WORLD}
  app.ik = animation.layer_create(&app.leg.animators[app.rig], rig, ik, app.bones)

  focus := app.root + {0, app.reach * 0.5, 0}
  app.orbit = render.make_orbit(focus + {0, app.reach * 0.6, app.reach * 2.2}, focus)
  render.camera_orbit(render.main_camera(&app.renderer), app.orbit)
  return .READY
}

shutdown :: proc(app: ^App) {
  gltf.destroy(&app.leg, &app.scene, &app.renderer)
  gltf.destroy(&app.model, &app.renderer)
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
  debugui.feed(&app.debug, &app.input, &app.renderer)
  debug_ui(app)
  render.stage_overlay(&app.renderer, debugui.end(&app.debug))
  render.orbit_drag(&app.orbit, render.main_camera(&app.renderer), &app.input)
  solve(app, dt)
  world.update(&app.scene)
  gltf.animate(&app.leg, &app.model, &app.scene, &app.renderer, dt)
  render.stage_transforms(&app.renderer, world.changes(&app.scene))
  render.update(&app.renderer, dt)
}

solve :: proc(app: ^App, dt: f32) {
  if !app.paused do app.time += dt
  t := app.time
  reach := app.reach
  mid := app.root + {0, reach * 0.5, 0}
  target := mid
  pole := app.root + {0, reach * 0.5, reach}
  switch app.scenario {
  case .CIRCLE:
    target = mid + {math.cos(t), 0, math.sin(t)} * reach * 0.6
  case .OUT_OF_REACH:
    far := reach * (1.3 + 0.7 * math.sin(t * 0.7))
    target = app.root + linalg.normalize([3]f32{0.4, 0.6, 0.7}) * far
  case .TOO_CLOSE:
    target = app.root + {0.2, 0.3 + 0.2 * math.sin(t), 0.2} * reach * (0.5 + 0.5 * math.sin(t * 0.5))
  case .POLE_ORBIT:
    target = app.root + {reach * 0.3, reach * 0.6, 0}
    pole = mid + {math.cos(t), 0, math.sin(t)} * reach
  }
  if app.paused && !app.was_paused do app.manual = target
  app.was_paused = app.paused
  if app.paused do target = app.manual
  target.y = max(target.y, 0.1)
  animator := &app.leg.animators[app.rig]
  limits := animation.bone_limits(animator)
  limit := app.limit_deg * math.RAD_PER_DEG
  for b in app.bones[1:] do limits[b] = animation.JointLimit{{limit, limit, limit}}
  if ik, ok := animation.layer_params(animator, app.ik, animation.IKParams); ok {
    ik.target, ik.pole = target, pole
    ik.pole_weight = app.pole_weight
    ik.iterations = int(app.iterations)
  }
  animation.layer_fade(animator, app.ik, app.ik_weight)
  r := &app.renderer
  reachable := linalg.length(target - app.root) <= reach
  render.debug_sphere(r, app.root, reach, DIM)
  render.debug_segment(r, app.root, target, RED if reachable else {1, 0.8, 0.1, 1})
  render.debug_sphere(r, target, 0.3, RED)
  if app.pole_weight > 0 {
    render.debug_sphere(r, pole, 0.2, BLUE)
    render.debug_segment(r, mid, pole, BLUE)
  }
}

draw :: proc(app: ^App) -> bool {
  return mjolnir.frame(&app.platform, &app.renderer)
}

debug_ui :: proc(app: ^App) {
  ctx := debugui.begin(&app.debug)
  if debugui.window(&app.debug, "IK", {20, 20, 300, 380}, {}) {
    mu.layout_row(ctx, {-1}, 0)
    mu.label(ctx, "Scenario")
    mu.layout_row(ctx, {68, 68, 68, 68}, 0)
    for s in Scenario {
      label := fmt.tprintf("%s%s", "> " if s == app.scenario else "", SCENARIO_NAMES[s])
      if .SUBMIT in mu.button(ctx, label) do app.scenario = s
    }
    mu.layout_row(ctx, {-1}, 0)
    mu.checkbox(ctx, "Pause", &app.paused)
    if app.paused {
      reach := app.reach * 2
      mu.label(ctx, "Target XYZ")
      mu.layout_row(ctx, {90, 90, 90}, 0)
      mu.slider(ctx, &app.manual.x, -reach, reach)
      mu.slider(ctx, &app.manual.y, 0, reach)
      mu.slider(ctx, &app.manual.z, -reach, reach)
      mu.layout_row(ctx, {-1}, 0)
    }
    mu.label(ctx, "IK weight"); mu.slider(ctx, &app.ik_weight, 0, 1)
    mu.label(ctx, "Pole weight"); mu.slider(ctx, &app.pole_weight, 0, 1)
    mu.label(ctx, "Iterations"); mu.slider(ctx, &app.iterations, 1, 20, 1)
    mu.label(ctx, "Max joint angle (deg)"); mu.slider(ctx, &app.limit_deg, 0, 180)
  }
}

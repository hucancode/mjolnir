// FABRIK with bend-cone constraints.
package main

import "core:fmt"
import "core:log"
import "core:math"
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
LEG_NAMES := [LEG_COUNT]string{"FR", "MR", "BR", "FL", "ML", "BL"}
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
POLE_HEIGHT :: 5

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
  time:           f32,
  feet:           [LEG_COUNT][3]f32,
  legs:           [LEG_COUNT]animation.LayerHandle,
  body_amplitude: mu.Real,
  body_speed:     mu.Real,
  leg_lift:       mu.Real,
  ik_weight:      mu.Real,
  paused:         bool,
  show_markers:   bool,
  manual_feet:    bool,
  foot_y:         [LEG_COUNT]mu.Real,
}

main :: proc() {
  context.logger = log.create_console_logger()
  app := new(App)
  app.body_amplitude = 2.5
  app.body_speed = 0.15
  app.leg_lift = 2.5
  app.ik_weight = 1
  app.show_markers = true
  w := &app.window
  if !platform.init(w, 800, 600, "IK") do return
  if !render.init(&app.renderer, "IK", w.window, platform.framebuffer_size(w), platform.dpi_scale(w)) do return
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

should_close :: proc(app: ^App) -> bool {
  return platform.should_close(&app.window)
}

setup :: proc(app: ^App) -> mjolnir.Setup {
  if !render.ready(&app.renderer) do return .WAIT
  if !debugui.init(&app.debug, &app.renderer) do return .FAIL
  render.camera_look_at(render.main_camera(&app.renderer), {0, 20, 20}, {0, 0, 0})
  app.orbit = render.orbit_from_camera(render.main_camera(&app.renderer))

  ground := world.spawn(&app.scene)
  render.attach(&app.renderer, render.SlotHandle(ground.index), render.primitive(&app.renderer, .CUBE, .GRAY))
  world.scale(&app.scene, ground, [3]f32{40, 0.2, 40})

  app.spider_model = gltf.model_create(&app.renderer, #load("../../assets/spider.glb"))
  app.spider = gltf.instance_create(&app.spider_model, &app.scene, &app.renderer)
  if len(app.spider.roots) == 0 || len(app.spider.skinned) == 0 do return .FAIL
  app.spider_root = app.spider.roots[0]
  app.spider_mesh = app.spider.skinned[0].node
  app.rig = &app.spider_model.rigs[app.spider.skinned[0].rig]
  skel := &app.rig.skeleton
  animation.animator_init(&app.animator, app.rig)
  for chain, i in LEG_CHAINS {
    tip, has_tip := animation.rest_position(skel, chain.tip)
    if !has_tip {
      log.warnf("Leg %d: tip %s missing", i, chain.tip)
      continue
    }
    app.feet[i] = {tip.x, 0, tip.z}
    bones, _ := animation.bone_chain(skel, chain.root, chain.tip, context.temp_allocator)
    for b, k in bones do animation.bone_limits(&app.animator)[b] = HIP_LIMIT if k == 0 else JOINT_LIMIT
    ik := animation.IKParams{target = app.feet[i], pole = leg_pole(app.feet[i], 0), pole_weight = 1, space = .WORLD}
    app.legs[i] = animation.layer_create(&app.animator, app.rig, ik, bones)
  }
  return .READY
}

leg_pole :: proc(foot: [3]f32, body_x: f32) -> [3]f32 {
  return {(foot.x + body_x) * 0.5, POLE_HEIGHT, foot.z * 0.5}
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
  if app.rig != nil do for s in app.spider.skinned do render.stage_bones(&app.renderer, render.SlotHandle(s.node.index), app.animator.palette)
  render.update(&app.renderer, dt)
}

walk :: proc(app: ^App, dt: f32) {
  if !app.paused do app.time += dt
  phase := app.time * f32(app.body_speed) * math.PI
  body_x := f32(app.body_amplitude) * math.sin(phase * 2)
  world.translate(&app.scene, app.spider_root, [3]f32{body_x, 0, 0})
  for foot, i in app.feet {
    target := foot
    target.y += f32(app.foot_y[i]) if app.manual_feet else f32(app.leg_lift) * max(math.sin(phase), 0)
    pole := leg_pole(foot, body_x)
    if ik, ok := animation.layer_params(&app.animator, app.legs[i], animation.IKParams); ok do ik.target, ik.pole = target, pole
    animation.layer_fade(&app.animator, app.legs[i], f32(app.ik_weight))
    if app.show_markers {
      render.debug_sphere(&app.renderer, target, 0.5, {1, 0.2, 0.2, 1})
      render.debug_sphere(&app.renderer, pole, 0.3, {0.3, 0.5, 1, 1})
    }
  }
  animation.animator_update(&app.animator, app.rig, dt, world.world_matrix(&app.scene, app.spider_mesh))
}

frame :: proc(app: ^App) -> bool {
  platform.poll_events(&app.window)
  ctx := debugui.begin(&app.debug)
  if mu.window(ctx, "IK", {480, 20, 300, 560}, {.NO_CLOSE}) {
    mu.layout_row(ctx, {-1}, 0)
    mu.checkbox(ctx, "Pause", &app.paused)
    mu.checkbox(ctx, "Show markers", &app.show_markers)
    mu.label(ctx, "Body amplitude")
    mu.slider(ctx, &app.body_amplitude, 0, 6)
    mu.label(ctx, "Body speed")
    mu.slider(ctx, &app.body_speed, 0, 1)
    mu.label(ctx, "IK weight")
    mu.slider(ctx, &app.ik_weight, 0, 1)
    mu.checkbox(ctx, "Manual feet Y", &app.manual_feet)
    if app.manual_feet {
      for name, i in LEG_NAMES {
        mu.label(ctx, fmt.tprintf("%s foot Y", name))
        mu.slider(ctx, &app.foot_y[i], 0, 6)
      }
    } else {
      mu.label(ctx, "Leg lift")
      mu.slider(ctx, &app.leg_lift, 0, 6)
    }
  }
  render.stage_overlay(&app.renderer, debugui.end(&app.debug))
  return render.frame(&app.renderer, platform.framebuffer_size(&app.window), platform.dpi_scale(&app.window))
}

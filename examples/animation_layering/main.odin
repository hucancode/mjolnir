// Bone-mask layer blending across multiple clips.
package main

import "../../mjolnir"
import anim "../../mjolnir/animation"
import "../../mjolnir/input"
import "../../mjolnir/platform"
import "../../mjolnir/render"
import "../../mjolnir/world"
import "core:fmt"
import "core:log"
import "core:math"
import mu "vendor:microui"

App :: struct {
  window:   platform.Platform,
  scene:    world.World,
  renderer: render.Renderer,
  input:    input.State,
  time:     f32,
  // orbit controller state, owned by the app
  yaw, pitch, dist: f32,
}

fox_scene: mjolnir.GltfScene
fox_handle: world.NodeHandle
rig: ^anim.Rig
animator: anim.Animator
target_cube: world.NodeHandle

walk_layer:   int = -1
run_layer:    int = -1
survey_layer: int = -1
ik_layer:     int = -1

walk_run_blend: mu.Real = 0.0
auto_blend:     bool    = true
blend_dir:      f32     = 1.0
survey_weight:  mu.Real = 0.0
ik_weight:      mu.Real = 0.0
animate_target: bool    = true
target_x:       mu.Real = 0.0
target_y:       mu.Real = 4.0
target_z:       mu.Real = 5.0
target_radius:  mu.Real = 4.0
target_speed:   mu.Real = 1.0
TRANSITION_DURATION :: f32(1.5)
on_run: bool = false

main :: proc() {
  context.logger = log.create_console_logger()
  defer mjolnir.gltf_scene_destroy(&fox_scene)
  app := new(App)
  defer free(app)
  w := &app.window
  if !platform.init(w, 800, 600, "Animation Layering") do return
  defer platform.shutdown(w)
  if !render.init(&app.renderer, "Animation Layering", w.window, platform.framebuffer_size(w), platform.dpi_scale(w)) do return
  defer render.shutdown(&app.renderer)
  if !world.init(&app.scene) do return
  defer world.shutdown(&app.scene)
  render.load_environment_map(&app.renderer, "assets/Cannon_Exterior.hdr")
  setup(app)
  mjolnir.run(mjolnir.Loop(App){app = app, should_close = should_close, update = update, frame = frame})
}

should_close :: proc(app: ^App) -> bool {
  return platform.should_close(&app.window)
}

setup :: proc(app: ^App) {
  render.main_camera_look_at(&app.renderer, {3, 2, 3}, {0, 1, 0})
  app.yaw, app.pitch, app.dist = render.camera_orbit_state(render.main_camera(&app.renderer))

  fox_scene = mjolnir.load_gltf(&app.scene, &app.renderer, "assets/Fox2.glb")
  if len(fox_scene.skinned) == 0 {
    log.error("Fox2.glb has no skinned mesh")
    return
  }
  fox_handle = fox_scene.skinned[0].node
  rig = &fox_scene.rigs[fox_scene.skinned[0].rig]
  anim.animator_init(&animator, rig)
  walk_layer,   _ = anim.add_clip_layer(&animator, rig, "Walk", weight = 1.0)
  run_layer,    _ = anim.add_clip_layer(&animator, rig, "Run",  weight = 0.0)
  survey_layer, _ = anim.add_clip_layer(&animator, rig, "Survey", weight = 0.0, speed = 0.5)
  if bones, ok := anim.find_bones(&rig.skeleton, {"b_Spine01_02", "b_Spine02_03", "b_Neck_04", "b_Head_05"}); ok {
    ik_layer, _ = anim.add_ik_layer(&animator, rig, bones, {f32(target_x), f32(target_y), f32(target_z)}, {0, 5, 2.5}, weight = 0.0, space = .WORLD)
  }
  log.infof("Layers: walk=%d run=%d survey=%d ik=%d", walk_layer, run_layer, survey_layer, ik_layer)

  target_cube = world.spawn(&app.scene, {f32(target_x), f32(target_y), f32(target_z)})
  render.attach(&app.renderer, target_cube.index, render.primitive(&app.renderer, .CUBE, .RED, cast_shadow = false))
  world.scale(&app.scene, target_cube, 0.25)
  light := world.spawn(&app.scene)
  render.attach(&app.renderer, light.index, render.directional_light_attachment({1, 1, 1, 1}, 10.0, true))
}

update :: proc(app: ^App, dt: f32) {
  app.time += dt
  platform.read_input(&app.window, &app.input)
  input.feed_microui(&app.input, render.debug_ctx(&app.renderer))
  if !app.input.mouse_captured {
    if input.mouse_down(&app.input, .LEFT) {
      app.yaw += app.input.mouse_delta.x * 0.02
      app.pitch = clamp(app.pitch + app.input.mouse_delta.y * 0.02, -1.5, 1.5)
    }
    app.dist = clamp(app.dist - app.input.scroll.y * 2, 1, 200)
  }
  render.main_camera_orbit(&app.renderer, app.yaw, app.pitch, app.dist)
  if rig != nil do animate(app, dt)
  world.update(&app.scene)
  render.stage_transforms(&app.renderer, world.changes(&app.scene))
  if rig != nil do render.stage_bones(&app.renderer, fox_handle.index, animator.palette)
  render.update(&app.renderer, dt)
}

frame :: proc(app: ^App) -> bool {
  platform.poll_events(&app.window)
  debug_ui(app)
  return render.frame(&app.renderer, platform.framebuffer_size(&app.window), platform.dpi_scale(&app.window))
}

animate :: proc(app: ^App, dt: f32) {

  if auto_blend {
    walk_run_blend += mu.Real(blend_dir * dt * 0.5)
    if walk_run_blend >= 1.0 { walk_run_blend = 1.0; blend_dir = -1.0 }
    if walk_run_blend <= 0.0 { walk_run_blend = 0.0; blend_dir =  1.0 }
  }

  if walk_layer >= 0 do anim.set_layer_weight(&animator, walk_layer, 1.0 - f32(walk_run_blend))
  if run_layer  >= 0 do anim.set_layer_weight(&animator, run_layer,  f32(walk_run_blend))
  if survey_layer >= 0 do anim.set_layer_weight(&animator, survey_layer, f32(survey_weight))

  if ik_layer >= 0 {
    anim.set_layer_weight(&animator, ik_layer, f32(ik_weight))
    if animate_target {
      t := app.time * f32(target_speed)
      r := f32(target_radius)
      target_x = mu.Real(math.cos(t) * r)
      target_z = mu.Real(math.sin(t) * r)
      target_y = mu.Real(4.0 + math.sin(t * 2.0))
    }
    pos := [3]f32{f32(target_x), f32(target_y), f32(target_z)}
    anim.set_ik_target(&animator, ik_layer, pos, {0, 5, 0})
    if world.valid(&app.scene, target_cube) do world.translate(&app.scene, target_cube, pos)
  }
  anim.animator_update(&animator, rig, dt, world.world_matrix(&app.scene, fox_handle))
}

debug_ui :: proc(app: ^App) {
  ctx := render.debug_ui(&app.renderer)
  if mu.window(ctx, "Animation Layering", {480, 20, 320, 490}, {.NO_CLOSE}) {
    mu.layout_row(ctx, {-1}, 0)
    mu.label(ctx, "Base layer (Walk <-> Run)")
    mu.checkbox(ctx, "Auto blend", &auto_blend)
    mu.label(ctx, fmt.tprintf("Blend: %.2f", walk_run_blend))
    mu.slider(ctx, &walk_run_blend, 0.0, 1.0)
    if .SUBMIT in mu.button(ctx, "Trigger transition") {
      if walk_layer >= 0 && run_layer >= 0 {
        on_run = !on_run
        name := on_run ? "Run" : "Walk"
        from := on_run ? walk_layer : run_layer
        to   := on_run ? run_layer  : walk_layer
        anim.transition_to(&animator, rig, name, duration = TRANSITION_DURATION, from = from, to = to)
        auto_blend = false
        walk_run_blend = on_run ? 1.0 : 0.0
      }
    }
    mu.label(ctx, "")
    mu.label(ctx, "Upper body (Survey)")
    mu.label(ctx, fmt.tprintf("Weight: %.2f", survey_weight)); mu.slider(ctx, &survey_weight, 0.0, 1.0)
    mu.label(ctx, "")
    mu.label(ctx, "IK head tracking")
    mu.label(ctx, fmt.tprintf("Weight: %.2f", ik_weight)); mu.slider(ctx, &ik_weight, 0.0, 1.0)
    mu.checkbox(ctx, "Animate target", &animate_target)
    if animate_target {
      mu.label(ctx, fmt.tprintf("Radius: %.2f", target_radius)); mu.slider(ctx, &target_radius, 1.0, 8.0)
      mu.label(ctx, fmt.tprintf("Speed: %.2f", target_speed));   mu.slider(ctx, &target_speed, 0.0, 4.0)
    } else {
      mu.label(ctx, fmt.tprintf("X: %.2f", target_x)); mu.slider(ctx, &target_x, -8.0, 8.0)
      mu.label(ctx, fmt.tprintf("Y: %.2f", target_y)); mu.slider(ctx, &target_y, 0.0, 8.0)
      mu.label(ctx, fmt.tprintf("Z: %.2f", target_z)); mu.slider(ctx, &target_z, -8.0, 8.0)
    }
  }
}

// Skinned glTF playback.
package main

import "../../mjolnir"
import anim "../../mjolnir/animation"
import "../../mjolnir/input"
import "../../mjolnir/platform"
import "../../mjolnir/render"
import "../../mjolnir/world"
import "core:log"
import "core:math"

App :: struct {
  window:    platform.Platform,
  scene:     world.World,
  renderer:  render.Renderer,
  input:     input.State,
  gltf:      mjolnir.GltfScene,
  // one animator per skinned node of the scene
  animators: [dynamic]anim.Animator,
  // orbit controller state, owned by the app
  yaw, pitch, dist: f32,
}

main :: proc() {
  context.logger = log.create_console_logger()
  app := new(App)
  defer free(app)
  w := &app.window
  if !platform.init(w, 800, 600, "GLTF Animation") do return
  defer platform.shutdown(w)
  if !render.init(&app.renderer, "GLTF Animation", w.window, platform.framebuffer_size(w), platform.dpi_scale(w)) do return
  defer render.shutdown(&app.renderer)
  if !world.init(&app.scene) do return
  defer world.shutdown(&app.scene)
  render.load_environment_map(&app.renderer, "assets/Cannon_Exterior.hdr")
  defer mjolnir.gltf_scene_destroy(&app.gltf)
  setup(app)
  mjolnir.run(mjolnir.Loop(App){app = app, should_close = should_close, update = update, frame = frame})
}

should_close :: proc(app: ^App) -> bool {
  return platform.should_close(&app.window)
}

setup :: proc(app: ^App) {
  render.main_camera_look_at(&app.renderer, {1.5, 1.5, 1.5}, {0, 1, 0})
  app.yaw, app.pitch, app.dist = render.camera_orbit_state(render.main_camera(&app.renderer))
  app.gltf = mjolnir.load_gltf(&app.scene, &app.renderer, "assets/CesiumMan.glb")
  for s in app.gltf.skinned {
    rig := &app.gltf.rigs[s.rig]
    a: anim.Animator
    anim.animator_init(&a, rig)
    anim.play(&a, rig, "Anim_0")
    append(&app.animators, a)
  }
  light := world.spawn(&app.scene)
  render.attach(&app.renderer, light.index, render.directional_light_attachment())
}

update :: proc(app: ^App, dt: f32) {
  platform.read_input(&app.window, &app.input)
  if !app.input.mouse_captured {
    if input.mouse_down(&app.input, .LEFT) {
      app.yaw += app.input.mouse_delta.x * 0.02
      app.pitch = clamp(app.pitch + app.input.mouse_delta.y * 0.02, -1.5, 1.5)
    }
    app.dist = clamp(app.dist - app.input.scroll.y * 2, 1, 200)
  }
  render.main_camera_orbit(&app.renderer, app.yaw, app.pitch, app.dist)
  rot := dt * math.PI * 0.05
  for h in app.gltf.roots do world.rotate_by(&app.scene, h, rot)
  for s, i in app.gltf.skinned do anim.animator_update(&app.animators[i], &app.gltf.rigs[s.rig], dt)
  world.update(&app.scene)
  render.stage_transforms(&app.renderer, world.changes(&app.scene))
  for s, i in app.gltf.skinned do render.stage_bones(&app.renderer, s.node.index, app.animators[i].palette)
  render.update(&app.renderer, dt)
}

frame :: proc(app: ^App) -> bool {
  platform.poll_events(&app.window)
  return render.frame(&app.renderer, platform.framebuffer_size(&app.window), platform.dpi_scale(&app.window))
}

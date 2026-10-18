// Procedural tail follow-through.
package main

import "core:log"
import "core:math"
import mu "vendor:microui"
import "../../mjolnir"
import anim "../../mjolnir/animation"
import "../../mjolnir/debugui"
import "../../mjolnir/gltf"
import "../../mjolnir/input"
import "../../mjolnir/platform"
import "../../mjolnir/render"
import "../../mjolnir/world"

GROUND_Y :: f32(-1)
HEAD_BONE :: "root"

App :: struct {
  window:          platform.Platform,
  scene:           world.World,
  renderer:        render.Renderer,
  debug:           debugui.Context,
  input:           input.State,
  orbit:           render.Orbit,
  snake:           gltf.Scene,
  snake_node:      world.NodeHandle,
  rig:             ^anim.Rig,
  animator:        anim.Animator,
  tail:            anim.LayerHandle,
  head_bone:       u32,
  time:            f32,
  stiffness:       mu.Real,
  damping:         mu.Real,
  stretch:         bool,
  auto_animate:    bool,
  drive_frequency: mu.Real,
  drive_amplitude: mu.Real,
  dragging:        bool,
  drag_height:     f32,
  head_offset:     [3]f32,
}

main :: proc() {
  context.logger = log.create_console_logger()
  app := new(App)
  app.stiffness = 0.3
  app.damping = 0.7
  app.auto_animate = true
  app.drive_frequency = 0.7
  app.drive_amplitude = 0.5
  w := &app.window
  if !platform.init(w, 900, 700, "Tail Modifier") do return
  if !render.init(&app.renderer, "Tail Modifier", w.window, platform.framebuffer_size(w), platform.dpi_scale(w)) do return
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
  anim.destroy(&app.animator)
  gltf.destroy(&app.snake, &app.scene, &app.renderer)
  world.shutdown(&app.scene)
  debugui.shutdown(&app.debug)
  render.shutdown(&app.renderer)
  platform.shutdown(&app.window)
  free(app)
}

should_close :: proc(app: ^App) -> bool {
  return platform.should_close(&app.window)
}

setup :: proc(app: ^App) -> bool {
  if !render.ready(&app.renderer) do return false
  if !debugui.init(&app.debug, &app.renderer) do return false
  render.environment_map_load(&app.renderer, #load("../../assets/Cannon_Exterior.hdr"))
  render.camera_look_at(render.main_camera(&app.renderer), {0, 4, -4}, {0, 1, 0})
  app.orbit = render.orbit_from_camera(render.main_camera(&app.renderer), {0, 1, 0})
  ground := world.spawn(&app.scene, {0, GROUND_Y, 0})
  render.attach(&app.renderer, render.SlotHandle(ground.index), render.primitive(&app.renderer, .QUAD_XZ, .GRAY, cast_shadow = false))
  world.scale(&app.scene, ground, 20.0)
  light := world.spawn(&app.scene, {-4, 10, 6})
  render.attach(&app.renderer, render.SlotHandle(light.index), render.light_create(&app.renderer, render.make_point_light({0.6, 0.7, 1.0}, 1000, 25.0, false)))

  app.snake = gltf.scene_create(&app.scene, &app.renderer, #load("../../assets/stuffed_snake_rigged.glb"))
  if len(app.snake.skinned) == 0 do return true
  app.snake_node = app.snake.skinned[0].node
  app.rig = &app.snake.rigs[app.snake.skinned[0].rig]
  skel := &app.rig.skeleton
  anim.animator_init(&app.animator, app.rig)
  whole_body, _ := anim.bone_chain_down(skel, HEAD_BONE, u32(anim.bone_count(skel)), context.temp_allocator)
  app.tail = anim.layer_create(&app.animator, app.rig, tail_params(app), whole_body)
  app.head_bone = anim.bone_find(skel, HEAD_BONE)
  return true
}

tail_params :: proc(app: ^App) -> anim.TailParams {
  return {stiffness = f32(app.stiffness), damping = f32(app.damping), stretch = app.stretch}
}

update :: proc(app: ^App, dt: f32) {
  platform.read_input(&app.window, &app.input)
  debugui.feed(&app.debug, &app.input)
  if !app.input.mouse_captured {
    drag := app.input.mouse_delta if input.mouse_down(&app.input, .LEFT) else 0
    render.orbit_drag(&app.orbit, drag, app.input.scroll.y)
  }
  render.camera_orbit(render.main_camera(&app.renderer), app.orbit)
  if app.rig != nil do animate(app, dt)
  world.update(&app.scene)
  render.stage_transforms(&app.renderer, world.changes(&app.scene))
  if app.rig != nil do render.stage_bones(&app.renderer, render.SlotHandle(app.snake_node.index), app.animator.palette)
  render.update(&app.renderer, dt)
}

animate :: proc(app: ^App, dt: f32) {
  if app.auto_animate {
    app.time += dt
    y := f32(app.drive_amplitude) * math.sin(app.time * f32(app.drive_frequency) * 2 * math.PI)
    world.translate(&app.scene, app.snake_node, 0, y, 0)
    app.dragging = false
  } else {
    drag_head(app)
  }
  if tail, ok := anim.layer_params(&app.animator, app.tail, anim.TailParams); ok do tail^ = tail_params(app)
  anim.animator_update(&app.animator, app.rig, dt, world.world_matrix(&app.scene, app.snake_node))
}

cursor_on_ground :: proc(app: ^App) -> (hit: [3]f32, ok: bool) {
  ray := render.cursor_ray(&app.renderer, app.input.cursor) or_return
  if abs(ray.direction.y) < 1e-6 do return
  t := (GROUND_Y - ray.origin.y) / ray.direction.y
  if t <= 0 do return
  return ray.origin + ray.direction * t, true
}

drag_head :: proc(app: ^App) {
  if input.mouse_pressed(&app.input, .RIGHT) && !app.input.mouse_captured {
    node_world := world.world_matrix(&app.scene, app.snake_node)
    head_world := node_world * anim.bone_matrix(&app.animator, app.head_bone)
    app.dragging = true
    app.drag_height = world.node(&app.scene, app.snake_node).transform.position.y
    app.head_offset = head_world[3].xyz - node_world[3].xyz
  }
  if !input.mouse_down(&app.input, .RIGHT) do app.dragging = false
  if !app.dragging do return
  hit, on_ground := cursor_on_ground(app)
  if !on_ground do return
  world.translate(&app.scene, app.snake_node, [3]f32{hit.x - app.head_offset.x, app.drag_height, hit.z - app.head_offset.z})
}

frame :: proc(app: ^App) -> bool {
  platform.poll_events(&app.window)
  ctx := debugui.begin(&app.debug)
  if mu.window(ctx, "Tail Modifier", {20, 300, 320, 320}, {.NO_CLOSE}) {
    mu.layout_row(ctx, {-1}, 0)
    mu.checkbox(ctx, "Auto animate", &app.auto_animate)
    if app.auto_animate {
      mu.label(ctx, "Frequency (Hz)"); mu.slider(ctx, &app.drive_frequency, 0, 4)
      mu.label(ctx, "Amplitude (units)"); mu.slider(ctx, &app.drive_amplitude, 0, 5)
    } else {
      mu.label(ctx, "Right-drag in the scene to move the head")
    }
    mu.label(ctx, "Stiffness"); mu.slider(ctx, &app.stiffness, 0, 1)
    mu.label(ctx, "Damping"); mu.slider(ctx, &app.damping, 0, 1)
    mu.checkbox(ctx, "Stretch", &app.stretch)
  }
  render.stage_overlay(&app.renderer, {commands = debugui.end(&app.debug, platform.dpi_scale(&app.window))})
  return render.frame(&app.renderer, platform.framebuffer_size(&app.window), platform.dpi_scale(&app.window))
}

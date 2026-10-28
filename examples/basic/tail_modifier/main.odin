// Procedural tail follow-through.
package main

import "core:log"
import "core:math"
import mu "vendor:microui"
import "mjolnir"
import "mjolnir/animation"
import "mjolnir/debugui"
import "mjolnir/geometry"
import "mjolnir/gltf"
import "mjolnir/input"
import "mjolnir/platform"
import "mjolnir/render"
import "mjolnir/world"

GROUND_Y :: f32(-1)
HEAD_BONE :: "root"

App :: struct {
  platform:        platform.Platform,
  scene:           world.World,
  renderer:        render.Renderer,
  debug:           debugui.Context,
  input:           input.State,
  orbit:           render.Orbit,
  snake_model:     gltf.Model,
  snake:           gltf.Instance,
  snake_node:      world.NodeHandle,
  rig:             gltf.RigHandle,
  tail:            animation.LayerHandle,
  head_bone:       u32,
  time:            f32,
  stiffness:       f32,
  damping:         f32,
  stretch:         bool,
  auto_animate:    bool,
  drive_frequency: f32,
  drive_amplitude: f32,
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
  if !platform.init(&app.platform, 1280, 720, "Tail Modifier") do return
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

shutdown :: proc(app: ^App) {
  gltf.destroy(&app.snake, &app.scene, &app.renderer)
  gltf.destroy(&app.snake_model, &app.renderer)
  world.shutdown(&app.scene)
  debugui.shutdown(&app.debug)
  render.shutdown(&app.renderer)
  platform.shutdown(&app.platform)
  free(app)
}

should_close :: proc(app: ^App) -> bool {
  return platform.should_close(&app.platform)
}

setup :: proc(app: ^App) -> mjolnir.Setup {
  if !render.ready(&app.renderer) do return .WAIT
  if !debugui.init(&app.debug, &app.renderer) do return .FAIL
  app.orbit = render.make_orbit({0, 4, -4}, {0, 1, 0})
  render.camera_orbit(render.main_camera(&app.renderer), app.orbit)
  mjolnir.spawn_mesh(&app.scene, &app.renderer, render.primitive(&app.renderer, .QUAD_XZ, .GRAY, cast_shadow = false), {0, GROUND_Y, 0}, scale = 20.0)
  app.snake_model = gltf.model_create(&app.renderer, #load("assets/stuffed_snake_rigged.glb"))
  app.snake = gltf.instance_create(&app.snake_model, &app.scene, &app.renderer)
  if len(app.snake.skinned) == 0 do return .FAIL
  app.snake_node = app.snake.skinned[0].node
  app.rig = app.snake.skinned[0].rig
  rig := &app.snake_model.rigs[app.rig]
  skel := &rig.skeleton
  whole_body, _ := animation.bone_chain_down(skel, HEAD_BONE, u32(animation.bone_count(skel)), context.temp_allocator)
  app.tail = animation.layer_create(&app.snake.animators[app.rig], rig, tail_params(app), whole_body)
  app.head_bone = animation.bone_find(skel, HEAD_BONE)
  return .READY
}

tail_params :: proc(app: ^App) -> animation.TailParams {
  return {stiffness = app.stiffness, damping = app.damping, stretch = app.stretch}
}

update :: proc(app: ^App, dt: f32) {
  render.lock(&app.renderer)
  defer render.unlock(&app.renderer)
  platform.read_input(&app.platform, &app.input)
  debugui.feed(&app.debug, &app.input, &app.renderer)
  debug_ui(app)
  render.stage_overlay(&app.renderer, debugui.end(&app.debug))
  render.orbit_drag(&app.orbit, render.main_camera(&app.renderer), &app.input)
  move_snake(app, dt)
  world.update(&app.scene)
  gltf.animate(&app.snake, &app.snake_model, &app.scene, &app.renderer, dt)
  render.stage_transforms(&app.renderer, world.changes(&app.scene))
  render.update(&app.renderer, dt)
}

move_snake :: proc(app: ^App, dt: f32) {
  if app.auto_animate {
    app.time += dt
    y := app.drive_amplitude * math.sin(app.time * app.drive_frequency * 2 * math.PI)
    world.translate(&app.scene, app.snake_node, 0, y, 0)
    app.dragging = false
  } else {
    drag_head(app)
  }
  if tail, ok := animation.layer_params(&app.snake.animators[app.rig], app.tail, animation.TailParams); ok do tail^ = tail_params(app)
}

cursor_on_ground :: proc(app: ^App) -> (hit: [3]f32, ok: bool) {
  ray := render.cursor_ray(&app.renderer, app.input.cursor) or_return
  return geometry.ray_plane_intersection(ray, {0, GROUND_Y, 0}, {0, 1, 0})
}

drag_head :: proc(app: ^App) {
  if input.mouse_pressed(&app.input, .RIGHT) && !app.input.mouse_captured {
    node_world := world.world_matrix(&app.scene, app.snake_node)
    head_world := node_world * animation.bone_matrix(&app.snake.animators[app.rig], app.head_bone)
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
  return mjolnir.frame(&app.platform, &app.renderer)
}

debug_ui :: proc(app: ^App) {
  ctx := debugui.begin(&app.debug)
  if debugui.window(&app.debug, "Tail Modifier", {20, 20, 320, 320}, {}) {
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
}

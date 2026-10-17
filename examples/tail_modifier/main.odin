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

scene: gltf.Scene
rig: ^anim.Rig
animator: anim.Animator
snake_child_node: world.NodeHandle
tail_layer: Maybe(anim.LayerHandle)

stiffness: mu.Real = 0.3
damping: mu.Real = 0.7
stretch_enabled: bool = false

animate_enabled: bool = true // auto sine drive vs. manual drag
drive_frequency: mu.Real = 0.7
drive_amplitude: mu.Real = 0.5
animation_time: f32 = 0

GROUND_Y :: f32(-1)
HEAD_BONE :: "root" // chain root bone; sits at the snake's head (eyes end)

// Drag state. Right-click/drag raycasts the cursor onto the ground plane and
// drives the head bone there in X/Z, so the head leads and the tail trails.
dragging: bool = false
head_bone: u32 // index of HEAD_BONE in the skeleton
head_found: bool
rest_y: f32 // node's resting local height, preserved while dragging
head_offset: [3]f32 // head world pos minus node origin, captured at drag start

App :: struct {
  window:   platform.Platform,
  scene:    world.World,
  renderer: render.Renderer,
  debug:    debugui.Context,
  input:    input.State,
  // orbit controller state, owned by the app
  yaw, pitch, dist: f32,
}

main :: proc() {
  context.logger = log.create_console_logger()
  app := new(App)
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
  world.shutdown(&app.scene)
  debugui.shutdown(&app.debug)
  render.shutdown(&app.renderer)
  platform.shutdown(&app.window)
  free(app)
  gltf.destroy(&scene)
}

should_close :: proc(app: ^App) -> bool {
  return platform.should_close(&app.window)
}

// On the web the renderer's device arrives after main returns: build the scene once it is up.
setup :: proc(app: ^App) -> bool {
  if !render.ready(&app.renderer) do return false
  if !debugui.init(&app.debug, &app.renderer) do return false
  render.environment_map_load(&app.renderer, #load("../../assets/Cannon_Exterior.hdr"))
  render.camera_look_at(render.main_camera(&app.renderer), {0, 4, -4}, {0, 1, 0})
  app.yaw, app.pitch, app.dist = render.camera_orbit_state(render.main_camera(&app.renderer))
  ground := world.spawn(&app.scene, {0, GROUND_Y, 0})
  render.attach(&app.renderer, render.SlotHandle(ground.index), render.primitive(&app.renderer, .QUAD_XZ, .GRAY, cast_shadow = false))
  world.scale(&app.scene, ground, 20.0)
  scene = gltf.scene_create(&app.scene, &app.renderer, #load("../../assets/stuffed_snake_rigged.glb"))
  if len(scene.skinned) == 0 do return true
  snake_child_node = scene.skinned[0].node
  rig = &scene.rigs[scene.skinned[0].rig]
  anim.animator_init(&animator, rig)
  // the whole body, head to tail tip
  chain, _ := anim.bone_chain_down(&rig.skeleton, HEAD_BONE, u32(anim.bone_count(&rig.skeleton)), context.temp_allocator)
  if idx, layer_ok := anim.layer_create(&animator, rig, anim.TailParams{stiffness = f32(stiffness), damping = f32(damping)}, chain); layer_ok {
    tail_layer = idx
    log.infof("Added tail modifier to node (layer %d)", idx)
  }
  head_bone, head_found = anim.find_bone(&rig.skeleton, HEAD_BONE)
  light := world.spawn(&app.scene, {-4, 10, 6})
  render.attach(&app.renderer, render.SlotHandle(light.index), render.light_create(&app.renderer, render.make_point_light({0.6, 0.7, 1.0, 1.5}, 15.0, false)))
  return true
}

update :: proc(app: ^App, dt: f32) {
  platform.read_input(&app.window, &app.input)
  debugui.feed(&app.debug, &app.input)
  if !app.input.mouse_captured {
    if input.mouse_down(&app.input, .LEFT) {
      app.yaw += app.input.mouse_delta.x * 0.02
      app.pitch = clamp(app.pitch + app.input.mouse_delta.y * 0.02, -1.5, 1.5)
    }
    app.dist = clamp(app.dist - app.input.scroll.y * 2, 1, 200)
  }
  render.camera_orbit(render.main_camera(&app.renderer), app.yaw, app.pitch, app.dist)
  if animate_enabled {
    animation_time += dt
    y := f32(drive_amplitude) * math.sin(animation_time * f32(drive_frequency) * 2 * math.PI)
    world.translate(&app.scene, snake_child_node, 0, y, 0)
    dragging = false
  } else {
    handle_drag(app)
  }
  if layer, ok := tail_layer.?; ok {
    if p, ok := anim.layer_params(&animator, layer, anim.TailParams); ok {
      p^ = {stiffness = f32(stiffness), damping = f32(damping), stretch = stretch_enabled}
    }
  }
  if rig != nil do anim.animator_update(&animator, rig, dt, world.world_matrix(&app.scene, snake_child_node))
  world.update(&app.scene)
  render.stage_transforms(&app.renderer, world.changes(&app.scene))
  if rig != nil do render.stage_bones(&app.renderer, render.SlotHandle(snake_child_node.index), animator.palette)
  render.update(&app.renderer, dt)
}

// Raycast the cursor onto the ground plane (y = GROUND_Y).
cursor_ground_hit :: proc(app: ^App) -> (hit: [3]f32, ok: bool) {
  ray, ray_ok := render.cursor_ray(&app.renderer, app.input.cursor)
  if !ray_ok do return {}, false
  origin, dir := ray.origin, ray.direction
  if abs(dir.y) < 1e-6 do return {}, false // ray parallel to ground
  t := (GROUND_Y - origin.y) / dir.y
  if t <= 0 do return {}, false // ground behind the camera
  return origin + dir * t, true
}

handle_drag :: proc(app: ^App) {
  if _, ok := world.node(&app.scene, snake_child_node); !ok do return

  // Begin drag on press (ignore when the UI owns the click). Capture the
  // head's offset from the node origin so we can land the head on the cursor.
  if input.mouse_pressed(&app.input, .RIGHT) && !app.input.mouse_captured {
    dragging = true
    rest_y = world.node(&app.scene, snake_child_node).transform.position.y
    head_offset = {0, 0, 0}
    if head_found {
      node_world := world.world_matrix(&app.scene, snake_child_node)
      head_world := node_world * anim.bone_matrix(&animator, head_bone)
      head_offset = head_world[3].xyz - node_world[3].xyz
    }
  }
  if !input.mouse_down(&app.input, .RIGHT) {
    dragging = false
    return
  }
  if !dragging do return

  hit, hit_ok := cursor_ground_hit(app)
  if !hit_ok do return
  // Move so the head bone lands on the cursor; keep the node's resting height.
  target := [3]f32{hit.x - head_offset.x, rest_y, hit.z - head_offset.z}
  world.translate(&app.scene, snake_child_node, target)
}

frame :: proc(app: ^App) -> bool {
  platform.poll_events(&app.window)
  ctx := debugui.begin(&app.debug)
  if mu.window(ctx, "Tail Modifier", {20, 300, 320, 320}, {.NO_CLOSE}) {
    mu.layout_row(ctx, {-1}, 0)
    mu.checkbox(ctx, "Auto animate", &animate_enabled)
    if animate_enabled {
      mu.label(ctx, "Frequency (Hz)"); mu.slider(ctx, &drive_frequency, 0.0, 4.0)
      mu.label(ctx, "Amplitude (units)"); mu.slider(ctx, &drive_amplitude, 0.0, 5.0)
    } else {
      mu.label(ctx, "Right-drag in the scene to move the head")
    }
    mu.label(ctx, "Stiffness"); mu.slider(ctx, &stiffness, 0.0, 1.0)
    mu.label(ctx, "Damping"); mu.slider(ctx, &damping, 0.0, 1.0)
    mu.checkbox(ctx, "Stretch", &stretch_enabled)
  }
  render.stage_overlay(&app.renderer, {commands = debugui.end(&app.debug, platform.dpi_scale(&app.window))})
  return render.frame(&app.renderer, platform.framebuffer_size(&app.window), platform.dpi_scale(&app.window))
}

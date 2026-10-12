package main

import "../../mjolnir"
import "../../mjolnir/input"
import anim "../../mjolnir/animation"
import "../../mjolnir/platform"
import "../../mjolnir/render"
import "../../mjolnir/world"
import "core:log"
import "core:math"
import mu "vendor:microui"

scene: mjolnir.GltfScene
rig: ^anim.Rig
animator: anim.Animator
snake_child_node: world.NodeHandle
tail_layer_index: int = -1

propagation_speed: mu.Real = 0.3
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
  renderer: render.Manager,
  camera:   mjolnir.CameraController,
  input:    input.State,
}

main :: proc() {
  context.logger = log.create_console_logger()
  defer mjolnir.gltf_scene_destroy(&scene)
  app := new(App)
  defer free(app)
  w := &app.window
  if !platform.init(w, 900, 700, "Tail Modifier") do return
  defer platform.shutdown(w)
  if !render.init(&app.renderer, "Tail Modifier", platform.vulkan_instance_extensions(), platform.vulkan_get_instance_proc_addr(), platform.create_surface, w, platform.framebuffer_size(w), platform.dpi_scale(w)) do return
  defer render.shutdown(&app.renderer)
  if !world.init(&app.scene) do return
  defer world.shutdown(&app.scene)
  render.load_environment_map(&app.renderer, "assets/Cannon_Exterior.hdr")
  app.camera = mjolnir.orbit_controller()
  setup(app)
  mjolnir.run(mjolnir.Loop(App){app = app, should_close = should_close, update = update, frame = frame})
}

should_close :: proc(app: ^App) -> bool {
  return platform.should_close(&app.window)
}

setup :: proc(app: ^App) {
  render.main_camera_look_at(&app.renderer, {0, 4, -4}, {0, 1, 0})
  ground := world.spawn(&app.scene, {0, GROUND_Y, 0})
  render.attach(&app.renderer, ground.index, render.primitive(&app.renderer, .QUAD_XZ, .GRAY, cast_shadow = false))
  world.scale(&app.scene, ground, 20.0)
  scene = mjolnir.load_gltf(&app.scene, &app.renderer, "assets/stuffed_snake_rigged.glb")
  if len(scene.skinned) == 0 do return
  snake_child_node = scene.skinned[0].node
  rig = &scene.rigs[scene.skinned[0].rig]
  anim.animator_init(&animator, rig)
  if idx, layer_ok := anim.add_tail_layer(&animator, rig, "root", 10,
    propagation_speed = f32(propagation_speed),
    damping = f32(damping),
    weight = 1.0,
  ); layer_ok {
    tail_layer_index = idx
    log.infof("Added tail modifier to node (layer %d)", tail_layer_index)
  }
  head_bone, head_found = anim.find_bone(&rig.skeleton, HEAD_BONE)
  light := world.spawn(&app.scene, {-4, 10, 6})
  render.attach(&app.renderer, light.index, render.point_light_attachment({0.6, 0.7, 1.0, 1.5}, 15.0, false))
}

update :: proc(app: ^App, dt: f32) {
  platform.read_input(&app.window, &app.input)
  render.debug_ui_input(&app.renderer, &app.input)
  mjolnir.camera_controller_update(&app.camera, &app.renderer, &app.input, dt)
  if animate_enabled {
    animation_time += dt
    y := f32(drive_amplitude) * math.sin(animation_time * f32(drive_frequency) * 2 * math.PI)
    world.translate(&app.scene, snake_child_node, 0, y, 0)
    dragging = false
  } else {
    handle_drag(app)
  }
  if tail_layer_index >= 0 {
    anim.set_tail_params(&animator, tail_layer_index,
      propagation_speed = f32(propagation_speed),
      damping = f32(damping),
      stretch = stretch_enabled,
    )
  }
  if rig != nil do anim.animator_update(&animator, rig, dt, world.world_matrix(&app.scene, snake_child_node))
  world.update(&app.scene)
  for i in world.removed_nodes(&app.scene) do render.stage_slot_removal(&app.renderer, i)
  render.stage_transforms(&app.renderer, world.changed_nodes(&app.scene))
  if rig != nil do render.stage_bones(&app.renderer, snake_child_node.index, animator.palette)
  render.update(&app.renderer, dt)
}

// Raycast the cursor onto the ground plane (y = GROUND_Y).
cursor_ground_hit :: proc(app: ^App) -> (hit: [3]f32, ok: bool) {
  origin, dir, ray_ok := render.cursor_ray(&app.renderer, app.input.cursor)
  if !ray_ok do return {}, false
  if abs(dir.y) < 1e-6 do return {}, false // ray parallel to ground
  t := (GROUND_Y - origin.y) / dir.y
  if t <= 0 do return {}, false // ground behind the camera
  return origin + dir * t, true
}

handle_drag :: proc(app: ^App) {
  if !world.valid(&app.scene, snake_child_node) do return

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
  ctx := render.debug_ui(&app.renderer)
  if mu.window(ctx, "Tail Modifier", {20, 300, 320, 320}, {.NO_CLOSE}) {
    mu.layout_row(ctx, {-1}, 0)
    mu.checkbox(ctx, "Auto animate", &animate_enabled)
    if animate_enabled {
      mu.label(ctx, "Frequency (Hz)"); mu.slider(ctx, &drive_frequency, 0.0, 4.0)
      mu.label(ctx, "Amplitude (units)"); mu.slider(ctx, &drive_amplitude, 0.0, 5.0)
    } else {
      mu.label(ctx, "Right-drag in the scene to move the head")
    }
    mu.label(ctx, "Propagation speed"); mu.slider(ctx, &propagation_speed, 0.0, 1.0)
    mu.label(ctx, "Damping"); mu.slider(ctx, &damping, 0.0, 1.0)
    mu.checkbox(ctx, "Stretch", &stretch_enabled)
  }
  return render.frame(&app.renderer, platform.framebuffer_size(&app.window), platform.dpi_scale(&app.window))
}

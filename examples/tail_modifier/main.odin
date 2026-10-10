package main

import "../../mjolnir"
import "../../mjolnir/input"
import anim "../../mjolnir/animation"
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

main :: proc() {
  defer mjolnir.gltf_scene_destroy(&scene)
  mjolnir.run_app({
    title      = "Tail Modifier",
    width      = 900,
    height     = 700,
    debug_ui   = true,
    setup      = setup,
    update     = update,
    pre_render = debug_ui,
  })
}

setup :: proc(engine: ^mjolnir.Engine) {
  render.main_camera_look_at(&engine.render, {0, 4, -4}, {0, 1, 0})
  mjolnir.spawn_ground(engine, 20.0, position = {0, GROUND_Y, 0})
  scene = mjolnir.load_gltf(engine, "assets/stuffed_snake_rigged.glb")
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
  mjolnir.spawn(engine, {-4, 10, 6}, render.point_light_attachment({0.6, 0.7, 1.0, 1.5}, 15.0, false))
}

update :: proc(engine: ^mjolnir.Engine, dt: f32) {
  if animate_enabled {
    animation_time += dt
    y := f32(drive_amplitude) * math.sin(animation_time * f32(drive_frequency) * 2 * math.PI)
    world.translate(&engine.world, snake_child_node, 0, y, 0)
    dragging = false
  } else {
    handle_drag(engine)
  }
  if tail_layer_index >= 0 {
    anim.set_tail_params(&animator, tail_layer_index,
      propagation_speed = f32(propagation_speed),
      damping = f32(damping),
      stretch = stretch_enabled,
    )
  }
  if rig != nil do anim.animator_update(&animator, rig, dt, world.world_matrix(&engine.world, snake_child_node))
  world.update(&engine.world)
  for i in world.removed_nodes(&engine.world) do render.stage_slot_removal(&engine.render, i)
  for n in world.changed_nodes(&engine.world) do render.stage_transform(&engine.render, n.index, n.world_matrix, n.visible)
  if rig != nil do render.stage_bones(&engine.render, snake_child_node.index, animator.palette)
}

// Raycast the cursor onto the ground plane (y = GROUND_Y).
cursor_ground_hit :: proc(engine: ^mjolnir.Engine) -> (hit: [3]f32, ok: bool) {
  origin, dir, ray_ok := mjolnir.cursor_world_ray(engine)
  if !ray_ok do return {}, false
  if abs(dir.y) < 1e-6 do return {}, false // ray parallel to ground
  t := (GROUND_Y - origin.y) / dir.y
  if t <= 0 do return {}, false // ground behind the camera
  return origin + dir * t, true
}

handle_drag :: proc(engine: ^mjolnir.Engine) {
  if !world.valid(&engine.world, snake_child_node) do return

  // Begin drag on press (ignore when the UI owns the click). Capture the
  // head's offset from the node origin so we can land the head on the cursor.
  if input.mouse_pressed(&engine.input, .RIGHT) && !engine.mouse_captured {
    dragging = true
    rest_y = world.position(&engine.world, snake_child_node).y
    head_offset = {0, 0, 0}
    if head_found {
      node_world := world.world_matrix(&engine.world, snake_child_node)
      head_world := node_world * anim.bone_matrix(&animator, head_bone)
      head_offset = head_world[3].xyz - node_world[3].xyz
    }
  }
  if !input.mouse_down(&engine.input, .RIGHT) {
    dragging = false
    return
  }
  if !dragging do return

  hit, hit_ok := cursor_ground_hit(engine)
  if !hit_ok do return
  // Move so the head bone lands on the cursor; keep the node's resting height.
  target := [3]f32{hit.x - head_offset.x, rest_y, hit.z - head_offset.z}
  world.translate(&engine.world, snake_child_node, target)
}

debug_ui :: proc(engine: ^mjolnir.Engine) {
  ctx := render.debug_ui(&engine.render)
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
}

package main

import "../../mjolnir"
import "../../mjolnir/world"
import "core:log"
import "core:math"
import "vendor:glfw"
import mu "vendor:microui"

root_nodes: [dynamic]world.NodeHandle
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
  world.main_camera_look_at(&engine.world, {0, 4, -4}, {0, 1, 0})
  world.spawn_ground(&engine.world, 20.0, position = {0, GROUND_Y, 0})
  root_nodes = mjolnir.load_gltf(engine, "assets/stuffed_snake_rigged.glb")
  if len(root_nodes) == 0 do return
  child, has := world.mesh_child(&engine.world, root_nodes[0])
  if !has do return
  snake_child_node = child
  if idx, layer_ok := world.add_tail_modifier_layer(&engine.world, child, "root", 10,
    propagation_speed = f32(propagation_speed),
    damping = f32(damping),
    weight = 1.0,
  ); layer_ok {
    tail_layer_index = idx
    log.infof("Added tail modifier to node (layer %d)", tail_layer_index)
  }
  if att, has_att := world.mesh_attachment(&engine.world, child); has_att {
    if m, has_m := world.mesh(&engine.world, att.handle); has_m {
      head_bone, head_found = world.find_bone_by_name(m, HEAD_BONE)
    }
  }
  world.spawn_light_point(&engine.world, {-4, 10, 6}, {0.6, 0.7, 1.0, 1.5}, 15.0, false)
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
    world.set_tail_modifier_params(&engine.world, snake_child_node, tail_layer_index,
      propagation_speed = f32(propagation_speed),
      damping = f32(damping),
      stretch = stretch_enabled,
    )
  }
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
  node, ok := world.node(&engine.world, snake_child_node)
  if !ok do return

  // Begin drag on press (ignore when the UI owns the click). Capture the
  // head's offset from the node origin so we can land the head on the cursor.
  if mjolnir.is_mouse_pressed(engine, glfw.MOUSE_BUTTON_RIGHT) &&
     !mjolnir.debug_ui_wants_mouse(engine) {
    dragging = true
    rest_y = node.transform.position.y
    head_offset = {0, 0, 0}
    if head_found {
      if bt, bt_ok := world.get_bone_world_transform(&engine.world, snake_child_node, head_bone); bt_ok {
        head_offset = bt.position - node.transform.world_matrix[3].xyz
      }
    }
  }
  if !mjolnir.is_mouse_down(engine, glfw.MOUSE_BUTTON_RIGHT) {
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
  ctx := mjolnir.ui_ctx(engine)
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

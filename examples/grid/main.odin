package main

import "../../mjolnir"
import "../../mjolnir/world"
import "core:fmt"
import "core:log"
import "core:math"
import "core:math/linalg"
import mu "vendor:microui"

GRID_SIZES :: [3]int{5, 256, 300}

current_size_index: int = -1
pending_index: int = -1
despawn_cooldown: int
grid_root: world.NodeHandle

main :: proc() {
  mjolnir.run_app({title = "Grid", debug_ui = true, setup = setup, update = update, pre_render = debug_ui})
}

setup :: proc(engine: ^mjolnir.Engine) {
  light := world.spawn_light_directional(&engine.world, {10, 18, 10}, {1, 0.97, 0.92, 3.0}, 60.0, false)
  world.rotate(&engine.world, light, math.PI * 0.5, linalg.VECTOR3F32_X_AXIS)
  world.main_camera_look_at(&engine.world, {14, 14, 14}, {0, 0, 0})
  pending_index = 0
}

// Split despawn/respawn across FRAMES_IN_FLIGHT frames to let Remove ops drain.
request_rebuild :: proc(idx: int) {
  if idx == current_size_index do return
  pending_index = idx
}

update :: proc(engine: ^mjolnir.Engine, dt: f32) {
  if despawn_cooldown > 0 {
    despawn_cooldown -= 1
    if despawn_cooldown == 0 do spawn_grid(engine, pending_index)
    return
  }
  if pending_index >= 0 && pending_index != current_size_index {
    if grid_root.index != 0 do world.despawn(&engine.world, grid_root)
    grid_root = {}
    despawn_cooldown = 2
  }
}

spawn_grid :: proc(engine: ^mjolnir.Engine, idx: int) {
  current_size_index = idx
  pending_index = -1
  sizes := GRID_SIZES
  n := sizes[idx]
  color := world.Color.GREEN if n > 5 else world.Color.YELLOW
  half := f32(n) * 0.5
  log.infof("spawning %dx%d cubes", n, n)
  grid_root = world.spawn(&engine.world, {0, 0, 0})
  for z in 0 ..< n do for x in 0 ..< n {
    world.spawn_primitive_mesh_child(&engine.world, grid_root, .CUBE, color, position = {(f32(x) - half) * 4, 0, (f32(z) - half) * 4})
  }
}

debug_ui :: proc(engine: ^mjolnir.Engine) {
  ctx := mjolnir.ui_ctx(engine)
  if mu.window(ctx, "Grid", {540, 20, 240, 200}, {.NO_CLOSE}) {
    sizes := GRID_SIZES
    label_text: string = "<loading>"
    if current_size_index >= 0 do label_text = fmt.tprintf("%dx%d", sizes[current_size_index], sizes[current_size_index])
    mu.label(ctx, fmt.tprintf("Size: %s", label_text))
    mu.label(ctx, "")
    mu.layout_row(ctx, {-1}, 0)
    for n, i in sizes {
      if .SUBMIT in mu.button(ctx, fmt.tprintf("%dx%d", n, n)) do request_rebuild(i)
    }
  }
}

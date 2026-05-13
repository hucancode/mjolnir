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
  context.logger = log.create_console_logger()
  engine := new(mjolnir.Engine)
  engine.setup_proc = setup
  engine.update_proc = update
  engine.pre_render_proc = debug_ui
  mjolnir.run(engine, 800, 600, "Grid")
}

setup :: proc(engine: ^mjolnir.Engine) {
  engine.debug_ui_enabled = true
  light, _ := world.spawn_light_directional(&engine.world, {10, 18, 10}, {1, 0.97, 0.92, 3.0}, 60.0, false)
  world.rotate(&engine.world, light, math.PI * 0.5, linalg.VECTOR3F32_X_AXIS)
  world.main_camera_look_at(&engine.world, {14, 14, 14}, {0, 0, 0})
  pending_index = 0
}

// Button click only requests a swap. Engine's staging applies Remove and
// Update ops in undefined map-iteration order. If a freed pool slot is reused
// by a new spawn in the same frame, the Remove for the old handle can wipe
// the GPU slot the new node just wrote into. Splitting despawn and respawn
// across FRAMES_IN_FLIGHT frames lets the Remove ops drain first.
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
  mat := world.get_builtin_material(&engine.world, .GREEN if n > 5 else .YELLOW)
  mesh := world.get_builtin_mesh(&engine.world, .CUBE)
  half := f32(n) * 0.5
  log.infof("spawning %dx%d cubes", n, n)
  grid_root = world.spawn(&engine.world, {0, 0, 0}) or_else {}
  for z in 0 ..< n {
    for x in 0 ..< n {
      world.spawn_child(
        &engine.world,
        grid_root,
        {(f32(x) - half) * 4, 0, (f32(z) - half) * 4},
        world.MeshAttachment{handle = mesh, material = mat},
      )
    }
  }
}

debug_ui :: proc(engine: ^mjolnir.Engine) {
  ctx := mjolnir.ui_ctx(engine)
  if mu.window(ctx, "Grid", {540, 20, 240, 200}, {.NO_CLOSE}) {
    sizes := GRID_SIZES
    label_text: string = "<loading>"
    if current_size_index >= 0 {
      label_text = fmt.tprintf("%dx%d", sizes[current_size_index], sizes[current_size_index])
    }
    mu.label(ctx, fmt.tprintf("Size: %s", label_text))
    mu.label(ctx, "")
    mu.layout_row(ctx, {-1}, 0)
    for n, i in sizes {
      btn := fmt.tprintf("%dx%d", n, n)
      if .SUBMIT in mu.button(ctx, btn) do request_rebuild(i)
    }
  }
}

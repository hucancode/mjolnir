package main

import "../../mjolnir"
import "core:fmt"
import "core:math"
import "core:math/linalg"
import mu "vendor:microui"

helmet_nodes: [dynamic]mjolnir.NodeHandle
dir_light: mjolnir.NodeHandle

dir_intensity: mu.Real = 4.0
rotate_speed: mu.Real = 0.5
spinning: bool = true
rotation_phase: f32

main :: proc() {
  mjolnir.run_app({
    title      = "PBR Showcase (full texture set)",
    width      = 1000,
    height     = 700,
    debug_ui   = true,
    setup      = setup,
    update     = update,
    pre_render = debug_ui,
  })
}

setup :: proc(engine: ^mjolnir.Engine) {
  mjolnir.main_camera_look_at(engine, {0, 0.2, 3.5}, {0, 0, 0})
  helmet_nodes = mjolnir.load_gltf(engine, "assets/DamagedHelmet.glb")
  dir_light = mjolnir.spawn_light_directional(engine, {4, 6, 4}, {1, 0.98, 0.95, f32(dir_intensity)}, 15.0, false)
}

update :: proc(engine: ^mjolnir.Engine, delta_time: f32) {
  mjolnir.set_light_intensity(engine, dir_light, f32(dir_intensity))
  if spinning {
    rotation_phase += delta_time * f32(rotate_speed)
  }
  for h in helmet_nodes {
    mjolnir.rotate(engine, h, rotation_phase, linalg.VECTOR3F32_Y_AXIS)
    mjolnir.rotate_by(engine, h, math.PI * 0.5, linalg.VECTOR3F32_X_AXIS)
  }
}

debug_ui :: proc(engine: ^mjolnir.Engine) {
  ctx := mjolnir.ui_ctx(engine)
  if mu.window(ctx, "PBR Lighting", {700, 20, 280, 320}, {.NO_CLOSE}) {
    mu.label(ctx, fmt.tprintf("Sun intensity: %.2f", dir_intensity))
    mu.slider(ctx, &dir_intensity, 0.0, 20.0)
    mu.checkbox(ctx, "Spinning", &spinning)
  }
}

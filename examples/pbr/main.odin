package main

import "../../mjolnir"
import "../../mjolnir/world"
import "core:fmt"
import "core:log"
import "core:math"
import "core:math/linalg"
import mu "vendor:microui"

helmet_nodes: [dynamic]world.NodeHandle
dir_light: world.NodeHandle

dir_intensity: mu.Real = 4.0
rotate_speed: mu.Real = 0.5
spinning: bool = true
rotation_phase: f32

main :: proc() {
  context.logger = log.create_console_logger()
  engine := new(mjolnir.Engine)
  engine.setup_proc = setup
  engine.update_proc = update
  engine.pre_render_proc = debug_ui
  mjolnir.run(engine, 1000, 700, "PBR Showcase (full texture set)")
}

setup :: proc(engine: ^mjolnir.Engine) {
  engine.debug_ui_enabled = true
  world.main_camera_look_at(&engine.world, {0, 0.2, 3.5}, {0, 0, 0})
  helmet_nodes = mjolnir.load_gltf(engine, "assets/DamagedHelmet.glb")
  dir_light =
    world.spawn(
      &engine.world,
      {4, 6, 4},
      world.create_directional_light_attachment(
        {1, 0.98, 0.95, f32(dir_intensity)},
        15.0,
        false,
      ),
    ) or_else {}
}

update :: proc(engine: ^mjolnir.Engine, delta_time: f32) {
  // Direct light intensity slider
  if dn, ok := world.node(&engine.world, dir_light); ok {
    if att, ok := &dn.attachment.(world.DirectionalLightAttachment); ok {
      att.color.a = f32(dir_intensity)
    }
    dn.transform.is_dirty = true
    world.stage_light_data(&engine.world.staging, dir_light)
  }

  if spinning {
    rotation_phase += delta_time * f32(rotate_speed)
  }
  for h in helmet_nodes {
    world.rotate(&engine.world, h, rotation_phase, linalg.VECTOR3F32_Y_AXIS)
    world.rotate_by(&engine.world, h, math.PI * 0.5, linalg.VECTOR3F32_X_AXIS)
  }
}

debug_ui :: proc(engine: ^mjolnir.Engine) {
  ctx := &engine.render.debug_ui.ctx
  if mu.window(ctx, "PBR Lighting", {700, 20, 280, 320}, {.NO_CLOSE}) {
    mu.label(ctx, fmt.tprintf("Sun intensity: %.2f", dir_intensity))
    mu.slider(ctx, &dir_intensity, 0.0, 20.0)
    mu.checkbox(ctx, "Spinning", &spinning)
  }
}

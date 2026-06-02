package main

import "../../mjolnir"
import "../../mjolnir/render/ambient"
import "../../mjolnir/world"
import "core:math"
import "core:math/linalg"
import mu "vendor:microui"

Model :: struct {
  label:  string,
  path:   string,
  scale:  f32,
  offset: [3]f32,
  rot_x:  f32,
}

MODELS := [?]Model{
  {"Mjolnir",        "assets/Mjolnir.glb",        0.3,   {0, -1, 0},    math.PI * -0.3},
  {"Suzanne",        "assets/Suzanne.glb",        1.0,   {0, 0, 0},     0},
  {"Duck",           "assets/Duck.glb",           0.4,   {0, -1, 0},    0},
  {"Damaged Helmet", "assets/DamagedHelmet.glb",  1.0,   {0, 0, 0},     math.PI * 0.5},
  {"SciFi Helmet",   "assets/SciFiHelmet.glb",    1.0,   {0, -1, 0},    0},
}

model_nodes: [dynamic]world.NodeHandle
current_model: int = -1
dir_light: world.NodeHandle

dir_intensity: mu.Real = 1.0
rotate_speed: mu.Real = 0.5
spinning: bool = true
rotation_phase: f32
ibl_intensity: mu.Real = 1.0
skybox_on: bool = true
skybox_blur: mu.Real = 0.25

main :: proc() {
  mjolnir.run_app({
    title      = "PBR",
    debug_ui   = true,
    setup      = setup,
    update     = update,
    pre_render = debug_ui,
  })
}

setup :: proc(engine: ^mjolnir.Engine) {
  world.main_camera_look_at(&engine.world, {0, 0.2, 3.5}, {0, 0, 0})
  dir_light = world.spawn_light_directional(&engine.world, {4, 6, 4}, {1, 0.98, 0.95, f32(dir_intensity)}, 15.0, false)
  swap_model(engine, 0)
}

swap_model :: proc(engine: ^mjolnir.Engine, index: int) {
  if index == current_model do return
  for h in model_nodes do world.despawn(&engine.world, h)
  clear(&model_nodes)
  current_model = index
  m := MODELS[index]
  model_nodes = mjolnir.load_gltf(engine, m.path)
  rotation_phase = 0
}

update :: proc(engine: ^mjolnir.Engine, delta_time: f32) {
  world.set_light_intensity(&engine.world, dir_light, f32(dir_intensity))
  ambient.set_ibl_intensity(&engine.render.ambient, f32(ibl_intensity))
  ambient.set_skybox_enabled(&engine.render.ambient, skybox_on)
  ambient.set_skybox_blur(&engine.render.ambient, f32(skybox_blur))
  if spinning {
    rotation_phase += delta_time * f32(rotate_speed)
  }
  m := MODELS[current_model]
  for h in model_nodes {
    world.translate(&engine.world, h, m.offset)
    world.rotate(&engine.world, h, rotation_phase, linalg.VECTOR3F32_Y_AXIS)
    if m.rot_x != 0 do world.rotate_by(&engine.world, h, m.rot_x, linalg.VECTOR3F32_X_AXIS)
    world.scale(&engine.world, h, m.scale)
  }
}

debug_ui :: proc(engine: ^mjolnir.Engine) {
  ctx := mjolnir.ui_ctx(engine)
  if mu.window(ctx, "PBR Lighting", {550, 20, 220, 400}, {.NO_CLOSE}) {
    mu.label(ctx, "Sun intensity")
    mu.slider(ctx, &dir_intensity, 0.0, 5.0)
    mu.label(ctx, "IBL intensity")
    mu.slider(ctx, &ibl_intensity, 0.0, 2.0)
    mu.checkbox(ctx, "Skybox", &skybox_on)
    mu.label(ctx, "Skybox blur")
    mu.slider(ctx, &skybox_blur, 0.0, 1.0)
    mu.checkbox(ctx, "Spinning", &spinning)
    mu.label(ctx, "Model:")
    mu.layout_row(ctx, {-1}, 0)
    for m, i in MODELS {
      if .SUBMIT in mu.button(ctx, m.label) do swap_model(engine, i)
    }
  }
}

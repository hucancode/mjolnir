package main

import "../../mjolnir"
import "../../mjolnir/render"
import "../../mjolnir/gpu"
import "../../mjolnir/world"
import "core:strings"
import "core:fmt"
import mu "vendor:microui"

TextureEntry :: struct {
  name:   string,
  handle: gpu.Texture2DHandle,
}

TEXTURE_FILES := [?]string{
  "circle_01", "circle_02", "circle_03", "circle_04", "circle_05",
  "light_01", "light_02", "light_03",
  "scorch_01", "scorch_02", "scorch_03",
  "smoke_01", "smoke_02", "smoke_03",
  "star_01", "star_02", "star_03",
  "symbol_01", "symbol_02",
}

textures:            [dynamic]TextureEntry
selected_tex_index:  i32 = 0
emitter_node:        world.NodeHandle
emitter_handle:      world.EmitterHandle
enabled:             bool = true

emission_rate:    mu.Real = 200
lifetime:         mu.Real = 2.0
size_start:       mu.Real = 350
size_end:         mu.Real = 80
weight:           mu.Real = 0.2
weight_spread:    mu.Real = 0.1
position_spread:  mu.Real = 0.3
velocity_x:       mu.Real = 0
velocity_y:       mu.Real = 3.0
velocity_z:       mu.Real = 0
velocity_spread:  mu.Real = 1.5
aabb_extent:f32 =      8.0

color_start: [4]f32 = {1.0, 0.9, 0.4, 1.0}
color_end:   [4]f32 = {1.0, 0.2, 0.0, 0.0}

main :: proc() {
  mjolnir.run_app({
    title      = "Particles",
    width      = 1280,
    height     = 800,
    debug_ui   = true,
    setup      = setup,
    update     = update,
    pre_render = debug_ui,
  })
}

setup :: proc(engine: ^mjolnir.Engine) {
  world.main_camera_look_at(&engine.world, {0, 5, 10}, {0, 2, 0})
  render.set_skybox_enabled(&engine.render, false)

  for name in TEXTURE_FILES {
    path := fmt.tprintf("assets/particles/%s.png", name)
    handle, ok := mjolnir.create_texture(engine, path)
    if !ok do continue
    append(&textures, TextureEntry{name = strings.clone(name), handle = handle})
  }
  if len(textures) > 0 && int(selected_tex_index) >= len(textures) do selected_tex_index = 0

  emitter_node, emitter_handle, _ = world.spawn_emitter(&engine.world, position = {0, 2, 0})
}

update :: proc(engine: ^mjolnir.Engine, delta_time: f32) {
  tex: gpu.Texture2DHandle
  if len(textures) > 0 && int(selected_tex_index) < len(textures) {
    tex = textures[selected_tex_index].handle
  }
  world.set_emitter(&engine.world, emitter_handle,
    texture           = tex,
    enabled           = enabled,
    emission_rate     = f32(emission_rate),
    particle_lifetime = f32(lifetime),
    size_start        = f32(size_start),
    size_end          = f32(size_end),
    weight            = f32(weight),
    weight_spread     = f32(weight_spread),
    position_spread   = f32(position_spread),
    initial_velocity  = [3]f32{f32(velocity_x), f32(velocity_y), f32(velocity_z)},
    velocity_spread   = f32(velocity_spread),
    color_start       = color_start,
    color_end         = color_end,
    aabb_min          = [3]f32{-aabb_extent, -aabb_extent, -aabb_extent},
    aabb_max          = [3]f32{ aabb_extent,  aabb_extent,  aabb_extent},
  )
}

debug_ui :: proc(engine: ^mjolnir.Engine) {
  ctx := mjolnir.ui_ctx(engine)

  if mu.window(ctx, "Texture", {20, 20, 220, 760}, {.NO_CLOSE}) {
    mu.layout_row(ctx, {-1}, 0)
    mu.checkbox(ctx, "Enabled", &enabled)
    current_name := "(none)"
    if len(textures) > 0 && int(selected_tex_index) < len(textures) {
      current_name = textures[selected_tex_index].name
    }
    mu.layout_row(ctx, {-1}, 0)
    for tex, idx in textures {
      prefix := "  "
      if i32(idx) == selected_tex_index do prefix = "> "
      if .SUBMIT in mu.button(ctx, fmt.tprintf("%s%s", prefix, tex.name)) {
        selected_tex_index = i32(idx)
      }
    }
  }

  if mu.window(ctx, "Emission & Lifetime", {900, 20, 320, 600}, {.NO_CLOSE}) {
    mu.layout_row(ctx, {-1}, 0)
    mu.label(ctx, "Emission rate")
    mu.slider(ctx, &emission_rate, 1, 300)
    mu.label(ctx, "Lifetime")
    mu.slider(ctx, &lifetime, 0.1, 10)
    mu.layout_row(ctx, {-1}, 0)
    mu.label(ctx, "Size start")
    mu.slider(ctx, &size_start, 1, 1000)
    mu.label(ctx, "Size end")
    mu.slider(ctx, &size_end, 1, 1000)
    mu.label(ctx, "Weight")
    mu.slider(ctx, &weight, -2, 5)
    mu.label(ctx, "Weight spread")
    mu.slider(ctx, &weight_spread, 0, 2)
    mu.layout_row(ctx, {-1}, 0)
    mu.label(ctx, "Velocity X")
    mu.slider(ctx, &velocity_x, -8, 8)
    mu.label(ctx, "Velocity Y")
    mu.slider(ctx, &velocity_y, -8, 12)
    mu.label(ctx, "Velocity Z")
    mu.slider(ctx, &velocity_z, -8, 8)
    mu.label(ctx, "Velocity spread")
    mu.slider(ctx, &velocity_spread, 0, 8)
    mu.label(ctx, "Position spread")
    mu.slider(ctx, &position_spread, 0, 4)
  }

}

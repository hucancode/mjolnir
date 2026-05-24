package main

import "../../mjolnir"
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
emitter_node:        mjolnir.NodeHandle
emitter_handle:      mjolnir.EmitterHandle
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
  mjolnir.main_camera_look_at(engine, {0, 5, 10}, {0, 2, 0})
  mjolnir.set_skybox_enabled(engine, false)

  for name in TEXTURE_FILES {
    path := fmt.tprintf("assets/particles/%s.png", name)
    handle, ok := mjolnir.create_texture(engine, path)
    if !ok do continue
    append(&textures, TextureEntry{name = strings.clone(name), handle = handle})
  }

  initial_tex: gpu.Texture2DHandle
  if len(textures) > 0 {
    if int(selected_tex_index) >= len(textures) do selected_tex_index = 0
    initial_tex = textures[selected_tex_index].handle
  }

  emitter_node, _ = mjolnir.spawn(engine, {0, 2, 0})
  emitter_handle, _ = world.create_emitter(
    &engine.world,
    node_handle       = emitter_node,
    texture_handle    = initial_tex,
    emission_rate     = f32(emission_rate),
    initial_velocity  = {f32(velocity_x), f32(velocity_y), f32(velocity_z)},
    velocity_spread   = f32(velocity_spread),
    color_start       = color_start,
    color_end         = color_end,
    aabb_min          = {-aabb_extent, -aabb_extent, -aabb_extent},
    aabb_max          = { aabb_extent,  aabb_extent,  aabb_extent},
    particle_lifetime = f32(lifetime),
    position_spread   = f32(position_spread),
    size_start        = f32(size_start),
    size_end          = f32(size_end),
    weight            = f32(weight),
    weight_spread     = f32(weight_spread),
  )
  mjolnir.spawn_child(engine, emitter_node, attachment = world.EmitterAttachment{handle = emitter_handle})

  // mjolnir.spawn_light_point(engine, position = {3, 5, 3}, color = {1, 0.9, 0.6, 1}, radius = 12, cast_shadow = false)
}

update :: proc(engine: ^mjolnir.Engine, delta_time: f32) {
  em, ok := world.emitter(&engine.world, emitter_handle)
  if !ok do return

  tex: gpu.Texture2DHandle
  if len(textures) > 0 && int(selected_tex_index) < len(textures) {
    tex = textures[selected_tex_index].handle
  }

  em.texture_handle    = tex
  em.enabled           = b32(enabled)
  em.emission_rate     = f32(emission_rate)
  em.particle_lifetime = f32(lifetime)
  em.size_start        = f32(size_start)
  em.size_end          = f32(size_end)
  em.weight            = f32(weight)
  em.weight_spread     = f32(weight_spread)
  em.position_spread   = f32(position_spread)
  em.initial_velocity  = {f32(velocity_x), f32(velocity_y), f32(velocity_z)}
  em.velocity_spread   = f32(velocity_spread)
  em.color_start       = color_start
  em.color_end         = color_end
  em.aabb_min          = {-aabb_extent, -aabb_extent, -aabb_extent}
  em.aabb_max          = { aabb_extent,  aabb_extent,  aabb_extent}

  world.stage_emitter_data(&engine.world.staging, emitter_handle)
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

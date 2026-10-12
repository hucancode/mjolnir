package main

import "../../mjolnir"
import "../../mjolnir/input"
import "../../mjolnir/platform"
import "../../mjolnir/render"
import "../../mjolnir/world"
import "core:strings"
import "core:fmt"
import "core:log"
import mu "vendor:microui"

App :: struct {
  window:   platform.Platform,
  scene:    world.World,
  renderer: render.Manager,
  input:    input.State,
}

TextureEntry :: struct {
  name:   string,
  handle: render.TextureHandle,
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
emitter_handle:      render.EmitterHandle
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

color_start: [4]f32 = {1.0, 0.9, 0.4, 1.0}
color_end:   [4]f32 = {1.0, 0.2, 0.0, 0.0}

main :: proc() {
  context.logger = log.create_console_logger()
  app := new(App)
  defer free(app)
  w := &app.window
  if !platform.init(w, 1280, 800, "Particles") do return
  defer platform.shutdown(w)
  if !render.init(&app.renderer, "Particles", platform.vulkan_instance_extensions(), platform.vulkan_get_instance_proc_addr(), platform.create_surface, w, platform.framebuffer_size(w), platform.dpi_scale(w)) do return
  defer render.shutdown(&app.renderer)
  if !world.init(&app.scene) do return
  defer world.shutdown(&app.scene)
  render.load_environment_map(&app.renderer, "assets/Cannon_Exterior.hdr")

  render.main_camera_look_at(&app.renderer, {0, 5, 10}, {0, 2, 0})
  app.renderer.ambient.skybox_intensity = 0

  for name in TEXTURE_FILES {
    path := fmt.tprintf("assets/particles/%s.png", name)
    handle, ret := render.create_texture_from_path(&app.renderer, path)
    if ret != .SUCCESS do continue
    append(&textures, TextureEntry{name = strings.clone(name), handle = handle})
  }
  if len(textures) > 0 && int(selected_tex_index) >= len(textures) do selected_tex_index = 0

  emitter_handle = render.create_emitter(&app.renderer)
  emitter_node = world.spawn(&app.scene, {0, 2, 0})
  render.attach(&app.renderer, emitter_node.index, render.EmitterAttachment{emitter_handle})

  mjolnir.run(mjolnir.Loop(App){app = app, should_close = should_close, update = update, frame = frame})
}

should_close :: proc(app: ^App) -> bool {
  return platform.should_close(&app.window)
}

update :: proc(app: ^App, dt: f32) {
  platform.read_input(&app.window, &app.input)
  render.debug_ui_input(&app.renderer, &app.input)
  if cam, ok := render.main_camera(&app.renderer); ok && !app.input.mouse_captured {
    yaw, pitch, dist := render.camera_orbit_state(cam)
    if input.mouse_down(&app.input, .LEFT) {
      yaw += app.input.mouse_delta.x * 0.02
      pitch = clamp(pitch + app.input.mouse_delta.y * 0.02, -1.5, 1.5)
    }
    render.camera_orbit(cam, yaw, pitch, clamp(dist - app.input.scroll.y * 2, 1, 200))
  }
  tex: render.TextureHandle
  if len(textures) > 0 && int(selected_tex_index) < len(textures) {
    tex = textures[selected_tex_index].handle
  }
  if em, ok := render.emitter(&app.renderer, emitter_handle); ok {
    em.texture_index     = render.texture_index(tex)
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
    render.set_emitter(&app.renderer, emitter_handle, em^)
  }
  world.update(&app.scene)
  for i in world.removed_nodes(&app.scene) do render.stage_slot_removal(&app.renderer, i)
  render.stage_transforms(&app.renderer, world.changed_nodes(&app.scene))
  render.update(&app.renderer, dt)
}

frame :: proc(app: ^App) -> bool {
  platform.poll_events(&app.window)
  debug_ui(app)
  return render.frame(&app.renderer, platform.framebuffer_size(&app.window), platform.dpi_scale(&app.window))
}

debug_ui :: proc(app: ^App) {
  ctx := render.debug_ui(&app.renderer)

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

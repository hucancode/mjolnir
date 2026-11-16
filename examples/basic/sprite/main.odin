// Sprite sheets with frame animation.
package main

import "core:fmt"
import "core:log"
import mu "vendor:microui"
import "mjolnir"
import "mjolnir/debugui"
import "mjolnir/input"
import "mjolnir/platform"
import "mjolnir/render"
import "mjolnir/world"

SHEET_COLUMNS :: 6
SHEET_ROWS :: 17
CELL_ASPECT :: f32(69.0 / 44.0)
SPRITE_HEIGHT :: 5
FPS :: 8.0

State :: enum {
  FALLEN,
  HANG,
  HANG_SLIDE,
  IDLE,
  RUN,
  CLIMB,
}

Action :: enum {
  FATAL,
  HURT,
  JUMP,
  ATTACK,
  RUN_ATTACK,
  STOP,
  DASH,
  LONG_JUMP,
}

STATE_CLIPS := [State]render.SpriteClip {
  .IDLE           = {first = 0, count = 6, fps = FPS},
  .RUN            = {first = 6, count = 8, fps = FPS},
  .FALLEN         = {first = 36, count = 1, fps = FPS},
  .HANG           = {first = 54, count = 6, fps = FPS},
  .HANG_SLIDE     = {first = 60, count = 3, fps = FPS},
  .CLIMB          = {first = 91, count = 8, fps = FPS},
}

ACTION_CLIPS := [Action]render.SpriteClip {
  .ATTACK     = {first = 14, count = 12, fps = FPS, once = true},
  .FATAL      = {first = 28, count = 10, fps = FPS, once = true},
  .HURT       = {first = 37, count = 4, fps = FPS, once = true},
  .JUMP       = {first = 42, count = 8, fps = FPS, once = true},
  .RUN_ATTACK = {first = 76, count = 8, fps = FPS, once = true},
  .STOP       = {first = 73, count = 3, fps = FPS, once = true},
  .DASH       = {first = 84, count = 7, fps = FPS, once = true},
  .LONG_JUMP  = {first = 63, count = 10, fps = FPS, once = true},
}

App :: struct {
  platform: platform.Platform,
  scene:    world.World,
  renderer: render.Renderer,
  input:    input.State,
  orbit:    render.Orbit,
  debug:    debugui.Context,
  sprite:   world.NodeHandle,
  state:    State,
  action:   Action,
  acting:   bool,
  elapsed:  f32,
}

main :: proc() {
  context.logger = log.create_console_logger()
  app := new(App)
  if !platform.init(&app.platform, 1280, 720, "Sprite") do return
  if !render.init(&app.renderer, app.platform.window) do return
  if !world.init(&app.scene) do return
  mjolnir.run(
    mjolnir.Loop(App) {
      app = app,
      setup = setup,
      shutdown = shutdown,
      update = update,
      render = draw,
    },
  )
}

shutdown :: proc(app: ^App) {
  world.shutdown(&app.scene)
  debugui.shutdown(&app.debug)
  render.shutdown(&app.renderer)
  platform.shutdown(&app.platform)
  free(app)
}

setup :: proc(app: ^App) -> mjolnir.Setup {
  if !render.ready(&app.renderer) do return .WAIT
  app.orbit = render.make_orbit({0, 1.5, 6}, {0, 1.5, 0})

  tex, tex_ok := render.texture_create(&app.renderer, #load("assets/Warrior_Sheet-Effect.png"))
  if !tex_ok {
    log.error("failed to load warrior sheet")
    return .FAIL
  }

  if !debugui.init(&app.debug, &app.renderer) do return .FAIL
  app.state = .IDLE
  frames := render.sprite_frames_create(&app.renderer, render.sprite_frames_grid(SHEET_COLUMNS, SHEET_ROWS))
  if frames == 0 do return .FAIL
  material := render.material_create(&app.renderer, render.make_material(.SPRITE, albedo_texture = tex, sprite_frames = frames))
  if material == 0 do return .FAIL
  app.sprite = mjolnir.spawn(&app.scene, &app.renderer, render.primitive(&app.renderer, .QUAD_XY, material, no_shadow = true), {0, 1.5, 0}, scale = {SPRITE_HEIGHT * CELL_ASPECT, SPRITE_HEIGHT, 1})

  return .READY
}

update :: proc(app: ^App, dt: f32) {
  render.lock(&app.renderer)
  platform.read_input(&app.platform, &app.input)
  debug_ui(app)
  mjolnir.orbit_drag(&app.orbit, render.main_camera(&app.renderer), &app.input, rotate_with = {})
  app.elapsed += dt
  frame, done := render.sprite_clip_frame(ACTION_CLIPS[app.action] if app.acting else STATE_CLIPS[app.state], app.elapsed)
  if app.acting && done {
    app.acting = false
    app.elapsed = 0
    frame, _ = render.sprite_clip_frame(STATE_CLIPS[app.state], 0)
  }
  render.sprite_frame(&app.renderer, app.sprite, frame)
  mjolnir.update(&app.scene, &app.renderer, dt)
}

debug_ui :: proc(app: ^App) {
  ctx := debugui.begin(&app.debug, &app.input, &app.renderer)
  defer debugui.end(&app.debug, &app.renderer)
  if debugui.window(&app.debug, "Animation", {20, 20, 200, 450}) {
    mu.layout_row(ctx, {-1}, 0)
    mu.label(ctx, "State")
    for state in State {
      if .SUBMIT in mu.button(ctx, fmt.tprint(state)) {
        app.state = state
        if !app.acting do app.elapsed = 0
      }
    }
    mu.label(ctx, "Action")
    for action in Action {
      if .SUBMIT in mu.button(ctx, fmt.tprint(action)) {
        app.action = action
        app.acting = true
        app.elapsed = 0
      }
    }
  }
}

draw :: proc(app: ^App) -> bool {
  return mjolnir.frame(&app.platform, &app.renderer)
}

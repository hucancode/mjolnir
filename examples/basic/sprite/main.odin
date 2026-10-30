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
SPRITE_HEIGHT :: 2.5
FPS :: 8.0

Clip :: struct {
  first: u32,
  count: u32,
}

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

STATE_CLIPS := [State]Clip {
  .IDLE           = {0, 6},
  .RUN            = {6, 8},
  .FALLEN         = {36, 1},
  .HANG           = {54, 6},
  .HANG_SLIDE     = {60, 3},
  .CLIMB          = {91, 8},
}

ACTION_CLIPS := [Action]Clip {
  .ATTACK     = {14, 12},
  .FATAL      = {28, 10},
  .HURT       = {37, 4},
  .JUMP       = {42, 8},
  .RUN_ATTACK = {76, 8},
  .STOP       = {73, 3},
  .DASH       = {84, 7},
  .LONG_JUMP  = {63, 10},
}

App :: struct {
  platform: platform.Platform,
  scene:    world.World,
  renderer: render.Renderer,
  input:    input.State,
  orbit:    render.Orbit,
  debug:    debugui.Context,
  sprite:   render.MaterialHandle,
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
  sprite_ok: bool
  app.sprite, sprite_ok = render.material_create(&app.renderer, render.make_material(.SPRITE, albedo_texture = tex, frame_columns = SHEET_COLUMNS, frame_rows = SHEET_ROWS))
  if !sprite_ok do return .FAIL
  node, node_ok := world.spawn(&app.scene, {0, 1.5, 0})
  if !node_ok do return .FAIL
  render.attach(&app.renderer, node, render.primitive(&app.renderer, .QUAD_XY, app.sprite, no_shadow = true))
  world.transform(&app.scene, node).scale = {SPRITE_HEIGHT * CELL_ASPECT, SPRITE_HEIGHT, 1}

  return .READY
}

update :: proc(app: ^App, dt: f32) {
  render.lock(&app.renderer)
  platform.read_input(&app.platform, &app.input)
  debug_ui(app)
  mjolnir.orbit_drag(&app.orbit, render.main_camera(&app.renderer), &app.input, rotate_with = {})
  app.elapsed += dt
  clip := ACTION_CLIPS[app.action] if app.acting else STATE_CLIPS[app.state]
  step := u32(app.elapsed * FPS)
  if app.acting && step >= clip.count {
    app.acting = false
    app.elapsed = 0
    clip = STATE_CLIPS[app.state]
    step = 0
  }
  render.material(&app.renderer, app.sprite).frame_index = clip.first + step % clip.count
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

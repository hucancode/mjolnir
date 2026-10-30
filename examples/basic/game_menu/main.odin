// Game menu: title, play and pause screens as a state machine. Enter starts or resumes, Escape pauses, T goes back to the title, Q quits from a menu.
package main

import "core:log"
import "core:math/linalg"
import "mjolnir"
import "mjolnir/font"
import "mjolnir/fsm"
import "mjolnir/input"
import "mjolnir/platform"
import "mjolnir/render"
import "mjolnir/world"

Screen :: enum {
  TITLE,
  PLAY,
  PAUSE,
}

SCREENS := [Screen]fsm.State(App, Screen) {
  .TITLE = {update = title},
  .PLAY  = {update = play},
  .PAUSE = {update = pause},
}

App :: struct {
  platform: platform.Platform,
  scene:    world.World,
  renderer: render.Renderer,
  input:    input.State,
  font:     font.Font,
  screen:   fsm.Machine(Screen),
  spinner:  world.NodeHandle,
  quitting: bool,
}

main :: proc() {
  context.logger = log.create_console_logger()
  app := new(App)
  if !platform.init(&app.platform, 1280, 720, "Game menu") do return
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

setup :: proc(app: ^App) -> mjolnir.Setup {
  if !render.ready(&app.renderer) do return .WAIT
  sun := render.light_create(&app.renderer, render.make_directional_light())
  mjolnir.spawn(&app.scene, &app.renderer, sun, rotation = linalg.quaternion_from_forward_and_up([3]f32{-0.4, -1, -0.3}, [3]f32{0, 1, 0}))
  if !font.init(&app.font, #load("assets/Outfit-Regular.ttf")) do return .FAIL
  r := &app.renderer
  mjolnir.spawn(&app.scene, r, render.primitive(r, .QUAD_XZ, .GRAY, no_shadow = true), scale = 20)
  app.spinner = mjolnir.spawn(&app.scene, r, render.primitive(r, .CUBE, .MAGENTA), {0, 1, 0})
  render.camera_look_at(render.main_camera(r), {0, 3, 6}, {0, 1, 0})
  fsm.start(&app.screen, SCREENS, app, .TITLE)
  return .READY
}

shutdown :: proc(app: ^App) {
  font.destroy(&app.font)
  world.shutdown(&app.scene)
  render.shutdown(&app.renderer)
  platform.shutdown(&app.platform)
  free(app)
}

menu :: proc(app: ^App, heading: string, lines: ..string) {
  size := render.window_size(&app.renderer)
  commands := make([dynamic]render.OverlayCommand, context.temp_allocator)
  width := font.measure(&app.font, heading, 64)
  for line in lines do width = max(width, font.measure(&app.font, line, 26))
  left := (size.x - width) / 2
  append(&commands, render.OverlayCommand{shape = render.OverlayQuad{size = size, color = {0, 0, 0, 160}}})
  append(&commands, render.OverlayCommand{shape = render.OverlayText{text = heading, position = {left, size.y / 3}, size = 64, color = 255}, z_order = 1})
  for line, i in lines {
    append(&commands, render.OverlayCommand{shape = render.OverlayText{text = line, position = {left, size.y / 3 + 100 + f32(i) * 36}, size = 26, color = {220, 220, 220, 255}}, z_order = 1})
  }
  render.stage_overlay(&app.renderer, commands[:], &app.font)
}

title :: proc(app: ^App, dt: f32) -> Screen {
  menu(app, "MJOLNIR", "Enter: play", "Q: quit")
  if input.key_pressed(&app.input, .Q) do app.quitting = true
  return .PLAY if input.key_pressed(&app.input, .ENTER) else .TITLE
}

play :: proc(app: ^App, dt: f32) -> Screen {
  world.transform(&app.scene, app.spinner).rotation *= linalg.quaternion_angle_axis(dt, linalg.VECTOR3F32_Y_AXIS)
  hud := [?]render.OverlayCommand{{shape = render.OverlayText{text = "Escape: pause", position = {20, 20}, size = 22, color = 255}}}
  render.stage_overlay(&app.renderer, hud[:], &app.font)
  return .PAUSE if input.key_pressed(&app.input, .ESCAPE) else .PLAY
}

pause :: proc(app: ^App, dt: f32) -> Screen {
  menu(app, "Paused", "Enter: resume", "T: title", "Q: quit")
  if input.key_pressed(&app.input, .Q) do app.quitting = true
  if input.key_pressed(&app.input, .T) do return .TITLE
  return .PLAY if input.key_pressed(&app.input, .ENTER) else .PAUSE
}

update :: proc(app: ^App, dt: f32) {
  render.lock(&app.renderer)
  platform.read_input(&app.platform, &app.input)
  fsm.update(&app.screen, SCREENS, app, dt)
  mjolnir.update(&app.scene, &app.renderer, dt)
}

draw :: proc(app: ^App) -> bool {
  return !app.quitting && mjolnir.frame(&app.platform, &app.renderer)
}

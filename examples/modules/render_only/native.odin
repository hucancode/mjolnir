#+build !js
package main

import "core:log"
import "vendor:glfw"
import "mjolnir/font"
import "mjolnir/render"

FRAMES :: #config(FRAMES, 0)

main :: proc() {
  context.logger = log.create_console_logger()
  if !glfw.Init() do return
  defer glfw.Terminate()
  glfw.WindowHint(glfw.CLIENT_API, glfw.NO_API)
  window := glfw.CreateWindow(1280, 720, "Render only", nil, nil)
  r = new(render.Renderer)
  defer free(r)
  if !render.init(r, window) do return
  defer render.shutdown(r)
  for !render.ready(r) do glfw.PollEvents()
  if !setup() do return
  defer font.destroy(&f)
  for frame := 0; !glfw.WindowShouldClose(window) && (FRAMES == 0 || frame < FRAMES); frame += 1 {
    glfw.PollEvents()
    draw(frame)
  }
}

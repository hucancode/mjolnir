#+build !js
#+private file
package render

import "../font"
import "../geometry"
import "core:math/linalg"
import "core:testing"
import "vendor:glfw"

// render on its own, with a raw GLFW window and no scene graph: type-checked by `odin test`, run
// by hand (it opens a window), so the standalone path keeps compiling.
standalone :: proc(ttf: []u8) {
  if !glfw.Init() do return
  defer glfw.Terminate()
  glfw.WindowHint(glfw.CLIENT_API, glfw.NO_API)
  window := glfw.CreateWindow(1280, 720, "render only", nil, nil)
  r := new(Renderer)
  defer free(r)
  if !init(r, window) do return
  defer shutdown(r)
  for !ready(r) {}
  CUBE, BALL, LAMP :: SlotHandle(0), SlotHandle(1), SlotHandle(2)
  attach(r, CUBE, primitive(r, .CUBE, .RED))
  ball := mesh_create(r, geometry.make_sphere())
  attach(r, BALL, MeshAttachment{ball, material_create(r, make_material(base_color_factor = {0.2, 0.6, 1, 1})), true, 0})
  attach(r, LAMP, light_create(r, make_point_light()))
  place(r, LAMP, linalg.matrix4_translate([3]f32{0, 3, 0}))
  place(r, BALL, linalg.matrix4_translate([3]f32{2, 0, 0}))
  f: font.Font
  font.init(&f, ttf)
  defer font.destroy(&f)
  for frame_count := 0; !glfw.WindowShouldClose(window) && frame_count < 120; frame_count += 1 {
    glfw.PollEvents()
    place(r, CUBE, linalg.matrix4_rotate(f32(frame_count) * 0.02, [3]f32{0, 1, 0}))
    debug_axes(r, {})
    stage_overlay(r, {{shape = DrawTextCommand{"render only", {10, 10}, 20, {255, 255, 255, 255}}}}, &f)
    update(r, 1.0 / 60)
    frame(r)
  }
  release(r, BALL)
}

@(test)
test_standalone_compiles :: proc(t: ^testing.T) {
  _ = standalone
}

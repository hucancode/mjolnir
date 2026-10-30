// Render on its own: slots placed by hand, no scene graph and no platform layer. The command line opens a raw GLFW window (run with -define:FRAME_DUMP=dir to keep the frames); the web page draws into the bare canvas.
package main

import "core:math"
import "core:math/linalg"
import "mjolnir/font"
import "mjolnir/geometry"
import "mjolnir/render"

RING :: 12
FLOOR, TORUS, LAMP, SPOT :: render.SlotHandle(0), render.SlotHandle(1), render.SlotHandle(2), render.SlotHandle(3)
SUN :: render.SlotHandle(4 + RING)

r: ^render.Renderer
f: font.Font
orbit: render.Orbit

setup :: proc() -> bool {
  font.init(&f, #load("../../../assets/Outfit-Regular.ttf")) or_return
  render.attach(r, FLOOR, render.primitive(r, .QUAD_XZ, .GRAY, no_shadow = true))
  render.place(r, FLOOR, linalg.matrix4_scale([3]f32{12, 1, 12}))
  gold := render.material_create(r, render.make_material(base_color_factor = {1, 0.8, 0.3, 1}, metallic_factor = 1, roughness_factor = 0.3))
  render.attach(r, TORUS, render.MeshAttachment{mesh = render.mesh_create(r, geometry.make_torus()), material = gold})
  render.attach(r, LAMP, render.light_create(r, render.make_point_light({1, 0.6, 0.3}, 40, 8)))
  render.place(r, LAMP, linalg.matrix4_translate([3]f32{0, 2.5, 0}))
  render.attach(r, SPOT, render.light_create(r, render.make_spot_light({0.4, 0.6, 1}, 200, 15)))
  render.place(r, SPOT, linalg.matrix4_translate([3]f32{0, 6, 0}) * linalg.matrix4_rotate(-math.PI / 2, [3]f32{1, 0, 0}))
  cube := render.primitive(r, .CUBE, .WHITE)
  for i in 0 ..< RING do render.attach(r, render.SlotHandle(4 + i), cube)
  render.attach(r, SUN, render.light_create(r, render.make_directional_light(intensity = 0.5)))
  render.place(r, SUN, linalg.matrix4_from_quaternion(linalg.quaternion_from_forward_and_up([3]f32{-0.4, -1, -0.3}, [3]f32{0, 1, 0})))
  orbit = render.make_orbit({7, 4, 7}, {0, 0.5, 0})
  return true
}

draw :: proc(frame: int) {
  t := f32(frame) / 60
  render.place(r, TORUS, linalg.matrix4_translate([3]f32{0, 1, 0}) * linalg.matrix4_rotate(t, [3]f32{1, 1, 0}))
  for i in 0 ..< RING {
    a := t * 0.5 + f32(i) * 2 * math.PI / RING
    m := linalg.matrix4_translate([3]f32{4 * math.cos(a), 0.3 + 0.2 * math.sin(3 * a), 4 * math.sin(a)}) * linalg.matrix4_scale(f32(0.3))
    render.place(r, render.SlotHandle(4 + i), m, visible = i % 4 != frame / 60 % 4)
  }
  orbit.yaw = 0.8 + t * 0.2
  render.camera_orbit(render.main_camera(r), orbit)
  render.debug_axes(r, {0, 0.01, 0})
  render.debug_circle(r, {0, 0.02, 0}, {0, 1, 0}, 4)
  render.stage_overlay(r, {{shape = render.OverlayText{"render only: slots placed by hand", {16, 16}, 24, {255, 255, 255, 255}}}}, &f)
  render.update(r, 1.0 / 60)
  render.frame(r)
}

// Mesh generated at runtime.
package main

import "../../mjolnir"
import "../../mjolnir/input"
import "../../mjolnir/platform"
import "../../mjolnir/render"
import "../../mjolnir/world"
import "core:log"
import "core:math"
import "core:math/linalg"
import mu "vendor:microui"

wave_node: world.NodeHandle
knot_node: world.NodeHandle
spiral_node: world.NodeHandle

wave_visible: bool = true
knot_visible: bool = true
spiral_visible: bool = true

rotate_speed: mu.Real = 0.4
spin: f32

App :: struct {
  window:   platform.Platform,
  scene:    world.World,
  renderer: render.Renderer,
  input:    input.State,
  // orbit controller state, owned by the app
  yaw, pitch, dist: f32,
}

main :: proc() {
  context.logger = log.create_console_logger()
  app := new(App)
  w := &app.window
  if !platform.init(w, 1000, 700, "Procedural Mesh") do return
  if !render.init(&app.renderer, "Procedural Mesh", w.window, platform.framebuffer_size(w), platform.dpi_scale(w)) do return
  if !world.init(&app.scene) do return
  mjolnir.run(
    mjolnir.Loop(App) {
      app = app,
      setup = setup,
      shutdown = shutdown,
      should_close = should_close,
      update = update,
      frame = frame,
    },
  )
}

shutdown :: proc(app: ^App) {
  world.shutdown(&app.scene)
  render.shutdown(&app.renderer)
  platform.shutdown(&app.window)
  free(app)
}

should_close :: proc(app: ^App) -> bool {
  return platform.should_close(&app.window)
}

frame :: proc(app: ^App) -> bool {
  platform.poll_events(&app.window)
  return render.frame(&app.renderer, platform.framebuffer_size(&app.window), platform.dpi_scale(&app.window))
}

spawn_mesh :: proc(app: ^App, mesh_handle: render.MeshHandle, material: render.MaterialHandle, pos: [3]f32) -> world.NodeHandle {
  n := world.spawn(&app.scene, pos)
  render.attach(&app.renderer, render.SlotHandle(n.index), render.MeshAttachment{mesh = mesh_handle, material = material, cast_shadow = true})
  return n
}

// On the web the renderer's device arrives after main returns: build the scene once it is up.
setup :: proc(app: ^App) -> bool {
  if !render.ready(&app.renderer) do return false
  render.environment_map_load(&app.renderer, #load("../../assets/Cannon_Exterior.hdr"))
  render.camera_look_at(render.main_camera(&app.renderer), {0, 6, 14}, {0, 1, 0})
  app.yaw, app.pitch, app.dist = render.camera_orbit_state(render.main_camera(&app.renderer))
  light := world.spawn(&app.scene, {6, 12, 6})
  render.attach(&app.renderer, render.SlotHandle(light.index), render.light_create(&app.renderer, render.make_directional_light(color = {1, 0.97, 0.93, 5.0}, shadow_radius = 20.0)))
  ground := world.spawn(&app.scene, {0, -1, 0})
  render.attach(&app.renderer, render.SlotHandle(ground.index), render.primitive(&app.renderer, .QUAD_XZ, .GRAY, cast_shadow = false))
  world.scale(&app.scene, ground, 12.0)

  wave_mat   := render.material_create(&app.renderer, base_color_factor = {0.3, 0.55, 0.85, 1}, metallic_value = 0.2, roughness_value = 0.5)
  knot_mat   := render.material_create(&app.renderer, base_color_factor = {0.9, 0.5,  0.2,  1}, metallic_value = 0.8, roughness_value = 0.3)
  spiral_mat := render.material_create(&app.renderer, base_color_factor = {0.4, 0.85, 0.4,  1}, metallic_value = 0.0, roughness_value = 0.7)

  wave_node   = spawn_mesh(app, render.mesh_create(&app.renderer, build_wave(40, 8.0, 0.6)), wave_mat, {-6, 0, 0})
  knot_node   = spawn_mesh(app, render.mesh_create(&app.renderer, build_torus_knot(2, 3, 200, 12, 1.6, 0.3)), knot_mat, {0, 1.5, 0})
  spiral_node = spawn_mesh(app, render.mesh_create(&app.renderer, build_helix_tube(120, 8, 2.5, 0.25, 4.0, 3.0)), spiral_mat, {6, 0, 0})
  return true
}

build_wave :: proc(n: int, size: f32, amp: f32) -> render.Geometry {
  vertices := make([]render.Vertex, n * n)
  indices := make([]u32, (n - 1) * (n - 1) * 6)
  step := size / f32(n - 1)
  for j in 0 ..< n do for i in 0 ..< n {
    x := f32(i) * step - size * 0.5
    z := f32(j) * step - size * 0.5
    y := math.sin(x * 0.9) * math.cos(z * 0.9) * amp
    dy_dx := 0.9 * math.cos(x * 0.9) * math.cos(z * 0.9) * amp
    dy_dz := -0.9 * math.sin(x * 0.9) * math.sin(z * 0.9) * amp
    vertices[j * n + i] = render.Vertex{
      position = {x, y, z},
      normal   = linalg.normalize([3]f32{-dy_dx, 1.0, -dy_dz}),
      color    = {1, 1, 1, 1},
      uv       = {f32(i) / f32(n - 1), f32(j) / f32(n - 1)},
    }
  }
  idx := 0
  for j in 0 ..< n - 1 do for i in 0 ..< n - 1 {
    a := u32(j * n + i); b := u32(j * n + i + 1)
    c := u32((j + 1) * n + i); d := u32((j + 1) * n + i + 1)
    indices[idx + 0] = a; indices[idx + 1] = c; indices[idx + 2] = b
    indices[idx + 3] = b; indices[idx + 4] = c; indices[idx + 5] = d
    idx += 6
  }
  return render.geometry_create(vertices, indices)
}

build_torus_knot :: proc(p, q, segments_u, segments_v: int, radius, tube: f32) -> render.Geometry {
  vertices := make([]render.Vertex, segments_u * segments_v)
  indices := make([]u32, segments_u * segments_v * 6)
  for i in 0 ..< segments_u {
    u := f32(i) / f32(segments_u) * 2.0 * math.PI
    r := math.cos(f32(q) * u) + 2.0
    center := [3]f32{r * math.cos(f32(p) * u), math.sin(f32(q) * u), r * math.sin(f32(p) * u)}
    eps := f32(0.001); u2 := u + eps; r2 := math.cos(f32(q) * u2) + 2.0
    next := [3]f32{r2 * math.cos(f32(p) * u2), math.sin(f32(q) * u2), r2 * math.sin(f32(p) * u2)}
    t := linalg.normalize(next - center)
    bi := linalg.normalize(linalg.cross(t, [3]f32{0, 1, 0}))
    nrm := linalg.normalize(linalg.cross(bi, t))
    for j in 0 ..< segments_v {
      v := f32(j) / f32(segments_v) * 2.0 * math.PI
      offset := nrm * (math.cos(v) * tube) + bi * (math.sin(v) * tube)
      pos := center * radius + offset
      vertices[i * segments_v + j] = render.Vertex{
        position = pos, normal = linalg.normalize(offset),
        color = {1, 1, 1, 1}, uv = {f32(i) / f32(segments_u), f32(j) / f32(segments_v)},
      }
    }
  }
  idx := 0
  for i in 0 ..< segments_u do for j in 0 ..< segments_v {
    i_next := (i + 1) % segments_u; j_next := (j + 1) % segments_v
    a := u32(i * segments_v + j);  b := u32(i * segments_v + j_next)
    c := u32(i_next * segments_v + j); d := u32(i_next * segments_v + j_next)
    indices[idx + 0] = a; indices[idx + 1] = b; indices[idx + 2] = c
    indices[idx + 3] = b; indices[idx + 4] = d; indices[idx + 5] = c
    idx += 6
  }
  return render.geometry_create(vertices, indices)
}

build_helix_tube :: proc(segments_u, segments_v: int, helix_radius, tube, height, turns: f32) -> render.Geometry {
  vertices := make([]render.Vertex, segments_u * segments_v)
  indices := make([]u32, (segments_u - 1) * segments_v * 6)
  for i in 0 ..< segments_u {
    t := f32(i) / f32(segments_u - 1)
    angle := t * turns * 2.0 * math.PI
    center := [3]f32{helix_radius * math.cos(angle), t * height, helix_radius * math.sin(angle)}
    tangent := linalg.normalize([3]f32{-helix_radius * math.sin(angle), height / (turns * 2.0 * math.PI), helix_radius * math.cos(angle)})
    side := linalg.normalize(linalg.cross(tangent, [3]f32{0, 1, 0}))
    nrm := linalg.normalize(linalg.cross(side, tangent))
    for j in 0 ..< segments_v {
      v := f32(j) / f32(segments_v) * 2.0 * math.PI
      offset := nrm * (math.cos(v) * tube) + side * (math.sin(v) * tube)
      pos := center + offset
      vertices[i * segments_v + j] = render.Vertex{
        position = pos, normal = linalg.normalize(offset),
        color = {1, 1, 1, 1}, uv = {t, f32(j) / f32(segments_v)},
      }
    }
  }
  idx := 0
  for i in 0 ..< segments_u - 1 do for j in 0 ..< segments_v {
    j_next := (j + 1) % segments_v
    a := u32(i * segments_v + j);     b := u32(i * segments_v + j_next)
    c := u32((i + 1) * segments_v + j); d := u32((i + 1) * segments_v + j_next)
    indices[idx + 0] = a; indices[idx + 1] = b; indices[idx + 2] = c
    indices[idx + 3] = b; indices[idx + 4] = d; indices[idx + 5] = c
    idx += 6
  }
  return render.geometry_create(vertices, indices)
}

update :: proc(app: ^App, dt: f32) {
  platform.read_input(&app.window, &app.input)
  if !app.input.mouse_captured {
    if input.mouse_down(&app.input, .LEFT) {
      app.yaw += app.input.mouse_delta.x * 0.02
      app.pitch = clamp(app.pitch + app.input.mouse_delta.y * 0.02, -1.5, 1.5)
    }
    app.dist = clamp(app.dist - app.input.scroll.y * 2, 1, 200)
  }
  render.camera_orbit(render.main_camera(&app.renderer), app.yaw, app.pitch, app.dist)
  spin += dt * f32(rotate_speed)
  set_spin(app, wave_node,   wave_visible,   spin, {-6, 0, 0})
  set_spin(app, knot_node,   knot_visible,   spin, {0, 1.5, 0})
  set_spin(app, spiral_node, spiral_visible, spin, {6, 0, 0})
  world.update(&app.scene)
  render.stage_transforms(&app.renderer, world.changes(&app.scene))
  render.update(&app.renderer, dt)
}

set_spin :: proc(app: ^App, h: world.NodeHandle, visible: bool, angle: f32, pos: [3]f32) {
  world.set_visible(&app.scene, h, visible)
  world.translate(&app.scene, h, pos)
  world.rotate(&app.scene, h, angle)
}

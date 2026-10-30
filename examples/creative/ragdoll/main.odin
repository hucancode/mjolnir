// Ragdoll: play around with physics powered ragdoll.
// Model: CesiumMan by Cesium (CC BY 4.0).
package main

import "core:log"
import "core:math/linalg"
import mu "vendor:microui"
import "mjolnir"
import "mjolnir/debugui"
import "mjolnir/geometry"
import "mjolnir/gltf"
import "mjolnir/input"
import "mjolnir/physics"
import "mjolnir/platform"
import "mjolnir/ragdoll"
import "mjolnir/render"
import "mjolnir/world"

Mode :: enum {
  EDIT,
  SIM,
}

PART_COUNT :: 13

BLOCKS := [PART_COUNT]ragdoll.Block {
  {name = "Pelvis", start = 0, end = 1, parent = -1, back = 0.07, size = {0.095, 0, 0.07}},
  {name = "Torso", start = 1, end = 3, parent = 0, joint = .BALL, cone = 0.45, extend = 0.03, size = {0.085, 0, 0.065}},
  {name = "Head", start = 3, end = 4, parent = 1, joint = .BALL, cone = 0.8, extend = 0.14, size = {0.07, 0, 0.075}},
  {name = "Upper arm L", start = 5, end = 6, parent = 1, joint = .BALL, cone = 1.6, back = 0.03, size = {0.035, 0, 0.035}},
  {name = "Forearm L", start = 6, end = 7, parent = 3, joint = .HINGE, lower = -0.1, upper = 2.4, extend = 0.08, size = {0.03, 0, 0.03}},
  {name = "Upper arm R", start = 8, end = 9, parent = 1, joint = .BALL, cone = 1.6, back = 0.03, size = {0.035, 0, 0.035}},
  {name = "Forearm R", start = 9, end = 10, parent = 5, joint = .HINGE, lower = -0.1, upper = 2.4, extend = 0.08, size = {0.03, 0, 0.03}},
  {name = "Thigh L", start = 11, end = 12, parent = 0, joint = .BALL, cone = 1.3, size = {0.055, 0, 0.055}},
  {name = "Shin L", start = 12, end = 13, parent = 7, joint = .HINGE, lower = -0.1, upper = 2.4, size = {0.045, 0, 0.045}},
  {name = "Foot L", start = 13, end = 14, parent = 8, joint = .HINGE, lower = -0.7, upper = 0.7, extend = 0.02, size = {0.04, 0, 0.035}},
  {name = "Thigh R", start = 15, end = 16, parent = 0, joint = .BALL, cone = 1.3, size = {0.055, 0, 0.055}},
  {name = "Shin R", start = 16, end = 17, parent = 10, joint = .HINGE, lower = -0.1, upper = 2.4, size = {0.045, 0, 0.045}},
  {name = "Foot R", start = 17, end = 18, parent = 11, joint = .HINGE, lower = -0.7, upper = 0.7, extend = 0.02, size = {0.04, 0, 0.035}},
}

MIRRORS := [PART_COUNT]int{-1, -1, -1, 5, 6, 3, 4, 10, 11, 12, 7, 8, 9}

Grab :: struct {
  active: bool,
  part:   int,
  joint:  physics.JointHandle,
  point:  [3]f32,
}

App :: struct {
  platform:  platform.Platform,
  scene:     world.World,
  renderer:  render.Renderer,
  input:     input.State,
  debug:     debugui.Context,
  orbit:     render.Orbit,
  phys:      physics.World,
  model:     gltf.Model,
  inst:      gltf.Instance,
  rag:       ragdoll.Ragdoll,
  blocks:    [PART_COUNT]ragdoll.Block,
  pins:      [dynamic]physics.JointHandle,
  grab:      Grab,
  mode:      Mode,
  selected:  int,
  mirror:    bool,
  show:      bool,
  pin_drops: bool,
  dirty:     bool,
}

main :: proc() {
  context.logger = log.create_console_logger()
  app := new(App)
  app.mirror = true
  app.show = true
  if !platform.init(&app.platform, 1280, 720, "Ragdoll") do return
  if !render.init(&app.renderer, app.platform.window) do return
  if !world.init(&app.scene) do return
  if !physics.init(&app.phys) do return
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

draw :: proc(app: ^App) -> bool {
  return mjolnir.frame(&app.platform, &app.renderer)
}

setup :: proc(app: ^App) -> mjolnir.Setup {
  if !render.ready(&app.renderer) do return .WAIT
  sun := render.light_create(&app.renderer, render.make_directional_light())
  mjolnir.spawn(&app.scene, &app.renderer, sun, rotation = linalg.quaternion_from_forward_and_up([3]f32{-0.4, -1, -0.3}, [3]f32{0, 1, 0}))
  if !debugui.init(&app.debug, &app.renderer) do return .FAIL

  mjolnir.spawn(&app.scene, &app.renderer, render.primitive(&app.renderer, .CUBE, .GRAY), {0, -0.05, 0}, scale = {40, 0.1, 40})
  mjolnir.spawn(&app.scene, &app.renderer, render.light_create(&app.renderer, render.make_point_light(intensity = 200, radius = 25)), {2, 6, 4})
  physics.body_create(&app.phys, {0, -0.5, 0}, collider = physics.BoxCollider{half_extents = {20, 0.5, 20}})

  app.model = gltf.model_create(&app.renderer, #load("assets/CesiumMan.glb"))
  app.inst = gltf.instance_create(&app.model, &app.scene, &app.renderer)
  if len(app.inst.skinned) == 0 do return .FAIL
  rig := app.inst.skinned[0].rig
  app.blocks = BLOCKS
  if !ragdoll.init(&app.rag, &app.model.rigs[rig].skeleton, app.blocks[:]) do return .FAIL
  for i in 0 ..< PART_COUNT do app.blocks[i].size.y = ragdoll.fit_length(&app.rag, i)
  respawn(app)

  app.orbit = render.make_orbit({1.2, 1.1, 3.4}, {0, 0.65, 0})
  return .READY
}

shutdown :: proc(app: ^App) {
  ragdoll.bodies_destroy(&app.rag, &app.phys)
  ragdoll.destroy(&app.rag)
  gltf.destroy(&app.inst, &app.scene, &app.renderer)
  gltf.destroy(&app.model, &app.renderer)
  delete(app.pins)
  physics.shutdown(&app.phys)
  world.shutdown(&app.scene)
  debugui.shutdown(&app.debug)
  render.shutdown(&app.renderer)
  platform.shutdown(&app.platform)
  free(app)
}

respawn :: proc(app: ^App) {
  app.dirty = false
  app.grab = {}
  clear(&app.pins)
  ragdoll.bodies_create(&app.rag, &app.phys, {0, ragdoll.ground_height(&app.rag), 0}, app.mode == .SIM)
}

set_mode :: proc(app: ^App, mode: Mode) {
  if app.mode == mode do return
  app.mode = mode
  respawn(app)
}

update :: proc(app: ^App, dt: f32) {
  render.lock(&app.renderer)
  platform.read_input(&app.platform, &app.input)
  debug_ui(app)
  if app.dirty do respawn(app)
  if app.mode == .EDIT do pick_part(app)
  else do drag_part(app)
  if !app.grab.active do mjolnir.orbit_drag(&app.orbit, render.main_camera(&app.renderer), &app.input, {.RIGHT})

  if app.mode == .SIM do physics.step(&app.phys, dt)
  rig := app.inst.skinned[0].rig
  palette := app.inst.animators[rig].palette
  if origin, ok := ragdoll.sync(&app.rag, &app.phys, palette); ok {
    world.transform(&app.scene, app.inst.root).position = origin
    world.transform(&app.scene, app.inst.root).scale = app.rag.scale
    render.stage_bones(&app.renderer, app.inst.bones[rig], palette)
  }
  if app.show do draw_blocks(app)
  mjolnir.update(&app.scene, &app.renderer, dt)
}

part_at_cursor :: proc(app: ^App) -> (part: int, hit: physics.RayHit, ok: bool) {
  ray := render.cursor_ray(&app.renderer, app.input.cursor) or_return
  hit = physics.raycast(&app.phys, ray)
  if !hit.hit do return
  part, ok = ragdoll.block_of(&app.rag, hit.body)
  return
}

pick_part :: proc(app: ^App) {
  if app.input.mouse_captured || !input.mouse_pressed(&app.input, .LEFT) do return
  if part, _, ok := part_at_cursor(app); ok do app.selected = part
}

drag_part :: proc(app: ^App) {
  g := &app.grab
  if !g.active {
    if app.input.mouse_captured || !input.mouse_pressed(&app.input, .LEFT) do return
    part, hit, ok := part_at_cursor(app)
    if !ok do return
    joint, made := physics.joint_create(&app.phys, ragdoll.body(&app.rag, part), {}, physics.BallJoint{anchor = hit.point})
    if !made do return
    g^ = {active = true, part = part, joint = joint, point = hit.point}
    app.selected = part
    return
  }
  if input.mouse_down(&app.input, .LEFT) {
    ray, ok := render.cursor_ray(&app.renderer, app.input.cursor)
    if !ok do return
    normal := linalg.mul(render.main_camera(&app.renderer).rotation, linalg.VECTOR3F32_Z_AXIS)
    if at, hit := geometry.ray_plane_intersection(ray, g.point, normal, 100); hit do physics.joint_anchor(&app.phys, g.joint, at)
    return
  }
  if app.pin_drops do append(&app.pins, g.joint)
  else do physics.joint_destroy(&app.phys, g.joint)
  g^ = {}
}

throw :: proc(app: ^App) {
  for k in 0 ..< PART_COUNT {
    physics.apply_impulse(&app.phys, ragdoll.body(&app.rag, k), ragdoll.mass(&app.rag, k) * [3]f32{2.5, 5, 1.5})
  }
  if position, _, _, ok := ragdoll.block_pose(&app.rag, &app.phys, 2); ok {
    physics.apply_impulse_at(&app.phys, ragdoll.body(&app.rag, 2), ragdoll.mass(&app.rag, 2) * [3]f32{0, 0, 3}, position + {0.05, 0.05, 0})
  }
}

unpin :: proc(app: ^App) {
  for j in app.pins do physics.joint_destroy(&app.phys, j)
  clear(&app.pins)
}

draw_blocks :: proc(app: ^App) {
  for k in 0 ..< PART_COUNT {
    position, rotation, half, ok := ragdoll.block_pose(&app.rag, &app.phys, k)
    if !ok do continue
    color := render.COLOR_RGB[.YELLOW] if k == app.selected else render.COLOR_RGB[.GREEN]
    if app.grab.active && app.grab.part == k do color = render.COLOR_RGB[.RED]
    render.debug_cube(&app.renderer, position, rotation, half, color)
    if app.mode == .SIM && app.blocks[k].parent >= 0 {
      start := [3]f32{0, -(half.y - app.blocks[k].back * app.rag.scale), 0}
      render.debug_point(&app.renderer, position + linalg.mul(rotation, start), 0.03 * app.rag.scale, render.COLOR_RGB[.CYAN], 0, true)
    }
  }
}

debug_ui :: proc(app: ^App) {
  ctx := debugui.begin(&app.debug, &app.input, &app.renderer)
  defer debugui.end(&app.debug, &app.renderer)
  if debugui.window(&app.debug, "Ragdoll", {20, 20, 310, 420}) {
    mu.layout_row(ctx, {140, -1}, 0)
    if .SUBMIT in mu.button(ctx, "Edit" if app.mode == .SIM else "[Edit]") do set_mode(app, .EDIT)
    if .SUBMIT in mu.button(ctx, "[Simulate]" if app.mode == .SIM else "Simulate") do set_mode(app, .SIM)
    mu.layout_row(ctx, {-1}, 0)
    mu.checkbox(ctx, "Show physics blocks", &app.show)
    if app.mode == .EDIT do edit_ui(app, ctx)
    else do sim_ui(app, ctx)
  }
}

edit_ui :: proc(app: ^App, ctx: ^mu.Context) {
  mu.label(ctx, "Size")
  if .CHANGE in mu.slider(ctx, &app.rag.scale, 0.5, 2) do app.dirty = true
  mu.label(ctx, "Click a block to select it")
  b := &app.blocks[app.selected]
  mu.label(ctx, b.name)
  edited := false
  mu.label(ctx, "Width")
  if .CHANGE in mu.slider(ctx, &b.size.x, 0.01, 0.25) do edited = true
  mu.label(ctx, "Length")
  if .CHANGE in mu.slider(ctx, &b.size.y, 0.02, 0.4) do edited = true
  mu.label(ctx, "Depth")
  if .CHANGE in mu.slider(ctx, &b.size.z, 0.01, 0.25) do edited = true
  mu.checkbox(ctx, "Mirror left and right", &app.mirror)
  mirror := MIRRORS[app.selected]
  if edited {
    if app.mirror && mirror >= 0 do app.blocks[mirror].size = b.size
    app.dirty = true
  }
  if .SUBMIT in mu.button(ctx, "Reset this part") {
    b.size = BLOCKS[app.selected].size
    b.size.y = ragdoll.fit_length(&app.rag, app.selected)
    app.dirty = true
  }
}

sim_ui :: proc(app: ^App, ctx: ^mu.Context) {
  mu.label(ctx, "Drag a block with the left mouse button")
  mu.label(ctx, "Orbit with the right mouse button")
  mu.checkbox(ctx, "Pin a block where you drop it", &app.pin_drops)
  mu.layout_row(ctx, {140, -1}, 0)
  if .SUBMIT in mu.button(ctx, "Unpin all") do unpin(app)
  if .SUBMIT in mu.button(ctx, "Throw") do throw(app)
  mu.layout_row(ctx, {-1}, 0)
  if .SUBMIT in mu.button(ctx, "Reset pose") do app.dirty = true
}

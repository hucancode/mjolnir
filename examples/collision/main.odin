// Static and dynamic bodies of every shape, moved and reshaped live.
package main

import "../../mjolnir"
import "../../mjolnir/debugui"
import "../../mjolnir/physics"
import "../../mjolnir/input"
import "../../mjolnir/platform"
import "../../mjolnir/render"
import "../../mjolnir/world"
import "core:fmt"
import "core:log"
import "core:math"
import "core:math/linalg"
import mu "vendor:microui"

CIRCLE_RADIUS :: f32(4.0)
CIRCLE_OMEGA :: f32(1.2)
CIRCLE_STEERING :: f32(3.0)
GROUND_HALF :: [3]f32{20, 0.5, 20}
WALL_HEIGHT :: f32(2.0)
WALL_THICK :: f32(0.5)
NO_SELECTION :: -1

Shape :: enum {
  Sphere,
  Box,
  Cylinder,
}

Kind :: enum {
  Static,
  DynamicStill,
  DynamicCircle,
}

Body :: struct {
  kind:          Kind,
  shape:         Shape,
  size:          [3]f32, // Sphere: x=radius; Box: half extents; Cylinder: x=radius y=half height
  position:      [3]f32, // DynamicCircle: the orbit center
  euler_deg:     [3]f32,
  mass:          f32,
  node:          world.NodeHandle,
  visual:        world.NodeHandle,
  handle:        physics.BodyHandle,
  shape_changed: bool,
  pose_changed:  bool,
  mass_changed:  bool,
}

App :: struct {
  window:        platform.Platform,
  scene:         world.World,
  renderer:      render.Renderer,
  debug:         debugui.Context,
  input:         input.State,
  orbit:         render.Orbit,
  phys:          physics.World,
  bodies:        [3]Body,
  selected:      int,
  circle_angle:  f32,
  reset_pending: bool,
  paused:        bool,
}

default_bodies :: proc() -> [3]Body {
  return {
    {kind = .Static, shape = .Box, size = {1.5, 1.5, 1.5}, position = {0, 1.5, -4.5}, mass = 1},
    {kind = .DynamicStill, shape = .Sphere, size = {1.2, 1.2, 1.2}, position = {0, 1.2, 4.5}, mass = 5},
    {kind = .DynamicCircle, shape = .Sphere, size = {1.0, 1.0, 1.0}, position = {0, 1.5, 0}, mass = 3},
  }
}

main :: proc() {
  context.logger = log.create_console_logger()
  app := new(App)
  if !physics.init(&app.phys) do return
  w := &app.window
  if !platform.init(w, 1100, 760, "Collision") do return
  if !render.init(&app.renderer, "Collision", w.window, platform.framebuffer_size(w), platform.dpi_scale(w)) do return
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
  debugui.shutdown(&app.debug)
  render.shutdown(&app.renderer)
  platform.shutdown(&app.window)
  physics.shutdown(&app.phys)
  free(app)
}

should_close :: proc(app: ^App) -> bool {
  return platform.should_close(&app.window)
}

frame :: proc(app: ^App) -> bool {
  platform.poll_events(&app.window)
  return render.frame(&app.renderer, platform.framebuffer_size(&app.window), platform.dpi_scale(&app.window))
}

setup :: proc(app: ^App) -> mjolnir.Setup {
  if !render.ready(&app.renderer) do return .WAIT
  if !debugui.init(&app.debug, &app.renderer, {1100, 760}) do return .FAIL
  render.setup(&app.renderer)
  render.camera_look_at(render.main_camera(&app.renderer), {16, 14, 16}, {0, 1.5, 0})
  app.orbit = render.orbit_from_camera(render.main_camera(&app.renderer), {0, 1.5, 0})
  spawn_scene(app)
  return .READY
}

spawn_scene :: proc(app: ^App) {

  spawn_scenery_box(app, {0, -GROUND_HALF.y, 0}, GROUND_HALF)
  spawn_scenery_box(app, {GROUND_HALF.x, WALL_HEIGHT, 0}, {WALL_THICK, WALL_HEIGHT, GROUND_HALF.z})
  spawn_scenery_box(app, {-GROUND_HALF.x, WALL_HEIGHT, 0}, {WALL_THICK, WALL_HEIGHT, GROUND_HALF.z})
  spawn_scenery_box(app, {0, WALL_HEIGHT, GROUND_HALF.z}, {GROUND_HALF.x, WALL_HEIGHT, WALL_THICK})
  spawn_scenery_box(app, {0, WALL_HEIGHT, -GROUND_HALF.z}, {GROUND_HALF.x, WALL_HEIGHT, WALL_THICK})

  app.bodies = default_bodies()
  app.selected = NO_SELECTION
  app.circle_angle = 0
  for &b in app.bodies {
    b.node = world.spawn(&app.scene, b.position)
    world.rotate(&app.scene, b.node, body_rotation(&b))
    b.visual = world.spawn(&app.scene, parent = b.node)
    render.attach(&app.renderer, render.SlotHandle(b.visual.index), render.primitive(&app.renderer, body_mesh(b.shape), body_color(b.kind)))
    world.scale(&app.scene, b.visual, body_visual_scale(&b))
    if b.kind == .Static {
      b.handle = physics.body_create(&app.phys, b.position, body_rotation(&b), body_collider(&b))
    } else {
      b.handle = physics.body_create(&app.phys, b.position, body_rotation(&b), body_collider(&b), b.mass, user = world.Handle(b.node))
    }
  }
}

spawn_scenery_box :: proc(app: ^App, center, half_extents: [3]f32) {
  node := world.spawn(&app.scene, center)
  physics.body_create(&app.phys, center, collider = physics.BoxCollider{half_extents = half_extents}, user = world.Handle(node))
  visual := world.spawn(&app.scene, parent = node)
  render.attach(&app.renderer, render.SlotHandle(visual.index), render.primitive(&app.renderer, .CUBE, .GRAY))
  world.scale(&app.scene, visual, half_extents)
}

body_collider :: proc(b: ^Body) -> physics.Collider {
  switch b.shape {
  case .Sphere:   return physics.SphereCollider{radius = b.size.x}
  case .Box:      return physics.BoxCollider{half_extents = b.size}
  case .Cylinder: return physics.CylinderCollider{radius = b.size.x, half_height = b.size.y}
  }
  return nil
}

body_visual_scale :: proc(b: ^Body) -> [3]f32 {
  switch b.shape {
  case .Sphere:
    return b.size.x
  case .Box:
    return b.size
  case .Cylinder:
    return {b.size.x, b.size.y, b.size.x}
  }
  return 1
}

body_mesh :: proc(shape: Shape) -> render.Primitive {
  switch shape {
  case .Sphere:   return .SPHERE
  case .Box:      return .CUBE
  case .Cylinder: return .CYLINDER
  }
  return .SPHERE
}

body_color :: proc(kind: Kind) -> render.Color {
  switch kind {
  case .Static:        return .BLUE
  case .DynamicStill:  return .CYAN
  case .DynamicCircle: return .MAGENTA
  }
  return .WHITE
}

body_rotation :: proc(b: ^Body) -> quaternion128 {
  r := b.euler_deg * math.RAD_PER_DEG
  return linalg.quaternion_from_euler_angles_f32(r.y, r.x, r.z, .YXZ)
}

apply_shape :: proc(app: ^App, b: ^Body) {
  physics.set_collider(&app.phys, b.handle, body_collider(b))
  render.attach(&app.renderer, render.SlotHandle(b.visual.index), render.primitive(&app.renderer, body_mesh(b.shape), body_color(b.kind)))
  world.scale(&app.scene, b.visual, body_visual_scale(b))
}

apply_pose :: proc(app: ^App, b: ^Body) {
  physics.set_pose(&app.phys, b.handle, b.position, body_rotation(b))
  if b.kind == .Static {
    world.translate(&app.scene, b.node, b.position)
    world.rotate(&app.scene, b.node, body_rotation(b))
    return
  }
  physics.set_velocity(&app.phys, b.handle, {})
  physics.set_angular_velocity(&app.phys, b.handle, {})
}

drive_circle :: proc(app: ^App, b: ^Body) {
  a := app.circle_angle
  target := b.position + [3]f32{math.cos(a), 0, math.sin(a)} * CIRCLE_RADIUS
  tangent := [3]f32{-math.sin(a), 0, math.cos(a)} * (CIRCLE_RADIUS * CIRCLE_OMEGA)
  body, ok := physics.body(&app.phys, b.handle)
  if !ok do return
  desired := tangent + (target - body.position) * CIRCLE_STEERING
  physics.apply_impulse(&app.phys, b.handle, (desired - body.velocity) * b.mass)
}

update :: proc(app: ^App, dt: f32) {
  render.lock(&app.renderer)
  defer render.unlock(&app.renderer)
  platform.read_input(&app.window, &app.input)
  debugui.feed(&app.debug, &app.input, &app.renderer)
  debug_ui(app)
  render.stage_overlay(&app.renderer, debugui.end(&app.debug))
  if !app.input.mouse_captured {
    drag := app.input.mouse_delta if input.mouse_down(&app.input, .LEFT) else 0
    render.orbit_drag(&app.orbit, drag, app.input.scroll.y)
  }
  render.camera_orbit(render.main_camera(&app.renderer), app.orbit)
  if app.reset_pending {
    app.reset_pending = false
    physics.teardown(&app.phys)
    world.teardown(&app.scene)
    render.teardown(&app.renderer)
    spawn_scene(app)
  }
  if !app.paused do app.circle_angle += dt * CIRCLE_OMEGA

  for &b in app.bodies {
    if b.shape_changed do apply_shape(app, &b)
    if b.mass_changed do physics.set_mass(&app.phys, b.handle, b.mass)
    if b.pose_changed && b.kind != .DynamicCircle do apply_pose(app, &b)
    b.shape_changed, b.mass_changed, b.pose_changed = false, false, false
    if b.kind == .DynamicCircle && !app.paused do drive_circle(app, &b)
  }

  handle_picking(app)
  draw_contacts(app, dt)
  draw_selection(app)
  if !app.paused do physics.step(&app.phys, dt)
  world.set_world_poses(&app.scene, physics.body_poses(&app.phys))
  world.update(&app.scene)
  render.stage_transforms(&app.renderer, world.changes(&app.scene))
  render.update(&app.renderer, dt)
}

handle_picking :: proc(app: ^App) {
  if app.input.mouse_captured || !input.mouse_pressed(&app.input, .LEFT) do return
  ray, has_ray := render.cursor_ray(&app.renderer, app.input.cursor)
  if !has_ray do return
  hit := physics.raycast(&app.phys, ray)
  app.selected = NO_SELECTION
  if !hit.hit do return
  for &b, i in app.bodies do if b.handle == hit.body do app.selected = i
}

draw_contacts :: proc(app: ^App, dt: f32) {
  life := max(dt * 2.0, 0.04)
  for &c in physics.contacts(&app.phys) {
    for p in c.points[:c.count] {
      penetration := -p.base_separation
      render.debug_sphere(&app.renderer, p.point, 0.12, {1, 0.9, 0, 1}, life, true)
      render.debug_arrow(&app.renderer, p.point, p.point + c.normal * 0.9, {0, 1, 1, 1}, life, true)
      if penetration > 0 {
        render.debug_segment(&app.renderer, p.point, p.point - c.normal * penetration, {1, 0, 1, 1}, life, true)
      }
      if dt > 0 && p.normal_impulse > 0 {
        force := p.normal_impulse / dt
        force_arrow_length := clamp(force * 0.01, 0.1, 4.0)
        render.debug_arrow(&app.renderer, p.point, p.point + c.normal * force_arrow_length, {1, 0.25, 0.2, 1}, life, true)
      }
    }
  }
}

draw_selection :: proc(app: ^App) {
  if app.selected == NO_SELECTION do return
  b := &app.bodies[app.selected]
  body, ok := physics.body(&app.phys, b.handle)
  if !ok do return
  pos, rot := body.position, body.rotation
  render.debug_axes(&app.renderer, pos, rot, 1.8, 0, true)
  green := [4]f32{0.2, 1, 0.3, 1}
  switch b.shape {
  case .Sphere:
    render.debug_sphere(&app.renderer, pos, b.size.x, green, 0, true)
  case .Box:
    render.debug_cube(&app.renderer, pos, rot, b.size, green, 0, true)
  case .Cylinder:
    axis := linalg.quaternion_mul_vector3(rot, [3]f32{0, 1, 0})
    render.debug_circle(&app.renderer, pos + axis * b.size.y, axis, b.size.x, green, 0, true)
    render.debug_circle(&app.renderer, pos - axis * b.size.y, axis, b.size.x, green, 0, true)
  }
}

slider_changed :: proc(ctx: ^mu.Context, value: ^f32, low, high: f32) -> bool {
  return .CHANGE in mu.slider(ctx, value, low, high)
}

inspector :: proc(ctx: ^mu.Context, b: ^Body) {
  mu.layout_row(ctx, {90, 90, 90}, 0)
  for shape in Shape {
    if .SUBMIT in mu.button(ctx, fmt.tprint(shape)) {
      b.shape = shape
      b.shape_changed = true
    }
  }

  mu.layout_row(ctx, {-1}, 0)
  switch b.shape {
  case .Sphere:
    mu.label(ctx, "Radius")
    b.shape_changed |= slider_changed(ctx, &b.size.x, 0.2, 4.0)
  case .Box:
    mu.label(ctx, "Half extents X / Y / Z")
    b.shape_changed |= slider_changed(ctx, &b.size.x, 0.2, 4.0)
    b.shape_changed |= slider_changed(ctx, &b.size.y, 0.2, 4.0)
    b.shape_changed |= slider_changed(ctx, &b.size.z, 0.2, 4.0)
  case .Cylinder:
    mu.label(ctx, "Radius / Half height")
    b.shape_changed |= slider_changed(ctx, &b.size.x, 0.2, 4.0)
    b.shape_changed |= slider_changed(ctx, &b.size.y, 0.2, 3.0)
  }

  mu.label(ctx, "Orbit center X / Y / Z" if b.kind == .DynamicCircle else "Position X / Y / Z")
  b.pose_changed |= slider_changed(ctx, &b.position.x, -12, 12)
  b.pose_changed |= slider_changed(ctx, &b.position.y, 0, 12)
  b.pose_changed |= slider_changed(ctx, &b.position.z, -12, 12)

  mu.label(ctx, "Rotation X / Y / Z (deg)")
  b.pose_changed |= slider_changed(ctx, &b.euler_deg.x, -180, 180)
  b.pose_changed |= slider_changed(ctx, &b.euler_deg.y, -180, 180)
  b.pose_changed |= slider_changed(ctx, &b.euler_deg.z, -180, 180)

  if b.kind != .Static {
    mu.label(ctx, "Mass")
    b.mass_changed |= slider_changed(ctx, &b.mass, 0.5, 50)
  }
}

debug_ui :: proc(app: ^App) {
  ctx := debugui.begin(&app.debug)
  if debugui.window(&app.debug, "Inspector", {20, 220, 320, 400}, {}, {.NO_CLOSE}) {
    if app.selected == NO_SELECTION {
      mu.label(ctx, "Left-click an object to select it.")
    } else {
      inspector(ctx, &app.bodies[app.selected])
    }
  }
  if debugui.window(&app.debug, "Collision", {20, 20, 320, 180}, {}, {.NO_CLOSE}) {
    mu.layout_row(ctx, {150, -1}, 0)
    if .SUBMIT in mu.button(ctx, "Reset Scene") do app.reset_pending = true
    if .SUBMIT in mu.button(ctx, "Resume" if app.paused else "Pause") do app.paused = !app.paused

    mu.label(ctx, fmt.tprintf("Contacts: %d", physics.perf(&app.phys).contact_count))

    mu.layout_row(ctx, {-1}, 0)
    shown := physics.contacts(&app.phys)
    for c in shown[:min(6, len(shown))] {
      p := c.points[0]
      mu.label(
        ctx,
        fmt.tprintf(
          "%s Contact x%d (%.1f,%.1f,%.1f) pen %.2f J %.1f",
          "Dynamic" if c.b_dynamic else "Static",
          c.count, p.point.x, p.point.y, p.point.z, -p.base_separation, p.normal_impulse,
        ),
      )
    }
  }
}

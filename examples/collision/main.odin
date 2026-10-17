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
GROUND_HALF :: [3]f32{20, 0.5, 20}
WALL_HEIGHT :: f32(2.0)
WALL_THICK :: f32(0.5)
DEG2RAD :: math.PI / 180.0

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
  size:          [3]f32, // Sphere: x=radius; Box: half extents; Cylinder: x=radius y=height
  position:      [3]f32, // for DynamicCircle this is the orbit center
  euler_deg:     [3]f32,
  mass:          mu.Real,
  node:          world.NodeHandle, // physics-driven parent
  visual:        world.NodeHandle, // mesh child; mesh swapped in place on shape change
  handle:        physics.BodyHandle, // recreated on reset
  // change tracking
  built_shape:   Shape,
  built_size:    [3]f32,
  applied_pos:   [3]f32,
  applied_rot:   quaternion128,
  applied_valid: bool,
}

SceneryBox :: struct {
  center: [3]f32,
  half:   [3]f32,
  node:   world.NodeHandle,
}

App :: struct {
  window:   platform.Platform,
  scene:    world.World,
  renderer: render.Renderer,
  debug:    debugui.Context,
  input:    input.State,
  // orbit controller state, owned by the app
  yaw, pitch, dist: f32,
}

bodies: [3]Body
scenery: [5]SceneryBox // ground + 4 walls (static, not editable)
selected: int = -1
circle_angle: f32
reset_requested: bool
paused: bool
phys: physics.World

default_bodies :: proc() -> [3]Body {
  return {
    {kind = .Static, shape = .Box, size = {1.5, 1.5, 1.5}, position = {0, 1.5, -4.5}, mass = 1},
    {kind = .DynamicStill, shape = .Sphere, size = {1.2, 1.2, 1.2}, position = {0, 1.2, 4.5}, mass = 5},
    {kind = .DynamicCircle, shape = .Sphere, size = {1.0, 1.0, 1.0}, position = {0, 1.5, 0}, mass = 3},
  }
}

main :: proc() {
  context.logger = log.create_console_logger()
  physics.init(&phys)
  app := new(App)
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
  free(app)
  physics.shutdown(&phys)
}

should_close :: proc(app: ^App) -> bool {
  return platform.should_close(&app.window)
}

frame :: proc(app: ^App) -> bool {
  platform.poll_events(&app.window)
  panel(app)
  render.stage_overlay(&app.renderer, {commands = debugui.end(&app.debug, platform.dpi_scale(&app.window))})
  return render.frame(&app.renderer, platform.framebuffer_size(&app.window), platform.dpi_scale(&app.window))
}

// On the web the renderer's device arrives after main returns: build the scene once it is up.
setup :: proc(app: ^App) -> bool {
  if !render.ready(&app.renderer) do return false
  if !debugui.init(&app.debug, &app.renderer) do return false
  render.environment_map_load(&app.renderer, #load("../../assets/Cannon_Exterior.hdr"))
  render.camera_look_at(render.main_camera(&app.renderer), {16, 14, 16}, {0, 1.5, 0})
  app.yaw, app.pitch, app.dist = render.camera_orbit_state(render.main_camera(&app.renderer))
  light := world.spawn(&app.scene, {-6, 14, 6})
  render.attach(&app.renderer, render.SlotHandle(light.index), render.light_create(&app.renderer, render.make_directional_light({1, 0.96, 0.9, 1}, 6.0, true)))
  spawn_scene(app)
  return true
}

// One-time creation of nodes + visuals + physics bodies.
spawn_scene :: proc(app: ^App) {
  wy := WALL_HEIGHT
  scenery[0] = {center = {0, -GROUND_HALF.y, 0}, half = GROUND_HALF}
  scenery[1] = {center = {GROUND_HALF.x, wy, 0}, half = {WALL_THICK, WALL_HEIGHT, GROUND_HALF.z}}
  scenery[2] = {center = {-GROUND_HALF.x, wy, 0}, half = {WALL_THICK, WALL_HEIGHT, GROUND_HALF.z}}
  scenery[3] = {center = {0, wy, GROUND_HALF.z}, half = {GROUND_HALF.x, WALL_HEIGHT, WALL_THICK}}
  scenery[4] = {center = {0, wy, -GROUND_HALF.z}, half = {GROUND_HALF.x, WALL_HEIGHT, WALL_THICK}}
  for &s in scenery {
    s.node, _ = world.spawn(&app.scene, s.center)
    physics.body_create(&phys, s.center, collider = physics.BoxCollider{half_extents = s.half}, user = world.Handle(s.node))
    visual := world.spawn(&app.scene, parent = s.node)
    render.attach(&app.renderer, render.SlotHandle(visual.index), render.primitive(&app.renderer, .CUBE, .GRAY))
    world.scale(&app.scene, visual, s.half.x, s.half.y, s.half.z)
  }

  bodies = default_bodies()
  for &b in bodies {
    q := obj_rotation(&b)
    b.node, _ = world.spawn(&app.scene, b.position)
    world.rotate(&app.scene, b.node, q)
    b.visual, _ = world.spawn(&app.scene, parent = b.node)
    render.attach(&app.renderer, render.SlotHandle(b.visual.index), render.primitive(&app.renderer, obj_mesh(b.shape), obj_color(b.kind)))
    s := obj_visual_scale(&b)
    world.scale(&app.scene, b.visual, s.x, s.y, s.z)
    create_body_physics(app, &b)
    b.built_shape = b.shape
    b.built_size = b.size
  }
}

obj_collider :: proc(b: ^Body) -> physics.Collider {
  switch b.shape {
  case .Sphere:
    return physics.SphereCollider{radius = b.size.x}
  case .Box:
    return physics.BoxCollider{half_extents = b.size}
  case .Cylinder:
    return physics.CylinderCollider{radius = b.size.x, height = b.size.y}
  }
  return physics.SphereCollider{radius = b.size.x}
}

// Scale that fits the unit builtin mesh to the collider. The builtin cylinder
// has unit half-height, so cylinders halve `height`.
obj_visual_scale :: proc(b: ^Body) -> [3]f32 {
  switch b.shape {
  case .Sphere:   return {b.size.x, b.size.x, b.size.x}
  case .Box:      return b.size
  case .Cylinder: return {b.size.x, b.size.y * 0.5, b.size.x}
  }
  return {1, 1, 1}
}

obj_mesh :: proc(shape: Shape) -> render.Primitive {
  switch shape {
  case .Sphere:   return .SPHERE
  case .Box:      return .CUBE
  case .Cylinder: return .CYLINDER
  }
  return .SPHERE
}

obj_color :: proc(kind: Kind) -> render.Color {
  switch kind {
  case .Static:        return .BLUE
  case .DynamicStill:  return .CYAN
  case .DynamicCircle: return .MAGENTA
  }
  return .WHITE
}

obj_rotation :: proc(b: ^Body) -> quaternion128 {
  r := b.euler_deg * DEG2RAD
  qx := linalg.quaternion_angle_axis(r.x, linalg.VECTOR3F32_X_AXIS)
  qy := linalg.quaternion_angle_axis(r.y, linalg.VECTOR3F32_Y_AXIS)
  qz := linalg.quaternion_angle_axis(r.z, linalg.VECTOR3F32_Z_AXIS)
  return qy * qx * qz
}

// Create the physics body for b's current descriptor and wire the node to it.
// The static body has no user link: the example poses its node directly.
create_body_physics :: proc(app: ^App, b: ^Body) {
  if b.kind == .Static {
    b.handle = physics.body_create(&phys, b.position, obj_rotation(b), obj_collider(b))
  } else {
    b.handle = physics.body_create(&phys, b.position, obj_rotation(b), obj_collider(b), f32(b.mass), user = world.Handle(b.node))
  }
}

apply_shape :: proc(app: ^App, b: ^Body) {
  physics.set_collider(&phys, b.handle, obj_collider(b))
  render.attach(
    &app.renderer,
    render.SlotHandle(b.visual.index),
    render.MeshAttachment {
      mesh = app.renderer.builtin_meshes[obj_mesh(b.shape)],
      material = app.renderer.builtin_materials[obj_color(b.kind)],
      cast_shadow = true,
    },
  )
  s := obj_visual_scale(b)
  world.scale(&app.scene, b.visual, s.x, s.y, s.z) // marks the node dirty → re-staged
  b.built_shape = b.shape
  b.built_size = b.size
}

drive_circle :: proc(b: ^Body) {
  a := circle_angle
  center := b.position
  target := center + [3]f32{math.cos(a), 0, math.sin(a)} * CIRCLE_RADIUS
  tangent :=
    [3]f32{-math.sin(a), 0, math.cos(a)} * (CIRCLE_RADIUS * CIRCLE_OMEGA)
  body, ok := physics.body(&phys, b.handle)
  if !ok do return
  desired := tangent + (target - body.position) * 3.0
  physics.apply_impulse(&phys, b.handle, (desired - body.velocity) * f32(b.mass))
}

update :: proc(app: ^App, dt: f32) {
  platform.read_input(&app.window, &app.input)
  debugui.feed(&app.debug, &app.input)
  if !app.input.mouse_captured {
    if input.mouse_down(&app.input, .LEFT) {
      app.yaw += app.input.mouse_delta.x * 0.02
      app.pitch = clamp(app.pitch + app.input.mouse_delta.y * 0.02, -1.5, 1.5)
    }
    app.dist = clamp(app.dist - app.input.scroll.y * 2, 1, 200)
  }
  render.camera_orbit(render.main_camera(&app.renderer), app.yaw, app.pitch, app.dist)
  if reset_requested {
    reset_requested = false
    physics.teardown(&phys)
    world.teardown(&app.scene)
    render.teardown(&app.renderer)
    if render.setup(&app.renderer) do setup(app)
    render.update(&app.renderer, dt)
    return
  }
  if !paused do circle_angle += dt * CIRCLE_OMEGA

  for i in 0 ..< len(bodies) {
    b := &bodies[i]
    if b.shape != b.built_shape || b.size != b.built_size {
      apply_shape(app, b)
    }
  }

  for i in 0 ..< len(bodies) {
    b := &bodies[i]
    q := obj_rotation(b)
    if b.kind == .Static {
      if !b.applied_valid || b.position != b.applied_pos || q != b.applied_rot {
        physics.set_pose(&phys, b.handle, b.position, q)
        world.translate(&app.scene, b.node, b.position)
        world.rotate(&app.scene, b.node, q)
        b.applied_pos = b.position
        b.applied_rot = q
        b.applied_valid = true
      }
      continue
    }
    if b.mass > 0 do physics.set_mass(&phys, b.handle, f32(b.mass))
    if b.kind == .DynamicCircle {
      if !paused do drive_circle(b)
    } else if !b.applied_valid ||
       b.position != b.applied_pos ||
       q != b.applied_rot {
      // DynamicStill: teleport only when the user edits the transform.
      physics.set_pose(&phys, b.handle, b.position, q)
      physics.set_velocity(&phys, b.handle, {})
      physics.set_angular_velocity(&phys, b.handle, {})
      b.applied_pos = b.position
      b.applied_rot = q
      b.applied_valid = true
    }
  }

  handle_picking(app)
  draw_contacts(app, dt)
  draw_selection(app)
  if !paused do physics.step(&phys, dt)
  world.set_world_poses(&app.scene, physics.body_poses(&phys))
  world.update(&app.scene)
  render.stage_transforms(&app.renderer, world.changes(&app.scene))
  render.update(&app.renderer, dt)
}

handle_picking :: proc(app: ^App) {
  if app.input.mouse_captured do return
  if !input.mouse_pressed(&app.input, .LEFT) do return
  ray, has_ray := render.cursor_ray(&app.renderer, app.input.cursor)
  if !has_ray do return
  hit := physics.raycast(&phys, ray)
  if !hit.hit {
    selected = -1
    return
  }
  selected = -1
  for &b, i in bodies do if b.handle == hit.body do selected = i
}

draw_contacts :: proc(app: ^App, dt: f32) {
  life := max(dt * 2.0, 0.04)
  draw_one :: proc(
    app: ^App,
    p, n: [3]f32,
    penetration, normal_impulse, dt, life: f32,
  ) {
    // hit point
    render.debug_sphere(&app.renderer, p, 0.12, {1, 0.9, 0, 1}, life, true)
    // contact normal (cyan, fixed length)
    render.debug_arrow(&app.renderer, p, p + n * 0.9, {0, 1, 1, 1}, life, true)
    // penetration depth (magenta, into surface)
    if penetration > 0 {
      render.debug_segment(
        &app.renderer,
        p,
        p - n * penetration,
        {1, 0, 1, 1},
        life,
        true,
      )
    }
    // approximate contact force = impulse / dt (red, scaled + clamped)
    if dt > 0 && normal_impulse > 0 {
      force := normal_impulse / dt
      flen := clamp(force * 0.01, 0.1, 4.0)
      render.debug_arrow(&app.renderer, p, p + n * flen, {1, 0.25, 0.2, 1}, life, true)
    }
  }
  for c in phys.contacts {
    for i in 0 ..< c.count {
      p := c.points[i]
      draw_one(app, p.point, c.normal, -p.base_separation, p.normal_impulse, dt, life)
    }
  }
}

body_transform :: proc(
  app: ^App,
  b: ^Body,
) -> (
  pos: [3]f32,
  rot: quaternion128,
) {
  if b.kind == .Static {
    return b.position, obj_rotation(b)
  }
  if body, ok := physics.body(&phys, b.handle); ok {
    return body.position, body.rotation
  }
  return b.position, obj_rotation(b)
}

draw_selection :: proc(app: ^App) {
  if selected < 0 do return
  b := &bodies[selected]
  pos, rot := body_transform(app, b)
  render.debug_axes(&app.renderer, pos, rot, 1.8, 0, true)
  green := [4]f32{0.2, 1, 0.3, 1}
  switch b.shape {
  case .Sphere:
    render.debug_sphere(&app.renderer, pos, b.size.x, green, 0, true)
  case .Box:
    render.debug_cube(&app.renderer, pos, rot, b.size * 2, green, 0, true)
  case .Cylinder:
    axis := linalg.quaternion_mul_vector3(rot, [3]f32{0, 1, 0})
    h := b.size.y * 0.5
    render.debug_circle(&app.renderer, pos + axis * h, axis, b.size.x, green, 0, true)
    render.debug_circle(&app.renderer, pos - axis * h, axis, b.size.x, green, 0, true)
  }
}

panel :: proc(app: ^App) {
  ctx := debugui.begin(&app.debug)
  if mu.window(ctx, "Inspector", {20, 220, 320, 500}, {.NO_CLOSE}) {
    if selected <= 0 {
      mu.label(ctx, "Left-click an object to select it.")
    } else {
      b := &bodies[selected]
      mu.layout_row(ctx, {-1}, 0)
      mu.layout_row(ctx, {90, 90, 90}, 0)
      if .SUBMIT in mu.button(ctx, "Sphere") do b.shape = .Sphere
      if .SUBMIT in mu.button(ctx, "Box") do b.shape = .Box
      if .SUBMIT in mu.button(ctx, "Cylinder") do b.shape = .Cylinder

      mu.layout_row(ctx, {-1}, 0)
      switch b.shape {
      case .Sphere:
        mu.label(ctx, "Radius")
        mu.slider(ctx, &b.size.x, 0.2, 4.0)
      case .Box:
        mu.label(ctx, "Half extents X / Y / Z")
        mu.slider(ctx, &b.size.x, 0.2, 4.0)
        mu.slider(ctx, &b.size.y, 0.2, 4.0)
        mu.slider(ctx, &b.size.z, 0.2, 4.0)
      case .Cylinder:
        mu.label(ctx, "Radius / Height")
        mu.slider(ctx, &b.size.x, 0.2, 4.0)
        mu.slider(ctx, &b.size.y, 0.4, 6.0)
      }

      label := b.kind == .DynamicCircle ? "Orbit center X / Y / Z" : "Position X / Y / Z"
      mu.label(ctx, label)
      mu.slider(ctx, &b.position.x, -12, 12)
      mu.slider(ctx, &b.position.y, 0, 12)
      mu.slider(ctx, &b.position.z, -12, 12)

      mu.label(ctx, "Rotation X / Y / Z (deg)")
      mu.slider(ctx, &b.euler_deg.x, -180, 180)
      mu.slider(ctx, &b.euler_deg.y, -180, 180)
      mu.slider(ctx, &b.euler_deg.z, -180, 180)

      if b.kind != .Static {
        mu.label(ctx, "Mass")
        mu.slider(ctx, &b.mass, 0.5, 50)
      }
    }
  }
  if mu.window(ctx, "Collision", {20, 20, 320, 180}, {.NO_CLOSE}) {
    mu.layout_row(ctx, {150, -1}, 0)
    // Reset in the next update, not mid-way through building this frame's UI.
    if .SUBMIT in mu.button(ctx, "Reset Scene") do reset_requested = true
    if .SUBMIT in mu.button(ctx, paused ? "Resume" : "Pause") do paused = !paused

    mu.label(ctx, fmt.tprintf("Contacts: %d", phys.last_perf.contact_count))

    mu.layout_row(ctx, {-1}, 0)
    for c in phys.contacts[:min(6, len(phys.contacts))] {
      p := c.points[0]
      mu.label(
        ctx,
        fmt.tprintf(
          "%s Contact x%d (%.1f,%.1f,%.1f) pen %.2f J %.1f",
          c.b_dynamic ? "Dynamic" : "Static",
          c.count, p.point.x, p.point.y, p.point.z, -p.base_separation, p.normal_impulse,
        ),
      )
    }
  }
}
